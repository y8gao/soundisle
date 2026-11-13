import CryptoKit
import Foundation

/// The file work of an update: verify, unpack, and hand the swap to a script
/// that can outlive this process — the running bundle cannot be replaced from
/// inside itself.
public enum UpdateInstaller {
    public enum InstallError: Error, Equatable {
        case checksumMismatch
        case unpackFailed
        case notWritable(String)
    }

    public static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")

    /// Streaming digest, so a 5MB build never has to be held in memory as well
    /// as on disk.
    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 16), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unpacks the release archive and returns the `.app` inside it.
    public static func unpack(_ archive: URL, into directory: URL) throws -> URL {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = ditto
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InstallError.unpackFailed }

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw InstallError.unpackFailed
        }
        return app
    }

    /// Starts the swap. The script waits for `pid` to exit, moves the old
    /// bundle aside, copies the new one in, clears the quarantine flag the
    /// download carries (otherwise Gatekeeper blocks the relaunch) and reopens
    /// it. If the copy fails the old bundle goes back.
    public static func swapAfterQuit(
        newApp: URL,
        target: URL,
        pid: Int32,
        staging: URL,
        relaunch: Bool = true
    ) throws {
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw InstallError.notWritable(parent.path)
        }

        let script = swapScript(
            newApp: newApp,
            target: target,
            pid: pid,
            staging: staging,
            relaunch: relaunch
        )
        let scriptURL = staging.appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // nohup + background: the script has to survive the app quitting.
        process.arguments = ["-c", "nohup /bin/sh \(shellQuoted(scriptURL.path)) >/dev/null 2>&1 &"]
        try process.run()
    }

    /// Exposed for tests: the exact shell the swap runs. `relaunch` is false
    /// when the swap happens as the app quits — the user asked to quit, so
    /// the new build waits until they open the app again.
    public static func swapScript(
        newApp: URL,
        target: URL,
        pid: Int32,
        staging: URL,
        relaunch: Bool = true
    ) -> String {
        """
        #!/bin/sh
        # Written by SoundIsle's updater.
        target=\(shellQuoted(target.path))
        new=\(shellQuoted(newApp.path))
        staging=\(shellQuoted(staging.path))
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf "$target.old"
        if ! /bin/mv "$target" "$target.old"; then
          exit 1
        fi
        if ! /usr/bin/ditto "$new" "$target"; then
          /bin/mv "$target.old" "$target"
          exit 1
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null
        rm -rf "$target.old"
        \(relaunch ? "/usr/bin/open \"$target\"" : "# quit by the user: reopen next launch")
        rm -rf "$staging"
        """
    }

    /// Single-quoted, with embedded quotes escaped, so a path with spaces or
    /// Chinese characters (`/Applications/声屿.app`) survives the shell.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
