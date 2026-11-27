package xyz.weiji.notes.core.network

import java.io.BufferedReader
import java.io.IOException
import kotlinx.serialization.Serializable
import xyz.weiji.notes.model.*

sealed interface SseEvent {
    data class Status(val message: String?) : SseEvent
    data class Step(val step: AiStep) : SseEvent
    data class Citations(val citations: List<AiCitation>) : SseEvent
    data class Reasoning(val text: String) : SseEvent
    data class Delta(val text: String) : SseEvent
}

object SseParser {
    @Serializable private data class StatusPayload(val message: String? = null)
    @Serializable private data class TextPayload(val text: String)
    @Serializable private data class CitationsPayload(val citations: List<AiCitation>)
    @Serializable private data class ErrorPayload(val error: String, val status: Int = 500)

    suspend fun read(reader: BufferedReader, onEvent: suspend (SseEvent) -> Unit): AiDone {
        var event = ""
        val data = mutableListOf<String>()
        while (true) {
            val line = reader.readLine() ?: throw IOException("连接已中断，请重试。")
            if (line.isEmpty()) {
                if (data.isNotEmpty()) {
                    val payload = data.joinToString("\n")
                    when (event) {
                        "status" -> onEvent(SseEvent.Status(wireJson.decodeFromString<StatusPayload>(payload).message))
                        "step" -> onEvent(SseEvent.Step(wireJson.decodeFromString(payload)))
                        "citations" -> onEvent(SseEvent.Citations(wireJson.decodeFromString<CitationsPayload>(payload).citations))
                        "reasoning" -> onEvent(SseEvent.Reasoning(wireJson.decodeFromString<TextPayload>(payload).text))
                        "delta" -> onEvent(SseEvent.Delta(wireJson.decodeFromString<TextPayload>(payload).text))
                        "done" -> return wireJson.decodeFromString(payload)
                        "error" -> wireJson.decodeFromString<ErrorPayload>(payload).let { throw ApiException(it.status, it.error) }
                    }
                }
                event = ""
                data.clear()
            } else if (!line.startsWith(':')) {
                val value = line.substringAfter(':', "").removePrefix(" ")
                when (line.substringBefore(':')) {
                    "event" -> event = value
                    "data" -> data.add(value)
                }
            }
        }
    }
}
