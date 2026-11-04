package com.yomi.yomi

import android.os.Handler
import android.os.Looper
import bridge.Bridge
import bridge.InterfaceSource
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.NetworkInterface
import java.util.concurrent.Executors

private const val TUNNEL_CHANNEL = "com.yomi.yomi/tunnel"

/** Runs the embedded Tailscale node off the main thread; joining can take many seconds. */
class TunnelChannel(messenger: BinaryMessenger) {
    private val worker = Executors.newSingleThreadExecutor()
    private val mainThread = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, TUNNEL_CHANNEL).setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        worker.execute {
            try {
                val value = run(call)
                mainThread.post { result.success(value) }
            } catch (error: UnsatisfiedLinkError) {
                // Devices with a processor the bridge wasn't built for, such as x86 emulators.
                mainThread.post { result.error("unsupported", error.message, null) }
            } catch (error: Exception) {
                mainThread.post { result.error("tunnel", error.message, null) }
            }
        }
    }

    private fun run(call: MethodCall): Any? = when (call.method) {
        "start" -> {
            Bridge.setInterfaceSource(DeviceInterfaces)
            Bridge.start(
                call.argument<String>("stateDir"),
                call.argument<String>("authKey").orEmpty(),
                call.argument<String>("hostname"),
            )
            null
        }
        "forward" -> Bridge.forward(call.argument<String>("remote")).toInt()
        "state" -> Bridge.state()
        "stop" -> {
            Bridge.stop()
            null
        }
        else -> throw IllegalArgumentException("Unknown call ${call.method}")
    }
}

/** Android 11+ stops Go listing network interfaces, but Java still can. */
private object DeviceInterfaces : InterfaceSource {
    override fun interfaces(): String {
        val all = NetworkInterface.getNetworkInterfaces() ?: return ""
        return all.toList().joinToString("\n") { device ->
            val flags = buildString {
                if (device.isUp) append('u')
                if (device.isLoopback) append('l')
                if (device.isPointToPoint) append('p')
                if (device.supportsMulticast()) append('m')
            }
            val addresses = device.interfaceAddresses.joinToString(";") { entry ->
                val host = entry.address.hostAddress.orEmpty().substringBefore('%')
                "$host/${entry.networkPrefixLength}"
            }
            "${device.name},${device.index},${device.mtu},$flags,$addresses"
        }
    }
}
