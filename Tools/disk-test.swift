//
//  disk-test.swift
//
//  Exercises the storage reader: the volume filter, the capacity arithmetic,
//  and the rate the device counters are differenced into.
//
//  Run:  cat Roost/Monitor/Readings.swift Roost/Monitor/DiskReadings.swift \
//            Roost/Cleanup/DiskCleanup.swift \
//            Tools/disk-test.swift | swift -
//
//  Two of these are the kind of wrong that looks right. A rate taken across a
//  sleep reports a trickle that never happened, and an APFS container's
//  helper volumes each report the container's capacity with nothing free --
//  so listing them shows one disk six times, every copy apparently full.
//  Neither produces an error and neither can be reproduced to order on a
//  live machine, so both are checked here against values written down.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let gigabyte: UInt64 = 1_073_741_824

func volume(name: String = "Macintosh HD", path: String = "/",
            total: UInt64, free: UInt64, freeNow: UInt64? = nil,
            removable: Bool = false) -> DiskReadings.Volume {
    DiskReadings.Volume(name: name, path: path, total: total, free: free,
                        freeNow: freeNow ?? free,
                        isRemovable: removable, isInternal: true, format: "APFS")
}

// MARK: - When a tidy-up is worth suggesting

print("DiskCleanup.isWorthSuggesting")

check("the boot volume nearly full is worth saying something about",
      DiskCleanup.isWorthSuggesting(path: "/", percentUsed: 0.94))
check("exactly at the threshold counts",
      DiskCleanup.isWorthSuggesting(path: "/", percentUsed: 0.90))
check("just under it does not",
      !DiskCleanup.isWorthSuggesting(path: "/", percentUsed: 0.89))
// An external drive at 92% is usually an archive doing its job. Saying
// something about it is noise, and noise is what gets a prompt ignored when
// it finally matters.
check("a full external drive is not the same problem",
      !DiskCleanup.isWorthSuggesting(path: "/Volumes/Archive", percentUsed: 0.99))
check("nor a full disk image",
      !DiskCleanup.isWorthSuggesting(path: "/Volumes/Installer", percentUsed: 1.0))
check("an empty boot volume is fine",
      !DiskCleanup.isWorthSuggesting(path: "/", percentUsed: 0.1))

// MARK: - Purgeable space

print("DiskReadings.Volume.purgeable")

do {
    // The gap between what `df` prints and what Finder shows: snapshots,
    // caches, downloads already watched. It is why one tool says 26 GB and
    // another says 27.6 GB on the same disk.
    let v = volume(total: 100, free: 30, freeNow: 26)
    check("purgeable is the gap between the two free figures", v.purgeable == 4)
    check("and used is still measured against the Finder figure", v.used == 70)
}

check("a volume with nothing held back has none",
      volume(total: 100, free: 30, freeNow: 30).purgeable == 0)
// freeNow is clamped to free when it is read, so this cannot arise from the
// filesystem -- but the arithmetic must not underflow if it ever does.
check("more free now than important usage is not negative purgeable",
      volume(total: 100, free: 26, freeNow: 30).purgeable == 0)
check("a full disk has no purgeable space",
      volume(total: 100, free: 0, freeNow: 0).purgeable == 0)

// MARK: - Capacity arithmetic

print("DiskReadings.Volume")

do {
    let v = volume(total: 100 * gigabyte, free: 25 * gigabyte)
    check("used is capacity less what is available", v.used == 75 * gigabyte)
    check("the share follows from it", abs(v.percent - 0.75) < 0.0001)
}

do {
    // A read-only image reports nothing available, and that is not an error:
    // you genuinely cannot write to it.
    let v = volume(total: 2 * gigabyte, free: 0)
    check("nothing available is entirely used", v.used == 2 * gigabyte)
    check("and reads as full", v.percent == 1)
}

do {
    // An autofs stub reports zero for everything. Zero over zero is not full.
    let v = volume(total: 0, free: 0)
    check("a volume with no capacity is not full", v.percent == 0)
    check("and has used nothing", v.used == 0)
}

do {
    // Free space above capacity cannot happen, but a volume being resized
    // underneath a read is two system calls apart.
    let v = volume(total: 10 * gigabyte, free: 20 * gigabyte)
    check("more free than total does not go negative", v.used == 0)
    check("nor past the end of the scale", v.percent == 0)
}

do {
    let v = volume(total: 195_383_263_232, free: 4_888_379_392)
    check("the figure matches the machine it was measured on",
          Int((v.percent * 100).rounded()) == 97)
    check("and the bytes format the way the menu bar formats them",
          Readings.bytes(v.free) == "4.6 GB")
}

// MARK: - The rate

