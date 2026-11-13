package com.conjure.now_playing

import android.Manifest
import android.app.Activity
import android.content.*
import android.content.pm.PackageManager
import android.net.wifi.p2p.*
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.net.wifi.p2p.nsd.WifiP2pServiceRequest
import android.net.wifi.WpsInfo
import android.os.Build
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * VYBE-specific Wi-Fi Direct discovery.
 *
 * Never show raw nearby Wi-Fi Direct devices. The head unit advertises a
 * DNS-SD service with VYBE's protocol marker and its persistent receiver ID.
 * The phone displays ONLY peers returning a matching service TXT record.
 *
 * An advertisement is a discovery hint, not cryptographic authentication.
 * VYBE Connect's TCP hello subsequently checks the paired receiver identity.
 */
class VybeDirect(private val activity: Activity, private val channel: MethodChannel) {
    companion object {
        private const val INSTANCE_NAME = "VYBE-Receiver"
        private const val SERVICE_TYPE = "_vybe-link._tcp"
        private const val APP_MARKER = "vybe"
        private const val PROTOCOL_VERSION = "2"
    }

    private val manager = activity.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    private val p2pChannel = manager?.initialize(activity, Looper.getMainLooper(), null)
    private var registered = false
    private var advertised = false
    private var advertisingPending = false
    private var localService: WifiP2pDnsSdServiceInfo? = null
    private var localServiceId = ""
    private var serviceRequest: WifiP2pServiceRequest? = null
    private var discoveryPending = false
    private var listenersInstalled = false

