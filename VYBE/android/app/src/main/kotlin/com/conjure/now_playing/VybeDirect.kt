package com.conjure.now_playing

import android.Manifest
import android.app.Activity
import android.content.*
import android.content.pm.PackageManager
import android.net.wifi.p2p.*
import android.net.wifi.WpsInfo
import android.os.Build
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/** Android 9+ Wi-Fi Direct connection path. Receiver owns the P2P group and TCP server. */
class VybeDirect(private val activity: Activity, private val channel: MethodChannel) {
    private val manager = activity.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    private val p2pChannel = manager?.initialize(activity, Looper.getMainLooper(), null)
    private var registered = false
    private var peers: List<WifiP2pDevice> = emptyList()
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> refreshPeers()
                WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                    if (!permitted()) return
                    manager?.requestConnectionInfo(p2pChannel!!) { info ->
                        if (info.groupFormed && info.groupOwnerAddress != null) {
                            event(mapOf("type" to "connected", "host" to info.groupOwnerAddress.hostAddress,
                                "owner" to info.isGroupOwner))
                        } else event(mapOf("type" to "disconnected"))
                    }
                }
                WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                    val state = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                    event(mapOf("type" to "state", "enabled" to (state == WifiP2pManager.WIFI_P2P_STATE_ENABLED)))
                }
            }
        }
    }
    private fun event(value: Map<String, Any?>) { activity.runOnUiThread { channel.invokeMethod("event", value) } }
    private fun permitted(): Boolean {
        val permission = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION
        return activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }
    fun permission(): String = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION
    fun available(): Boolean = manager != null && p2pChannel != null &&
        activity.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)
    fun start(): Boolean {
        if (!available() || !permitted()) return false
        if (!registered) {
            val filter = IntentFilter().apply {
                addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
                addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
                addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            }
            activity.registerReceiver(receiver, filter)
            registered = true
        }
        return true
    }
    private fun action(name: String, invoke: (WifiP2pManager.ActionListener) -> Unit) {
        invoke(object : WifiP2pManager.ActionListener {
            override fun onSuccess() { event(mapOf("type" to "action", "name" to name, "ok" to true)) }
            override fun onFailure(reason: Int) { event(mapOf("type" to "error", "message" to "$name failed ($reason)")) }
        })
    }
    fun host(): Boolean {
        if (!start()) return false
        action("host") { manager!!.createGroup(p2pChannel!!, it) }
        return true
    }
    fun discover(): Boolean {
        if (!start()) return false
        action("discover") { manager!!.discoverPeers(p2pChannel!!, it) }
        refreshPeers()
        return true
    }
    private fun refreshPeers() {
        if (!permitted()) return
        manager?.requestPeers(p2pChannel!!) { list ->
            peers = list.deviceList.toList()
            event(mapOf("type" to "peers", "items" to peers.map { mapOf("name" to (it.deviceName ?: "Android device"), "address" to it.deviceAddress) }))
        }
    }
    fun connect(address: String): Boolean {
        if (!start()) return false
        if (peers.none { it.deviceAddress == address }) return false
        val config = WifiP2pConfig().apply { deviceAddress = address; wps.setup = WpsInfo.PBC; groupOwnerIntent = 0 }
        action("connect") { manager!!.connect(p2pChannel!!, config, it) }
        return true
    }
    fun stop() {
        if (registered) { try { activity.unregisterReceiver(receiver) } catch (_: Exception) {} ; registered = false }
    }
}
