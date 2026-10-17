package com.algoramming.flutter_esc_pos_usb_universal

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Android: USB printers through Android's USB host API. Android has no driver
 * for USB printers, so the app opens the printer-class interface itself and
 * writes to its bulk OUT endpoint. Android asks the user once per printer
 * whether the app may use it ("requestPermission").
 *
 * Errors carry the package's codes: notFound, busy, permissionDenied, timeout,
 * ioError, notConnected.
 */
class FlutterEscPosUsbUniversalPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var usbManager: UsbManager

    /** Blocking USB calls run here, never on the main thread. */
    private val executor: ExecutorService = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())

    private class Session(
        val device: UsbDevice,
        val connection: UsbDeviceConnection,
        val usbInterface: UsbInterface,
        val endpoint: UsbEndpoint,
    )

    private val sessions = ConcurrentHashMap<Int, Session>()
    private val nextHandle = AtomicInteger(1)

    /** Permission requests waiting for the user's answer, by device name. */
    private val pendingPermissions = ConcurrentHashMap<String, MutableList<Result>>()
    private var permissionReceiver: BroadcastReceiver? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        for (handle in sessions.keys.toList()) closeSession(handle)
        permissionReceiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
            }
        }
        permissionReceiver = null
        for (results in pendingPermissions.values) results.forEach { it.success(false) }
        pendingPermissions.clear()
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "list" -> background(result) { list() }
            "requestPermission" -> requestPermission(call.argument<String>("deviceName") ?: "", result)
            "open" -> background(result) { open(call.argument<String>("deviceName") ?: "") }
            "write" -> {
                val handle = call.argument<Int>("handle") ?: 0
                val data = call.argument<ByteArray>("data") ?: ByteArray(0)
                val chunkSize = call.argument<Int>("chunkSize") ?: DEFAULT_CHUNK
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 10000
                background(result) { write(handle, data, chunkSize, timeoutMs) }
            }
            "close" -> {
                closeSession(call.argument<Int>("handle") ?: 0)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ── Listing ──────────────────────────────────────────────────────────────

    private fun list(): List<Map<String, Any?>> {
        val open = sessions.values.map { it.device.deviceName }.toSet()
        val printers = mutableListOf<Map<String, Any?>>()
        for (device in usbManager.deviceList.values) {
            val target = printerInterface(device) ?: continue
            val permitted = usbManager.hasPermission(device)
            // Android 10+ hides the serial number until the app may use the device.
            val serial = if (permitted) {
                try {
                    device.serialNumber
                } catch (_: SecurityException) {
                    null
                }
            } else {
                null
            }
            var ieee1284: ByteArray? = null
            var busy = false
            // The 1284 Device ID needs the device open; never while this app
            // prints on it (a second claim would fail and look like "busy").
            if (permitted && device.deviceName !in open) {
                val connection = usbManager.openDevice(device)
                if (connection == null) {
                    busy = true
                } else {
                    try {
                        if (connection.claimInterface(target.first, true)) {
                            ieee1284 = read1284(connection, target.first)
                            connection.releaseInterface(target.first)
                        } else {
                            busy = true
                        }
                    } finally {
                        connection.close()
                    }
                }
            }
            printers.add(
                mapOf(
                    "deviceName" to device.deviceName,
                    "vendorId" to device.vendorId,
                    "productId" to device.productId,
                    "manufacturerName" to device.manufacturerName,
                    "productName" to device.productName,
                    "serialNumber" to serial,
                    "interfaceNumber" to target.first.id,
                    "hasPermission" to permitted,
                    "ieee1284" to ieee1284,
                    "busy" to busy,
                ),
            )
        }
        return printers
    }

    /** The first printer-class (07) interface with a bulk OUT endpoint. */
    private fun printerInterface(device: UsbDevice): Pair<UsbInterface, UsbEndpoint>? {
        for (i in 0 until device.interfaceCount) {
            val usbInterface = device.getInterface(i)
            if (usbInterface.interfaceClass != UsbConstants.USB_CLASS_PRINTER) continue
            for (e in 0 until usbInterface.endpointCount) {
                val endpoint = usbInterface.getEndpoint(e)
                if (endpoint.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                    endpoint.direction == UsbConstants.USB_DIR_OUT
                ) {
                    return usbInterface to endpoint
                }
            }
        }
        return null
    }

    /** GET_DEVICE_ID, the printer class request. The raw reply; Dart decodes it. */
    private fun read1284(connection: UsbDeviceConnection, usbInterface: UsbInterface): ByteArray? {
        val buffer = ByteArray(1024)
        val index = (usbInterface.id shl 8) or usbInterface.alternateSetting
        val got = connection.controlTransfer(0xA1, 0, 0, index, buffer, 1023, 2000)
        return if (got > 2) buffer.copyOf(got) else null
    }

    // ── Permission ───────────────────────────────────────────────────────────

    private fun requestPermission(deviceName: String, result: Result) {
        val device = usbManager.deviceList[deviceName]
        if (device == null) {
            result.error("notFound", "The USB printer is not connected", null)
            return
        }
        if (usbManager.hasPermission(device)) {
            result.success(true)
            return
        }
        val waiting = pendingPermissions.getOrPut(deviceName) { mutableListOf() }
        synchronized(waiting) {
            waiting.add(result)
            // One system dialog per printer, however many callers wait for it.
            if (waiting.size > 1) return
        }
        ensurePermissionReceiver()
        // Explicit (this app's package) and immutable, as Android 12+ requires.
        // The answer is read back with hasPermission(), so the system does not
        // need to add extras to the intent.
        val intent = Intent(ACTION_USB_PERMISSION)
            .setPackage(context.packageName)
            .putExtra(EXTRA_DEVICE_NAME, deviceName)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val pending = PendingIntent.getBroadcast(context, deviceName.hashCode(), intent, flags)
        try {
            usbManager.requestPermission(device, pending)
        } catch (e: Exception) {
            finishPermission(deviceName, false)
        }
    }

    private fun ensurePermissionReceiver() {
        if (permissionReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != ACTION_USB_PERMISSION) return
                val deviceName = intent.getStringExtra(EXTRA_DEVICE_NAME) ?: return
                val device = usbManager.deviceList[deviceName]
                finishPermission(deviceName, device != null && usbManager.hasPermission(device))
            }
        }
        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
        permissionReceiver = receiver
    }

    private fun finishPermission(deviceName: String, granted: Boolean) {
        val waiting = pendingPermissions.remove(deviceName) ?: return
        val results = synchronized(waiting) { waiting.toList() }
        main.post { results.forEach { it.success(granted) } }
    }

    // ── Opening and writing ──────────────────────────────────────────────────

    private fun open(deviceName: String): Int {
        val device = usbManager.deviceList[deviceName]
            ?: throw UsbFailure("notFound", "The USB printer is not connected")
        if (!usbManager.hasPermission(device)) {
            throw UsbFailure("permissionDenied", "Android did not allow this app to use the USB printer")
        }
        val (usbInterface, endpoint) = printerInterface(device)
            ?: throw UsbFailure("unsupported", "The device has no printer interface")
        val connection = usbManager.openDevice(device)
            ?: throw UsbFailure("busy", "Could not open the USB printer; another app may be using it")
        // force: detach a kernel driver, should the device's kernel have one.
        if (!connection.claimInterface(usbInterface, true)) {
            connection.close()
            throw UsbFailure("busy", "Another app is using the USB printer")
        }
        val handle = nextHandle.getAndIncrement()
        sessions[handle] = Session(device, connection, usbInterface, endpoint)
        return handle
    }

    /**
     * Writes [data] in pieces. Each piece must be taken within [timeoutMs]:
     * a printer that is out of paper, has its cover open or is switched off
     * stops taking data, and the write fails instead of waiting forever.
     */
    private fun write(handle: Int, data: ByteArray, chunkSize: Int, timeoutMs: Int): Int {
        val session = sessions[handle] ?: throw UsbFailure("notConnected", "The USB printer is not open")
        // Android before 9 moved at most 16 kB per bulk transfer.
        val chunk = chunkSize.coerceIn(64, DEFAULT_CHUNK)
        var offset = 0
        while (offset < data.size) {
            val length = minOf(chunk, data.size - offset)
            val started = SystemClock.elapsedRealtime()
            val sent = session.connection.bulkTransfer(session.endpoint, data, offset, length, timeoutMs)
            if (sent > 0) {
                offset += sent
                continue
            }
            if (usbManager.deviceList[session.device.deviceName] == null) {
                throw UsbFailure("notFound", "The USB printer was unplugged")
            }
            if (SystemClock.elapsedRealtime() - started >= timeoutMs - 50) {
                throw UsbFailure(
                    "timeout",
                    "The printer did not take the data in time. Check that it has paper, the cover is closed and it is online.",
                )
            }
            throw UsbFailure("ioError", "The printer did not take the data")
        }
        return offset
    }

    private fun closeSession(handle: Int) {
        val session = sessions.remove(handle) ?: return
        try {
            session.connection.releaseInterface(session.usbInterface)
        } catch (_: Exception) {
        }
        session.connection.close()
    }

    // ── Plumbing ─────────────────────────────────────────────────────────────

    private class UsbFailure(val code: String, message: String) : Exception(message)

    /** Runs [work] off the main thread and answers on it. */
    private fun background(result: Result, work: () -> Any?) {
        executor.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: UsbFailure) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: SecurityException) {
                main.post { result.error("permissionDenied", e.message ?: "Android did not allow USB access", null) }
            } catch (e: Exception) {
                main.post { result.error("ioError", e.message ?: e.toString(), null) }
            }
        }
    }

    companion object {
        private const val CHANNEL = "flutter_esc_pos_usb_universal"
        private const val ACTION_USB_PERMISSION = "com.algoramming.flutter_esc_pos_usb_universal.USB_PERMISSION"
        private const val EXTRA_DEVICE_NAME = "deviceName"
        private const val DEFAULT_CHUNK = 16 * 1024
    }
}
