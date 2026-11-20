import AppKit
import CryptoKit

/// Checks for, downloads, verifies and installs a new Roost.
///
/// Written against the GitHub releases API rather than ported: the replacement
/// for `Kit/plugins/Updater.swift`. Three behaviours are different on purpose.
///
/// 1. **A failed check is an error, not "up to date".** The old one compared
///    version strings and returned "not newer" whenever it could not parse
///    one, so a rate-limited or malformed feed was indistinguishable from
///    having the latest build.
/// 2. **The checksum is mandatory when the release publishes one.** Roost is
///    signed ad hoc, so a code-signature check cannot establish anything; the
///    SHA-256 beside the asset is what makes the download trustworthy.
/// 3. **The old copy is quit before it is replaced.** Launching the new binary
///    beside the old one left two processes alive, and the new one could
///    register none of the global hotkeys the old one still held.
final class AppUpdater {

    /// What a check found.
    enum Outcome {
        case upToDate(current: Version)
        case available(Release)
    }

    enum Failure: LocalizedError {
        case noCurrentVersion
        case badResponse(Int)
        case checksumMissing
        case checksumMismatch(expected: String, got: String)
        case mountFailed(String)
        case noAppInImage

        var errorDescription: String? {
            switch self {
            case .noCurrentVersion:
                return "Roost cannot read its own version."
            case .badResponse(let code):
                return "The release feed answered \(code)."
            case .checksumMissing:
                return "The release publishes a checksum but it could not be read."
            case .checksumMismatch(let expected, let got):
                return "The download does not match its checksum.\nExpected \(expected)\nGot      \(got)"
            case .mountFailed(let message):
                return "The disk image could not be opened: \(message)"
            case .noAppInImage:
                return "The disk image does not contain Roost."
            }
        }
    }

    private let repository: String
    private let assetName: String
    private let session: URLSession

    init(repository: String, assetName: String = "Roost.dmg", session: URLSession = .shared) {
        self.repository = repository
        self.assetName = assetName
        self.session = session
    }

    private var feedURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    // MARK: - Check

    func check(completion: @escaping (Result<Outcome, Error>) -> Void) {
        guard let current = Version.current else {
            completion(.failure(Failure.noCurrentVersion)); return
        }

        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completion(.failure(Failure.badResponse(http.statusCode))); return
            }
            guard let data else { completion(.failure(Failure.badResponse(0))); return }
            do {
                let release = try Release.decode(data, assetNamed: self.assetName)
                completion(.success(release.version > current ? .available(release)
                                                              : .upToDate(current: current)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Download

    /// Downloads the image and refuses to hand back one whose checksum does
    /// not match. Fails closed: if the release advertises a checksum and it
    /// cannot be fetched, the download is rejected rather than trusted.
    func download(_ release: Release,
                  progress: @escaping (Double) -> Void = { _ in },
                  completion: @escaping (Result<URL, Error>) -> Void) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Roost-\(release.tag).dmg")

        var observation: NSKeyValueObservation?
        let task = session.downloadTask(with: release.downloadURL) { temp, response, error in
            observation?.invalidate()
            if let error { completion(.failure(error)); return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completion(.failure(Failure.badResponse(http.statusCode))); return
            }
            guard let temp else { completion(.failure(Failure.badResponse(0))); return }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temp, to: destination)
            } catch {
                completion(.failure(error)); return
            }

            guard let checksumURL = release.checksumURL else {
                completion(.success(destination)); return
            }
            self.verify(destination, against: checksumURL) { error in
                if let error {
                    try? FileManager.default.removeItem(at: destination)
                    completion(.failure(error))
                } else {
                    completion(.success(destination))
                }
            }
        }
        observation = task.progress.observe(\.fractionCompleted) { value, _ in
            progress(value.fractionCompleted)
        }
        task.resume()
    }

    /// The published file is `<sha256>  dist/Roost.dmg`; only the first field
    /// is ours to care about.
    private func verify(_ file: URL, against checksumURL: URL,
                        completion: @escaping (Error?) -> Void) {
        var request = URLRequest(url: checksumURL)
        request.timeoutInterval = 20
        session.dataTask(with: request) { data, _, _ in
            guard let data, let text = String(data: data, encoding: .utf8),
                  let expected = text.split(separator: " ").first.map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  expected.count == 64
            else { completion(Failure.checksumMissing); return }

            guard let actual = Self.sha256(of: file) else {
                completion(Failure.checksumMissing); return
            }
            completion(actual == expected ? nil
                       : Failure.checksumMismatch(expected: expected, got: actual))
        }.resume()
    }

