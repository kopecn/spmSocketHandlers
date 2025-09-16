import Foundation
import Logging
import NIOCore
import SocketCommon

/// A ChannelInboundHandler that observes connection state changes and notifies the caller.
///
/// This handler emits `.connected`, `.disconnected`, or `.error(err)` events based on channel lifecycle.
class NIOClientConnectionStateHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let onStateChange: (SocketClientConnectionState) -> Void
    private let logger: Logger

    init(
        logger: Logger,
        onStateChange: @escaping (SocketClientConnectionState) -> Void
    ) {
        self.logger = logger
        self.onStateChange = onStateChange
    }

    func channelActive(context: ChannelHandlerContext) {
        logger.info("🟢 Channel became active.")
        onStateChange(.connected)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        logger.info("🟢 Channel became inactive.")
        onStateChange(.disconnected)
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
