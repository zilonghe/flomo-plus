package xyz.weiji.notes.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import xyz.weiji.notes.model.AiStep
import xyz.weiji.notes.state.AiChatState
import xyz.weiji.notes.state.AppState
import xyz.weiji.notes.ui.components.Action
import xyz.weiji.notes.ui.components.MarkdownContent
import xyz.weiji.notes.ui.components.WeijiPrimaryButton

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun AiChatScreen(app: AppState, chat: AiChatState) {
    var panel by rememberSaveable { mutableStateOf<String?>(null) }
    var confirmDelete by rememberSaveable { mutableStateOf<String?>(null) }
    val turns = chat.session?.turns.orEmpty()
    val scroll = rememberLazyListState()
    val live = chat.sending || chat.delta.isNotEmpty() || chat.steps.isNotEmpty() || chat.reasoning.isNotEmpty()
    val stepCards = chat.steps.values.sortedBy { it.id }

    LaunchedEffect(chat) { app.work { chat.loadModels() } }
    LaunchedEffect(turns.size, live) {
        val last = turns.lastIndex + if (live) 1 else 0
        if (last >= 0) scroll.scrollToItem(last)
    }
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        WrapActions {
            Action("新对话", chat::startNew, enabled = !chat.sending)
            Action("会话", { panel = "history"; app.work { chat.list() } }, enabled = !chat.sending)
            Action("模型", { panel = "models" }, enabled = !chat.sending)
        }
        chat.sourceNoteId?.let { id -> Action("来源笔记", { app.openNote(id) }) }
        LazyColumn(
            Modifier.weight(1f).fillMaxWidth(), state = scroll,
            verticalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(vertical = 8.dp),
        ) {
            items(turns) { turn ->
                Surface(shape = MaterialTheme.shapes.large, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (step in turn.steps.orEmpty()) StepCard(step, app::openNote)
                        MarkdownContent(turn.text, turn.citations.orEmpty(), app::openNote)
                    }
                }
            }
            if (live) item {
                Surface(shape = MaterialTheme.shapes.large, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        chat.status?.takeIf { chat.sending }?.let { Text(it, style = MaterialTheme.typography.labelLarge) }
                        for (step in stepCards) StepCard(step, app::openNote)
                        if (chat.reasoning.isNotEmpty()) Reasoning(chat.reasoning)
                        MarkdownContent(chat.delta, chat.citations, app::openNote)
                    }
                }
            }
        }
        OutlinedTextField(chat.draft, { chat.draft = it }, Modifier.fillMaxWidth(), label = { Text("消息") },
            maxLines = 4, enabled = !chat.sending)
        Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            Action(if (chat.references.isEmpty()) "引用笔记" else "引用笔记 · ${chat.references.size}",
                { panel = "references" }, enabled = !chat.sending)
            WeijiPrimaryButton(if (chat.sending) "发送中" else "发送", { app.work { chat.send() } },
                enabled = chat.draft.isNotBlank() && !chat.sending)
        }
    }

    if (panel != null) ModalBottomSheet(onDismissRequest = { panel = null }, containerColor = MaterialTheme.colorScheme.surface) {
        LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 16.dp), contentPadding = PaddingValues(bottom = 16.dp)) {
            when (panel) {
                "history" -> {
                    if (chat.history.isEmpty()) item { Text("暂无会话") }
                    items(chat.history, key = { it.id }) { summary ->
                        Row {
                            Action(summary.title, {
                                app.work { if (chat.open(summary.id) && panel == "history") panel = null }
                            }, Modifier.weight(1f))
                            Action("删除", { confirmDelete = summary.id })
                        }
                    }
                    if (chat.nextCursor != null) item { Action("加载更多", { app.work { chat.list(more = true) } }) }
                }
                "models" -> {
                    if (chat.provider == "openai") item {
                        OutlinedTextField(chat.apiKey, { chat.apiKey = it }, Modifier.fillMaxWidth(), label = { Text("API Key") },
                            singleLine = true, visualTransformation = PasswordVisualTransformation(),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                    }
                    if (chat.models?.models.orEmpty().isEmpty()) item {
                        OutlinedTextField(chat.model, chat::selectModel, Modifier.fillMaxWidth(), label = { Text("模型") }, singleLine = true)
                    } else item {
                        WrapActions {
                            val metadata = chat.models?.modelMeta.orEmpty().associateBy { it.id }
                            for (id in chat.models?.models.orEmpty()) {
                                FilterChip(id == chat.model, { chat.selectModel(id) }, { Text(metadata[id]?.label ?: id) },
                                    Modifier.heightIn(min = 48.dp))
                            }
                        }
                    }
                    val model = chat.models?.modelMeta.orEmpty().find { it.id == chat.model }
                    if (model?.thinking == true && model.fixedEffort == null && model.efforts.isNotEmpty()) item {
                        Text("思考档位", style = MaterialTheme.typography.titleSmall)
                        WrapActions {
                            for (effort in model.efforts) FilterChip(
                                chat.effort == effort, { chat.effort = effort }, { Text(effort) }, Modifier.heightIn(min = 48.dp),
                            )
                        }
                    }
                }
                "references" -> {
                    if (app.notes.isEmpty()) item { Text("暂无可引用的笔记") }
                    items(app.notes, key = { it.id }) { note ->
                        val checked = note.id in chat.references
                        FilterChip(checked, {
                            chat.references = if (checked) chat.references - note.id else chat.references + note.id
                        }, { Text(note.body.take(120), maxLines = 2, overflow = TextOverflow.Ellipsis) },
                            Modifier.fillMaxWidth().heightIn(min = 48.dp), enabled = checked || chat.references.size < 10)
                    }
                }
            }
        }
    }
    confirmDelete?.let { id ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null }, title = { Text("删除这段对话？") },
            confirmButton = { Action("删除", { confirmDelete = null; app.work { chat.delete(id) } }) },
            dismissButton = { Action("取消", { confirmDelete = null }) },
        )
    }
}

@Composable private fun StepCard(step: AiStep, openNote: (String) -> Unit) {
    var expanded by rememberSaveable(step.id) { mutableStateOf(false) }
    Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = MaterialTheme.shapes.medium, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(horizontal = 8.dp)) {
            val expandable = !step.detail.isNullOrBlank() || !step.items.isNullOrEmpty()
            if (expandable) Action(step.label, { expanded = !expanded })
            else Text(step.label, Modifier.padding(8.dp), maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (step.status == "running") LinearProgressIndicator(Modifier.fillMaxWidth())
            if (expanded) {
                step.detail?.let { Text(it, Modifier.padding(horizontal = 8.dp)) }
                for (item in step.items.orEmpty()) Action("[${item.ref}] ${item.title}", { openNote(item.noteId) })
            }
        }
    }
}

@Composable private fun Reasoning(text: String) {
    var open by rememberSaveable { mutableStateOf(false) }
    Action("思考过程", { open = !open })
    if (open) Text(text, style = MaterialTheme.typography.bodyMedium)
}
