package xyz.weiji.notes.core.storage

import androidx.room.*
import kotlinx.serialization.encodeToString
import xyz.weiji.notes.model.Note
import xyz.weiji.notes.model.wireJson

@Entity(tableName = "cached_notes", primaryKeys = ["origin", "userId", "noteId"])
data class CachedNote(
    val origin: String, val userId: String, val noteId: String, val payloadJson: String,
    val revision: Int, val createdAt: String,
)

@Entity(tableName = "sync_meta", primaryKeys = ["origin", "userId"])
data class SyncMeta(val origin: String, val userId: String, val etag: String?, val updatedAt: Long)
data class CachedSnapshot(val notes: List<Note>, val etag: String?)

@Dao
abstract class NoteCache {
    @Query("SELECT * FROM cached_notes WHERE origin = :origin AND userId = :userId ORDER BY createdAt DESC, noteId")
    protected abstract suspend fun rows(origin: String, userId: String): List<CachedNote>
    @Query("SELECT etag FROM sync_meta WHERE origin = :origin AND userId = :userId")
    protected abstract suspend fun etag(origin: String, userId: String): String?
    @Query("DELETE FROM cached_notes WHERE origin = :origin AND userId = :userId")
    protected abstract suspend fun clearNotes(origin: String, userId: String)
    @Query("DELETE FROM sync_meta WHERE origin = :origin AND userId = :userId")
    protected abstract suspend fun clearMeta(origin: String, userId: String)
    @Query("DELETE FROM cached_notes WHERE origin = :origin AND userId = :userId AND noteId = :id")
    protected abstract suspend fun deleteNote(origin: String, userId: String, id: String)
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    protected abstract suspend fun putNotes(notes: List<CachedNote>)
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    protected abstract suspend fun putMeta(meta: SyncMeta)

    private fun row(origin: String, userId: String, note: Note) =
        CachedNote(origin, userId, note.id, wireJson.encodeToString(note), note.revision, note.createdAt)

    @Transaction
    open suspend fun loadSnapshot(origin: String, userId: String) =
        CachedSnapshot(rows(origin, userId).map { wireJson.decodeFromString<Note>(it.payloadJson) }, etag(origin, userId))

    @Transaction
    open suspend fun replaceSnapshot(origin: String, userId: String, notes: List<Note>, etag: String?) {
        clearNotes(origin, userId)
        putNotes(notes.map { row(origin, userId, it) })
        putMeta(SyncMeta(origin, userId, etag, System.currentTimeMillis()))
    }

    @Transaction
    open suspend fun applyMutation(origin: String, userId: String, note: Note?, deletedId: String?) {
        if (note != null) putNotes(listOf(row(origin, userId, note)))
        if (deletedId != null) deleteNote(origin, userId, deletedId)
        // A mutation response is not a full snapshot; reload without an ETag next time.
        clearMeta(origin, userId)
    }

    @Transaction
    open suspend fun clearAccount(origin: String, userId: String) {
        clearNotes(origin, userId)
        clearMeta(origin, userId)
    }
}

@Database(entities = [CachedNote::class, SyncMeta::class], version = 1)
abstract class NoteCacheDb : RoomDatabase() {
    abstract fun notes(): NoteCache
}
