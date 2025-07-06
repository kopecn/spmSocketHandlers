import Foundation
import NIOCore
import Logging
import SocketCommon

/// A ChannelInboundHandler that observes individual connection events for a server.
///
/// This handler emits `.activeConnections`, `.disconnected`, or `.error(err)` based on channel activity.
/// It's intended to be attached to **per-client channels** on the server side.
final class NIOServerConnectionStateHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let onStateChange: (SocketServerListeningState) -> Void
    private let logger: Logger

    init(
        logger: Logger,
        onStateChange: @escaping (SocketServerListeningState) -> Void
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
        logger.info("🟢 Channel became inactive.")
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
