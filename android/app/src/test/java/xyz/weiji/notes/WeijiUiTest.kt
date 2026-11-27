package xyz.weiji.notes

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Looper
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.unit.dp
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config
import xyz.weiji.notes.core.auth.OAuthPkce
import xyz.weiji.notes.core.storage.CredentialStore
import xyz.weiji.notes.core.storage.Credentials
import xyz.weiji.notes.core.storage.NoteCacheDb
import xyz.weiji.notes.model.*

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w393dp-h852dp")
class WeijiUiTest {
    @get:Rule val compose = createEmptyComposeRule()

    private lateinit var app: WeijiApplication
    private lateinit var server: MockWebServer
    private lateinit var creds: CredentialStore
    private lateinit var db: NoteCacheDb
    private var scenario: ActivityController<MainActivity>? = null

    @Before fun setUp() {
        app = ApplicationProvider.getApplicationContext()
        server = MockWebServer().apply { start() }
        creds = CredentialStore(app.getSharedPreferences(UUID.randomUUID().toString(), Context.MODE_PRIVATE))
        creds.origin = server.origin
        db = Room.inMemoryDatabaseBuilder(app, NoteCacheDb::class.java).build()
        app.testContainer = WeijiContainer(creds, db)
    }

    @After fun tearDown() {
        scenario?.close()
        app.testContainer = null
        server.close()
        db.close()
    }

    private fun launch(intent: Intent = Intent(app, MainActivity::class.java)) {
        scenario = Robolectric.buildActivity(MainActivity::class.java, intent).setup().windowFocusChanged(true)
    }

    private fun deliver(intent: Intent) {
        scenario!!.newIntent(intent)
    }

    private fun waitText(text: String, substring: Boolean = false) {
        // Indeterminate progress animations can run while the real HTTP request is in flight.
        val clock = compose.mainClock
        clock.autoAdvance = false
        try {
            compose.waitUntil(timeoutMillis = 8_000) {
                shadowOf(Looper.getMainLooper()).idle()
                Snapshot.sendApplyNotifications()
                clock.advanceTimeByFrame()
                compose.onAllNodesWithText(text, substring = substring).fetchSemanticsNodes().isNotEmpty()
            }
        } catch (timeout: ComposeTimeoutException) {
            throw AssertionError("Missing text: $text\n${compose.onRoot(useUnmergedTree = true).printToString()}", timeout)
        } finally {
            clock.autoAdvance = true
        }
    }

    private fun oauthConfig(origin: String = server.origin) =
        AuthProvidersResponse("oauth", true, origin, listOf(AuthProvider("github", "GitHub")))
    private fun noteSnapshot(vararg notes: Note) = NotesSnapshotResponse(notes.toList(), emptyList())
    private fun callback(state: String) = Intent(Intent.ACTION_VIEW, Uri.parse("weiji://auth/callback?code=valid-code&state=$state"))
        .setClass(app, MainActivity::class.java)

    private fun respondToExchange() {
        server.json(AuthExchangeResponse("native-token", "device-session", DATE, testSession.user))
        server.json(testSession)
        server.json(noteSnapshot(testNote))
    }

    private fun checkExchange(verifier: String) {
        val exchange = server.next()
        assertEquals("/api/auth/exchange", exchange.path)
        assertEquals(server.origin, exchange.getHeader("Origin"))
        val body = wireJson.parseToJsonElement(exchange.body.readUtf8()).jsonObject
        assertEquals("valid-code", body.getValue("code").jsonPrimitive.content)
        assertEquals(verifier, body.getValue("codeVerifier").jsonPrimitive.content)
        assertTrue(body.getValue("deviceLabel").jsonPrimitive.content.startsWith("Android ("))
        assertNull(creds.pending)
        assertEquals("native-token", creds.credentials?.token)
        assertEquals("/api/session", server.next().path)
        assertEquals("alice", server.next().getHeader("X-Journal-Account"))
    }

