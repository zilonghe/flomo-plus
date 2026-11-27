package xyz.weiji.notes

import kotlinx.serialization.encodeToString
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import xyz.weiji.notes.model.*
import java.util.concurrent.TimeUnit

internal const val NOTE_ID = "12345678-1234-5678-9abc-123456789abc"
internal const val OTHER_NOTE_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
internal const val DATE = "2026-11-27T10:00:00Z"
internal const val SESSION_ID = "87654321-4321-8765-abcd-87654321abcd"
internal val testNote = Note(NOTE_ID, "第一条 #工作/项目", DATE, 1)
internal val otherNote = Note(OTHER_NOTE_ID, "另一条 #生活", DATE, 3)
internal val testSession = SessionInfo(User("alice", "Alice", "alice@example.com", "user"), true, "gateway", "oauth")
internal val aiSession = AiSession(SESSION_ID, "测试对话", 2, DATE, DATE, "note",
    listOf(AiTurn("assistant", "有记录 [N1]", listOf(AiCitation("N1", NOTE_ID, "第一条")))), NOTE_ID)
internal val semantic = SemanticStatus("disabled", 1, 2, 1, false, true)

internal val MockWebServer.origin get() = url("/").toString().removeSuffix("/")
internal inline fun <reified T> MockWebServer.json(value: T, etag: String? = null) =
    enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(wireJson.encodeToString(value)).apply {
        etag?.let { setHeader("ETag", it) }
    })
internal fun MockWebServer.raw(body: String, code: Int = 200) =
    enqueue(MockResponse().setResponseCode(code).setHeader("Content-Type", "application/json").setBody(body))
internal fun MockWebServer.stream(body: String) =
    enqueue(MockResponse().setHeader("Content-Type", "text/event-stream; charset=utf-8").setChunkedBody(body, 11))
internal fun MockWebServer.next(): RecordedRequest =
    checkNotNull(takeRequest(3, TimeUnit.SECONDS)) { "Missing expected HTTP request" }
internal fun frame(name: String, payload: String) = "event: $name\ndata: $payload\n\n"
internal fun doneFrame(session: AiSession = aiSession) =
    frame("done", wireJson.encodeToString(AiDone(session, "有记录 [N1]", listOf(AiCitation("N1", NOTE_ID, "第一条")))))
