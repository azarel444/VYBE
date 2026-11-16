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
import android.os.Handler
import android.os.SystemClock
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
    // Android can drop the underlying P2P framework channel without a Wi-Fi
    // radio broadcast. A permanently-held null-listener channel required an
    // app force-close to recover. Recreate it and all per-channel state.
    private var p2pChannel: WifiP2pManager.Channel? = createP2pChannel()
    private var registered = false
    private var advertised = false
    private var advertisingPending = false
    private var advertisementRemovalPending = false
    private var localService: WifiP2pDnsSdServiceInfo? = null
    private var localServiceId = ""
    private var advertisingGeneration = 0
    private var advertisingFailures = 0
    private var serviceRequest: WifiP2pServiceRequest? = null
    private var discoveryPending = false
    private var discoveryGeneration = 0
    private var lastDiscoveryStartedMs = 0L
    private var listenersInstalled = false

    // Device addresses can rotate between reconnections. The receiver's
    // published VYBE ID is the more stable identifier.
    private val verifiedReceivers = linkedMapOf<String, Map<String, String>>()
    private val verifiedReceiverSeen = mutableMapOf<String, Long>()
    private var hostPending = false
    private var hostReadyChecks = 0
    private var pendingHostReceiverId = ""
    private val mainHandler = Handler(Looper.getMainLooper())
    private var connectingAddress: String? = null
    private var connectAttemptGeneration = 0
    private var resettingStaleGroup = false

    private fun createP2pChannel(): WifiP2pManager.Channel? {
        val service = manager ?: return null
        return service.initialize(activity, Looper.getMainLooper(),
            object : WifiP2pManager.ChannelListener {
                override fun onChannelDisconnected() {
                    p2pChannel = null
                    resettingStaleGroup = false
                    connectingAddress = null
                    connectAttemptGeneration++
                    hostPending = false
                    hostReadyChecks = 0
                    discoveryPending = false
                    discoveryGeneration++
                    lastDiscoveryStartedMs = 0L
                    serviceRequest = null
                    listenersInstalled = false
                    localService = null
                    advertised = false
                    advertisingPending = false
                    advertisementRemovalPending = false
                    advertisingGeneration++
                    verifiedReceivers.clear()
                    verifiedReceiverSeen.clear()
                    publishVerifiedReceivers()
                    event(mapOf("type" to "channel_reset",
                        "message" to "Android Wi-Fi Direct channel disconnected; reopening"))
                    mainHandler.postDelayed({
                        // Do not resurrect a channel after Activity disposal.
                        if (registered && p2pChannel == null) {
                            p2pChannel = createP2pChannel()
                            if (p2pChannel != null) {
                                event(mapOf("type" to "channel_recovered",
                                    "message" to "Wi-Fi Direct framework reconnected"))
                            }
                        }
                    }, 500L)
                }
            })
    }

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
                        if (info.groupFormed && resettingStaleGroup)
                            return@requestConnectionInfo
                        if (info.groupFormed && info.groupOwnerAddress != null) {
                            val requestedAddress = connectingAddress
                            if (requestedAddress != null) {
                                // Android may report an OLD, unrelated group
                                // while we're replacing it. Verify its owner
                                // is the selected VYBE device before accepting
                                // this broadcast as a completed pairing.
                                service.requestGroupInfo(ch) { group ->
                                    if (connectingAddress != requestedAddress)
                                        return@requestGroupInfo
                                    val actualOwner = group?.owner?.deviceAddress
                                    if (group?.isGroupOwner == false &&
                                        actualOwner?.equals(requestedAddress,
                                            ignoreCase = true) == true) {
                                        connectingAddress = null
                                        connectAttemptGeneration++
                                        event(mapOf(
                                            "type" to "connected",
                                            "host" to info.groupOwnerAddress.hostAddress,
                                            "owner" to false))
                                    } else {
                                        event(mapOf("type" to "pairing",
                                            "message" to "Waiting for selected head unit; existing P2P group is not its group"))
                                    }
                                }
                            } else {
                                hostPending = false
                                hostReadyChecks = 0
                                if (info.isGroupOwner &&
                                    pendingHostReceiverId.isNotEmpty()) {
                                    advertiseReceiver(pendingHostReceiverId)
                                }
                                // The Flutter side verifies the receiver's
                                // hello before reporting an app connection.
                                event(mapOf(
                                    "type" to "connected",
                                    "host" to info.groupOwnerAddress.hostAddress,
                                    "owner" to info.isGroupOwner))
                            }
                        } else if (connectingAddress != null) {
                            // Android can broadcast a disconnected state
                            // DURING initial group negotiation. This is not
                            // a failed pairing and must not trigger another
                            // simultaneous discover/connect cycle.
                            event(mapOf("type" to "pairing",
                                "message" to "Waiting for Android to form Wi-Fi Direct group..."))
                        } else {
                            // A receiver group that was previously ready may
                            // be silently destroyed by Android. Its earlier
                            // DNS-SD registration is no longer proof it is
                            // advertising on the new P2P session.
                            if (pendingHostReceiverId.isNotEmpty() && !hostPending) {
                                forgetReceiverAdvertisement()
                            }
                            event(mapOf("type" to "disconnected"))
                        }
                    }
                }
                WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                    val state = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                    if (state != WifiP2pManager.WIFI_P2P_STATE_ENABLED) {
                        connectingAddress = null
                        connectAttemptGeneration++
                        hostPending = false
                        hostReadyChecks = 0
                        discoveryPending = false
                        discoveryGeneration++
                        lastDiscoveryStartedMs = 0L
                        serviceRequest = null
                        forgetReceiverAdvertisement()
                        verifiedReceivers.clear()
                        verifiedReceiverSeen.clear()
                        publishVerifiedReceivers()
                    }
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
        // Android may keep a P2P group across app restarts. This is only
        // a ROUTE hint, not proof the group is with the chosen head unit;
        // Dart must verify the receiver's TCP hello before marking Connect up.
        val ch = p2pChannel ?: return false
        manager?.requestConnectionInfo(ch) { info ->
            if (info.groupFormed && info.groupOwnerAddress != null &&
                connectingAddress == null && !resettingStaleGroup) {
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
    private fun forgetReceiverAdvertisement(afterRemoval: (() -> Unit)? = null) {
        val generation = ++advertisingGeneration
        val previous = localService
        localService = null
        advertised = false
        advertisingPending = false
        advertisingFailures = 0
        advertisementRemovalPending = previous != null
        if (previous != null) {
            val service = manager
            val ch = p2pChannel
            if (service != null && ch != null) {
                // removeLocalService is ASYNCHRONOUS. Adding the same service
                // before this callback finishes produced a radio ERROR/BUSY
                // and head units that appeared but refused first tap.
                try {
                    service.removeLocalService(ch, previous,
                        object : WifiP2pManager.ActionListener {
                            override fun onSuccess() {
                                if (generation == advertisingGeneration) {
                                    advertisementRemovalPending = false
                                    afterRemoval?.invoke()
                                }
                            }
                            override fun onFailure(reason: Int) {
                                if (generation == advertisingGeneration) {
                                    advertisementRemovalPending = false
                                    afterRemoval?.invoke()
                                }
                            }
                        })
                    return
                } catch (_: Exception) {}
            }
        }
        if (generation == advertisingGeneration) {
            advertisementRemovalPending = false
            afterRemoval?.invoke()
        }
    }

    private fun advertiseReceiver(receiverId: String) {
        val service = manager ?: return
        val ch = p2pChannel ?: return
        if (!receiverId.matches(Regex("[0-9a-fA-F]{32}"))) {
            event(mapOf("type" to "error",
                "message" to "VYBE receiver identity unavailable; reopen Connect"))
            return
        }
        if (advertisementRemovalPending) return
        if ((advertised || advertisingPending) && receiverId == localServiceId) return

        // If the ID changes (e.g. reinstall), retire only OUR advertisement.
        val previous = localService
        if (previous != null && localServiceId != receiverId) {
            forgetReceiverAdvertisement { advertiseReceiver(receiverId) }
            return
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
        val generation = ++advertisingGeneration
        service.addLocalService(ch, info, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                if (generation != advertisingGeneration) return
                advertisingPending = false
                advertised = true
                advertisingFailures = 0
                localService = info
                event(mapOf("type" to "status",
                    "message" to "VYBE Head Unit visible to VYBE devices"))
            }
            override fun onFailure(reason: Int) {
                if (generation != advertisingGeneration) return
                advertisingPending = false
                advertised = false
                if (advertisingFailures < 2 &&
                    pendingHostReceiverId == receiverId &&
                    (reason == WifiP2pManager.ERROR ||
                     reason == WifiP2pManager.BUSY)) {
                    advertisingFailures++
                    event(mapOf("type" to "status",
                        "message" to "Android rejected VYBE advertisement ($reason); retrying once the group settles..."))
                    mainHandler.postDelayed({
                        if (generation == advertisingGeneration &&
                            pendingHostReceiverId == receiverId && !advertised &&
                            !advertisingPending) {
                            service.requestConnectionInfo(ch) { state ->
                                if (state.groupFormed && state.isGroupOwner &&
                                    pendingHostReceiverId == receiverId) {
                                    advertiseReceiver(receiverId)
                                }
                            }
                        }
                    }, 1200L * advertisingFailures)
                } else {
                    event(mapOf("type" to "error",
                        "message" to "Could not advertise VYBE receiver ($reason); use Set up head-unit Wi-Fi Direct again"))
                }
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
                val address = device.deviceAddress
                val id = receiverId.lowercase()
                // Key by stable VYBE identity, not a rotating Android MAC.
                // A new broadcast updates the same visible row in place.
                verifiedReceiverSeen[id] = SystemClock.elapsedRealtime()
                verifiedReceivers[id] = mapOf(
                    "address" to address,
                    "id" to id,
                    "name" to "VYBE Head Unit · ${id.takeLast(6).uppercase()}")
                publishVerifiedReceivers()
            })
        listenersInstalled = true
    }

    /**
     * Android's Wi-Fi P2P framework can silently forget DNS-SD service
     * requests after a group disconnect or Wi-Fi radio reset. In that case,
     * discoverServices() fails with NO_SERVICE_REQUESTS (=3) even though our
     * local 'serviceRequest' field still contains a non-null request object.
     *
     * Always rebuild the request for a new discovery and do not treat our
     * cached Kotlin request object as proof it exists in Android's stack.
     * Saved receiver identity remains in Flutter preferences. Discovered
     * addresses must be refreshed because Android can rotate their MACs.
     */
    fun discover(force: Boolean = false): Boolean {
        if (!start()) return false
        val service = manager ?: return false
        val ch = p2pChannel ?: return false
        installServiceResponseListeners()
        if (connectingAddress != null) {
            event(mapOf("type" to "pairing",
                "message" to "Pairing in progress; waiting for Wi-Fi Direct group"))
            return true
        }
        if (discoveryPending) return true
        val now = SystemClock.elapsedRealtime()
        // Android's discovery callback means the SEARCH started, not that
        // the scan finished. The 10-second Flutter recovery loop must not
        // cancel a still-running search by clearing its service request.
        // A user's Find button may explicitly force a fresh scan.
        if (!force && lastDiscoveryStartedMs != 0L &&
            now - lastDiscoveryStartedMs < 20000L) return true
        lastDiscoveryStartedMs = now
        // Don't erase a valid, just-discovered peer while the user taps it.
        // The old behavior cleared the entire verified list on EVERY scan
        // (including background recovery), so connect(address) immediately
        // rejected the address the UI had just displayed. Expire old records
        // instead and refresh their timestamp on the next DNS-SD TXT reply.
        verifiedReceivers.keys.filter { id ->
            now - (verifiedReceiverSeen[id] ?: 0L) > 60000L
        }.toList().forEach { id ->
            verifiedReceivers.remove(id)
            verifiedReceiverSeen.remove(id)
        }
        publishVerifiedReceivers()
        discoveryPending = true
        val generation = ++discoveryGeneration
        event(mapOf("type" to "status",
            "message" to "Registering VYBE-only discovery request..."))

        fun fail(message: String) {
            if (generation != discoveryGeneration) return
            discoveryPending = false
            lastDiscoveryStartedMs = 0L
            event(mapOf("type" to "error", "message" to message))
        }

        fun registerAndSearch(recoveriesRemaining: Int) {
            if (generation != discoveryGeneration) return
            val request = WifiP2pDnsSdServiceRequest.newInstance(
                INSTANCE_NAME, SERVICE_TYPE)
            service.addServiceRequest(ch, request, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    if (generation != discoveryGeneration) return
                    serviceRequest = request
                    event(mapOf("type" to "status",
                        "message" to "VYBE service request registered; searching for head units..."))
                    service.discoverServices(ch, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() {
                            if (generation != discoveryGeneration) return
                            discoveryPending = false
                            event(mapOf("type" to "status",
                                "message" to "Scanning for verified VYBE receivers..."))
                        }
                        override fun onFailure(reason: Int) {
                            if (generation != discoveryGeneration) return
                            if (reason == WifiP2pManager.NO_SERVICE_REQUESTS &&
                                recoveriesRemaining > 0) {
                                // Android lost the request between the add
                                // callback and discoverServices. Re-register.
                                serviceRequest = null
                                event(mapOf("type" to "status",
                                    "message" to "Android reset Wi-Fi discovery; repairing VYBE search..."))
                                service.clearServiceRequests(ch,
                                    object : WifiP2pManager.ActionListener {
                                        override fun onSuccess() {
                                            registerAndSearch(recoveriesRemaining - 1)
                                        }
                                        override fun onFailure(reason: Int) {
                                            registerAndSearch(recoveriesRemaining - 1)
                                        }
                                    })
                            } else {
                                val description = if (reason == WifiP2pManager.NO_SERVICE_REQUESTS)
                                    "Android lost Wi-Fi Direct service requests (3); toggle Wi-Fi to reset its radio"
                                else "VYBE service search failed (Android code $reason)"
                                fail(description)
                            }
                        }
                    })
                }
                override fun onFailure(reason: Int) {
                    fail("Cannot register VYBE discovery request (Android code $reason)")
                }
            })
        }

        // Reuse a registered service request during normal scans. Clearing
        // and re-adding it every 20 seconds was interrupting in-flight
        // discovery just as a user selected the head unit.
        fun beginSearch(recoveriesRemaining: Int) {
            service.discoverServices(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    if (generation != discoveryGeneration) return
                    discoveryPending = false
                    event(mapOf("type" to "status",
                        "message" to "Scanning for verified VYBE receivers..."))
                }
                override fun onFailure(reason: Int) {
                    if (generation != discoveryGeneration) return
                    if (reason == WifiP2pManager.NO_SERVICE_REQUESTS &&
                        recoveriesRemaining > 0) {
                        serviceRequest = null
                        service.clearServiceRequests(ch,
                            object : WifiP2pManager.ActionListener {
                                override fun onSuccess() { registerAndSearch(0) }
                                override fun onFailure(reason: Int) {
                                    registerAndSearch(0)
                                }
                            })
                    } else fail("VYBE service discovery failed (Android code $reason)")
                }
            })
        }
        if (serviceRequest != null) beginSearch(1)
        else registerAndSearch(1)
        // Service callbacks can be lost on some radios; allow the next
        // deliberate scan to recover without restarting the app.
        mainHandler.postDelayed({
            if (generation == discoveryGeneration && discoveryPending) {
                fail("Wi-Fi Direct discovery timed out; retrying with a fresh request")
            }
        }, 12000L)
        return true
    }

    private fun retryHostAfterDiscovery() {
        android.os.Handler(Looper.getMainLooper()).postDelayed({
            beginHost(false)
        }, 1000L)
    }

    private fun reportGroupReady(service: WifiP2pManager, ch: WifiP2pManager.Channel) {
        // createGroup().onSuccess means Android accepted the request, NOT
        // that the head unit has a usable P2P group. Keep hostPending set
        // until connection info actually confirms a group owner. Otherwise
        // the recovery timer can issue another createGroup() mid-negotiation.
        service.requestConnectionInfo(ch) { info ->
            if (info.groupFormed && info.isGroupOwner &&
                info.groupOwnerAddress != null) {
                hostPending = false
                hostReadyChecks = 0
                if (pendingHostReceiverId.isNotEmpty()) {
                    advertiseReceiver(pendingHostReceiverId)
                }
                event(mapOf("type" to "action", "name" to "host", "ok" to true))
                event(mapOf("type" to "connected",
                    "host" to info.groupOwnerAddress.hostAddress,
                    "owner" to true))
            } else if (hostPending && hostReadyChecks < 24) {
                hostReadyChecks++
                mainHandler.postDelayed({
                    if (hostPending) reportGroupReady(service, ch)
                }, 750L)
            } else if (hostPending) {
                hostPending = false
                hostReadyChecks = 0
                event(mapOf("type" to "error",
                    "message" to "Head unit Wi-Fi Direct group did not become ready"))
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

    fun host(receiverId: String, refreshAdvertisement: Boolean = false): Boolean {
        if (!start()) return false
        if (!receiverId.matches(Regex("[0-9a-fA-F]{32}"))) {
            event(mapOf("type" to "error",
                "message" to "VYBE receiver identity unavailable; reopen Connect"))
            return false
        }
        pendingHostReceiverId = receiverId
        // A deliberate setup tap must recover even if the Android framework
        // silently forgot a DNS-SD service while keeping the same P2P group.
        // Automatic recovery leaves a healthy advertisement untouched.
        if (refreshAdvertisement && advertisingPending) {
            // Let the in-flight add resolve before replacing it. Cancelling
            // its generation without an accepted localService handle loses
            // the ability to remove it cleanly from the framework.
            mainHandler.postDelayed({
                if (pendingHostReceiverId == receiverId)
                    host(receiverId, refreshAdvertisement = true)
            }, 750L)
            return true
        }
        if (refreshAdvertisement && localService != null) {
            forgetReceiverAdvertisement {
                if (pendingHostReceiverId == receiverId && !hostPending) {
                    hostPending = true
                    hostReadyChecks = 0
                    beginHost(true)
                }
            }
            return true
        }
        // Don't broadcast VYBE's identity before Android finishes creating
        // the group. Advertising too early lets the phone tap a receiver
        // that cannot yet accept a connect() invitation (often ERROR 0).
        if (hostPending) return true
        hostPending = true
        hostReadyChecks = 0
        beginHost(true)
        return true
    }

    fun connect(address: String): Boolean {
        if (!start()) return false
        val service = manager ?: return false
        val ch = p2pChannel ?: return false
        // Never connect to a generic nearby Android device. The caller
        // may only select a peer verified by VYBE's DNS-SD TXT record in
        // the current discovery session (old results are cleared on scan).
        val now = SystemClock.elapsedRealtime()
        val knownId = verifiedReceivers.entries.firstOrNull {
            it.value["address"] == address
        }?.key
        val known = knownId != null &&
            now - (verifiedReceiverSeen[knownId] ?: 0L) < 60000L
        if (!known) {
            event(mapOf("type" to "error",
                "message" to "Receiver address is no longer verified; scan for VYBE head units again"))
            return false
        }
        if (connectingAddress != null) {
            event(mapOf("type" to "pairing",
                "message" to "Already pairing with a VYBE head unit; no repeat request sent"))
            return true
        }

        val config = WifiP2pConfig().apply {
            deviceAddress = address
            wps.setup = WpsInfo.PBC
            groupOwnerIntent = 0
        }
        connectingAddress = address
        val generation = ++connectAttemptGeneration
        event(mapOf("type" to "pairing",
            "message" to "Requesting Wi-Fi Direct pairing with verified VYBE head unit..."))

        fun formedGroup(host: String, isOwner: Boolean) {
            if (generation != connectAttemptGeneration) return
            connectingAddress = null
            connectAttemptGeneration++
            event(mapOf("type" to "connected",
                "host" to host, "owner" to isOwner))
        }

        fun rejected(reason: Int) {
            if (generation != connectAttemptGeneration) return
            connectingAddress = null
            connectAttemptGeneration++
            // ERROR=0 is generic. It does NOT prove an expired MAC and must
            // not erase a fresh verified TXT record. The caller can refresh
            // its discovery on a failed attempt, without losing identity.
            val message = when (reason) {
                WifiP2pManager.ERROR ->
                    "Android rejected Wi-Fi Direct connect request (ERROR 0); rechecking group/peer state"
                WifiP2pManager.BUSY ->
                    "Android Wi-Fi Direct is busy (2); wait for group setup, then scan again"
                else -> "Wi-Fi Direct pairing request failed (Android code $reason)"
            }
            event(mapOf("type" to "pairing_failed", "message" to message))
            // ERROR=0 alone cannot identify a root cause. Record whether
            // Android still sees the selected peer and whether another P2P
            // group is already active. This survives in visible diagnostics.
            val failedGeneration = connectAttemptGeneration
            service.requestPeers(ch) { peers ->
                if (failedGeneration != connectAttemptGeneration) return@requestPeers
                val matchingPeer = peers.deviceList.firstOrNull {
                    it.deviceAddress.equals(address, ignoreCase = true)
                }
                service.requestGroupInfo(ch) { group ->
                    if (failedGeneration != connectAttemptGeneration)
                        return@requestGroupInfo
                    event(mapOf("type" to "diagnostic",
                        "message" to "Pairing error=$reason; peerSeen=${matchingPeer != null}; peerStatus=${matchingPeer?.status ?: -1}; existingGroup=${group != null}; groupOwner=${group?.owner?.deviceAddress ?: "none"}; localOwner=${group?.isGroupOwner ?: false}"))
                }
            }
        }

        fun attemptConnect(retriesLeft: Int) {
            if (generation != connectAttemptGeneration ||
                connectingAddress != address) return
            // Android automatically stops active P2P discovery when a
            // connection is requested. Explicitly calling stopPeerDiscovery()
            // first can invalidate a newly advertised device on some radios.
            service.connect(ch, config, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    if (generation == connectAttemptGeneration &&
                        connectingAddress == address) {
                        event(mapOf("type" to "pairing",
                            "message" to "Android accepted pairing; waiting for Wi-Fi Direct group..."))
                    }
                }
                override fun onFailure(reason: Int) {
                    if (generation != connectAttemptGeneration ||
                        connectingAddress != address) return
                    if (retriesLeft > 0 &&
                        (reason == WifiP2pManager.ERROR ||
                         reason == WifiP2pManager.BUSY)) {
                        // Some Android radios reject connect() while the
                        // receiver's group is still being negotiated. Check
                        // whether it formed before making ONE delayed retry.
                        event(mapOf("type" to "pairing",
                            "message" to "Android pairing busy (code $reason); checking group and retrying once..."))
                        service.requestConnectionInfo(ch) { info ->
                            if (generation != connectAttemptGeneration) return@requestConnectionInfo
                            if (info.groupFormed && info.groupOwnerAddress != null) {
                                formedGroup(info.groupOwnerAddress.hostAddress,
                                    info.isGroupOwner)
                            } else {
                                mainHandler.postDelayed({ attemptConnect(0) }, 1200L)
                            }
                        }
                    } else {
                        rejected(reason)
                    }
                }
            })
        }

        // The immediate ActionListener result is NOT proof of a group.
        // Only a P2P connection-info event may mark the link connected.
        mainHandler.postDelayed({
            if (generation == connectAttemptGeneration &&
                connectingAddress == address) {
                connectingAddress = null
                connectAttemptGeneration++
                event(mapOf("type" to "pairing_timeout",
                    "message" to "Wi-Fi Direct group not formed; refresh VYBE discovery"))
            }
        }, 25000L)

        // A saved Android P2P group may belong to a completely different
        // device (or the phone may still be group owner from an old session).
        // In that state WifiP2pManager.connect() returns ERROR 0 repeatedly.
        // Check and release the wrong group BEFORE the first connect() call.
        service.requestGroupInfo(ch) { existing ->
            if (generation != connectAttemptGeneration ||
                connectingAddress != address) return@requestGroupInfo
            val ownerAddress = existing?.owner?.deviceAddress
            if (existing == null) {
                attemptConnect(1)
            } else if (!existing.isGroupOwner &&
                ownerAddress?.equals(address, ignoreCase = true) == true) {
                service.requestConnectionInfo(ch) { info ->
                    if (generation != connectAttemptGeneration) return@requestConnectionInfo
                    if (info.groupFormed && info.groupOwnerAddress != null) {
                        formedGroup(info.groupOwnerAddress.hostAddress, info.isGroupOwner)
                    } else {
                        attemptConnect(1)
                    }
                }
            } else {
                event(mapOf("type" to "pairing",
                    "message" to "Releasing old Wi-Fi Direct group before pairing selected head unit"))
                service.removeGroup(ch, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        if (generation == connectAttemptGeneration)
                            mainHandler.postDelayed({ attemptConnect(1) }, 650L)
                    }
                    override fun onFailure(reason: Int) {
                        if (generation == connectAttemptGeneration)
                            rejected(reason)
                    }
                })
            }
        }
        return true
    }

    /**
     * Repair a P2P group that Android calls "connected" but whose
     * group-owner IP cannot complete VYBE's receiver identity handshake.
     * The Flutter side calls this only after several actual TCP failures or
     * a wrong receiver hello. It does not remove healthy connected groups.
     */
    fun resetStaleGroup(): Boolean {
        if (!start() || resettingStaleGroup) return false
        val service = manager ?: return false
        val ch = p2pChannel ?: return false
        if (connectingAddress != null) {
            event(mapOf("type" to "pairing",
                "message" to "Cannot reset Direct during an active invitation"))
            return false
        }
        resettingStaleGroup = true
        service.requestGroupInfo(ch) { group ->
            if (group == null) {
                resettingStaleGroup = false
                verifiedReceivers.clear()
                verifiedReceiverSeen.clear()
                publishVerifiedReceivers()
                event(mapOf("type" to "disconnected"))
                return@requestGroupInfo
            }
            event(mapOf("type" to "status",
                "message" to "Repairing unverified Wi-Fi Direct group"))
            service.removeGroup(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    resettingStaleGroup = false
                    verifiedReceivers.clear()
                    verifiedReceiverSeen.clear()
                    publishVerifiedReceivers()
                    event(mapOf("type" to "disconnected"))
                }
                override fun onFailure(reason: Int) {
                    resettingStaleGroup = false
                    event(mapOf("type" to "error",
                        "message" to "Failed to release stale P2P group ($reason)"))
                }
            })
        }
        return true
    }

    /**
     * Called when the user turns automatic pairing off. Abort any pending
     * automatic request and peer discovery, but preserve verified VYBE
     * receiver identities for a subsequent deliberate manual selection.
     * This does not tear down an already formed Wi-Fi Direct group.
     */
    fun cancelAutomaticPairing(): Boolean {
        val active = connectingAddress != null
        connectingAddress = null
        connectAttemptGeneration++
        discoveryPending = false
        discoveryGeneration++
        val service = manager
        val ch = p2pChannel
        if (service != null && ch != null) {
            if (active) {
                try { service.cancelConnect(ch, null) } catch (_: Exception) {}
            }
            try { service.stopPeerDiscovery(ch, null) } catch (_: Exception) {}
        }
        event(mapOf("type" to "manual",
            "message" to "Automatic pairing paused; choose a VYBE head unit manually"))
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
        advertisementRemovalPending = false
        advertisingGeneration++
        discoveryPending = false
        discoveryGeneration++
        lastDiscoveryStartedMs = 0L
        hostPending = false
        hostReadyChecks = 0
        pendingHostReceiverId = ""
        resettingStaleGroup = false
        listenersInstalled = false
        verifiedReceivers.clear()
        connectingAddress = null
        connectAttemptGeneration++
    }
}
