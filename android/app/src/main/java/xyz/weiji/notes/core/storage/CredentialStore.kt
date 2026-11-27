package xyz.weiji.notes.core.storage

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.serialization.encodeToString
import kotlinx.serialization.Serializable
import xyz.weiji.notes.core.auth.PendingOAuth
import xyz.weiji.notes.model.SessionInfo
import xyz.weiji.notes.model.wireJson

@Serializable data class Credentials(val origin: String, val token: String, val session: SessionInfo)

class CredentialStore(private val prefs: SharedPreferences) {
    companion object {
        fun encrypted(context: Context): CredentialStore {
            val master = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
            return CredentialStore(EncryptedSharedPreferences.create(
                context, "weiji_credentials", master,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            ))
        }
    }

    private inline fun <reified T> read(key: String): T? =
        prefs.getString(key, null)?.let { wireJson.decodeFromString<T>(it) }

    private fun write(key: String, value: String?) {
        check(prefs.edit().putString(key, value).commit()) { "无法保存本地登录状态。" }
    }

    var credentials: Credentials?
        get() = read("credentials")
        set(value) = write("credentials", value?.let { wireJson.encodeToString(it) })
    var pending: PendingOAuth?
        get() = read("pending_oauth")
        set(value) = write("pending_oauth", value?.let { wireJson.encodeToString(it) })
    var origin: String?
        get() = prefs.getString("origin", null)
        set(value) { prefs.edit().putString("origin", value).apply() }
    var theme: String
        get() = prefs.getString("theme", "pine") ?: "pine"
        set(value) { prefs.edit().putString("theme", value).apply() }
    var colorMode: String
        get() = prefs.getString("color_mode", "system") ?: "system"
        set(value) { prefs.edit().putString("color_mode", value).apply() }
}
