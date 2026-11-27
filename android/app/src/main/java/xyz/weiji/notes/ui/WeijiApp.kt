package xyz.weiji.notes.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Notes
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Explore
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import xyz.weiji.notes.state.AppState
import xyz.weiji.notes.state.Tab
import xyz.weiji.notes.ui.components.ErrorText
import xyz.weiji.notes.ui.screens.*
import xyz.weiji.notes.ui.theme.LocalWeijiColors
import xyz.weiji.notes.ui.theme.WeijiMaterialTheme

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun WeijiApp(state: AppState, openOAuth: (String) -> Unit) {
    WeijiMaterialTheme(state.theme, state.colorMode) {
        val colors = LocalWeijiColors.current
        val inApp = state.session != null
        val main = state.reader == null && state.editor == null && !state.settings
        BackHandler(inApp && (!main || state.tab != Tab.Notes)) { state.back() }
        Scaffold(
            containerColor = colors.paper.canvas,
            topBar = {
                if (inApp && main) TopAppBar(
                    title = { Text(if (state.tab == Tab.Notes) "微记" else state.tab.label) },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.paper.canvas),
                    actions = {
                        IconButton(state::openSettings, Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)) {
                            Icon(Icons.Outlined.Settings, "设置")
                        }
                    },
                )
            },
            bottomBar = {
                if (inApp && main) NavigationBar(containerColor = colors.paper.paper) {
                    for (tab in Tab.entries) NavigationBarItem(
                        selected = state.tab == tab,
                        onClick = { if (tab == Tab.Walk && state.walk.result == null) state.openWalk() else state.tab = tab },
                        icon = { Icon(when (tab) {
                            Tab.Notes -> Icons.AutoMirrored.Outlined.Notes
                            Tab.Walk -> Icons.Outlined.Explore
                            Tab.Ai -> Icons.Outlined.AutoAwesome
                        }, contentDescription = null) },
                        label = { Text(tab.label) },
                    )
                }
            },
        ) { insets ->
            Column(Modifier.fillMaxSize().padding(insets).imePadding()) {
                if (inApp && state.error != null) Box(Modifier.padding(horizontal = 16.dp)) { ErrorText(state.error) }
                when {
                    !inApp -> LoginScreen(state, openOAuth)
                    state.editor != null -> NoteEditor(state)
                    state.reader != null -> NoteReader(state)
                    state.settings -> SettingsScreen(state)
                    state.tab == Tab.Notes -> NotesScreen(state)
                    state.tab == Tab.Walk -> WalkScreen(state)
                    else -> state.ai?.let { AiChatScreen(state, it) }
                }
            }
        }
    }
}