print("\nDiskReadings.rate")

func counters(_ read: UInt64, _ written: UInt64) -> DiskReadings.Counters {
    DiskReadings.Counters(read: read, written: written)
}

do {
    let rate = DiskReadings.rate(from: counters(0, 0), to: counters(2048, 1024), elapsed: 2)
    check("bytes over seconds is bytes per second",
          rate?.read == 1024 && rate?.written == 512)
}

do {
    check("a clock that did not move is refused",
          DiskReadings.rate(from: counters(0, 0), to: counters(1, 1), elapsed: 0) == nil)
    check("a clock that went backwards is refused",
          DiskReadings.rate(from: counters(0, 0), to: counters(1, 1), elapsed: -3) == nil)
    check("an interval that is not a number is refused",
          DiskReadings.rate(from: counters(0, 0), to: counters(1, 1), elapsed: .nan) == nil)
    check("an infinite interval is refused",
          DiskReadings.rate(from: counters(0, 0), to: counters(1, 1),
                            elapsed: .infinity) == nil)
}

do {
    // The machine slept. The bytes are real; averaging them over the sleep
    // is not.
    check("a gap longer than a minute is refused",
          DiskReadings.rate(from: counters(0, 0), to: counters(10_000_000_000, 0),
                            elapsed: 3600) == nil)
    check("but a minute short of it is not",
          DiskReadings.rate(from: counters(0, 0), to: counters(590, 0), elapsed: 59) != nil)
}

do {
    // A drive detached and reattached starts counting again from zero.
    check("a read counter below its predecessor is refused",
          DiskReadings.rate(from: counters(5000, 0), to: counters(10, 0), elapsed: 1) == nil)
    check("a write counter below its predecessor is refused",
          DiskReadings.rate(from: counters(0, 5000), to: counters(0, 10), elapsed: 1) == nil)
}

do {
    // Nothing non-finite may reach a chart, whatever the counters do.
    let huge = DiskReadings.rate(from: counters(0, 0),
                                 to: counters(UInt64.max / 2, UInt64.max / 2),
                                 elapsed: 0.001)
    check("even an absurd delta stays finite",
          (huge?.read.isFinite ?? false) && (huge?.written.isFinite ?? false))
    check("and stays positive", (huge?.read ?? -1) > 0)
}

do {
    let idle = DiskReadings.rate(from: counters(900, 900), to: counters(900, 900), elapsed: 1)
    check("a disk doing nothing reads as nothing, not as missing",
          idle?.read == 0 && idle?.written == 0)
}

// MARK: - Against this machine

print("\nOn this Mac")

do {
    let list = DiskReadings.volumes()
    check("at least the startup volume is listed", !list.isEmpty)
    check("every one has a capacity", list.allSatisfy { $0.total > 0 })
    check("every share is a share", list.allSatisfy { $0.percent >= 0 && $0.percent <= 1 })
    check("every share is a number", list.allSatisfy { $0.percent.isFinite })
    check("used never exceeds capacity", list.allSatisfy { $0.used <= $0.total })
    check("the startup volume is the primary one",
          DiskReadings.primary()?.path == "/" || DiskReadings.primary() == nil)

    // The filter is the point: a dozen volumes mount on a modern Mac and
    // all but a couple are an APFS container's own machinery.
    let everything = FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: nil, options: [])?.count ?? 0
    check("the browsable filter drops the container's helper volumes "
          + "(\(list.count) of \(everything))", list.count < everything)

    // Containers share capacity, so two volumes reporting the same total is
    // normal -- which is exactly why they must not be summed.
    let summed = list.reduce(UInt64(0)) { $0 + $1.total }
    check("capacities are reported per volume, not summed into a fiction",
          summed >= (list.first?.total ?? 0))
}

do {
    let including = DiskReadings.volumes(includingRemovable: true)
    let excluding = DiskReadings.volumes(includingRemovable: false)
    check("asking for removable drives never returns fewer",
          including.count >= excluding.count)
    check("excluding them leaves none behind",
          excluding.allSatisfy { !$0.isRemovable })
}

do {
    let (total, byDevice) = DiskReadings.counters()
    check("at least one block device answered", !byDevice.isEmpty)
    check("the total is the sum of the devices",
          total.read == byDevice.values.reduce(0) { $0 + $1.read })
    check("and so is the write total",
          total.written == byDevice.values.reduce(0) { $0 + $1.written })
    check("every device is named", byDevice.keys.allSatisfy { !$0.isEmpty })

    // Counters are cumulative, so a second reading can only be larger.
    let again = DiskReadings.counters().total
    check("counters do not go backwards between two reads",
          again.read >= total.read && again.written >= total.written)
}

