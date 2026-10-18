import AppKit
import IOKit
import Metal
import UniformTypeIdentifiers

/// What this Mac is: the facts that do not change while Roost runs.
///
/// Read once and cached, because every one of them is a `sysctl`, an IOKit
/// registry walk or a disk query, and none of them can change without a
/// reboot — except uptime, which is computed from the boot time rather than
/// stored.
///
/// Written against public APIs: `sysctlbyname` for the processor and memory,
/// `IOPlatformExpertDevice` for the model and serial, `NSScreen` for the
/// display, `URLResourceValues` for the volume, `MTLCreateSystemDefaultDevice`
/// for the GPU. Nothing here is private and nothing needs a permission.
enum DeviceInfo {

    // MARK: - Model

    struct Model {
        /// The marketing name, when macOS knows one: "MacBook Air 13\" (M2)".
        let name: String
        /// The hardware identifier: "Mac14,2".
        let identifier: String
        /// Four-digit year, when it can be determined.
        let year: Int?
        let icon: NSImage?
    }

    static let model: Model = {
        let identifier = platformString("model") ?? "Unknown"
        let name = marketingName() ?? identifier
        // Apple puts the year in the marketing name for older Macs; Apple
        // Silicon names carry the chip instead, so a missing year is normal
        // and shown as Unknown rather than guessed at.
        let year = name.range(of: #"\b20\d{2}\b"#, options: .regularExpression)
            .flatMap { Int(name[$0]) }
        return Model(name: name, identifier: identifier, year: year,
                     icon: modelIcon(identifier))
    }()

    /// The readable name: "MacBook Air (M2, 2022)".
    ///
    /// Published in the device tree at `IODeviceTree:/product`, not on
    /// IOPlatformExpertDevice, which carries only the identifier. Falling back
    /// to the identifier would show a user "Mac14,2" where they expect the
    /// name of their Mac.
    private static func marketingName() -> String? {
        let name = entryString("IODeviceTree:/product", "product-name")
        return (name?.isEmpty ?? true) ? nil : name
    }

    /// A string property on a device-tree entry addressed by path.
    private static func entryString(_ path: String, _ key: String) -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let raw = IORegistryEntryCreateCFProperty(entry, key as CFString,
                                                        kCFAllocatorDefault, 0)?
                .takeRetainedValue() else { return nil }
        if let data = raw as? Data {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        return raw as? String
    }

    /// The picture of this Mac that Finder and About This Mac show.
    ///
    /// Asked of Launch Services by hardware identifier: the system declares
    /// a type for every Mac model, tagged with its identifier under
    /// `com.apple.device-model-code` ("MacBookAir10,1" is
    /// `com.apple.macbookair-late-2020`), and the icon for that type is the
    /// machine's own picture -- the mapping Finder itself uses.
    ///
    /// This replaced matching the marketing name against the icon files in
    /// CoreTypes.bundle, which guessed: "MacBook Air (M1, 2020)" looked for a
    /// file with both "macbookair" and "2020" in its name, but the M1 Air
    /// shares the 2018 design and its files say 2018, so it got the generic
    /// iMac picture. An identifier the system does not know comes back as a
    /// dynamic type, and gets the generic Mac icon rather than a wrong one.
    private static func modelIcon(_ identifier: String) -> NSImage? {
        let modelCode = UTTagClass(rawValue: "com.apple.device-model-code")
        for tag in [identifier] + colouredTags(of: identifier) {
            if let type = UTType(tag: tag, tagClass: modelCode, conformingTo: nil),
               !type.isDynamic {
                return NSWorkspace.shared.icon(for: type)
            }
        }
        guard let type = UTType("com.apple.mac") else { return nil }
        let generic = NSWorkspace.shared.icon(for: type)
        return generic.size.width > 0 ? generic : nil
    }

    /// The colour variants the system declares for a model -- tags like
    /// `MacBook10,1@ECOLOR=225,225,223`.
    ///
    /// For when the bare identifier is not declared at all. Of the 248 Mac
    /// model tags CoreTypes declares, one model, the 2017 12" MacBook, exists
    /// only with a colour attached, so its plain identifier resolved to
    /// nothing and it got the generic icon. Any colour of the right model is
    /// the right machine.
    private static func colouredTags(of identifier: String) -> [String] {
        let info = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Info.plist"
        guard let plist = NSDictionary(contentsOfFile: info),
              let types = plist["UTExportedTypeDeclarations"] as? [[String: Any]]
        else { return [] }
        return types.flatMap { declaration -> [String] in
            let spec = declaration["UTTypeTagSpecification"] as? [String: Any]
            let tags = spec?["com.apple.device-model-code"]
            return (tags as? [String]) ?? [(tags as? String)].compactMap { $0 }
        }.filter { $0.hasPrefix(identifier + "@") }
    }

    /// A string property from the platform expert — model, serial, and the
    /// product name on Apple Silicon.
    private static func platformString(_ key: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                        kCFAllocatorDefault, 0)?
                .takeRetainedValue() else { return nil }
        if let data = raw as? Data {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        return raw as? String
    }

    static let serialNumber: String? = platformString("IOPlatformSerialNumber")

    // MARK: - Operating system

    struct OS {
        /// "macOS Tahoe", or plain "macOS" for a release `MacOSRelease` does
        /// not know.
        let name: String
        /// Always major.minor.patch, which the diagnostics report compares.
        let version: String
        let build: String
        /// "macOS Tahoe 26.1" or "macOS 27.0", for reading.
        let description: String
    }

    static let os: OS = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return OS(name: MacOSRelease.name(major: v.majorVersion).map { "macOS \($0)" } ?? "macOS",
                  version: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                  build: platformBuild() ?? "",
                  description: MacOSRelease.describe(major: v.majorVersion, minor: v.minorVersion,
                                                     patch: v.patchVersion))
    }()

