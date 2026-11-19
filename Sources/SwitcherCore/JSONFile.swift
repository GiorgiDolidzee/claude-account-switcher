import Foundation

public enum JSONFileError: Error, Equatable {
    case notAnObject(String)
    case writeFailed(String)
}

/// Reads and writes files that hold one JSON object, without losing other keys.
public enum JSONFile {
    public static func readObject(_ url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw JSONFileError.notAnObject(url.lastPathComponent)
        }
        return obj
    }

    public static func writeObject(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
        try writeData(data, to: url)
    }

    /// Atomic write: temp file in the same folder, fsync, rename. Keeps the old mode; new files get 0600.
    public static func writeData(_ data: Data, to target: URL) throws {
        let fm = FileManager.default
        // Write through a symlink instead of replacing it.
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil
        let url = isLink ? target.resolvingSymlinksInPath() : target
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o600
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode))
        guard fd >= 0 else { throw JSONFileError.writeFailed(url.lastPathComponent) }
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        fchmod(fd, mode_t(mode))
        fsync(fd)
        close(fd)
        guard ok, rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw JSONFileError.writeFailed(url.lastPathComponent)
        }
    }

    public static func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }

    public static func isEmptyValue(_ value: Any?) -> Bool {
        switch value {
        case nil: return true
        case is NSNull: return true
        case let s as String: return s.isEmpty
        case let a as [Any]: return a.isEmpty
        case let d as [String: Any]: return d.isEmpty
        default: return false
        }
    }
}

/// A JSON object kept as raw text per key, so untouched values stay byte-for-byte the same.
public struct RawJSONObject: Equatable, Sendable {
    public private(set) var entries: [(key: String, value: Data)] = []

    public init() {}

    public static func == (a: RawJSONObject, b: RawJSONObject) -> Bool {
        a.entries.count == b.entries.count && zip(a.entries, b.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    public var keys: [String] { entries.map(\.key) }
    public var isEmpty: Bool { entries.isEmpty }

    public subscript(key: String) -> Data? { entries.first { $0.key == key }?.value }

    public mutating func set(_ key: String, _ value: Data) {
        if let i = entries.firstIndex(where: { $0.key == key }) { entries[i].value = value } else { entries.append((key, value)) }
    }

    public mutating func remove(_ key: String) { entries.removeAll { $0.key == key } }

    public func data() throws -> Data {
        var out = Data("{".utf8)
        for (i, entry) in entries.enumerated() {
            if i > 0 { out.append(0x2C) }
            out.append(try JSONSerialization.data(withJSONObject: entry.key, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            out.append(0x3A)
            out.append(entry.value)
        }
        out.append(0x7D)
        return out
    }

    /// Splits the top level of a JSON object. Values are checked to be valid JSON but kept as text.
    public init(parsing data: Data, name: String) throws {
        let b = [UInt8](data)
        var i = 0
        let bad = JSONFileError.notAnObject(name)
        func skipSpace() { while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 } }
        func scanString() throws {
            guard i < b.count, b[i] == 0x22 else { throw bad }
            i += 1
            while i < b.count, b[i] != 0x22 { i += b[i] == 0x5C ? 2 : 1 }
            guard i < b.count else { throw bad }
            i += 1
        }
        func scanValue() throws {
            guard i < b.count else { throw bad }
            if b[i] == 0x22 { try scanString(); return }
            if b[i] == 0x7B || b[i] == 0x5B {
                var depth = 0
                repeat {
                    guard i < b.count else { throw bad }
                    switch b[i] {
                    case 0x22: try scanString(); continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D: depth -= 1
                    default: break
                    }
                    i += 1
                } while depth > 0
                return
            }
            while i < b.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x0A, 0x0D, 0x09].contains(b[i]) { i += 1 }
        }
        skipSpace()
        guard i < b.count, b[i] == 0x7B else { throw bad }
        i += 1
        skipSpace()
        if i < b.count, b[i] == 0x7D {
            i += 1
        } else {
            while true {
                skipSpace()
                let keyStart = i
                try scanString()
                guard let key = (try? JSONSerialization.jsonObject(with: Data(b[keyStart..<i]), options: [.fragmentsAllowed])) as? String else { throw bad }
                skipSpace()
                guard i < b.count, b[i] == 0x3A else { throw bad }
                i += 1
                skipSpace()
                let valueStart = i
                try scanValue()
                let value = Data(b[valueStart..<i])
                guard !value.isEmpty, (try? JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed])) != nil else { throw bad }
                set(key, value)
                skipSpace()
                guard i < b.count else { throw bad }
                if b[i] == 0x2C { i += 1; continue }
                if b[i] == 0x7D { i += 1; break }
                throw bad
            }
        }
        skipSpace()
        guard i == b.count else { throw bad }
    }
}

extension JSONFile {
    public static func readRaw(_ url: URL) throws -> RawJSONObject? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try RawJSONObject(parsing: Data(contentsOf: url), name: url.lastPathComponent)
    }

    public static func writeRaw(_ obj: RawJSONObject, to url: URL) throws {
        try writeData(try obj.data(), to: url)
    }

    /// True when two raw JSON values mean the same thing.
    public static func sameValue(_ a: Data, _ b: Data) -> Bool {
        if a == b { return true }
        guard let x = try? JSONSerialization.jsonObject(with: a, options: [.fragmentsAllowed]),
              let y = try? JSONSerialization.jsonObject(with: b, options: [.fragmentsAllowed]),
              let cx = try? canonical(x), let cy = try? canonical(y) else { return false }
        return cx == cy
    }
}
