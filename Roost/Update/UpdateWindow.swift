import AppKit

/// The window that offers an update, downloads it and installs it.
///
/// Takes a `Release` rather than a flattened record of strings, which is what
/// lets the adapter in `AppUpdater` go: the window reads the version, the
/// notes and the download straight off the thing the feed produced.
///
/// Built with constraints rather than hard-coded frames, so the release notes
/// decide the height instead of being clipped by it -- the window it replaces
/// laid everything out in fixed rectangles and cut the notes off at two lines.
final class UpdateWindow: NSWindow, NSWindowDelegate {

    var onClose: (() -> Void)?

    private let updater: AppUpdater
    private let body = NSStackView()
    private var pending: Release?
    private var downloaded: URL?

    private let title_ = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let notes = NSTextView()
    private let notesScroll = NSScrollView()
    private let progress = NSProgressIndicator()
    private let dismiss = NSButton()
    private let act = NSButton()

    init(updater: AppUpdater) {
        self.updater = updater
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                   styleMask: [.closable, .titled],
                   backing: .buffered,
                   defer: true)

        self.title = "Roost"
        self.titlebarAppearsTransparent = true
        self.isReleasedWhenClosed = false
        self.delegate = self

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        self.contentView = content

        title_.font = .systemFont(ofSize: 18, weight: .semibold)
        title_.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center

        notes.isEditable = false
        notes.drawsBackground = false
        notes.font = .systemFont(ofSize: 12)
        notes.textColor = .labelColor
        notesScroll.documentView = notes
        notesScroll.hasVerticalScroller = true
        notesScroll.drawsBackground = false
        notesScroll.borderType = .noBorder

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true

        dismiss.bezelStyle = .rounded
        dismiss.title = localized("Close")
        dismiss.target = self
        dismiss.action = #selector(closeWindow)

        act.bezelStyle = .rounded
        act.keyEquivalent = "\r"
        act.target = self
        act.action = #selector(primary)

        let buttons = NSStackView(views: [dismiss, act])
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 10

        body.orientation = .vertical
        body.alignment = .centerX
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        body.setViews([title_, detail, notesScroll, progress, buttons], in: .leading)
        content.addSubview(body)

        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            notesScroll.widthAnchor.constraint(equalTo: body.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: body.widthAnchor),
            progress.widthAnchor.constraint(equalTo: body.widthAnchor)
        ])

        self.center()
        self.setIsVisible(false)
    }

    // MARK: - Showing

    /// A release is available.
    func offer(_ release: Release) {
        self.pending = release
        self.downloaded = nil

        title_.stringValue = "Roost \(release.version) is available"
        detail.stringValue = "You have \(Version.current?.description ?? "an earlier version")"
        notes.string = release.notes.isEmpty ? "No release notes." : release.notes
        notesScroll.isHidden = false
        progress.isHidden = true
        progress.doubleValue = 0
        dismiss.title = localized("Later")
        act.title = localized("Download")
        act.isHidden = false
        present()
    }

    /// Nothing to do -- shown only when the user asked.
    func reportUpToDate() {
        pending = nil
        title_.stringValue = localized("Roost is up to date")
        detail.stringValue = Version.current.map { "Version \($0)" } ?? ""
        notesScroll.isHidden = true
        progress.isHidden = true
        dismiss.title = localized("Close")
        act.isHidden = true
        present()
    }

    /// The check itself failed. Said out loud rather than swallowed, which is
    /// the behaviour this whole component exists to change.
    func report(_ error: Error) {
        pending = nil
        title_.stringValue = localized("Could not check for updates")
        detail.stringValue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        notesScroll.isHidden = true
        progress.isHidden = true
        dismiss.title = localized("Close")
        act.isHidden = true
        present()
    }

    private func present() {
        self.setIsVisible(true)
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Actions

    @objc private func primary() {
        if let image = downloaded {
            act.isEnabled = false
            act.title = localized("Installing…")
            updater.install(image) { [weak self] error in
                guard let error else { return }   // on success the app is replaced and relaunched
                DispatchQueue.main.async {
                    self?.act.isEnabled = true
                    self?.act.title = localized("Install")
                    Alert.show("Could not install the update", error: error)
                }
            }
            return
        }

        guard let release = pending else { return }
        act.isEnabled = false
        act.title = localized("Downloading…")
        progress.isHidden = false

        updater.download(release, progress: { [weak self] fraction in
            DispatchQueue.main.async {
                self?.progress.doubleValue = fraction
                self?.detail.stringValue = "\(Int(fraction * 100))%"
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.act.isEnabled = true
                switch result {
                case .success(let file):
                    self.downloaded = file
                    self.detail.stringValue = localized("Verified. Roost will restart.")
                    self.act.title = localized("Install")
                case .failure(let error):
                    self.progress.isHidden = true
                    self.act.title = localized("Download")
                    self.detail.stringValue = localized("Download failed.")
                    Alert.show("Could not download the update", error: error)
                }
            }
        })
    }

    @objc private func closeWindow() { self.close() }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
