package com.alsix.alsix_comic

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.File
import java.io.FileOutputStream

/** Writes small JPEG covers into the app cache. */
class CoverService(context: Context, private val pdf: PdfService) {
    private val scanner = LibraryScanner(context)

    /**
     * Renders page [page] of [uri] ([type] "pdf" or "images") [width] pixels
     * wide into [out]. Returns [out], or null when the item has no pages.
     */
    fun cover(uri: String, type: String, width: Int, out: String, page: Int): String? {
        val bitmap = when (type) {
            "pdf" -> {
                val (fd, renderer) = pdf.openRenderer(uri)
                try {
                    if (renderer.pageCount == 0) return null
                    PdfService.renderBitmap(renderer, page.coerceIn(0, renderer.pageCount - 1), width)
                } finally {
                    renderer.close()
                    fd.close()
                }
            }
            else -> {
                val images = scanner.listImages(uri)
                if (images.isEmpty()) return null
                decodeScaled(images[page.coerceIn(0, images.size - 1)], width) ?: return null
            }
        }
        val file = File(out)
        file.parentFile?.mkdirs()
        val tmp = File("$out.tmp")
        FileOutputStream(tmp).use { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }
        bitmap.recycle()
        tmp.renameTo(file)
        return out
    }

    private fun decodeScaled(uri: String, width: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        scanner.open(uri).use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0) return null
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= width) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = scanner.open(uri).use { BitmapFactory.decodeStream(it, null, opts) } ?: return null
        if (decoded.width <= width) return decoded
        val h = (decoded.height.toLong() * width / decoded.width).toInt()
        val scaled = Bitmap.createScaledBitmap(decoded, width, h, true)
        if (scaled != decoded) decoded.recycle()
        return scaled
    }
}
