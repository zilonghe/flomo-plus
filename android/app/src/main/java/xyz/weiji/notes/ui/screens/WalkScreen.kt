package xyz.weiji.notes.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import xyz.weiji.notes.state.AppState
import xyz.weiji.notes.ui.components.WeijiPrimaryButton

@Composable fun WalkScreen(state: AppState) {
    val walk = state.walk.result
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp),
        contentPadding = PaddingValues(vertical = 12.dp)) {
        item {
            WeijiPrimaryButton(if (walk == null) "开始漫步" else "换一条", { state.openWalk() },
                enabled = state.notes.isNotEmpty() && !state.walkBusy)
        }
        if (state.walkBusy) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        if (state.notes.isEmpty() && !state.noteBusy) item { Text("写下第一条笔记后开始漫步。") }
        if (walk != null) {
            item {
                NoteCard(walk.focus.body, walk.focus.reading?.bookTitle ?: walk.focus.createdAt.take(10)) { state.openNote(walk.focus.id) }
            }
            item { Text("相关笔记", style = MaterialTheme.typography.titleMedium) }
            if (walk.related.isEmpty()) item { Text("暂无相关笔记") }
            items(walk.related, key = { it.id }) { related ->
                NoteCard(related.note.body, buildString {
                    append("${related.relevancePercent}%")
                    if (related.sharedTags.isNotEmpty()) append(" · " + related.sharedTags.joinToString(" ") { "#$it" })
                }) { state.openNote(related.id) }
            }
        }
    }
}
