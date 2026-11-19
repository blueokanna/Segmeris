package com.blue.segmeris

import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.provider.MediaStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Provider contract tests make broad deletion regressions fail without touching user media. */
@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 29)
class MediaStoreDeletionInstrumentedTest {
    private val base get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun absentPath() = File(base.cacheDir, "absent-quote'-${System.nanoTime()}.mp4").absolutePath

    @Test fun legacyLookupUsesExactParameterizedPathAndDeletesOnlyItsItem() {
        val path = absentPath()
        val provider = RecordingProvider(listOf(42L to path))
        assertTrue(MediaStoreHelper.deleteDownloadedFile(wrap(provider), path))
        assertEquals("${MediaStore.MediaColumns.DATA} = ?", provider.selection)
        assertArrayEquals(arrayOf(path), provider.selectionArgs)
        assertEquals(listOf("content://media/external/file/42"), provider.deleted.map { it.toString() })
    }

    @Test fun ambiguousLegacyPathNeverDeletesAnyRow() {
        val path = absentPath()
        val provider = RecordingProvider(listOf(42L to path, 43L to path))
        assertThrows(IOException::class.java) { MediaStoreHelper.deleteDownloadedFile(wrap(provider), path) }
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun mismatchedLegacyPathNeverDeletesAnyRow() {
        val provider = RecordingProvider(listOf(42L to "/unrelated/user/file.mp4"))
        assertThrows(IOException::class.java) {
            MediaStoreHelper.deleteDownloadedFile(wrap(provider), absentPath())
        }
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun missingFileAndMissingRowAreSuccessful() {
        val provider = RecordingProvider(emptyList())
        assertTrue(MediaStoreHelper.deleteDownloadedFile(wrap(provider), absentPath()))
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun providerPermissionFailurePropagates() {
        val provider = RecordingProvider(emptyList()).apply { denyDelete = true }
        assertThrows(SecurityException::class.java) {
            MediaStoreHelper.deleteDownloadedFile(wrap(provider), "content://media/external/file/42")
        }
    }

    @Test fun nullQueryCannotBeMistakenForMissingFile() {
        val provider = RecordingProvider(emptyList()).apply { nullQuery = true }
        assertThrows(IOException::class.java) {
            MediaStoreHelper.deleteDownloadedFile(wrap(provider), absentPath())
        }
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun collectionAndForeignUrisNeverReachProviderDelete() {
        val provider = RecordingProvider(emptyList())
        val context = wrap(provider)
        listOf("content://media/external/file", "content://other/external/file/42").forEach { uri ->
            assertThrows(IllegalArgumentException::class.java) { MediaStoreHelper.deleteDownloadedFile(context, uri) }
        }
        assertTrue(provider.deleted.isEmpty())
    }

    private fun wrap(provider: RecordingProvider): Context {
        provider.attachInfo(base, ProviderInfo().apply { authority = "media" })
        val resolver = ContentResolver.wrap(provider)
        return object : ContextWrapper(base) {
            override fun getContentResolver(): ContentResolver = resolver
        }
    }

    private class RecordingProvider(private val rows: List<Pair<Long, String>>) : ContentProvider() {
        var selection: String? = null
        var selectionArgs: Array<out String>? = null
        var denyDelete = false
        var nullQuery = false
        val deleted = mutableListOf<Uri>()
        override fun onCreate() = true
        override fun getType(uri: Uri): String = "video/mp4"
        override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int =
            throw UnsupportedOperationException()
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int {
            if (denyDelete) throw SecurityException("MediaStore access denied")
            assertNull("Delete must address an item URI", selection)
            assertNull(selectionArgs)
            deleted += uri
            return 1
        }
        override fun query(
            uri: Uri, projection: Array<out String>?, selection: String?,
            selectionArgs: Array<out String>?, sortOrder: String?
        ): Cursor? {
            this.selection = selection
            this.selectionArgs = selectionArgs
            if (nullQuery) return null
            return MatrixCursor(arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DATA)).apply {
                rows.forEach { (id, path) -> addRow(arrayOf<Any>(id, path)) }
            }
        }
    }
}
