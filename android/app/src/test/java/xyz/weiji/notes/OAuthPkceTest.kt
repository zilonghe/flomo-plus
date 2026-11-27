package xyz.weiji.notes

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import xyz.weiji.notes.core.auth.OAuthPkce
import xyz.weiji.notes.core.auth.PendingOAuth
import xyz.weiji.notes.core.network.ApiException
import xyz.weiji.notes.core.storage.CredentialStore
import xyz.weiji.notes.model.AuthProvidersResponse

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class OAuthPkceTest {
    private val verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    private val pending = PendingOAuth("https://weiji.example", "our-state", verifier, 20L)
    private val callback = "weiji://auth/callback"

    @Test fun rfc7636ChallengeAndStartQuery() {
        val expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        assertEquals(expected, OAuthPkce.challenge(verifier))
        val url = OAuthPkce.startUrl("github", pending).toHttpUrl()
        assertEquals("/auth/github/start", url.encodedPath)
        assertEquals(mapOf("client" to "android", "code_challenge_method" to "S256",
            "code_challenge" to expected, "redirect_uri" to callback, "state" to pending.state),
            url.queryParameterNames.associateWith { url.queryParameter(it) })
        val issued = OAuthPkce.pending(pending.origin)
        assertEquals(43, issued.verifier.length)
        assertNotEquals(issued.verifier, issued.state)
    }

    @Test fun callbackChecksExactBaseAndNoFragment() {
        assertEquals("a+b", OAuthPkce.callbackCode("$callback?code=a%2Bb&state=our-state", pending, 100))
        for (base in listOf("https://auth/callback", "weiji://bad/callback", "weiji://auth/wrong",
            "weiji://auth:42/callback", "weiji://a@auth/callback", "weiji://auth/%63allback")) {
            assertThrows(IllegalArgumentException::class.java) {
                OAuthPkce.callbackCode("$base?state=our-state&code=good", pending, 100)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            OAuthPkce.callbackCode("$callback?state=our-state&code=good#fragment", pending, 100)
        }
    }

    @Test fun callbackRejectsMissingIncorrectOrRepeatedStateAndCode() {
        for (query in listOf("code=ok", "state=no&code=ok", "state=our-state&state=our-state&code=ok",
            "state=our-state", "state=our-state&code=", "state=our-state&code=ok&%63ode=another")) {
            assertThrows(RuntimeException::class.java) { OAuthPkce.callbackCode("$callback?$query", pending, 100) }
        }
        val disabled = assertThrows(ApiException::class.java) {
            OAuthPkce.callbackCode("$callback?state=our-state&error=account_disabled", pending, 100)
        }
        assertEquals(403, disabled.status)
        assertEquals("该账号已停用。", disabled.message)
    }

    @Test fun oauthMustAdvertiseExactlyTheNormalizedOrigin() {
        val origin = OAuthPkce.normalizeOrigin(" HTTPS://WEIJI.EXAMPLE:443/ ")
        assertEquals("https://weiji.example", origin)
        OAuthPkce.verifyOrigin(origin, AuthProvidersResponse("oauth", publicOrigin = origin))
        assertEquals("登录服务地址不一致。", assertThrows(IllegalArgumentException::class.java) {
            OAuthPkce.verifyOrigin(origin, AuthProvidersResponse("oauth", publicOrigin = "https://elsewhere.example"))
        }.message)
        assertThrows(IllegalArgumentException::class.java) { OAuthPkce.normalizeOrigin("http://weiji.example") }
    }

    @Test fun restoresPendingAcrossStoreInstancesAndRejectsMissingOrExpired() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = { context.getSharedPreferences("oauth-test", Context.MODE_PRIVATE) }
        val store = CredentialStore(preferences())
        store.pending = pending
        assertEquals(pending, CredentialStore(preferences()).pending)
        assertThrows(IllegalArgumentException::class.java) {
            OAuthPkce.callbackCode("$callback?state=our-state&code=ok", store.pending, 601_000)
        }
        store.pending = null
        assertNull(CredentialStore(preferences()).pending)
        val error = assertThrows(IllegalArgumentException::class.java) {
            OAuthPkce.callbackCode("$callback?state=our-state&code=ok", null)
        }
        assertEquals("登录已失效，请重新登录。", error.message)
    }
}
