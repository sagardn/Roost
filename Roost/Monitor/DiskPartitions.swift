import Foundation
import DiskArbitration
import IOKit

/// Every partition on each physical drive -- not only the volumes macOS
/// mounts.
///
/// `DiskReadings.volumes` lists what Finder lists, which is right for the
/// figure the menu bar watches and wrong for "what is on this disk": on this
/// Mac the 251 GB SSD also holds a Linux install (two Linux partitions, its
/// EFI partition and a 2.5 GB APFS stub), and none of it appeared anywhere.
///
/// Read through DiskArbitration, which reports every partition's GPT type and
/// exact size without mounting anything, and the IORegistry, which says which
/// partition an APFS container lives on. How full a partition is can only be
/// known where macOS mounts something on it; for the rest -- Linux
/// filesystems macOS has no driver for, an EFI partition nobody mounted --
/// the size is real and the usage is reported as unknown, never estimated.
enum DiskPartitions {

    // MARK: - Model

    enum Kind: String, Equatable {
        case apfs, apfsSystem, apfsRecovery, efi, linux, linuxSwap, linuxLVM, windows, hfs, appleBoot, other

        /// By GPT partition type GUID, the identifier the partition table
        /// itself stores -- not a name, which on a GPT disk is whatever the
        /// installer typed ("Untitled 5" on this Mac).
        init(typeGUID: String) {
            switch typeGUID.uppercased() {
            case "7C3457EF-0000-11AA-AA11-00306543ECAC": self = .apfs
            case "69646961-6700-11AA-AA11-00306543ECAC": self = .apfsSystem
            case "52637672-7900-11AA-AA11-00306543ECAC": self = .apfsRecovery
            case "C12A7328-F81F-11D2-BA4B-00A0C93EC93B": self = .efi
            case "0FC63DAF-8483-4772-8E79-3D69D8477DE4": self = .linux
            case "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F": self = .linuxSwap
            case "E6D6D379-F507-44C2-A23C-238F2A3DF928": self = .linuxLVM
            case "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7": self = .windows
            case "48465300-0000-11AA-AA11-00306543ECAC": self = .hfs
            case "426F6F74-0000-11AA-AA11-00306543ECAC": self = .appleBoot
            default:                                     self = .other
            }
        }

        var title: String {
            switch self {
            case .apfs:         return localized("APFS")
            case .apfsSystem:   return localized("macOS startup system")
            case .apfsRecovery: return localized("macOS Recovery")
            case .efi:          return localized("EFI system")
            case .linux:        return localized("Linux")
            case .linuxSwap:    return localized("Linux swap")
            case .linuxLVM:     return localized("Linux LVM")
            case .windows:      return localized("Windows or FAT")
            case .hfs:          return localized("Mac OS Extended")
            case .appleBoot:    return localized("Apple boot")
            case .other:        return localized("Other")
            }
        }

        /// The parts macOS needs and nobody manages by hand. Drawn quieter,
        /// so the partitions somebody chose to make stand out.
        var isSystem: Bool { [.apfsSystem, .apfsRecovery, .appleBoot].contains(self) }
    }

    struct Partition: Equatable, Identifiable {
        /// "disk0s6".
        let id: String
        let kind: Kind
        let size: UInt64
        /// What to call it: the main volume's name where macOS mounts one,
        /// otherwise the kind.
        let name: String
        /// How much of it is in use and free, where something on it is
        /// mounted. nil means macOS cannot say -- not empty.
        let used: UInt64?
        let free: UInt64?
        /// Whether the Mac is running from it.
        let isStartup: Bool
    }

    struct Drive: Equatable, Identifiable {
        /// "disk0".
        let id: String
        let model: String
        let size: UInt64
        let partitions: [Partition]

        /// Space no partition claims. A GPT disk keeps a few megabytes at
        /// each end for its tables, so anything under a hundred megabytes
        /// is that and not worth a row.
        var unallocated: UInt64 {
            let claimed = partitions.reduce(UInt64(0)) { $0 + $1.size }
            guard size > claimed else { return 0 }
            let gap = size - claimed
            return gap >= 100_000_000 ? gap : 0
        }
    }

    // MARK: - Naming

    /// The name a partition is shown under, from the volumes mounted on it.
    ///
    /// The startup volume's name for the container macOS runs from, the
    /// first ordinary volume's for another -- "lin", not "lin - Data", which
    /// is the data half of the same volume group. A partition with nothing
    /// mounted is named by its kind.
    static func name(kind: Kind, volumeNames: [String], isStartup: Bool, startupName: String?) -> String {
        if isStartup, let startupName { return startupName }
        if kind.isSystem { return kind.title }
        let ordinary = volumeNames.filter { !$0.hasSuffix(" - Data") && !["Preboot", "Recovery", "VM", "Update"].contains($0) }
        return ordinary.first ?? volumeNames.first ?? kind.title
    }

    // MARK: - Reading

    /// Every physical drive and its partitions. Disk images, the APFS
    /// containers macOS synthesises and anything else virtual are left out:
    /// they are not drives, and their space is already a partition's.
    ///
    /// A few dozen DiskArbitration and IORegistry lookups; called off the
    /// main thread, when the Storage panel appears and when a volume mounts
    /// or unmounts.
    static func read() -> [Drive] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let volumes = mountedVolumes(session)
        var drives: [Drive] = []

