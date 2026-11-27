package xyz.weiji.notes.state

import androidx.compose.runtime.*
import xyz.weiji.notes.core.network.WeijiApiClient
import xyz.weiji.notes.model.Note
import xyz.weiji.notes.model.RelatedNotesResponse

class WalkState {
    var result by mutableStateOf<RelatedNotesResponse?>(null)
        private set

    suspend fun open(api: WeijiApiClient, notes: List<Note>, noteId: String? = null) {
        val focus = noteId ?: notes.filterNot { it.id == result?.focus?.id }.randomOrNull()?.id
            ?: notes.firstOrNull()?.id ?: return
        result = api.related(focus)
    }
}
