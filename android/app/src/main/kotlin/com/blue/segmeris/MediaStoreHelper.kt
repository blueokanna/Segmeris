package com.blue.segmeris

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Process
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import java.io.OutputStream

/** File operations run on MainActivity's bounded I/O worker, never the platform thread. */
object MediaStoreHelper {
    private const val TAG = "MediaStoreHelper"
    private const val MAX_NAME_ATTEMPTS = 10_000

    /** Returns a real MediaStore item URI on Q+, or a filesystem path on older Android. */
    @JvmStatic
    fun saveToDownloads(
        context: Context,
        srcPath: String,
        fileName: String,
        mimeType: String,
        subDir: String
    ): String? {
        val source = sourceFile(srcPath)
        val safeName = sanitizeFileName(fileName)
        val safeSubDir = sanitizeFileName(subDir).takeUnless { subDir.isBlank() } ?: "Segmeris"
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveViaMediaStore(context, source, safeName, mimeType, safeSubDir)
        } else {
            @Suppress("DEPRECATION")
            val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            saveDirectly(context, source, File(downloads, safeSubDir), safeName, mimeType)
        }
    }

    /** Errors propagate to MethodChannel instead of being turned into an unexplained null. */
    @JvmStatic
    fun saveToPath(context: Context, srcPath: String, destDir: String, fileName: String): String? {
        val source = sourceFile(srcPath)
        val safeName = sanitizeFileName(fileName)
        if (destDir.startsWith("content:", ignoreCase = true)) {
            return saveViaDocumentTree(context, source, requireDocumentTreeUri(destDir), safeName)
        }
        require(File(destDir).isAbsolute) { "destDir must be an absolute filesystem directory or a document tree URI" }
        return saveDirectly(context, source, File(destDir), safeName, "video/mp4")
    }

    /** Deletes precisely one downloaded file; an already absent file is a successful deletion. */
    @JvmStatic
    fun deleteDownloadedFile(context: Context, path: String): Boolean {
        require(path.isNotBlank()) { "path is required" }
        checkInterrupted()
        if (path.startsWith("content:", ignoreCase = true)) {
            val uri = Uri.parse(path)
            return if (uri.authority == MediaStore.AUTHORITY) {
                deleteMediaItem(context, requireMediaItemUri(path))
            } else {
                deleteDocumentItem(context, requireDocumentItemUri(path))
            }
        }
        val file = File(path)
        require(file.isAbsolute) { "path must be an absolute file path or a granted file item URI" }
        require(!file.isDirectory) { "Refusing to delete a directory" }
        if (file.delete()) return true

        // Old app versions persisted absolute paths. Scoped storage may hide those files
        // from File.exists(), so also check the exact DATA path before declaring them absent.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            findLegacyMediaItem(context, file.absolutePath)?.let { return deleteMediaItem(context, it) }
        }
        if (!file.exists()) return true
        throw IOException("Could not delete file: ${file.absolutePath}")
    }

    /** Allow only file item routes, never collections, playlists, query parameters or other providers. */
    internal fun requireMediaItemUri(path: String): Uri {
        val uri = Uri.parse(path)
        val parts = uri.pathSegments
        val fileRoute = (parts.size == 3 && parts[1] in setOf("downloads", "file")) ||
            (parts.size == 4 && parts[1] in setOf("video", "images", "audio") && parts[2] == "media")
        require(
            uri.scheme == "content" && uri.authority == MediaStore.AUTHORITY &&
                uri.query == null && uri.fragment == null && fileRoute &&
                parts.first().matches(Regex("[A-Za-z0-9_-]+")) &&
                parts.last().matches(Regex("[0-9]+")) && (parts.last().toLongOrNull() ?: 0L) > 0L &&
                uri.encodedPath == "/" + parts.joinToString("/")
        ) { "Only a concrete content://media file item URI can be deleted" }
        return uri
    }

    /** SAF exports accept only the exact tree root returned by the directory picker. */
    internal fun requireDocumentTreeUri(path: String): Uri {
        val uri = requireDocumentAuthority(path)
        val parts = uri.pathSegments
        require(parts.size == 2 && parts[0] == "tree" && parts[1].isNotEmpty()) {
            "Destination must be a document tree URI"
        }
        require(uri == DocumentsContract.buildTreeDocumentUri(uri.authority!!, parts[1])) {
            "Invalid document tree URI"
        }
        return uri
    }

    /** A document ID is opaque, so use DocumentsContract builders to validate its encoding. */
    internal fun requireDocumentItemUri(path: String): Uri {
        val uri = requireDocumentAuthority(path)
        val parts = uri.pathSegments
        val expected = when {
            parts.size == 2 && parts[0] == "document" && parts[1].isNotEmpty() ->
                DocumentsContract.buildDocumentUri(uri.authority!!, parts[1])
            parts.size == 4 && parts[0] == "tree" && parts[1].isNotEmpty() &&
                parts[2] == "document" && parts[3].isNotEmpty() && parts[1] != parts[3] ->
                DocumentsContract.buildDocumentUriUsingTree(
                    DocumentsContract.buildTreeDocumentUri(uri.authority!!, parts[1]), parts[3]
                )
            else -> throw IllegalArgumentException("Only a concrete file document URI can be deleted")
        }
        require(uri == expected) { "Invalid document item URI" }
        return uri
    }

    private fun requireDocumentAuthority(path: String): Uri {
        val uri = Uri.parse(path)
        require(uri.scheme == "content" && uri.authority != MediaStore.AUTHORITY &&
            uri.authority?.matches(Regex("[A-Za-z0-9_.-]+")) == true &&
            uri.query == null && uri.fragment == null) { "Invalid document provider URI" }
        return uri
    }

    private fun requireDocumentWriteGrant(context: Context, uri: Uri) {
        if (context.checkUriPermission(uri, Process.myPid(), Process.myUid(),
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION) != PackageManager.PERMISSION_GRANTED) {
            throw SecurityException("Write permission for this document has expired; select its directory again")
        }
    }

    /** Null means a confirmed absent item; a null cursor or ambiguous result is an error. */
    private fun documentMimeType(context: Context, uri: Uri): String? {
        val cursor = try {
            context.contentResolver.query(uri, arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_MIME_TYPE
            ), null, null, null)
        } catch (_: FileNotFoundException) {
            return null
        } ?: throw IOException("Cannot query document metadata")
        cursor.use {
            if (!it.moveToFirst()) return null
            val id = it.getString(it.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID))
            val mime = it.getString(it.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE))
            if (id != DocumentsContract.getDocumentId(uri) || mime.isNullOrBlank() || it.moveToNext()) {
                throw IOException("Document URI does not identify exactly one file")
            }
            return mime
        }
    }

    private fun deleteDocumentItem(context: Context, uri: Uri): Boolean {
        requireDocumentWriteGrant(context, uri)
        val mime = documentMimeType(context, uri) ?: return true
        require(mime != DocumentsContract.Document.MIME_TYPE_DIR) { "Refusing to delete a document directory" }
        checkInterrupted()
        try {
            if (!DocumentsContract.deleteDocument(context.contentResolver, uri)) {
                throw IOException("Document provider refused to delete the file")
            }
        } catch (_: FileNotFoundException) {
            // Permission was checked before lookup; another deletion can race us.
        }
        return true
    }

    private fun saveViaDocumentTree(context: Context, source: File, tree: Uri, fileName: String): String {
        checkInterrupted()
        requireDocumentWriteGrant(context, tree)
        val resolver = context.contentResolver
        val treeId = DocumentsContract.getTreeDocumentId(tree)
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, treeId)
        if (documentMimeType(context, parent) != DocumentsContract.Document.MIME_TYPE_DIR) {
            throw IOException("Selected document tree is not an accessible directory")
        }
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, treeId)
        val names = HashSet<String>()
        val ids = HashSet<String>()
        val cursor = resolver.query(children, arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME
        ), null, null, null) ?: throw IOException("Cannot list the selected document directory")
        cursor.use {
            val idColumn = it.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameColumn = it.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            while (it.moveToNext()) {
                checkInterrupted()
                ids += it.getString(idColumn)
                names += it.getString(nameColumn)
            }
        }
        val name = (0 until MAX_NAME_ATTEMPTS).asSequence().map { numberedName(fileName, it) }
            .firstOrNull { it !in names } ?: throw IOException("Too many documents with the same file name")
        checkInterrupted()
        // createDocument allocates a new file. Providers resolve a racing name conflict;
        // an existing ID returned by a broken provider must never be opened or deleted.
        val created = DocumentsContract.createDocument(resolver, parent, "video/mp4", name)
            ?: throw IOException("Document provider did not create a file")
        val item = requireDocumentItemUri(created.toString())
        if (item.authority != tree.authority || !DocumentsContract.isTreeUri(item) ||
            DocumentsContract.getTreeDocumentId(item) != treeId ||
            DocumentsContract.getDocumentId(item) in ids) {
            throw IOException("Document provider did not return a new file in the selected directory")
        }
        try {
            requireDocumentWriteGrant(context, item)
            val mime = documentMimeType(context, item) ?: throw IOException("Created document is missing")
            if (mime == DocumentsContract.Document.MIME_TYPE_DIR) throw IOException("Provider created a directory instead of a file")
            resolver.openOutputStream(item, "w")?.use { output -> copySource(source, output) }
                ?: throw IOException("Cannot open the new document for writing")
        } catch (failure: Throwable) {
            try {
                if (!DocumentsContract.deleteDocument(resolver, item)) {
                    throw IOException("Cannot remove incomplete document export: $item")
                }
            } catch (cleanup: Throwable) {
                failure.addSuppressed(cleanup)
            }
            throw failure
        }
        return item.toString()
    }

    private fun deleteMediaItem(context: Context, uri: Uri): Boolean {
        checkInterrupted()
        val count = context.contentResolver.delete(requireMediaItemUri(uri.toString()), null, null)
        if (count !in 0..1) throw IOException("Unexpected MediaStore delete count: $count")
        return true
    }

    @Suppress("DEPRECATION")
    private fun findLegacyMediaItem(context: Context, path: String): Uri? {
        val collection = MediaStore.Files.getContentUri("external")
        val projection = arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DATA)
        val cursor = context.contentResolver.query(
            collection, projection, "${MediaStore.MediaColumns.DATA} = ?", arrayOf(path), null
        ) ?: throw IOException("Cannot query MediaStore for the legacy download path")
        cursor.use {
            if (!it.moveToFirst()) return null
            val id = it.getLong(it.getColumnIndexOrThrow(MediaStore.MediaColumns._ID))
            val storedPath = it.getString(it.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA))
            if (id <= 0 || storedPath != path || it.moveToNext()) {
                throw IOException("Legacy download path does not identify exactly one MediaStore item")
            }
            return requireMediaItemUri(ContentUris.withAppendedId(collection, id).toString())
        }
    }

    private fun sourceFile(path: String): File {
        require(path.isNotBlank()) { "srcPath is required" }
        return File(path).also {
            if (!it.isFile) throw IOException("Source file does not exist or is not a regular file: $path")
        }
    }

    internal fun sanitizeFileName(fileName: String): String = fileName
        .replace(Regex("[\\\\/:*?\"<>|\\x00-\\x1f]"), "_")
        .trim('.', ' ')
        .ifEmpty { "video.mp4" }

    internal fun numberedName(fileName: String, index: Int): String {
        if (index == 0) return fileName
        val dot = fileName.lastIndexOf('.').takeIf { it > 0 } ?: fileName.length
        return "${fileName.substring(0, dot)} ($index)${fileName.substring(dot)}"
    }

    private fun saveViaMediaStore(
        context: Context, source: File, fileName: String, mimeType: String, subDir: String
    ): String {
        checkInterrupted()
        val resolver = context.contentResolver
        val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/$subDir/"
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val displayName = (0 until MAX_NAME_ATTEMPTS).asSequence().map { numberedName(fileName, it) }
            .firstOrNull { name ->
                checkInterrupted()
                val cursor = resolver.query(
                    collection, arrayOf(MediaStore.MediaColumns._ID),
                    "${MediaStore.MediaColumns.RELATIVE_PATH} = ? AND ${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
                    arrayOf(relativePath, name), null
                ) ?: throw IOException("Cannot check for an existing download")
                cursor.use { !it.moveToFirst() }
            } ?: throw IOException("Too many downloads with the same file name")
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        // Inserting a new row also makes MediaProvider allocate a distinct file if another
        // app creates the same name between our query and insert. Never open an existing row.
        val item = resolver.insert(collection, values) ?: throw IOException("MediaStore insert returned null")
        try {
            resolver.openOutputStream(item, "w")?.use { output ->
                copySource(source, output)
            } ?: throw IOException("Cannot open MediaStore output")
            val published = ContentValues().apply {
                if (mimeType.startsWith("video/")) {
                    val duration = Mp4Duration.readMs(source.absolutePath)
                        ?: throw IOException("Cannot publish an MP4 without a valid movie duration")
                    put(MediaStore.Video.VideoColumns.DURATION, duration)
                }
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            checkInterrupted()
            if (resolver.update(item, published, null, null) != 1) {
                throw IOException("Cannot publish MediaStore entry")
            }
        } catch (failure: Throwable) {
            try {
                if (resolver.delete(item, null, null) !in 0..1) {
                    throw IOException("Cannot clean up incomplete MediaStore export: $item")
                }
            } catch (cleanup: Throwable) {
                failure.addSuppressed(cleanup)
            }
            throw failure
        }
        return item.toString()
    }

    private fun saveDirectly(
        context: Context, source: File, directory: File, fileName: String, mimeType: String
    ): String {
        val target = copyToUniqueFile(source, directory, fileName)
        // A scanner problem must not turn a completed export into an unreported orphan.
        try {
            MediaScannerConnection.scanFile(context, arrayOf(target.absolutePath), arrayOf(mimeType), null)
        } catch (error: Exception) {
            Log.w(TAG, "Saved file could not be scheduled for media scanning", error)
        }
        return target.absolutePath
    }

    /** Reserve a new file atomically; existing files (including the source itself) are untouched. */
    internal fun copyToUniqueFile(source: File, directory: File, fileName: String): File {
        checkInterrupted()
        if (!directory.isDirectory && !directory.mkdirs() && !directory.isDirectory) {
            throw IOException("Cannot create destination directory: $directory")
        }
        val sourcePath = source.canonicalPath
        val safeName = sanitizeFileName(fileName)
        for (index in 0 until MAX_NAME_ATTEMPTS) {
            checkInterrupted()
            val target = File(directory, numberedName(safeName, index))
            if (target.canonicalPath == sourcePath || !target.createNewFile()) continue
            try {
                FileOutputStream(target).use { output ->
                    copySource(source, output)
                    output.fd.sync()
                }
                checkInterrupted()
                return target
            } catch (failure: Throwable) {
                try {
                    if (!target.delete() && target.exists()) {
                        throw IOException("Cannot remove incomplete export: $target")
                    }
                } catch (cleanup: Throwable) {
                    failure.addSuppressed(cleanup)
                }
                throw failure
            }
        }
        throw IOException("Too many files with the same name in: $directory")
    }

    private fun copySource(source: File, output: OutputStream) {
        val expected = source.length()
        FileInputStream(source).use { input ->
            val copied = copyInterruptibly(input, output)
            if (copied != expected || source.length() != expected) throw IOException("Incomplete media export")
        }
        output.flush()
        checkInterrupted()
    }

    internal fun copyInterruptibly(input: InputStream, output: OutputStream): Long {
        val buffer = ByteArray(65_536)
        var copied = 0L
        while (true) {
            checkInterrupted()
            val count = input.read(buffer)
            if (count < 0) return copied
            checkInterrupted()
            output.write(buffer, 0, count)
            copied += count
        }
    }

    private fun checkInterrupted() {
        if (Thread.currentThread().isInterrupted) throw InterruptedIOException("File operation cancelled")
    }
}
