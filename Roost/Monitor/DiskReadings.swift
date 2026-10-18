import Foundation
import IOKit

/// Storage: what the volumes hold, and what the devices are doing.
///
/// Two unrelated readings that the one module shows together. Capacity comes
/// from the volume URLs' own resource values; activity comes from the
/// `Statistics` dictionary every `IOBlockStorageDriver` publishes in the
/// IORegistry. Both are public, and neither needs an entitlement or a helper.
enum DiskReadings {

    // MARK: - Capacity

    struct Volume: Equatable {
        /// What Finder calls it.
        let name: String
        /// Where it is mounted.
        let path: String
        /// The capacity the system reports for this volume.
        ///
        /// On APFS this is the **container's** size, which every volume in
        /// the container reports identically -- see `visible`.
        let total: UInt64
        /// Space available for important usage: what Finder shows as free,
        /// after purgeable space is accounted for.
        let free: UInt64
        /// What is free this instant, before anything is reclaimed -- the
        /// number `df` prints.
        let freeNow: UInt64
        let isRemovable: Bool
        let isInternal: Bool
        /// "APFS", "exFAT", and so on. nil where the system does not say.
        let format: String?

        var used: UInt64 { total > free ? total - free : 0 }

        /// Space macOS is holding but will give back when something needs it:
        /// local Time Machine snapshots, caches, already-watched downloads.
        ///
        /// This is the difference between the two numbers above, and it is
        /// the reason a disk reads 26 GB free in `df` and 27.6 GB in Finder.
        /// Worth showing because the gap is otherwise unexplainable from
        /// inside the app, and because it is the honest answer to "where did
        /// my space go" -- it has not gone anywhere, and nothing needs
        /// cleaning.
        var purgeable: UInt64 { free > freeNow ? free - freeNow : 0 }

        /// 0...1, and nothing on a volume reporting no capacity at all --
        /// an autofs stub reports zero, and zero over zero is not full.
        var percent: Double { total == 0 ? 0 : Double(used) / Double(total) }
    }

