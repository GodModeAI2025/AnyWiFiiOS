import Foundation

/// Minimaler ZIP-Container (nur Methode „stored“, ohne Kompression) für Debug-Pakete und
/// `.captiveprofile`-Dateien. Plattformneutral, keine Abhängigkeiten. Feste Zeitstempel → deterministische Dateien.
public enum ZipArchive {
    public struct Entry: Equatable, Sendable {
        public var path: String
        public var data: Data

        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }

        public init(path: String, text: String) {
            self.init(path: path, data: Data(text.utf8))
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalidPath(String)
        case duplicatePath(String)
        case tooLarge
        case malformed(String)
        case unsupportedCompression(path: String, method: Int)
        case checksumMismatch(String)
    }

    /// Obergrenzen beim Lesen fremder Dateien (Schutz vor ZIP-Bomben und absurden Importen).
    public static let maxEntries = 256
    public static let maxTotalBytes = 16 * 1024 * 1024

    // MARK: Schreiben

    public static func write(_ entries: [Entry]) throws -> Data {
        var seen = Set<String>()
        var out = Data()
        var central = Data()
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = 0x0021 // 1980-01-01

        for entry in entries {
            guard isSafePath(entry.path) else { throw Failure.invalidPath(entry.path) }
            guard seen.insert(entry.path).inserted else { throw Failure.duplicatePath(entry.path) }
            guard entry.data.count < Int(UInt32.max), out.count < Int(UInt32.max) else { throw Failure.tooLarge }
            let name = Data(entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            let offset = UInt32(out.count)
            let size = UInt32(entry.data.count)

            out.appendLE(UInt32(0x0403_4B50))
            out.appendLE(UInt16(20))       // version needed
            out.appendLE(UInt16(0x0800))   // Flag: Dateinamen in UTF-8
            out.appendLE(UInt16(0))        // stored
            out.appendLE(dosTime)
            out.appendLE(dosDate)
            out.appendLE(crc)
            out.appendLE(size)
            out.appendLE(size)
            out.appendLE(UInt16(name.count))
            out.appendLE(UInt16(0))
            out.append(name)
            out.append(entry.data)

            central.appendLE(UInt32(0x0201_4B50))
            central.appendLE(UInt16(20))   // version made by
            central.appendLE(UInt16(20))   // version needed
            central.appendLE(UInt16(0x0800))
            central.appendLE(UInt16(0))
            central.appendLE(dosTime)
            central.appendLE(dosDate)
            central.appendLE(crc)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0))    // extra
            central.appendLE(UInt16(0))    // comment
            central.appendLE(UInt16(0))    // disk
            central.appendLE(UInt16(0))    // internal attributes
            central.appendLE(UInt32(0))    // external attributes
            central.appendLE(offset)
            central.append(name)
        }

        let centralOffset = UInt32(out.count)
        out.append(central)
        out.appendLE(UInt32(0x0605_4B50))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(central.count))
        out.appendLE(centralOffset)
        out.appendLE(UInt16(0))
        return out
    }

    // MARK: Lesen

    /// Liest Archive, die `write` erzeugt hat (und andere ZIPs mit Methode „stored“).
    public static func read(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw Failure.malformed("zu kurz") }
        // End of Central Directory suchen (Kommentar max. 64 KiB).
        var eocd = -1
        var i = bytes.count - 22
        let lowerBound = max(0, bytes.count - 22 - 65_535)
        while i >= lowerBound {
            if bytes.readLE32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure.malformed("kein Central Directory") }
        let count = Int(bytes.readLE16(eocd + 10))
        var cursor = Int(bytes.readLE32(eocd + 16))
        guard count <= maxEntries else { throw Failure.tooLarge }

        var entries: [Entry] = []
        var total = 0
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, bytes.readLE32(cursor) == 0x0201_4B50 else {
                throw Failure.malformed("Central-Directory-Eintrag")
            }
            let method = Int(bytes.readLE16(cursor + 10))
            let crc = bytes.readLE32(cursor + 16)
            let compressed = Int(bytes.readLE32(cursor + 20))
            let nameLength = Int(bytes.readLE16(cursor + 28))
            let extraLength = Int(bytes.readLE16(cursor + 30))
            let commentLength = Int(bytes.readLE16(cursor + 32))
            let localOffset = Int(bytes.readLE32(cursor + 42))
            guard cursor + 46 + nameLength <= bytes.count else { throw Failure.malformed("Name") }
            let path = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            cursor += 46 + nameLength + extraLength + commentLength

            guard isSafePath(path) else { throw Failure.invalidPath(path) }
            if path.hasSuffix("/") { continue } // Verzeichniseintrag
            guard method == 0 else { throw Failure.unsupportedCompression(path: path, method: method) }
            total += compressed
            guard total <= maxTotalBytes else { throw Failure.tooLarge }

            guard localOffset + 30 <= bytes.count, bytes.readLE32(localOffset) == 0x0403_4B50 else {
                throw Failure.malformed("Lokaler Header \(path)")
            }
            let localName = Int(bytes.readLE16(localOffset + 26))
            let localExtra = Int(bytes.readLE16(localOffset + 28))
            let start = localOffset + 30 + localName + localExtra
            guard start + compressed <= bytes.count else { throw Failure.malformed("Daten \(path)") }
            let content = Data(bytes[start..<(start + compressed)])
            guard CRC32.checksum(content) == crc else { throw Failure.checksumMismatch(path) }
            entries.append(Entry(path: path, data: content))
        }
        return entries
    }

    /// Relative Pfade ohne `..`, ohne absolute Pfade, ohne Backslashes.
    static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), path.utf8.count < 512 else { return false }
        return !path.split(separator: "/").contains("..")
    }
}

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}

extension Array where Element == UInt8 {
    func readLE16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readLE32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1]) << 8
        let b2 = UInt32(self[offset + 2]) << 16
        let b3 = UInt32(self[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}