    @Test fun loginShowsOAuthButtonAndItsStartIntent() {
        server.json(oauthConfig())
        launch()
        waitText("用 GitHub 登录")
        val button = compose.onNodeWithText("用 GitHub 登录")
        button.assertIsDisplayed().assertHeightIsAtLeast(48.dp).assertWidthIsAtLeast(48.dp).performClick()
        compose.waitUntil(timeoutMillis = 5_000) { creds.pending != null }
        assertEquals("/api/auth/providers", server.next().path)
        assertEquals(server.origin, creds.pending?.origin)
        val launched = shadowOf(app).nextStartedActivity
        assertEquals("android", launched.data?.getQueryParameter("client"))
        assertEquals(creds.pending?.state, launched.data?.getQueryParameter("state"))
        assertEquals(OAuthPkce.challenge(creds.pending!!.verifier), launched.data?.getQueryParameter("code_challenge"))
    }

    @Test fun wrongPublicOriginHidesOAuthAndManualTokenStillLogsIn() {
        server.json(oauthConfig("https://wrong.example"))
        server.json(testSession.copy(authMode = "legacy"))
        server.json(noteSnapshot(testNote))
        launch()
        waitText("登录服务地址不一致。")
        compose.onNodeWithText("用 GitHub 登录").assertDoesNotExist()
        compose.onNodeWithText("高级连接").performClick()
        compose.onNode(hasSetTextAction() and hasText("访问令牌")).performTextInput("manual-secret")
        compose.onNodeWithText("使用令牌连接").performClick()
        waitText(testNote.body)
        assertEquals("/api/auth/providers", server.next().path)
        val login = server.next()
        assertEquals("/api/session", login.path)
        assertEquals("Bearer manual-secret", login.getHeader("Authorization"))
        assertNull(login.getHeader("X-Journal-Account"))
        assertEquals("alice", server.next().getHeader("X-Journal-Account"))
    }