    // Device addresses can rotate between reconnections. The receiver's
    // published VYBE ID is the more stable identifier.
    private val verifiedReceivers = linkedMapOf<String, Map<String, String>>()
    private var hostPending = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                // The generic PEERS_CHANGED broadcast is deliberately NOT
                // shown in VYBE. Printers and unrelated Androids stay hidden.
                WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                    if (!permitted()) return
                    val service = manager ?: return
                    val ch = p2pChannel ?: return
                    service.requestConnectionInfo(ch) { info ->
                        if (info.groupFormed && info.groupOwnerAddress != null) {
                            event(mapOf(
                                "type" to "connected",
                                "host" to info.groupOwnerAddress.hostAddress,
                                "owner" to info.isGroupOwner))
                        } else {
                            event(mapOf("type" to "disconnected"))
                        }
                    }
                }
                WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                    val state = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                    event(mapOf("type" to "state",
                        "enabled" to (state == WifiP2pManager.WIFI_P2P_STATE_ENABLED)))
                }
            }
        }
    }

    private fun event(value: Map<String, Any?>) {
        activity.runOnUiThread { channel.invokeMethod("event", value) }
    }

    private fun permitted(): Boolean {
        val permission = if (Build.VERSION.SDK_INT >= 33)
            Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION
        return activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    fun permission(): String = if (Build.VERSION.SDK_INT >= 33)
        Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION

    fun available(): Boolean =
        manager != null && p2pChannel != null &&
        activity.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)

    fun start(): Boolean {
        if (!available() || !permitted()) return false
        if (!registered) {
            val filter = IntentFilter().apply {
                addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
                addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            }
            activity.registerReceiver(receiver, filter)
            registered = true
        }
        // Android may have kept the P2P group after an app restart.
        manager?.requestConnectionInfo(p2pChannel!!) { info ->
            if (info.groupFormed && info.groupOwnerAddress != null) {
                event(mapOf("type" to "connected",
                    "host" to info.groupOwnerAddress.hostAddress,
                    "owner" to info.isGroupOwner))
            }
        }
        return true
    }

    private fun action(name: String, invoke: (WifiP2pManager.ActionListener) -> Unit) {
        invoke(object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                event(mapOf("type" to "action", "name" to name, "ok" to true))
            }
            override fun onFailure(reason: Int) {
                event(mapOf("type" to "error",
                    "message" to "$name failed ($reason)"))
            }
        })
    }

    /**
     * Called only in the receiver/head-unit role. Do NOT advertise VYBE on
     * every Android with the app installed; phones should not appear as
     * selectable head units.
     */
    private fun advertiseReceiver(receiverId: String) {
        val service = manager ?: return
        val ch = p2pChannel ?: return
        if (!receiverId.matches(Regex("[0-9a-fA-F]{32}"))) {
            event(mapOf("type" to "error",
                "message" to "VYBE receiver identity unavailable; reopen Connect"))
            return
        }
        if ((advertised || advertisingPending) && receiverId == localServiceId) return

        // If the ID changes (e.g. reinstall), retire only OUR advertisement.
        val previous = localService
        if (previous != null && localServiceId != receiverId) {
            service.removeLocalService(ch, previous, null)
            localService = null
            advertised = false
        }

        localServiceId = receiverId
        val info = WifiP2pDnsSdServiceInfo.newInstance(
            INSTANCE_NAME, SERVICE_TYPE, mapOf(
                "app" to APP_MARKER,
                "role" to "receiver",
                "v" to PROTOCOL_VERSION,
                "id" to receiverId.lowercase(),
                "port" to "38927"))
        advertisingPending = true
        service.addLocalService(ch, info, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                advertisingPending = false
                advertised = true
                localService = info
                event(mapOf("type" to "status",
                    "message" to "VYBE Head Unit visible to VYBE devices"))
            }
            override fun onFailure(reason: Int) {
                advertisingPending = false
                advertised = false
                event(mapOf("type" to "error",
                    "message" to "Could not advertise VYBE receiver ($reason); shared Wi-Fi remains available"))
            }
        })
    }

    private fun publishVerifiedReceivers() {
        event(mapOf("type" to "peers",
            "items" to verifiedReceivers.values.toList(),
            "verified" to true))
    }

    private fun installServiceResponseListeners() {
        if (listenersInstalled) return
        val service = manager ?: return
        val ch = p2pChannel ?: return
        service.setDnsSdResponseListeners(ch,
            WifiP2pManager.DnsSdServiceResponseListener { instance, serviceType, device ->
                // PTR responses aren't enough for pairing. Wait for our
                // marker and stable ID in the DNS-SD TXT record.
                if (instance == INSTANCE_NAME &&
                    serviceType.contains(SERVICE_TYPE, ignoreCase = true)) {
                    event(mapOf("type" to "status",
                        "message" to "Checking nearby VYBE receiver identity..."))
                }
            },
            WifiP2pManager.DnsSdTxtRecordListener { domain, record, device ->
                val validDomain = domain.lowercase()
                    .contains("._vybe-link._tcp.")
                val receiverId = record["id"] ?: ""
                val valid = validDomain &&
                    record["app"] == APP_MARKER &&
                    record["role"] == "receiver" &&
                    record["v"] == PROTOCOL_VERSION &&
                    record["port"] == "38927" &&
                    receiverId.matches(Regex("[0-9a-fA-F]{32}"))
                if (!valid || device.deviceAddress.isNullOrBlank()) return@DnsSdTxtRecordListener
                val key = device.deviceAddress
                val id = receiverId.lowercase()
                verifiedReceivers[key] = mapOf(
                    "address" to key,
                    "id" to id,
                    "name" to "VYBE Head Unit · ${id.takeLast(6).uppercase()}")
                publishVerifiedReceivers()
            })
        listenersInstalled = true
    }

    /** Discover only branded VYBE head units, not generic P2P neighbors. */
    fun discover(): Boolean {
        if (!start()) return false
        val service = manager ?: return false
        val ch = p2pChannel ?: return false
        installServiceResponseListeners()
        verifiedReceivers.clear()
        publishVerifiedReceivers()
        event(mapOf("type" to "status",
            "message" to "Searching for VYBE head units (other devices hidden)..."))
        if (discoveryPending) return true
        discoveryPending = true

        fun launchDiscovery() {
            service.discoverServices(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    discoveryPending = false
                    event(mapOf("type" to "status",
                        "message" to "Scanning for VYBE receiver advertisements..."))
                }
                override fun onFailure(reason: Int) {
                    discoveryPending = false
                    event(mapOf("type" to "error",
                        "message" to "VYBE-only discovery failed ($reason). You can pair through shared Wi-Fi instead."))
                }
            })
        }

        if (serviceRequest != null) {
            launchDiscovery()
        } else {
            // Restricted to VYBE's exact DNS-SD TXT service. No generic
            // peer list and no automatic connections to unnamed devices.
            val request = WifiP2pDnsSdServiceRequest.newInstance(
                INSTANCE_NAME, SERVICE_TYPE)
            service.addServiceRequest(ch, request, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    serviceRequest = request
                    launchDiscovery()
                }
                override fun onFailure(reason: Int) {
                    discoveryPending = false
                    event(mapOf("type" to "error",
                        "message" to "Cannot start VYBE service discovery ($reason)"))
                }
            })
        }
        return true
    }

    private fun retryHostAfterDiscovery() {
        android.os.Handler(Looper.getMainLooper()).postDelayed({
            beginHost(false)
        }, 1000L)
    }

    private fun reportGroupReady(service: WifiP2pManager, ch: WifiP2pManager.Channel) {
        hostPending = false
        event(mapOf("type" to "action", "name" to "host", "ok" to true))
        service.requestConnectionInfo(ch) { info ->
            if (info.groupFormed && info.groupOwnerAddress != null) {
                event(mapOf("type" to "connected",
                    "host" to info.groupOwnerAddress.hostAddress,
                    "owner" to info.isGroupOwner))
            }
        }
    }

    private fun beginHost(allowRetry: Boolean) {
        val service = manager ?: return
        val ch = p2pChannel ?: return
        service.requestGroupInfo(ch) { group ->
            if (group?.isGroupOwner == true) {
                reportGroupReady(service, ch)
            } else if (group != null) {
                hostPending = false
                event(mapOf("type" to "error",
                    "message" to "Already connected to another Wi-Fi Direct group"))
            } else {
                service.createGroup(ch, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        reportGroupReady(service, ch)
                    }
                    override fun onFailure(reason: Int) {
                        if (reason == WifiP2pManager.BUSY && allowRetry) {
                            event(mapOf("type" to "status",
                                "message" to "Wi-Fi Direct busy; retrying group creation"))
                            service.stopPeerDiscovery(ch, object : WifiP2pManager.ActionListener {
                                override fun onSuccess() { retryHostAfterDiscovery() }
                                override fun onFailure(reason: Int) { retryHostAfterDiscovery() }
                            })
                        } else {
                            hostPending = false
                            val message = if (reason == WifiP2pManager.BUSY)
                                "Wi-Fi Direct busy; use shared Wi-Fi as an alternative"
                            else "Wi-Fi Direct group creation failed ($reason)"
                            event(mapOf("type" to "error", "message" to message))
                        }
                    }
                })
            }
        }
    }

    fun host(receiverId: String): Boolean {
        if (!start()) return false
        advertiseReceiver(receiverId)
        if (hostPending) return true
        hostPending = true
        beginHost(true)
        return true
    }

    fun connect(address: String): Boolean {
        if (!start()) return false
        // Never accept a raw peer address from Android's generic P2P list.
        // The chosen device must currently advertise the VYBE service.
        if (!verifiedReceivers.containsKey(address)) {
            event(mapOf("type" to "error",
                "message" to "Device has not advertised a VYBE receiver service"))
            return false
        }
        val config = WifiP2pConfig().apply {
            deviceAddress = address
            wps.setup = WpsInfo.PBC
            groupOwnerIntent = 0
        }
        action("connect") { manager!!.connect(p2pChannel!!, config, it) }
        return true
    }

    fun stop() {
        if (registered) {
            try { activity.unregisterReceiver(receiver) } catch (_: Exception) {}
            registered = false
        }
        serviceRequest?.let { req ->
            try { manager?.removeServiceRequest(p2pChannel!!, req, null) }
            catch (_: Exception) {}
        }
        serviceRequest = null
        localService?.let { info ->
            try { manager?.removeLocalService(p2pChannel!!, info, null) }
            catch (_: Exception) {}
        }
        localService = null
        advertised = false
        advertisingPending = false
        discoveryPending = false
        listenersInstalled = false
        verifiedReceivers.clear()
    }
}
