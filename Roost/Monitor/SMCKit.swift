import Foundation
import IOKit

/// Talks to the System Management Controller.
///
/// The SMC is the microcontroller that owns the machine's thermal and power
/// telemetry: temperatures, voltages, currents, wattages and fan speeds. It
/// is reached through `AppleSMC`, an IOKit service, with a single selector
/// and a fixed request struct -- there is no framework wrapper and no public
/// header, so the struct layout below is the interface.
///
/// Three commands are enough for reading:
///
///   - `readKeyInfo` asks what a key's value looks like: how many bytes and
///     in which encoding.
///   - `readBytes` fetches those bytes.
///   - `readIndex` walks the key table by position, which with the `#KEY`
///     count is how the full list is discovered.
///
/// Nothing here writes. The SMC will happily take fan-control commands and
/// this deliberately cannot send them: a reading tool has no business
/// driving the cooling.
final class SMCKit {

    static let shared = SMCKit()

    // MARK: - Wire format

    private struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
    }

    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    /// 32 bytes, the largest payload the SMC returns.
    private typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    private struct KeyData {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        /// Explicit, not an oversight. In C the field after `keyInfo` lands
        /// on the next 4-byte boundary; Swift packs its own structs more
        /// tightly, so without these two bytes every field below sits two
        /// bytes early and the controller answers nothing at all.
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private enum Command: UInt8 {
        case readBytes = 5
        case readIndex = 8
        case readKeyInfo = 9
    }

    /// The one selector `AppleSMC` answers for this protocol.
    private static let handleYPCEvent: UInt32 = 2

    // MARK: - Connection

    private var connection: io_connect_t = 0
    private let lock = NSLock()

    private init() {
        open()
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    private func open() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        IOServiceOpen(service, mach_task_self_, 0, &connection)
    }

    var isAvailable: Bool { connection != 0 }

    // MARK: - Keys

    /// Every key the controller publishes, in table order.
    ///
    /// The table is walked by index rather than guessed at from a list of
    /// known names: which keys exist differs by model and firmware, and a
    /// hard-coded table is wrong on the next Mac.
    func allKeys() -> [String] {
        // The table is fixed for the life of the boot, and walking it is one
        // round trip per key -- 1,763 on an M2 -- so it is walked once. It
        // was walked on every sensor read, which made the key table, not the
        // readings, the single largest cost of the Sensors module.
        if let cachedKeys { return cachedKeys }
        guard let count = readUInt32(key: "#KEY") else { return [] }

        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        for index in 0..<count {
            var input = KeyData()
            input.data8 = Command.readIndex.rawValue
            input.data32 = index
            guard let output = call(input) else { continue }
            let name = Self.string(from: output.key)
            if !name.isEmpty { keys.append(name) }
        }
        if !keys.isEmpty { cachedKeys = keys }
        return keys
    }

    private var cachedKeys: [String]?

    // MARK: - Reading

    /// A key's value as a Double, whatever encoding the SMC used for it.
    ///
    /// nil when the key is absent, unreadable, or in an encoding this does
    /// not decode -- never a zero, because zero is a real reading and
    /// "no answer" is not.
    func value(_ key: String) -> Double? {
        guard let (info, bytes) = read(key) else { return nil }
        return Self.decode(bytes, type: Self.string(from: info.dataType),
                           size: Int(info.dataSize))
    }

    /// The raw four-character type code, for deciding what a key means.
    func type(_ key: String) -> String? {
        guard let info = keyInfo(key) else { return nil }
        return Self.string(from: info.dataType)
    }

    /// A key whose payload is text rather than a number -- fan names are
    /// stored this way.
    func stringValue(_ key: String) -> String? {
        guard let (info, bytes) = read(key), info.dataSize > 0 else { return nil }
        let text = String(bytes: bytes.prefix(Int(info.dataSize)).filter { $0 != 0 },
                          encoding: .utf8)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private func readUInt32(key: String) -> UInt32? {
        guard let (info, bytes) = read(key), info.dataSize >= 4 else { return nil }
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
             | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    private func keyInfo(_ key: String) -> KeyInfo? {
        var input = KeyData()
        input.key = Self.code(from: key)
        input.data8 = Command.readKeyInfo.rawValue
        guard let output = call(input), output.keyInfo.dataSize > 0 else { return nil }
        return output.keyInfo
    }

    private func read(_ key: String) -> (KeyInfo, [UInt8])? {
        guard let info = keyInfo(key), info.dataSize <= 32 else { return nil }

        var input = KeyData()
        input.key = Self.code(from: key)
        input.keyInfo = info
        input.data8 = Command.readBytes.rawValue
        guard let output = call(input) else { return nil }

        var bytes = [UInt8](repeating: 0, count: 32)
        withUnsafeBytes(of: output.bytes) { raw in
            for i in 0..<32 { bytes[i] = raw[i] }
        }
        return (info, bytes)
    }

    private func call(_ input: KeyData) -> KeyData? {
        guard connection != 0 else { return nil }

        var input = input
        var output = KeyData()
        var outputSize = MemoryLayout<KeyData>.stride

        // The connection is a single kernel channel; two threads sharing one
        // request struct get each other's answers.
        lock.lock()
        let result = IOConnectCallStructMethod(connection, Self.handleYPCEvent,
                                               &input, MemoryLayout<KeyData>.stride,
                                               &output, &outputSize)
        lock.unlock()

        // `result` is the IOKit call; `output.result` is the SMC's own verdict,
        // and a key that does not exist fails there rather than here.
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    // MARK: - Encoding

    /// Four-character codes travel as a big-endian UInt32.
    private static func code(from key: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in key.utf8.prefix(4) { value = (value << 8) | UInt32(byte) }
        return value
    }

    private static func string(from code: UInt32) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes.filter { $0 != 0 }, encoding: .utf8) ?? ""
    }

    /// Decodes the SMC's numeric encodings.
    ///
    /// `flt ` is an IEEE single. The `spXY` and `fpXY` families are fixed
    /// point, signed and unsigned respectively, where the digits say how
    /// many bits fall after the point -- `sp78` is 7 integer bits and 8
    /// fractional, `fpe2` is 14 and 2. Decoding them from the name rather
    /// than listing every variant means a type this has never seen still
    /// reads correctly.
    static func decode(_ bytes: [UInt8], type: String, size: Int) -> Double? {
        guard size > 0, bytes.count >= size else { return nil }
        let head = Array(bytes.prefix(size))

        func unsigned() -> UInt64 {
            head.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }

        switch type {
        case "flt ":
            guard size == 4 else { return nil }
            // Little-endian on every Mac that reports this type.
            let bits = UInt32(head[0]) | (UInt32(head[1]) << 8)
                     | (UInt32(head[2]) << 16) | (UInt32(head[3]) << 24)
            let value = Float(bitPattern: bits)
            return value.isFinite ? Double(value) : nil

        case "ui8 ", "ui16", "ui32", "ui64":
            return Double(unsigned())

        case "si8 ", "si16", "si32":
            let raw = unsigned()
            let bits = UInt64(size * 8)
            let sign = UInt64(1) << (bits - 1)
            return raw >= sign ? Double(Int64(raw) - Int64(sign << 1)) : Double(raw)

        case "hex_", "ch8*", "{ala", "{alc", "{ali", "{alp", "{alr", "{alv":
            // Structured or opaque payloads: not a single number.
            return nil

        default:
            // sp78 / fp88 / fpe2 and the rest of the fixed-point family.
            guard type.count == 4 else { return nil }
            let kind = type.prefix(2)
            guard kind == "sp" || kind == "fp",
                  let fraction = UInt32(String(type.suffix(1)), radix: 16)
            else { return nil }

            let raw = unsigned()
            let divisor = Double(1 << fraction)
            if kind == "sp" {
                let bits = UInt64(size * 8)
                let sign = UInt64(1) << (bits - 1)
                let signed = raw >= sign ? Double(Int64(raw) - Int64(sign << 1)) : Double(raw)
                return signed / divisor
            }
            return Double(raw) / divisor
        }
    }
}
