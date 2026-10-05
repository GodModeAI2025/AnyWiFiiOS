import Foundation

public enum ZipError: Error, Equatable, Sendable {
    case malformed
    case unsupported
}

/// Minimaler ZIP-Writer/-Reader (Methode "stored", ohne Abhängigkeiten, läuft auf Linux).
/// Genügt für Debug-Pakete und `.captiveprofile`-Container.
public enum ZipArchive {
    public struct Entry: Equatable, Sendable {
        public var path: String
        public var data: Data
        public init(path: String, data: Data) { self.path = path; self.data = data }
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    // Fester DOS-Zeitstempel (2026-01-01 00:00), damit Archive reproduzierbar sind.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = UInt16(((2026 - 1980) << 9) | (1 << 5) | 1)

    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

    public static func write(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        for e in entries {
            let name = Data(e.path.utf8)
            let crc = crc32(e.data)
            let offset = UInt32(out.count)
            var local = Data()
            local += le32(0x04034b50) + le16(20) + le16(0x0800) + le16(0) + le16(dosTime) + le16(dosDate)
            local += le32(crc) + le32(UInt32(e.data.count)) + le32(UInt32(e.data.count))
            local += le16(UInt16(name.count)) + le16(0)
            out += local + name + e.data
            central += le32(0x02014b50) + le16(20) + le16(20) + le16(0x0800) + le16(0) + le16(dosTime) + le16(dosDate)
            central += le32(crc) + le32(UInt32(e.data.count)) + le32(UInt32(e.data.count))
            central += le16(UInt16(name.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset)
            central += name
        }
        let cdOffset = UInt32(out.count)
        out += central
        out += le32(0x06054b50) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        out += le32(UInt32(central.count)) + le32(cdOffset) + le16(0)
        return out
    }

    public static func read(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard bytes.count >= 22 else { throw ZipError.malformed }
        var eocd = bytes.count - 22
        while eocd >= 0, u32(eocd) != 0x06054b50 { eocd -= 1 }
        guard eocd >= 0 else { throw ZipError.malformed }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var entries: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x02014b50 else { throw ZipError.malformed }
            let method = u16(p + 10)
            guard method == 0 else { throw ZipError.unsupported }
            let size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let localOffset = u32(p + 42)
            guard p + 46 + nameLen <= bytes.count else { throw ZipError.malformed }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            guard localOffset + 30 <= bytes.count, u32(localOffset) == 0x04034b50 else { throw ZipError.malformed }
            let lNameLen = u16(localOffset + 26), lExtraLen = u16(localOffset + 28)
            let start = localOffset + 30 + lNameLen + lExtraLen
            guard start + size <= bytes.count else { throw ZipError.malformed }
            entries.append(Entry(path: name, data: Data(bytes[start..<(start + size)])))
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }
}
