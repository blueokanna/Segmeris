package com.blue.segmeris

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

@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 29)
class MediaStoreFileInstrumentedTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun deletionAcceptsOnlyConcreteMediaFileItems() {
        listOf(
            "content://media/external_primary/downloads/42",
            "content://media/external/file/42",
            "content://media/external/video/media/42",
            "content://media/external/images/media/42",
            "content://media/0123-4567/audio/media/42"
        ).forEach { assertEquals(it, MediaStoreHelper.requireMediaItemUri(it).toString()) }
        listOf(
            "content://media/external_primary/downloads",
            "content://media/external/file",
            "content://media/external/video/media",
            "content://media/external/video/media/0",
            "content://media/external/video/media/-1",
            "content://media/external/video/media/99999999999999999999999",
            "content://media/external/video/media/42/extra",
            "content://media/external/video/media/42/",
            "content://media/external/audio/playlists/42",
            "content://media/external/audio/albums/42",
            "content://media/external/images/thumbnails/42",
            "content://media/external/file/42?recursive=true",
            "content://media/external/file/42#fragment",
            "content://media/external/file/%34%32",
            "content://media/external%2Ffile/42",
            "content://other.provider/external/file/42",
            "content://10@media/external/file/42",
            "file:///storage/emulated/0/Download/file.mp4"
        ).forEach { path ->
            assertThrows("Must reject $path", IllegalArgumentException::class.java) {
                MediaStoreHelper.requireMediaItemUri(path)
            }
        }
    }

    @Test fun exportsReturnDistinctReadableUrisAndDeleteIdempotently() {
        val folder = "Segmeris-io-test-${System.nanoTime()}"
        val source = File.createTempFile("segmeris-export-", ".txt", context.cacheDir)
        val saved = mutableListOf<String>()
        try {
            source.writeText("first export")
            saved += MediaStoreHelper.saveToDownloads(context, source.path, "same.txt", "text/plain", folder)!!
            source.writeText("second export")
            saved += MediaStoreHelper.saveToDownloads(context, source.path, "same.txt", "text/plain", folder)!!
            assertNotEquals(saved[0], saved[1])
            saved.forEach { assertEquals("media", Uri.parse(it).authority) }
            assertEquals("first export", readText(saved[0]))
            assertEquals("second export", readText(saved[1]))
            assertThrows(IllegalArgumentException::class.java) {
                MediaStoreHelper.deleteDownloadedFile(context, MediaStore.Downloads.EXTERNAL_CONTENT_URI.toString())
            }
            assertEquals("first export", readText(saved[0]))
            saved.forEach { path ->
                context.contentResolver.query(Uri.parse(path), arrayOf(MediaStore.MediaColumns.IS_PENDING), null, null, null)!!.use {
                    assertTrue(it.moveToFirst())
                    assertEquals(0, it.getInt(0))
                }
                assertTrue(MediaStoreHelper.deleteDownloadedFile(context, path))
                assertTrue(MediaStoreHelper.deleteDownloadedFile(context, path))
            }
        } finally {
            saved.forEach { MediaStoreHelper.deleteDownloadedFile(context, it) }
            source.delete()
        }
    }

    @Test fun failedVideoValidationLeavesNoPendingOrPublishedRow() {
        val folder = "Segmeris-failed-export-${System.nanoTime()}"
        val source = File.createTempFile("segmeris-invalid-", ".mp4", context.cacheDir)
        try {
            source.writeText("not a valid movie")
            assertThrows(IOException::class.java) {
                MediaStoreHelper.saveToDownloads(context, source.path, "invalid.mp4", "video/mp4", folder)
            }
            context.contentResolver.query(
                MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.RELATIVE_PATH} = ?", arrayOf("Download/$folder/"), null
            )!!.use { assertFalse("Failed export left a MediaStore row", it.moveToFirst()) }
        } finally { source.delete() }
    }

    @Test fun ordinaryFileDeletionHandlesMissingButRejectsDirectories() {
        val directory = File(context.cacheDir, "segmeris-delete-${System.nanoTime()}").apply { mkdirs() }
        val source = File(directory, "download.mp4").apply { writeText("download") }
        try {
            assertTrue(MediaStoreHelper.deleteDownloadedFile(context, source.path))
            assertFalse(source.exists())
            assertTrue(MediaStoreHelper.deleteDownloadedFile(context, source.path))
            assertThrows(IllegalArgumentException::class.java) {
                MediaStoreHelper.deleteDownloadedFile(context, directory.path)
            }
            assertTrue(directory.isDirectory)
        } finally { directory.deleteRecursively() }
    }

    private fun readText(path: String): String = context.contentResolver.openInputStream(Uri.parse(path))!!.use {
        it.readBytes().toString(Charsets.UTF_8)
    }
}