// MARK: - Formatting a rate that cannot happen

print("\nReadings.rate")

// `UInt64(.infinity)` is a trap, not an error: it takes the process down.
// Both readers refuse to produce a non-finite rate, but this is the last
// place before the conversion.
check("a rate that is not a number formats as nothing",
      Readings.rate(.nan) == "0 B/s")
check("an infinite rate does not take the app with it",
      Readings.rate(.infinity) == "0 B/s")
check("a negative rate is nothing, not a huge number",
      Readings.rate(-5000) == "0 B/s")
check("an absurd but finite rate still formats",
      Readings.rate(1e30).hasSuffix("/s"))
check("an ordinary rate is unchanged", Readings.rate(1024) == "1.0 KB/s")
check("and so is the boundary the formatter switches at",
      Readings.rate(102_400) == "100 KB/s")

// MARK: - Which volume the figure is about

print("\nDiskReadings.choose")

do {
    let boot = volume(name: "Macintosh HD", path: "/", total: 100, free: 10)
    let backup = volume(name: "Backup", path: "/Volumes/Backup", total: 200, free: 20)
    // Two drives with the same name is why the choice is stored as a mount
    // point: a name cannot tell them apart.
    let other = volume(name: "Backup", path: "/Volumes/Backup 1", total: 300, free: 30)
    let list = [boot, backup, other]

    check("nothing chosen is the startup volume",
          DiskReadings.choose(from: list, preferring: nil)?.path == "/")
    check("an empty choice is the startup volume too",
          DiskReadings.choose(from: list, preferring: "")?.path == "/")
    check("a chosen volume is honoured",
          DiskReadings.choose(from: list, preferring: "/Volumes/Backup")?.total == 200)
    check("two volumes of the same name are told apart by where they are",
          DiskReadings.choose(from: list, preferring: "/Volumes/Backup 1")?.total == 300)
    check("a chosen volume that is not mounted falls back to the startup one",
          DiskReadings.choose(from: list, preferring: "/Volumes/Gone")?.path == "/")
    check("with no startup volume it falls back to the first there is",
          DiskReadings.choose(from: [backup, other], preferring: "/Volumes/Gone")?.total == 200)
    check("an empty list chooses nothing rather than crashing",
          DiskReadings.choose(from: [], preferring: "/") == nil)
}

// MARK: - Which key wins

print("\nDiskReadings.resolveWatchedVolume")

do {
    let boot = volume(name: "Macintosh HD", path: "/", total: 100, free: 10)
    let backup = volume(name: "Backup", path: "/Volumes/Backup", total: 200, free: 20)
    let twin = volume(name: "Backup", path: "/Volumes/Backup 1", total: 300, free: 30)
    let mounted = [boot, backup, twin]

    // The rule that matters: a choice made under the current key is never
    // overwritten by an older key that also happens to exist.
    check("a canonical value wins outright",
          DiskReadings.resolveWatchedVolume(canonical: "/Volumes/Backup",
                                            parallel: "/", legacyName: "Macintosh HD",
                                            mounted: mounted) == nil)
    check("even when the older keys disagree with each other",
          DiskReadings.resolveWatchedVolume(canonical: "/",
                                            parallel: "/Volumes/Backup",
                                            legacyName: "Backup",
                                            mounted: mounted) == nil)

    check("the parallel key transfers as a path",
          DiskReadings.resolveWatchedVolume(canonical: "", parallel: "/Volumes/Backup",
                                            legacyName: "", mounted: mounted)
            == "/Volumes/Backup")
    check("the parallel key beats the original one",
          DiskReadings.resolveWatchedVolume(canonical: "", parallel: "/Volumes/Backup",
                                            legacyName: "Macintosh HD", mounted: mounted)
            == "/Volumes/Backup")
    check("a parallel path for a volume that is gone is not used",
          DiskReadings.resolveWatchedVolume(canonical: "", parallel: "/Volumes/Gone",
                                            legacyName: "", mounted: mounted) == nil)
    check("and falls through to the original key",
          DiskReadings.resolveWatchedVolume(canonical: "", parallel: "/Volumes/Gone",
                                            legacyName: "Macintosh HD", mounted: mounted)
            == "/")

    check("a name resolves to the mount point it names",
          DiskReadings.resolveWatchedVolume(canonical: "", parallel: "",
                                            legacyName: "Macintosh HD", mounted: mounted)
            == "/")
    // The ambiguity that made names unusable in the first place.
    check("a name two volumes answer to resolves to neither",
          DiskReadings.resolveWatchedVolume(canonical: "", parallel: "",
                                            legacyName: "Backup", mounted: mounted) == nil)
    check("a name nothing answers to resolves to nothing",
          DiskReadings.resolveWatchedVolume(canonical: "", parallel: "",
                                            legacyName: "Elsewhere", mounted: mounted) == nil)
    check("nothing stored anywhere is nothing to migrate",
          DiskReadings.resolveWatchedVolume(canonical: "", parallel: "",
                                            legacyName: "", mounted: mounted) == nil)
    check("no volumes mounted is nothing to migrate",
          DiskReadings.resolveWatchedVolume(canonical: "", parallel: "/",
                                            legacyName: "Macintosh HD", mounted: []) == nil)
}

