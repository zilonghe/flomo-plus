package xyz.weiji.notes.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import java.util.Locale
import xyz.weiji.notes.state.AppState
import xyz.weiji.notes.ui.components.Action
import xyz.weiji.notes.ui.components.WeijiPrimaryButton
import xyz.weiji.notes.ui.theme.WeijiTheme

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun SettingsScreen(state: AppState) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Action("返回", { state.settings = false })
        Text("设置", style = MaterialTheme.typography.headlineSmall)
        Text("主题", style = MaterialTheme.typography.titleMedium)
        WrapActions {
            for (theme in WeijiTheme.entries) {
                val key = theme.name.lowercase(Locale.ROOT)
                FilterChip(state.theme == key, { state.selectTheme(key) }, { Text(theme.label) }, Modifier.heightIn(min = 48.dp))
            }
        }
        WrapActions {
            for ((key, label) in listOf("system" to "跟随系统", "light" to "浅色", "dark" to "深色")) {
                FilterChip(state.colorMode == key, { state.selectColorMode(key) }, { Text(label) }, Modifier.heightIn(min = 48.dp))
            }
        }
        HorizontalDivider()
        Text("语义索引", style = MaterialTheme.typography.titleMedium)
        val index = state.semantic
        if (index != null) {
            Text("已索引 ${index.indexed} / ${index.total}" + if (index.indexing) " · 正在索引" else "")
            index.lastError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
        WeijiPrimaryButton("重建索引", { state.reindex() }, enabled = !state.settingsBusy && index?.indexing != true)
        val status = state.obsidian
        if (state.session?.user?.role == "admin" && status?.configured == true) {
            HorizontalDivider()
            Text("Obsidian 同步", style = MaterialTheme.typography.titleMedium)
            status.lastRun?.let { Text(it.error ?: it.at) }
            WeijiPrimaryButton("立即同步", { state.syncObsidian() }, enabled = !state.settingsBusy && !status.running)
        }
        if (state.settingsBusy) LinearProgressIndicator(Modifier.fillMaxWidth())
        HorizontalDivider()
        Text(state.session?.user?.name.orEmpty())
        Action("退出登录", { state.logout() })
    }
}