    /// The volumes worth showing somebody.
    ///
    /// Filtered to the browsable ones, which is what Finder lists, and that
    /// filter is doing real work rather than tidying: an APFS container's
    /// helper volumes -- VM, Preboot, Update, Recovery, xART -- each report
    /// the **container's** total capacity and nothing available, so listing
    /// them shows the same disk five or six times over, each one apparently
    /// completely full. Measured on this Mac: thirteen volumes mount, two are
    /// browsable, and the other eleven are that.
    ///
    /// A volume with no capacity is dropped for the same reason: an autofs
    /// stub reports zero for everything, and a row of dashes is not a disk.
    static func volumes(includingRemovable removable: Bool = false) -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsBrowsableKey,
            .volumeLocalizedFormatDescriptionKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) else { return [] }

        let found = urls.compactMap { url -> Volume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true,
                  let total = values.volumeTotalCapacity, total > 0
            else { return nil }

            let isRemovable = values.volumeIsRemovable ?? false
            guard removable || !isRemovable else { return nil }

            let available = values.volumeAvailableCapacityForImportantUsage ?? 0
            // Falls back to the important-usage figure rather than zero: a
            // volume that reports one and not the other has no purgeable
            // space to show, which is better than claiming all of it is.
            let now = values.volumeAvailableCapacity.map { Int64($0) } ?? available
            return Volume(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: UInt64(total),
                free: UInt64(max(0, available)),
                freeNow: UInt64(max(0, min(now, available))),
                isRemovable: isRemovable,
                isInternal: values.volumeIsInternal ?? !isRemovable,
                format: values.volumeLocalizedFormatDescription)
        }

        // Boot volume first, then the internal ones, then the rest by name:
        // the order somebody would look for them in, and a stable one. Mount
        // order is neither -- it changes when a drive is replugged, which
        // would silently move the row a settings list calls "the first".
        return found.sorted { lhs, rhs in
            if (lhs.path == "/") != (rhs.path == "/") { return lhs.path == "/" }
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// The volume a single figure in the menu bar should be about.
    ///
    /// The one the user picked if it is mounted, the startup volume
    /// otherwise. A drive that has been unplugged falls back rather than
    /// leaving the menu bar blank, and it falls back without forgetting the
    /// choice, so plugging it in again restores it.
    static func primary(includingRemovable removable: Bool = false,
                        preferring mountPoint: String? = nil) -> Volume? {
        choose(from: volumes(includingRemovable: removable), preferring: mountPoint)
    }

    /// Which stored value should become the canonical volume choice.
    ///
    /// Three keys have held this setting, because the module was built twice
    /// -- see `DiskSettings.migrateChosenVolume`. The precedence is strict:
    ///
    /// 1. A canonical value already present wins outright. It is a choice
    ///    made under the current key and is never overwritten by an older
    ///    key that also happens to exist.
    /// 2. Otherwise a mount point from the parallel implementation, if that
    ///    volume is actually mounted.
    /// 3. Otherwise a *name* from the original module, if exactly one
    ///    mounted volume answers to it. Two drives of the same name is the
    ///    ambiguity that made names unusable, and guessing between them
    ///    would be worse than falling back to the startup volume.
    ///
    /// nil means "nothing to migrate"; the caller keeps whatever it had.
    /// Pure, so the precedence can be checked against values written down
    /// rather than whatever is plugged into this machine.
    static func resolveWatchedVolume(canonical: String, parallel: String,
                                     legacyName: String,
                                     mounted: [Volume]) -> String? {
        guard canonical.isEmpty else { return nil }

        if !parallel.isEmpty, mounted.contains(where: { $0.path == parallel }) {
            return parallel
        }

        guard !legacyName.isEmpty else { return nil }
        let matches = mounted.filter { $0.name == legacyName }
        return matches.count == 1 ? matches[0].path : nil
    }

    /// Split out from `primary` so the fallback order can be checked against
    /// a list written down rather than whatever happens to be mounted.
    static func choose(from list: [Volume], preferring mountPoint: String?) -> Volume? {
        if let mountPoint, !mountPoint.isEmpty,
           let chosen = list.first(where: { $0.path == mountPoint }) {
            return chosen
        }
        return list.first { $0.path == "/" } ?? list.first
    }

    // MARK: - Activity

    /// Bytes a device has read and written since it was attached.
    ///
    /// Cumulative and monotonic while the device stays attached, which is
    /// what makes a difference between two of them a rate.
    struct Counters: Equatable {
        var read: UInt64 = 0
        var written: UInt64 = 0
    }

    struct Activity: Equatable {
        /// Bytes per second.
        var read: Double = 0
        var written: Double = 0

        /// What the device is moving in total, either direction.
        var total: Double { read + written }
    }

    /// Every block device's counters, by BSD name, plus their sum.
    ///
    /// Summed as well as listed because the menu bar wants one number and the
    /// popup wants the breakdown, and walking the registry twice to get both
    /// would be walking it twice.
    static func counters() -> (total: Counters, byDevice: [String: Counters]) {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS
        else { return (Counters(), [:]) }
        defer { IOObjectRelease(iterator) }

        var total = Counters()
        var byDevice: [String: Counters] = [:]

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged,
                                                    kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                  let statistics = properties["Statistics"] as? [String: Any]
            else { continue }

            let read = nonNegative(statistics["Bytes (Read)"])
            let written = nonNegative(statistics["Bytes (Write)"])

            // The driver itself is unnamed; the BSD name is on the media
            // below it.
            let name = (IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, "BSD Name" as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively)) as? String) ?? "disk"

            byDevice[name] = Counters(read: read, written: written)
            total.read += read
            total.written += written
        }
        return (total, byDevice)
    }

    /// Bytes per second between two readings of the counters.
    ///
    /// Pure, and separated from the sampling for the same reason the network
    /// module's is: none of the four refusals below produce an error, they
    /// produce a plausible wrong number, and a real disk will not reproduce
    /// any of them to order.
    static func rate(from previous: Counters, to current: Counters,
                     elapsed: TimeInterval) -> Activity? {
        // A clock that did not move, or moved backwards, divides by nothing.
        guard elapsed > 0, elapsed.isFinite else { return nil }
        // A gap this long means the machine slept. The bytes are real but
        // averaging them over the sleep reports a trickle that never
        // happened.
        guard elapsed < 60 else { return nil }
        // Counters below their predecessor mean the device was detached and
        // reattached, or swapped underneath us, so there is nothing to
        // subtract from.
        guard current.read >= previous.read,
              current.written >= previous.written else { return nil }

        return Activity(read: Double(current.read - previous.read) / elapsed,
                        written: Double(current.written - previous.written) / elapsed)
    }

    /// Statistics come back as `NSNumber`, and a negative one means the
    /// driver is reporting something this is not.
    private static func nonNegative(_ value: Any?) -> UInt64 {
        guard let number = value as? NSNumber else { return 0 }
        let raw = number.int64Value
        return raw > 0 ? UInt64(raw) : 0
    }

    // MARK: - Live activity

    /// Differences the counters into a rate, one device at a time.
    ///
    /// Per device, not on the summed total, and that is the whole reason this
    /// is a type rather than two lines in the popup. Counters reset when a
    /// drive is detached and reattached, and a reset drags the *sum* below
    /// its predecessor -- so differencing the total throws away the sample
    /// entirely, and every other drive's work with it. Differencing each
    /// device and adding what survives keeps the drives that did report
    /// honestly.
    ///
    /// Taken from a second Disk implementation written in parallel, which got
    /// this right where the first version of this file did not.
    final class Meter {

        /// What one pair of samples measured.
        struct Sample: Equatable {
            let activity: Activity
            /// The bytes behind the rate, for a running total. Only from the
            /// devices that produced an honest delta.
            let read: UInt64
            let written: UInt64
        }

        private var previous: [String: Counters] = [:]
        private var sampledAt = Date.distantPast

        /// nil on the first call, and whenever no device produced an honest
        /// delta. Never a fabricated zero: a disk that could not be measured
        /// and a disk doing nothing are different answers.
        func sample(now: Date = Date(),
                    reading: () -> [String: Counters] = { counters().byDevice }) -> Sample? {
            let current = reading()
            defer {
                previous = current
                sampledAt = now
            }

            guard !previous.isEmpty else { return nil }
            let elapsed = now.timeIntervalSince(sampledAt)

            var activity = Activity()
            var read: UInt64 = 0
            var written: UInt64 = 0
            var measured = false

            for (name, counters) in current {
                guard let before = previous[name],
                      let rate = DiskReadings.rate(from: before, to: counters,
                                                   elapsed: elapsed) else { continue }
                activity.read += rate.read
                activity.written += rate.written
                read += counters.read - before.read
                written += counters.written - before.written
                measured = true
            }
            return measured ? Sample(activity: activity, read: read, written: written) : nil
        }

        /// Forget the baseline, so the next pair of samples starts clean.
        func reset() {
            previous = [:]
            sampledAt = .distantPast
        }
    }
}
