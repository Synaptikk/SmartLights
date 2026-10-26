// AiDot LAN wire helpers, following python-aidot (device_client.py, discover.py, aes_utils.py).

import Foundation
import NIOCore

/// TCP frame: `>H magic 0x1EED`, `>H msgtype` (1 = login/action, 2 = ping), `>I bodysize`, body.
public struct AiDotFrame: Sendable, Equatable {
    public static let magic: UInt16 = 0x1EED
    public static let headerSize = 8

    public var magic: UInt16
    public var msgType: UInt16
    public var body: [UInt8]

    public init(msgType: UInt16, body: [UInt8], magic: UInt16 = AiDotFrame.magic) {
        self.magic = magic
        self.msgType = msgType
        self.body = body
    }

    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(8 + body.count)
        out += [UInt8(magic >> 8), UInt8(magic & 0xFF), UInt8(msgType >> 8), UInt8(msgType & 0xFF)]
        let n = UInt32(body.count)
        out += [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        out += body
        return out
    }

    /// Reads one frame if a complete one is buffered.
    public static func decode(from buffer: inout ByteBuffer) -> AiDotFrame? {
        guard buffer.readableBytes >= headerSize,
            let magic = buffer.getInteger(at: buffer.readerIndex, as: UInt16.self),
            let type = buffer.getInteger(at: buffer.readerIndex + 2, as: UInt16.self),
            let size = buffer.getInteger(at: buffer.readerIndex + 4, as: UInt32.self),
            buffer.readableBytes >= headerSize + Int(size)
        else { return nil }
        buffer.moveReaderIndex(forwardBy: headerSize)
        let body = buffer.readBytes(length: Int(size)) ?? []
        return AiDotFrame(msgType: type, body: body, magic: magic)
    }

    /// Encrypts `json` with AES-128-ECB/PKCS7 under `key` (device aesKey[0] padded to 16 bytes).
    public static func encrypted(_ json: JSON, msgType: UInt16, key: [UInt8]) throws -> AiDotFrame {
        AiDotFrame(msgType: msgType, body: try SimCrypto.aesECBEncrypt(Array(json.compact.utf8), key: key))
    }

    public func decryptedJSON(key: [UInt8]) throws -> JSON {
        try JSON.parse(try SimCrypto.aesECBDecrypt(body, key: key))
    }
}

struct AiDotFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = AiDotFrame

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let frame = AiDotFrame.decode(from: &buffer) else { return .needMoreData }
        context.fireChannelRead(wrapInboundOut(frame))
        return .continue
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws
        -> DecodingState
    {
        try decode(context: context, buffer: &buffer)
    }
}

/// AiDot cloud constants (python-aidot const.py / login_const.py).
public enum AiDotConstants {
    public static let appId = "1383974540041977857"
    public static let tokenExpired = 21026
    public static let loginInvalid = 21025
    public static let userPasswordIncorrect = 560080
    public static let discoveryPort = 6666
    public static let tcpPort = 10000

    /// `int32` RGBW packing used by python-aidot: `(r<<24)|(g<<16)|(b<<8)|w` as signed.
    public static func packRGBW(r: UInt8, g: UInt8, b: UInt8, w: UInt8) -> Int {
        Int(Int32(bitPattern: UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(w)))
    }

    public static func unpackRGBW(_ v: Int) -> (r: UInt8, g: UInt8, b: UInt8, w: UInt8) {
        let u = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
        return (UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF))
    }
}
