import Foundation
import CryptoKit

struct Configuration: Codable {
    let MacIP: String
    let Port: UInt16
    let Key: String
    let DownloadToken: String?
}

struct AudioPacket {
    let session: Data
    let sequence: UInt32
    let rate: Int
    let frames: Int
    let pcm: Data

    static func decode(_ data: Data, key: SymmetricKey) -> AudioPacket? {
        guard data.count >= 44, data.count <= 1000,
              Array(data.prefix(4)) == Array("WAM1".utf8) else { return nil }
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        let rate = Int(u32(16)), frames = u16(22)
        guard (8000...192000).contains(rate), u16(20) == 2,
              (1...240).contains(frames), data.count == 24 + frames * 4 + 16 else { return nil }
        do {
            let nonce = try AES.GCM.Nonce(data: data[4..<16])
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: data[24..<(data.count - 16)], tag: data.suffix(16))
            let pcm = try AES.GCM.open(box, using: key, authenticating: data.prefix(24))
            return AudioPacket(session: Data(data[4..<12]), sequence: u32(12), rate: rate, frames: frames, pcm: pcm)
        } catch { return nil }
    }
}

// Reject duplicates and old packets; an active stream cannot be replaced by another sender.
struct SequenceGate {
    var session: Data?
    var sequence: UInt32?
    var lastSeen: TimeInterval = 0
    mutating func accept(_ packet: AudioPacket, now: TimeInterval) -> (reset: Bool, missing: Int)? {
        let expired = now - lastSeen > 0.5
        if let session, session != packet.session, !expired { return nil }
        let reset = session != packet.session || expired
        if !reset, let sequence, packet.sequence <= sequence { return nil }
        let missing = !reset && sequence != nil ? Int(packet.sequence - sequence! - 1) : 0
        session = packet.session; sequence = packet.sequence; lastSeen = now
        return (reset, missing)
    }
}
