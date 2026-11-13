package com.alsix.alsix_comic

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Renders PDF pages with the platform PdfRenderer. The file is read through a
 * file descriptor with random access, so a 1 GB PDF opens as fast as a small
 * one: only the cross-reference table and the requested page are read.
 */
class PdfService(private val context: Context) {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private class Doc(val fd: ParcelFileDescriptor, val renderer: PdfRenderer, var lastUse: Long)

    private val docs = LinkedHashMap<Int, Doc>()
    private var nextId = 1

    fun submit(result: MethodChannel.Result, work: () -> Any?) {
        executor.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error(e.javaClass.simpleName, e.message, null) }
            }
        }
    }

    fun openRenderer(uri: String): Pair<ParcelFileDescriptor, PdfRenderer> {
        val fd = if (uri.startsWith("content://")) {
            context.contentResolver.openFileDescriptor(Uri.parse(uri), "r")
                ?: error("Cannot open $uri")
        } else {
            ParcelFileDescriptor.open(File(uri), ParcelFileDescriptor.MODE_READ_ONLY)
        }
        return try {
            Pair(fd, PdfRenderer(fd))
        } catch (e: Throwable) {
            fd.close()
            throw e
        }
    }

    /** Returns {doc, pages}. Keeps at most 3 documents open. */
    fun open(uri: String): Map<String, Any> {
        while (docs.size >= 3) {
            val oldest = docs.entries.minByOrNull { it.value.lastUse }!!
            close(oldest.key)
        }
        val (fd, renderer) = openRenderer(uri)
        val id = nextId++
        docs[id] = Doc(fd, renderer, System.nanoTime())
        return mapOf("doc" to id, "pages" to renderer.pageCount)
    }

    private fun doc(id: Int): Doc {
        val d = docs[id] ?: error("Document $id is not open")
        d.lastUse = System.nanoTime()
        return d
    }

    fun pageSize(id: Int, index: Int): List<Int> {
        doc(id).renderer.openPage(index).use { return listOf(it.width, it.height) }
    }

    /** Renders a page [width] pixels wide. Returns raw RGBA pixels. */
    fun render(id: Int, index: Int, width: Int): Map<String, Any> {
        val bitmap = renderBitmap(doc(id).renderer, index, width)
        try {
            val buffer = ByteBuffer.allocate(bitmap.byteCount)
            bitmap.copyPixelsToBuffer(buffer)
            return mapOf(
                "width" to bitmap.width,
                "height" to bitmap.height,
                "pixels" to buffer.array(),
            )
        } finally {
            bitmap.recycle()
        }
    }

    fun close(id: Int) {
        docs.remove(id)?.let {
            it.renderer.close()
            it.fd.close()
        }
    }

    fun shutdown() {
        executor.execute { docs.keys.toList().forEach { close(it) } }
        executor.shutdown()
    }

    companion object {
        fun renderBitmap(renderer: PdfRenderer, index: Int, width: Int): Bitmap {
            renderer.openPage(index).use { page ->
                val w = width.coerceIn(16, 4096)
                val h = (w.toLong() * page.height / page.width.coerceAtLeast(1)).toInt()
                    .coerceIn(16, 8192)
                val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                return bitmap
            }
        }
    }
}
