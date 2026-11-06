package com.yomi.yomi

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLException
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executors

private const val YTDLP_CHANNEL = "com.yomi.yomi/ytdlp"
private const val TAG = "YtDlpChannel"

/**
 * Runs the yt-dlp bundled by youtubedl-android. Dart builds the arguments; each output
 * line goes back as a "line" call so downloads can show progress.
 */
class YtDlpChannel(messenger: BinaryMessenger, private val context: Context) {
    private val channel = MethodChannel(messenger, YTDLP_CHANNEL)
    private val worker = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var initError: String? = null

    @Volatile
    private var isReady = false

    init {
        channel.setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "run" -> run(call, result)
            "update" -> update(result)
            else -> result.notImplemented()
        }
    }

    @Synchronized
    private fun ensureReady(): Boolean {
        if (isReady) return true
        return try {
            YoutubeDL.getInstance().init(context.applicationContext)
            isReady = true
            true
        } catch (error: Throwable) {
            Log.e(TAG, "init failed", error)
            initError = error.message ?: "yt-dlp could not start"
            false
        }
    }

    private fun run(call: MethodCall, result: MethodChannel.Result) {
        val args = call.argument<List<String>>("args")
        val job = call.argument<String>("job") ?: UUID.randomUUID().toString()
        if (args == null) {
            result.error("bad_args", "No arguments", null)
            return
        }
        worker.execute {
            if (!ensureReady()) {
                main.post { result.error("unavailable", initError, null) }
                return@execute
            }
            try {
                val request = YoutubeDLRequest(emptyList<String>()).addCommands(args)
                val response = YoutubeDL.getInstance().execute(request, job) { _, _, line ->
                    main.post { channel.invokeMethod("line", mapOf("job" to job, "line" to line)) }
                }
                main.post { result.success(response.out) }
            } catch (error: YoutubeDLException) {
                Log.w(TAG, "yt-dlp failed", error)
                main.post { result.error("failed", lastLine(error.message), null) }
            } catch (error: InterruptedException) {
                main.post { result.error("failed", "Stopped", null) }
            } catch (error: YoutubeDL.CanceledException) {
                main.post { result.error("failed", "Canceled", null) }
            } catch (error: Throwable) {
                // Anything else must still answer Dart, or the caller waits forever.
                Log.e(TAG, "yt-dlp crashed", error)
                main.post { result.error("failed", error.message ?: "yt-dlp crashed", null) }
            }
        }
    }

    private fun update(result: MethodChannel.Result) {
        worker.execute {
            if (!ensureReady()) {
                main.post { result.success(null) }
                return@execute
            }
            try {
                val status = YoutubeDL.getInstance().updateYoutubeDL(context.applicationContext)
                main.post { result.success(status?.name) }
            } catch (error: Throwable) {
                Log.w(TAG, "update failed", error)
                main.post { result.success(null) }
            }
        }
    }

    private fun lastLine(message: String?): String =
        message?.lines()?.lastOrNull { it.isNotBlank() }?.trim() ?: "yt-dlp failed"
}
