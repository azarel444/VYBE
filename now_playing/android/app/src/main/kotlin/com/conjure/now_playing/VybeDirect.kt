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
import android.net.MacAddress
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
        private const val INSTANCE_NAME = "VYBE-Phone"
        private const val SERVICE_TYPE = "_vybe-link._tcp"
        private const val APP_MARKER = "vybe"
        private const val PROTOCOL_VERSION = "2"
    }

    private val manager = activity.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    // Android can drop the underlying P2P framework channel without a Wi-Fi
    // radio broadcast. A permanently-held null-listener channel required an
    // app force-close to recover. Recreate it and all per-channel state.
    private var channelGeneration = 0
    private var p2pChannel: WifiP2pManager.Channel? = createP2pChannel()
    private var registered = false
    private var advertised = false
    private var advertisingPending = false
    private var advertisementRemovalPending = false
    private var localService: WifiP2pDnsSdServiceInfo? = null
    private var localServiceId = ""
    private var advertisingGeneration = 0
    private var advertisingFailures = 0
    private var advertisementTimeoutRetries = 0
    private var serviceRequest: WifiP2pServiceRequest? = null
    private var rawDiscovery = false
    private val rawPeers = linkedMapOf<String, Map<String, String>>()
    private var discoveryPending = false
    private var discoveryGeneration = 0
    private var lastDiscoveryStartedMs = 0L
    private var listenersInstalled = false

    // Device addresses can rotate between reconnections. The receiver's
    // published VYBE ID is the more stable identifier.
    private val verifiedReceivers = linkedMapOf<String, Map<String, String>>()
    private val verifiedReceiverSeen = mutableMapOf<String, Long>()
    private var hostPending = false
    private var hostGeneration = 0
    private var hostReadyChecks = 0
    private var pendingHostReceiverId = ""
    private val mainHandler = Handler(Looper.getMainLooper())
    private var connectingAddress: String? = null
    private var connectAttemptGeneration = 0
    private var connectPreflightPassed = false
    private var resettingStaleGroup = false
    private var resetGroupGeneration = 0

    private fun createP2pChannel(): WifiP2pManager.Channel? {
        val service = manager ?: return null
        val generation = ++channelGeneration
        return service.initialize(activity, Looper.getMainLooper(),
            object : WifiP2pManager.ChannelListener {
                override fun onChannelDisconnected() {
                    if (generation != channelGeneration) return
                    p2pChannel = null
                    resettingStaleGroup = false
                    connectingAddress = null
                    connectPreflightPassed = false
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
                WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                    if (rawDiscovery) publishRawPeers()
                }
                WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                    if (!permitted()) return
                    val service = manager ?: return
                    val ch = p2pChannel ?: return
                    service.requestConnectionInfo(ch) { info ->
                        if (ch !== p2pChannel || resettingStaleGroup)
                            return@requestConnectionInfo
                        if (info.groupFormed && info.groupOwnerAddress != null) {
                            val requestedAddress = connectingAddress
                            if (requestedAddress != null) {
                                // Android may report an OLD, unrelated group
                                // while we're replacing it. Verify its owner
                                // is the selected VYBE device before accepting
                                // this broadcast as a completed pairing.
                                service.requestGroupInfo(ch) { group ->
                                    if (ch !== p2pChannel || resettingStaleGroup || connectingAddress != requestedAddress)
                                        return@requestGroupInfo
                                    val actualOwner = group?.owner?.deviceAddress
                                    if (connectPreflightPassed &&
                                        group?.isGroupOwner == false) {
                                        // Android can randomize the owner's
                                        // P2P MAC at group formation. Once
                                        // preflight has cleared an unrelated
                                        // group, trust group formation
                                        // provisionally and let TCP hello
                                        // validate the receiver's stable ID.
                                        connectingAddress = null
                                        connectPreflightPassed = false
                                        connectAttemptGeneration++
                                        event(mapOf(
                                            "type" to "connected",
                                            "host" to info.groupOwnerAddress.hostAddress,
                                            "owner" to false))
                                    } else {
                                        event(mapOf("type" to "pairing",
                                            "message" to "Waiting for selected Wi-Fi Direct group, preflight still active"))
                                    }
                                }
                            } else {
                                hostPending = false
                                hostReadyChecks = 0
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

    /** This API was introduced in Android 10 (API 29). The Android 9
     * ATOTO is a group owner and cannot be told to use 5 GHz through the
     * public Wi-Fi Direct API. On a newer phone, band selection constrains
     * which group band can be JOINED; it cannot retune the Android 9 owner.
     */
    fun bandCapabilities(): Map<String, Any> = mapOf(
        "sdk" to Build.VERSION.SDK_INT,
        "canSelectBand" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q),
        "canReadFrequency" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
    )

    /** Returns a fresh reading from the Wi-Fi Direct group, NOT the ordinary
     * Wi-Fi STA frequency (which may be unrelated to the P2P link).
     */
    fun refreshBandInfo(): Boolean {
        val service = manager ?: return false
        val ch = p2pChannel ?: return false
        if (!permitted()) return false
        service.requestGroupInfo(ch) { group ->
            val mhz = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                group?.frequency ?: 0 else 0
            val actual = when {
                group == null -> "No Wi-Fi Direct group"
                Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ->
                    "Unknown (Android 9 cannot report P2P frequency)"
                mhz in 2400..2500 -> "2.4 GHz"
                mhz in 4900..5899 -> "5 GHz"
                mhz in 5900..7125 -> "6 GHz"
                else -> "Unknown (driver did not report frequency)"
            }
            event(mapOf(
                "type" to "band_info",
                "sdk" to Build.VERSION.SDK_INT,
                "groupFormed" to (group != null),
                "isOwner" to (group?.isGroupOwner ?: false),
                "frequencyMHz" to mhz,
                "band" to actual,
                "verified" to (mhz > 0 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
            ))
        }
        return true
    }

    fun available(): Boolean =
        manager != null &&
        activity.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)

    fun start(): Boolean {
        if (!available() || !permitted()) return false
        if (p2pChannel == null) p2pChannel = createP2pChannel()
        if (p2pChannel == null) return false
        if (!registered) {
            val filter = IntentFilter().apply {
                addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
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
            if (ch === p2pChannel && info.groupFormed && info.groupOwnerAddress != null &&
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
                                if (generation == advertisingGeneration &&
                                    advertisementRemovalPending) {
                                    advertisementRemovalPending = false
                                    afterRemoval?.invoke()
                                }
                            }
                            override fun onFailure(reason: Int) {
                                if (generation == advertisingGeneration &&
                                    advertisementRemovalPending) {
                                    advertisementRemovalPending = false
                                    afterRemoval?.invoke()
                                }
                            }
                        })
                    mainHandler.postDelayed({
                        if (generation == advertisingGeneration &&
                            advertisementRemovalPending) {
                            // A missing Android callback must not permanently
                            // block receiver discovery until app restart.
                            advertisementRemovalPending = false
                            event(mapOf("type" to "status",
                                "message" to "Local service removal callback timed out; recovering advertisement"))
                            afterRemoval?.invoke()
                        }
                    }, 6000L)
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
        if (advertised && receiverId == localServiceId) {
            event(mapOf("type" to "host_advertised", "id" to receiverId))
            return
        }
        if (advertisingPending && receiverId == localServiceId) return

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
                "role" to "sender",
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
                advertisementTimeoutRetries = 0
                localService = info
                event(mapOf("type" to "host_advertised", "id" to receiverId))
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
                        "message" to "Could not advertise VYBE receiver ($reason); use Set up phone Wi-Fi Direct again"))
                }
            }
        })
        // Some low-end Wi-Fi P2P stacks lose addLocalService callbacks.
        // Invalidate and remove this exact service before ONE fresh add,
        // rather than leaving advertisingPending latched indefinitely.
        mainHandler.postDelayed({
            if (generation != advertisingGeneration || !advertisingPending)
                return@postDelayed
            advertisingPending = false
            advertised = false
            advertisingGeneration++
            event(mapOf("type" to "status",
                "message" to "Android advertisement did not acknowledge; repairing service registration"))
            service.removeLocalService(ch, info,
                object : WifiP2pManager.ActionListener {
                    private fun proceed() {
                        if (pendingHostReceiverId != receiverId) return
                        if (advertisementTimeoutRetries < 1) {
                            advertisementTimeoutRetries++
                            advertiseReceiver(receiverId)
                        } else {
                            event(mapOf("type" to "error",
                                "message" to "Android Wi-Fi Direct local service is unresponsive; radio needs recovery"))
                        }
                    }
                    override fun onSuccess() { proceed() }
                    override fun onFailure(reason: Int) { proceed() }
                })
        }, 8500L)
    }

    // Only publish after Flutter has bound its TCP listener on the owner IP.
    fun publishHost(receiverId: String): Boolean {
        if (!permitted() || resettingStaleGroup || pendingHostReceiverId != receiverId) return false
        val service = manager ?: return false
        val ch = p2pChannel ?: return false
        service.requestConnectionInfo(ch) { info ->
            if (ch !== p2pChannel || resettingStaleGroup || pendingHostReceiverId != receiverId)
                return@requestConnectionInfo
            if (info.groupFormed && info.isGroupOwner) {
                advertiseReceiver(receiverId)
                service.requestGroupInfo(ch) { group ->
                    if (ch === p2pChannel && pendingHostReceiverId == receiverId && group?.isGroupOwner == true) {
                        event(mapOf("type" to "host_network", "name" to group.networkName))
                    }
                }
            } else {
                event(mapOf("type" to "error", "message" to "Phone is not the Wi-Fi Direct group owner"))
            }
        }
        return true
    }

    private fun publishRawPeers() {
        if (!rawDiscovery || !permitted()) return
        val service = manager ?: return
        val ch = p2pChannel ?: return
        service.requestPeers(ch) { peers ->
            if (!rawDiscovery || ch !== p2pChannel) return@requestPeers
            rawPeers.clear()
            for (peer in peers.deviceList) {
                if (peer.deviceAddress.isNullOrBlank()) continue
                rawPeers[peer.deviceAddress] = mapOf("address" to peer.deviceAddress,
                    "name" to (peer.deviceName.takeIf { it.isNotBlank() } ?: "Android Wi-Fi Direct device"))
            }
            event(mapOf("type" to "raw_peers", "items" to rawPeers.values.toList()))
        }
    }

    // Explicit fallback for devices that cannot deliver DNS-SD TXT responses.
    // These peers are not VYBE-verified and never auto-pair.
    fun discoverRaw(): Boolean {
        if (!start() || resettingStaleGroup || connectingAddress != null) return false
        val service = manager ?: return false
        val ch = p2pChannel ?: return false
        discoveryGeneration++
        discoveryPending = false
        lastDiscoveryStartedMs = 0L
        rawDiscovery = true
        rawPeers.clear()
        event(mapOf("type" to "raw_peers", "items" to emptyList<Map<String, String>>()))
        service.discoverPeers(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                if (rawDiscovery && ch === p2pChannel) {
                    publishRawPeers()
                    event(mapOf("type" to "status", "message" to "Scanning system Wi-Fi Direct devices"))
                }
            }
            override fun onFailure(reason: Int) {
                if (rawDiscovery && ch === p2pChannel) {
                    rawDiscovery = false
                    event(mapOf("type" to "error", "message" to "System Wi-Fi Direct scan failed ($reason)"))
                }
            }
        })
        return true
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
                        "message" to "Checking nearby VYBE phone identity..."))
                }
            },
            WifiP2pManager.DnsSdTxtRecordListener { domain, record, device ->
                val validDomain = domain.lowercase()
                    .contains("._vybe-link._tcp.")
                val receiverId = record["id"] ?: ""
                val valid = validDomain &&
                    record["app"] == APP_MARKER &&
                    record["role"] == "sender" &&
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
                    "name" to "VYBE Phone · ${id.takeLast(6).uppercase()}")
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
        rawDiscovery = false
        rawPeers.clear()
        installServiceResponseListeners()
        if (connectingAddress != null) {
            event(mapOf("type" to "pairing",
                "message" to "Pairing in progress; waiting for Wi-Fi Direct group"))
            return true
        }
        if (discoveryPending) {
            event(mapOf("type" to "status", "message" to "VYBE discovery is already starting; waiting for Android"))
            return true
        }
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
            // Query all DNS-SD records; only the VYBE marker and sender role are accepted above.
            val request = WifiP2pDnsSdServiceRequest.newInstance()
            service.addServiceRequest(ch, request, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    if (generation != discoveryGeneration) return
                    serviceRequest = request
                    event(mapOf("type" to "status",
                        "message" to "VYBE service request registered; searching for VYBE phones..."))
                    service.discoverServices(ch, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() {
                            if (generation != discoveryGeneration) return
                            discoveryPending = false
                            event(mapOf("type" to "status",
                                "message" to "Scanning for verified VYBE phones..."))
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
                        "message" to "Scanning for verified VYBE phones..."))
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
        if (force) {
            // A deliberate Find tap must not reuse an OS request from a dead session.
            serviceRequest = null
            service.stopPeerDiscovery(ch, object : WifiP2pManager.ActionListener {
                private fun clearAndSearch() {
                    if (generation != discoveryGeneration) return
                    service.clearServiceRequests(ch, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() { registerAndSearch(1) }
                        override fun onFailure(reason: Int) {
                            fail("Cannot clear stale VYBE discovery requests (Android code $reason); tap Find again")
                        }
                    })
                }
                override fun onSuccess() { clearAndSearch() }
                override fun onFailure(reason: Int) { clearAndSearch() }
            })
        } else if (serviceRequest != null) beginSearch(1)
        else registerAndSearch(1)
        // Service callbacks can be lost on some radios; allow the next
        // deliberate scan to recover without restarting the app.
        mainHandler.postDelayed({
            if (generation == discoveryGeneration && discoveryPending) {
                serviceRequest = null
                fail("Wi-Fi Direct discovery timed out; tap Find to start a fresh request")
            }
        }, 12000L)
        return true
    }

    private fun hostCurrent(ch: WifiP2pManager.Channel, epoch: Int): Boolean =
        hostPending && hostGeneration == epoch && ch === p2pChannel &&
            !resettingStaleGroup && pendingHostReceiverId.isNotEmpty()

    private fun hostFailed(ch: WifiP2pManager.Channel, epoch: Int, message: String) {
        if (!hostCurrent(ch, epoch)) return
        hostPending = false
        hostReadyChecks = 0
        event(mapOf("type" to "error", "message" to message))
    }

    private fun reportGroupReady(service: WifiP2pManager, ch: WifiP2pManager.Channel, epoch: Int) {
        if (!hostCurrent(ch, epoch)) return
        service.requestConnectionInfo(ch) { info ->
            if (!hostCurrent(ch, epoch)) return@requestConnectionInfo
            if (info.groupFormed && info.isGroupOwner && info.groupOwnerAddress != null) {
                hostPending = false
                hostReadyChecks = 0
                event(mapOf("type" to "connected",
                    "host" to info.groupOwnerAddress.hostAddress, "owner" to true))
            } else if (hostReadyChecks < 24) {
                hostReadyChecks++
                mainHandler.postDelayed({ reportGroupReady(service, ch, epoch) }, 750L)
            } else {
                hostFailed(ch, epoch, "Android accepted group creation but no phone group became ready")
            }
        }
    }

    // Android may remain BUSY after removeGroup() reports success. Cancel
    // invitations, stop discovery, then wait for the framework to settle.
    // A lost callback must not permanently latch hostPending.
    private fun retryBusyHost(service: WifiP2pManager, ch: WifiP2pManager.Channel,
                              epoch: Int, retries: Int) {
        if (!hostCurrent(ch, epoch)) return
        var stopStarted = false
        var retryScheduled = false
        fun scheduleRetry() {
            if (retryScheduled || !hostCurrent(ch, epoch)) return
            retryScheduled = true
            val delay = when (retries) { 3 -> 1500L; 2 -> 3000L; else -> 5000L }
            mainHandler.postDelayed({
                if (hostCurrent(ch, epoch)) beginHost(epoch, retries - 1)
            }, delay)
        }
        fun stopDiscovery() {
            if (stopStarted || !hostCurrent(ch, epoch)) return
            stopStarted = true
            try {
                service.stopPeerDiscovery(ch, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() { scheduleRetry() }
                    override fun onFailure(reason: Int) { scheduleRetry() }
                })
            } catch (_: Exception) { scheduleRetry() }
            mainHandler.postDelayed({ scheduleRetry() }, 1500L)
        }
        try {
            service.cancelConnect(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() { stopDiscovery() }
                override fun onFailure(reason: Int) { stopDiscovery() }
            })
        } catch (_: Exception) { stopDiscovery() }
        mainHandler.postDelayed({ stopDiscovery() }, 1500L)
    }

    private fun beginHost(epoch: Int, retries: Int) {
        val service = manager ?: return
        val ch = p2pChannel ?: return
        if (!hostCurrent(ch, epoch)) return
        service.requestGroupInfo(ch) { group ->
            if (!hostCurrent(ch, epoch)) return@requestGroupInfo
            if (group?.isGroupOwner == true) {
                reportGroupReady(service, ch, epoch)
            } else if (group != null) {
                hostFailed(ch, epoch, "Already connected to another Wi-Fi Direct group; reset the phone connection")
            } else {
                service.createGroup(ch, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        reportGroupReady(service, ch, epoch)
                    }
                    override fun onFailure(reason: Int) {
                        if (!hostCurrent(ch, epoch)) return
                        if (reason == WifiP2pManager.BUSY && retries > 0) {
                            event(mapOf("type" to "status",
                                "message" to "Android Wi-Fi Direct busy; releasing stale invitation and retrying (" + (4 - retries) + "/3)"))
                            retryBusyHost(service, ch, epoch, retries)
                        } else {
                            hostFailed(ch, epoch, if (reason == WifiP2pManager.BUSY)
                                "Android Wi-Fi Direct still busy after recovery; toggle Wi-Fi on the phone, then tap Start again"
                            else "Wi-Fi Direct group creation failed ($reason); tap Set up again")
                        }
                    }
                })
            }
        }
    }

    private fun startHostAttempt() {
        val ch = p2pChannel ?: return
        hostPending = true
        hostReadyChecks = 0
        val epoch = ++hostGeneration
        mainHandler.postDelayed({
            hostFailed(ch, epoch, "Android did not finish creating the phone group; tap Set up to retry")
        }, 45000L)
        beginHost(epoch, 3)
    }

    fun host(receiverId: String, refreshAdvertisement: Boolean = false): Boolean {
        if (!start() || resettingStaleGroup) return false
        if (!receiverId.matches(Regex("[0-9a-fA-F]{32}"))) return false
        pendingHostReceiverId = receiverId
        if (hostPending) return true
        startHostAttempt()
        return true
    }

    fun connect(address: String, requestedBand: String = "auto", rawSelected: Boolean = false): Boolean {
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
        if (!known && !(rawSelected && rawDiscovery && rawPeers.containsKey(address))) {
            event(mapOf("type" to "error",
                "message" to "Receiver address is no longer verified; scan for VYBE phones again"))
            return false
        }
        if (connectingAddress != null) {
            event(mapOf("type" to "pairing",
                "message" to "Already pairing with a VYBE phone; no repeat request sent"))
            return true
        }

        // Strict bands are available to modern ANDROID PHONES only. This is
        // an opt-in experiment, not a promise to change the ATOTO's band.
        // The default path retains the already-tested legacy configuration.
        val strictBand = requestedBand == "5ghz" || requestedBand == "2ghz"
        if (strictBand && Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            event(mapOf("type" to "pairing_failed",
                "message" to "Band selection needs Android 10+. This device is Android ${Build.VERSION.RELEASE}; use Automatic."))
            return false
        }
        val config: WifiP2pConfig = try {
            if (strictBand && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val band = if (requestedBand == "5ghz")
                    WifiP2pConfig.GROUP_OWNER_BAND_5GHZ
                    else WifiP2pConfig.GROUP_OWNER_BAND_2GHZ
                WifiP2pConfig.Builder()
                    .setDeviceAddress(MacAddress.fromString(address))
                    .setGroupOperatingBand(band)
                    .build().apply {
                        wps.setup = WpsInfo.PBC
                        groupOwnerIntent = 0 // phone remains group owner
                    }
            } else {
                WifiP2pConfig().apply {
                    deviceAddress = address
                    wps.setup = WpsInfo.PBC
                    groupOwnerIntent = 0
                }
            }
        } catch (error: Exception) {
            event(mapOf("type" to "pairing_failed",
                "message" to "Cannot prepare ${requestedBand} Wi-Fi Direct connection: ${error.message}"))
            return false
        }
        rawDiscovery = false
        connectingAddress = address
        connectPreflightPassed = false
        val generation = ++connectAttemptGeneration
        event(mapOf("type" to "pairing",
            "message" to "Requesting Wi-Fi Direct pairing with verified VYBE phone..."))

        fun formedGroup(host: String, isOwner: Boolean) {
            if (generation != connectAttemptGeneration) return
            connectingAddress = null
            connectPreflightPassed = false
            connectAttemptGeneration++
            event(mapOf("type" to "connected",
                "host" to host, "owner" to isOwner))
        }

        fun rejected(reason: Int) {
            if (generation != connectAttemptGeneration) return
            connectingAddress = null
            connectPreflightPassed = false
            connectAttemptGeneration++
            // ERROR=0 is generic. It does NOT prove an expired MAC and must
            // not erase a fresh verified TXT record. The caller can refresh
            // its discovery on a failed attempt, without losing identity.
            val message = when (reason) {
                WifiP2pManager.ERROR ->
                    if (strictBand)
                        "Android rejected the ${if (requestedBand == "5ghz") "5 GHz" else "2.4 GHz"}-only attempt. The phone may be hosting on another band; switch to Automatic to reconnect."
                    else "Android rejected Wi-Fi Direct connect request (ERROR 0); rechecking group/peer state"
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
                connectPreflightPassed = false
                connectAttemptGeneration++
                try { service.cancelConnect(ch, null) } catch (_: Exception) {}
                event(mapOf("type" to "pairing_timeout",
                    "message" to "Wi-Fi Direct group not formed; refresh VYBE discovery"))
            }
        }, 25000L)

        // A P2P group can survive app restarts. If the phone is already a
        // CLIENT, first try its live group-owner IP and verify the head unit
        // using its stable VYBE TCP hello. The group owner's randomized MAC
        // is not a trustworthy identity test; removing a healthy group here
        // caused needless disconnect/rejoin cycles. If hello fails, Flutter
        // explicitly asks us to remove that unverified group.
        //
        // If this phone is the group OWNER of an old group, it cannot join
        // the head unit until that incompatible group is released.
        service.requestGroupInfo(ch) { existing ->
            if (generation != connectAttemptGeneration ||
                connectingAddress != address) return@requestGroupInfo
            if (strictBand && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                existing != null && !existing.isGroupOwner &&
                existing.frequency > 0 &&
                (if (requestedBand == "5ghz") existing.frequency !in 4900..5899
                 else existing.frequency !in 2400..2500)) {
                // An existing P2P group isn't retuned by a new connect()
                // request. Don't falsely call a 2.4-GHz link a 5-GHz test.
                rejected(WifiP2pManager.ERROR)
                refreshBandInfo()
                return@requestGroupInfo
            }
            if (existing == null) {
                connectPreflightPassed = true
                attemptConnect(1)
            } else if (!existing.isGroupOwner) {
                service.requestConnectionInfo(ch) { info ->
                    if (generation != connectAttemptGeneration) return@requestConnectionInfo
                    if (info.groupFormed && info.groupOwnerAddress != null) {
                        formedGroup(info.groupOwnerAddress.hostAddress, info.isGroupOwner)
                    } else {
                        connectPreflightPassed = true
                        attemptConnect(1)
                    }
                }
            } else {
                event(mapOf("type" to "pairing",
                    "message" to "Releasing old Wi-Fi Direct group before pairing selected head unit"))
                service.removeGroup(ch, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        if (generation == connectAttemptGeneration) {
                            connectPreflightPassed = true
                            mainHandler.postDelayed({ attemptConnect(1) }, 650L)
                        }
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
        val resetGeneration = ++resetGroupGeneration
        mainHandler.postDelayed({
            if (resetGeneration == resetGroupGeneration &&
                resettingStaleGroup) {
                resettingStaleGroup = false
                event(mapOf("type" to "error",
                    "message" to "Android failed to acknowledge P2P group reset; retry available"))
            }
        }, 10000L)
        service.requestGroupInfo(ch) { group ->
            if (resetGeneration != resetGroupGeneration ||
                !resettingStaleGroup) return@requestGroupInfo
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
                    if (resetGeneration != resetGroupGeneration ||
                        !resettingStaleGroup) return
                    resettingStaleGroup = false
                    verifiedReceivers.clear()
                    verifiedReceiverSeen.clear()
                    publishVerifiedReceivers()
                    event(mapOf("type" to "disconnected"))
                }
                override fun onFailure(reason: Int) {
                    if (resetGeneration != resetGroupGeneration ||
                        !resettingStaleGroup) return
                    resettingStaleGroup = false
                    event(mapOf("type" to "error",
                        "message" to "Failed to release stale P2P group ($reason)"))
                }
            })
        }
        return true
    }


    /**
     * Explicit user recovery. Clear all native in-flight pairing/discovery
     * gates and remove an existing P2P group, on sender OR receiver. This is
     * deliberately separate from resetStaleGroup(), which protects healthy
     * links during automatic recovery.
     */
    fun resetSession(): Boolean {
        val service = manager ?: return false
        if (!permitted()) return false
        val ch = p2pChannel ?: createP2pChannel()?.also {
            p2pChannel = it
        } ?: return false
        resettingStaleGroup = true
        val epoch = ++resetGroupGeneration
        hostGeneration++
        connectingAddress = null
        connectPreflightPassed = false
        connectAttemptGeneration++
        hostPending = false
        hostReadyChecks = 0
        pendingHostReceiverId = ""
        rawDiscovery = false
        rawPeers.clear()
        discoveryPending = false
        discoveryGeneration++
        lastDiscoveryStartedMs = 0L
        verifiedReceivers.clear()
        verifiedReceiverSeen.clear()
        publishVerifiedReceivers()
        // Do not allow old service registration or discovery callbacks to
        // resurrect the previous pairing after a user-initiated reset.
        forgetReceiverAdvertisement()
        serviceRequest?.let { req ->
            try { service.removeServiceRequest(ch, req, null) }
            catch (_: Exception) {}
        }
        serviceRequest = null
        listenersInstalled = false
        fun complete(ok: Boolean, message: String) {
            if (epoch != resetGroupGeneration || !resettingStaleGroup) return
            resettingStaleGroup = false
            var ready = ok
            if (ok) {
                // Retire the old framework channel and its callback generation.
                // Channel.close is public on API 27+, including Android 9.
                channelGeneration++
                p2pChannel = null
                if (Build.VERSION.SDK_INT >= 27) {
                    try { ch.close() } catch (_: Exception) {}
                }
                p2pChannel = try { createP2pChannel() } catch (_: Exception) { null }
                ready = p2pChannel != null
            }
            val type = if (ready) "reset_complete" else "reset_failed"
            event(mapOf("type" to type, "message" to if (ok && !ready)
                "Old group removed but Android channel could not reopen; tap Reset again" else message))
        }
        fun verifyRemoved(attempt: Int) {
            if (epoch != resetGroupGeneration || !resettingStaleGroup) return
            service.requestGroupInfo(ch) { current ->
                if (epoch != resetGroupGeneration || !resettingStaleGroup) return@requestGroupInfo
                if (current == null) complete(true, "Old Wi-Fi Direct session cleared; fresh discovery channel ready")
                else if (attempt < 8) mainHandler.postDelayed({ verifyRemoved(attempt + 1) }, 500L)
                else complete(false, "Android still reports the old Wi-Fi Direct group; tap Reset again")
            }
        }
        mainHandler.postDelayed({
            complete(false, "Android did not finish Wi-Fi Direct reset. Retry or toggle Wi-Fi.")
        }, 12000L)
        try {
            // Wait for cancellation and discovery stop before asking Android
            // to remove the group. A null callback can leave teardown in flight.
            fun removeOldGroup() {
                if (epoch != resetGroupGeneration || !resettingStaleGroup) return
                service.requestGroupInfo(ch) { group ->
                if (epoch != resetGroupGeneration || !resettingStaleGroup)
                    return@requestGroupInfo
                if (group == null) {
                    verifyRemoved(0)
                } else {
                    try {
                        service.removeGroup(ch, object : WifiP2pManager.ActionListener {
                            override fun onSuccess() {
                                mainHandler.postDelayed({ verifyRemoved(0) }, 400L)
                            }
                            override fun onFailure(reason: Int) {
                                complete(false, "Android could not remove the old Wi-Fi Direct group (code $reason)")
                            }
                        })
                    } catch (error: Exception) {
                        complete(false, "Cannot release Wi-Fi Direct group: ${error.message}")
                    }
                }
                }
            }
            var stopStarted = false
            var removalStarted = false
            fun finishStop() {
                if (removalStarted || epoch != resetGroupGeneration || !resettingStaleGroup) return
                removalStarted = true
                mainHandler.postDelayed({ removeOldGroup() }, 500L)
            }
            fun stopSearch() {
                if (stopStarted || epoch != resetGroupGeneration || !resettingStaleGroup) return
                stopStarted = true
                try {
                    service.stopPeerDiscovery(ch, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() { finishStop() }
                        override fun onFailure(reason: Int) { finishStop() }
                    })
                } catch (_: Exception) { finishStop() }
                mainHandler.postDelayed({ finishStop() }, 1200L)
            }
            try {
                service.cancelConnect(ch, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() { stopSearch() }
                    override fun onFailure(reason: Int) { stopSearch() }
                })
            } catch (_: Exception) { stopSearch() }
            mainHandler.postDelayed({ stopSearch() }, 1200L)
        } catch (error: Exception) {
            complete(false, "Wi-Fi Direct reset failed: ${error.message}")
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
            "message" to "Automatic pairing paused; choose a VYBE phone manually"))
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
