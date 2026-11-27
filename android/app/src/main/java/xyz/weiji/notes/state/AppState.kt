package xyz.weiji.notes.state

import androidx.compose.runtime.*
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import xyz.weiji.notes.core.auth.DEFAULT_ORIGIN
import xyz.weiji.notes.core.auth.OAuthPkce
import xyz.weiji.notes.core.network.ApiException
import xyz.weiji.notes.core.network.NoteConflict
import xyz.weiji.notes.core.network.WeijiApiClient
import xyz.weiji.notes.core.storage.CredentialStore
import xyz.weiji.notes.core.storage.Credentials
import xyz.weiji.notes.core.storage.NoteCache
import xyz.weiji.notes.model.*

enum class Tab(val label: String) { Notes("笔记"), Walk("漫步"), Ai("AI") }

data class NoteDraft(val note: Note, val body: String, val sessionId: Long)
class AppState(private val store: CredentialStore, private val cache: NoteCache) : ViewModel() {
    var address by mutableStateOf(store.credentials?.origin ?: store.origin ?: DEFAULT_ORIGIN)
    var theme by mutableStateOf(store.theme)
        private set
    var colorMode by mutableStateOf(store.colorMode)
        private set
    var providers by mutableStateOf<AuthProvidersResponse?>(null)
        private set
    private var discoveredOrigin: String? = null
    var authBusy by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    var session by mutableStateOf<SessionInfo?>(null)
        private set
    var notes by mutableStateOf(listOf<Note>())
        private set
    var noteBusy by mutableStateOf(false)
        private set
    var notesLoaded by mutableStateOf(false)
        private set
    var notesQuery by mutableStateOf("")
    var selectedTag by mutableStateOf<String?>(null)
    var tab by mutableStateOf(Tab.Notes)
    var settings by mutableStateOf(false)
    var reader by mutableStateOf<Note?>(null)
        private set
    var editor by mutableStateOf<NoteDraft?>(null)
        private set
    var conflict by mutableStateOf<NoteConflictResponse?>(null)
        private set
    var semantic by mutableStateOf<SemanticStatus?>(null)
        private set
    var obsidian by mutableStateOf<ObsidianStatus?>(null)
        private set
    var settingsBusy by mutableStateOf(false)
        private set
    var walkBusy by mutableStateOf(false)
        private set
    var walk by mutableStateOf(WalkState())
        private set
    var ai by mutableStateOf<AiChatState?>(null)
        private set

    private var api: WeijiApiClient? = null
    private var credentials: Credentials? = null
    private var connectionGeneration = 0L
    private var editorSessionId = 0L
    private var share: String? = null
    private var logoutInProgress = false

    init { store.credentials?.let { connect(it, validate = true) } }

    fun selectTheme(value: String) { store.theme = value; theme = value }
    fun selectColorMode(value: String) { store.colorMode = value; colorMode = value }

    private fun show(error: Exception) {
        this.error = error.localizedMessage ?: "操作失败，请重试。"
    }

    fun work(action: suspend () -> Unit): Job = viewModelScope.launch {
        error = null
        try { action() } catch (cancelled: CancellationException) { throw cancelled } catch (failure: Exception) { show(failure) }
    }

    fun dismissError() { error = null }

