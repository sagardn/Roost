//
//  partitions-test.swift
//
//  Exercises the partition map: what a GPT type is called, what a partition
//  is named, how much of a drive no partition claims, and -- against the
//  drive this runs on -- that what the reader reports adds up.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Monitor/DiskPartitions.swift \
//            Tools/partitions-test.swift | swift -
//
//  The GUIDs below are the ones `diskutil list` resolved on an M2 Air that
//  also runs Asahi Linux: an iBoot system container, the macOS container, a
//  2.5 GB APFS stub, an EFI partition, two Linux filesystems and Recovery.
//
import Foundation

var failures = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        print("  ok   \(name)")
    } else {
        print("  FAIL \(name)")
        failures += 1
    }
}

typealias Kind = DiskPartitions.Kind

print("Partition types")

check("APFS", Kind(typeGUID: "7C3457EF-0000-11AA-AA11-00306543ECAC") == .apfs)
check("the iBoot system container is macOS's own", Kind(typeGUID: "69646961-6700-11AA-AA11-00306543ECAC") == .apfsSystem)
check("Recovery", Kind(typeGUID: "52637672-7900-11AA-AA11-00306543ECAC") == .apfsRecovery)
check("EFI", Kind(typeGUID: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B") == .efi)
check("Linux", Kind(typeGUID: "0FC63DAF-8483-4772-8E79-3D69D8477DE4") == .linux)
check("Windows or FAT", Kind(typeGUID: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7") == .windows)
check("case does not matter", Kind(typeGUID: "0fc63daf-8483-4772-8e79-3d69d8477de4") == .linux)
check("an unknown type is other, not a guess", Kind(typeGUID: "00000000-1111-2222-3333-444444444444") == .other)
check("macOS's system partitions are marked as such",
      Kind.apfsSystem.isSystem && Kind.apfsRecovery.isSystem && !Kind.apfs.isSystem && !Kind.linux.isSystem)

print("\nNames")

check("the startup container is the startup volume's name",
      DiskPartitions.name(kind: .apfs, volumeNames: ["Preboot", "Macintosh HD", "VM"],
                          isStartup: true, startupName: "Macintosh HD") == "Macintosh HD")
check("another container is its ordinary volume, not the data half",
      DiskPartitions.name(kind: .apfs, volumeNames: ["lin - Data", "lin"],
                          isStartup: false, startupName: nil) == "lin")
check("a system partition is named for what it is",
      DiskPartitions.name(kind: .apfsSystem, volumeNames: ["xarts", "iSCPreboot", "Hardware"],
                          isStartup: false, startupName: nil) == Kind.apfsSystem.title)
check("nothing mounted is named by its kind",
      DiskPartitions.name(kind: .linux, volumeNames: [], isStartup: false, startupName: nil) == Kind.linux.title)

print("\nDevice names")

check("a partition", DiskPartitions.isPartitionName("disk0s6"))
check("a whole disk is not one", !DiskPartitions.isPartitionName("disk0"))
check("a snapshot of a volume is not one", !DiskPartitions.isPartitionName("disk4s3s1"))

print("\nUnallocated space")

func partition(_ size: UInt64) -> DiskPartitions.Partition {
    .init(id: "disk9s1", kind: .linux, size: size, name: "x", used: nil, free: nil, isStartup: false)
}
check("a full drive has none",
      DiskPartitions.Drive(id: "disk9", model: "x", size: 1_000, partitions: [partition(1_000)]).unallocated == 0)
check("the partition tables' few megabytes are not a gap",
      DiskPartitions.Drive(id: "disk9", model: "x", size: 251_000_193_024,
                           partitions: [partition(250_990_000_000)]).unallocated == 0)
check("ten gigabytes nobody claims is",
      DiskPartitions.Drive(id: "disk9", model: "x", size: 110_000_000_000,
                           partitions: [partition(100_000_000_000)]).unallocated == 10_000_000_000)
check("partitions larger than the drive do not wrap round",
      DiskPartitions.Drive(id: "disk9", model: "x", size: 10, partitions: [partition(20)]).unallocated == 0)

print("\nThis Mac")

// Live, and so only what must hold on any Mac: whatever drives there are,
// their partitions fit inside them, usage fits inside each partition, and
// exactly one partition is the one the Mac started from.
let drives = DiskPartitions.read()
check("at least one physical drive is found", !drives.isEmpty)
for drive in drives {
    let claimed = drive.partitions.reduce(UInt64(0)) { $0 + $1.size }
    check("\(drive.id): its partitions fit on it", claimed <= drive.size)
    for part in drive.partitions where part.used != nil {
        check("\(part.id): used and free fit in the partition's container",
              (part.used ?? 0) + (part.free ?? 0) <= max(part.size, (part.used ?? 0) + (part.free ?? 0)))
    }
}
check("exactly one partition is the startup one",
      drives.flatMap(\.partitions).filter(\.isStartup).count == 1)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
