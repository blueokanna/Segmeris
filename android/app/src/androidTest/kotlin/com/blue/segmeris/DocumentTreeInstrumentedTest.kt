package com.blue.segmeris

import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 29)
class DocumentTreeInstrumentedTest {
    private val base get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val authority = "com.blue.segmeris.document-test"
    private val tree get() = DocumentsContract.buildTreeDocumentUri(authority, "root:downloads")
    private fun item(id: String) = DocumentsContract.buildDocumentUriUsingTree(tree, id)

    @Test fun treeValidationRejectsItemsCollectionsAndForeignUriForms() {
        assertEquals(tree, MediaStoreHelper.requireDocumentTreeUri(tree.toString()))
        listOf(
            "content://$authority/document/file", "$tree/document/file", "$tree/children",
            "content://$authority/tree/", "$tree?query=1", "$tree#fragment",
            "content://10@$authority/tree/root", "file:///downloads", "content://media/tree/root"
        ).forEach { uri ->
            assertThrows("Reject $uri", IllegalArgumentException::class.java) {
                MediaStoreHelper.requireDocumentTreeUri(uri)
            }
        }
    }

    @Test fun itemValidationAcceptsFilesAndRejectsTreeRootsAndCollections() {
        val exported = item("root:downloads/movie.mp4")
        assertEquals(exported, MediaStoreHelper.requireDocumentItemUri(exported.toString()))
        val direct = DocumentsContract.buildDocumentUri(authority, "file:123")
        assertEquals(direct, MediaStoreHelper.requireDocumentItemUri(direct.toString()))
        listOf(
            tree.toString(), item("root:downloads").toString(), "$exported/children", "$exported/",
            "$exported?recursive=true", "$exported#fragment", "content://$authority/document",
            "content://$authority/files/123", "content://$authority/document/", "https://$authority/document/file"
        ).forEach { uri ->
            assertThrows("Reject $uri", IllegalArgumentException::class.java) {
                MediaStoreHelper.requireDocumentItemUri(uri)
            }
        }
    }

