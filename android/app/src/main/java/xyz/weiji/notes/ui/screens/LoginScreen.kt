package xyz.weiji.notes.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import xyz.weiji.notes.state.AppState
import xyz.weiji.notes.ui.components.Action
import xyz.weiji.notes.ui.components.ErrorText
import xyz.weiji.notes.ui.components.WeijiPrimaryButton

@Composable fun LoginScreen(state: AppState, openOAuth: (String) -> Unit) {
    var advanced by rememberSaveable { mutableStateOf(false) }
    var token by remember { mutableStateOf("") }
    var reload by remember { mutableIntStateOf(0) }
    val address = state.address
    LaunchedEffect(address, reload) {
        delay(200)
        state.discover(address)
    }

    Box(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), contentAlignment = Alignment.Center) {
        Card(Modifier.widthIn(max = 400.dp).fillMaxWidth(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
            Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("微记", style = MaterialTheme.typography.headlineLarge)
                for (provider in state.providers?.providers.orEmpty()) {
                    WeijiPrimaryButton("用 ${provider.name} 登录", { state.startOAuth(provider.id, openOAuth) },
                        Modifier.fillMaxWidth(), !state.authBusy)
                }
                ErrorText(state.error)
                if (state.error != null && state.providers == null) Action("重试", { state.dismissError(); reload++ })
                Action("高级连接", { advanced = !advanced })
                if (advanced) {
                    OutlinedTextField(address, { state.address = it; state.dismissError() }, Modifier.fillMaxWidth(),
                        label = { Text("服务器地址") }, singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                    OutlinedTextField(token, { token = it }, Modifier.fillMaxWidth(), label = { Text("访问令牌") },
                        singleLine = true, visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                    WeijiPrimaryButton("使用令牌连接", { state.manualLogin(token) }, Modifier.fillMaxWidth(), !state.authBusy)
                }
                if (state.authBusy) LinearProgressIndicator(Modifier.fillMaxWidth())
            }
        }
    }
}
