package com.blue.segmeris

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.IOException
import java.io.InterruptedIOException
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private var mediaChannel: MethodChannel? = null
    private var fileIo: MediaStoreIoQueue? = null

    companion object {
        private const val TAG = "MainActivity"
        private const val CHANNEL = "com.blue.segmeris/media_store"
        private var rustLibLoaded = false

        init {
            try {
                System.loadLibrary("rust_lib_segmeris")
                rustLibLoaded = true
                Log.i(TAG, "✅ Rust library loaded successfully")
            } catch (e: UnsatisfiedLinkError) {
                Log.e(TAG, "❌ Failed to load rust_lib_segmeris: ${e.message}", e)
            }
        }
    }

    private external fun nativeInitMedia(transcoder: Class<*>, files: String, external: String, cache: String)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (rustLibLoaded) {
            val app = applicationContext
            nativeInitMedia(MediaTranscoder::class.java, app.filesDir.absolutePath,
                (app.getExternalFilesDir(null) ?: app.filesDir).absolutePath, app.cacheDir.absolutePath)
        }
        Log.i(TAG, "✅ Flutter engine configured")

        closeFileIo()
        val mainHandler = Handler(Looper.getMainLooper())
        val ioQueue = MediaStoreIoQueue { callback -> mainHandler.post(callback) }
        val appContext = applicationContext
        fileIo = ioQueue
        mediaChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getRuntimeCapabilities" -> {
                        try {
                            val report = JSONObject(MediaTranscoder.capabilityReport())
                            val encoders = report.getJSONArray("hardwareVideoEncoders")
                            val decoders = report.getJSONArray("hardwareVideoDecoders")
                            val hardwareTranscoderReady = rustLibLoaded && encoders.length() > 0
                            result.success(
                                mapOf(
                                    "platform" to "android",
                                    "transcoderBackend" to if (hardwareTranscoderReady) {
                                        "Android MediaCodec / MediaMuxer"
                                    } else if (rustLibLoaded) {
                                        "Android MediaMuxer (no hardware AVC encoder)"
                                    } else {
                                        "Unavailable (Rust runtime failed to load)"
                                    },
                                    "hardwareAccelerated" to hardwareTranscoderReady,
                                    "videoEncoders" to List(encoders.length()) { index ->
                                        encoders.getString(index)
                                    },
                                    "videoDecoders" to List(decoders.length()) { index ->
                                        decoders.getString(index)
                                    },
                                    "ffmpegAvailable" to false,
                                    "ytdlpAvailable" to false,
                                    "nativeRuntimeLoaded" to rustLibLoaded,
                                )
                            )
                        } catch (error: Exception) {
                            result.error(
                                "CAPABILITY_PROBE_FAILED",
                                "MediaCodec capability probe failed",
                                error.message,
                            )
                        }
                    }

                    "saveToDownloads" -> {
                        val srcPath = call.argument<String>("srcPath")
                        val fileName = call.argument<String>("fileName")
                        val mimeType = call.argument<String>("mimeType") ?: "video/mp4"
                        val subDir = call.argument<String>("subDir") ?: "Segmeris"

                        if (srcPath == null || fileName == null) {
                            result.error("INVALID_ARGS", "srcPath and fileName are required", null)
                            return@setMethodCallHandler
                        }

                        ioQueue.submit(result, "SAVE_FAILED") {
                            MediaStoreHelper.saveToDownloads(appContext, srcPath, fileName, mimeType, subDir)
                                ?: throw IOException("Failed to save file to Downloads")
                        }
                    }

                    "saveToPath" -> {
                        val srcPath = call.argument<String>("srcPath")
                        val destDir = call.argument<String>("destDir")
                        val fileName = call.argument<String>("fileName")

                        if (srcPath == null || destDir == null || fileName == null) {
                            result.error("INVALID_ARGS", "srcPath, destDir and fileName are required", null)
                            return@setMethodCallHandler
                        }

                        ioQueue.submit(result, "SAVE_FAILED") {
                            MediaStoreHelper.saveToPath(appContext, srcPath, destDir, fileName)
                                ?: throw IOException("Failed to save file")
                        }
                    }

                    "deleteDownloadedFile" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "path is required", null)
                            return@setMethodCallHandler
                        }
                        ioQueue.submit(result, "DELETE_FAILED") {
                            MediaStoreHelper.deleteDownloadedFile(appContext, path)
                        }
                    }

                    "getAppExternalFilesDir" -> {
                        val dir = applicationContext.getExternalFilesDir(null)
                        result.success(dir?.absolutePath ?: applicationContext.filesDir.absolutePath)
                    }

                    "getDefaultDownloadDir" -> {
                        @Suppress("DEPRECATION")
                        val dl = Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_DOWNLOADS
                        )
                        result.success(dl.absolutePath)
                    }

                    // ── Foreground service ──
                    "startForegroundService" -> {
                        DownloadForegroundService.start(applicationContext)
                        result.success(true)
                    }
                    "stopForegroundService" -> {
                        DownloadForegroundService.stop(applicationContext)
                        result.success(true)
                    }
                    "updateServiceProgress" -> {
                        val progress = call.argument<Int>("progress") ?: 0
                        val status = call.argument<String>("status") ?: ""
                        DownloadForegroundService.updateProgress(applicationContext, progress, status)
                        result.success(true)
                    }

                    // ── Battery optimization ──
                    "isIgnoringBatteryOptimizations" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val pm = getSystemService(POWER_SERVICE) as PowerManager
                            result.success(pm.isIgnoringBatteryOptimizations(packageName))
                        } else {
                            result.success(true)
                        }
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                data = Uri.parse("package:$packageName")
                            }
                            startActivity(intent)
                            result.success(true)
                        } else {
                            result.success(true)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        closeFileIo()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        closeFileIo()
        super.onDestroy()
    }

    private fun closeFileIo() {
        mediaChannel?.setMethodCallHandler(null)
        mediaChannel = null
        fileIo?.close()
        fileIo = null
    }
}

