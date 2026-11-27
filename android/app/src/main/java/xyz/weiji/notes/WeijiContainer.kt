package xyz.weiji.notes

import android.app.Application
import androidx.room.Room
import xyz.weiji.notes.core.storage.CredentialStore
import xyz.weiji.notes.core.storage.NoteCacheDb
import xyz.weiji.notes.state.AppState

class WeijiContainer(val credentials: CredentialStore, val database: NoteCacheDb) {
    fun appState() = AppState(credentials, database.notes())
}

class WeijiApplication : Application() {
    private val production by lazy {
        WeijiContainer(CredentialStore.encrypted(this), Room.databaseBuilder(this, NoteCacheDb::class.java, "notes.db").build())
    }
    internal var testContainer: WeijiContainer? = null
    val container get() = testContainer ?: production
}
