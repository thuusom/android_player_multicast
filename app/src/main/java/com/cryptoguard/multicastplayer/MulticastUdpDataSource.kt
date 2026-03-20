package com.cryptoguard.multicastplayer

import android.net.Uri
import android.util.Log
import androidx.media3.common.C
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.io.IOException
import java.net.DatagramPacket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.NetworkInterface
import java.net.SocketTimeoutException

/**
 * A DataSource that receives UDP packets with proper IGMP multicast group joining.
 *
 * ExoPlayer's built-in UdpDataSource uses a plain DatagramSocket which does NOT
 * call joinGroup() for multicast addresses. This class uses MulticastSocket and
 * properly joins/leaves the multicast group.
 *
 * Supports both:
 * - Multicast: udp://239.x.x.x:port (joins the group via IGMP)
 * - Unicast:   udp://0.0.0.0:port or udp://192.168.x.x:port (plain receive)
 */
class MulticastUdpDataSource(
    private val socketTimeoutMs: Int = 8000,
    private val packetBufferSize: Int = 2000
) : BaseDataSource(/* isNetwork= */ true) {

    companion object {
        private const val TAG = "MulticastPlayer"
        private const val SCHEME_UDP = "udp"
    }

    private var socket: MulticastSocket? = null
    private var multicastAddress: InetAddress? = null
    private var networkInterface: NetworkInterface? = null
    private var packet: DatagramPacket? = null
    private var packetBuffer: ByteArray? = null
    private var packetBytesRemaining = 0
    private var packetOffset = 0
    private var opened = false
    private var uri: Uri? = null

    override fun open(dataSpec: DataSpec): Long {
        uri = dataSpec.uri
        val uriString = uri.toString()
        val host = uri?.host ?: "0.0.0.0"
        val port = uri?.port ?: 5000

        Log.i(TAG, "MulticastUdpDataSource.open()")
        Log.i(TAG, "  URI: $uriString")
        Log.i(TAG, "  Host: $host, Port: $port")

        try {
            val address = InetAddress.getByName(host)
            val isMulticast = address.isMulticastAddress

            Log.i(TAG, "  Address: ${address.hostAddress}")
            Log.i(TAG, "  Is multicast: $isMulticast")

            // Create MulticastSocket
            val ms = MulticastSocket(null)
            ms.reuseAddress = true
            ms.soTimeout = socketTimeoutMs

            // Set a large receive buffer to handle bursts
            ms.receiveBufferSize = 256 * 1024
            Log.i(TAG, "  Receive buffer: ${ms.receiveBufferSize} bytes")

            if (isMulticast) {
                multicastAddress = address

                // Find the best network interface for multicast
                networkInterface = findMulticastInterface()
                Log.i(TAG, "  Network interface: ${networkInterface?.displayName ?: "<default>"}")

                // Set the network interface BEFORE binding and joining
                networkInterface?.let { ni ->
                    ms.networkInterface = ni
                    Log.i(TAG, "  Set socket network interface to ${ni.displayName}")
                }

                // Bind to the multicast group address (not wildcard) — some Android
                // WiFi stacks only deliver multicast when bound to the group address
                try {
                    ms.bind(InetSocketAddress(address, port))
                    Log.i(TAG, "  Bound to ${address.hostAddress}:$port")
                } catch (e: Exception) {
                    Log.w(TAG, "  Bind to multicast address failed, binding to wildcard", e)
                    ms.bind(InetSocketAddress(port))
                    Log.i(TAG, "  Bound to 0.0.0.0:$port (wildcard)")
                }

                // Disable loopback
                ms.loopbackMode = false

                // Join multicast group on the specific interface
                try {
                    ms.joinGroup(InetSocketAddress(address, port), networkInterface)
                    Log.i(TAG, "  ✓ Joined multicast group ${address.hostAddress}:$port on ${networkInterface?.displayName ?: "default"}")
                } catch (e: Exception) {
                    Log.w(TAG, "  joinGroup with interface failed ($e), trying legacy joinGroup()")
                    try {
                        @Suppress("DEPRECATION")
                        ms.joinGroup(address)
                        Log.i(TAG, "  ✓ Joined multicast group ${address.hostAddress} (legacy)")
                    } catch (e2: Exception) {
                        Log.e(TAG, "  ✗ Failed to join multicast group", e2)
                        throw e2
                    }
                }
            } else {
                // Unicast: bind to wildcard
                ms.bind(InetSocketAddress(port))
                Log.i(TAG, "  Bound to 0.0.0.0:$port (unicast)")
            }

            socket = ms
            packetBuffer = ByteArray(packetBufferSize)
            packet = DatagramPacket(packetBuffer!!, packetBufferSize)
            opened = true

            transferStarted(dataSpec)
            Log.i(TAG, "  ✓ DataSource opened successfully")

        } catch (e: IOException) {
            Log.e(TAG, "Failed to open MulticastUdpDataSource", e)
            throw IOException("Failed to open UDP socket for $uriString", e)
        }

        return C.LENGTH_UNSET.toLong()
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0

        // If we've exhausted the current packet, receive a new one
        if (packetBytesRemaining == 0) {
            try {
                socket?.receive(packet)
            } catch (e: SocketTimeoutException) {
                // Re-throw as IOException so ExoPlayer handles it
                throw IOException("UDP receive timeout after ${socketTimeoutMs}ms", e)
            }
            packetBytesRemaining = packet?.length ?: 0
            packetOffset = 0
        }

        // Copy from the received packet into the caller's buffer
        val bytesToRead = minOf(length, packetBytesRemaining)
        System.arraycopy(packetBuffer!!, packetOffset, buffer, offset, bytesToRead)
        packetOffset += bytesToRead
        packetBytesRemaining -= bytesToRead

        bytesTransferred(bytesToRead)
        return bytesToRead
    }

    override fun getUri(): Uri? = uri

    /**
     * Find the best network interface for multicast.
     * Prefers wlan0/eth0 with a non-loopback IPv4 address that supports multicast.
     */
    private fun findMulticastInterface(): NetworkInterface? {
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()?.toList() ?: emptyList()

            // Log all interfaces for debugging
            for (ni in interfaces) {
                val addrs = ni.inetAddresses.toList()
                    .filter { !it.isLoopbackAddress }
                    .map { it.hostAddress }
                if (addrs.isNotEmpty()) {
                    Log.d(TAG, "  Interface: ${ni.displayName} (up=${ni.isUp}, multicast=${ni.supportsMulticast()}) addrs=$addrs")
                }
            }

            // Prefer wlan0 or eth0 that is up, supports multicast, and has a non-loopback address
            val preferred = listOf("wlan0", "eth0", "wlan1", "en0", "en1")
            for (name in preferred) {
                val ni = interfaces.find { it.displayName == name }
                if (ni != null && ni.isUp && ni.supportsMulticast()) {
                    val hasIpv4 = ni.inetAddresses.toList().any {
                        !it.isLoopbackAddress && it is java.net.Inet4Address
                    }
                    if (hasIpv4) {
                        Log.i(TAG, "  Selected interface: ${ni.displayName}")
                        return ni
                    }
                }
            }

            // Fallback: any interface that is up, supports multicast, has a non-loopback IPv4 address
            for (ni in interfaces) {
                if (ni.isUp && ni.supportsMulticast() && !ni.isLoopback) {
                    val hasIpv4 = ni.inetAddresses.toList().any {
                        !it.isLoopbackAddress && it is java.net.Inet4Address
                    }
                    if (hasIpv4) {
                        Log.i(TAG, "  Selected interface (fallback): ${ni.displayName}")
                        return ni
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "  Error enumerating network interfaces", e)
        }

        Log.w(TAG, "  No suitable multicast interface found, using system default")
        return null
    }

    override fun close() {
        Log.i(TAG, "MulticastUdpDataSource.close()")

        try {
            multicastAddress?.let { addr ->
                socket?.let { ms ->
                    try {
                        ms.leaveGroup(InetSocketAddress(addr, 0), networkInterface)
                        Log.i(TAG, "  Left multicast group ${addr.hostAddress}")
                    } catch (e: Exception) {
                        Log.w(TAG, "  Error leaving multicast group", e)
                    }
                }
            }
        } finally {
            try {
                socket?.close()
            } catch (e: Exception) {
                Log.w(TAG, "  Error closing socket", e)
            }
            socket = null
            multicastAddress = null
            networkInterface = null
            packetBuffer = null
            packet = null
            packetBytesRemaining = 0
            packetOffset = 0

            if (opened) {
                opened = false
                transferEnded()
            }
        }
    }

    /**
     * Factory for creating MulticastUdpDataSource instances.
     * Falls through to a delegate factory for non-UDP URIs.
     */
    class Factory(
        private val delegateFactory: DataSource.Factory? = null
    ) : DataSource.Factory {

        override fun createDataSource(): DataSource {
            return MulticastUdpDataSourceWrapper(
                MulticastUdpDataSource(),
                delegateFactory?.createDataSource()
            )
        }
    }

    /**
     * Wrapper that routes UDP URIs to MulticastUdpDataSource,
     * and everything else to a delegate DataSource.
     */
    private class MulticastUdpDataSourceWrapper(
        private val multicastSource: MulticastUdpDataSource,
        private val delegate: DataSource?
    ) : DataSource {

        private var activeSource: DataSource? = null

        override fun addTransferListener(transferListener: TransferListener) {
            multicastSource.addTransferListener(transferListener)
            delegate?.addTransferListener(transferListener)
        }

        override fun open(dataSpec: DataSpec): Long {
            val scheme = dataSpec.uri.scheme?.lowercase()
            activeSource = if (scheme == SCHEME_UDP) {
                Log.i(TAG, "Routing to MulticastUdpDataSource for ${dataSpec.uri}")
                multicastSource
            } else {
                delegate ?: throw IOException("No delegate DataSource for scheme: $scheme")
            }
            return activeSource!!.open(dataSpec)
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            return activeSource?.read(buffer, offset, length)
                ?: throw IOException("DataSource not opened")
        }

        override fun getUri(): Uri? = activeSource?.uri

        override fun close() {
            activeSource?.close()
            activeSource = null
        }
    }
}
