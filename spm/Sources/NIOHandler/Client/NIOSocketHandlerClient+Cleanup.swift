import Logging
import NIOCore
import NIOPosix
import SocketCommon

final class LineBasedFrameDecoder: ByteToMessageDecoder, Sendable {
    typealias InboundOut = ByteBuffer

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if let bytes = buffer.readSlice(length: buffer.readableBytes),
            let newlineIndex = bytes.readableBytesView.firstIndex(of: UInt8(ascii: "\n"))
        {
            let length = newlineIndex - bytes.readerIndex + 1
            if let frame = buffer.readSlice(length: length) {
                context.fireChannelRead(wrapInboundOut(frame))
                return .continue
            }
        }
        return .needMoreData
    }
}

// print("Please enter line to send to the server")
// let line = readLine(strippingNewline: true)!

// private final class EchoHandler: ChannelInboundHandler {
//     public typealias InboundIn = ByteBuffer
//     public typealias OutboundOut = ByteBuffer
//     private var sendBytes = 0
//     private var receiveBuffer: ByteBuffer = ByteBuffer()

//     public func channelActive(context: ChannelHandlerContext) {
//         print("Client connected to \(context.remoteAddress?.description ?? "unknown")")

//         // We are connected. It's time to send the message to the server to initialize the ping-pong sequence.
//         let buffer = context.channel.allocator.buffer(string: line)
//         self.sendBytes = buffer.readableBytes
//         context.writeAndFlush(Self.wrapOutboundOut(buffer), promise: nil)
//     }

//     public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
//         var unwrappedInboundData = Self.unwrapInboundIn(data)
//         self.sendBytes -= unwrappedInboundData.readableBytes
//         receiveBuffer.writeBuffer(&unwrappedInboundData)

//         if self.sendBytes == 0 {
//             let string = String(buffer: receiveBuffer)
//             print("Received: '\(string)' back from the server, closing channel.")
//             context.close(promise: nil)
//         }
//     }

//     public func errorCaught(context: ChannelHandlerContext, error: Error) {
//         print("error: ", error)

//         // As we are not really interested getting notified on success or failure we just pass nil as promise to
//         // reduce allocations.
//         context.close(promise: nil)
//     }
// }

//////////
///
/// A simple newline based encoder and decoder.
private final class NewlineDelimiterCoder: ByteToMessageDecoder, MessageToByteEncoder {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = String

    private let newLine = UInt8(ascii: "\n")

    init() {}

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let readableBytes = buffer.readableBytesView

        if let firstLine = readableBytes.firstIndex(of: newLine).map({ readableBytes[..<$0] }) {
            buffer.moveReaderIndex(forwardBy: firstLine.count + 1)
            // Fire a read without a newline
            context.fireChannelRead(Self.wrapInboundOut(String(buffer: ByteBuffer(firstLine))))
            return .continue
        } else {
            return .needMoreData
        }
    }

    func encode(data: String, out: inout ByteBuffer) throws {
        out.writeString(data)
        out.writeInteger(newLine)
    }
}
