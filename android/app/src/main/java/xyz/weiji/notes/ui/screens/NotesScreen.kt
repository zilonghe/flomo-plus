package xyz.weiji.notes.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import xyz.weiji.notes.core.text.TagParser
import xyz.weiji.notes.model.Note
import xyz.weiji.notes.state.AppState
import xyz.weiji.notes.ui.components.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun NotesScreen(state: AppState) {
    var drawer by rememberSaveable { mutableStateOf(false) }
    val notes = state.notes
    val counts = remember(notes) { TagParser.counts(notes.map { it.body }) }
    val query = state.notesQuery.trim()
    val selected = state.selectedTag
    val shown = remember(notes, query, selected) {
        notes.filter { note ->
            (query.isEmpty() || note.body.contains(query, ignoreCase = true) || note.reading?.bookTitle?.contains(query, ignoreCase = true) == true) &&
                (selected == null || TagParser.tags(note.body).any { it == selected || it.startsWith("$selected/") })
        }
    }
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(state.notesQuery, { state.notesQuery = it }, Modifier.weight(1f),
                label = { Text("搜索笔记") }, singleLine = true)
            IconButton({ state.syncNotes() }, Modifier.size(48.dp), enabled = !state.noteBusy) {
                Icon(Icons.Outlined.Refresh, "同步笔记")
            }
            IconButton({ state.beginNote() }, Modifier.size(48.dp)) { Icon(Icons.Outlined.Add, "新笔记") }
        }
        Action(selected?.let { "#$it" } ?: "标签", { drawer = true })
        if (state.noteBusy) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (shown.isEmpty() && state.notesLoaded && !state.noteBusy) Text(
            if (notes.isEmpty()) "还没有笔记" else "没有匹配的笔记", Modifier.padding(vertical = 16.dp),
        )
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(bottom = 12.dp)) {
            items(shown, key = { it.id }) { note ->
                NoteCard(note.body, note.reading?.bookTitle ?: note.createdAt.take(10)) { state.openNote(note.id) }
            }
        }
    }
    if (drawer) ModalBottomSheet(onDismissRequest = { drawer = false }, containerColor = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
            Action("全部笔记", { state.selectedTag = null; drawer = false })
            for (node in TagParser.tree(counts)) TagBranch(node, 0) { state.selectedTag = it; drawer = false }
        }
    }
}

@Composable private fun TagBranch(node: TagParser.Node, depth: Int, onTag: (String) -> Unit) {
    var expanded by rememberSaveable(node.path) { mutableStateOf(true) }
    Row(Modifier.padding(start = (depth.coerceAtMost(3) * 16).dp), verticalAlignment = Alignment.CenterVertically) {
        Action("${node.name} · ${node.count}", { onTag(node.path) }, Modifier.weight(1f))
        if (node.children.isNotEmpty()) Action(if (expanded) "收起" else "展开", { expanded = !expanded })
    }
    if (expanded) for (child in node.children) TagBranch(child, depth + 1, onTag)
}

@Composable fun NoteCard(body: String, detail: String, click: () -> Unit) {
    Card(onClick = click, Modifier.fillMaxWidth().heightIn(min = 48.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(body, maxLines = 5, overflow = TextOverflow.Ellipsis)
            Text(detail, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable fun NoteReader(state: AppState) {
    val note = state.reader ?: return
    var confirmation by rememberSaveable(note.id) { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Action("返回", state::closeReader)
            Spacer(Modifier.weight(1f))
            Action("编辑", { state.edit(note) }, enabled = !state.noteBusy)
        }
        if (state.editor == null) ConflictText(state, note)
        Surface(shape = MaterialTheme.shapes.large, modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(note.createdAt.take(10), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                note.reading?.bookTitle?.let { Text(it, style = MaterialTheme.typography.titleMedium) }
                MarkdownContent(note.body, onCitation = state::openNote)
            }
        }
        WrapActions {
            Action("以此漫步", { state.openWalk(note.id) })
            Action("与 AI 对话", { state.openAi(note.id) })
            Action("删除", { confirmation = true }, enabled = !state.noteBusy)
        }
    }
    if (confirmation) AlertDialog(
        onDismissRequest = { confirmation = false },
        title = { Text("删除这条笔记？") },
        confirmButton = { Action("删除", { confirmation = false; state.delete(note) }) },
        dismissButton = { Action("取消", { confirmation = false }) },
    )
}

@Composable fun NoteEditor(state: AppState) {
    val editor = state.editor ?: return
    var value by rememberSaveable(editor.note.id, stateSaver = TextFieldValue.Saver) {
        mutableStateOf(TextFieldValue(editor.body, TextRange(editor.body.length)))
    }
    val notes = state.notes
    val counts = remember(notes) { TagParser.counts(notes.map { it.body }) }
    val query = if (value.selection.collapsed) TagParser.query(value.text, value.selection.end) else null
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Action("取消", state::closeEditor, enabled = !state.noteBusy)
            Spacer(Modifier.weight(1f))
            WeijiPrimaryButton("保存", { state.save() }, enabled = value.text.isNotBlank() && !state.noteBusy)
        }
        ConflictText(state, editor.note)
        OutlinedTextField(value, { value = it; state.changeDraft(it.text) }, Modifier.fillMaxWidth(),
            label = { Text("笔记内容") }, minLines = 8, enabled = !state.noteBusy)
        if (query != null) WrapActions {
            for (tag in TagParser.suggest(query.text, counts)) {
                Action("#$tag", {
                    val replacement = "#$tag" + if (value.text.getOrNull(query.end)?.isWhitespace() == true) "" else " "
                    val updated = value.text.replaceRange(query.start, query.end, replacement)
                    value = TextFieldValue(updated, TextRange(query.start + replacement.length))
                    state.changeDraft(updated)
                })
            }
        }
    }
}

@Composable private fun ConflictText(state: AppState, note: Note) {
    val conflict = state.conflict ?: return
    val current = conflict.current
    if (current?.note != null && current.note.id == note.id) {
        Text("云端有新版本：")
        Text(current.note.body, maxLines = 5, overflow = TextOverflow.Ellipsis)
        if (state.editor != null) Action("以云端版本为基准重试", state::acceptCloudRevision)
    } else Text(if (current?.deleted != null) "笔记已在云端删除。" else "云端找不到这条笔记。")
    if (state.editor != null && current?.note == null) Action("另存为新笔记", { state.beginNote(state.editor?.body.orEmpty()) })
}

@OptIn(ExperimentalLayoutApi::class)
@Composable fun WrapActions(content: @Composable () -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) { content() }
}