    private static func platformBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Processor

    struct CPU {
        let name: String?
        let physicalCores: Int?
        let logicalCores: Int?
        /// Apple Silicon reports its cores split by kind.
        let efficiencyCores: Int?
        let performanceCores: Int?
    }

    static let cpu: CPU = CPU(
        name: sysctlString("machdep.cpu.brand_string"),
        physicalCores: sysctlInt("hw.physicalcpu"),
        logicalCores: sysctlInt("hw.logicalcpu"),
        efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu"),
        performanceCores: sysctlInt("hw.perflevel0.physicalcpu")
    )

    // MARK: - Memory

    /// Total physical memory in bytes.
    static let memory: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)

    // MARK: - Graphics

    /// The Metal device's name with its core count: "Apple M2 (8 cores)".
    ///
    /// The count is not on MTLDevice; it is `gpu-core-count` on the
    /// AGXAccelerator service, which exists only on Apple Silicon — an Intel
    /// Mac gets the name alone rather than a wrong number.
    static let gpu: String? = {
        guard let name = MTLCreateSystemDefaultDevice()?.name else { return nil }
        guard let cores = gpuCoreCount() else { return name }
        return "\(name) (\(cores) cores)"
    }()

    private static func gpuCoreCount() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AGXAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            if let count = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString,
                                                           kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int {
                return count
            }
        }
        return nil
    }

    // MARK: - Storage

    struct Volume {
        let name: String
        let capacity: Int64
    }

    static let volumes: [Volume] = {
        // Root file systems only. "Internal" is also true of a mounted disk
        // image on an internal disk, which put a 2.5 GB scratch volume in the
        // list beside the boot drive.
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        guard let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                                 options: [.skipHiddenVolumes])
        else { return [] }
        return mounted.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsInternal == true,
                  values.volumeIsRootFileSystem == true,
                  let name = values.volumeName,
                  let capacity = values.volumeTotalCapacity else { return nil }
            return Volume(name: name, capacity: Int64(capacity))
        }
    }()

    /// The physical storage device, as opposed to the volume on it.
    ///
    /// "Macintosh HD" is a volume; "APPLE SSD AP0256Z" is the drive. Neither
    /// the old pane nor the first version of this one showed the drive at all,
    /// is what "SSD information not showing" was about -- the row named the
    /// volume and stopped.
    ///
    /// Read from `Device Characteristics` on IOBlockStorageDevice. Mounted
    /// disk images show up there too and are filtered out: they are not
    /// hardware.
    struct Drive {
        let name: String
        /// "Solid State" or "Rotational".
        let medium: String
    }

    static let drives: [Drive] = {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDevice"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [Drive] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let characteristics = IORegistryEntryCreateCFProperty(
                    service, "Device Characteristics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let product = (characteristics["Product Name"] as? String)?
                    .trimmingCharacters(in: .whitespaces),
                  !product.isEmpty,
                  // A mounted .dmg is an IOBlockStorageDevice with no medium.
                  let medium = characteristics["Medium Type"] as? String,
                  !medium.isEmpty
            else { continue }

            let vendor = (characteristics["Vendor Name"] as? String)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let name = vendor.isEmpty || product.hasPrefix(vendor) ? product : "\(vendor) \(product)"
            found.append(Drive(name: name, medium: medium))
        }
        return found
    }()

    // MARK: - Display

    /// A display: what the panel is, and what it is doing now.
    ///
    /// Three resolutions, because there are three and they were being
    /// confused. The row used to print the frame times the backing scale --
    /// 2940×1912 on this M2 Air -- and call it the display. That is the
    /// buffer macOS renders the scaled desktop into; the panel itself is
    /// 2560×1664, and the desktop looks like 1470×956. Measured with
    /// CGDisplayCopyAllDisplayModes: the native-flagged mode is 2560×1664,
    /// the current mode's pixels are 2940×1912, and the largest mode on offer
    /// (3420×2224) is a scaled mode, not the panel -- so "the biggest mode"
    /// is not a usable stand-in for native either.
    struct Display {
        let name: String
        let isBuiltIn: Bool
        /// Diagonal in inches, from the panel's physical size, to a tenth.
        /// A tenth because the whole inch was wrong: this Air's panel
        /// measures 290.6 × 189.0 mm, a 13.6-inch diagonal -- Apple's figure
        /// for it -- which rounded to 14.
        let inches: Double?
        /// The panel's own pixels: the mode the driver flags as native. nil
        /// where no mode carries the flag, rather than a guess.
        let native: (width: Int, height: Int)?
        /// The desktop's size in points -- what "Looks like" means in
        /// Displays settings.
        let looksLike: (width: Int, height: Int)
        /// The buffer the desktop is drawn into before it is scaled to the
        /// panel.
        let rendered: (width: Int, height: Int)
        /// The current mode's refresh rate. nil where the mode reports 0,
        /// which a variable-rate panel does.
        let refreshHz: Int?
        /// The fastest the screen can refresh, from NSScreen.
        let maximumHz: Int
    }

    /// The IOKit flag on the panel's own mode (IOGraphicsTypes.h).
    private static let nativeModeFlag: UInt32 = 0x0200_0000

    static var displays: [Display] {
        NSScreen.screens.map { screen in
            let frame = screen.frame
            let scale = screen.backingScaleFactor
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

            var inches: Double?
            var native: (Int, Int)?
            var refresh: Int?
            var builtIn = false
            var rendered = (Int(frame.width * scale), Int(frame.height * scale))
            if let number {
                builtIn = CGDisplayIsBuiltin(number) != 0
                let mm = CGDisplayScreenSize(number)
                if mm.width > 0 && mm.height > 0 {
                    inches = ((sqrt(mm.width * mm.width + mm.height * mm.height) / 25.4) * 10).rounded() / 10
                }
                if let mode = CGDisplayCopyDisplayMode(number) {
                    rendered = (mode.pixelWidth, mode.pixelHeight)
                    refresh = mode.refreshRate > 0 ? Int(mode.refreshRate.rounded()) : nil
                }
                // The duplicate low-resolution modes have to be asked for:
                // without them the list can leave out the native mode.
                let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
                let modes = (CGDisplayCopyAllDisplayModes(number, options) as? [CGDisplayMode]) ?? []
                native = modes.first { $0.ioFlags & nativeModeFlag != 0 }
                    .map { ($0.pixelWidth, $0.pixelHeight) }
            }
            return Display(name: screen.localizedName,
                           isBuiltIn: builtIn,
                           inches: inches,
                           native: native,
                           looksLike: (Int(frame.width), Int(frame.height)),
                           rendered: rendered,
                           refreshHz: refresh,
                           maximumHz: screen.maximumFramesPerSecond)
        }
    }

    // MARK: - Uptime

    /// When the machine last booted, from `kern.boottime`.
    static let bootDate: Date? = {
        var timeval = timeval()
        var size = MemoryLayout<Foundation.timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &timeval, &size, nil, 0) == 0, timeval.tv_sec != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(timeval.tv_sec))
    }()

    // MARK: - sysctl

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return value
    }
}