/** One worker and a finite waiting queue; saturation must never run I/O on the caller. */
internal class MediaStoreIoQueue(
    queueCapacity: Int = 8,
    private val postToMain: (Runnable) -> Unit
) {
    private val executor = ThreadPoolExecutor(
        1, 1, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(queueCapacity),
        { task -> Thread(task, "segmeris-file-io") }, ThreadPoolExecutor.AbortPolicy()
    )

    fun submit(result: MethodChannel.Result, errorCode: String, operation: () -> Any?) {
        val task = IoTask(result, errorCode, operation)
        try {
            executor.execute(task)
        } catch (_: RejectedExecutionException) {
            task.fail(
                if (executor.isShutdown) "IO_CANCELLED" else "IO_BUSY",
                if (executor.isShutdown) "File I/O is closed" else "Too many pending file operations"
            )
        }
    }

    fun close() {
        executor.shutdownNow().forEach { (it as IoTask).fail("IO_CANCELLED", "File I/O is closed") }
    }

    private inner class IoTask(
        private val result: MethodChannel.Result,
        private val errorCode: String,
        private val operation: () -> Any?
    ) : Runnable {
        private val replied = AtomicBoolean(false)

        override fun run() {
            try {
                if (Thread.currentThread().isInterrupted) throw InterruptedIOException("File operation cancelled")
                val value = operation()
                reply { result.success(value) }
            } catch (error: Exception) {
                val code = when (error) {
                    is InterruptedIOException, is InterruptedException -> "IO_CANCELLED"
                    is IllegalArgumentException -> "INVALID_ARGS"
                    is SecurityException -> "PERMISSION_DENIED"
                    else -> errorCode
                }
                fail(code, error.message ?: "File operation failed", error.suppressed.map { it.toString() })
            }
        }

        fun fail(code: String, message: String, details: Any? = null) {
            reply { result.error(code, message, details) }
        }

        private fun reply(callback: () -> Unit) {
            if (replied.compareAndSet(false, true)) postToMain(Runnable { callback() })
        }
    }
}
