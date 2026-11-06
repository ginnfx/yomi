package com.yomi.yomi

import android.content.ActivityNotFoundException
import android.content.Intent
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

private const val INSTALLER_CHANNEL = "com.yomi.yomi/installer"
private const val APK_MIME_TYPE = "application/vnd.android.package-archive"

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALLER_CHANNEL)
            .setMethodCallHandler(::handleInstallerCall)
        TunnelChannel(flutterEngine.dartExecutor.binaryMessenger)
        YtDlpChannel(flutterEngine.dartExecutor.binaryMessenger, this)
    }

    private fun handleInstallerCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "installApk") {
            result.notImplemented()
            return
        }
        val apk = call.argument<String>("path")?.let(::File)
        if (apk == null || !isDownloadedUpdate(apk)) {
            result.error("invalid_path", "Not a downloaded update", null)
            return
        }
        try {
            startActivity(installIntent(apk))
            result.success(null)
        } catch (error: ActivityNotFoundException) {
            result.error("no_installer", error.message, null)
        }
    }

    // Only files in the app's own update folder may reach the installer.
    private fun isDownloadedUpdate(file: File): Boolean {
        val updatesDir = File(cacheDir, "updates").canonicalFile
        return file.isFile && file.canonicalFile.parentFile == updatesDir
    }

    private fun installIntent(apk: File): Intent {
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
        return Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, APK_MIME_TYPE)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}
