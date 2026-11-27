package xyz.weiji.notes.core.auth

import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import kotlinx.serialization.Serializable
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import xyz.weiji.notes.core.network.ApiException
import xyz.weiji.notes.model.AuthProvidersResponse

const val DEFAULT_ORIGIN = "https://weiji.18818888.xyz"

@Serializable data class PendingOAuth(val origin: String, val state: String, val verifier: String, val createdAt: Long)

object OAuthPkce {
    const val CALLBACK = "weiji://auth/callback"
    private const val MAX_AGE_MS = 10 * 60 * 1000L
    private val random = SecureRandom()

    fun normalizeOrigin(input: String): String {
        val raw = input.trim()
        val url = (if ("://" in raw) raw else "https://$raw").toHttpUrlOrNull()
        require(url != null && url.encodedPath == "/" && url.query == null && url.fragment == null &&
            url.encodedUsername.isEmpty() && url.encodedPassword.isEmpty()) { "请输入有效的服务地址。" }
        require(url.isHttps || url.host in setOf("localhost", "127.0.0.1", "10.0.2.2")) { "请使用 HTTPS 服务地址。" }
        return url.toString().removeSuffix("/")
    }

    private fun base64(bytes: ByteArray) = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    private fun token() = base64(ByteArray(32).also(random::nextBytes))
    fun challenge(verifier: String) = base64(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII)))
    fun pending(origin: String, now: Long = System.currentTimeMillis()) = PendingOAuth(origin, token(), token(), now)

    fun verifyOrigin(origin: String, config: AuthProvidersResponse) {
        require(config.authMode != "oauth" || config.publicOrigin == origin) { "登录服务地址不一致。" }
    }

    fun startUrl(provider: String, pending: PendingOAuth): String = pending.origin.toHttpUrl().newBuilder()
        .addPathSegment("auth").addPathSegment(provider).addPathSegment("start")
        .addQueryParameter("client", "android").addQueryParameter("redirect_uri", CALLBACK)
        .addQueryParameter("code_challenge", challenge(pending.verifier)).addQueryParameter("code_challenge_method", "S256")
        .addQueryParameter("state", pending.state).build().toString()

    fun callbackCode(url: String, pending: PendingOAuth?, now: Long = System.currentTimeMillis()): String {
        require(pending != null && now - pending.createdAt in 0..MAX_AGE_MS) { "登录已失效，请重新登录。" }
        val uri = runCatching { URI(url) }.getOrNull()
        require(uri != null && url.substringBefore('?') == CALLBACK && uri.rawFragment == null) { "登录回调地址无效。" }
        val query = uri.rawQuery.orEmpty().split('&').map {
            URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
        }
        fun values(name: String) = query.filter { it.first == name }.map { it.second }
        require(values("state").singleOrNull() == pending.state) { "登录状态无效，请重新登录。" }
        if ("account_disabled" in values("error")) throw ApiException(403, "该账号已停用。")
        require(values("error").isEmpty()) { "登录失败，请重试。" }
        return values("code").singleOrNull()?.takeIf { it.isNotBlank() } ?: error("登录凭证无效，请重新登录。")
    }
}