        // Device numbers are dense but not contiguous -- a disk image
        // unmounted leaves a hole -- so the walk stops after a run of misses
        // rather than at the first, and never probes thousands of names that
        // cannot exist.
        var misses = 0
        for index in 0..<64 {
            let whole = "disk\(index)"
            guard misses < 8 else { break }
            guard let description = describe(whole, session) else { misses += 1; continue }
            misses = 0
            guard
                  description[kDADiskDescriptionMediaWholeKey as String] as? Bool == true,
                  description[kDADiskDescriptionMediaContentKey as String] as? String == "GUID_partition_scheme",
                  description[kDADiskDescriptionDeviceProtocolKey as String] as? String != "Virtual Interface",
                  let size = (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value
            else { continue }

            var partitions: [Partition] = []
            var gaps = 0
            for slice in 1..<129 {
                let bsd = "\(whole)s\(slice)"
                guard gaps < 4 else { break }
                guard let part = describe(bsd, session) else { gaps += 1; continue }
                gaps = 0
                guard let type = part[kDADiskDescriptionMediaContentKey as String] as? String,
                      let bytes = (part[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value
                else { continue }
                let kind = Kind(typeGUID: type)
                let mounted = volumes.filter { $0.partition == bsd }
                let isStartup = mounted.contains { $0.path == "/" }
                // Any one volume of an APFS container reports the container's
                // capacity and free space; a FAT or HFS partition is its one
                // volume.
                let startup = mounted.first { $0.path == "/" }
                let reference = startup ?? mounted.first
                // Important-usage free space on the startup volume, which is
                // what Finder and the Storage card show. Elsewhere plain free
                // space: the small system volumes report zero for important
                // usage, and the 524 MB startup-system partition read as full
                // while `df` showed 504 MB free.
                let free = reference.map { startup != nil ? $0.importantFree : $0.free }
                let used = reference.flatMap { volume in free.map { volume.total > $0 ? volume.total - $0 : 0 } }
                partitions.append(Partition(
                    id: bsd, kind: kind, size: bytes,
                    name: name(kind: kind, volumeNames: mounted.map(\.name), isStartup: isStartup,
                               startupName: mounted.first { $0.path == "/" }?.name),
                    used: used, free: free, isStartup: isStartup))
            }
            guard !partitions.isEmpty else { continue }
            let model = (description[kDADiskDescriptionDeviceModelKey as String] as? String)?
                .trimmingCharacters(in: .whitespaces) ?? whole
            drives.append(Drive(id: whole, model: model, size: size, partitions: partitions))
        }
        return drives
    }

    private static func describe(_ bsd: String, _ session: DASession) -> [String: Any]? {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else { return nil }
        return DADiskCopyDescription(disk) as? [String: Any]
    }

    private struct Mounted {
        let path: String
        let name: String
        /// The partition it lives on: "disk0s2".
        let partition: String
        let total: UInt64
        let free: UInt64
        let importantFree: UInt64
    }

    private static func mountedVolumes(_ session: DASession) -> [Mounted] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        return urls.compactMap { url in
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                  let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }),
                  let partition = partition(holding: bsd, session),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let free = values.volumeAvailableCapacity.map { UInt64(max(0, $0)) } ?? 0
            let important = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? free
            return Mounted(path: url.path, name: values.volumeName ?? url.lastPathComponent,
                           partition: partition, total: UInt64(total),
                           free: min(free, UInt64(total)), importantFree: min(important, UInt64(total)))
        }
    }

    /// The partition a device lives on: itself for "disk0s4", the APFS
    /// container's physical store for "disk4s1".
    ///
    /// Walked up the IORegistry's service plane from the device's media
    /// object to the first ancestor whose BSD name is a partition of a
    /// physical drive -- the link `diskutil list` prints as "Physical Store".
    static func partition(holding bsd: String, _ session: DASession) -> String? {
        if isPartitionName(bsd), !isAPFSDevice(bsd, session) { return bsd }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        guard entry != 0 else { return nil }
        for _ in 0..<32 {
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard status == KERN_SUCCESS else { return nil }
            entry = parent
            if let name = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String, name != bsd, isPartitionName(name), !isAPFSDevice(name, session) {
                IOObjectRelease(entry)
                return name
            }
        }
        IOObjectRelease(entry)
        return nil
    }

    /// "disk0s2", not "disk0" or "disk4s3s1".
    static func isPartitionName(_ bsd: String) -> Bool {
        bsd.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil
    }

    /// Whether a device is a volume inside an APFS container rather than a
    /// partition of a drive: its whole disk is a synthesised container.
    private static func isAPFSDevice(_ bsd: String, _ session: DASession) -> Bool {
        guard let wholeName = bsd.range(of: #"^disk[0-9]+"#, options: .regularExpression).map({ String(bsd[$0]) }),
              let whole = describe(wholeName, session) else { return false }
        return whole[kDADiskDescriptionMediaContentKey as String] as? String == "EF57347C-0000-11AA-AA11-00306543ECAC"
    }
}
