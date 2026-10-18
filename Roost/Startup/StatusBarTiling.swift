import AppKit

extension AppDelegate {

    /// Silences the WindowServer "Invalid window" log spam on macOS 26.
    ///
    /// On Tahoe every layout pass on an `NSStatusBarWindow` schedules a
    /// tiling-constraints sync (`-[NSWindow(NSFullScreen)
    /// _refreshTilingConstraints:]`) which calls
    /// `SLSPackagesSetWindowConstraints` with the window number. A status bar
    /// window has no regular server-side window on Tahoe -- the low 32 bits
    /// of its `windowNumber` are zero -- so WindowServer rejects every call
    /// and logs `_CGXPackagesSetWindowConstraints: Invalid window` on each
    /// widget update. For a menu bar app that is several lines a second.
    ///
    /// The gate, `-[NSWindow(NSFullScreen) _needsTilingConstraintUpdate]`,
    /// returns true whenever the app is inactive, which for a menu bar app is
    /// almost always. Overriding it on `NSStatusBarWindow` alone stops the
    /// sync being scheduled at all; a status bar window can never be tiled,
    /// so there is nothing to lose. Every other window keeps the default.
    ///
    /// Not specific to Roost: it follows from the status bar window itself,
    /// so any app that redraws a status item on macOS 26 meets it.
    internal func suppressStatusBarTilingConstraintUpdates() {
        guard #available(macOS 26.0, *) else { return }

        let selector = NSSelectorFromString("_needsTilingConstraintUpdate")
        guard let statusBarWindow = NSClassFromString("NSStatusBarWindow"),
              let existing = class_getInstanceMethod(statusBarWindow, selector)
        else { return }

        let alwaysFalse: @convention(block) (AnyObject) -> Bool = { _ in false }
        class_addMethod(statusBarWindow, selector,
                        imp_implementationWithBlock(alwaysFalse),
                        method_getTypeEncoding(existing))
    }
}
