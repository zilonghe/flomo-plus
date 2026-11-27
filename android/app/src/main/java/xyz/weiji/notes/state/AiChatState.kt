package xyz.weiji.notes.state

import androidx.compose.runtime.*
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import xyz.weiji.notes.core.network.SseEvent
import xyz.weiji.notes.core.network.WeijiApiClient
import xyz.weiji.notes.model.*

class AiChatState(private val api: WeijiApiClient, val provider: String) {
    var session by mutableStateOf<AiSession?>(null)
        private set
    var sourceNoteId by mutableStateOf<String?>(null)
        private set
    private var draftState by mutableStateOf("")
    var draft: String
        get() = draftState
        set(value) {
            if (draftState != value) {
                draftState = value
                operationGeneration++
            }
        }
    var model by mutableStateOf("")
        private set
    var effort by mutableStateOf("")
    var apiKey by mutableStateOf("")
    var references by mutableStateOf(setOf<String>())
    var models by mutableStateOf<AiModelsResponse?>(null)
        private set
    var history by mutableStateOf(listOf<AiSessionSummary>())
        private set
    var nextCursor by mutableStateOf<String?>(null)
        private set
    var sending by mutableStateOf(false)
        private set
    var status by mutableStateOf<String?>(null)
        private set
    var delta by mutableStateOf("")
        private set
    var reasoning by mutableStateOf("")
        private set
    var citations by mutableStateOf(listOf<AiCitation>())
        private set
    val steps = mutableStateMapOf<String, AiStep>()

    private var retry: AiChatRequest? = null
    private var operationGeneration = 0L

    suspend fun loadModels() {
        if (models != null) return
        models = api.models()
        selectModel(models?.defaultModel.orEmpty())
    }

    fun selectModel(value: String) {
        model = value
        effort = models?.modelMeta.orEmpty().firstOrNull { it.id == value }?.defaultEffort.orEmpty()
    }

    private fun resetLive() {
        status = null
        delta = ""
        reasoning = ""
        citations = emptyList()
        steps.clear()
    }

    private fun select(value: AiSession?, source: String?) {
        session = value
        sourceNoteId = source
        draftState = ""
        references = emptySet()
        retry = null
        resetLive()
    }

    fun startNew() {
        if (sending) return
        operationGeneration++
        select(null, null)
    }

    suspend fun openSource(id: String) = selectSession(id) { api.sourceSession(id) }
    suspend fun open(id: String): Boolean = selectSession { api.aiSession(id) }

    private suspend fun selectSession(source: String? = null, load: suspend () -> AiSession?): Boolean {
        if (sending) return false
        val generation = ++operationGeneration
        val found = try {
            load()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            if (generation != operationGeneration) return false
            throw failure
        }
        if (generation != operationGeneration) return false
        select(found, source ?: found?.sourceNoteId)
        return true
    }

    suspend fun list(more: Boolean = false) {
        val cursor = if (more) nextCursor ?: return else null
        val page = api.sessions(cursor)
        history = if (more) (history + page.sessions).distinctBy { it.id } else page.sessions
        nextCursor = page.nextCursor.takeIf { page.hasMore }
    }

    suspend fun delete(id: String) {
        if (sending) return
        val deleted = api.deleteSession(id).deleted
        history = history.filterNot { it.id == deleted }
        if (session?.id == deleted) startNew()
    }

    suspend fun send() {
        val message = draft
        if (sending || message.isBlank()) return
        operationGeneration++
        val candidate = AiChatRequest(
            message, "", provider, references.sorted(),
            model = model.takeIf { it.isNotBlank() }, reasoningEffort = effort.takeIf { it.isNotBlank() },
            apiKey = apiKey.takeIf { provider == "openai" && it.isNotBlank() },
            sessionId = session?.id, expectedVersion = session?.version, sourceNoteId = sourceNoteId,
        )
        val input = retry?.takeIf { it.copy(clientRequestId = "") == candidate }
            ?: candidate.copy(clientRequestId = UUID.randomUUID().toString())
        retry = input
        sending = true
        resetLive()
        try {
            val done = api.chat(input) { event -> withContext(Dispatchers.Main.immediate) { apply(event) } }
            session = done.session
            if (draftState == message) draftState = ""
            references = emptySet()
            retry = null
            resetLive()
        } finally {
            sending = false
        }
    }

    internal fun apply(event: SseEvent) {
        when (event) {
            is SseEvent.Status -> status = event.message
            is SseEvent.Step -> steps[event.step.id] = event.step
            is SseEvent.Citations -> citations = event.citations
            is SseEvent.Reasoning -> reasoning += event.text
            is SseEvent.Delta -> delta += event.text
        }
    }
}
