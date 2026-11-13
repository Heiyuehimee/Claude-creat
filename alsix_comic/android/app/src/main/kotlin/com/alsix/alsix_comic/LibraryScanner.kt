package com.alsix.alsix_comic

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import java.io.File
import java.io.InputStream
import java.security.MessageDigest

/**
 * Walks a library root and reports readable items: PDF files and folders that
 * directly contain images. Roots are Storage Access Framework tree URIs
 * (content://…) chosen by the user, or plain paths (used by tests).
 * Nothing is ever written to the library.
 */
class LibraryScanner(private val context: Context) {

    private val resolver = context.contentResolver

    fun persistedRoots(): List<String> =
        resolver.persistedUriPermissions.filter { it.isReadPermission }.map { it.uri.toString() }

    fun releaseRoot(uri: String) {
        try {
            resolver.releasePersistableUriPermission(
                Uri.parse(uri),
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        } catch (_: SecurityException) {
            // Already gone.
        }
    }

    fun displayName(treeUri: Uri, docId: String): String {
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
        resolver.query(docUri, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) return it.getString(0)
        }
        return docId.substringAfterLast(':').substringAfterLast('/')
    }

    private class Child(
        val id: String,
        val name: String,
        val isDir: Boolean,
        val size: Long,
        val modified: Long,
    )

    /** Scans [root]; [progress] receives (items found, current folder). */
    fun scan(root: String, progress: (Int, String) -> Unit): Map<String, Any?> {
        val entries = ArrayList<Map<String, Any?>>()
        var folders = 0
        var lastReport = 0L
        val isFile = !root.startsWith("content://")
        val treeUri = if (isFile) null else Uri.parse(root)

        // Depth-first walk with an explicit stack: (id, relative path).
        val stack = ArrayDeque<Pair<String, String>>()
        stack.addLast(
            Pair(if (isFile) root else DocumentsContract.getTreeDocumentId(treeUri), ""),
        )
        while (stack.isNotEmpty()) {
            val (id, rel) = stack.removeLast()
            folders++
            val children = if (isFile) listFile(id) else listTree(treeUri!!, id)
            val images = ArrayList<Child>()
            for (c in children) {
                if (c.name.startsWith(".")) continue
                val childRel = if (rel.isEmpty()) c.name else "$rel/${c.name}"
                when {
                    c.isDir -> stack.addLast(Pair(c.id, childRel))
                    c.name.endsWith(".pdf", ignoreCase = true) -> entries.add(
                        mapOf(
                            "path" to childRel,
                            "type" to "pdf",
                            "uri" to uriOf(treeUri, c.id),
                            "size" to c.size,
                            "modified" to c.modified,
                        ),
                    )
                    isImage(c.name) -> images.add(c)
                }
            }
            if (images.isNotEmpty() && rel.isNotEmpty()) {
                images.sortWith { a, b -> naturalCompare(a.name, b.name) }
                entries.add(
                    mapOf(
                        "path" to rel,
                        "type" to "images",
                        "uri" to uriOf(treeUri, id),
                        "size" to images.sumOf { it.size },
                        "modified" to images.maxOf { it.modified },
                        "imageCount" to images.size,
                        "firstImage" to uriOf(treeUri, images.first().id),
                    ),
                )
            }
            val now = System.currentTimeMillis()
            if (now - lastReport > 120) {
                lastReport = now
                progress(entries.size, rel)
            }
        }
        progress(entries.size, "")
        return mapOf("entries" to entries, "folders" to folders)
    }

    private fun uriOf(treeUri: Uri?, id: String): String =
        if (treeUri == null) id else DocumentsContract.buildDocumentUriUsingTree(treeUri, id).toString()

    private fun listTree(treeUri: Uri, parentId: String): List<Child> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        val result = ArrayList<Child>()
        resolver.query(
            uri,
            arrayOf(
                Document.COLUMN_DOCUMENT_ID,
                Document.COLUMN_DISPLAY_NAME,
                Document.COLUMN_MIME_TYPE,
                Document.COLUMN_SIZE,
                Document.COLUMN_LAST_MODIFIED,
            ),
            null,
            null,
            null,
        )?.use { c ->
            while (c.moveToNext()) {
                result.add(
                    Child(
                        id = c.getString(0),
                        name = c.getString(1) ?: "",
                        isDir = c.getString(2) == Document.MIME_TYPE_DIR,
                        size = if (c.isNull(3)) 0 else c.getLong(3),
                        modified = if (c.isNull(4)) 0 else c.getLong(4),
                    ),
                )
            }
        }
        return result
    }

    private fun listFile(path: String): List<Child> =
        (File(path).listFiles() ?: emptyArray()).map {
            Child(it.absolutePath, it.name, it.isDirectory, it.length(), it.lastModified())
        }

    /** Image documents of a folder item, in natural order. */
    fun listImages(folder: String): List<String> {
        if (!folder.startsWith("content://")) {
            return (File(folder).listFiles() ?: emptyArray())
                .filter { it.isFile && isImage(it.name) && !it.name.startsWith(".") }
                .sortedWith { a, b -> naturalCompare(a.name, b.name) }
                .map { it.absolutePath }
        }
        val uri = Uri.parse(folder)
        val id = DocumentsContract.getDocumentId(uri)
        return listTree(uri, id)
            .filter { !it.isDir && isImage(it.name) && !it.name.startsWith(".") }
            .sortedWith { a, b -> naturalCompare(a.name, b.name) }
            .map { DocumentsContract.buildDocumentUriUsingTree(uri, it.id).toString() }
    }

    fun open(uri: String): InputStream =
        if (uri.startsWith("content://")) {
            resolver.openInputStream(Uri.parse(uri)) ?: error("Cannot open $uri")
        } else {
            File(uri).inputStream()
        }

    fun readBytes(uri: String): ByteArray = open(uri).use { it.readBytes() }

    /** Identity of a file independent of its name: size + hash of the first 256 KB. */
    fun fingerprint(uri: String): String {
        val digest = MessageDigest.getInstance("SHA-1")
        var total = 0L
        open(uri).use { input ->
            val buf = ByteArray(64 * 1024)
            while (total < 256 * 1024) {
                val n = input.read(buf)
                if (n <= 0) break
                digest.update(buf, 0, n)
                total += n
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    companion object {
        private val imageExt = setOf("jpg", "jpeg", "png", "webp", "gif", "bmp", "avif", "heic")

        fun isImage(name: String): Boolean = name.substringAfterLast('.', "").lowercase() in imageExt

        /** "2.jpg" < "10.jpg"; case-insensitive otherwise. */
        fun naturalCompare(a: String, b: String): Int {
            var i = 0
            var j = 0
            while (i < a.length && j < b.length) {
                val ca = a[i]
                val cb = b[j]
                if (ca.isDigit() && cb.isDigit()) {
                    var ei = i
                    while (ei < a.length && a[ei].isDigit()) ei++
                    var ej = j
                    while (ej < b.length && b[ej].isDigit()) ej++
                    val na = a.substring(i, ei).trimStart('0')
                    val nb = b.substring(j, ej).trimStart('0')
                    if (na.length != nb.length) return na.length - nb.length
                    val cmp = na.compareTo(nb)
                    if (cmp != 0) return cmp
                    i = ei
                    j = ej
                } else {
                    val cmp = ca.lowercaseChar().compareTo(cb.lowercaseChar())
                    if (cmp != 0) return cmp
                    i++
                    j++
                }
            }
            return (a.length - i) - (b.length - j)
        }
    }
}
