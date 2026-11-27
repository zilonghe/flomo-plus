package xyz.weiji.notes

import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test
import org.robolectric.annotation.Config
import xyz.weiji.notes.core.network.*
import xyz.weiji.notes.model.wireJson
import xyz.weiji.notes.state.AiChatState

@Config(sdk = [34])
class SseParserTest {
    @Test fun decodesUtf8MultilineFramesAndUpdatesStepsById() = runBlocking {
        val chat = AiChatState(WeijiApiClient("https://weiji.example"), "codex")
        val live = listOf(
            ": ping\r\n\r\n",
            "event: status\r\ndata: {\r\ndata: \"message\": \"检索中\"}\r\n\r\n",
            frame("step", """{"id":"retrieve","kind":"search","label":"检索","status":"running"}"""),
            frame("step", """{"id":"retrieve","kind":"search","label":"检索","status":"done"}"""),
            frame("citations", """{"citations":[{"ref":"N1","noteId":"$NOTE_ID","excerpt":"第一条"}]}"""),
            frame("reasoning", """{"text":"思考"}"""),
            frame("delta", """{"text":"你"}"""),
            frame("delta", """{"text":"好"}"""),
        ).joinToString("")
        val states = mutableListOf<String?>()
        val done = SseParser.read((live + doneFrame()).reader().buffered()) { event ->
            chat.apply(event)
            if (event is SseEvent.Step) states += chat.steps["retrieve"]?.status
        }
        assertEquals(listOf("running", "done"), states)
        assertEquals(1, chat.steps.size)
        assertEquals("检索中", chat.status)
        assertEquals(NOTE_ID, chat.citations.single().noteId)
        assertEquals("思考", chat.reasoning)
        assertEquals("你好", chat.delta)
        assertEquals(aiSession, done.session)
    }

    @Test fun eofBeforeDoneIsFailure() {
        val truncated = frame("delta", """{"text":"partial"}""")
        assertThrows(IOException::class.java) {
            runBlocking { SseParser.read(truncated.reader().buffered()) {} }
        }
    }

    @Test fun serverErrorFramePreservesStatusAndMessage() {
        val error = assertThrows(ApiException::class.java) {
            runBlocking { SseParser.read(frame("error", """{"error":"暂不可用","status":503}""").reader().buffered()) {} }
        }
        assertEquals(503, error.status)
        assertEquals("暂不可用", error.message)
    }

    @Test fun retryAfterRealTruncatedStreamReusesRequestIdAndKeepsDraft() {
        MockWebServer().use { server ->
            server.start()
            server.stream(": ping\n\n")
            server.stream(doneFrame())
            val chat = AiChatState(WeijiApiClient(server.origin), "codex")
            chat.draft = "找笔记"
            assertThrows(IOException::class.java) { runBlocking { chat.send() } }
            assertEquals("找笔记", chat.draft)
            assertFalse(chat.sending)
            val first = wireJson.parseToJsonElement(server.next().body.readUtf8()).jsonObject
            runBlocking { chat.send() }
            val retry = wireJson.parseToJsonElement(server.next().body.readUtf8()).jsonObject
            assertEquals(first, retry)
            assertTrue(retry.getValue("clientRequestId").jsonPrimitive.content.isNotBlank())
            assertEquals("", chat.draft)
            assertEquals(aiSession, chat.session)
        }
    }
}
