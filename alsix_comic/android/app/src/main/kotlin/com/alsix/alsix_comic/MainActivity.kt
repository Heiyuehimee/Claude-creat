package com.alsix.alsix_comic

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.view.KeyEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private val main = Handler(Looper.getMainLooper())

    /** Scanning and cover generation run here, in parallel with rendering. */
    private val ioPool = Executors.newFixedThreadPool(3)

    private lateinit var library: LibraryScanner
    private lateinit var pdf: PdfService
    private lateinit var covers: CoverService

    private var pendingPick: MethodChannel.Result? = null
    private var volumePaging = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        library = LibraryScanner(applicationContext)
        pdf = PdfService(applicationContext)
        covers = CoverService(applicationContext, pdf)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "alsix/native")
        channel.setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFolder" -> pickFolder(result)
            "persistedRoots" -> result.success(library.persistedRoots())
            "releaseRoot" -> {
                library.releaseRoot(call.argument<String>("uri")!!)
                result.success(null)
            }
            "scan" -> background(result) {
                val root = call.argument<String>("root")!!
                val scanId = call.argument<Int>("scanId") ?: 0
                library.scan(root) { count, dir ->
                    main.post {
                        channel.invokeMethod(
                            "scanProgress",
                            mapOf("scanId" to scanId, "count" to count, "dir" to dir),
                        )
                    }
                }
            }
            "fingerprint" -> background(result) {
                library.fingerprint(call.argument<String>("uri")!!)
            }
            "listImages" -> background(result) {
                library.listImages(call.argument<String>("uri")!!)
            }
            "readBytes" -> background(result) {
                library.readBytes(call.argument<String>("uri")!!)
            }
            "pdfOpen" -> pdf.submit(result) { pdf.open(call.argument<String>("uri")!!) }
            "pdfPageSize" -> pdf.submit(result) {
                pdf.pageSize(call.argument<Int>("doc")!!, call.argument<Int>("page")!!)
            }
            "pdfRender" -> pdf.submit(result) {
                pdf.render(
                    call.argument<Int>("doc")!!,
                    call.argument<Int>("page")!!,
                    call.argument<Int>("width")!!,
                )
            }
            "pdfClose" -> pdf.submit(result) {
                pdf.close(call.argument<Int>("doc")!!)
                null
            }
            "cover" -> background(result) {
                covers.cover(
                    call.argument<String>("uri")!!,
                    call.argument<String>("type")!!,
                    call.argument<Int>("width")!!,
                    call.argument<String>("out")!!,
                    call.argument<Int>("page") ?: 0,
                )
            }
            "cacheDir" -> result.success(cacheDir.absolutePath)
            "filesDir" -> result.success(filesDir.absolutePath)
            "externalFilesDir" -> result.success(getExternalFilesDir(null)?.absolutePath)
            "keepScreenOn" -> {
                if (call.argument<Boolean>("on") == true) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            }
            "volumePaging" -> {
                volumePaging = call.argument<Boolean>("on") == true
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        ioPool.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error(e.javaClass.simpleName, e.message, null) }
            }
        }
    }

    // ---- Folder picker (Storage Access Framework) -------------------------

    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "A folder picker is already open", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        startActivityForResult(intent, PICK_FOLDER)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_FOLDER) return
        val result = pendingPick ?: return
        pendingPick = null
        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val docId = DocumentsContract.getTreeDocumentId(uri)
        result.success(mapOf("uri" to uri.toString(), "name" to library.displayName(uri, docId)))
    }

    // ---- Volume keys --------------------------------------------------------

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (volumePaging &&
            (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)
        ) {
            val dir = if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) "next" else "previous"
            channel.invokeMethod("volumeKey", dir)
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (volumePaging &&
            (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)
        ) {
            return true
        }
        return super.onKeyUp(keyCode, event)
    }

    override fun onDestroy() {
        ioPool.shutdownNow()
        pdf.shutdown()
        super.onDestroy()
    }

    companion object {
        private const val PICK_FOLDER = 4201
    }
}