// MARK: - Device facts

// Pure, and here rather than with the Dashboard that shows them, because
// Tools/hardware-report.swift compiles this file on its own.

enum MacOSRelease {

    /// The marketing name of a major version, where it is known for certain.
    ///
    /// A table, because there is no public API for it: `sw_vers` and
    /// `ProcessInfo` give "macOS" and a number. It used to end in
    /// `case 26...: "macOS Tahoe"`, which named every future release Tahoe --
    /// and this Mac, measured, runs 27.0 and was called Tahoe. A release this
    /// table has not met gets the version alone, which is never wrong.
    static func name(major: Int) -> String? {
        switch major {
        case 26: return "Tahoe"
        case 15: return "Sequoia"
        case 14: return "Sonoma"
        case 13: return "Ventura"
        case 12: return "Monterey"
        case 11: return "Big Sur"
        default: return nil
        }
    }

    /// "27.0", "26.1", "15.6.1": the form `sw_vers` prints, with a patch
    /// only when there is one.
    static func version(major: Int, minor: Int, patch: Int) -> String {
        patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    /// "macOS Tahoe 26.1", or "macOS 27.0" for a release the table does not
    /// know.
    static func describe(major: Int, minor: Int, patch: Int) -> String {
        let number = version(major: major, minor: minor, patch: patch)
        guard let name = name(major: major) else { return "macOS \(number)" }
        return "macOS \(name) \(number)"
    }
}

enum SerialMask {
    /// All but the last four characters hidden.
    ///
    /// A serial number identifies one machine to Apple's warranty and
    /// support systems, and the Dashboard is a screen people screenshot. Four
    /// characters are enough to tell two of your own Macs apart and not
    /// enough to be anybody else's. A serial of four or fewer is hidden
    /// whole, since "the last four" of it would be all of it.
    static func masked(_ serial: String) -> String {
        let visible = serial.count > 4 ? 4 : 0
        return String(repeating: "•", count: serial.count - visible) + serial.suffix(visible)
    }
}

enum Uptime {
    /// "3d 4h 12m", "4h 12m", "12m". Days and hours are left out while
    /// they are zero, minutes never are.
    static func describe(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if days > 0 || hours > 0 { parts.append("\(hours)h") }
        parts.append("\(minutes)m")
        return parts.joined(separator: " ")
    }
}
