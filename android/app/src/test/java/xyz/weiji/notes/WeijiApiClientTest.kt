package xyz.weiji.notes

import android.content.Context
import android.os.Looper
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import java.util.UUID
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import xyz.weiji.notes.core.network.*
import xyz.weiji.notes.core.storage.*
import xyz.weiji.notes.model.*
import xyz.weiji.notes.state.AppState

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class WeijiApiClientTest {
    private lateinit var server: MockWebServer
    private lateinit var cache: NoteCacheDb
    private lateinit var store: CredentialStore

    @Before fun setup() {
        server = MockWebServer().apply { start() }
        val context = ApplicationProvider.getApplicationContext<Context>()
        cache = Room.inMemoryDatabaseBuilder(context, NoteCacheDb::class.java).build()
        store = CredentialStore(context.getSharedPreferences(UUID.randomUUID().toString(), Context.MODE_PRIVATE))
    }

    @After fun teardown() {
        server.close()
        cache.close()
    }

    private fun client() = WeijiApiClient(server.origin, "a-token", "alice")

    @Test fun carriesBearerAccountOriginAndHonors304() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(304))
        assertNull(client().notes("\"local\""))
        val read = server.next()
        assertEquals("GET", read.method)
        assertEquals("/api/notes", read.path)
        assertEquals("Bearer a-token", read.getHeader("Authorization"))
        assertEquals("alice", read.getHeader("X-Journal-Account"))
        assertEquals("application/json", read.getHeader("Accept"))
        assertEquals("\"local\"", read.getHeader("If-None-Match"))

        server.json(AiDeletedSessionResponse(SESSION_ID))
        assertEquals(SESSION_ID, client().deleteSession(SESSION_ID).deleted)
        val deletion = server.next()
        assertEquals("/api/ai/sessions/$SESSION_ID", deletion.path)
        assertEquals("DELETE", deletion.method)
        assertEquals(server.origin, deletion.getHeader("Origin"))
    }

    @Test fun redirectDoesNotForwardToken() {
        MockWebServer().use { destination ->
            destination.start()
            server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", destination.url("/stolen")))
            val error = assertThrows(ApiException::class.java) { runBlocking { client().session() } }
            assertEquals(302, error.status)
            assertEquals(0, destination.requestCount)
        }
    }

    @Test fun forbiddenAccountClearsOnlyCurrentCredentialsAndCache() {
        val dao = cache.notes()
        runBlocking {
            dao.replaceSnapshot(server.origin, "alice", listOf(testNote), "current")
            dao.replaceSnapshot(server.origin, "bob", listOf(otherNote), "other")
        }
        store.credentials = Credentials(server.origin, "a-token", testSession)
        server.raw("""{"error":"登录账号已变化，请重新登录。"}""", 403)
        val app = AppState(store, dao)
        spinUntil { app.session == null && app.error != null }
        assertEquals("alice", server.next().getHeader("X-Journal-Account"))
        assertNull(store.credentials)
        assertEquals("登录账号已变化，请重新登录。", app.error)
        runBlocking {
            assertEquals(CachedSnapshot(emptyList(), null), dao.loadSnapshot(server.origin, "alice"))
            assertEquals(CachedSnapshot(listOf(otherNote), "other"), dao.loadSnapshot(server.origin, "bob"))
        }
    }

    @Test fun roomSnapshotIsolationSurvives304ReplacementAndLogout() {
        val dao = cache.notes()
        val alternate = "https://other.example"
        runBlocking {
            dao.replaceSnapshot(server.origin, "alice", listOf(testNote, otherNote), "\"first\"")
            dao.replaceSnapshot(alternate, "alice", listOf(otherNote), "alternate")
            dao.replaceSnapshot(server.origin, "bob", listOf(testNote), "bob")
        }
        store.credentials = Credentials(server.origin, "a-token", testSession)
        server.json(testSession)
        server.enqueue(MockResponse().setResponseCode(304))
        val app = AppState(store, dao)
        spinUntil { app.notesLoaded && !app.noteBusy }
        assertEquals("/api/session", server.next().path)
        assertEquals("\"first\"", server.next().getHeader("If-None-Match"))
        assertEquals(setOf(testNote, otherNote), app.notes.toSet())
        runBlocking {
            assertEquals(setOf(testNote, otherNote), dao.loadSnapshot(server.origin, "alice").notes.toSet())
            assertEquals(listOf(otherNote), dao.loadSnapshot(alternate, "alice").notes)
            assertEquals(listOf(testNote), dao.loadSnapshot(server.origin, "bob").notes)
        }
        val changed = testNote.copy(body = "修改", revision = 2)
        server.json(NotesSnapshotResponse(listOf(changed), listOf(Tombstone(OTHER_NOTE_ID, 4))), "\"second\"")
        waitFor(app.syncNotes())
        assertEquals(listOf(changed), app.notes)
        assertEquals("\"first\"", server.next().getHeader("If-None-Match"))
        runBlocking { assertEquals(CachedSnapshot(listOf(changed), "\"second\""), dao.loadSnapshot(server.origin, "alice")) }
        server.raw("""{"ok":true}""")
        waitFor(app.logout())
        assertEquals("/api/auth/logout", server.next().path)
        assertNull(app.session)
        runBlocking {
            assertEquals(CachedSnapshot(emptyList(), null), dao.loadSnapshot(server.origin, "alice"))
            assertEquals(CachedSnapshot(listOf(otherNote), "alternate"), dao.loadSnapshot(alternate, "alice"))
            assertEquals(CachedSnapshot(listOf(testNote), "bob"), dao.loadSnapshot(server.origin, "bob"))
        }
    }

    @Test fun writesRevisionForCreateEditAndDelete() = runBlocking {
        val api = client()
        val created = testNote.copy(body = "新建", revision = 1)
        val edited = created.copy(body = "更新", revision = 2)
        for ((expected, payload, result) in listOf(
            Triple(0, created.payload(created.body), created),
            Triple(1, edited.payload(edited.body), edited),
        )) {
            server.json(NoteConflictCurrent(note = result))
            assertEquals(result, api.write(NoteMutation(NOTE_ID, expected, payload)).note)
            val request = server.next()
            assertEquals(server.origin, request.getHeader("Origin"))
            assertEquals("/api/notes", request.path)
            assertEquals("POST", request.method)
            assertEquals("application/json; charset=utf-8", request.getHeader("Content-Type"))
            val body = wireJson.parseToJsonElement(request.body.readUtf8()).jsonObject
            assertEquals(expected, body.getValue("expectedRevision").jsonPrimitive.int)
            assertEquals(payload.body, body.getValue("note").jsonObject.getValue("body").jsonPrimitive.content)
        }
        val tombstone = Tombstone(NOTE_ID, 3)
        server.json(NoteConflictCurrent(deleted = tombstone))
        assertEquals(tombstone, api.write(NoteMutation(NOTE_ID, 2, delete = true)).deleted)
        val request = server.next()
        val body = wireJson.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertEquals(2, body.getValue("expectedRevision").jsonPrimitive.int)
        assertTrue(body.getValue("delete").jsonPrimitive.boolean)
        assertFalse("note" in body)
    }

    @Test fun conflictFormsDecodeWithoutReplacingUnsavedDraft() {
        server.json(testSession)
        server.json(NotesSnapshotResponse(listOf(testNote), emptyList()))
        store.credentials = Credentials(server.origin, "a-token", testSession)
        val app = AppState(store, cache.notes())
        spinUntil { app.notesLoaded && !app.noteBusy }
        server.next()
        server.next()
        app.edit(testNote)
        app.changeDraft("重要的草稿")
        val cloud = testNote.copy(body = "云端新版", revision = 2)
        for ((wire, expected) in listOf(
            wireJson.encodeToJsonElement(NoteConflictCurrent(note = cloud)) to NoteConflictCurrent(note = cloud),
            wireJson.encodeToJsonElement(NoteConflictCurrent(deleted = Tombstone(NOTE_ID, 3))) to NoteConflictCurrent(deleted = Tombstone(NOTE_ID, 3)),
            JsonNull to null,
        )) {
            server.raw("""{"error":"笔记冲突","current":$wire}""", 409)
            waitFor(app.save())
            assertEquals(1, wireJson.parseToJsonElement(server.next().body.readUtf8()).jsonObject
                .getValue("expectedRevision").jsonPrimitive.int)
            assertEquals(expected, app.conflict?.current)
            assertEquals("笔记冲突", app.conflict?.error)
            assertEquals("重要的草稿", app.editor?.body)
            assertEquals(1, app.editor?.note?.revision)
        }
    }

    @Test fun walkAndSemanticUseTheServerRoutes() = runBlocking {
        val focus = RelatedNoteSummary(NOTE_ID, "焦点", DATE)
        val related = RelatedNoteSummary(OTHER_NOTE_ID, "关联", DATE)
        val walk = RelatedNotesResponse(focus, "semantic", 7, 9, listOf(RelatedNote(OTHER_NOTE_ID, 0.8, 76, listOf("工作"), related)))
        server.json(walk)
        server.json(semantic)
        server.json(semantic.copy(indexing = true))
        assertEquals(walk, client().related(NOTE_ID))
        val relatedRequest = server.next()
        assertEquals("GET", relatedRequest.method)
        assertEquals("/api/notes/$NOTE_ID/related?limit=10", relatedRequest.path)
        assertEquals(semantic, client().semanticStatus())
        val statusRequest = server.next()
        assertEquals("GET", statusRequest.method)
        assertEquals("/api/semantic/status", statusRequest.path)
        assertTrue(client().reindex().indexing)
        val post = server.next()
        assertEquals("/api/semantic/reindex", post.path)
        assertEquals("POST", post.method)
        assertEquals(server.origin, post.getHeader("Origin"))
    }

    @Test fun aiRoutesDecodeModelsSourceSummaryAndFullSession() = runBlocking {
        val meta = ModelMeta("model-a", "Model A", "openai", true, listOf("medium", "high"), defaultEffort = "medium")
        val models = AiModelsResponse(true, listOf(meta.id), meta.id, "gateway", listOf(meta))
        val summary = AiSessionSummary(SESSION_ID, "测试对话", 2, DATE, DATE, "note", NOTE_ID)
        val page = AiSessionListResponse(listOf(summary), true, "$DATE|$SESSION_ID")
        server.json(models)
        server.json(AiSessionEnvelope(aiSession))
        server.json(AiSessionEnvelope(null))
        server.json(page)
        server.json(AiSessionEnvelope(aiSession))
        assertEquals(models, client().models())
        assertEquals("/api/ai/models", server.next().path)
        assertEquals(aiSession, client().sourceSession(NOTE_ID))
        assertEquals(NOTE_ID, server.next().requestUrl?.queryParameter("sourceNoteId"))
        assertNull(client().sourceSession(OTHER_NOTE_ID))
        assertEquals(OTHER_NOTE_ID, server.next().requestUrl?.queryParameter("sourceNoteId"))
        assertEquals(page, client().sessions(page.nextCursor))
        val listRequest = server.next().requestUrl!!
        assertEquals("/api/ai/sessions", listRequest.encodedPath)
        assertEquals("50", listRequest.queryParameter("limit"))
        assertEquals(page.nextCursor, listRequest.queryParameter("cursor"))
        assertEquals(aiSession, client().aiSession(SESSION_ID))
        assertEquals("/api/ai/sessions/$SESSION_ID", server.next().path)
    }

    @Test fun chatSendsNewAndContinuedTurnsWithStreamingHeadersAndDecodesSse() = runBlocking {
        val input = AiChatRequest("查笔记", "request-id", "codex", listOf(OTHER_NOTE_ID), sourceNoteId = NOTE_ID)
        for (request in listOf(input, input.copy(clientRequestId = "continued", sessionId = SESSION_ID, expectedVersion = 2))) {
            server.stream(frame("delta", """{"text":"结果"}""") + doneFrame())
            val received = mutableListOf<SseEvent>()
            assertEquals(aiSession, client().chat(request) { received += it }.session)
            assertEquals(listOf(SseEvent.Delta("结果")), received)
            val post = server.next()
            assertEquals("/api/ai/chat", post.path)
            assertEquals("POST", post.method)
            assertEquals(server.origin, post.getHeader("Origin"))
            assertEquals("text/event-stream", post.getHeader("Accept"))
            assertEquals("identity", post.getHeader("Accept-Encoding"))
            val body = wireJson.parseToJsonElement(post.body.readUtf8()).jsonObject
            assertEquals("codex", body.getValue("provider").jsonPrimitive.content)
            assertEquals("查笔记", body.getValue("message").jsonPrimitive.content)
            assertEquals(request.clientRequestId, body.getValue("clientRequestId").jsonPrimitive.content)
            assertEquals(listOf(JsonPrimitive(OTHER_NOTE_ID)), body.getValue("referencedNoteIds").jsonArray)
            assertEquals(NOTE_ID, body.getValue("sourceNoteId").jsonPrimitive.content)
            assertTrue(body.getValue("stream").jsonPrimitive.boolean)
            assertEquals(request.sessionId, body["sessionId"]?.jsonPrimitive?.content)
            assertEquals(request.expectedVersion, body["expectedVersion"]?.jsonPrimitive?.int)
        }
    }

    private fun waitFor(job: Job) = spinUntil { job.isCompleted }

    private fun spinUntil(check: () -> Boolean) {
        val deadline = System.nanoTime() + 5_000_000_000L
        while (!check() && System.nanoTime() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(5)
        }
        assertTrue("Timed out waiting for app state", check())
    }
}