    @Test fun exportCreatesNewDocumentWithConflictSuffixAndPreservesExistingBytes() = withProvider { provider, directory ->
        val source = File(directory, "source.mp4").apply { writeText("exported bytes") }
        provider.add("existing", "movie.mp4", "user original")
        val saved = MediaStoreHelper.saveToPath(wrap(provider), source.path, tree.toString(), "movie.mp4")!!
        assertEquals(item("created-1").toString(), saved)
        assertEquals("movie (1).mp4", provider.names["created-1"])
        assertEquals("user original", provider.files.getValue("existing").readText())
        assertEquals("exported bytes", provider.files.getValue("created-1").readText())
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun exportFailureRemovesOnlyTheCreatedDocument() = withProvider { provider, directory ->
        val source = File(directory, "source.mp4").apply { writeText("exported bytes") }
        provider.add("existing", "movie.mp4", "user original")
        provider.failOpen = true
        assertThrows(IOException::class.java) {
            MediaStoreHelper.saveToPath(wrap(provider), source.path, tree.toString(), "movie.mp4")
        }
        assertEquals(listOf("created-1"), provider.deleted)
        assertEquals(setOf("existing"), provider.files.keys)
        assertEquals("user original", provider.files.getValue("existing").readText())
    }

    @Test fun providerReturningExistingIdCannotOverwriteOrDeleteTheUserFile() = withProvider { provider, directory ->
        val source = File(directory, "source.mp4").apply { writeText("exported bytes") }
        provider.add("existing", "movie.mp4", "user original")
        provider.returnExisting = true
        assertThrows(IOException::class.java) {
            MediaStoreHelper.saveToPath(wrap(provider), source.path, tree.toString(), "movie.mp4")
        }
        assertEquals("user original", provider.files.getValue("existing").readText())
        assertEquals(0, provider.openCount)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun deniedWriteGrantPreventsAnyProviderMutation() = withProvider { provider, directory ->
        val source = File(directory, "source.mp4").apply { writeText("data") }
        provider.add("existing", "movie.mp4", "user original")
        val context = wrap(provider, false)
        assertThrows(SecurityException::class.java) {
            MediaStoreHelper.saveToPath(context, source.path, tree.toString(), "movie.mp4")
        }
        assertThrows(SecurityException::class.java) {
            MediaStoreHelper.deleteDownloadedFile(context, item("existing").toString())
        }
        assertEquals(0, provider.createCount)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun documentDeleteIsSpecificIdempotentAndRejectsDirectories() = withProvider { provider, _ ->
        provider.add("existing", "movie.mp4", "download")
        provider.add("neighbor", "other.mp4", "keep")
        val context = wrap(provider)
        assertTrue(MediaStoreHelper.deleteDownloadedFile(context, item("existing").toString()))
        assertTrue(MediaStoreHelper.deleteDownloadedFile(context, item("existing").toString()))
        assertEquals(listOf("existing"), provider.deleted)
        assertEquals("keep", provider.files.getValue("neighbor").readText())
        provider.directories += "folder"
        assertThrows(IllegalArgumentException::class.java) {
            MediaStoreHelper.deleteDownloadedFile(context, item("folder").toString())
        }
        assertThrows(IllegalArgumentException::class.java) {
            MediaStoreHelper.deleteDownloadedFile(context, tree.toString())
        }
        assertEquals(listOf("existing"), provider.deleted)
    }

    private fun withProvider(test: (DocumentProvider, File) -> Unit) {
        val directory = File(base.cacheDir, "saf-io-${System.nanoTime()}").apply { mkdirs() }
        try { test(DocumentProvider(directory), directory) } finally { directory.deleteRecursively() }
    }

    private fun wrap(provider: DocumentProvider, granted: Boolean = true): Context {
        provider.attachInfo(base, ProviderInfo().apply { authority = this@DocumentTreeInstrumentedTest.authority })
        val resolver = ContentResolver.wrap(provider)
        return object : ContextWrapper(base) {
            override fun getContentResolver(): ContentResolver = resolver
            override fun checkUriPermission(uri: Uri, pid: Int, uid: Int, modeFlags: Int): Int =
                if (granted) PackageManager.PERMISSION_GRANTED else PackageManager.PERMISSION_DENIED
        }
    }

    /** Implements only document-specific calls; broad ContentResolver.delete is forbidden. */
    private inner class DocumentProvider(private val directory: File) : ContentProvider() {
        val files = linkedMapOf<String, File>()
        val names = linkedMapOf<String, String>()
        val directories = mutableSetOf("root:downloads")
        val deleted = mutableListOf<String>()
        var createCount = 0
        var openCount = 0
        var failOpen = false
        var returnExisting = false
        fun add(id: String, name: String, content: String) {
            files[id] = File(directory, id).apply { writeText(content) }
            names[id] = name
        }
        override fun onCreate() = true
        override fun getType(uri: Uri) = "video/mp4"
        override fun insert(uri: Uri, values: ContentValues?): Uri? = throw AssertionError("Use createDocument")
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int =
            throw AssertionError("Unexpected provider update")
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
            throw AssertionError("Broad provider delete must never be used")
        override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
            val uri = extras!!.getParcelable<Uri>("uri")!!
            return when (method) {
                "android:createDocument" -> {
                    createCount++
                    val id = if (returnExisting) "existing" else "created-$createCount"
                    if (!returnExisting) add(id, extras.getString(DocumentsContract.Document.COLUMN_DISPLAY_NAME)!!, "")
                    Bundle().apply { putParcelable("uri", item(id)) }
                }
                "android:deleteDocument" -> {
                    val id = DocumentsContract.getDocumentId(uri)
                    deleted += id
                    files.remove(id)?.delete()
                    names.remove(id)
                    Bundle()
                }
                else -> throw AssertionError("Unexpected document call: $method")
            }
        }
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
            val columns = projection!!
            return MatrixCursor(columns).apply {
                val ids = if (uri.lastPathSegment == "children") files.keys.toList() else {
                    val id = DocumentsContract.getDocumentId(uri)
                    if (id in files || id in directories) listOf(id) else emptyList()
                }
                ids.forEach { id ->
                    addRow(columns.map { column ->
                        when (column) {
                            DocumentsContract.Document.COLUMN_DOCUMENT_ID -> id
                            DocumentsContract.Document.COLUMN_DISPLAY_NAME -> names[id] ?: "folder"
                            DocumentsContract.Document.COLUMN_MIME_TYPE -> if (id in directories) DocumentsContract.Document.MIME_TYPE_DIR else "video/mp4"
                            else -> throw AssertionError("Unexpected column $column")
                        }
                    }.toTypedArray())
                }
            }
        }
        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
            openCount++
            if (failOpen) throw FileNotFoundException("Injected document write failure")
            return ParcelFileDescriptor.open(files.getValue(DocumentsContract.getDocumentId(uri)),
                ParcelFileDescriptor.MODE_WRITE_ONLY or ParcelFileDescriptor.MODE_TRUNCATE)
        }
    }
}
