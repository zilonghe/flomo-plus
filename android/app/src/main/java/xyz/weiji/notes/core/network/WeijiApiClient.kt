package xyz.weiji.notes.core.network

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.Serializable
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import xyz.weiji.notes.model.*

open class ApiException(val status: Int, message: String) : IOException(message)
class NoteConflict(val conflict: NoteConflictResponse) : ApiException(409, conflict.error)

data class NotesSnapshot(val payload: NotesSnapshotResponse, val etag: String?)

class WeijiApiClient(
    val origin: String,
    private val token: String? = null,
    private val userId: String? = null,
    private val onAuthInvalid: suspend () -> Unit = {},
) {
    companion object {
        private val http = OkHttpClient.Builder()
            .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
            .connectTimeout(10, TimeUnit.SECONDS).readTimeout(90, TimeUnit.SECONDS).build()
        private val jsonType = "application/json".toMediaType()
    }

    @Serializable private data class ErrorBody(val error: String)
    @Serializable private data class Logout(val ok: Boolean)

    private fun endpoint(vararg segments: String): HttpUrl.Builder = origin.toHttpUrl().newBuilder().apply {
        addPathSegment("api")
        segments.forEach { addPathSegment(it) }
    }

    private suspend fun <T> request(
        url: HttpUrl.Builder, method: String = "GET", body: String? = null, etag: String? = null,
        stream: Boolean = false, acceptNotModified: Boolean = false, noteConflict: Boolean = false,
        decode: suspend (Response) -> T,
    ): T {
        val request = Request.Builder().url(url.build()).apply {
            header("Accept", if (stream) "text/event-stream" else "application/json")
            if (stream) header("Accept-Encoding", "identity")
            if (!token.isNullOrBlank()) header("Authorization", "Bearer $token")
            userId?.let { header("X-Journal-Account", it) }
            etag?.let { header("If-None-Match", it) }
            if (method != "GET") header("Origin", origin)
            method(method, (body ?: if (method == "POST") "" else null)?.toRequestBody(if (body != null) jsonType else null))
        }.build()
        val call = http.newCall(request)
        try {
            return coroutineScope {
                val cancelCall = launch(start = CoroutineStart.UNDISPATCHED) {
                    try { awaitCancellation() } finally { call.cancel() }
                }
                try {
                    withContext(Dispatchers.IO) {
                        call.execute().use { response ->
                            when {
                                response.isSuccessful || (acceptNotModified && response.code == 304) -> decode(response)
                                noteConflict && response.code == 409 -> throw NoteConflict(response.json())
                                else -> {
                                    val message = runCatching { response.json<ErrorBody>().error }
                                        .getOrDefault("服务器请求失败（${response.code}）。")
                                    throw ApiException(response.code, message)
                                }
                            }
                        }
                    }
                } finally {
                    cancelCall.cancel()
                }
            }
        } catch (error: ApiException) {
            if (error.status == 401 || error.status == 403) onAuthInvalid()
            throw error
        }
    }

    private inline fun <reified T> Response.json(): T = wireJson.decodeFromString(body?.string() ?: throw IOException("服务器没有返回数据。"))
    private suspend inline fun <reified T> get(url: HttpUrl.Builder) = request(url) { it.json<T>() }
    private suspend inline fun <reified T> post(url: HttpUrl.Builder, body: String? = null) =
        request(url, "POST", body) { it.json<T>() }

    suspend fun providers() = get<AuthProvidersResponse>(endpoint("auth", "providers"))
    suspend fun exchange(code: String, verifier: String, label: String) =
        post<AuthExchangeResponse>(endpoint("auth", "exchange"), wireJson.encodeToString(AuthExchangeRequest(code, verifier, label)))
    suspend fun logout(): Boolean = post<Logout>(endpoint("auth", "logout")).ok
    suspend fun session() = get<SessionInfo>(endpoint("session"))

    suspend fun notes(etag: String?): NotesSnapshot? =
        request(endpoint("notes"), etag = etag, acceptNotModified = true) {
            if (it.code == 304) null else NotesSnapshot(it.json(), it.header("ETag"))
        }
    suspend fun write(mutation: NoteMutation): NoteConflictCurrent =
        request(endpoint("notes"), "POST", wireJson.encodeToString(mutation), noteConflict = true) { it.json() }

    suspend fun related(id: String) =
        get<RelatedNotesResponse>(endpoint("notes", id, "related").addQueryParameter("limit", "10"))

    suspend fun models() = get<AiModelsResponse>(endpoint("ai", "models"))
    suspend fun sourceSession(id: String) =
        get<AiSessionEnvelope>(endpoint("ai", "sessions").addQueryParameter("sourceNoteId", id)).session
    suspend fun sessions(cursor: String? = null) =
        get<AiSessionListResponse>(endpoint("ai", "sessions").addQueryParameter("limit", "50").apply {
            cursor?.let { addQueryParameter("cursor", it) }
        })
    suspend fun aiSession(id: String) = requireNotNull(get<AiSessionEnvelope>(endpoint("ai", "sessions", id)).session)
    suspend fun deleteSession(id: String): AiDeletedSessionResponse =
        request(endpoint("ai", "sessions", id), "DELETE") { it.json() }
    suspend fun chat(input: AiChatRequest, onEvent: suspend (SseEvent) -> Unit): AiDone = request(
        endpoint("ai", "chat"), "POST", wireJson.encodeToString(input), stream = true,
    ) { response ->
        val body = response.body ?: throw IOException("服务器没有返回对话。")
        SseParser.read(body.source().inputStream().bufferedReader(Charsets.UTF_8), onEvent)
    }

    suspend fun semanticStatus() = get<SemanticStatus>(endpoint("semantic", "status"))
    suspend fun reindex() = post<SemanticStatus>(endpoint("semantic", "reindex"))

    suspend fun obsidianStatus(session: SessionInfo): ObsidianStatus? =
        if (session.user.role == "admin") get<ObsidianStatus>(endpoint("admin", "obsidian", "status")) else null
    suspend fun syncObsidian(session: SessionInfo, status: ObsidianStatus) =
        if (session.user.role == "admin" && status.configured) post<ObsidianSyncResponse>(endpoint("admin", "obsidian", "sync"))
        else null
}