    @Test fun coldStartConsumesPersistedOAuthCallback() {
        val pending = OAuthPkce.pending(server.origin)
        creds.pending = pending
        // Both provider discovery and exchange may start on the login page.
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.path) {
                "/api/auth/providers" -> MockResponse().setBody(wireJson.encodeToString(AuthProvidersResponse.serializer(), oauthConfig()))
                "/api/auth/exchange" -> MockResponse().setBody(wireJson.encodeToString(
                    AuthExchangeResponse.serializer(), AuthExchangeResponse("native-token", "device-session", DATE, testSession.user)))
                "/api/session" -> MockResponse().setBody(wireJson.encodeToString(SessionInfo.serializer(), testSession))
                "/api/notes" -> MockResponse().setBody(wireJson.encodeToString(NotesSnapshotResponse.serializer(), noteSnapshot(testNote)))
                else -> MockResponse().setResponseCode(404)
            }
        }
        launch(callback(pending.state))
        waitText(testNote.body)
        val requests = List(server.requestCount) { server.next() }
        assertEquals(1, requests.count { it.path == "/api/auth/exchange" })
        val exchange = requests.single { it.path == "/api/auth/exchange" }
        val body = wireJson.parseToJsonElement(exchange.body.readUtf8()).jsonObject
        assertEquals(pending.verifier, body.getValue("codeVerifier").jsonPrimitive.content)
        assertEquals("valid-code", body.getValue("code").jsonPrimitive.content)
        assertNull(creds.pending)
        assertEquals("native-token", creds.credentials?.token)
    }

    @Test fun warmSingleTopCallbackConsumesPersistedOAuthState() {
        server.json(oauthConfig())
        launch()
        waitText("用 GitHub 登录")
        assertEquals("/api/auth/providers", server.next().path)
        val pending = OAuthPkce.pending(server.origin)
        creds.pending = pending
        respondToExchange()
        deliver(callback(pending.state))
        waitText(testNote.body)
        checkExchange(pending.verifier)
    }

    @Test fun notesSearchSuggestionsAndShareEditorPrefill() {
        authenticated(testNote, otherNote)
        compose.onNode(hasSetTextAction() and hasText("搜索笔记")).performTextInput("另一条")
        compose.onNodeWithText(testNote.body).assertDoesNotExist()
        compose.onNodeWithText(otherNote.body).assertIsDisplayed()
        val share = "分享的文字"
        deliver(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, share))
        compose.onNode(hasSetTextAction() and hasText("笔记内容")).assertTextContains(share)
        compose.onNode(hasSetTextAction() and hasText("笔记内容")).performTextInput(" #工作/")
        compose.onNodeWithText("#工作/项目").assertIsDisplayed().performClick()
        compose.onNode(hasSetTextAction() and hasText("笔记内容")).assertTextContains("$share #工作/项目 ")
    }

    @Test fun normalUserSettingsNeverRequestAdminAndLeaveCacheIntact() {
        authenticated(testNote, otherNote)
        server.json(testSession)
        server.json(semantic)
        compose.onNodeWithContentDescription("设置").performClick()
        waitText("已索引 1 / 2")
        assertEquals("/api/session", server.next().path)
        assertEquals("/api/semantic/status", server.next().path)
        assertNull(server.takeRequest(250, TimeUnit.MILLISECONDS))
        compose.onNodeWithText("Obsidian 同步").assertDoesNotExist()
        assertEquals("alice", creds.credentials?.session?.user?.id)
        runBlocking {
            assertEquals(setOf(testNote, otherNote), db.notes().loadSnapshot(server.origin, "alice").notes.toSet())
        }
    }

    @Test fun walkUsesLocalFocusAndNoteAiOpensExistingOrNewSourceWithWorkingCitation() {
        authenticated(testNote, otherNote)
        val summary = RelatedNoteSummary(NOTE_ID, testNote.body, DATE)
        server.json(RelatedNotesResponse(summary, "semantic", 2, 2, emptyList()))
        compose.onNodeWithText("漫步").performClick()
        waitText("相关笔记")
        assertTrue(server.next().path!!.matches(Regex("/api/notes/($NOTE_ID|$OTHER_NOTE_ID)/related\\?limit=10")))
        compose.onNodeWithText(testNote.body).performClick()

        server.json(AiSessionEnvelope(aiSession))
        server.json(AiModelsResponse(true, listOf("model-a"), "model-a", "gateway"))
        compose.onNodeWithText("与 AI 对话").assertIsDisplayed().performSemanticsAction(SemanticsActions.OnClick)
        assertEquals(NOTE_ID, server.next().requestUrl?.queryParameter("sourceNoteId"))
        waitText("有记录", substring = true)
        assertEquals("/api/ai/models", server.next().path)
        compose.onNode(hasClickAction() and hasText("[N1]")).assertHeightIsAtLeast(48.dp)
            .assertWidthIsAtLeast(48.dp).performClick()
        waitText("与 AI 对话")
        compose.onNodeWithText("返回").performClick()
        compose.onNodeWithText("笔记").performClick()
        compose.onNodeWithText(otherNote.body).performClick()
        server.json(AiSessionEnvelope(null))
        compose.onNodeWithText("与 AI 对话").assertIsDisplayed().performSemanticsAction(SemanticsActions.OnClick)
        waitText("来源笔记")
        assertEquals(OTHER_NOTE_ID, server.next().requestUrl?.queryParameter("sourceNoteId"))
        compose.onNodeWithText("有记录", substring = true).assertDoesNotExist()

        val running = frame("step", """{"id":"search","kind":"retrieve","label":"检索中","status":"running"}""")
        val finished = frame("step", """{"id":"search","kind":"retrieve","label":"检索完成","status":"done"}""")
        val message = frame("delta", """{"text":"答复"}""")
        server.enqueue(MockResponse().setHeader("Content-Type", "text/event-stream")
            .setBody(running + finished + message).throttleBody(running.toByteArray().size.toLong(), 600, TimeUnit.MILLISECONDS))
        compose.onNode(hasSetTextAction() and hasText("消息")).performTextInput("请查一下")
        compose.onNodeWithText("发送").assertHeightIsAtLeast(48.dp).performClick()
        waitText("检索完成")
        compose.onAllNodesWithText("检索完成").assertCountEquals(1)
        compose.onNodeWithText("检索中").assertDoesNotExist()
        waitText("发送")
        compose.onNode(hasSetTextAction() and hasText("消息")).assertTextContains("请查一下")
        assertEquals("/api/ai/chat", server.next().path)
    }

    private fun authenticated(vararg notes: Note) {
        creds.credentials = Credentials(server.origin, "a-token", testSession)
        server.json(testSession)
        server.json(noteSnapshot(*notes))
        launch()
        waitText(notes.first().body)
        assertEquals("/api/session", server.next().path)
        assertEquals("/api/notes", server.next().path)
    }
}
