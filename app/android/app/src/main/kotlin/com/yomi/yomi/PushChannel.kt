package com.yomi.yomi

import android.util.Log
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

private const val PUSH_CHANNEL = "yomi/push"

/**
 * Hands this phone's Firebase push token to Dart, which gives it to the Yomi server.
 * Without google-services.json Firebase isn't set up and the call quietly does nothing.
 */
class PushChannel(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, PUSH_CHANNEL)

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "register") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            fetchToken()
            result.success(null)
        }
    }

    private fun fetchToken() {
        try {
            FirebaseMessaging.getInstance().token.addOnSuccessListener { token ->
                channel.invokeMethod("token", mapOf("token" to token, "environment" to "android"))
            }.addOnFailureListener { error ->
                Log.w("YomiPush", "Could not get a push token", error)
            }
        } catch (error: IllegalStateException) {
            Log.w("YomiPush", "Firebase isn't set up in this build", error)
        }
    }
}