    suspend fun discover(input: String) {
        providers = null
        discoveredOrigin = null
        try {
            val origin = OAuthPkce.normalizeOrigin(input)
            val config = try { WeijiApiClient(origin).providers() } catch (e: ApiException) {
                if (e.status !in setOf(401, 404, 405)) throw e
                AuthProvidersResponse("legacy")
            }
            OAuthPkce.verifyOrigin(origin, config)
            if (address == input) {
                discoveredOrigin = origin
                providers = config
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            if (address == input) show(failure)
        }
    }

    fun startOAuth(provider: String, open: (String) -> Unit) = work {
        val origin = OAuthPkce.normalizeOrigin(address)
        val config = providers
        require(discoveredOrigin == origin && config?.authMode == "oauth" && config.providers.any { it.id == provider }) {
            "登录方式已变化，请重新加载。"
        }
        OAuthPkce.verifyOrigin(origin, config)
        val pending = OAuthPkce.pending(origin)
        store.pending = pending
        store.origin = origin
        open(OAuthPkce.startUrl(provider, pending))
    }

    fun finishOAuth(callback: String, label: String) = authenticate {
        val pending = store.pending
        val code = try {
            OAuthPkce.callbackCode(callback, pending)
        } catch (e: ApiException) {
            store.pending = null
            throw e
        }
        checkNotNull(pending)
        // Consume once before the network call, so a replay cannot replace the current session.
        store.pending = null
        val result = WeijiApiClient(pending.origin).exchange(code, pending.verifier, label)
        val session = try {
            WeijiApiClient(pending.origin, result.token, result.user.id).session()
        } catch (e: java.io.IOException) {
            if (e is ApiException && e.status in setOf(401, 403)) throw e
            SessionInfo(result.user, authMode = "oauth")
        }
        Credentials(pending.origin, result.token, session)
    }

    fun manualLogin(token: String) = authenticate {
        val origin = OAuthPkce.normalizeOrigin(address)
        val secret = token.trim()
        require(secret.isNotEmpty()) { "请输入访问令牌。" }
        val session = WeijiApiClient(origin, secret).session()
        store.pending = null
        Credentials(origin, secret, session)
    }

    private fun authenticate(action: suspend () -> Credentials) = work {
        if (authBusy || credentials != null) return@work
        authBusy = true
        try {
            val account = action()
            store.credentials = account
            store.origin = account.origin
            address = account.origin
            connect(account, validate = false)
        } finally {
            authBusy = false
        }
    }

    private fun connect(account: Credentials, validate: Boolean) {
        connectionGeneration++
        credentials = account
        val client = WeijiApiClient(account.origin, account.token, account.session.user.id) { invalidate(account) }
        api = client
        setSession(client, account.session)
        share?.let { beginNote(it); share = null }
        noteBusy = true
        work {
            try {
                val cached = cache.loadSnapshot(account.origin, account.session.user.id)
                if (api !== client) return@work
                notes = cached.notes
                notesLoaded = true
                if (validate) {
                    setSession(client, client.session(), persist = true)
                }
                refresh(client)
            } finally { if (api === client) noteBusy = false }
        }
    }

    private fun setSession(client: WeijiApiClient, info: SessionInfo, persist: Boolean = false) {
        if (api !== client) return
        session = info
        val provider = if (info.codexAvailable) "codex" else "openai"
        if (ai?.provider != provider) ai = AiChatState(client, provider)
        if (persist) store.credentials = credentials?.copy(session = info)
    }

    private suspend fun invalidate(account: Credentials) {
        if (credentials !== account) return
        connectionGeneration++
        credentials = null
        api = null
        session = null
        notes = emptyList()
        notesLoaded = false
        notesQuery = ""
        selectedTag = null
        noteBusy = false
        editor = null
        conflict = null
        reader = null
        ai = null
        walk = WalkState()
        walkBusy = false
        semantic = null
        obsidian = null
        settings = false
        settingsBusy = false
        tab = Tab.Notes
        share = null
        store.credentials = null
        store.pending = null
        cache.clearAccount(account.origin, account.session.user.id)
    }

    fun logout() = work {
        val client = api ?: return@work
        val account = credentials ?: return@work
        if (logoutInProgress) return@work
        logoutInProgress = true
        connectionGeneration++
        try {
            if (session?.authMode == "oauth") client.logout()
        } finally {
            invalidate(account)
            logoutInProgress = false
        }
    }

    private suspend fun refresh(client: WeijiApiClient) {
        val account = credentials ?: return
        val (origin, _, info) = account
        val user = info.user.id
        val cached = cache.loadSnapshot(origin, user)
        if (client !== api) return
        val snapshot = client.notes(cached.etag) ?: return
        if (client !== api) return
        val deleted = snapshot.payload.deleted.mapTo(hashSetOf()) { it.id }
        val replacement = snapshot.payload.notes.filterNot { it.id in deleted }
        cache.replaceSnapshot(origin, user, replacement, snapshot.etag)
        if (client === api) {
            notes = replacement.sortedByDescending { it.createdAt }
            notesLoaded = true
        }
    }

    fun syncNotes() = noteWork(::refresh)

    private fun noteWork(action: suspend (WeijiApiClient) -> Unit) = work {
        val client = api ?: return@work
        if (noteBusy) return@work
        noteBusy = true
        try { action(client) } finally { if (client === api) noteBusy = false }
    }

    fun receiveShare(text: String) {
        if (text.isBlank()) return
        if (session == null || editor != null) share = text else beginNote(text)
    }

    fun beginNote(text: String = "") {
        conflict = null
        editor = NoteDraft(Note(UUID.randomUUID().toString(), "", Instant.now().toString(), 0), text, ++editorSessionId)
    }

    fun openNote(id: String) {
        val note = notes.firstOrNull { it.id.equals(id, ignoreCase = true) } ?: return
        reader = note
    }

    fun closeReader() { reader = null }
    fun edit(note: Note) { conflict = null; editor = NoteDraft(note, note.body, ++editorSessionId) }
    fun changeDraft(body: String) { editor = editor?.copy(body = body) }
    fun closeEditor() {
        editor = null
        conflict = null
        share?.let { beginNote(it); share = null }
    }

    fun save() = noteWork { client ->
        val draft = editor ?: return@noteWork
        if (draft.body.isBlank()) return@noteWork
        val note = draft.note
        mutate(client, NoteMutation(note.id, note.revision, note.payload(draft.body)), draft)
    }

    fun delete(note: Note) = noteWork { client ->
        mutate(client, NoteMutation(note.id, note.revision, delete = true))
    }

    fun acceptCloudRevision() {
        val updated = conflict?.current?.note
        if (updated != null) {
            editor = editor?.copy(note = updated)
            reader = reader?.takeUnless { it.id == updated.id } ?: updated
            conflict = null
        }
    }

    private suspend fun mutate(client: WeijiApiClient, mutation: NoteMutation, draft: NoteDraft? = null) {
        val account = credentials ?: return
        val result = try { client.write(mutation) } catch (error: NoteConflict) {
            val current = editor
            val matches = if (draft != null) current?.sessionId == draft.sessionId
                else (current?.note ?: reader)?.id == mutation.id
            if (api === client && matches) conflict = error.conflict
            throw error
        }
        if (api !== client) return
        val note = result.note
        val deleted = result.deleted
        check(note != null || deleted != null) { "服务器未确认笔记变更。" }
        cache.applyMutation(account.origin, account.session.user.id, note, deleted?.id)
        if (api !== client) return
        notes = (notes.filterNot { it.id == mutation.id } + listOfNotNull(note)).sortedByDescending { it.createdAt }
        if (reader?.id == mutation.id) reader = note
        val current = editor
        when {
            mutation.delete && deleted != null && current?.note?.id == deleted.id -> closeEditor()
            draft != null && current === draft -> closeEditor()
            note != null && current != null && current.sessionId == draft?.sessionId -> editor = current.copy(note = note)
        }
    }

    fun openSettings(): Job {
        settings = true
        return settingsWork { client, isCurrent ->
            val info = client.session()
            if (!isCurrent()) return@settingsWork
            setSession(client, info, persist = true)
            obsidian = null
            val index = client.semanticStatus()
            if (!isCurrent()) return@settingsWork
            semantic = index
            val status = client.obsidianStatus(info)
            if (isCurrent()) obsidian = status
        }
    }

    fun reindex() = settingsWork { client, isCurrent ->
        val status = client.reindex()
        if (isCurrent()) semantic = status
    }
    fun syncObsidian() = settingsWork { client, isCurrent ->
        val info = session ?: return@settingsWork
        val status = obsidian ?: return@settingsWork
        val result = client.syncObsidian(info, status)
        if (isCurrent() && result != null) obsidian = result.status
    }

    private fun settingsWork(action: suspend (WeijiApiClient, () -> Boolean) -> Unit) = work {
        val client = api ?: return@work
        if (settingsBusy || logoutInProgress) return@work
        val generation = connectionGeneration
        val isCurrent = { api === client && connectionGeneration == generation }
        settingsBusy = true
        try {
            action(client, isCurrent)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            if (isCurrent()) throw failure
        } finally {
            if (isCurrent()) settingsBusy = false
        }
    }

    fun openWalk(noteId: String? = null) {
        reader = null
        tab = Tab.Walk
        work {
            val client = api ?: return@work
            if (walkBusy) return@work
            walkBusy = true
            try { walk.open(client, notes, noteId) } finally { if (api === client) walkBusy = false }
        }
    }

    fun openAi(noteId: String) = work {
        val chat = ai ?: return@work
        if (!chat.openSource(noteId) || chat !== ai) return@work
        reader = null
        tab = Tab.Ai
    }

    fun back(): Boolean = when {
        editor != null && !noteBusy -> true.also { closeEditor() }
        reader != null -> true.also { closeReader() }
        settings -> true.also { settings = false }
        tab != Tab.Notes -> true.also { tab = Tab.Notes }
        else -> false
    }
}
