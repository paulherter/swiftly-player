package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.SocketFailure
import de.paulherter.swiftly.rustcore.WebSocketLink
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.util.concurrent.TimeUnit

/**
 * The core's control channel (remote commands, play orders, SyncPlay) over OkHttp's WebSocket. OkHttp is already
 * in the app (Coil's network layer), uses the system trust store like [AndroidHttpClient], and pings so a dead
 * link ends instead of hanging. One object serves all reconnects: `connect` replaces the socket behind it, and a
 * pending `receive` of the old socket fails.
 */
class AndroidWebSocketLink(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .pingInterval(30, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build(),
) : WebSocketLink {

    private class Link {
        /** A text message, `null` for a frame to skip, or the end of the socket as the failure. */
        val inbox = Channel<Result<String?>>(Channel.UNLIMITED)
        @Volatile var socket: WebSocket? = null
    }

    @Volatile private var link: Link? = null

    override suspend fun connect(url: String): Unit {
        link?.let { closeLink() }
        val fresh = Link()
        val opened = CompletableDeferred<Unit>()
        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) { opened.complete(Unit) }
            override fun onMessage(webSocket: WebSocket, text: String) { fresh.inbox.trySend(Result.success(text)) }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) { fresh.inbox.trySend(Result.success(null)) }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(code, reason)
                fresh.inbox.trySend(Result.failure(SocketFailure.Other("closed ($code)")))
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                val failure: SocketFailure =
                    if (response != null) SocketFailure.SetupFailed(response.code) else SocketFailure.Other(t.message ?: t.javaClass.simpleName)
                fresh.inbox.trySend(Result.failure(failure))
                opened.completeExceptionally(failure)
            }
        }
        // OkHttp wants http(s) in the request; the scheme of ws(s) addresses is mapped the same way it does.
        fresh.socket = client.newWebSocket(Request.Builder().url(url.replaceFirst("ws", "http")).build(), listener)
        link = fresh
        opened.await()
    }

    override suspend fun receive(): String? {
        val current = link ?: throw SocketFailure.Other("not connected")
        return current.inbox.receive().getOrThrow()
    }

    override suspend fun send(text: String) {
        val socket = link?.socket ?: throw SocketFailure.Other("not connected")
        if (!socket.send(text)) throw SocketFailure.Other("send failed")
    }

    override fun closeLink() {
        val old = link ?: return
        link = null
        old.socket?.close(1000, null)
        old.inbox.trySend(Result.failure(SocketFailure.Other("closed")))
    }
}