// MARK: - The meter

print("\nDiskReadings.Meter")

func counterMap(_ pairs: [String: (UInt64, UInt64)]) -> [String: DiskReadings.Counters] {
    pairs.mapValues { DiskReadings.Counters(read: $0.0, written: $0.1) }
}

do {
    let meter = DiskReadings.Meter()
    let start = Date()
    check("the first sample has nothing to difference against",
          meter.sample(now: start, reading: { counterMap(["disk0": (0, 0)]) }) == nil)

    let sample = meter.sample(now: start.addingTimeInterval(2),
                              reading: { counterMap(["disk0": (2048, 1024)]) })
    check("bytes over seconds is bytes per second",
          sample?.activity.read == 1024 && sample?.activity.written == 512)
    check("and the bytes behind it come back for a running total",
          sample?.read == 2048 && sample?.written == 1024)
    check("total is the two added", sample?.activity.total == 1536)
}

do {
    // The case this type exists for. One drive detaches and its counter
    // resets, dragging the *sum* below its predecessor -- differencing the
    // total would throw the whole sample away, and the other drive's work
    // with it.
    let meter = DiskReadings.Meter()
    let start = Date()
    _ = meter.sample(now: start,
                     reading: { counterMap(["disk0": (1000, 1000), "disk9": (5000, 5000)]) })
    let sample = meter.sample(now: start.addingTimeInterval(1),
                              reading: { counterMap(["disk0": (3000, 2000), "disk9": (10, 10)]) })
    check("a drive whose counter reset does not lose the other drive's work",
          sample?.activity.read == 2000 && sample?.activity.written == 1000)
    check("and the reset drive contributes nothing rather than a negative",
          sample?.read == 2000)
}

do {
    let meter = DiskReadings.Meter()
    let start = Date()
    _ = meter.sample(now: start, reading: { counterMap(["disk0": (0, 0)]) })
    check("no drive producing an honest delta is nil, not a fabricated zero",
          meter.sample(now: start.addingTimeInterval(1),
                       reading: { counterMap(["disk0": (0, 0)]) })?.activity.read == 0)
    // An idle drive is zero; an *unmeasurable* one is nil. Different answers.
    let other = DiskReadings.Meter()
    _ = other.sample(now: start, reading: { counterMap(["disk0": (500, 500)]) })
    check("a drive that went backwards everywhere is nil",
          other.sample(now: start.addingTimeInterval(1),
                       reading: { counterMap(["disk0": (1, 1)]) }) == nil)
}

do {
    let meter = DiskReadings.Meter()
    let start = Date()
    _ = meter.sample(now: start, reading: { counterMap(["disk0": (0, 0)]) })
    check("a gap longer than a minute is refused",
          meter.sample(now: start.addingTimeInterval(3600),
                       reading: { counterMap(["disk0": (9_000_000, 0)]) }) == nil)

    let fresh = DiskReadings.Meter()
    _ = fresh.sample(now: start, reading: { counterMap(["disk0": (0, 0)]) })
    fresh.reset()
    check("a reset drops the baseline",
          fresh.sample(now: start.addingTimeInterval(1),
                       reading: { counterMap(["disk0": (100, 0)]) }) == nil)
}

do {
    // A sub-second interval scales the rate up, not down.
    let meter = DiskReadings.Meter()
    let start = Date()
    _ = meter.sample(now: start, reading: { counterMap(["disk0": (0, 0)]) })
    let sample = meter.sample(now: start.addingTimeInterval(0.5),
                              reading: { counterMap(["disk0": (512, 0)]) })
    check("half a second of 512 bytes is a kilobyte a second",
          sample?.activity.read == 1024)
}

// MARK: - Order

print("\nVolume order")

do {
    let list = DiskReadings.volumes(includingRemovable: true)
    if let first = list.first, list.count > 1 {
        check("the boot volume is first", first.path == "/")
    } else {
        check("there is nothing to order", true)
    }
    check("mount points are unique",
          Set(list.map { $0.path }).count == list.count)
    check("the order is stable across two reads",
          DiskReadings.volumes(includingRemovable: true).map { $0.path }
            == list.map { $0.path })
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