    /// Streamed in 1 MB chunks: a disk image does not belong in memory.
    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Install

    /// Replaces the running app and relaunches it.
    ///
    /// The work happens in a detached shell script because the app cannot
    /// overwrite its own bundle while running. The script quits Roost and
    /// waits for the process to go before copying -- two live copies is how
    /// the global hotkeys ended up registered to a dying process.
    func install(_ image: URL, completion: @escaping (Error?) -> Void) {
        let bundle = Bundle.main.bundleURL
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-update-\(UUID().uuidString)")

        // Refused here, while there is still a running Roost to say so. The
        // script used to find out at `rm -rf`, after it had quit the app:
        // `set -e` then stopped it with nothing relaunched, the image still
        // mounted -- and a failure after the `rm` left no Roost at all.
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            completion(CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: bundle.path]))
            return
        }

        // Copied beside the app *before* it is quit, here and waited on, so a
        // bad image or a full disk is reported while Roost is still running
        // -- the detached script could only fail silently, leaving the window
        // on "Installing…". Only the quit, the two-`mv` swap and the relaunch
        // happen after Roost has gone.
        let stage = URL(fileURLWithPath: bundle.path + ".update-\(getpid())")
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            func fail(_ what: String, _ output: String) {
                _ = Self.run("/usr/bin/hdiutil", ["detach", "-quiet", mountPoint.path])
                try? fm.removeItem(at: mountPoint)
                try? fm.removeItem(at: stage)
                let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let error = NSError(domain: "Roost.Update", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: text.isEmpty ? what : "\(what): \(text)"])
                DispatchQueue.main.async { completion(error) }
            }
            try? fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            let attach = Self.run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noautoopen",
                                                       "-mountpoint", mountPoint.path, image.path])
            guard attach.status == 0 else { return fail("The downloaded image could not be opened", attach.output) }
            let source = mountPoint.appendingPathComponent("Roost.app")
            guard fm.fileExists(atPath: source.path) else { return fail("The downloaded image has no Roost in it", "") }
            try? fm.removeItem(at: stage)
            let copy = Self.run("/usr/bin/ditto", [source.path, stage.path])
            guard copy.status == 0 else { return fail("The new version could not be copied", copy.output) }
            _ = Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stage.path])
            _ = Self.run("/usr/bin/hdiutil", ["detach", "-quiet", mountPoint.path])
            try? fm.removeItem(at: mountPoint)
            DispatchQueue.main.async { self.swap(in: stage, for: bundle, image: image, completion: completion) }
        }
    }

    /// Quits Roost, puts the staged copy in its place and relaunches it.
    ///
    /// Detached, because it outlives the app. Whatever happens the trap puts
    /// the old app back if the new one did not arrive, and opens whichever
    /// is there -- and nothing in it runs under `set -e`, so a failed step
    /// cannot stop the cleanup before the relaunch.
    private func swap(in stage: URL, for bundle: URL, image: URL, completion: @escaping (Error?) -> Void) {
        let script = """
        #!/bin/bash
        TARGET=\(shellQuoted(bundle.path))
        STAGE=\(shellQuoted(stage.path))
        IMAGE=\(shellQuoted(image.path))
        OLD="$TARGET.old-$$"

        finish() {
          if [ -d "$OLD" ] && [ ! -d "$TARGET" ]; then mv "$OLD" "$TARGET"; fi
          rm -rf "$STAGE" "$OLD" 2>/dev/null
          open "$TARGET"
        }
        trap finish EXIT

        # Quit the running copy and wait for it, rather than launching a second
        # one beside it.
        pkill -x Roost 2>/dev/null
        for _ in $(seq 1 25); do
          pgrep -x Roost >/dev/null || break
          sleep 0.2
        done
        pgrep -x Roost >/dev/null && pkill -9 -x Roost

        # An app moved or deleted while it ran has nothing to set aside; the
        # new one simply goes where it was.
        if [ -e "$TARGET" ]; then mv "$TARGET" "$OLD" || exit 1; fi
        mv "$STAGE" "$TARGET" && rm -f "$IMAGE"
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-install-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: scriptURL.path)
        } catch {
            try? FileManager.default.removeItem(at: stage)
            completion(error); return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        do {
            try process.run()      // deliberately not waited on: it outlives us
            completion(nil)
        } catch {
            try? FileManager.default.removeItem(at: stage)
            completion(error)
        }
    }

    /// A tool run to completion, with what it said.
    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
