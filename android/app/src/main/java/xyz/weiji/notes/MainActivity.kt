package xyz.weiji.notes

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.browser.customtabs.CustomTabsIntent
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import xyz.weiji.notes.state.AppState
import xyz.weiji.notes.ui.WeijiApp

class MainActivity : ComponentActivity() {
    private val state by lazy {
        ViewModelProvider(this, viewModelFactory {
            initializer { (application as WeijiApplication).container.appState() }
        })[AppState::class.java]
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (savedInstanceState == null) handle(intent)
        setContent { WeijiApp(state) { CustomTabsIntent.Builder().build().launchUrl(this, Uri.parse(it)) } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent) {
        when (intent.action) {
            Intent.ACTION_VIEW -> intent.dataString?.let { state.finishOAuth(it, "Android (${Build.MODEL})") }
            Intent.ACTION_SEND -> if (intent.type == "text/plain") {
                intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.let(state::receiveShare)
            }
        }
    }
}
