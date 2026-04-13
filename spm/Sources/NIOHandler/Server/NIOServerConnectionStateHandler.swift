import Foundation
import Logging
import NIOCore
import SocketCommon

/// A ChannelInboundHandler that observes individual connection events for a server.
///
/// This handler emits `.activeConnections`, `.disconnected`, or `.error(err)` based on channel activity.
/// It's intended to be attached to **per-client channels** on the server side.
final class NIOServerConnectionStateHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let onStateChange: @Sendable (SocketServerListeningState) -> Void
    private let logger: Logger

    init(
        logger: Logger,
        onStateChange: @escaping @Sendable (SocketServerListeningState) -> Void
    ) {
        self.logger = logger
        self.onStateChange = onStateChange
    }

    func channelActive(context: ChannelHandlerContext) {
        logger.info("🟢 Channel became active.")
        onStateChange(.activeConnections)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        logger.info("🔴 Channel became inactive.")
        // Note: onStateChange is intentionally NOT called here. The server tracks per-client
        // disconnection via channel.closeFuture.whenComplete in setupChildChannel, which gives
        // it access to the client key needed for cleanup. This handler is only used to emit
        // .activeConnections and .error(err:) state changes.
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let nioError = error as? IOError {
            switch nioError.errnoCode {
            case ECONNRESET:
                logger.warning("🔄 Connection reset by peer (ECONNRESET).")
            default:
                logger.error("🔴 IO error: \(nioError)")
            }
        } else {
            logger.error("🔴 Non-IO error: \(error)")
        }

        onStateChange(.error(err: error))
        context.fireErrorCaught(error)
    }
}
