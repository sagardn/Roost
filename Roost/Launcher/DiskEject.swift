import AppKit

/// Ejects every disk somebody would unplug: external drives, card readers,
/// mounted disk images and network shares. Never the startup disk, and never
/// another internal volume -- a second APFS volume on the built-in SSD is
/// not something anyone means by "eject".
enum DiskEject {

    struct Volume: Equatable {
        let url: URL
        let name: String
        let isEjectable: Bool
        let isRemovable: Bool
        let isInternal: Bool
        let isLocal: Bool
        let isRoot: Bool
    }

    /// Which of `volumes` to eject. Pure, so the choice can be checked
    /// against volumes written down rather than whatever is plugged in.
    ///
    /// Ejectable or removable is Finder's own test for the eject button. A
    /// network share is neither, and is ejected too, as Finder does. An
    /// external drive that reports neither -- some USB enclosures do -- is
    /// still not internal, which is the test that catches it.
    ///
    /// And only under /Volumes, where Finder mounts everything a person
    /// plugs in, opens or connects to. Other mounts are the system's: on the
    /// Mac this was written on, `df` lists an Xcode simulator runtime disk
    /// image under /private/var/run and a device file system in ~/Library.
    /// They are hidden today, so the mounted list skips them, but that is
    /// one flag between them and an eject.
    static func ejectable(_ volumes: [Volume]) -> [Volume] {
        volumes.filter { volume in
            guard !volume.isRoot, volume.url.standardizedFileURL.path.hasPrefix("/Volumes/") else {
                return false
            }
            return volume.isEjectable || volume.isRemovable || !volume.isLocal || !volume.isInternal
        }
    }

    /// The volumes mounted now.
    static func mounted() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey,
                                      .volumeIsRemovableKey, .volumeIsInternalKey,
                                      .volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Volume(url: url,
                          name: values.volumeLocalizedName ?? url.lastPathComponent,
                          isEjectable: values.volumeIsEjectable ?? false,
                          isRemovable: values.volumeIsRemovable ?? false,
                          // Unknown counts as internal: when macOS will not
                          // say, leaving a volume mounted is the safe answer.
                          isInternal: values.volumeIsInternal ?? true,
                          isLocal: values.volumeIsLocal ?? true,
                          isRoot: values.volumeIsRootFileSystem ?? false)
        }
    }

    /// Ejects them all, off the main thread -- an unmount waits for every
    /// open file on the disk to close, and a busy one can take seconds --
    /// and says what happened.
    static func ejectAll() {
        DispatchQueue.global(qos: .userInitiated).async {
            let targets = ejectable(mounted())
            var ejected: [String] = []
            var refused: [String] = []
            // Ejecting one partition of a drive ejects the drive, and with it
            // the drive's other volumes still on this list -- which then
            // failed, and were reported as in use. A volume that is no longer
            // mounted went with its sibling, and counts as ejected.
            let stillMounted = { (volume: Volume) in
                (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
                    .contains { $0.standardizedFileURL == volume.url.standardizedFileURL }
            }
            for volume in targets {
                guard stillMounted(volume) else { ejected.append(volume.name); continue }
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
                    ejected.append(volume.name)
                } catch where !stillMounted(volume) {
                    ejected.append(volume.name)
                } catch {
                    Log.error("eject \(volume.name): \(error.localizedDescription)")
                    refused.append(volume.name)
                }
            }
            DispatchQueue.main.async {
                Notify.show(message(ejected: ejected, refused: refused), symbol: "eject.fill")
            }
        }
    }

    /// One line for the toast. The first refusal is named, because "could
    /// not eject" without a name sends somebody looking through every disk
    /// to find the one that is in use.
    static func message(ejected: [String], refused: [String]) -> String {
        if let first = refused.first {
            return localized("Could not eject %0 — something is using it", first)
        }
        switch ejected.count {
        case 0:  return localized("No disks to eject")
        case 1:  return localized("Ejected %0", ejected[0])
        default: return localized("Ejected %0 disks", String(ejected.count))
        }
    }
}
