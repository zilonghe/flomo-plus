package xyz.weiji.notes.model

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

val wireJson = Json { ignoreUnknownKeys = true }

@Serializable data class User(val id: String, val name: String, val email: String? = null, val role: String? = null)
@Serializable data class AuthProvider(val id: String, val name: String)
@Serializable data class AuthProvidersResponse(
    val authMode: String, val inviteRequired: Boolean = false, val publicOrigin: String? = null,
    val providers: List<AuthProvider> = emptyList(),
)
@Serializable data class AuthExchangeRequest(val code: String, val codeVerifier: String, val deviceLabel: String)
@Serializable data class AuthExchangeResponse(val token: String, val sessionId: String, val expiresAt: String, val user: User)
@Serializable data class SessionInfo(
    val user: User, val codexAvailable: Boolean = false, val codexMode: String? = null, val authMode: String? = null,
)

@Serializable data class Reading(
    val bookTitle: String? = null, val author: String? = null, val chapter: String? = null,
    val sourceDate: String? = null, val fingerprint: String? = null,
)
@Serializable data class Note(
    val id: String, val body: String, val createdAt: String, val revision: Int,
    val reading: Reading? = null, val turns: List<AiTurn> = emptyList(),
) {
    fun payload(body: String) = NotePayload(id, body, createdAt, reading, turns)
}
@Serializable data class NotePayload(
    val id: String, val body: String, val createdAt: String, val reading: Reading? = null,
    val turns: List<AiTurn> = emptyList(),
)
@Serializable data class NoteMutation(
    val id: String, val expectedRevision: Int, val note: NotePayload? = null, val delete: Boolean = false,
)
@Serializable data class Tombstone(val id: String, val revision: Int)
@Serializable data class NotesSnapshotResponse(val notes: List<Note>, val deleted: List<Tombstone>)
@Serializable data class NoteConflictResponse(val error: String, val current: NoteConflictCurrent? = null)
@Serializable data class NoteConflictCurrent(val note: Note? = null, val deleted: Tombstone? = null)

@Serializable data class RelatedNoteSummary(
    val id: String, val body: String, val createdAt: String, val reading: Reading? = null,
)
@Serializable data class RelatedNote(
    val id: String, val score: Double, val relevancePercent: Int, val sharedTags: List<String>, val note: RelatedNoteSummary,
)
@Serializable data class RelatedNotesResponse(
    val focus: RelatedNoteSummary, val mode: String, val indexed: Int, val total: Int, val related: List<RelatedNote>,
)

@Serializable data class ModelMeta(
    val id: String, val label: String, val vendor: String, val thinking: Boolean, val efforts: List<String> = emptyList(),
    val fixedEffort: String? = null, val defaultEffort: String? = null,
)
@Serializable data class AiModelsResponse(
    val available: Boolean, val models: List<String>, val defaultModel: String? = null,
    val source: String, val modelMeta: List<ModelMeta>? = null,
)
@Serializable data class AiSessionSummary(
    val id: String, val title: String, val version: Int, val createdAt: String,
    val updatedAt: String, val origin: String, val sourceNoteId: String? = null,
)
@Serializable data class AiSession(
    val id: String, val title: String, val version: Int, val createdAt: String,
    val updatedAt: String, val origin: String, val turns: List<AiTurn>, val sourceNoteId: String? = null,
)
@Serializable data class AiSessionEnvelope(val session: AiSession?)
@Serializable data class AiSessionListResponse(
    val sessions: List<AiSessionSummary>, val hasMore: Boolean, val nextCursor: String? = null,
    val upgradedNoteIds: List<String>? = null,
)
@Serializable data class AiDeletedSessionResponse(val deleted: String)
@OptIn(ExperimentalSerializationApi::class)
@Serializable data class AiChatRequest(
    val message: String, val clientRequestId: String, val provider: String,
    val referencedNoteIds: List<String>, val model: String? = null, val reasoningEffort: String? = null,
    val apiKey: String? = null, val sessionId: String? = null, val expectedVersion: Int? = null,
    val sourceNoteId: String? = null,
) {
    @EncodeDefault val stream: Boolean = true
}
@Serializable data class AiTurn(
    val role: String, val text: String, val citations: List<AiCitation>? = null, val steps: List<AiStep>? = null,
)
@Serializable data class AiCitation(
    val ref: String, val noteId: String, val excerpt: String, val createdAt: String? = null, val bookTitle: String? = null,
)
@Serializable data class AiStep(
    val id: String, val kind: String, val label: String, val status: String? = null,
    val detail: String? = null, val durationMs: Int? = null, val items: List<AiStepItem>? = null,
)
@Serializable data class AiStepItem(val ref: String, val noteId: String, val title: String, val excerpt: String)
@Serializable data class AiDone(
    val session: AiSession, val reply: String, val citations: List<AiCitation>, val deduplicated: Boolean = false,
)
@Serializable data class SemanticStatus(
    val provider: String, val indexed: Int, val total: Int, val pending: Int, val indexing: Boolean, val ftsReady: Boolean,
    val model: String? = null, val lastError: String? = null,
)
@Serializable data class ObsidianStatus(
    val configured: Boolean, val running: Boolean = false, val intervalMs: Long? = null,
    val prefixes: List<String>? = null, val lastRun: ObsidianRun? = null,
)
@Serializable data class ObsidianRun(
    val at: String, val trigger: String, val ok: Boolean, val error: String? = null,
    val indexWarning: String? = null, val stats: ObsidianStats? = null,
)
@Serializable data class ObsidianStats(
    val scanned: Int, val fetched: Int, val created: Int, val updated: Int,
    val skipped: Int, val excluded: Int, val conflicts: Int,
)
@Serializable data class ObsidianSyncResponse(val ok: Boolean, val stats: ObsidianStats, val status: ObsidianStatus)
