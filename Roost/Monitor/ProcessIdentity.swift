import AppKit

/// What a person calls a process, and the icon to draw beside it.
///
/// The samplers name a process the way the kernel does. `ps` and `nettop`
/// give `p_comm`, which is cut at sixteen characters -- "Google Chrome He"
/// -- and even a full executable name is "com.apple.WebKit.WebContent" or
/// "Google Chrome Helper (Renderer)". Only a process with a Dock icon has an
/// `NSRunningApplication` to ask, and that is the minority of any top-five
/// list, so most rows used to get a Terminal symbol and a truncated name.
///
/// Asked in order, stopping at the first answer:
/// 1. the running application, for its name and icon;
/// 2. the full path from `proc_pidpath`, walked up to the app it is inside --
///    a helper is drawn with its app's icon, so a list of five Chrome
///    helpers is visibly Chrome's;
/// 3. the executable's own name, from the same path, so it is at least not
///    cut short; a few system daemons that turn up in every list get words.
enum ProcessIdentity {

    struct Identity {
        let name: String
        let icon: NSImage?
    }

    /// Icons by path: Launch Services is not something to ask twice a second
    /// for the same five processes.
    private static let icons = NSCache<NSString, NSImage>()

    static func identify(pid: pid_t, fallback: String) -> Identity {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return Identity(name: name, icon: app.icon)
        }
        guard let path = executablePath(pid) else {
            return Identity(name: friendly(fallback) ?? fallback, icon: nil)
        }
        let executable = (path as NSString).lastPathComponent
        if let bundle = owningApp(of: path) {
            let appName = FileManager.default.displayName(atPath: bundle)
            let display = (appName as NSString).deletingPathExtension
            return Identity(name: title(executable: executable, app: display), icon: icon(forFile: bundle))
        }
        return Identity(name: friendly(executable) ?? executable, icon: nil)
    }

    /// A helper's executable usually starts with its app's name already --
    /// "Google Chrome Helper (Renderer)" -- and is then the clearer of the
    /// two. One that does not is said with the app in front, so that
    /// `com.apple.WebKit.WebContent` inside Safari reads as Safari's.
    static func title(executable: String, app: String) -> String {
        if executable == app { return app }
        if executable.lowercased().hasPrefix(app.lowercased()) { return executable }
        return "\(app) · \(friendly(executable) ?? executable)"
    }

    /// The outermost `.app` a path is inside: a helper is often an app
    /// inside an app, and the one a person recognises is the outer one.
    static func owningApp(of path: String) -> String? {
        var built = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            built += "/" + component
            if component.hasSuffix(".app") { return built }
        }
        return nil
    }

    /// Words for the system processes that turn up near the top of any list
    /// and mean nothing by their names. Only these: guessing at the rest
    /// would be worse than showing them as they are.
    static func friendly(_ executable: String) -> String? {
        switch executable {
        case "kernel_task":                  return localized("macOS kernel")
        case "WindowServer":                 return localized("WindowServer (draws the screen)")
        case "mds", "mds_stores", "mdworker", "mdworker_shared":
                                             return localized("Spotlight indexing")
        case "com.apple.WebKit.WebContent":  return localized("Web page content")
        case "com.apple.WebKit.Networking":  return localized("Web page networking")
        case "com.apple.WebKit.GPU":         return localized("Web page graphics")
        case "backupd":                      return localized("Time Machine backup")
        case "softwareupdated":              return localized("Software Update")
        case "photoanalysisd":               return localized("Photos analysis")
        case "bird", "cloudd":               return localized("iCloud sync")
        default:                             return nil
        }
    }

    private static func icon(forFile path: String) -> NSImage {
        let key = path as NSString
        if let hit = icons.object(forKey: key) { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons.setObject(image, forKey: key)
        return image
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
