import Logging
import NIOCore
import SocketCommon

/// `NIOStringHandler` is a `ChannelInboundHandler` that decodes incoming `ByteBuffer` data into UTF-8 strings,
/// splitting messages based on a configurable tokenizer (defaulting to newline `\n`). It accumulates partial
/// reads in an internal buffer, ensuring that messages are only forwarded once fully received. Upon decoding
/// a complete message, it forwards the string up the pipeline and asynchronously invokes a user-provided
/// `MessageHandling` instance to process the message. This handler is designed for use with SwiftNIO-based
/// networking applications where line- or token-delimited string protocols are used.
///
/// - Parameters:
///   - logger: Logger instance for diagnostic output.
///   - eventLoop: The `EventLoop` on which asynchronous message handling is scheduled.
///   - messageHandler: An object conforming to `MessageHandling` that processes decoded messages.
///   - tokenizer: The string delimiter used to split incoming data into messages (default: `"\n"`).
///
/// - Important: The tokenizer is assumed to be a single ASCII character. Multi-character or non-ASCII
///   delimiters are not supported.
///
/// - Note: The handler accumulates incoming bytes in a buffer to handle cases where messages arrive in
///   fragments across multiple reads.
///
/// - SeeAlso: `ChannelInboundHandler`, `ByteBuffer`, `MessageHandling`
///
/// A handler that decodes incoming ByteBuffers into UTF-8 strings based on a configurable tokenizer,
/// and forwards them asynchronously.
final class NIOStringHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = String

    private let logger: Logger
    private let messageHandler: MessageHandling
    private let eventLoop: EventLoop
    private let tokenizer: String

    /// Buffer used to accumulate incoming bytes across partial reads.
    private var cumulationBuffer: ByteBuffer

    init(
        _ logger: Logger,
        _ eventLoop: EventLoop,
        _ messageHandler: MessageHandling,
        tokenizer: String = "\n"
    ) {
        self.logger = logger
        self.eventLoop = eventLoop
        self.messageHandler = messageHandler
        self.tokenizer = tokenizer
        self.cumulationBuffer = ByteBufferAllocator().buffer(capacity: 1024)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var byteBuffer = unwrapInboundIn(data)

        // Append incoming data to the buffer
        cumulationBuffer.writeBuffer(&byteBuffer)

        // Decode strings split by tokenizer
        processBufferedMessages(context: context)
    }
    private func processBufferedMessages(context: ChannelHandlerContext) {
        let tokenByte = tokenizer.utf8.first!  // assuming tokenizer is a single ASCII char like "\n"

        while true {
            let readable = cumulationBuffer.readableBytesView

            guard let newlineOffset = readable.firstIndex(of: tokenByte) else {
                // No full message yet
                return
            }

            let length = newlineOffset - cumulationBuffer.readerIndex

            // Read message up to the token
            guard let messageBytes = cumulationBuffer.readSlice(length: length),
                let message = messageBytes.getString(at: 0, length: length)
            else {
                logger.warning("⚠️ Failed to decode message bytes as UTF-8 string.")
                return
            }

            // Skip the token
            _ = cumulationBuffer.readInteger(as: UInt8.self)  // skip the "\n"

            logger.debug("🔵 Received message: \(message)")
            context.fireChannelRead(wrapInboundOut(message))

            // Handle message asynchronously
            let handler = self.messageHandler
            let loop = self.eventLoop
            _ = loop.flatSubmit {
                Task {
                    await handler.handleMessage(message)
                }.futureResult(on: loop)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("🔴 errorCaught: \(error.localizedDescription)")
        context.close(promise: nil)
    }
}
