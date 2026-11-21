//
//  eject-test.swift
//
//  Which disks "Eject All Disks" takes, and what it says afterwards.
//
//  Run:  cat Roost/UI/Localized.swift Roost/UI/Log.swift \
//            Roost/Launcher/Notify.swift Roost/Launcher/DiskEject.swift \
//            Tools/eject-test.swift | swift -
//
//  The choice is the part that can hurt: ejecting the startup disk is
//  refused by macOS, but a second internal volume -- a Linux partition, a
//  Boot Camp disk, the "lin" APFS volume on the Mac this was written on --
//  would go. Written-down volumes, so nothing here ejects anything.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

typealias V = DiskEject.Volume
func volume(_ path: String, ejectable: Bool = false, removable: Bool = false,
            builtIn: Bool = true, local: Bool = true, root: Bool = false) -> V {
    V(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent,
      isEjectable: ejectable, isRemovable: removable, isInternal: builtIn,
      isLocal: local, isRoot: root)
}

print("Which disks")
let startup = volume("/", root: true)
let data = volume("/System/Volumes/Data")
let linux = volume("/Volumes/lin")
let usb = volume("/Volumes/Backup", ejectable: true, removable: true, builtIn: false)
let image = volume("/Volumes/Installer", ejectable: true)
let share = volume("/Volumes/Team", local: false)
let enclosure = volume("/Volumes/Archive", builtIn: false)
let chosen: [V] = DiskEject.ejectable([startup, data, linux, usb, image, share, enclosure])
let names: [String] = chosen.map(\.name)
check("never the startup disk", !names.contains("/"))
check("never the system's own data volume", !names.contains("Data"))
check("never another internal volume", !names.contains("lin"))
check("a USB drive goes", names.contains("Backup"))
check("a mounted disk image goes", names.contains("Installer"))
check("a network share goes, as in Finder", names.contains("Team"))
check("an external drive that reports neither flag still goes", names.contains("Archive"))
check("nothing else", chosen.count == 4)
let simulator = volume("/private/var/run/com.apple.security.cryptexd/mnt/Runtime", ejectable: true, builtIn: false)
check("never a disk image mounted outside /Volumes, like a simulator runtime",
      DiskEject.ejectable([simulator]).isEmpty)

print("\nWhat it says")
check("nothing mounted", DiskEject.message(ejected: [], refused: []) == "No disks to eject")
check("one disk is named", DiskEject.message(ejected: ["Backup"], refused: []) == "Ejected Backup")
check("several are counted", DiskEject.message(ejected: ["A", "B"], refused: []) == "Ejected 2 disks")
check("a refusal names the disk in use",
      DiskEject.message(ejected: ["A"], refused: ["Backup"]).hasPrefix("Could not eject Backup"))

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
