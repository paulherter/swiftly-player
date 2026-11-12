package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.DatagramHost
import de.paulherter.swiftly.rustcore.DiscoverInterface
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface

/** The UDP half of the local server search: one broadcast socket, the probe to every target, then what comes back. */
class AndroidDatagramHost : DatagramHost {
    private val socket: DatagramSocket? = runCatching { DatagramSocket().apply { broadcast = true } }.getOrNull()

    override fun send(payload: ByteArray, target: UInt, port: UShort): Boolean {
        val s = socket ?: return false
        val a = target.toLong()
        val bytes = byteArrayOf((a shr 24).toByte(), (a shr 16).toByte(), (a shr 8).toByte(), a.toByte())
        return runCatching { s.send(DatagramPacket(payload, payload.size, InetAddress.getByAddress(bytes), port.toInt())) }.isSuccess
    }

    override fun receive(seconds: UInt): List<ByteArray> {
        val s = socket ?: return emptyList()
        val end = System.currentTimeMillis() + seconds.toLong() * 1000
        val out = ArrayList<ByteArray>()
        val buffer = ByteArray(2048)
        try {
            while (true) {
                val left = end - System.currentTimeMillis()
                if (left <= 0) break
                s.soTimeout = left.toInt()
                val p = DatagramPacket(buffer, buffer.size)
                try { s.receive(p) } catch (_: java.net.SocketTimeoutException) { break }
                out.add(p.data.copyOf(p.length))
            }
        } catch (_: Exception) {
        } finally { runCatching { s.close() } }
        return out
    }

    companion object {
        /** The IPv4 interfaces that are up, address and netmask in host byte order. */
        fun interfaces(): List<DiscoverInterface> = runCatching {
            NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }.flatMap { n ->
                n.interfaceAddresses.filter { it.address is Inet4Address }.map { a ->
                    val b = a.address.address
                    val address = b.fold(0L) { acc, x -> (acc shl 8) or (x.toLong() and 0xff) }
                    val mask = if (a.networkPrefixLength.toInt() == 0) 0L else (0xffffffffL shl (32 - a.networkPrefixLength.toInt())) and 0xffffffffL
                    DiscoverInterface(address.toUInt(), mask.toUInt())
                }
            }
        }.getOrDefault(emptyList())
    }
}
