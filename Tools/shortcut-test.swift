//
//  shortcut-test.swift
//
//  Exercises the module popup shortcuts: what may be recorded, how it is
//  stored, and how it reads back.
//
//  Run:  cat Roost/UI/Localized.swift Roost/UI/Events.swift \
//            Roost/UI/ShortcutRecorder.swift Tools/shortcut-test.swift | swift -
//
//  The stored form is load-bearing: a pressed key is matched by building
//  its codes the same way and comparing arrays, so a shortcut recorded in a
//  different modifier order would never fire. Recording and matching both
//  go through PopupShortcut.keyCodes, and the cases below hold it to that.
//
import AppKit

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let c = PopupShortcut.self

print("How a shortcut is stored")
check("⌃⌥C is control, option, then the key",
      c.keyCodes(modifiers: [.control, .option], keyCode: 8) == [59, 58, 8])
check("the order is fixed whatever order they were pressed in",
      c.keyCodes(modifiers: [.option, .control, .command], keyCode: 8)
        == c.keyCodes(modifiers: [.command, .control, .option], keyCode: 8))
check("with every modifier: ⌃ ⇧ ⌘ ⌥",
      c.keyCodes(modifiers: [.control, .shift, .command, .option], keyCode: 8) == [59, 60, 55, 58, 8])

print("\nWhat may be recorded")
check("⌃⌥ plus a letter", c.isAcceptable(modifiers: [.control, .option], keyCode: 8))
check("⌘ plus a letter", c.isAcceptable(modifiers: [.command], keyCode: 8))
check("a function key on its own", c.isAcceptable(modifiers: [], keyCode: 122))
check("not a plain letter: it would fire on every keystroke", !c.isAcceptable(modifiers: [], keyCode: 8))
check("not shift and a letter: that is a capital", !c.isAcceptable(modifiers: [.shift], keyCode: 8))
check("not a modifier key on its own", !c.isAcceptable(modifiers: [.control], keyCode: 59))

print("\nHow it reads")
let letters: (UInt16) -> String = { [8: "C", 0: "A", 18: "1"][$0] ?? "?" }
check("⌃⌥C", c.display([59, 58, 8], keyName: letters) == "⌃⌥C")
check("modifiers print in the menus' order, not the stored one",
      c.display([59, 60, 55, 58, 0], keyName: letters) == "⌃⌥⇧⌘A")
check("arrows and function keys by their own names",
      c.display([55, 123]) == "⌘←" && c.display([122]) == "F1" && c.display([59, 49]) == "⌃Space")
check("nothing reads as nothing", c.display([]) == "")
check("letters come from the keyboard layout, not a table", !c.keyName(for: 8).hasPrefix("#"))

print("\nOne shortcut, one module")
do {
    let suite = "roost-shortcut-test-\(getpid())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set([59, 58, 8], forKey: "RAM_popupShortcut")
    check("a combination RAM holds is reported as RAM's",
          c.owner(of: [59, 58, 8], excluding: "CPU", defaults: defaults) == "RAM")
    check("re-recording RAM's own is not a clash",
          c.owner(of: [59, 58, 8], excluding: "RAM", defaults: defaults) == nil)
    check("a free combination clashes with nothing",
          c.owner(of: [59, 58, 0], excluding: "CPU", defaults: defaults) == nil)
check("the launcher's ⌃Space is not free for a module",
      c.owner(of: [59, 49], excluding: "CPU", defaults: defaults) != nil)
check("nor ⌃Tab, its ⌥Tab fallback, ⌃` or ⌃1",
      [[59, 48], [58, 48], [59, 50], [59, 18]].allSatisfy {
          c.owner(of: $0, excluding: "Clipboard", defaults: defaults) != nil })
check("while ⌃⇧Space is",
      c.owner(of: [59, 60, 49], excluding: "CPU", defaults: defaults) == nil)
defaults.set([59, 58, 9], forKey: "Clipboard_popupShortcut")
check("the clipboard's shortcut is checked like a module's",
      c.owner(of: [59, 58, 9], excluding: "CPU", defaults: defaults) == "Clipboard")
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
