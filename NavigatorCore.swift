// Pure path rules, shared by the app and its tests.
//
// Everything here is a plain function over paths/URLs with no UI, no Browser, and
// no app state — which is exactly why it lives in its own file: the test bundle
// compiles THIS file, not main.swift (a single-file SwiftUI app can't be imported
// by a test target). The rules below are the ones that actually caused damage in
// real use, so they're the ones worth pinning down with tests.

import Foundation
// CoreGraphics only — no AppKit. The pixel sampling behind the adaptive backing colour
// lives here so `swift test` exercises the SHIPPED code rather than a copy of it.
import CoreGraphics
import ImageIO

import Darwin

// One owner for argv, both pipes and reaping: waiting before draining can block
// forever once either pipe fills, even when the other pipe is completely quiet.
enum ExternalProcess {
    struct Output {
        let stdout: Data
        let stderr: Data
        let status: Int32
        var out: String { String(data: stdout, encoding: .utf8) ?? "" }
        var err: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    enum Result {
        case success(Output)
        case nonZero(Output)
        case timedOut(Output)
        case cancelled(Output)
        case failedToLaunch(Error)

        // Callers keep their command-specific exit messages; launch and timeout
        // failures must never look like a successful status of zero.
        func completed() throws -> Output {
            switch self {
            case .success(let output), .nonZero(let output): return output
            case .failedToLaunch(let error): throw error
            case .cancelled:
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECANCELED))
            case .timedOut:
                throw NSError(domain: "Navigator.ExternalProcess", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The command timed out."])
            }
        }
    }

    // Only the worker owns the PID. Cancellation before launch and after exit cannot
    // accidentally signal a reused PID, and the UI never waits for a child to exit.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    private final class Capture {
        var data = Data()

        func drain(_ handle: FileHandle, until deadline: DispatchTime,
                   cancellation: Cancellation?, receive: ((Data) -> Void)?) {
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var buffer = [UInt8](repeating: 0, count: 16384)
            // Descendants can inherit the pipe after the direct child exits. A
            // bounded, nonblocking read prevents those descriptors defeating timeout.
            while DispatchTime.now() < deadline && cancellation?.isCancelled != true {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                if ready < 0 && errno != EINTR { break }
                guard ready > 0 else { continue }
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    let chunk = Data(buffer.prefix(count))
                    if let receive { receive(chunk) } else { data.append(chunk) }
                }
                else if count == 0 { break }
                else if errno != EINTR && errno != EAGAIN { break }
            }
        }
    }

    // Streaming callbacks run serially on the stdout drain and finish before return.
    // A nil timeout lets searches run until completion or explicit cancellation.
    static func run(_ executable: String, arguments: [String] = [],
                    directory: URL? = nil, environment: [String: String]? = nil,
                    timeout: TimeInterval? = 3600,
                    onLaunch: ((@escaping () -> Bool) -> Void)? = nil,
                    cancellation: Cancellation? = nil,
                    receiveStdout: ((Data) -> Void)? = nil,
                    receiveStderr: ((Data) -> Void)? = nil) -> Result {
        if let timeout, !timeout.isFinite || timeout <= 0 {
            return .failedToLaunch(NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        if cancellation?.isCancelled == true {
            return .failedToLaunch(NSError(domain: NSPOSIXErrorDomain, code: Int(ECANCELED)))
        }
        do { try process.run() } catch { return .failedToLaunch(error) }
        let deadline = timeout.map { DispatchTime.now() + $0 } ?? .distantFuture
        let drainDeadline = timeout == nil ? DispatchTime.distantFuture : deadline + 0.5
        let drains = DispatchGroup()
        let out = Capture(), err = Capture()
        for (capture, pipe) in [(out, stdout), (err, stderr)] {
            drains.enter()
            DispatchQueue.global(qos: .utility).async {
                capture.drain(pipe.fileHandleForReading, until: drainDeadline,
                              cancellation: cancellation,
                              receive: pipe === stdout ? receiveStdout : receiveStderr)
                drains.leave()
            }
        }
        // The callback returns immediately; it can observe liveness without
        // taking ownership of the process or replacing our termination handler.
        onLaunch?({ process.isRunning })
        while cancellation?.isCancelled != true && DispatchTime.now() < deadline {
            if drains.wait(timeout: .now() + 0.025) == .success && !process.isRunning { break }
            // Quiet pipes must not hide cancellation behind a read-to-end wait.
            if process.isRunning { _ = exited.wait(timeout: .now() + 0.025) }
        }
        let cancelled = cancellation?.isCancelled == true
        let timedOut = !cancelled && DispatchTime.now() >= deadline
        if (timedOut || cancelled) && process.isRunning {
            process.terminate()
            // SIGTERM can be ignored. Escalate so timeout still reaps the child.
            if exited.wait(timeout: .now() + 0.25) == .timedOut && process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        drains.wait()
        process.waitUntilExit()
        let output = Output(stdout: out.data, stderr: err.data, status: process.terminationStatus)
        if cancelled { return .cancelled(output) }
        if timedOut { return .timedOut(output) }
        return output.status == 0 ? .success(output) : .nonZero(output)
    }
}

// JSON escapes filename newlines; the four-byte big-endian length also lets a
// killed writer leave an incomplete record without turning it into a result.
enum WalkStream {
    static let subcommand = "--navigator-internal-walk-v1"
    static let tokenKey = "NAVIGATOR_INTERNAL_WALK_TOKEN"
    static let maxRecordBytes = 1_048_576

    struct Request: Codable {
        let root: URL
        let tokens: [String]
        let kindTree: String?
        let showHidden: Bool
        let filters: SearchFilters
        let now: Date
        let cap: Int
    }

    enum Record<Row: Codable>: Codable {
        case row(Row)
        case finished(hitCap: Bool, readFailed: Bool)
    }

    static func encode<Row>(_ record: Record<Row>) throws -> Data {
        let payload = try JSONEncoder().encode(record)
        guard payload.count <= maxRecordBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let count = UInt32(payload.count)
        var data = Data([UInt8(count >> 24), UInt8((count >> 16) & 255),
                         UInt8((count >> 8) & 255), UInt8(count & 255)])
        data.append(payload)
        return data
    }

    struct Reader<Row: Codable> {
        private var pending = Data()
        private(set) var finished = false
        private(set) var hitCap = false
        private(set) var readFailed = false
        private(set) var count = 0
        let cap: Int

        init(cap: Int) { self.cap = cap }

        var complete: Bool { finished && pending.isEmpty }

        mutating func receive(_ data: Data, row: (Row) -> Void) throws {
            pending.append(data)
            while pending.count >= 4 {
                guard !finished else { throw CocoaError(.fileReadCorruptFile) }
                let length = pending.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0, length <= WalkStream.maxRecordBytes else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                guard pending.count >= 4 + length else { return }
                let record = try JSONDecoder().decode(Record<Row>.self,
                    from: Data(pending.dropFirst(4).prefix(length)))
                pending = Data(pending.dropFirst(4 + length))
                switch record {
                case .row(let value):
                    guard count < cap else { throw CocoaError(.fileReadCorruptFile) }
                    count += 1
                    row(value)
                case .finished(let capped, let failed):
                    guard !capped || count == cap else { throw CocoaError(.fileReadCorruptFile) }
                    finished = true; hitCap = capped; readFailed = failed
                }
            }
        }
    }

    struct Writer<Row: Codable> {
        let cap: Int
        let write: (Data) throws -> Void
        private(set) var count = 0

        init(cap: Int, write: @escaping (Data) throws -> Void) {
            self.cap = cap; self.write = write
        }

        // An extra matching row, not merely reaching the limit, proves truncation.
        mutating func append(_ row: Row) throws -> Bool {
            guard count < cap else { return false }
            try write(WalkStream.encode(Record<Row>.row(row)))
            count += 1
            return true
        }

        func finish(hitCap: Bool, readFailed: Bool) throws {
            try write(WalkStream.encode(Record<Row>.finished(hitCap: hitCap, readFailed: readFailed)))
        }
    }
}

/// Reading an archive's shape without expanding it, and reading a running expansion's
/// progress off the tool's own chatter.
///
/// Copying has had a progress window with a Cancel button for a long time; extracting
/// had nothing at all. On a local disk that is invisible — a 1.16 GB zip expands in
/// about 3 seconds. On an SMB share the same archive was measured at roughly 11 seconds
/// PER FILE, almost all of it round trips rather than data, and 1,223 files of silence
/// with no way to stop it is indistinguishable from a hang.
public enum ArchiveProgressRules {

    /// How many entries a zip holds, read from its End of Central Directory record.
    ///
    /// The EOCD sits at the very end of the file, so this needs the tail and not the
    /// 793 MB in front of it — which matters when the archive is on the share. `tail`
    /// is the last bytes of the file, and must be at least the 22-byte record; pass
    /// more to survive a zip comment, which can push the record up to 64 KB from the end.
    ///
    /// nil means "do not claim to know": an empty tail, no signature (not a zip, or the
    /// comment is longer than what was read), or the 0xFFFF that says the real count is
    /// in a Zip64 record this does not parse. The progress window shows a count without
    /// a bar in that case, which is honest, rather than a bar that lies.
    public static func zipEntryCount(tail: Data) -> Int? {
        let sig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let b = [UInt8](tail)
        guard b.count >= 22 else { return nil }
        // Scan backwards: the LAST signature is the real record. A zip that stores a
        // file whose own bytes happen to contain this signature would otherwise win.
        var i = b.count - 22
        while i >= 0 {
            if b[i] == sig[0], b[i+1] == sig[1], b[i+2] == sig[2], b[i+3] == sig[3] {
                let count = Int(b[i+10]) | (Int(b[i+11]) << 8)   // little-endian uint16
                return count == 0xFFFF ? nil : count
            }
            i -= 1
        }
        return nil
    }

    /// The file an extraction is working on, from one line of the tool's verbose output,
    /// or nil for a line that is not about a file.
    ///
    /// ditto -V writes "copying file NAME ... " and a following "N bytes for NAME"; only
    /// the first is counted, or every entry would count twice. tar -xv writes "x NAME".
    /// Both go to stderr, which is why run() had to learn to stream it.
    public static func extractedName(fromLine line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "copying file ") {
            var name = String(t[r.upperBound...])
            if let dots = name.range(of: " ...", options: .backwards) { name = String(name[..<dots.lowerBound]) }
            return name.isEmpty ? nil : name
        }
        if t.hasPrefix("x ") {
            let name = String(t.dropFirst(2))
            return name.isEmpty ? nil : name
        }
        return nil
    }
}

enum PathRules {

    static func canGoUp(_ url: URL) -> Bool {
        url.deletingLastPathComponent().path != url.path
    }

    // Paste may duplicate in place; drops and Send To cannot. Share the filtering so
    // a destination menu never promises a transfer the executor will discard.
    static func transferSources(_ urls: [URL], into directory: URL, allowSameFolder: Bool = false) -> [URL] {
        urls.filter {
            $0.isFileURL && $0.path != directory.path &&
                (allowSameFolder || $0.deletingLastPathComponent().path != directory.path)
        }
    }

    /// An AppleDouble sidecar: the "._name" file macOS writes beside "name" to carry a
    /// resource fork and extended attributes onto a filesystem that has nowhere to put
    /// them (exFAT, FAT, most SMB shares, many USB sticks).
    ///
    /// It matters here because the sidecar copies the original's WHOLE name, extension
    /// and all. So "._CNY_Sept22_Review.zip" ends in .zip while containing an AppleDouble
    /// header, and every extension-based check calls it an archive. Extracting a folder
    /// of zips off a USB stick then failed on half the selection with
    /// "ditto: Couldn't read PKZip signature" — a real error about a file that was never
    /// an archive and that the user never meant to select.
    ///
    /// Matching the name, not the bytes, is deliberate: the answer has to be the same for
    /// a file on an unreadable volume as for one in front of us, and "._" is a reserved
    /// convention rather than a guess.
    static func isAppleDouble(_ name: String) -> Bool { name.hasPrefix("._") }

    /// How long to allow an archive job that moves `bytes` before calling it hung.
    ///
    /// ExternalProcess defaults to an hour, which is right for a command that should
    /// answer in seconds and wrong for expanding a 793 MB zip onto an SMB share: that
    /// one was measured at roughly 84 minutes, so it would be killed at 60 and the
    /// half-written destination DELETED, reporting "the command timed out" after an
    /// hour of real work. A timeout that destroys the output has to be slower than the
    /// slowest honest run, not faster than it.
    ///
    /// 20 KB/s is the floor, not an estimate. The same share measured 13 MB/s reading
    /// and 2.4 MB/s writing, and ditto managed about 0.15 MB/s of output through it
    /// because every entry costs SMB round trips. The floor sits well under the worst
    /// of that so a slow share is never mistaken for a dead one, while an archive that
    /// truly hangs still ends instead of pinning the UI on "Extracting…" forever.
    ///
    /// ponytail: a fixed floor rate, not progress-driven. If a share is ever slower
    /// than this, watch ditto's output for movement instead of guessing from size.
    static func archiveTimeout(bytes: Int64) -> TimeInterval {
        max(3600, Double(bytes) / 20_000)
    }


    // Search selections can span parents; bare names would archive unrelated siblings.
    static func archiveInputs(_ urls: [URL]) -> (directory: URL, entries: [String])? {
        guard let first = urls.first, urls.allSatisfy({ $0.isFileURL }) else { return nil }
        let paths = urls.map { $0.standardizedFileURL.pathComponents }
        var common = first.standardizedFileURL.deletingLastPathComponent().pathComponents
        for path in paths {
            common = Array(zip(common, path.dropLast()).prefix { $0 == $1 }.map { $0.0 })
        }
        let directory = URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true)
        // Prefixing ./ also keeps a selected name beginning with '-' out of zip's options.
        let entries = paths.map { "./" + $0.dropFirst(common.count).joined(separator: "/") }
        return (directory, entries)
    }

    /// True when `dir` is `src` itself or sits inside it.
    ///
    /// Copying or moving a folder into its own subtree must be refused: FileManager
    /// happily recurses into the copy it is creating and only stops when the path
    /// gets too long — a real run produced 231 junk directories nested over 1000
    /// characters deep. The `/` suffix matters: "/a/bc" is NOT inside "/a/b".
    static func isSelfOrDescendant(_ dir: URL, of src: URL) -> Bool {
        let s = src.standardizedFileURL.resolvingSymlinksInPath().path
        let d = dir.standardizedFileURL.resolvingSymlinksInPath().path
        return d == s || d.hasPrefix(s.hasSuffix("/") ? s : s + "/")
    }

    // UI hover/menu checks cannot resolve symlinks on a stalled mount. Transfers
    // still use the resolved check above, on their worker, before writing anything.
    static func isLexicalSelfOrDescendant(_ dir: URL, of src: URL) -> Bool {
        let s = lexicalPath(src.path)
        let d = lexicalPath(dir.path)
        return d == s || d.hasPrefix(s.hasSuffix("/") ? s : s + "/")
    }

    /// The deepest of `roots` that contains `url`, or nil if none do.
    ///
    /// Used to answer "which mounted volume is this folder actually on?" for Eject.
    /// Deepest, not first match: "/" contains every path, and a volume can be
    /// mounted inside another one — the longer mount point is always the real owner.
    static func deepestRoot(containing url: URL, among roots: [URL]) -> URL? {
        roots.filter { isLexicalSelfOrDescendant(url, of: $0) }
             .max { lexicalPath($0.path).count < lexicalPath($1.path).count }
    }

    /// A favourite's location beneath its volume root:
    /// "/Volumes/Games/artSource" -> "artSource". Empty when the path IS the volume
    /// root. Used to re-anchor a network favourite when its share comes back on a
    /// different mountpoint (e.g. "Games-1" instead of "Games").
    static func shareRelativePath(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 2, parts[0] == "Volumes" else { return "" }
        return parts.dropFirst(2).joined(separator: "/")
    }

    /// First free "name", "name 2", "name 3"… in `dir`. Used for Keep Both on a
    /// name clash and for new folders/aliases/archives.
    static func uniqueDest(_ dir: URL, _ name: String, exists: (String) -> Bool) -> URL {
        var dest = dir.appendingPathComponent(name)
        guard exists(dest.path) else { return dest }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var i = 2
        while exists(dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            i += 1
        }
        return dest
    }

    /// True when renaming an item to `dest` would clobber a DIFFERENT item, so the
    /// user has to be asked before anything touches the disk.
    ///
    /// `isSameItem` must be a file-IDENTITY check (fileResourceIdentifier), never a
    /// path or string comparison. macOS volumes are case-insensitive by default, so
    /// renaming "photo.png" -> "Photo.png" finds the file ITSELF sitting at the
    /// destination: a bare `exists` check calls that a collision and refuses a rename
    /// that FileManager.moveItem performs perfectly happily.
    static func renameCollides(dest: String,
                               exists: (String) -> Bool,
                               isSameItem: (String) -> Bool) -> Bool {
        exists(dest) && !isSameItem(dest)
    }

    /// Why `name` can't be used as a filename, or nil if it can.
    ///
    /// "/" is the POSIX path separator and ":" is the classic-Mac one the Finder still
    /// swaps with "/" when it displays a name. Handed to FileManager they either build
    /// a path into some other directory or fail with "the file doesn't exist" —
    /// an error naming a folder the user never mentioned, which explains nothing.
    static func invalidNameReason(_ name: String) -> String? {
        if name.contains("/") { return "A file name can’t contain “/”." }
        if name.contains(":") { return "A file name can’t contain “:”." }
        return nil
    }

    /// The extension change a rename makes, or nil when there's nothing worth raising
    /// Finder's "are you sure you want to change the extension?" prompt over.
    ///
    /// Directories are exempt: Foundation happily reports a pathExtension for a folder
    /// named "My.Backups", but nothing opens a folder by extension, so warning about it
    /// is pure noise. Only the LAST dot component counts, which is why "archive.tar.gz"
    /// -> "archive.tar.bz2" reports gz -> bz2 and says nothing about ".tar". Case
    /// differences count ("a.PNG" -> "a.png"): the name on disk really does change.
    static func extensionChange(from old: String, to new: String,
                                isDirectory: Bool) -> (from: String, to: String)? {
        guard !isDirectory else { return nil }
        let o = (old as NSString).pathExtension, n = (new as NSString).pathExtension
        return o == n ? nil : (o, n)
    }

    /// Name for pasting a file into its own folder: "photo.jpg" -> "photo (1).jpg",
    /// then "(2)", "(3)"… (Explorer-style in-place duplicate).
    static func numberedCopyDest(_ dir: URL, _ name: String, exists: (String) -> Bool) -> URL {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        func make(_ n: Int) -> URL {
            dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
        }
        var i = 1, dest = make(1)
        while exists(dest.path) { i += 1; dest = make(i) }
        return dest
    }

    /// True for an output this app produced, so batch runs skip their own results
    /// and re-running is safe. `suffix` is "_rmbg" or "_upscaled".
    static func isOwnOutput(_ url: URL, suffix: String) -> Bool {
        url.deletingPathExtension().lastPathComponent.lowercased().hasSuffix(suffix)
    }

    /// The new element order after a sidebar drag-reorder, as indices into the
    /// original array, with one element optionally forced back to the front.
    ///
    /// Home is that pinned element: it's the fixed anchor of the Favorites list, so
    /// it returns to the top wherever it gets dropped — and it must also survive
    /// being displaced when something else is dropped above it. Index math after a
    /// move is easy to get subtly wrong, so it lives here where it can be tested.
    /// `to` follows SwiftUI's onMove convention: the dragged items end up just before
    /// whatever was originally at that offset (`count` means "to the end"). The move
    /// is spelled out rather than using Array.move(fromOffsets:toOffset:) because that
    /// lives in SwiftUI, and this file is deliberately UI-free so the tests can reach it.
    static func reorder(count: Int, from: IndexSet, to: Int, pinnedToFront pin: Int? = nil) -> [Int] {
        let picked = from.sorted().filter { $0 >= 0 && $0 < count }
        let moving = picked.map { $0 }
        var order = Array(0..<count)
        for i in picked.reversed() { order.remove(at: i) }
        // Every moved item that sat before the insertion point shifts it left.
        let insertAt = min(max(to - picked.filter { $0 < to }.count, 0), order.count)
        order.insert(contentsOf: moving, at: insertAt)
        if let pin, let at = order.firstIndex(of: pin), at != 0 {
            order.insert(order.remove(at: at), at: 0)
        }
        return order
    }

    /// A File Provider location — Google Drive, iCloud Drive and friends.
    static func isCloudProvider(_ url: URL) -> Bool {
        let p = url.path
        return p.contains("/Library/CloudStorage/") || p.contains("/Library/Mobile Documents/")
    }

    /// True when a drop must be forced to COPY because it takes items OUT of a cloud
    /// provider.
    ///
    /// Cloud providers live on the local volume, so comparing volume identifiers
    /// calls them "same volume" and a drag out would MOVE — deleting the original.
    /// On a shared team drive that removes it for everyone, from a gesture that looks
    /// like "give me a local copy". Rearranging within the provider stays a move.
    static func leavesCloudProvider(_ sources: [URL], into dest: URL) -> Bool {
        !isCloudProvider(dest) && sources.contains(where: isCloudProvider)
    }

    /// Every way a Google Drive location can be written down, re-anchored onto ONE
    /// Mac's Drive account root (".../Library/CloudStorage/GoogleDrive-me@x.com").
    ///
    /// Four inputs, one answer: a full path from ANOTHER Mac (different home folder,
    /// different account email), the username-free "Google Drive/…" form Navigator's
    /// own Copy Local Path produces, a bare "Shared drives/…" or "My Drive/…", and —
    /// for free, because it carries the same marker — a path that is already correct
    /// here, which re-anchors onto itself and comes back byte-identical.
    ///
    /// nil means "not a Drive path", never "couldn't fix it": callers keep whatever
    /// they had rather than substituting a guess. The account folder is the one
    /// component always dropped, because it is the one thing that is never portable.
    /// A portable, username-free path for a Drive item, matching the breadcrumb:
    /// /Users/x/Library/CloudStorage/GoogleDrive-x@…/Shared drives/A/B
    ///   → "Google Drive/Shared drives/A/B"
    ///
    /// Purely a string transform on the PATH. It needs nothing from Drive itself - no item id,
    /// no sync state - which is the whole point: it works on a file Drive has not registered
    /// yet. Anything gated on a Drive item id must not also gate this.
    static func googleDrivePortablePath(_ path: String) -> String? {
        guard let r = path.range(of: "/CloudStorage/GoogleDrive-") else { return nil }
        let after = path[r.upperBound...]
        guard let slash = after.firstIndex(of: "/") else { return nil }
        let rel = after[after.index(after: slash)...]
        return rel.isEmpty ? "Google Drive" : "Google Drive/\(rel)"
    }

    static func googleDrivePath(_ input: String, accountRoot: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var rel: String?
        if let r = s.range(of: "/CloudStorage/GoogleDrive-") {
            let after = s[r.upperBound...]
            if let slash = after.firstIndex(of: "/") { rel = String(after[after.index(after: slash)...]) }
        } else if s.hasPrefix("Google Drive/") {
            rel = String(s.dropFirst("Google Drive/".count))
        // Matched on a whole component, not a prefix: "Shared drivesXYZ" is somebody
        // else's folder name, and anchoring it under Drive would invent a path.
        } else if driveRoots.contains(where: { s == $0 || s.hasPrefix($0 + "/") }) {
            rel = s
        }
        // A leading "/" would make appending produce "…/GoogleDrive-me//Shared drives",
        // and an empty tail would silently hand back the account root — neither is a
        // location anyone asked for.
        guard let rel, !rel.isEmpty, !rel.hasPrefix("/") else { return nil }
        return accountRoot + "/" + rel
    }

    /// The two folders Drive for desktop always mounts at the account root.
    private static let driveRoots = ["Shared drives", "My Drive"]

    /// The drive-relative path ("Shared drives/A/B") for a chain of folder titles
    /// walked from an item UP to its root — the order a parent walk produces.
    ///
    /// A shared drive's root folder is the drive itself, and Drive for desktop mounts
    /// those one level down under "Shared drives"; a My Drive walk already ends at a
    /// folder called "My Drive", so that one needs no prefix. Feed the result back
    /// through `googleDrivePath` rather than joining a real path here — one place
    /// knows where the mount lives.
    static func driveRelativePath(leafFirst chain: [String], isSharedDrive: Bool) -> String? {
        guard !chain.isEmpty, !chain.contains(where: { $0.isEmpty }) else { return nil }
        let parts = (isSharedDrive ? ["Shared drives"] : []) + chain.reversed()
        guard driveRoots.contains(parts[0]) else { return nil }
        return parts.joined(separator: "/")
    }

    /// The Drive item id inside a drive.google.com / docs.google.com link, which is
    /// the only part of such a URL that means anything locally — Drive for desktop
    /// stamps that same id on the synced file as an xattr.
    ///
    /// Covers the three shapes Google hands out: /drive/folders/<id>, /file/d/<id>/view
    /// (and every /<kind>/d/<id> Docs variant), and the legacy /open?id=<id>.
    static func googleDriveItemID(webURL: String) -> String? {
        guard let c = URLComponents(string: webURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = c.host, host == "drive.google.com" || host == "docs.google.com"
        else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { $0 == "folders" || $0 == "d" }), i + 1 < parts.count {
            return validDriveID(parts[i + 1])
        }
        return validDriveID(c.queryItems?.first { $0.name == "id" }?.value)
    }

    /// Drive ids are long base64url-ish strings. Checked so that a truncated or
    /// decorative URL ("/drive/folders/" + nothing, ".../d/view") yields nil instead
    /// of a lookup for a word.
    private static func validDriveID(_ s: String?) -> String? {
        guard let s, s.count >= 12,
              s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return s
    }
}

/// Index Tab / ⇧Tab should land on, given where the selection is now.
///
/// Split out from the Browser because the two ends are where this goes wrong and a
/// UI test can't pin them down: Swift's `%` returns a NEGATIVE remainder for a
/// negative left operand, so the obvious `(cur + delta) % count` sends ⇧Tab on the
/// first item to index -1 and traps. Adding `count` before the modulo is what makes
/// the backwards wrap land on the last item. `nil` (nothing selected yet) starts at
/// the first item going forward and the last going backward, so Tab into an empty
/// selection always picks the end you're heading away from.
func cycledSelectionIndex(from current: Int?, delta: Int, count: Int) -> Int? {
    guard count > 0 else { return nil }
    guard let cur = current else { return delta < 0 ? count - 1 : 0 }
    return ((cur + delta) % count + count) % count
}

/// Rules for "Restyle (AI)" — the pure, testable parts.
///
/// Everything here is Vertex-only. Two things were wrong at different points and
/// are worth recording so they don't get re-learned the hard way:
///
/// 1. There is no Vertex endpoint that returns TEXT from an image — confirmed by
///    probing ~15 plausible route names (all 404) and by posting real vision
///    models straight to /v1/images, which correctly rejects anything outside its
///    four-model image-generation allowlist. A vision pre-pass briefly went
///    through fal to work around that; told to stop, which is how /v1/vision came
///    to exist instead — a small endpoint on the SAME Vertex service, added
///    specifically for this (see the ops runbook).
/// 2. Separately, and discovered only while wiring up /v1/vision: the image
///    generation call (H5GService.image) was silently sending every input image
///    under the wrong JSON key ("data" instead of "base64", the key the service
///    actually reads). No error, no 400 — the image was just never attached.
///    Proved directly: a request naming a completely different subject, with a
///    real photo attached under the wrong key, generated the wrong subject with
///    zero trace of the real photo. Every restyle before that fix was pure
///    text-to-image generation from the prompt, not an edit of the source — it
///    only ever looked like editing when the prompt's identity anchors were
///    specific enough to regenerate something recognizable from scratch.
///
/// With that fixed, the source image is a genuine edit target and a reference
/// image is a genuine second input. Named identity anchors ("golden mane, lion
/// face" rather than "the subject") remain the right call regardless — it's
/// Google's own documented guidance for holding identity through an edit, not a
/// workaround for the transport bug — but they're no longer trying to make up
/// for an image that was never there. `restylePrompt` handles no reference;
/// `restylePromptTwoImage` handles a real second reference image, source first,
/// reference second — re-test before reordering.

/// Which of the two possible images actually reach the model: the SOURCE (the file
/// being restyled) and the style REFERENCE. Either can be withheld, leaving its side
/// of the job to text alone — a content description instead of the source, style notes
/// instead of the reference.
///
/// This exists as one named type rather than two loose Bools because four things have
/// to stay in agreement about the mode: which prompt shape is used ("preserve this
/// image" vs "create a new image"), whether padding means anything (it only protects a
/// source image that's actually being sent), whether an empty content description is
/// fatal (it is, when the description is the only thing defining the subject), and what
/// gets recorded in the output's metadata. Deriving each of those separately from
/// `sendSource`/`sendReference` is how they'd drift apart.
enum RestyleInputMode: String {
    /// Source + reference: redraw this image in that image's style. The original mode.
    case editWithStyleImage
    /// Source only: redraw this image in a described style.
    case editWithStyleText
    /// Reference only: build the subject from its description, in that image's style.
    case createWithStyleImage
    /// Neither: pure text-to-image from a described subject and a described style.
    case createWithStyleText

    init(sendSource: Bool, sendReference: Bool) {
        switch (sendSource, sendReference) {
        case (true, true):   self = .editWithStyleImage
        case (true, false):  self = .editWithStyleText
        case (false, true):  self = .createWithStyleImage
        case (false, false): self = .createWithStyleText
        }
    }

    var sendsSource: Bool { self == .editWithStyleImage || self == .editWithStyleText }
    var sendsReference: Bool { self == .editWithStyleImage || self == .createWithStyleImage }

    /// True when the content description is the ONLY thing defining the subject, so an
    /// empty one can't produce a restyle of anything — it produces an unrelated image.
    var needsContentText: Bool { !sendsSource }

    /// Padding exists to stop Nano Banana flattening a transparent SOURCE to black.
    /// With no source image being sent there is nothing to pad.
    var padApplies: Bool { sendsSource }

    /// Recorded in the output PNG so a file can still say how it was made months later.
    var label: String {
        switch self {
        case .editWithStyleImage:   return "source + style image"
        case .editWithStyleText:    return "source + style text"
        case .createWithStyleImage: return "text content + style image"
        case .createWithStyleText:  return "text only"
        }
    }
}

enum RestyleRules {

    // MARK: - Aspect ratio

    /// Ratios the Gemini image endpoint accepts.
    /// "auto" lets the model keep the source's shape — the right default for a restyle,
    /// where reframing is the last thing wanted. The rest are the fixed ratios.
    static let aspects = ["auto", "21:9", "16:9", "3:2", "4:3", "5:4", "1:1", "4:5", "3:4", "2:3", "9:16"]

    /// Fixed ratios only — "auto" has no numeric shape, so nearest-match ignores it.
    static var fixedAspects: [String] { aspects.filter { $0 != "auto" } }

    /// The listed ratio closest to a real image's shape, so the sheet opens on
    /// something that won't reframe the art. Compared in log space, so being 10%
    /// too wide counts the same as 10% too tall — a plain difference of ratios
    /// biases towards the wide end (21:9 and 16:9 are further apart numerically
    /// than 9:16 and 2:3, though both are one step apart perceptually).
    static func nearestAspect(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "1:1" }
        let target = log(Double(width) / Double(height))
        return fixedAspects.min { a, b in
            abs(log(ratio(a)) - target) < abs(log(ratio(b)) - target)
        } ?? "1:1"
    }

    /// "16:9" -> 1.777…  Returns 1 for anything unparseable.
    static func ratio(_ aspect: String) -> Double {
        let p = aspect.split(separator: ":").compactMap { Double($0) }
        guard p.count == 2, p[1] != 0 else { return 1 }
        return p[0] / p[1]
    }

    // MARK: - Models

    /// Resolutions offered per model.
    ///
    /// Driven by the model table rather than a rule of thumb. An earlier version here
    /// hard-limited every flash model to 1K, on the strength of a note in the AI hub's
    /// client rather than a measurement — that was wrong to assert, and it hid sizes
    /// the newer models do render. Anything a model refuses comes back as a plain API
    /// error, which is better than a picker that quietly withholds an option.
    static func sizes(forModelFlag flag: String) -> [String] { ["1K", "2K", "4K"] }

    // MARK: - Vision prompts (describe an image in text, via /v1/vision)

    /// Describes WHAT IS IN the source image and HOW IT IS LAID OUT, so a restyle can
    /// change the rendering without losing content. Read on the SOURCE image.
    ///
    /// This started out character-centric — "describe the persistent IDENTITY of the
    /// main subject" — and that failed badly on real work. Given a slot pay table
    /// holding ~20 symbols, four pay panels and dozens of numbers, it picked the one
    /// hooded avatar inside it and returned "a mysterious shadowy figure wearing a
    /// hooded sweatshirt"; the restyle then dutifully produced exactly that, one
    /// character full-frame, and the entire layout was gone. Most art here is a sheet
    /// or art board, not a single subject, so "the main subject" was the wrong frame.
    ///
    /// It also used to invite "distinguishing markings or colouring" and "colour
    /// scheme", which is actively counterproductive: colour and texture are precisely
    /// what a restyle replaces, so naming them drags the old look into the new one.
    /// Style is now explicitly forbidden here and lives only in styleSystemPrompt.
    static let identitySystemPrompt = """
        Describe WHAT IS IN this image and HOW IT IS LAID OUT, so it can be redrawn in a completely different art style without losing any content.

        The image may be any of these — describe whichever it actually is:
        - a sheet or art board holding many symbols, icons and labels (very common)
        - a single character, creature, or object
        - a background, environment or scene with no characters at all
        - a UI element: panel, frame, banner, button, badge, pay table

        Always cover:
        - What kind of image it is, in an opening clause.
        - The layout: how many distinct elements there are and how they are arranged (grid, rows, columns, groups) and roughly where each sits.
        - Every distinct element, briefly — what it depicts. Account for all of them.
        - ALL visible text, numbers and labels, transcribed EXACTLY, and where each belongs.
        - Structural parts: frames, panels, borders, dividers, badges.

        NEVER mention: colour, shade, tone or hue of ANYTHING — not the background, not a border, not a material. "wooden", "metal", "leaf" are fine as WHAT something is; "dark reddish-brown wood", "green leaf", "gold border" are not, because the colour word alone is enough to drag the old palette into a restyle that changes it. If you would name a colour, describe the material or shape instead and stop there. Also never mention: art style, palette, texture, shading, lighting, glow, finish, or mood — all replaced, all forbidden for the same reason.

        Be complete rather than brief — if there are twenty symbols, account for twenty. Plain prose or a compact list. No preamble.
        """

    /// Extracts a reusable ART STYLE from a reference image, read on the REFERENCE.
    /// The hard rules are load-bearing and were tuned against a live model: a version
    /// that only said "don't mention the subject" still returned "fine strands of fur"
    /// and "sheen of leather" for a lion in leather robes — material nouns that would
    /// grow fur on a fish. Naming the banned materials explicitly, and asking for
    /// rendering behaviour instead, produced zero leakage.
    static let styleSystemPrompt = """
        You extract a reusable ART STYLE from a reference image so it can be applied \
        to a COMPLETELY DIFFERENT subject.

        Describe ONLY: medium and rendering technique, brush/line quality, palette and \
        colour temperature, lighting character and direction, contrast and value range, \
        surface finish, edge treatment, level of detail, grain/texture, and overall mood.

        EDGE TREATMENT IS REQUIRED, and must be stated explicitly, because everything \
        drawn from this description depends on it. Say which of these the artwork does:
        - a drawn contour: an inked outline or keyline following the silhouette, or \
        visible line art — say so plainly, using the word "outline" or "line art";
        - or no drawn contour: forms separated by painted colour and value meeting, with \
        the edge being where one surface ends and the next begins.
        Then say whether edges are crisp, soft, or crisp at the focal features and soft \
        where forms turn away, and whether there is any halo, glow or light band \
        following the silhouette.

        END your answer with these two lines, exactly, on their own lines:
        EDGE-TREATMENT: outline
        RIM-GLOW: yes
        Answer "outline" when a contour has deliberately been DRAWN — an ink line or \
        keyline following the silhouette, of roughly even weight, sitting on top of the \
        painting as a separate mark, or visible line art anywhere in the piece. Dark \
        recesses, embossed or engraved relief, occlusion shadow where forms meet, and a \
        dark material simply ending against a lighter one are NOT drawn contours — answer \
        "none" for those.

        Use RIM-GLOW "yes" only when a glow, halo or light band follows the silhouette, \
        and "no" when it does not.

        HARD RULES — breaking these ruins the result:
        - Never name or imply the subject: no species, creature, person, character, \
        clothing, props, setting, or body parts.
        - Never name materials that belong to the subject (e.g. fur, hair, scales, \
        feathers, skin, leather, fabric, metal armour). Describe HOW surfaces are \
        rendered instead — "fine high-frequency detail on organic surfaces", \
        "soft specular sheen".
        - No composition, framing, pose, or background layout.
        - Output style directives only, as one dense paragraph under 140 words, no preamble.
        """

    // MARK: - Prompts

    /// Single-image restyle: no reference, just the source and a typed description of
    /// the desired look. Contents are stated FIRST and the style change LAST —
    /// reordering to lead with the change and follow with "but keep X" measurably let
    /// content drift on live runs.
    ///
    /// The preservation clause used to read "This exact character must remain
    /// unchanged… same species, same face, same markings, same clothing", which is
    /// meaningless for a pay table or a background and actively harmful: it told the
    /// model to think in terms of a creature, and a 20-symbol art board came back as
    /// one hooded figure. It now protects elements, counts, layout and text instead.
    static func restylePrompt(identityAnchors: String, styleText: String, extra: String = "") -> String {
        let contents = anchorClause(identityAnchors,
                                    fallback: "everything currently in the image, exactly as arranged.")
        let style = styleText.trimmingCharacters(in: .whitespacesAndNewlines)
        var p = """
            \(preserveClause)

            CONTENTS TO PRESERVE: \(contents)

            Now replace the art style of this image with the following:

            ART STYLE: \(style)
            """
        let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { p += "\n\nADDITIONAL STYLE NOTES: \(e)" }
        return p
    }

    /// Two-image restyle: a real style-reference image alongside the source. Role
    /// labels ("IMAGE 1 is…", "IMAGE 2 is a style reference only…") are what keep the
    /// reference's own subject out of the output; without them the reference took the
    /// output over entirely on live runs.
    static func restylePromptTwoImage(identityAnchors: String, extra: String = "") -> String {
        let contents = anchorClause(identityAnchors,
                                    fallback: "everything currently in IMAGE 1, exactly as arranged.")
        var p = """
            IMAGE 1 is the artwork to redraw. \(preserveClause)

            CONTENTS OF IMAGE 1 TO PRESERVE: \(contents)

            IMAGE 2 is a STYLE reference ONLY. Do not copy its subject, objects, layout \
            or text — none of its content may appear in the output.

            Now replace the art style of IMAGE 1 with the art style of IMAGE 2 — its \
            rendering technique, colour palette, linework and lighting only.
            """
        let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { p += "\n\nADDITIONAL STYLE NOTES: \(e)" }
        return p
    }

    /// The contents clause used by both prompt shapes: the description if there is one
    /// (with a trailing period ensured so it doesn't run into the next sentence), else a
    /// generic fallback that still forbids reinterpretation.
    private static func anchorClause(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }

    /// The content-preservation demand shared by both prompt shapes. Deliberately about
    /// elements, counts, layout and text rather than a character — a pay table, a
    /// background and a UI panel all have to survive this, not just a creature.
    private static let preserveClause = """
        Keep every part of the content exactly as it is: each element, its position, size \
        and count, the overall layout, and all text and numbers character-for-character. Do \
        not add, remove, merge, crop, rearrange or reinterpret anything, and do not collapse \
        a multi-element layout into a single subject.
        """

    /// The counterpart to preserveClause for the two modes that send NO source image.
    /// There is no existing image to protect, so this demands completeness of the
    /// DESCRIPTION instead of fidelity to a source — but it keeps preserveClause's
    /// hard-won lessons, because they apply just as much when drawing a pay table
    /// from a description as when redrawing one: account for every element, don't
    /// invent extras, and get the text exactly right.
    private static let createClause = """
        Create a NEW image from the description below. Draw every element it names, in the \
        arrangement it describes, and reproduce all text and numbers character-for-character. \
        Do not add elements it does not mention, and do not collapse a multi-element layout \
        into a single subject.
        """

    /// Text-to-image: no source image and no reference image. The content description
    /// IS the subject here, not a set of anchors protecting an existing image, so the
    /// wording flips from "preserve" to "create" — telling a model to "keep every part
    /// exactly as it is" when it has no image to look at invites it to invent one and
    /// call that faithful.
    ///
    /// Contents first, style last, mirroring restylePrompt for the same measured
    /// reason: leading with the style change let the subject drift on live runs.
    static func generatePrompt(contents: String, styleText: String, extra: String = "") -> String {
        let c = anchorClause(contents, fallback: "the subject described by the art style notes below.")
        let style = styleText.trimmingCharacters(in: .whitespacesAndNewlines)
        var p = """
            \(createClause)

            CONTENTS TO CREATE: \(c)

            Render it in the following art style:

            ART STYLE: \(style)
            """
        let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { p += "\n\nADDITIONAL STYLE NOTES: \(e)" }
        return p
    }

    /// One image is attached and it is the STYLE reference — no source image. The role
    /// label carries even more weight than in restylePromptTwoImage: with nothing to
    /// redraw, an unlabelled reference is simply "the image", and the model returns its
    /// subject straight back. Same failure the two-image prompt already had to defend
    /// against, minus the source image that used to compete for the model's attention.
    static func generatePromptStyleImage(contents: String, extra: String = "") -> String {
        let c = anchorClause(contents, fallback: "the subject described by the style notes below.")
        var p = """
            \(createClause)

            CONTENTS TO CREATE: \(c)

            The attached image is a STYLE reference ONLY. Do not copy its subject, objects, \
            layout or text — none of its content may appear in the output. Take from it only \
            the rendering technique, colour palette, linework and lighting.
            """
        let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { p += "\n\nADDITIONAL STYLE NOTES: \(e)" }
        return p
    }

    /// The single place that turns "which images are we sending?" into a prompt, so the
    /// UI, the metadata and the prompt can never disagree about the mode.
    ///
    /// The styleText/extra split is NOT uniform across modes, and that asymmetry is
    /// deliberate and pre-existing: when an IMAGE carries the style, typed style text is
    /// demoted to supplementary notes, because a full style paragraph competing with a
    /// style reference wins and defeats the point of attaching the reference at all.
    /// When no image carries the style, that same text IS the style.
    static func prompt(mode: RestyleInputMode, contents: String,
                       styleText: String, extra: String = "") -> String {
        let folded = [styleText, extra].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: ". ")
        switch mode {
        case .editWithStyleImage:   return restylePromptTwoImage(identityAnchors: contents, extra: folded)
        case .editWithStyleText:    return restylePrompt(identityAnchors: contents, styleText: styleText, extra: extra)
        case .createWithStyleImage: return generatePromptStyleImage(contents: contents, extra: folded)
        case .createWithStyleText:  return generatePrompt(contents: contents, styleText: styleText, extra: extra)
        }
    }

    /// Style words that should NOT appear in a CONTENTS description. The contents field
    /// says what must survive; naming colour or texture there fights the new style
    /// instead of protecting the layout. Shown as a caution, not a block — the artist
    /// may have a reason.
    ///
    /// Started as a dozen buzzwords curated from one earlier failure (a neon slot
    /// symbol description) and that was too narrow: tested on a real vision-model
    /// output, it missed "dark reddish-brown wooden plank" entirely, and an A/B
    /// restyle proved that leak was not cosmetic — the version WITH "dark
    /// reddish-brown" in the contents came back with a visibly darker, redder panel
    /// than the version with it removed, on an otherwise identical prompt. Broadened
    /// to plain colour names, since those are what actually constrain a recolor, not
    /// just the buzzwords one bad example happened to use.
    static let styleWordsInContent = ["neon", "glowing", "glow", "glitchy", "pixelated",
                                      "aesthetic", "aesthetics", "palette", "gradient",
                                      "shading", "textured", "retro", "vibrant", "hued",
                                      "colour", "color", "shade", "tone", "hue",
                                      "red", "reddish", "orange", "yellow", "green",
                                      "blue", "cyan", "magenta", "purple", "violet",
                                      "pink", "brown", "black", "white", "grey", "gray",
                                      "gold", "golden", "silver", "bronze", "copper",
                                      "dark", "light", "bright", "pale", "deep", "muted",
                                      "pastel", "warm-toned", "cool-toned"]

    /// Style words found in a contents description, OUTSIDE quoted text.
    ///
    /// A contents description legitimately quotes on-image text verbatim — "VOLCANO
    /// GOLD" as a wordmark — and that quoted colour word is required transcription,
    /// not a style leak; scanning it anyway flagged a clean, fully-compliant
    /// description as if it had a problem. Quoted spans are blanked out before the
    /// scan so only the surrounding prose (which is where a real leak lives) counts.
    static func styleLeaksInContents(_ text: String) -> [String] {
        var scan = text
        for quote in ["\"", "\u{201C}\u{201D}"] {
            let opens = quote == "\"" ? "\"" : "\u{201C}"
            let closes = quote == "\"" ? "\"" : "\u{201D}"
            while let start = scan.range(of: opens),
                  let end = scan.range(of: closes, range: start.upperBound..<scan.endIndex) {
                scan.replaceSubrange(start.lowerBound..<end.upperBound,
                                     with: String(repeating: " ", count: scan.distance(from: start.lowerBound, to: end.upperBound)))
            }
        }
        let lower = scan.lowercased()
        return styleWordsInContent.filter { w in
            guard let r = lower.range(of: w) else { return false }
            let before = r.lowerBound == lower.startIndex ? " "
                : String(lower[lower.index(before: r.lowerBound)])
            let after = r.upperBound == lower.endIndex ? " " : String(lower[r.upperBound])
            return !before.first!.isLetter && !after.first!.isLetter
        }
    }

    /// Words that mean a typed style description drifted into describing a subject
    /// rather than a style. Shown as a warning rather than a block — an art style
    /// legitimately called "painterly fur texture" might be intended, and it's the
    /// artist's call, not ours.
    static let leakWords = ["fur", "hair", "scales", "feathers", "skin", "leather",
                            "fabric", "armour", "armor", "face", "eyes", "mane", "fins"]

    /// Subject words that leaked into supposedly style-only text.
    static func styleLeaks(in text: String) -> [String] {
        let lower = text.lowercased()
        return leakWords.filter { w in
            guard let r = lower.range(of: w) else { return false }
            // Whole words only, so "skin" doesn't fire on "skinny" nor "face" on "surface".
            let before = r.lowerBound == lower.startIndex ? " "
                : String(lower[lower.index(before: r.lowerBound)])
            let after = r.upperBound == lower.endIndex ? " " : String(lower[r.upperBound])
            return !before.first!.isLetter && !after.first!.isLetter
        }
    }
}

extension RestyleRules {
    /// True when the source's shape is far enough from every ratio the model accepts
    /// that sending it as-is would get it reframed. 2% covers rounding in real exports
    /// (1920x1081 is 16:9 for our purposes) without waving through a genuinely odd crop.
    static func needsPadding(width: Int, height: Int, tolerance: Double = 0.02) -> Bool {
        guard width > 0, height > 0 else { return false }
        let actual = Double(width) / Double(height)
        let nearest = ratio(nearestAspect(width: width, height: height))
        return abs(actual - nearest) / nearest > tolerance
    }
}

extension RestyleRules {
    /// Default output resolution. 2K, not 1K: measured 2026-07-30, NB2 with
    /// `image_size: "2K"` really does return 2K pixels (2528x1684 from a 1024px
    /// source, 1680 image tokens, $0.1014) — the AI hub runbook's old "flash caps
    /// ~1K" note was wrong and has been corrected. Art going into a game wants the
    /// larger render, and the price difference is a few cents.
    static let defaultSize = "2K"

    /// Default backing colour for transparent art. Magenta, not white: it's the
    /// least likely colour to appear in real artwork, so anything the model leaves
    /// behind from the padding is unmistakable rather than blending into pale
    /// linework — and it matches the greenscreen/magenta convention already in
    /// Prep for AI's colour list.
    static let defaultPadColorName = "MagentaScreen"

    /// True when a Vertex error is worth retrying rather than failing the item.
    ///
    /// Vertex returns transient 503 UNAVAILABLE under load — seen repeatedly while
    /// testing. On a one-off restyle that's a visible annoyance; in a batch of
    /// twenty it would abandon the rest of the queue for a condition that clears in
    /// seconds, so these are retried and everything else fails fast.
    static func isTransient(_ error: String) -> Bool {
        let e = error.lowercased()
        return e.contains("503") || e.contains("unavailable")
            || e.contains("429") || e.contains("resource_exhausted")
            || e.contains("timed out") || e.contains("timeout")
            || e.contains("network connection was lost")
    }
}

// MARK: - Undo / redo of file operations

/// One half of an undoable operation. Returns nil on success, or a message naming
/// what went wrong.
///
/// It reports rather than just running because the filesystem changes underneath
/// recorded operations all the time — the user bins the file in Finder, a share
/// drops, a folder gets renamed. The old `try?`-and-shrug closures turned that into
/// a silent no-op, which reads as "Undo is broken"; the returned message is what
/// the user actually gets shown.
typealias UndoAction = () -> String?

/// Undo/redo stack for file operations.
///
/// Both halves are supplied at push time rather than having `undo()` hand back its
/// own inverse. Several operations land somewhere different every time they re-run
/// — re-trashing an item gets a fresh, de-duplicated path inside the Trash — so the
/// two halves must share mutable state. Capturing one local `var` in both closures
/// does that in a line; threading an inverse back out through every early return of
/// fifteen call sites does not.
final class UndoStack {
    static let shared = UndoStack()
    /// `cleanup` runs when an entry can never be replayed again. Rename-with-Replace keeps
    /// the displaced file in a hidden stash so Undo can put it back; without this hook that
    /// stash would sit in the folder forever once the entry fell off the stack, and a user
    /// who renames over a hundred files would accumulate a hundred hidden leftovers.
    struct Entry {
        let desc: String; let undo: UndoAction; let redo: UndoAction
        var cleanup: (() -> Void)? = nil
    }

    /// One place that retires entries, so a new death point cannot forget to run cleanup.
    private func retire(_ entries: [Entry]) {
        for e in entries {
            if let cleanup = e.cleanup { execute({ cleanup(); return nil }, { _ in }) }
        }
    }

    /// 200, not the old 50: an entry is two closures over a handful of URLs, a few
    /// hundred bytes, so history is essentially free and the old cap threw away a
    /// morning's work to save nothing. The drop stays silent — an alert about a
    /// ceiling nobody reaches is pure nagging.
    static let limit = 200

    private(set) var undoStack: [Entry] = []
    private(set) var redoStack: [Entry] = []

    /// Injected by the app. This type is compiled into the test bundle, which has no
    /// business beeping or opening alerts, so the two user-visible outcomes are hooks
    /// rather than direct AppKit calls.
    var onEmpty: () -> Void = {}
    var onFailure: (_ summary: String, _ detail: String) -> Void = { _, _ in }

    // The app executes file actions on a worker and completes on main. Tests keep
    // synchronous execution; stack ownership never moves onto the I/O thread.
    var execute: (@escaping UndoAction, @escaping (String?) -> Void) -> Void = { action, done in done(action()) }
    private(set) var isPerforming = false
    private var revision = 0
    var canUndo: Bool { !isPerforming && !undoStack.isEmpty }
    var canRedo: Bool { !isPerforming && !redoStack.isEmpty }
    var topDescription: String? { undoStack.last?.desc }
    var topRedoDescription: String? { redoStack.last?.desc }

    func push(_ desc: String, undo: @escaping UndoAction, redo: @escaping UndoAction,
              cleanup: (() -> Void)? = nil) {
        revision += 1
        undoStack.append(Entry(desc: desc, undo: undo, redo: redo, cleanup: cleanup))
        if undoStack.count > Self.limit { retire([undoStack.removeFirst()]) }
        // Any NEW operation invalidates every pending redo. Those closures hold paths
        // the new operation may have just renamed, moved or binned, so replaying one
        // would act on files the user never asked about — the classic corruption bug
        // in hand-rolled undo.
        retire(redoStack); redoStack.removeAll()
    }

    func undo() { replay(redo: false) }
    func redo() { replay(redo: true) }

    private func replay(redo: Bool) {
        guard !isPerforming else { return }
        guard let entry = redo ? redoStack.popLast() : undoStack.popLast() else { onEmpty(); return }
        isPerforming = true
        let started = revision
        execute(redo ? entry.redo : entry.undo) { [self] problem in
            isPerforming = false
            if let problem {
                retire([entry])
                onFailure("Couldn’t \(redo ? "redo" : "undo") \(entry.desc)", problem)
                return
            }
            // A new operation while I/O was pending invalidates this old replay path.
            // Re-inserting it would offer Redo against files the new operation changed.
            guard revision == started else { retire([entry]); return }
            if redo {
                undoStack.append(entry)
                if undoStack.count > Self.limit { retire([undoStack.removeFirst()]) }
            } else {
                redoStack.append(entry)
                if redoStack.count > Self.limit { retire([redoStack.removeFirst()]) }
            }
        }
    }

    /// Only for tests and for a fresh app state — the app never discards history.
    func clear() { revision += 1; undoStack.removeAll(); redoStack.removeAll() }
}

/// Sequence a batch of moves so none of them lands on a path another move in the same
/// batch has not vacated yet.
///
/// The bug this fixes: Batch Rename records its undo pairs in the order it renamed, and
/// undo replayed them in exactly that order. Rename B→C and then A→B — a chain, and the
/// order the listing hands the pairs over whenever B sorts ahead of A — records undo as
/// C→B, B→A, and replaying that moves C onto the B that A is still sitting on. moveItem
/// fails, so Undo reported an error and left the batch half restored.
///
/// Emitting only the moves whose destination nothing else still holds is the whole fix
/// for a chain, and it leaves a batch with no interdependencies in its original order —
/// which is every other caller of restoreItems. A true CYCLE (A→B, B→A) has no such move
/// at all, so one member is parked under a name nobody wants and finished last.
/// `applyRenames`' own `fileExists` guard means a cycle cannot currently reach here — it
/// skips any rename whose destination already exists, so a swap renames nothing — but
/// undo is the path that moves the user's files back, and "the caller filters that out
/// today" is exactly the guarantee that stops being true without anyone noticing.
///
/// `tempSuffix` is a parameter only so a test can pin it; nothing in the app passes it.
func collisionSafeOrder(_ pairs: [(from: URL, to: URL)],
                        tempSuffix: @autoclosure () -> String = UUID().uuidString) -> [(from: URL, to: URL)] {
    var remaining = pairs
    var out: [(from: URL, to: URL)] = []
    while !remaining.isEmpty {
        let occupied = Set(remaining.map { $0.from.path })
        var ready: [(from: URL, to: URL)] = []
        var blocked: [(from: URL, to: URL)] = []
        for p in remaining { occupied.contains(p.to.path) ? blocked.append(p) : ready.append(p) }
        if ready.isEmpty {
            // Every move left wants a path another one still holds: park the first out of
            // the way, which frees its own path and unblocks whoever was waiting on it.
            var p = blocked.removeFirst()
            let parked = p.from.appendingPathExtension(tempSuffix())
            out.append((from: p.from, to: parked))
            p.from = parked
            blocked.append(p)
        } else {
            out += ready
        }
        remaining = blocked
    }
    return out
}

// Stage before both Rename and Redo: failure must leave the displaced item recoverable.
// The returned backup is retained for Undo, so a successful rename does not destroy it either.
func renameItem(_ source: URL, to destination: URL, replacing: Bool) throws -> URL? {
    let fm = FileManager.default
    var stash: URL?
    if replacing {
        // A legal 255-byte filename must not make its backup name exceed the volume's limit.
        let backup = destination.deletingLastPathComponent().appendingPathComponent(".navigator-replacing-\(UUID().uuidString)")
        try fm.moveItem(at: destination, to: backup)
        stash = backup
    }
    do { try fm.moveItem(at: source, to: destination) }
    catch {
        if let stash {
            // An occupied destination may be another process's file; never delete it to roll back.
            do { try fm.moveItem(at: stash, to: destination) }
            catch let rollbackError {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSLocalizedDescriptionKey: "\(error.localizedDescription); could not restore the original; it is in this folder as “\(stash.lastPathComponent)”: \(rollbackError.localizedDescription)"])
            }
        }
        throw error
    }
    return stash
}

/// Moves each `from` back to its `to`, collecting what failed into one message.
///
/// Every undo/redo closure funnels through this so an item the user deleted or moved
/// in Finder after the operation names itself in a single alert, instead of being
/// swallowed by `try?` and looking like Undo did nothing. That single funnel is also
/// why the collision ordering lives here rather than in Batch Rename: any caller whose
/// pairs overlap gets it without having to know it exists.
func restoreItems(_ pairs: [(from: URL, to: URL)]) -> String? {
    restoreItemsWithResults(pairs).problem
}

// Put Back must retain origins for failed moves and must not undo a move that never
// happened. Keep the successful pairs alongside the same error report other callers use.
func restoreItemsWithResults(_ pairs: [(from: URL, to: URL)]) -> (moved: [(from: URL, to: URL)], problem: String?) {
    var moved: [(from: URL, to: URL)] = []
    var failed: [String] = []
    for p in collisionSafeOrder(pairs) {
        do { try FileManager.default.moveItem(at: p.from, to: p.to); moved.append(p) }
        catch { failed.append("• \(p.to.lastPathComponent): \(error.localizedDescription)") }
    }
    return (moved, failed.isEmpty ? nil : failed.prefix(5).joined(separator: "\n"))
}

/// Bins each URL and hands back where each one landed, so the matching half can
/// restore exactly these items.
///
/// Restoring from the Trash, rather than re-running the original operation, is what
/// makes redo safe for anything that CREATES items: re-running would rebuild an
/// empty "New Folder" and throw away whatever the user had dropped into it, or
/// re-zip contents that have since changed.
func trashItems(_ urls: [URL]) -> (restores: [(from: URL, to: URL)], problem: String?) {
    let result = trashItemsWithFailures(urls)
    let failed = result.failures.map { "• \($0.url.lastPathComponent): \($0.reason)" }
    return (result.restores, failed.isEmpty ? nil : failed.prefix(5).joined(separator: "\n"))
}

func trashItemsWithFailures(_ urls: [URL]) -> (restores: [(from: URL, to: URL)], failures: [(url: URL, reason: String)]) {
    var restores: [(from: URL, to: URL)] = []
    var failures: [(url: URL, reason: String)] = []
    for u in urls {
        var out: NSURL?
        do {
            try FileManager.default.trashItem(at: u, resultingItemURL: &out)
            if let t = out as URL? { restores.append((from: t, to: u)) }
        } catch { failures.append((u, error.localizedDescription)) }
    }
    // Record every entry point, so viewer deletes and Browser deletes both support Put Back.
    TrashOrigins.record(restores)
    return (restores, failures)
}

// MARK: - Clipboard text forms for a selection

/// The text forms the "Copy …" context-menu items put on the clipboard.
///
/// These live here — and are tested — because every one of them is a quoting rule,
/// and quoting is exactly what goes wrong invisibly: a path holding a space, a
/// double quote or a `]` looks correct in the menu and then breaks whatever it was
/// pasted into. Multi-selection joins with newlines to match the existing
/// `Copy Path`, so the plain and the quoted item differ ONLY in the quoting.
enum PathText {

    /// Windows' "Copy as path": the path quoted so pasting it into a shell survives spaces.
    ///
    /// SINGLE quotes, not double. The previous version wrapped in double quotes and escaped
    /// only backslash and double quote, on the stated belief that those are the only two
    /// characters a POSIX filename may contain that a double-quoted shell word interprets.
    /// That is wrong: `$` and a backtick are both legal in a macOS filename and both still
    /// active inside double quotes. A file genuinely named `report $(id).png` pasted into a
    /// shell therefore RAN the substitution. Inside single quotes nothing is interpreted at
    /// all, which is the only wrapping that is safe for arbitrary filenames.
    ///
    /// A literal single quote cannot appear inside single quotes, so it is closed, escaped
    /// and reopened — the standard `'\''` dance, exactly what shlex.quote emits.
    static func quoted(_ paths: [String]) -> String {
        paths.map { p in
            "'" + p.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: "\n")
    }

    /// `file://` URLs. Percent-encoded by URL itself, which is what a browser or a
    /// Markdown link needs — a raw path with a space in it is not a usable URL.
    static func fileURLs(_ paths: [String]) -> String {
        paths.map { URL(fileURLWithPath: $0).absoluteString }.joined(separator: "\n")
    }

    /// Base names with the extension dropped: "shot.png" → "shot".
    ///
    /// A dotfile (".gitignore") is deliberately returned whole: its dot starts the
    /// name rather than an extension, and treating it as one would copy an empty
    /// string. A name with no dot at all is likewise returned unchanged.
    static func namesWithoutExtension(_ names: [String]) -> String {
        names.map { n -> String in
            guard let dot = n.lastIndex(of: "."), dot != n.startIndex else { return n }
            return String(n[n.startIndex..<dot])
        }.joined(separator: "\n")
    }

    /// `[name](file:///…)`, pasteable into Markdown.
    ///
    /// BOTH brackets are escaped, not just the closing one. CommonMark accepts raw
    /// brackets in link text only as a matched pair, so a filename like "shot [1].png"
    /// with only its `]` escaped leaves an unmatched `[` and the whole link stops
    /// parsing — it pastes as visible junk instead of a link.
    static func markdownLinks(_ items: [(name: String, path: String)]) -> String {
        items.map { i in
            let label = i.name.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "[", with: "\\[")
                              .replacingOccurrences(of: "]", with: "\\]")
            return "[\(label)](\(URL(fileURLWithPath: i.path).absoluteString))"
        }.joined(separator: "\n")
    }
}

// MARK: - Tab context-menu enablement

/// Which items a tab's right-click menu may offer, as plain index arithmetic.
///
/// Kept here so "would this actually do anything?" is decided once and pinned by
/// tests: an off-by-one shows up as a menu item that looks enabled and then does
/// nothing at all, which reads as a broken app rather than a disabled command.
enum TabMenuRules {
    static func canCloseOthers(index: Int, count: Int) -> Bool {
        count > 1 && (0..<count).contains(index)
    }
    static func canCloseToRight(index: Int, count: Int) -> Bool {
        index >= 0 && index < count - 1
    }
    /// Moving the ONLY tab out would leave an empty window behind, so it's refused
    /// rather than silently producing one.
    static func canMoveToNewWindow(index: Int, count: Int) -> Bool {
        count > 1 && (0..<count).contains(index)
    }
}

/// What ⌘W / File ▸ Close Tab should actually do.
enum CloseTabOutcome: Equatable {
    /// Something that isn't a browser window (Settings, Get Info, a viewer) holds key and
    /// owns ⌘W — closing a tab behind it would take a tab the user can still see.
    case closeKeyWindow
    case closeTab
    /// Last tab: closing it would leave an empty window, so close the window instead.
    case closeBrowserWindow
}

/// Extracted and tested because the inline version had a silent-no-op hole: it gated on
/// `NSApp.keyWindow is NavWindow`, so when there was NO key window at all (the app can be
/// frontmost with none — dismissing an alert or a non-activating panel leaves it that way)
/// the guard failed and the fallback ran `nil?.performClose(nil)`. ⌘W and File ▸ Close Tab
/// did nothing whatsoever, silently, while both stayed enabled.
///
/// `hasKeyWindow == false` must therefore still act on the front browser window, which is
/// what the caller's `lastKeyNavWindow` fallback resolves.
enum CloseTabRules {
    static func outcome(hasKeyWindow: Bool, keyWindowIsBrowser: Bool, tabCount: Int) -> CloseTabOutcome {
        if hasKeyWindow && !keyWindowIsBrowser { return .closeKeyWindow }
        return tabCount > 1 ? .closeTab : .closeBrowserWindow
    }
}

/// Turns an Adobe script failure into something worth showing a person.
///
/// The raw strings are internal: `ERROR: [open]` is the .jsx's own step marker, and
/// "the open options are incorrect" is Photoshop's way of saying a file isn't really a PSD.
/// Shown verbatim in a summary dialog it reads as a Navigator malfunction rather than
/// "this one file is broken", which is the opposite of the truth.
enum AdobeErrorText {
    /// Ordered: the first match wins, so specific phrases must precede generic ones.
    private static let plain: [(needle: String, text: String)] = [
        ("open options are incorrect",
         "not a readable Photoshop file — it may be damaged, or another format renamed .psd"),
        ("cannot open the file",
         "Photoshop couldn’t open this file — it may be damaged or still copying"),
        ("could not be found",       "the file wasn’t there when Photoshop looked for it"),
        ("is not a valid",           "not a valid Photoshop document"),
        ("damaged",                  "the file appears to be damaged"),
        ("unsupported",              "Photoshop doesn’t support this file type"),
        ("is not currently available",
         "Photoshop was busy and never answered — try again in a moment"),
        ("timed out",                "Photoshop took too long to respond"),
        ("disk",                     "Photoshop ran out of scratch disk space"),
    ]

    /// `"stub.psd: ERROR: [open] Cannot open the file because…"`
    ///   → `"stub.psd: not a readable Photoshop file — it may be damaged, or another…"`
    /// An unrecognised message keeps its text, just without the internal step marker — never
    /// swallowed, because an unexplained failure still has to be reportable.
    static func friendly(_ line: String) -> String {
        // Split "<file>: <message>" so the filename survives untouched.
        let head: String, body: String
        if let r = line.range(of: ": ") {
            head = String(line[line.startIndex..<r.lowerBound]) + ": "
            body = String(line[r.upperBound...])
        } else {
            head = ""; body = line
        }
        let lower = body.lowercased()
        if let hit = plain.first(where: { lower.contains($0.needle) }) { return head + hit.text }
        // Strip "ERROR: " and any "[step]" marker from anything we don't have wording for.
        var rest = body
        if let r = rest.range(of: "ERROR: ") { rest.removeSubrange(r) }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            rest = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return head + rest
    }
}

// MARK: - When an Adobe app is actually wedged (vs. just handed a bad file)

/// Decides whether repeated Photoshop/After Effects failures mean the APP is wedged — the
/// only condition a restart can fix.
///
/// The old rule was purely "two attempts failed, restart the app", which never asked why.
/// Feeding it one corrupt .psd made it quit and relaunch Photoshop: the file was invalid, the
/// app was perfectly healthy, and a restart could not possibly help. That matters beyond
/// being useless — the restart escalates to `forceTerminate()` when a polite quit is blocked,
/// and what blocks a polite quit is precisely an unsaved-changes dialog. So the old rule could
/// destroy someone's unsaved work because one file in a batch was corrupt.
enum AdobeRecoveryRules {
    /// Signatures of a genuinely unresponsive app: it briefly cannot service scripting at all.
    private static let wedgeSignatures = [
        "is not currently available",          // 'The command "Get" is not currently available'
        "timed out",
        "connection is invalid",
        "application isn’t running",
        "application isn't running",
        "no document open",
    ]

    /// Signatures of a file the app looked at and refused. Nothing to recover from.
    private static let badFileSignatures = [
        "cannot open the file",
        "open options are incorrect",
        "could not be found",
        "is not a valid",
        "damaged",
        "unsupported",
        "no such file",
    ]

    static func looksWedged(_ message: String) -> Bool {
        let m = message.lowercased()
        // A bad file wins outright: an [open]-step refusal naming the file is never a wedge,
        // even though Photoshop dresses it up in the same "General Photoshop error" wrapper.
        if badFileSignatures.contains(where: { m.contains($0) }) { return false }
        if wedgeSignatures.contains(where: { m.contains($0) }) { return true }
        // Failing at the very first step, repeatedly, with no file-specific reason given, is
        // the shape of an app that cannot answer — treat that as wedged.
        return m.contains("[open]") || m.contains("[activedocument]")
    }
}

// MARK: - Seedream 5.0 Pro Layerize

enum LayerizeCheck: Equatable {
    case ok
    /// Outside the endpoint's limits but fixable by resampling. Never done silently.
    case needsResize(reason: String, to: (w: Int, h: Int))
    case reject(reason: String)

    static func == (a: LayerizeCheck, b: LayerizeCheck) -> Bool {
        switch (a, b) {
        case (.ok, .ok): return true
        case let (.needsResize(r1, t1), .needsResize(r2, t2)): return r1 == r2 && t1 == t2
        case let (.reject(r1), .reject(r2)): return r1 == r2
        default: return false
        }
    }
}

/// Rules for `bytedance/seedream/v5/pro/layerize`, all established by measurement against the
/// live endpoint rather than assumed.
enum LayerizeRules {
    // Documented input limits.
    static let minSide = 512, maxSide = 6000
    static let minPixels = 512 * 512, maxPixels = 6000 * 6000
    static let maxBytes = 30 * 1024 * 1024
    static let minAspect = 1.0 / 16, maxAspect = 16.0
    /// base + up to 16 layers.
    static let maxLayers = 17

    /// Output sizes to try, in order.
    ///
    /// `auto` FIRST, because that is the API's own default and its documented behaviour is exactly
    /// what we want: "auto adapts to the input image while preserving each element's aspect ratio."
    ///
    /// This code used to never send it. It computed an explicit tier from a pixel-count threshold
    /// because an earlier session saw one 422 at `auto` and concluded there was a resolution
    /// "floor" — a mechanism that appears nowhere in fal's schema. We now know refusals are
    /// sometimes TRANSIENT: SF2_Pearl was declined once and then accepted on a byte-identical
    /// request. So that single 422 was most likely transient, and an entire tier system was built
    /// to work around it, which then produced its own refusals and inconsistent output sizes.
    ///
    /// Second attempt is `auto` again — the cheap fix for a transient refusal.
    ///
    /// Third is ONE explicit tier, and only as a last resort. Capped at three attempts because
    /// each one is a paid generation.
    static func sizeLadder(width: Int, height: Int) -> [String] {
        ["auto", "auto", lastResortSize(width: width, height: height)]
    }

    /// The explicit tier to fall back to when `auto` will not play.
    ///
    /// Empirical, and narrow: SF1_Red (632×791) was refused at `auto_1K` and accepted at
    /// `auto_1.5K`, so for a stubborn image asking for MORE output resolution is what worked.
    /// Hence one step above whatever the input would naturally suggest.
    static func lastResortSize(width: Int, height: Int) -> String {
        (width * height >= 1536 * 1536) ? "auto_2K" : "auto_1.5K"
    }

    /// Preflight against fal's DOCUMENTED limits, which are a pixel COUNT, not a per-side one:
    /// "The image must contain between 512x512 and 6000x6000 total pixels, have an aspect ratio
    /// between 1/16 and 16, and be no larger than 30 MB."
    ///
    /// The old version enforced 512 and 6000 as per-SIDE bounds, which is stricter than the API.
    /// A 300×1000 image (300,000 px) or an 8000×4000 one (32 MP) both satisfy the real limits and
    /// were being resampled for no reason — losing quality to a rule fal never stated.
    static func check(width w: Int, height h: Int, bytes: Int) -> LayerizeCheck {
        guard w > 0, h > 0 else { return .reject(reason: "not a readable image") }
        let ar = Double(w) / Double(h)
        guard ar >= minAspect, ar <= maxAspect else {
            return .reject(reason: "aspect ratio \(String(format: "%.2f", ar)):1 is outside the supported 1:16–16:1 range")
        }
        let px = w * h
        if px > maxPixels {
            let s = (Double(maxPixels) / Double(px)).squareRoot()
            let t = (max(1, Int((Double(w) * s).rounded(.down))), max(1, Int((Double(h) * s).rounded(.down))))
            return .needsResize(reason: "\(w)×\(h) is \(String(format: "%.1f", Double(px) / 1e6)) MP, over Layerize's 36 MP total", to: t)
        }
        if px < minPixels {
            let s = (Double(minPixels) / Double(px)).squareRoot()
            let t = (max(1, Int((Double(w) * s).rounded(.up))), max(1, Int((Double(h) * s).rounded(.up))))
            return .needsResize(reason: "\(w)×\(h) is \(String(format: "%.2f", Double(px) / 1e6)) MP, under Layerize's 0.26 MP total", to: t)
        }
        if bytes > maxBytes {
            return .needsResize(reason: "file is \(String(format: "%.1f", Double(bytes) / 1_048_576)) MB, over the 30 MB limit", to: (w, h))
        }
        return .ok
    }

    /// A layer that came back empty or isn't a PNG must never be written or recorded.
    ///
    /// `Data(contentsOf:)` succeeds on a ZERO-BYTE response, so a failed download was being
    /// written as an empty file, counted as saved, and listed in _layers.json — while the
    /// filesystem (Google Drive, in the observed case) quietly discarded it. Two real layers went
    /// missing that way: L01_Outer_black_background and L00_base.
    static func isPlausiblePNG(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 100 && Array(bytes.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    }

    /// VERIFIED 2026-08-12 by keeping the base on a mostly-transparent input (frame.png): fal
    /// returned a 2477x1703 plate that was 100% opaque with a colour standard deviation of 0.53 —
    /// blank white, none of the artwork in it. Discarding it is right, and it is NOT where a missing
    /// element hides. For a mostly-OPAQUE input the base is instead a real inpainted background
    /// (SF4_Blue's came back as the full underwater scene), which is why it is kept there.
    /// Keep fal's base image, or throw it away?
    ///
    /// The base is worth keeping only when fal had a real background to inpaint. For a CUTOUT it has
    /// nothing to work from and invents a backdrop, which arrives as grey and white blocks behind
    /// the art — that is what a user saw on a dragon symbol saved with its background removed.
    ///
    /// The test is the OUTER EDGE, not the overall transparent fraction. Overall cannot separate the
    /// cases: that dragon measured 15.7% transparent and an opaque framed symbol 15.4%, so the cutout
    /// slipped under a 20% bar and its invented base was kept. Measured around the border instead,
    /// cutouts sit at 96-99% and real scenes at 0%, so the bar can go anywhere in that gap.
    /// Two signals, because either one alone has a blind spot.
    ///
    /// The border catches the ordinary cutout. But art that runs to the edge on some sides — a
    /// character cropped at the bottom, a full-bleed panel with a transparent corner — can show an
    /// opaque border while still being a cutout, and would keep an invented base. Overall
    /// transparency catches that: measured, real scenes are at 0.0% and every cutout at 15% or more,
    /// so anything with meaningful transparency anywhere is treated as a cutout.
    ///
    /// Verified against six real assets — border / overall:
    ///     bluebird 0.0/0.0   mockup 0.0/0.0                      -> keep
    ///     dragon 96.7/15.7   frame 96.9/22.9   character 96.0/54.8   framed symbol 98.8/15.4 -> discard
    static func shouldKeepBase(borderTransparentFraction: Double,
                               overallTransparentFraction: Double) -> Bool {
        borderTransparentFraction < 0.50 && overallTransparentFraction < 0.02
    }

    /// The line that must be in EVERY layerize prompt.
    ///
    /// fal returns names and descriptions in Chinese without it, and the layer filenames are built
    /// from those names — an early run produced twelve layers all called "unnamed". It is never
    /// replaced by the user's text, only prepended to it.
    static let basePrompt = "Return name and description in english."

    /// What actually gets sent as `prompt`.
    ///
    /// fal documents this field as "instructions describing which elements to separate", and it is
    /// the only lever over WHAT comes back: with it empty the model separates "the major elements",
    /// which for a single character is three or four blobs. Naming the parts — "Separate guns,
    /// triggers, hands, and arms out from image" — is what produces per-limb layers, including
    /// left/right instances as their own layers.
    ///
    /// A GENERIC completeness instruction was measured and does NOT help: "separate every distinct
    /// structural element, leaving no part unassigned" scored 1.378% uncovered against 1.144% for no
    /// instruction at all. Specific beats generic, so nothing generic is added here — only what the
    /// user actually asked for.
    static func composePrompt(_ userText: String?) -> String {
        guard let raw = userText else { return basePrompt }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return basePrompt }
        // Someone pasting the whole prompt back in shouldn't get the base line twice.
        if t.hasPrefix(basePrompt) { return t }
        return basePrompt + "\n" + t
    }

    /// fal bills this endpoint by COMPUTE SECONDS at $0.00017 — from fal's own pricing API, checked
    /// 2026-08-12. The previous estimate invented a per-layer price and reported roughly 10x too
    /// much; it also chose a tier from `image.width` in the response, and that field is never
    /// present, so it silently fell to the cheap tier on every call anyway.
    ///
    /// Wall-clock is the only timing Navigator can see and it includes queueing, so this can only
    /// ever be an upper bound — display it as approximate, never as a billed figure.
    static let costPerComputeSecond = 0.00017
    static func estimatedCost(seconds: Double) -> Double { max(0, seconds) * costPerComputeSecond }

    /// Filesystem-safe WITHOUT destroying non-ASCII.
    ///
    /// Layerize returns Chinese names unless the prompt asks for English, and an ASCII-only
    /// sanitiser turned every one of them into an empty string — twelve layers all landed as
    /// "unnamed", distinguished only by index. Keep the characters; strip only what a
    /// filesystem genuinely cannot take.
    static func safeName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let illegal = Set("/:\\<>\"|?*")
        var out = String(raw.unicodeScalars.filter { !illegal.contains(Character($0)) && !CharacterSet.controlCharacters.contains($0) })
        out = out.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: "_")
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_. "))
        return String(out.prefix(60))
    }

    /// `<Original>_L03_Left_Dragon_Frame.png`. Index is included because layer NAMES can repeat
    /// and z_index ordering is NOT stable between runs — the same image ordered its layers
    /// differently on two separate calls, so the index alone can't identify a layer either.
    static func fileName(stem: String, zIndex: Int, name: String?) -> String {
        let label = safeName(name)
        let suffix = label.isEmpty ? (zIndex == 0 ? "base" : "layer") : label
        return String(format: "%@_L%02d_%@.png", stem, zIndex, suffix)
    }

    // The per-layer cost model that used to live here was invented — fal bills this endpoint by
    // compute second (see estimatedCost). It reported roughly 10x too much, and picked its tier from
    // `image.width`, a field fal never actually returns, so it always fell to the cheap rate anyway.
}

// MARK: - Columns that are too expensive to show on a network volume

/// Which Details columns are worth their cost on a slow volume.
///
/// Measured on two real SMB shares:
///
/// * **Owner** was the worst by a distance. `FileItem.owner` did a fresh `stat` per read, and
///   the cell reads it on every SwiftUI render pass — 669 rows on //fileserver-a/Games cost
///   ~60 SECONDS per pass, repeatably, because the SMB client never cached it. Memoizing that
///   fixed the repeat cost; not asking for it at all fixes the first pass too.
/// * **Date Created / Last Opened / Added / Tags** need attributes beyond the ones the listing
///   already fetches. On //fileserver-b/data those extras cost ~187 ms per entry on first
///   fetch, even with name/size/date for the same folder already cached.
///
/// Everything left is genuinely free: Name and Ext come straight off the filename, Kind is
/// derived from the extension by `localKind` with no I/O at all, and Size and Date Modified
/// arrive with the directory listing whether asked for or not.
enum NetworkColumnRules {
    static let costlyOnNetwork: Set<String> = ["created", "accessed", "owner", "duration", "dimensions"]

    /// Hidden on network volumes even when enabled globally — the point is that browsing a
    /// share never pays for a column, not that the preference is edited behind the user's back.
    /// Local folders always show exactly what was asked for.
    /// The DEFAULT column set for a network folder nobody has arranged by hand.
    ///
    /// Name, Ext and Kind and nothing else, because these three are the only columns
    /// that cost NOTHING: the name comes from readdir, and Ext and Kind are derived from
    /// it with no I/O at all. Whether a row is a folder comes free too, from readdir's
    /// d_type. So this set renders a complete, correct listing with zero per-file I/O —
    /// measured at 429 ms for artSource's 669 files.
    ///
    /// Size and Date Modified are deliberately NOT here. An earlier version of this
    /// comment claimed they were free because they "ride along in the same stat"; that
    /// was wrong — they ARE the stat, at 89 ms PER ENTRY on //fileserver-a/Games (a DFS
    /// namespace). That is 59 s for artSource, and 10.9 s for a 116-item folder. The cost
    /// is the server's, not the API's: resourceValues, raw lstat, 8/16/32-way concurrent
    /// lstat, and getattrlistbulk (all 669 in a single syscall) all land within
    /// 73-106 ms/entry cold. Concurrency buys nothing — the SMB client serializes them.
    ///
    /// None of them are forbidden. Turn Size on for a share and you get Size, and the
    /// slow load that comes with it, and the choice is remembered for that folder.

    /// Size and Date Modified are back on by default as of the shared index. When Size cost 89 ms
    /// per row and 59 s for a folder, leaving it on was indefensible; with an index the same
    /// folder answers in ~1 s, and rows render blank (not "0 bytes") until their real values
    /// arrive, so nothing is ever wrong on screen and navigation is never held up. The five in
    /// costlyOnNetwork stay off — Owner is a stat per cell render, Duration and Dimensions read
    /// file headers, and no index covers those.
    static let networkDefaults: Set<String> = ["name", "extension", "kind", "size", "modified"]

    /// Columns that cannot be filled without a per-file attribute fetch. On a network
    /// volume each one of these is what turns a 0.4 s listing into a 59 s one.
    /// These are the real column ids from fileColumnDefs. "duration" and "dimensions" are
    /// the worst of them by far: they read the file's HEADER, not just its stat, so on a
    /// share they cost a transfer per row rather than a round trip per row.
    static let attributeColumns: Set<String> =
        ["size", "modified", "created", "accessed", "owner", "duration", "dimensions"]

    /// Sort keys that need the same per-file data, whatever the columns say — sorting by
    /// size with no Size column still has to know every size.
    static let attributeSortKeys: Set<String> = ["size", "modified", "created", "accessed", "added"]

    /// Whether the metadata pass has to run at all. False means the names-only listing IS
    /// the finished answer and the expensive enumerate can be skipped outright.
    static func needsAttributePass(columns: Set<String>, sortKey: String) -> Bool {
        !columns.isDisjoint(with: attributeColumns) || attributeSortKeys.contains(sortKey)
    }

    /// Seed columns for a folder with nothing saved yet.
    static func seed(isNetwork: Bool, localDefaults: Set<String>) -> Set<String> {
        isNetwork ? networkDefaults : localDefaults
    }

    /// Strip the expensive columns (and an expensive sort) out of an arrangement that was
    /// saved for a NETWORK folder. Run once, as a migration: most saved network arrangements
    /// were never a deliberate choice — they got persisted as a side effect of visiting the
    /// folder — and they are what keeps a share on the 89 ms-per-row path. Turning a column
    /// back on afterwards is a deliberate act and is kept.
    static func cleaned(columns: Set<String>) -> Set<String> {
        // costlyOnNetwork, not all of attributeColumns: Size and Date Modified are affordable now
        // that the shared index answers them in bulk, and they are the two people actually want.
        // Owner, Duration and Dimensions are not indexable and stay off.
        let kept = columns.subtracting(costlyOnNetwork)
        // Never hand back something with no name column; that would render an empty table.
        return kept.contains("name") ? kept : kept.union(["name"])
    }

    /// Seed sort for a folder with nothing saved yet. Cheap columns alone are not enough to
    /// get an instant listing: sorting by size or date needs every file's attributes just
    /// as much as showing them does, so an unarranged network folder sorts by name. A
    /// folder sorted by size on purpose keeps it — this only fills in a default.
    static func seedSortKey(isNetwork: Bool, localDefault: String) -> String {
        isNetwork && attributeSortKeys.contains(localDefault) ? "name" : localDefault
    }

    /// Which of the user's columns are being withheld right now, so the UI can say so instead
    /// of leaving someone wondering where their column went.
    /// Which of the requested columns are the expensive ones — for a "this is why the
    /// folder is slow" hint, not for hiding anything.
    static func costly(in requested: Set<String>) -> Set<String> {
        requested.intersection(costlyOnNetwork)
    }
}

// MARK: - Search query parsing and matching

/// Turns what someone typed into something that actually finds files.
///
/// The old behaviour was a single raw substring test, and it meant **multi-word searches
/// returned nothing at all**. Measured against this project's own naming convention:
/// "phoenix v2" matched 0 files, while requiring each word separately matched 17 — including
/// `HP2_Phoenix_Direct_NB2_v2.png`, which is obviously what was wanted. Anyone whose files are
/// named `Thing_Detail_v3.png` could never search for them with a space.
///
/// So: split on whitespace and require EVERY token, in any order, anywhere in the name — which
/// is how Finder and Explorer both behave. A `"quoted phrase"` stays one token for the times
/// you really do want the literal string.
enum SearchQueryRules {
    /// Case- and diacritic-folded, so the two search backends agree. The recursive walk used
    /// plain `lowercased()` while Spotlight used `[cd]`, which meant "café" matched in one
    /// place and not the other.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Splits on whitespace, keeping `"quoted phrases"` intact. Already folded.
    static func tokens(_ raw: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if !inQuotes, ch.isWhitespace {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.map(fold).filter { !$0.isEmpty }
    }

    /// Every token must appear somewhere in the name. Order doesn't matter.
    static func matches(name: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let n = fold(name)
        return tokens.allSatisfy { n.contains($0) }
    }

    /// A single bare token that looks like an extension ("png", ".png", "*.png") should also
    /// match by extension, so `png` finds every PNG even when the name doesn't contain "png".
    /// Only for a lone token — "logo png" already works by name.
    static func extensionQuery(_ tokens: [String]) -> String? {
        guard tokens.count == 1 else { return nil }
        let t = tokens[0].trimmingCharacters(in: CharacterSet(charactersIn: "*."))
        guard !t.isEmpty, t.count <= 5, t.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return t
    }

    /// Does this file match, by name tokens or by an extension-style query?
    static func matchesFile(name: String, ext: String, tokens: [String]) -> Bool {
        if matches(name: name, tokens: tokens) { return true }
        if let e = extensionQuery(tokens) { return fold(ext) == e }
        return false
    }
}

/// Why a result list stopped where it did — so a capped search can say so instead of quietly
/// looking like a complete answer.
enum SearchTruncation: Equatable {
    case complete(Int)
    case capped(shown: Int, cap: Int)
    indirect case incomplete(SearchTruncation, Reason)

    enum Reason: Equatable {
        case indexCoverageUnknown, traversalErrors

        var text: String {
            switch self {
            case .indexCoverageUnknown: return "Spotlight results only — unindexed files may be missing"
            case .traversalErrors: return "incomplete — some locations or file details couldn’t be read"
            }
        }
    }

    var statusText: String {
        switch self {
        case .incomplete(let results, let reason):
            return results.statusText + " — " + reason.text
        case .complete(let n):
            return "\(n) found"
        case .capped(let shown, let cap):
            // Naming the cap matters: "500 items" reads as the truth, and someone then
            // concludes the file they wanted doesn't exist.
            return "first \(shown) of more than \(cap) — narrow the search to see the rest"
        }
    }

    static func of(shown: Int, cap: Int, hitCap: Bool, reason: Reason? = nil) -> SearchTruncation {
        let results: SearchTruncation = hitCap ? .capped(shown: shown, cap: cap) : .complete(shown)
        return reason.map { .incomplete(results, $0) } ?? results
    }
}

// MARK: - Thumbnail cache keys

/// Builds the thumbnail cache key.
///
/// This used to be just `path@size`, which meant a file REWRITTEN AT THE SAME PATH kept its old
/// thumbnail forever — the cache had no way to know the bytes had changed. That is the normal
/// case in this workflow, not an edge case: art gets re-exported over itself constantly, and a
/// dragon whose green cloud background had been removed still showed the cloud in Navigator
/// while opening the file showed it correctly gone. Refresh couldn't fix it either, because
/// refresh only cleared the FAILURE cache.
///
/// Including a content stamp fixes it everywhere at once — scroll, folder re-entry, background
/// change, ⌘R — instead of only where someone remembered to purge.
enum ThumbnailKeyRules {
    /// `mtime`/`bytes` come from a stat. Both are used, not just mtime: a file rewritten inside
    /// the same mtime tick (or on a filesystem with coarse timestamps — network shares and some
    /// cloud providers round to the second) still changes length in almost every real case.
    static func key(path: String, size: Int, mtime: TimeInterval?, bytes: Int64?) -> String {
        guard let m = mtime, let b = bytes else {
            // stat failed. Fall back to the old form rather than inventing a key that can never
            // hit — an unreadable file is about to fail thumbnailing anyway.
            return "\(path)@\(size)"
        }
        return "\(path)@\(size)#\(Int64((m * 1000).rounded())).\(b)"
    }

    /// Everything for one path+size regardless of content stamp — used to cancel in-flight work,
    /// which must not miss just because the file changed while a thumbnail was being generated.
    static func prefix(path: String, size: Int) -> String { "\(path)@\(size)" }
}

// MARK: - Photoshop Generative Upscale (Firefly / Gigapixel / Bloom) preflight

/// What to do with one image before handing it to Generative Upscale.
enum FireflyUpscalePlan: Equatable {
    /// Ready as-is at this scale.
    case upscale(scale: Int)
    /// Aspect is outside 1:4–4:1, so pad the short side first (adaptive backing), upscale,
    /// then crop the padding back off.
    case padThenUpscale(scale: Int, padTo: (w: Int, h: Int))
    /// No scale fits the output cap. `maxSide` is what the long edge would have to be.
    case tooLargeForAnyScale(longEdge: Int, maxInputLongEdge: Int)
    case notAnImage

    static func == (a: FireflyUpscalePlan, b: FireflyUpscalePlan) -> Bool {
        switch (a, b) {
        case let (.upscale(x), .upscale(y)): return x == y
        case let (.padThenUpscale(s1, p1), .padThenUpscale(s2, p2)): return s1 == s2 && p1 == p2
        case let (.tooLargeForAnyScale(l1, m1), .tooLargeForAnyScale(l2, m2)): return l1 == l2 && m1 == m2
        case (.notAnImage, .notAnImage): return true
        default: return false
        }
    }
}

/// Constraints read straight out of Photoshop 2026's own Generative Upscale dialog, which is
/// more authoritative than the docs:
///
///   "Output too large. Width or height exceeds 6144px. Try a smaller scale or reduce the
///    image size."
///   "Aspect ratio not supported. Please crop the image to be tall or wide, between 1:4 and 4:1."
///
/// Both were triggered by a real 2224×355 sheet (6.26:1), which fails aspect at ×2 and fails
/// the size cap at ×4. Note the cap moved between versions — it was 4096 in the 2025 beta —
/// so it is deliberately one constant here.
enum FireflyUpscaleRules {
    static let maxOutputSide = 6144
    static let aspectMin = 0.25          // 1:4
    static let aspectMax = 4.0           // 4:1
    static let scales = [4, 2]           // preferred first

    /// Largest input long edge that still fits the output cap at a given scale.
    static func maxInputLongEdge(scale: Int) -> Int { maxOutputSide / max(scale, 1) }

    static func aspectOK(width w: Int, height h: Int) -> Bool {
        guard w > 0, h > 0 else { return false }
        let r = Double(w) / Double(h)
        return r >= aspectMin && r <= aspectMax
    }

    /// Smallest canvas containing the image whose aspect is inside the allowed band. Only the
    /// SHORT side grows, so the long edge — and therefore which scales fit — never changes.
    static func aspectPadCanvas(width w: Int, height h: Int) -> (w: Int, h: Int) {
        guard w > 0, h > 0 else { return (max(w, 1), max(h, 1)) }
        let r = Double(w) / Double(h)
        if r > aspectMax { return (w, Int((Double(w) / aspectMax).rounded(.up))) }
        if r < aspectMin { return (Int((Double(h) * aspectMin).rounded(.up)), h) }
        return (w, h)
    }

    static func plan(width w: Int, height h: Int, preferred: Int? = nil) -> FireflyUpscalePlan {
        guard w > 0, h > 0 else { return .notAnImage }
        let longEdge = max(w, h)
        let wanted = preferred.map { [$0] } ?? scales
        guard let scale = wanted.first(where: { longEdge * $0 <= maxOutputSide }) else {
            let smallest = scales.min() ?? 2
            return .tooLargeForAnyScale(longEdge: longEdge, maxInputLongEdge: maxInputLongEdge(scale: smallest))
        }
        if aspectOK(width: w, height: h) { return .upscale(scale: scale) }
        return .padThenUpscale(scale: scale, padTo: aspectPadCanvas(width: w, height: h))
    }

    /// Plain-language reason, for the batch preflight dialog and the log.
    static func explain(_ plan: FireflyUpscalePlan, width w: Int, height h: Int) -> String {
        switch plan {
        case .notAnImage:
            return "not a readable image"
        case .upscale(let s):
            return "×\(s) → \(w * s)×\(h * s)"
        case .padThenUpscale(let s, let p):
            let r = Double(w) / Double(max(h, 1))
            return "\(w)×\(h) is \(String(format: "%.2f", r)):1, outside Generative Upscale's 1:4–4:1 range — pad to \(p.w)×\(p.h) first, then ×\(s) → \(p.w * s)×\(p.h * s), then crop the padding off"
        case .tooLargeForAnyScale(let long, let maxIn):
            return "\(w)×\(h) is already too big: even ×2 would exceed the 6144px output cap (long edge \(long) → \(long * 2)). The largest input that fits ×2 is \(maxIn)px on the long edge — split it or reduce it first"
        }
    }
}

// MARK: - Swipe Compare across N images

/// Which image the right-hand side of Swipe Compare is showing.
///
/// Compare used to be strictly two images. Judging a bake-off means holding ONE reference on
/// the left and stepping the right side through every candidate, so the eye compares each one
/// against the same baseline instead of against whichever file happened to be next to it.
enum CompareCycle {
    /// Wraps, so stepping past the end returns to the first candidate rather than dead-ending.
    static func step(index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// Right-hand candidates are every image except the fixed left one. With exactly two
    /// images that degenerates to the old behaviour: one candidate, nothing to cycle.
    static func candidates(total: Int, leftIndex: Int) -> [Int] {
        guard total > 0, leftIndex >= 0, leftIndex < total else { return [] }
        return (0..<total).filter { $0 != leftIndex }
    }

    /// Compare needs a reference plus at least one candidate.
    static func isAvailable(imageCount: Int) -> Bool { imageCount >= 2 }
}

// MARK: - Adaptive backing colour (Prep for AI)

struct RGB8: Equatable, Hashable {
    let r: UInt8, g: UInt8, b: UInt8
    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
}

enum BackingChoice: Equatable {
    /// The image ALREADY sits on a flat field (an LP sheet on magenta). Extend that exact
    /// colour: the pad becomes invisible and the whole canvas stays ONE keyable colour.
    /// Choosing a "maximally distant" colour here would be actively wrong — it would leave
    /// two different colours to key.
    case extendField(RGB8)
    /// A cutout (alpha) or a busy border. Pick the colour furthest from every colour in the
    /// subject, so keying can never eat part of the art.
    case keyColour(RGB8, marginDeltaE: Double)
}

/// Picks the background colour "Prep for AI" fills with.
///
/// The old fixed 7-colour menu could collide with the art: measured on real assets,
/// `HP4_Tortoise.png` contains pure white (ΔE 0.0 from the "White" option) and the frames
/// sheet contains near-black (ΔE 4.6 from "Black"). Filling with a colour the subject also
/// contains means a later chroma key removes part of the subject.
enum KeyColorRules {
    /// A border this uniform means the image is already on a flat field.
    static let flatFieldFraction = 0.90

    static func lab(_ c: RGB8) -> (L: Double, a: Double, b: Double) {
        func lin(_ v: UInt8) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        // sRGB -> XYZ (D65), then XYZ -> L*a*b*
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        let d = 6.0 / 29.0
        func f(_ t: Double) -> Double { t > d * d * d ? cbrt(t) : t / (3 * d * d) + 4.0 / 29.0 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func deltaE(_ a: RGB8, _ b: RGB8) -> Double {
        let l1 = lab(a), l2 = lab(b)
        let dL = l1.L - l2.L, da = l1.a - l2.a, db = l1.b - l2.b
        return (dL * dL + da * da + db * db).squareRoot()
    }

    /// Saturated hues around the wheel plus the classic keys. Saturated colours key far more
    /// reliably than near-neutrals, which is why the score below rewards saturation.
    static let candidates: [RGB8] = {
        var out: [RGB8] = []
        for step in stride(from: 0, to: 360, by: 12) {
            for (s, v) in [(1.0, 1.0), (1.0, 0.75), (1.0, 0.5), (0.85, 1.0)] {
                out.append(hsv(Double(step) / 360, s, v))
            }
        }
        out += [RGB8(0, 255, 0), RGB8(255, 0, 255), RGB8(0, 0, 255),
                RGB8(255, 255, 0), RGB8(255, 255, 255), RGB8(0, 0, 0)]
        return out
    }()

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> RGB8 {
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return RGB8(UInt8((r * 255).rounded()), UInt8((g * 255).rounded()), UInt8((b * 255).rounded()))
    }

    static func saturation(_ c: RGB8) -> Double {
        let r = Double(c.r), g = Double(c.g), b = Double(c.b)
        let mx = max(r, g, b), mn = min(r, g, b)
        return mx == 0 ? 0 : (mx - mn) / mx
    }

    /// `subject` is the colours actually present in the art (transparent pixels excluded —
    /// they are what we're about to fill, so they must not count as "present").
    static func choose(subject: [RGB8], flatField: (colour: RGB8, fraction: Double)?) -> BackingChoice {
        if let f = flatField, f.fraction >= flatFieldFraction { return .extendField(f.colour) }
        guard !subject.isEmpty else { return .keyColour(RGB8(0, 255, 0), marginDeltaE: .infinity) }
        let subjectLab = subject.map(lab)
        var best = candidates[0], bestScore = -Double.infinity, bestMargin = 0.0
        for cand in candidates {
            let cl = lab(cand)
            var margin = Double.infinity
            for s in subjectLab {
                let dL = cl.L - s.L, da = cl.a - s.a, db = cl.b - s.b
                margin = min(margin, (dL * dL + da * da + db * db).squareRoot())
                if margin <= bestMargin - 12 { break }   // can't win even with a full sat bonus
            }
            let score = margin + 12 * saturation(cand)
            if score > bestScore { bestScore = score; best = cand; bestMargin = margin }
        }
        return .keyColour(best, marginDeltaE: bestMargin)
    }
}

/// Draws into RGBA8 at up to `cap` on the long edge and hands back the buffer.
///
/// `interpolationQuality = .none` is REQUIRED, not a performance choice. With smoothing on,
/// the downscale AVERAGES neighbouring pixels: small saturated regions get washed out and
/// blended in-between colours appear that exist nowhere in the art. Both errors push the
/// computed margin UP, which is the dangerous direction — it would let the picker choose a
/// colour that a small element actually contains and key that element away. Caught by
/// cross-checking against a reference implementation: pure green measured ΔE 102 against a
/// sheet that really only stands 80 away from it.
///
/// The cap is 4096 for the same reason: at 2048 a 2224px-wide sheet still lost ~8% of its
/// pixels and over-stated the margin by 3.4 ΔE against ground truth, because the colour that
/// decides it is a one-pixel fringe. At 4096 essentially no real asset is subsampled at all.
/// Worst case is a transient 67 MB buffer on a background thread; `subjectColours` scores it
/// with a flat occupancy grid rather than millions of hash inserts.
func rgbaSample(_ cg: CGImage, cap: Int = 4096) -> (px: [UInt8], w: Int, h: Int)? {
    let scale = max(1.0, Double(max(cg.width, cg.height)) / Double(cap))
    let w = max(1, Int(Double(cg.width) / scale)), h = max(1, Int(Double(cg.height) / scale))
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .none    // see the note above — averaging hides colours
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? (buf, w, h) : nil
}

/// Colours actually present in the art. Transparent pixels are EXCLUDED — they are exactly
/// what we're about to fill, so counting them would make the fill avoid itself.
/// An occupancy grid over the quantised colour cube, not a Set.
///
/// The colour that decides the margin is often a 1–2px anti-aliased FRINGE (measured: the
/// closest colour to pure blue on one real sheet was `rgb(178,15,125)`, residual magenta
/// fringe one pixel wide). Subsampling skips exactly those pixels and over-states the
/// margin, so every pixel has to be looked at — and a flat 80k-entry grid makes that cheap,
/// where millions of Set inserts would not be.
func subjectColours(_ cg: CGImage) -> [RGB8] {
    guard let s = rgbaSample(cg) else { return [] }
    // q = 2 keeps the quantisation error under ~1 ΔE, which matters because the reported
    // margin must not be OPTIMISTIC — an over-stated margin is what would let the picker
    // choose a colour some thin fringe actually contains. Coarser bins (q = 6) over-stated it
    // by 3–5 against ground truth; keeping one arbitrary real colour per coarse bin was worse
    // still, because scan order keeps the bulk colour and throws the fringe away.
    // 129³ bins is a 2 MB flag array — cheaper than the alternative it replaced.
    let q = 2, side = 256 / q + 1
    let n = side * side * side
    var present = [Bool](repeating: false, count: n)
    var i = 0
    while i + 3 < s.px.count {
        let a = Int(s.px[i + 3])
        if a > 16 {
            var r = Int(s.px[i]), g = Int(s.px[i + 1]), b = Int(s.px[i + 2])
            // CG bitmap contexts only do PREMULTIPLIED alpha, so a semi-transparent fringe
            // pixel arrives darkened by its own alpha. Un-premultiply to recover the colour
            // the artwork actually is: that's the hue a key must stay away from, and counting
            // the darkened version instead over-stated one real asset's margin by 3.4 ΔE.
            if a < 255 {
                r = min(255, r * 255 / a); g = min(255, g * 255 / a); b = min(255, b * 255 / a)
            }
            present[(r / q * side + g / q) * side + b / q] = true
        }
        i += 4
    }
    var out: [RGB8] = []
    out.reserveCapacity(4096)
    for k in 0..<n where present[k] {
        let b = k % side, g = (k / side) % side, r = k / (side * side)
        out.append(RGB8(UInt8(min(255, r * q + q / 2)),
                        UInt8(min(255, g * q + q / 2)),
                        UInt8(min(255, b * q + q / 2))))
    }
    return out
}

/// The modal 1px-border colour and what fraction of the border matches it. A high fraction
/// means the image already sits on a flat field, which KeyColorRules extends rather than
/// contrasts against.
func flatFieldColour(_ cg: CGImage, tolerance: Int = 8) -> (colour: RGB8, fraction: Double)? {
    guard let s = rgbaSample(cg), s.w > 2, s.h > 2 else { return nil }
    func at(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = (y * s.w + x) * 4
        return (s.px[i], s.px[i + 1], s.px[i + 2], s.px[i + 3])
    }
    var edge: [(UInt8, UInt8, UInt8)] = []
    for x in 0..<s.w {
        for y in [0, s.h - 1] { let p = at(x, y); if p.3 > 250 { edge.append((p.0, p.1, p.2)) } }
    }
    for y in 0..<s.h {
        for x in [0, s.w - 1] { let p = at(x, y); if p.3 > 250 { edge.append((p.0, p.1, p.2)) } }
    }
    guard !edge.isEmpty else { return nil }
    var counts: [RGB8: Int] = [:]
    for e in edge { counts[RGB8(e.0 / 8 * 8, e.1 / 8 * 8, e.2 / 8 * 8), default: 0] += 1 }
    guard let modal = counts.max(by: { $0.value < $1.value })?.key else { return nil }
    // refine to the mean of the pixels in that bucket, so we extend the true field colour
    var sum = (0, 0, 0), n = 0
    for e in edge where abs(Int(e.0) - Int(modal.r)) <= 8 && abs(Int(e.1) - Int(modal.g)) <= 8 && abs(Int(e.2) - Int(modal.b)) <= 8 {
        sum = (sum.0 + Int(e.0), sum.1 + Int(e.1), sum.2 + Int(e.2)); n += 1
    }
    guard n > 0 else { return nil }
    let mean = RGB8(UInt8(sum.0 / n), UInt8(sum.1 / n), UInt8(sum.2 / n))
    let matching = edge.filter {
        abs(Int($0.0) - Int(mean.r)) <= tolerance && abs(Int($0.1) - Int(mean.g)) <= tolerance
            && abs(Int($0.2) - Int(mean.b)) <= tolerance
    }.count
    return (mean, Double(matching) / Double(edge.count))
}

// MARK: - Aspect-ratio prep for the Gemini image models

/// Measured, not assumed: a 5:1 sheet sent straight to NB2 with `--aspect 21:9` came back
/// with TWO OF FIVE symbols deleted and the survivors distorted 16.7%. The same sheet padded
/// to exactly 21:9 first kept all five to within 0.2% of the original. So anything whose
/// ratio isn't a supported one has to be padded, never sent raw.
enum AspectPrepRules {
    /// Supported width/height ratios for the Gemini image models.
    static let supported: [(name: String, ratio: Double)] = [
        ("21:9", 21.0/9), ("16:9", 16.0/9), ("3:2", 1.5), ("5:4", 1.25), ("4:3", 4.0/3),
        ("1:1", 1), ("4:5", 0.8), ("3:4", 0.75), ("2:3", 2.0/3), ("9:16", 9.0/16), ("9:21", 9.0/21),
    ]

    /// Nearest by log-distance, which is symmetric for ratios (2× too wide and 2× too tall
    /// are equally wrong — plain subtraction would not say that).
    static func nearest(width: Int, height: Int) -> (name: String, ratio: Double) {
        let r = Double(width) / Double(max(height, 1))
        return supported.min { abs(log($0.ratio) - log(r)) < abs(log($1.ratio) - log(r)) }!
    }

    /// The canvas to pad into: the smallest box of the target ratio that CONTAINS the image,
    /// times `pad`. The subject is never scaled or cropped — only centred.
    ///
    /// `pad` 1.0 = pad only as far as the ratio demands (the auto-prep path, where fidelity is
    /// the whole point). 1.2 = the manual "Prep for AI" default, which deliberately leaves the
    /// model breathing room. Scaling BOTH sides preserves the ratio, so padding never undoes
    /// the fit it just computed.
    static func canvas(width w: Int, height h: Int, ratio rt: Double, pad: Double = 1.0) -> (w: Int, h: Int) {
        guard w > 0, h > 0, rt > 0 else { return (max(w, 1), max(h, 1)) }
        let tight: (Double, Double) = Double(w) / Double(h) > rt
            ? (Double(w), Double(w) / rt)
            : (Double(h) * rt, Double(h))
        return (max(1, Int((tight.0 * pad).rounded())), max(1, Int((tight.1 * pad).rounded())))
    }

    /// How far off a supported ratio this image is, as a fraction (0 = already exact).
    /// Padding is nearly free, so the caller pads whenever this is non-zero; at 0 the pad is
    /// 0px and the whole step is a no-op.
    static func mismatch(width w: Int, height h: Int) -> Double {
        guard w > 0, h > 0 else { return 0 }
        let r = Double(w) / Double(h)
        return abs(r / nearest(width: w, height: h).ratio - 1)
    }

    /// Where the subject sits inside the padded canvas, in that canvas's own pixels.
    static func subjectOrigin(width w: Int, height h: Int, canvas c: (w: Int, h: Int)) -> (x: Int, y: Int) {
        ((c.w - w) / 2, (c.h - h) / 2)
    }

    /// The subject's rect inside a RESULT of a different resolution than the padded canvas —
    /// the model returns its own size, so the crop-back has to scale proportionally. Doing it
    /// this way means no resample: we crop, we never stretch.
    static func cropBack(canvas c: (w: Int, h: Int), subject s: (w: Int, h: Int),
                         result r: (w: Int, h: Int)) -> (x: Int, y: Int, w: Int, h: Int) {
        guard c.w > 0, c.h > 0 else { return (0, 0, r.w, r.h) }
        let sx = Double(r.w) / Double(c.w), sy = Double(r.h) / Double(c.h)
        let o = subjectOrigin(width: s.w, height: s.h, canvas: c)
        let x = Int((Double(o.x) * sx).rounded()), y = Int((Double(o.y) * sy).rounded())
        let w = Int((Double(s.w) * sx).rounded()), h = Int((Double(s.h) * sy).rounded())
        return (max(0, x), max(0, y), min(w, r.w - max(0, x)), min(h, r.h - max(0, y)))
    }
}

/// Where every tab ends up after one is dragged onto another (Chrome/Safari reorder).
///
/// Returns the new order as indices INTO THE OLD ARRAY rather than mutating anything,
/// so the caller can carry the selection across by identity instead of by index — a
/// reorder that keeps `selected` pointing at the same slot silently switches which
/// folder you are looking at, which is the bug this shape exists to make impossible.
enum TabMoveRules {
    /// nil when the drag changes nothing (bad index, single tab, dropped on itself) —
    /// the caller then skips the mutation AND the state save entirely.
    static func reordered(count: Int, from: Int, to: Int) -> [Int]? {
        guard count > 1, (0..<count).contains(from), (0..<count).contains(to), from != to else { return nil }
        var order = Array(0..<count)
        order.remove(at: from)
        order.insert(from, at: to)
        return order
    }
}

/// Does releasing a tab drag mean "pull this tab out into its own window"?
///
/// BUG CLASS — a polled watchdog as the PRIMARY mechanism (same class as the one that made
/// drag and drop wedge until relaunch). The tear-off used to be decided and applied by a
/// bare 0.25s mouse-release poll: nothing arbitrated it, so a poll left over from the
/// previous tab drag completed the NEXT one, and it could fire `moveTabToNewWindow` while a
/// drop on a tab was still being delivered. SwiftUI `.onDrag` really does offer no end
/// callback, so a poll still has to be what NOTICES the release — but it may only ACT
/// through a DragSessionLedger ticket, which is what makes a stale one silent. Do not put a
/// bare timer back in front of this.
///
/// Vertical travel only, and generously: a release this far from where the drag started is
/// far outside a ~26pt tab strip, so it cannot also have landed on a tab. Sideways travel,
/// however far, is a reorder — releasing in the 6pt gap between two tabs must leave the
/// strip alone rather than surprising the user with a new window.
enum TabTearOffRules {
    /// ~1.5 tab heights. Big enough that no reorder along the strip trips it.
    static let pullOut: CGFloat = 40

    static func shouldTearOff(verticalTravel: CGFloat, index: Int, tabCount: Int) -> Bool {
        // The SAME rule the context-menu item is enabled by, so the tear-off log line can
        // never claim a move that moveTabToNewWindow is about to refuse. Its refusal to move
        // the ONLY tab out is what keeps this from leaving an empty ghost window behind.
        abs(verticalTravel) > pullOut && TabMenuRules.canMoveToNewWindow(index: index, count: tabCount)
    }
}

// MARK: - Spring-loaded folders

/// When hovering a folder mid-drag is allowed to open it (Finder/Explorer spring-loading).
///
/// The rules are here rather than inline at each of the four drop surfaces because a
/// surface that disagrees with the others is exactly how "it springs in the list but
/// not in the grid" happens — and because two of them are genuinely dangerous to get
/// wrong (see below).
enum SpringRules {
    /// 0.7s. Under ~0.5s an ordinary sweep across a folder on the way to somewhere else
    /// trips it, which is worse than not having the feature: you lose your place while
    /// still holding the drag. Over ~1s and people give up and let go, assuming nothing
    /// is going to happen. Finder sits in the same window; 0.7 is the middle of it.
    static let dwell: TimeInterval = 0.7

    static func canSpring(into folder: URL, from current: URL, dragging sources: [URL]) -> Bool {
        // No file in the payload means this isn't a file drag at all — it's the sidebar's
        // own reorder token, or something from another app we would refuse anyway. Opening
        // folders under a drag we can't accept would just lose the user's place.
        guard !sources.isEmpty else { return false }
        // Already looking at it: springing would be a no-op navigation that still pushes a
        // history entry and re-runs a directory read over what may be a slow SMB mount.
        // Compared as PATHS, never as URLs: "file:///tmp/a/" and "file:///tmp/a" are the
        // same folder but two different URL values, and URL equality is string equality.
        let f = lexicalPath(folder.path)
        if f == lexicalPath(current.path) { return false }
        // Dragging a folder into itself or its own subtree can never be dropped (see
        // PathRules.isSelfOrDescendant), so opening it would strand the user inside the
        // thing they are carrying, with the drag still live and nowhere valid to release.
        return !sources.contains { PathRules.isLexicalSelfOrDescendant(folder, of: $0) }
    }
}

// MARK: - Per-folder view options (⌘J)

/// Everything one folder can remember about how to display itself — the exact set the
/// ⌘J panel shows.
///
/// Deliberately a COMPLETE record rather than six independent optionals. Finder's ⌘J
/// writes the whole arrangement for a folder, and a full record makes "what applies
/// here?" a single `?? defaults` instead of six separate merges, each of which can be
/// half-applied. The half-applied case is the one that bites: a folder remembering only
/// `groupBy` while inheriting a sort key that the global default later changes shows an
/// arrangement the user never chose and can't explain.
///
/// `sortKey` is a Details COLUMN id ("name", "size", "dimensions", …), not the
/// four-case SortField the toolbar Sort menu exposes — a folder sorted by a column the
/// toolbar can't name must still come back sorted that way.
struct ViewOptions: Codable, Equatable {
    var viewMode: String
    var iconSize: Double
    var sortKey: String
    var sortAscending: Bool
    var groupBy: String
    var columns: [String]

    init(viewMode: String, iconSize: Double, sortKey: String, sortAscending: Bool,
         groupBy: String, columns: [String]) {
        self.viewMode = viewMode
        self.iconSize = iconSize
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        self.groupBy = groupBy
        self.columns = columns
    }
}

/// The one key any per-folder record is filed under.
///
/// The bug this exists to end: everything per-folder was keyed on the raw
/// `currentURL.path`, and the same directory has more than one raw path. `/tmp` is a
/// symlink to `/private/tmp`, so the sidebar and the address bar reached one folder
/// under two keys and each kept its own view options — a folder silently forgot the
/// view you had just set on it, depending on how you got there. Same for a trailing
/// slash, for a path carrying `..`, and for the case someone typed.
///
/// NO FILESYSTEM ACCESS. This function must never touch the disk, and that is the whole point of
/// the version you are reading.
///
/// It used to call `realpath(3)`, which resolves every component by asking the filesystem. That is
/// correct and it is also a blocking call, and this key is computed in two places that cannot
/// tolerate blocking: on every folder render, and inside `FolderViewOptionsStore`'s one-time init,
/// which runs under `dispatch_once` on the main thread and normalises EVERY remembered folder path.
/// One remembered folder on a network mount that has stopped answering therefore froze the entire
/// application before it could draw a window — measured, with the main thread parked in
/// `realpath -> __getattrlist` on a wedged SMB path and no window on screen at all.
///
/// The reason realpath was reached for was real: Foundation maps `/private/tmp` back to `/tmp` for
/// the root only, so `/tmp/Photos` and `/private/tmp/Photos` survived
/// `standardizedFileURL.resolvingSymlinksInPath()` as two different strings. But the symlinks that
/// causes it are a FIXED, DOCUMENTED set on macOS — /tmp, /var and /etc are firmlinks into
/// /private — so the same unification is available lexically, for nothing.
///
/// What is given up: a symlink someone made themselves no longer unifies with its target, so a
/// folder reached both ways can hold two view records. That is a view arriving wrong in a rare case,
/// against an app that would not start. Not a close call.
///
/// Lowercased LAST, and deliberately: macOS volumes are case-insensitive by default, so `Photos` and
/// `photos` are one folder and two records for them is the mistake people actually hit. On a
/// case-SENSITIVE volume two genuinely different folders then share one record — a view arriving
/// wrong, never a file touched, which is much the cheaper of the two mistakes.
func folderKey(_ path: String) -> String { lexicalPath(path).lowercased() }

// Preserve case for operational paths: two names can differ only by case on APFS.
func lexicalPath(_ path: String) -> String {
    guard !path.isEmpty else { return "" }
    // Foundation's path APIs are NOT usable here. `resolvingSymlinksInPath()` obviously reads the
    // disk, but `standardizedFileURL` does too - measured: standardizing
    // /Volumes/<wedged>/deep/file.png never returned, and it resolved a symlink to its target on a
    // local path, which it could only do by asking the filesystem. A first attempt at this fix used
    // it and would have left the freeze exactly where it was.
    //
    // So the components are walked as strings and nothing here can block.
    var p = path
    if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }   // reads NSHomeDirectory, not the disk
    let absolute = p.hasPrefix("/")
    var parts: [String] = []
    for comp in p.split(separator: "/", omittingEmptySubsequences: true) {
        switch comp {
        case ".":  continue
        case "..": if !parts.isEmpty && parts.last != ".." { parts.removeLast() } else if !absolute { parts.append("..") }
        default:   parts.append(String(comp))
        }
    }
    var joined = (absolute ? "/" : "") + parts.joined(separator: "/")
    if absolute && joined.isEmpty { joined = "/" }
    // /tmp, /var and /etc are firmlinks into /private on every macOS install. Canonicalising INTO
    // /private matches what realpath produced for folders that existed, so keys already stored for
    // real folders keep matching.
    for root in ["/tmp", "/var", "/etc"] {
        if joined == root || joined.hasPrefix(root + "/") { joined = "/private" + joined; break }
    }
    return joined
}

/// Whether a path may live on a volume that can stop answering — decided from the STRING ALONE.
///
/// Exists because asking the filesystem is the thing being avoided. Browser.icon(for:) used to fall
/// back to `NSWorkspace.icon(forFile:)`, which stats the file, whenever `currentIsNetwork` was false
/// — and that flag is only assigned partway through load(), so at launch it is false for every item.
/// Restoring a folder on a mount that had stopped answering therefore froze the app inside a SwiftUI
/// view body, with the main thread parked in `stat`. Measured: no window ever appeared.
///
/// `isNetworkURL` cannot be used for this. It reads `.volumeIsLocalKey`, which is exactly the kind of
/// call that blocks on the volume in question.
///
/// Everything under /Volumes is treated as possibly-remote. That includes local external drives, so
/// those lose a custom per-file icon and get a type icon instead — a slightly plainer row, against an
/// app that would not open. The boot volume is "/" and is unaffected, which is where most browsing
/// happens.
enum VolumePathRules {
    @Synchronized static var health = VolumeHealthRules()
    static func mayBlockOnIO(_ path: String) -> Bool {
        path == "/Volumes" || path.hasPrefix("/Volumes/")
    }
}

/// SMB attributes cost 90–100 ms per entry when healthy; an unreachable server instead
/// costs a timeout per entry. One transport failure is sufficient evidence, whereas a
/// slow SUCCESS only backs off polling. Time is supplied by the caller, including for
/// a syscall that never returns (the same admission principle as WalkAdmission).
struct VolumeHealthRules {
    enum Operation { case attributes, probe }
    struct Ticket {
        let root: String
        let id: Int
    }
    private struct State {
        var unreachable = false
        var strikes = 0
        var lastFailure = 0
        var quietUntil: TimeInterval = 0
        var pending: [Int: TimeInterval] = [:]
    }
    static let timeout: TimeInterval = 15
    private var volumes: [String: State] = [:]
    private var serial = 0

    static func failure(_ error: NSError) -> MountFailureRules.Cause {
        if error.domain == NSPOSIXErrorDomain { return MountFailureRules.cause(errno: Int32(error.code)) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return failure(underlying) }
        return .other
    }

    /// The stored flag, without the deadline check that can flip it. Exists so a caller can
    /// tell a state it already knew about from one this call just discovered, which is the
    /// difference between logging a transition once and logging it per file.
    func peekUnreachable(root: String?) -> Bool {
        guard let root else { return false }
        return volumes[root]?.unreachable ?? false
    }

    mutating func isUnreachable(root: String?, now: TimeInterval) -> Bool {
        guard let root, var s = volumes[root] else { return false }
        if !s.unreachable, s.pending.values.contains(where: { now - $0 >= Self.timeout }) {
            s.unreachable = true
            s.strikes += 1
            s.quietUntil = now + min(60, 15 * Double(s.strikes))
            volumes[root] = s
        }
        return s.unreachable
    }

    mutating func begin(root: String?, operation: Operation, now: TimeInterval) -> Ticket? {
        // nil means a local volume, determined from the cached mount table, NOT /Volumes.
        guard let root else { return Ticket(root: "", id: 0) }
        let dead = isUnreachable(root: root, now: now)
        var s = volumes[root] ?? State()
        if dead && (operation != .probe || now < s.quietUntil || !s.pending.isEmpty) { return nil }
        if operation == .probe && (now < s.quietUntil || !s.pending.isEmpty) { return nil }
        serial += 1
        s.pending[serial] = now
        volumes[root] = s
        return Ticket(root: root, id: serial)
    }

    // A successful NEW mount replaces the old session. Its abandoned callbacks must
    // not poison the replacement, and EEXIST alone is not evidence of recovery.
    mutating func reconnected(root: String) { volumes[root] = nil }

    mutating func end(_ ticket: Ticket, failure: MountFailureRules.Cause?, now: TimeInterval) {
        guard var s = volumes[ticket.root], let start = s.pending.removeValue(forKey: ticket.id) else { return }
        if failure == .unreachable {
            s.unreachable = true
            s.lastFailure = max(s.lastFailure, ticket.id)
            s.strikes += 1
            s.quietUntil = now + min(60, 15 * Double(s.strikes))
        } else if failure == nil {
            // A late success may clear a deadline-based suspicion. An older concurrent
            // completion cannot erase a newer failure while other calls are still stuck.
            if s.pending.isEmpty && ticket.id > s.lastFailure { s.unreachable = false }
            if s.unreachable {
                volumes[ticket.root] = s
                return
            }
            if now - start > 2 {
                s.strikes += 1
                s.quietUntil = now + min(60, 15 * Double(s.strikes))
            } else {
                s.strikes = 0
                s.quietUntil = 0
            }
        } else {
            // Permissions and missing files say nothing about transport health.
            s.quietUntil = now + 15
        }
        volumes[ticket.root] = s
    }
}

/// What a listing that came back SHORTER than what is on screen actually means.
///
/// A share that has gone does not report an error. Measured on a real VPN drop with the
/// mounts still in the table: opendir on the volume root answered EACCES in 0 ms and an
/// unvisited path answered ENOENT in 0 ms, both instantly. So a folder that is merely
/// unreachable is indistinguishable, at the call site, from a folder someone just emptied —
/// and publishing that reading deletes rows off the screen for a share that is fine.
enum ListingTrustRules {
    /// Is this result safe to put on screen in place of what is already there?
    ///
    /// Growth is always trustworthy: nothing can be lost by accepting it, and a share that
    /// is answering enough to return MORE names is answering. A result that shrank is only
    /// believed when the volume itself still reads — that is the difference between "these
    /// files were deleted" and "this share stopped talking halfway through".
    static func trustShrunken(fresh: Int, onScreen: Int, volumeReadable: Bool) -> Bool {
        fresh >= onScreen || volumeReadable
    }
}

/// Per-folder view options keyed by path, with a hard cap and least-recently-used
/// eviction.
///
/// Why a cap at all: this is ONE UserDefaults blob, not Finder's per-folder .DS_Store.
/// Nothing ever deletes a folder's entry when the folder is deleted or renamed, so
/// without a bound the dictionary only ever grows — and it is decoded in full on every
/// launch.
///
/// The cap was 200 when a folder only got a record by ticking a checkbox. Remembering is
/// automatic now, so a record appears every time anyone changes a view setting anywhere —
/// still not once per folder VISITED (browsing writes nothing), but a far bigger working
/// set than "folders I deliberately arranged". 400 covers a year of that for a heavy
/// user, and at roughly 150 bytes per record it holds the blob near 60 KB: still a
/// sub-millisecond launch decode, still nowhere near a size UserDefaults minds.
///
/// Recency is refreshed on READ (`touch`), not only on write. Evicting by insertion
/// order instead would throw away the folder you open every day in favour of one you
/// customized once and never returned to — which is exactly backwards.
struct ViewOptionsLRU: Codable, Equatable {
    /// Paths, most-recently-used FIRST. Kept in step with `byPath`: every key in one
    /// appears in the other, which is what makes eviction a plain `order.last`.
    private(set) var order: [String] = []
    private(set) var byPath: [String: ViewOptions] = [:]
    static let cap = 400

    init() {}

    var count: Int { byPath.count }
    func contains(_ path: String) -> Bool { byPath[folderKey(path)] != nil }
    func value(for path: String) -> ViewOptions? { byPath[folderKey(path)] }

    /// Save (or replace) one folder's options, making it the most recently used and
    /// evicting the least recently used once past the cap.
    mutating func set(_ options: ViewOptions, for path: String) {
        let path = folderKey(path)
        byPath[path] = options
        order.removeAll { $0 == path }
        order.insert(path, at: 0)
        while order.count > ViewOptionsLRU.cap, let victim = order.popLast() {
            byPath[victim] = nil
        }
    }

    mutating func remove(_ path: String) {
        let path = folderKey(path)
        byPath[path] = nil
        order.removeAll { $0 == path }
    }

    /// Mark a folder as just used. Returns true only when the order actually moved, so
    /// the caller can skip a UserDefaults write on the common case of re-reading the
    /// folder that is already at the front (every refresh of the current folder).
    @discardableResult
    mutating func touch(_ path: String) -> Bool {
        let path = folderKey(path)
        guard byPath[path] != nil, order.first != path else { return false }
        order.removeAll { $0 == path }
        order.insert(path, at: 0)
        return true
    }

    /// Re-file a decoded store whose keys were written before `folderKey` existed.
    ///
    /// Migrating rather than dropping: these records are the user's own arrangements and
    /// there is no way to earn them back except by redoing every one of them by hand.
    /// Two raw keys can collapse onto one normalised key (`/tmp/x` and `/private/tmp/x`),
    /// and the more recently used of the pair wins — rebuilding least-recent-first means
    /// the later `set` both overwrites the value and lifts it to the front, which is the
    /// same answer the LRU would have given had the records never split.
    /// One-time cleanup of arrangements saved for NETWORK folders: drop the columns that cost
    /// a round trip per row, and downgrade a size/date sort to name (which needs the same data).
    /// Most of these arrangements were never chosen deliberately — visiting a folder persists
    /// one — and they are exactly what keeps a share off the fast path. Takes the network test
    /// as a parameter so this stays pure and testable.
    func strippingCostlyNetworkColumns(isNetwork: (String) -> Bool) -> ViewOptionsLRU {
        var out = self
        for (key, o) in byPath where isNetwork(key) {
            let keep = NetworkColumnRules.cleaned(columns: Set(o.columns))
            let sort = NetworkColumnRules.attributeSortKeys.contains(o.sortKey) ? "name" : o.sortKey
            guard keep != Set(o.columns) || sort != o.sortKey else { continue }
            out.byPath[key] = ViewOptions(viewMode: o.viewMode, iconSize: o.iconSize,
                                         sortKey: sort, sortAscending: o.sortAscending,
                                         groupBy: o.groupBy,
                                         columns: o.columns.filter { keep.contains($0) })
        }
        return out
    }

    func migratedToNormalizedKeys() -> ViewOptionsLRU {
        guard order.contains(where: { $0 != folderKey($0) }) else { return self }
        var out = ViewOptionsLRU()
        for path in order.reversed() {
            guard let o = byPath[path] else { continue }   // a blob whose halves disagree
            out.set(o, for: path)
        }
        return out
    }

    /// The options that apply to a folder: its own if it has any, otherwise the global
    /// defaults. The whole point of the feature in one line — and the reason a folder
    /// that was never arranged by hand behaves exactly as it did before any of this
    /// existed.
    func effective(for path: String, defaults: ViewOptions) -> ViewOptions {
        byPath[folderKey(path)] ?? defaults
    }
}

// MARK: - Guessing what a folder is for (Windows-style folder-type detection)

/// Extensions worth seeing as a picture. Here rather than beside `isImageFile` in
/// main.swift so the folder classifier below — which the test bundle compiles, and
/// main.swift cannot be imported into — judges from the SAME list the thumbnailer and
/// the image viewer use, instead of a second copy that quietly drifts from it.
let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "ico"]
let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "3gp", "m2ts", "mts", "m2v", "ts"]

/// What a folder appears to BE, judged only from the names the listing already holds.
///
/// This is Explorer's folder-type detection, and it exists for one reason: a folder full
/// of pictures is useless as a list of names. It runs on every folder load, including on
/// an SMB share over VPN, so it may only look at what enumeration already returned — a
/// name and an isDirectory flag. Never opens a file, never reads an image header, never
/// asks for a thumbnail.
enum FolderKind {
    /// Mostly pictures or video: worth the screen space of big thumbnails.
    case media
    /// Subfolders, documents, code, or a genuine mix — nothing a thumbnail helps with,
    /// so it stays with whatever the user's default view is (Details, out of the box).
    case general

    /// Countable entries needed before this will call a folder anything at all.
    ///
    /// Below this, "mostly images" is one or two files' worth of evidence: a folder
    /// holding a README and two screenshots is not a photo library, and blowing it up to
    /// giant icons on a 2-1 split is exactly the guess that sends people looking for the
    /// off switch. Five is the smallest count where a 60% lean means at least three files
    /// agreeing.
    static let minimumEvidence = 5

    /// Share of countable entries that must be media before the folder is called one.
    ///
    /// A plain majority tips on a single file in an even split, which makes the view mode
    /// jitter as a working folder fills up. 60% needs a real lean. Deliberately not
    /// higher: a photo folder with a few exports, a contact sheet and a notes file in it
    /// is still a photo folder.
    static let mediaShare = 0.6

    static func isMediaName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    /// nil = not enough to go on; leave the folder with the user's default view.
    ///
    /// Two things get discounted before the ratio is taken, both because they describe
    /// the folder's plumbing rather than its purpose:
    ///
    /// • Dotfiles (.DS_Store, .picasa.ini) — invisible in the listing unless Show Hidden
    ///   is on, so they must not be able to swing what the user sees either way.
    /// • Sidecars: a non-media file sharing its base name with a media file right beside
    ///   it (IMG_0431.xmp next to IMG_0431.cr2, clip.mov next to clip.srt). A raw
    ///   workflow writes one per shot, so counting them makes every raw folder exactly
    ///   50/50 and no photo folder ever reaches the threshold — the single most likely
    ///   way for this feature to look broken to the person who most wants it. The same
    ///   rule collapses a RAW+JPEG pair back to one shot for free.
    ///   ponytail: a raw-ONLY folder has no jpg to anchor that rule to and stays general.
    ///   Fix by classifying against thumbnailExtensions instead, if anyone asks.
    static func infer(_ entries: [(name: String, isDirectory: Bool)]) -> FolderKind? {
        let visible = entries.filter { !$0.name.hasPrefix(".") }
        func base(_ name: String) -> String { (name as NSString).deletingPathExtension.lowercased() }
        var mediaBases = Set<String>()
        for e in visible where !e.isDirectory && isMediaName(e.name) { mediaBases.insert(base(e.name)) }

        var media = 0, counted = 0
        for e in visible {
            if !e.isDirectory, isMediaName(e.name) { media += 1; counted += 1; continue }
            // A subfolder always counts — 25 project folders are the whole reason this
            // can't just be "does it contain images".
            if e.isDirectory || !mediaBases.contains(base(e.name)) { counted += 1 }
        }
        guard counted >= minimumEvidence else { return nil }
        return Double(media) >= mediaShare * Double(counted) ? .media : .general
    }
}

// MARK: - Remembering where you were in a folder

/// Your place in one folder: the item that was at the top of the view, plus what was
/// selected. Recorded when you leave a folder and replayed when you come back, so Back
/// returns you to the row you were reading instead of the top of the listing.
struct FolderPlace: Equatable {
    /// The item that was at the top of the viewport when you left.
    ///
    /// An ITEM, deliberately, not a pixel offset. A scroll offset recorded before three
    /// files were deleted (or before the sort order changed, or the icon size did) points
    /// at whatever happens to live at that y now — which is how you come back to a folder
    /// and land somewhere you have never been. The item you were looking at is still the
    /// item you were looking at.
    var anchorID: String?
    /// Where `anchorID` sat in the visible order. Used ONLY when the anchor itself is
    /// gone — deleted, renamed or filtered out while you were away. Coming back to the
    /// same POSITION is the closest thing to "where I was" that survives losing the
    /// anchor, and it is bounded by construction (see restoreAnchor).
    var anchorIndex: Int = 0
    var selection: Set<String> = []

    /// The id to put back at the top of the view, or nil to leave the scroll alone.
    ///
    /// `settled == false` means the listing is still filling in — the network loader
    /// commits partial batches while a slow share enumerates. A missing anchor then means
    /// "not there YET", not "gone", so we decline instead of falling back to the index
    /// and scrolling to a position computed from a tenth of the folder. The caller keeps
    /// the record and asks again on the next batch.
    func restoreAnchor(among ids: [String], settled: Bool) -> String? {
        if let a = anchorID, ids.contains(a) { return a }
        // anchorIndex 0 means you were already at the top: there is nothing to restore,
        // and scrolling to ids[0] would fight a view that is already showing it.
        guard settled, anchorIndex > 0, !ids.isEmpty else { return nil }
        return ids[min(anchorIndex, ids.count - 1)]
    }
}

/// Bounded, most-recently-used-first store of `FolderPlace` by folder path — the same
/// shape, and the same reason, as ViewOptionsLRU: a session that walks a deep tree visits
/// hundreds of folders, and an unbounded dictionary of them only ever grows.
///
/// Deliberately NOT Codable and never persisted, unlike ViewOptionsLRU: where you were
/// scrolled to is worth remembering while you are working, not across a relaunch — and
/// persisting it would mean paying a UserDefaults write on every single navigation.
struct FolderPlaceLRU: Equatable {
    /// Paths, most-recently-used FIRST, kept in step with `byPath` — same invariant as
    /// ViewOptionsLRU, which is what makes eviction a plain `order.last`.
    private(set) var order: [String] = []
    private(set) var byPath: [String: FolderPlace] = [:]
    /// Smaller than ViewOptionsLRU's 200 because nothing here is persisted or
    /// user-visible: it only has to cover the folders you are actually moving between.
    static let cap = 100

    var count: Int { byPath.count }
    func value(for path: String) -> FolderPlace? { byPath[folderKey(path)] }

    /// Record (or replace) one folder's place, making it the most recently used. Recency
    /// needs no separate `touch` here: you cannot return to a folder without having left
    /// one, so every visit ends in a `set`.
    mutating func set(_ place: FolderPlace, for path: String) {
        let path = folderKey(path)
        byPath[path] = place
        order.removeAll { $0 == path }
        order.insert(path, at: 0)
        while order.count > FolderPlaceLRU.cap, let victim = order.popLast() {
            byPath[victim] = nil
        }
    }
}

// MARK: - Sorting the lazily-loaded media columns (Time, Dimensions)

/// Sort key for the two Details columns whose values arrive asynchronously from
/// Spotlight: Time (duration) and Dimensions.
///
/// Two things this has to get right, both of which a bare `Double` key path gets wrong:
///
/// 1. **Missing and not-yet-loaded values must not scatter.** A text file has no
///    duration and a freshly listed video hasn't been asked yet; both come through as
///    nil and both map to 0, so they land together at the low end instead of wherever
///    an uninitialized read happened to put them. This matches what the Size column
///    already does with folders (size 0, so they clump), which is the behaviour this app
///    has always had for "no meaningful number here".
///    ponytail: the low end means unknowns lead when ascending and trail when
///    descending, rather than always trailing the way Finder does. Always-trailing is
///    not expressible as a KeyPathComparator — reversing the order reverses the whole
///    key — so it would mean replacing the comparator type everywhere `sortOrder` is
///    used. Worth doing only if the asymmetry actually annoys someone.
///
/// 2. **Ties must be deterministic.** Swift's sort is not documented as stable, so two
///    files with equal duration (or, far more common, the whole block of 0s) could come
///    back in a different order every time the list re-sorts — which reads as the list
///    shuffling itself for no reason. Folding the name into the key makes every
///    comparison total, so equal values always land in name order.
struct MediaSortKey: Comparable {
    /// Seconds for Time, width × height for Dimensions. 0 when absent or not yet loaded.
    let value: Double
    /// Tie-break, so equal values can never reorder between sorts.
    let name: String

    /// Duration in seconds, 0 when unknown. Negative durations (which some broken
    /// media files report) are clamped, or they would sort below genuinely unknown
    /// files and look like a rendering bug in the Time column.
    static func duration(_ seconds: Double?, name: String) -> MediaSortKey {
        MediaSortKey(value: max(0, seconds ?? 0), name: name)
    }

    /// Total pixel area, 0 when either dimension is unknown or non-positive.
    ///
    /// Area rather than width-then-height because area is the single number people
    /// mean by "bigger image": it ranks a 4000×3000 photo above a 5000×200 banner,
    /// which is the answer someone sorting a folder of images is looking for, whereas
    /// width-first would put the banner on top.
    static func pixelArea(width: Int?, height: Int?, name: String) -> MediaSortKey {
        guard let w = width, let h = height, w > 0, h > 0 else { return MediaSortKey(value: 0, name: name) }
        return MediaSortKey(value: Double(w) * Double(h), name: name)
    }

    static func < (l: MediaSortKey, r: MediaSortKey) -> Bool {
        l.value == r.value
            ? l.name.localizedStandardCompare(r.name) == .orderedAscending
            : l.value < r.value
    }
}

// MARK: - Collapsible group headers

/// Which items a set of collapsed groups leaves visible, and in what order.
///
/// Keeping `NSTableView.sortDescriptors` down to the ONE descriptor the app actually
/// sorts on.
///
/// AppKit does not replace the stack when a header is clicked — it PREPENDS the clicked
/// column's descriptor and keeps every earlier one as a secondary sort, and
/// `autosaveTableColumns` then persists that growing stack across launches (seen live:
/// ["modified:false", "kind:true", "name:true", "size:false"]). Navigator sorts on the
/// first descriptor only, so the leftovers never change the row order — but AppKit reuses
/// a remembered entry's DIRECTION, so clicking a column you last sorted descending brings
/// it back descending instead of starting ascending, which is not what a header click
/// promises. Rewriting down to the single active descriptor is what keeps "click a new
/// column → ascending, click again → descending" true.
enum TableSortRules {
    /// True when the table's stack is anything other than exactly the active sort.
    /// Deliberately also true for a stack whose FIRST entry already matches — that is the
    /// case that leaves stale directions behind for every other column.
    static func needsRewrite(current: [(key: String, ascending: Bool)],
                             desiredKey: String, desiredAscending: Bool) -> Bool {
        guard current.count == 1, let only = current.first else { return true }
        return only.key != desiredKey || only.ascending != desiredAscending
    }
}

/// This is here, tested, and used by BOTH renderers because of one subtle bug it
/// prevents: keyboard navigation (arrows, Tab/⇧Tab, type-to-select) walks the flat
/// visible order, and if that order still contains the items inside a collapsed group
/// then Tab silently selects something the user cannot see — the status bar changes,
/// Return opens a file that isn't on screen, and nothing on screen explains why.
/// Filtering the flat order is the fix, so it has to be the SAME filter the views use.
enum GroupCollapse {

    /// A group can only be collapsed if it has a header to click. `groups()` returns a
    /// single untitled group when Group By is off, and collapsing that would hide the
    /// entire folder with no header left to click to get it back.
    static func canCollapse(title: String) -> Bool { !title.isEmpty }

    /// The flat item order the given collapsed set leaves on screen. Group headers stay
    /// (they are what you click to expand again); only their contents disappear.
    static func visibleOrder<T>(groups: [(title: String, items: [T])], collapsed: Set<String>) -> [T] {
        groups.flatMap { g in
            canCollapse(title: g.title) && collapsed.contains(g.title) ? [] : g.items
        }
    }

    /// Toggling one group, with the untitled group refused for the reason above.
    static func toggled(_ collapsed: Set<String>, title: String) -> Set<String> {
        guard canCollapse(title: title) else { return collapsed }
        var out = collapsed
        if out.contains(title) { out.remove(title) } else { out.insert(title) }
        return out
    }

    /// Group titles that no longer exist are dropped: the folder changed (different
    /// Group By, files added, a filter typed) and keeping a stale title alive means a
    /// group that reappears later comes back mysteriously collapsed.
    static func pruned(_ collapsed: Set<String>, toTitles titles: [String]) -> Set<String> {
        collapsed.intersection(titles)
    }
}

// MARK: - Search filters (Date Modified / Size)

/// The Date Modified buckets in the search filter menu, as CALENDAR-DAY ranges.
///
/// Day boundaries, not "now minus 24 hours": a file saved at 9am does not stop
/// matching "Today" as the afternoon wears on, which is what an elapsed-seconds
/// window would do and is never what "Today" means to anyone.
///
/// Every range is half-open [from, to) so a file whose mtime is EXACTLY midnight
/// belongs to the day that is starting, in exactly one bucket — an inclusive upper
/// bound would put midnight in both "Yesterday" and "Today".
enum SearchDateFilter: String, CaseIterable, Codable {
    case any = "Any Date"
    case today = "Today"
    case yesterday = "Yesterday"
    case last7 = "Last 7 Days"
    case last30 = "Last 30 Days"
    case thisYear = "This Year"
    case custom = "Custom Range…"

    /// `from` inclusive, `to` exclusive; nil means unbounded on that side.
    ///
    /// `custom` takes whole days from the two date pickers — the pickers only offer a
    /// day, so treating `customTo` as an instant would silently exclude everything
    /// written on the last day the user picked.
    func range(now: Date, calendar: Calendar = .current,
               customFrom: Date? = nil, customTo: Date? = nil) -> (from: Date?, to: Date?) {
        let sod = calendar.startOfDay(for: now)
        func day(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: sod) ?? sod }
        switch self {
        case .any:       return (nil, nil)
        case .today:     return (sod, day(1))
        case .yesterday: return (day(-1), sod)
        // "Last 7 Days" is today plus the six days before it — the same seven calendar
        // days Explorer's "Last week" covers, and it must include today.
        case .last7:     return (day(-6), day(1))
        case .last30:    return (day(-29), day(1))
        case .thisYear:
            let start = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? sod
            return (start, day(1))
        case .custom:
            let lo = customFrom.map { calendar.startOfDay(for: $0) }
            let hi = customTo.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
            return (lo, hi)
        }
    }
}

/// The Size buckets in the search filter menu.
///
/// Non-overlapping, so picking one bucket can never also mean "and everything
/// smaller" — the labels carry the exact edges because "Small" means nothing on its
/// own and a filter you can't predict is worse than no filter.
///
/// Decimal KB/MB/GB (1000-based), NOT 1024: every size this app displays comes from
/// ByteCountFormatter with .file, which is decimal. A 1024-based threshold here
/// would reject a file the size column calls "100 KB" for being 100 KB.
enum SearchSizeFilter: String, CaseIterable, Codable {
    case any = "Any Size"
    case empty = "Empty (0 bytes)"
    case tiny = "Tiny (< 100 KB)"
    case small = "Small (100 KB – 1 MB)"
    case medium = "Medium (1 MB – 100 MB)"
    case large = "Large (100 MB – 1 GB)"
    case huge = "Huge (> 1 GB)"
    case custom = "Custom Range…"

    // Typed exponents, infinity and huge values must not trap during Int64 conversion.
    static func bytes(megabytes text: String) -> Int64? {
        guard let value = Double(text), value.isFinite, value >= 0 else { return nil }
        let bytes = value * Double(mb)
        guard bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }

    static let kb: Int64 = 1_000
    static let mb: Int64 = 1_000_000
    static let gb: Int64 = 1_000_000_000

    /// `from` inclusive, `to` exclusive; nil means unbounded on that side.
    /// Custom bounds arrive in BYTES (the UI multiplies its KB/MB field out).
    func range(customFrom: Int64? = nil, customTo: Int64? = nil) -> (from: Int64?, to: Int64?) {
        switch self {
        case .any:    return (nil, nil)
        case .empty:  return (0, 1)
        case .tiny:   return (1, 100 * Self.kb)
        case .small:  return (100 * Self.kb, Self.mb)
        case .medium: return (Self.mb, 100 * Self.mb)
        case .large:  return (100 * Self.mb, Self.gb)
        case .huge:   return (Self.gb, nil)
        case .custom: return (customFrom, customTo)
        }
    }
}

/// The one place a search result is tested against the Date/Size filters.
///
/// BOTH backends run this: the Spotlight path builds an equivalent NSMetadataQuery
/// predicate to keep the result set small, then re-checks here, and the recursive
/// walkSearch (SMB / Google Drive, which Spotlight cannot index) has only this. Two
/// separate implementations is how a filter ends up silently ignored on one path —
/// and Spotlight's own index can be stale about size, so the re-check is not
/// redundant even where the predicate already ran.
struct SearchFilters: Codable {
    var date: SearchDateFilter = .any
    var size: SearchSizeFilter = .any
    var customDateFrom: Date?
    var customDateTo: Date?
    var customSizeFrom: Int64?
    var customSizeTo: Int64?

    var isActive: Bool { date != .any || size != .any }

    func dateRange(now: Date = Date(), calendar: Calendar = .current) -> (from: Date?, to: Date?) {
        date.range(now: now, calendar: calendar, customFrom: customDateFrom, customTo: customDateTo)
    }
    func sizeRange() -> (from: Int64?, to: Int64?) {
        size.range(customFrom: customSizeFrom, customTo: customSizeTo)
    }

    /// `isDirectory` items are exempt from the SIZE filter: a folder's `size` in a
    /// listing is its directory-entry size (a few hundred bytes), not its contents, so
    /// judging folders by it would drop every folder from "Large" and file every folder
    /// under "Tiny" — both plainly wrong. Dates apply to folders normally.
    func matches(modified: Date, size bytes: Int64, isDirectory: Bool,
                 now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let d = dateRange(now: now, calendar: calendar)
        if let f = d.from, modified < f { return false }
        if let t = d.to, modified >= t { return false }
        if !isDirectory {
            let s = sizeRange()
            if let f = s.from, bytes < f { return false }
            if let t = s.to, bytes >= t { return false }
        }
        return true
    }
}

// MARK: - Sharing & Permissions (Get Info)

/// A POSIX permission triad shown the way Finder shows it, because "rwxr-xr-x" is
/// not something most people can read and is certainly not something they can edit.
///
/// The execute bit is deliberately NOT part of the level: stripping it turns a
/// directory into one you cannot enter (and a tool into one you cannot run), so a
/// user picking "Read only" for a group must not silently break traversal. See
/// `bits(existing:isDirectory:)`.
enum PosixAccess: String, CaseIterable, Codable {
    case readWrite = "Read & Write"
    case readOnly = "Read only"
    case writeOnly = "Write only (Drop Box)"
    case noAccess = "No Access"

    /// From one octal digit (0...7).
    static func from(bits: UInt16) -> PosixAccess {
        switch (bits & 4 != 0, bits & 2 != 0) {
        case (true, true):   return .readWrite
        case (true, false):  return .readOnly
        case (false, true):  return .writeOnly
        case (false, false): return .noAccess
        }
    }

    /// The octal digit for this level.
    ///
    /// `existing` supplies the execute/search bit, which is carried through unchanged
    /// for files — chmod'ing a script to "Read only" should not also un-run it.
    /// Directories are the exception: read access to a directory is useless without
    /// search permission (you can list names but cannot stat anything inside), so
    /// granting read to a directory grants search with it, which is what Finder does.
    func bits(existing: UInt16, isDirectory: Bool) -> UInt16 {
        guard self != .noAccess else { return 0 }   // no access means none, execute included
        // A directory always keeps search permission alongside any granted access: a
        // "Write only (Drop Box)" you cannot enter is not a drop box, and a readable
        // directory you cannot search lists names whose contents nothing can stat.
        let x: UInt16 = isDirectory ? 1 : (existing & 1)
        switch self {
        case .readWrite: return 6 | x
        case .readOnly:  return 4 | x
        case .writeOnly: return 2 | x
        case .noAccess:  return 0
        }
    }
}

/// Which triad of a mode a change applies to.
enum PosixClass: Int, CaseIterable { case owner = 6, group = 3, other = 0 }

enum PosixMode {
    /// The three levels of a full mode, for display.
    static func levels(_ mode: UInt16) -> (owner: PosixAccess, group: PosixAccess, other: PosixAccess) {
        (.from(bits: (mode >> 6) & 7), .from(bits: (mode >> 3) & 7), .from(bits: mode & 7))
    }
    /// `mode` with one triad replaced. Only the 12 permission bits are touched —
    /// setuid/setgid/sticky live above them and dropping them silently would break
    /// shared drop folders that rely on setgid.
    static func setting(_ mode: UInt16, _ cls: PosixClass, to level: PosixAccess, isDirectory: Bool) -> UInt16 {
        let shift = UInt16(cls.rawValue)
        let existing = (mode >> shift) & 7
        let replaced = level.bits(existing: existing, isDirectory: isDirectory)
        return (mode & ~(7 << shift)) | (replaced << shift)
    }
    /// "rwxr-xr-x" — kept because it's the form you can paste into a chmod discussion.
    static func string(_ mode: UInt16) -> String {
        func rwx(_ v: UInt16) -> String { "\(v & 4 != 0 ? "r" : "-")\(v & 2 != 0 ? "w" : "-")\(v & 1 != 0 ? "x" : "-")" }
        return rwx((mode >> 6) & 7) + rwx((mode >> 3) & 7) + rwx(mode & 7)
    }
}

// MARK: - Trash put-back

/// Where a trashed item came from, so "Put Back" lands it where Finder would.
struct TrashOrigin: Equatable {
    /// Absolute directory the item was in.
    var directory: String
    /// The name it had BEFORE the Trash renamed it for a collision — "New Folder",
    /// not "New Folder 08-27-42-686". Restoring under the trash-mangled name is the
    /// classic way a Restore feature quietly returns the wrong thing.
    var name: String
    var url: URL { URL(fileURLWithPath: directory).appendingPathComponent(name) }
}

/// Reads Finder's put-back records out of a Trash folder's `.DS_Store`.
///
/// This is the only place the original location of an item trashed by ANOTHER app
/// is recorded — there is no xattr and no metadata attribute for it (checked: a
/// freshly trashed file carries only com.apple.provenance). The records are
/// `ptbL` (original directory, as a path with no leading slash) and `ptbN`
/// (original name), keyed by the item's name inside the Trash.
///
/// The file is an undocumented "Bud1" buddy-allocator wrapping a B-tree, and it is
/// UNTRUSTED input: every read below is bounds-checked and every failure returns
/// what has been decoded so far rather than trapping. A corrupt .DS_Store must
/// degrade Restore to "origin unknown", never crash the app.
///
/// It is also written LAZILY by Finder, so an item trashed seconds ago may have no
/// record yet. That is why Navigator persists its own trash→origin map as well and
/// consults it first (see TrashOrigins); this parser is the fallback that makes
/// Restore work for the rest of the Trash.
enum DSStore {
    static func putBackRecords(_ data: Data) -> [String: TrashOrigin] {
        var out: [String: TrashOrigin] = [:]
        let b = [UInt8](data)
        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
        }
        guard u32(0) == 1, b.count > 8,
              b[4] == 0x42, b[5] == 0x75, b[6] == 0x64, b[7] == 0x31 else { return out }  // "Bud1"
        // Header: allocator-info offset at 0x08. All block offsets in this format are
        // relative to the end of the 4-byte magic, hence the +4 everywhere.
        guard let infoOff = u32(0x08).map({ Int($0) + 4 }), let blockCount = u32(infoOff) else { return out }
        guard blockCount > 0, blockCount < 100_000 else { return out }
        let addrStart = infoOff + 8
        // The address list is padded out to a whole multiple of 256 entries.
        let addrSlots = ((Int(blockCount) + 255) / 256) * 256
        var dirOff = addrStart + addrSlots * 4
        guard let dirCount = u32(dirOff), dirCount < 10_000 else { return out }
        dirOff += 4
        var dsdbBlock: Int?
        for _ in 0..<Int(dirCount) {
            guard dirOff < b.count else { return out }
            let nameLen = Int(b[dirOff]); dirOff += 1
            guard dirOff + nameLen + 4 <= b.count else { return out }
            let name = String(decoding: b[dirOff..<(dirOff + nameLen)], as: UTF8.self)
            dirOff += nameLen
            let block = u32(dirOff); dirOff += 4
            if name == "DSDB" { dsdbBlock = block.map(Int.init) }
        }
        // A block's address packs its offset and its log2 size into one word.
        func block(_ n: Int) -> Int? {
            guard let a = u32(addrStart + n * 4) else { return nil }
            return Int(a & ~0x1f) + 4
        }
        guard let dsdb = dsdbBlock, let dsdbOff = block(dsdb), let rootNode = u32(dsdbOff) else { return out }

        /// One key/value record. Returns the offset just past it, or nil to abandon
        /// the walk — an unrecognised value type means we no longer know how many
        /// bytes to skip, and guessing would read garbage as a filesystem path.
        func record(_ off: Int) -> Int? {
            guard let nameLen = u32(off), nameLen < 4096 else { return nil }
            var o = off + 4
            let nameBytes = Int(nameLen) * 2
            guard o + nameBytes + 8 <= b.count else { return nil }
            // Decode as UTF-16, not scalar-at-a-time: an emoji in a filename is a
            // surrogate PAIR, and treating each half as a scalar throws the name away.
            var units: [UInt16] = []
            var i = o
            while i + 1 < o + nameBytes {
                units.append((UInt16(b[i]) << 8) | UInt16(b[i + 1]))
                i += 2
            }
            let key = String(decoding: units, as: UTF16.self)
            o += nameBytes
            let sid = String(decoding: b[o..<(o + 4)], as: UTF8.self); o += 4
            let type = String(decoding: b[o..<(o + 4)], as: UTF8.self); o += 4
            var text: String?
            switch type {
            case "long", "shor", "type": o += 4
            case "bool": o += 1
            case "comp", "dutc": o += 8
            case "blob":
                guard let n = u32(o), n < 1 << 24 else { return nil }
                o += 4 + Int(n)
            case "ustr":
                guard let n = u32(o), n < 1 << 20 else { return nil }
                o += 4
                let bytes = Int(n) * 2
                guard o + bytes <= b.count else { return nil }
                var vu: [UInt16] = []
                var j = o
                while j + 1 < o + bytes {
                    vu.append((UInt16(b[j]) << 8) | UInt16(b[j + 1]))
                    j += 2
                }
                text = String(decoding: vu, as: UTF16.self)
                o += bytes
            default: return nil
            }
            guard o <= b.count else { return nil }
            if let text {
                switch sid {
                case "ptbL": out[key, default: TrashOrigin(directory: "", name: "")].directory = normalize(text)
                case "ptbN": out[key, default: TrashOrigin(directory: "", name: "")].name = text
                default: break
                }
            }
            return o
        }

        // Depth-first over the B-tree, with an EXPLICIT stack rather than recursion.
        //
        // The node-count bound below does not bound DEPTH: a corrupt file whose nodes
        // form a 10,000-long chain (each one naming the next, none of them repeating)
        // was 10,000 live stack frames deep. This runs from loadTrashPutBack on a
        // DispatchQueue.global worker, whose stack is 512 KB — deep enough to overflow
        // and take the whole app down with no error anyone could act on. A worklist has
        // no such ceiling. `visited` is still not paranoia: a block number that points
        // back at an ancestor would otherwise loop forever.
        //
        // Visiting order changes (LIFO, so `next` before the children) and that is safe:
        // `out` is keyed by filename+field and a B-tree holds each key once, so no
        // ordering of the same node set can produce a different result.
        var visited = Set<Int>()
        var stack = [Int(rootNode)]
        while let n = stack.popLast() {
            guard !visited.contains(n), visited.count < 10_000, let off = block(n) else { continue }
            visited.insert(n)
            guard let next = u32(off), let count = u32(off + 4), count < 100_000 else { continue }
            var o = off + 8
            if next == 0 {
                for _ in 0..<Int(count) {
                    guard let after = record(o) else { break }
                    o = after
                }
            } else {
                // An unreadable record abandons the REST of this node — including its
                // right-hand `next` sibling — exactly as the recursive form's early
                // return did. Children already read are still walked: they were read
                // before the bad record and are as trustworthy as anything else here.
                var truncated = false
                for _ in 0..<Int(count) {
                    guard let child = u32(o) else { truncated = true; break }
                    o += 4
                    // Bounded, and skipping the already-seen: `count` is only bounded at
                    // 100,000, so a corrupt node claiming that many children would
                    // otherwise queue work no visit budget can ever consume — trading the
                    // stack overflow this rewrite fixes for an out-of-memory one.
                    // Anything past the visit budget is unreachable by definition.
                    if !visited.contains(Int(child)), stack.count < 10_000 { stack.append(Int(child)) }
                    guard let after = record(o) else { truncated = true; break }
                    o = after
                }
                if !truncated, !visited.contains(Int(next)) { stack.append(Int(next)) }
            }
        }
        return out.filter { !$0.value.directory.isEmpty && !$0.value.name.isEmpty }
    }

    /// A `ptbL` value into a path you can hand to FileManager.
    ///
    /// Two fixups. The leading "/" is absent from the stored form. And Finder often
    /// records the firmlink path "/System/Volumes/Data/Users/…", which is the SAME
    /// directory as "/Users/…" but is a second name for it — restoring through it
    /// works, yet every path we then show the user, compare, or navigate to would be
    /// a path they have never seen anywhere else in the OS.
    static func normalize(_ raw: String) -> String {
        var p = raw
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        let firmlink = "/System/Volumes/Data"
        if p == firmlink { return "/" }
        if p.hasPrefix(firmlink + "/") { p = String(p.dropFirst(firmlink.count)) }
        return p
    }
}

/// Navigator's own record of where the things IT trashed came from — the
/// authoritative half of Put Back.
///
/// Finder's `.DS_Store` put-back records are written lazily (a file trashed seconds
/// ago is often not in them yet, measured), so relying on them alone would make
/// Restore fail exactly when it is most likely to be used: right after a delete.
/// Every trash operation records here immediately instead.
///
/// Keyed by the item's path INSIDE the Trash, which is unique — the Trash renames
/// collisions — and pruned to a bounded, recent set so this can't grow without end.
enum TrashOrigins {
    static let key = "trashOrigins"
    private static let limit = 500
    private static let lock = NSLock()
    /// Injected in tests; UserDefaults.standard in the app.
    static var defaults: UserDefaults = .standard

    static func record(_ pairs: [(from: URL, to: URL)]) {
        guard !pairs.isEmpty else { return }
        let snapshot = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let existing = snapshot.filter { FileManager.default.fileExists(atPath: $0.key) }
        let present = pairs.filter { FileManager.default.fileExists(atPath: $0.from.path) }
        var ages: [String: Date] = [:]
        for path in Set(existing.keys).union(present.map { $0.from.path }) {
            ages[path] = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.addedToDirectoryDateKey]))?
                .addedToDirectoryDate ?? .distantPast
        }
        lock.lock(); defer { lock.unlock() }
        var map = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        // Merge into the latest map: another completed transfer may have recorded an
        // origin while the age reads were waiting on a share. Never erase that entry.
        for (path, origin) in snapshot where existing[path] == nil && map[path] == origin { map[path] = nil }
        for p in present { map[p.from.path] = p.to.path }
        map = evict(map, limit: limit) { ages[$0] ?? .distantFuture }
        defaults.set(map, forKey: key)
    }

    /// Keep the `limit` most recently trashed entries.
    ///
    /// The bug this replaces: `Array(map).suffix(limit)` over a Dictionary. Dictionary
    /// iteration order is unspecified AND seeded per process, so eviction dropped an
    /// arbitrary set that differed on every launch — a Put Back that worked yesterday
    /// could silently have no origin today, for no reason the user could see or undo.
    /// Ordering by age makes the survivors the ones anybody would actually reach for.
    static func evict(_ map: [String: String], limit: Int, age: (String) -> Date) -> [String: String] {
        guard map.count > limit else { return map }
        let dated: [(path: String, at: Date)] = map.keys.map { (path: $0, at: age($0)) }
        // Path breaks ties, so two items trashed in the same instant still evict
        // deterministically instead of by hash order.
        let sorted = dated.sorted { $0.at == $1.at ? $0.path < $1.path : $0.at < $1.at }
        var out: [String: String] = [:]
        for e in sorted.suffix(limit) { out[e.path] = map[e.path] }
        return out
    }

    static func origin(of trashedPath: String) -> TrashOrigin? {
        guard let p = (defaults.dictionary(forKey: key) as? [String: String])?[trashedPath] else { return nil }
        let u = URL(fileURLWithPath: p)
        return TrashOrigin(directory: u.deletingLastPathComponent().path, name: u.lastPathComponent)
    }

    static func forget(_ trashedPaths: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard var map = defaults.dictionary(forKey: key) as? [String: String], !map.isEmpty else { return }
        for p in trashedPaths { map[p] = nil }
        defaults.set(map, forKey: key)
    }
}

// MARK: - Permissions (Setup Assistant + deny-at-use-time wording)

/// The answer a capability probe gives about one macOS permission.
///
/// `.notAsked` is a distinct answer, not a flavour of "no": macOS decides a
/// Files-&-Folders permission only at the moment an app first attempts the access, so
/// before that there genuinely is nothing recorded. Folding it into `.denied` would cry
/// wolf on every fresh install; folding it into `.granted` would hide the one row that
/// is about to break. `.unknown` is for what a normal app simply cannot observe — a
/// volume class with no such volume mounted — and the UI says "unknown" rather than
/// guessing, because a confident wrong status is worse than no status.
/// `.off` is kept apart from `.denied` for the same reason: a Finder extension nobody
/// has ever ticked was not "denied" by anyone, and saying so would have the user hunting
/// System Settings for a refusal that never happened.
/// `.covered` is the answer to a question macOS never lets an app ask directly: the
/// permission was never recorded, and never will be, because a broader one already
/// stands in for it. It reads as satisfied — because it IS — without claiming the
/// probe proved anything, which `.granted` would.
enum PermissionState: String, Equatable {
    case granted, denied, notAsked, unknown, off, covered

    var label: String {
        switch self {
        case .granted:  return "Granted"
        case .denied:   return "Denied"
        case .notAsked: return "Not yet asked"
        case .unknown:  return "Unknown"
        case .off:      return "Off"
        case .covered:  return "Covered by Full Disk Access"
        }
    }

    var symbol: String {
        switch self {
        case .granted:  return "checkmark.circle.fill"
        case .denied:   return "exclamationmark.octagon.fill"
        case .notAsked: return "circle.dashed"
        case .unknown:  return "questionmark.circle"
        case .off:      return "circle.slash"
        case .covered:  return "checkmark.circle"
        }
    }

    /// Drives the assistant's one-line summary. `.unknown` is deliberately NOT counted:
    /// we have no evidence anything is wrong, and sending someone to System Settings to
    /// fix a permission that may well be fine is how a setup screen loses its credibility.
    var needsAttention: Bool { self == .denied || self == .notAsked || self == .off }
}

/// The rules the Setup Assistant's rows and its footer count BOTH read.
///
/// They live together here because they used to be worked out separately and disagreed:
/// the footer counted rows whose only offered fix was a switch macOS was not showing, so
/// the very first screen of a fresh install announced work that did not exist and pointed
/// at a pane where the named row could not appear. A setup screen that cries wolf once is
/// worse than no setup screen, so both numbers now come out of the same three functions.
enum SetupAudit {

    /// The rows Full Disk Access makes moot.
    ///
    /// FDA (kTCCServiceSystemPolicyAllFiles) is a strict superset of the per-folder and
    /// per-volume-class Files & Folders grants, and macOS acts on that: an app holding it
    /// gets ONE greyed "Full Disk Access" line in the Files & Folders pane INSTEAD of the
    /// individual switches. So a row saying "go turn Desktop on" names a control that is
    /// provably not on the screen we just sent the user to.
    ///
    /// Automation and the Finder extension are deliberately absent: FDA says nothing about
    /// either, and folding them in would swap one false statement for another.
    static let coveredByFullDisk: Set<String> = ["Desktop", "Documents", "Downloads", "network", "removable"]

    /// What a row should actually say, given its own probe and the Full Disk Access answer.
    ///
    /// Only an answer that would otherwise raise an alarm gets rewritten. A probe that came
    /// back `.granted` keeps that word because it is proof — the access was performed — and
    /// `.unknown` stays unknown because FDA tells us nothing about a volume class with no
    /// volume mounted, and unknown is already not an alarm.
    static func effectiveState(id: String, probed: PermissionState, fullDisk: PermissionState) -> PermissionState {
        guard probed.needsAttention, fullDisk == .granted, coveredByFullDisk.contains(id) else { return probed }
        return .covered
    }

    /// The footer's number, from the same inputs the rows draw themselves from.
    ///
    /// Optional rows never count: Navigator is fully usable without Full Disk Access, so an
    /// unlit optional switch is a choice the user has made, not a job they still owe.
    static func attentionCount(_ rows: [(id: String, probed: PermissionState, optional: Bool)],
                               fullDisk: PermissionState) -> Int {
        rows.filter { !$0.optional && effectiveState(id: $0.id, probed: $0.probed, fullDisk: fullDisk).needsAttention }
            .count
    }

    /// Which of a row's two buttons lead somewhere the user can actually do something.
    ///
    /// `listedOnlyAfterRequest` is the whole point: macOS creates a Files & Folders (or
    /// Automation) row for an app only once the app has attempted the access — before that
    /// the pane has no switch to flip, so "Open Settings" is a guaranteed dead end and the
    /// only thing that works is provoking the real system prompt. A `.covered` row offers
    /// neither: there is nothing to ask for and nothing in Settings to look at.
    static func buttons(state: PermissionState, canAsk: Bool,
                        listedOnlyAfterRequest: Bool) -> (ask: Bool, settings: Bool) {
        let unrequested = state == .notAsked || state == .unknown
        return (ask: canAsk && unrequested,
                settings: state != .covered && !(listedOnlyAfterRequest && unrequested))
    }
}

enum PermissionDiagnosis {

    /// Is this NSError macOS refusing on permission grounds, as opposed to the file
    /// being missing, locked, or on a full disk?
    ///
    /// Both domains matter because the two engines Navigator copies with report
    /// differently: FileManager raises NSCocoaErrorDomain 257/513, while the copyfile()
    /// path builds its error straight from `errno` (EPERM/EACCES).
    static func isDenial(domain: String, code: Int) -> Bool {
        switch domain {
        case NSCocoaErrorDomain: return code == 257 || code == 513   // NSFileRead/WriteNoPermissionError
        case NSPOSIXErrorDomain: return code == 1 || code == 13      // EPERM / EACCES
        default: return false
        }
    }

    /// Same question, asked of a message rather than an error.
    ///
    /// Needed because the app funnels every file failure through one alert helper that
    /// only ever receives `localizedDescription` — threading a structured error through
    /// forty call sites to reach the same alert would be a far bigger change than the
    /// problem deserves. Known ceiling: these are the English strings Cocoa and strerror
    /// produce, so on a non-English system the alert falls back to the generic wording it
    /// has always shown. Upgrade path if that ever matters: pass the NSError down and use
    /// `isDenial` above, which is locale-proof.
    static func looksLikeDenial(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("permission denied")
            || t.contains("don't have permission") || t.contains("don\u{2019}t have permission")
            || t.contains("not permitted")
    }

    /// Which macOS-protected folder a path sits in, so a denial can name the folder the
    /// user was actually aiming at ("your Desktop") instead of lecturing about TCC.
    ///
    /// Only these three: they are exactly the home folders macOS gates behind their own
    /// Files-&-Folders switches. Pictures/Music/Movies are NOT gated, and claiming they
    /// were would send people looking for a switch that doesn't exist.
    static func protectedFolder(for path: String, home: String) -> String? {
        let h = URL(fileURLWithPath: home)
        return ["Desktop", "Documents", "Downloads"].first {
            PathRules.isSelfOrDescendant(URL(fileURLWithPath: path), of: h.appendingPathComponent($0))
        }
    }
}

// MARK: - Open/Save dialog bridge

/// The decisions behind "put my location where another app's Open/Save panel can reach
/// it". Pure, so the four selection cases and the chord table are pinned by tests — the
/// hotkey itself fires while Navigator is in the background, where a wrong answer is
/// invisible until it has already sent someone's dialog to the wrong folder.
///
/// Why a clipboard at all: macOS has no picker role. An Open/Save panel is always
/// NSOpenPanel/NSSavePanel (drawn by Powerbox for sandboxed apps), LaunchServices only
/// knows Viewer/Editor/Shell, and nothing in macOS 26 changed that — so a third-party
/// browser cannot be substituted for the panel. What every one of those panels DOES
/// accept is a POSIX path pasted into ⌘⇧G, which is the supported bridge this builds on.
enum PickerBridgeRules {

    /// The one path to hand a dialog's ⌘⇧G.
    ///
    /// A single selected FILE is deliberately returned as the file itself, not its
    /// folder: an Open panel's ⌘⇧G navigates to it *and* preselects it, so the user is
    /// one Return from done. A single folder is likewise itself — for a Save panel that
    /// is the destination, and for an Open panel it is where you wanted to look.
    static func pathToCopy(folder: String, selection: [String]) -> String {
        if selection.count == 1, !selection[0].isEmpty { return selection[0] }
        // Several items: a dialog can only go one place, so it goes to the folder they
        // live in. Taken from the items themselves rather than assumed to be `folder`,
        // because in search results the hits come from anywhere below it — and the
        // folder they share is a far better answer than the search root. Falls back to
        // `folder` when they genuinely don't share one.
        let parents = Set(selection.map { ($0 as NSString).deletingLastPathComponent })
        if parents.count == 1, let only = parents.first, !only.isEmpty { return only }
        return folder
    }

    /// A global hot key, described in the two forms both consumers need: Carbon's
    /// (keyCode, modifiers) pair for RegisterEventHotKey, and glyphs for the menu.
    struct Chord: Equatable {
        /// Stored in UserDefaults, so it must never change for an existing chord.
        let id: String
        /// The printable key, both for `display` and for the menu item's key equivalent.
        let key: String
        /// Carbon virtual key code (kVK_ANSI_*). Spelled numerically because this file
        /// deliberately imports nothing but Foundation.
        let keyCode: UInt32
        /// Carbon modifier mask: controlKey 0x1000, optionKey 0x800, shiftKey 0x200,
        /// cmdKey 0x100.
        let carbonModifiers: UInt32
        var display: String { PickerBridgeRules.glyphs(carbonModifiers) + key }
    }

    static let controlKeyMask: UInt32 = 0x1000
    static let optionKeyMask: UInt32  = 0x0800
    static let shiftKeyMask: UInt32   = 0x0200
    static let commandKeyMask: UInt32 = 0x0100

    /// The offered chords, rather than a free-form key recorder: every one of these is
    /// ⌃⌥⌘ + a letter, which no shipping macOS shortcut and nothing in Navigator's own
    /// menus uses, so picking one can't quietly shadow a chord the user relies on.
    ///
    /// None of them include Shift, and that is load-bearing: `teleportChord` derives the
    /// second hot key by ADDING Shift, so a Shift-bearing choice here would make the two
    /// chords identical.
    static let chords: [Chord] = [
        // ⌃⌥⌘G — G as in the ⌘⇧G it feeds. kVK_ANSI_G.
        Chord(id: "ctrl-opt-cmd-g", key: "G", keyCode: 5,
              carbonModifiers: controlKeyMask | optionKeyMask | commandKeyMask),
        // kVK_ANSI_P
        Chord(id: "ctrl-opt-cmd-p", key: "P", keyCode: 35,
              carbonModifiers: controlKeyMask | optionKeyMask | commandKeyMask),
        // kVK_ANSI_K
        Chord(id: "ctrl-opt-cmd-k", key: "K", keyCode: 40,
              carbonModifiers: controlKeyMask | optionKeyMask | commandKeyMask)
    ]

    /// Falls back to the first chord for an unknown or absent id, so a pref written by a
    /// later version (or a hand-edited plist) leaves the feature working rather than off.
    static func chord(id: String?) -> Chord {
        chords.first { $0.id == id } ?? chords[0]
    }

    /// The one-keystroke variant is always the copy chord plus Shift: one pref to set,
    /// and the pair stays memorable ("the same thing, harder").
    static func teleportChord(for c: Chord) -> Chord {
        Chord(id: c.id + "-shift", key: c.key, keyCode: c.keyCode,
              carbonModifiers: c.carbonModifiers | shiftKeyMask)
    }

    /// Modifier glyphs in Apple's canonical ⌃⌥⇧⌘ order — any other order reads as a
    /// typo next to the system's own menus.
    static func glyphs(_ carbonModifiers: UInt32) -> String {
        var s = ""
        if carbonModifiers & controlKeyMask != 0 { s += "\u{2303}" }
        if carbonModifiers & optionKeyMask  != 0 { s += "\u{2325}" }
        if carbonModifiers & shiftKeyMask   != 0 { s += "\u{21E7}" }
        if carbonModifiers & commandKeyMask != 0 { s += "\u{2318}" }
        return s
    }

    /// Path shortened for the confirmation HUD, from the LEFT: the tail names the file
    /// or folder the user just aimed at, and that is the part they need to recognise.
    static func hudLabel(_ path: String, max: Int = 56) -> String {
        guard path.count > max else { return path }
        var parts = path.split(separator: "/").map(String.init)
        while parts.count > 1 {
            parts.removeFirst()
            let candidate = "\u{2026}/" + parts.joined(separator: "/")
            if candidate.count <= max { return candidate }
        }
        // One component longer than the whole budget (a very long file name): keep its
        // end, since that is where the extension and any numbering live.
        return "\u{2026}" + String(path.suffix(max - 1))
    }

    // MARK: The Save-panel escape (bug: "one-key teleport wrote a file")
    //
    // The one-key variant used to post ⌘⇧G, wait a fixed 250 ms, ⌘V, wait 150 ms, ⏎.
    // In a Save panel that combination CREATED A FILE — once into a real Google Drive
    // shared-drive folder. The mechanism, measured rather than guessed:
    //
    //   Return is NOT delivered twice. When the Go-to-Folder sheet is genuinely up, one
    //   Return only navigates and the Save panel stays open. What goes wrong is the ⌘V:
    //   whenever the sheet has NOT appeared — the app doesn't honour ⌘⇧G, the panel is
    //   busy, 250 ms simply wasn't enough — the paste lands in the panel's OWN filename
    //   field, and NSSavePanel reads an absolute path there as a destination. The single
    //   Return then completes a real Save.
    //
    // So both halves get closed here: nothing is pasted until the Go-to-Folder field is
    // observed to hold focus, and Return is posted only into a panel proven to be an
    // Open panel. Neither is sufficient alone — the first makes the paste land where it
    // was aimed, the second means that even a misaimed paste can't be committed by us.

    /// What kind of Open/Save panel has keyboard focus, as far as the Accessibility tree
    /// will admit. `unknown` is a real and common answer — Photoshop's own Save As sheet,
    /// an ordinary window, an app that won't answer AX — and it is treated exactly like a
    /// Save panel, because the only safe reading of "I can't tell what this Return will
    /// do" is "then don't press it".
    enum PanelKind: Equatable { case openPanel, savePanel, unknown }

    /// Decided on AXIdentifiers, never on button titles: `open-panel`, `save-panel` and
    /// `saveAsNameTextField` are AppKit's own identifiers and are not localized, so this
    /// still works on a French Mac where the default button says "Enregistrer".
    static func panelKind(identifier: String?, hasFilenameField: Bool) -> PanelKind {
        // The filename field OUTRANKS the identifier: a panel that can name a new file is
        // a panel that can create one, whatever the panel calls itself.
        if hasFilenameField { return .savePanel }
        switch identifier {
        case "open-panel": return .openPanel
        case "save-panel": return .savePanel
        default:           return .unknown
        }
    }

    /// The hard constraint, in one line. Do not "simplify" this to `kind != .savePanel`:
    /// `unknown` must stay on the no-Return side or the guarantee is gone.
    static func mayPostReturn(_ kind: PanelKind) -> Bool { kind == .openPanel }

    /// Identifiers that mean "focus is in a dialog's Go-to-Folder field". `PathTextField`
    /// is the field itself and `GoToWindow` its sheet; either proves the sheet is up and
    /// listening, which is the precondition for pasting at all.
    static let goToFolderIdentifiers: Set<String> = ["PathTextField", "GoToWindow"]

    /// `chain` is the focused element and its ancestors, outward.
    static func isGoToFolderFocused(_ chain: [String]) -> Bool {
        chain.contains { goToFolderIdentifiers.contains($0) }
    }

    /// What actually happened, so the HUD can say it. Behaviour that differs between an
    /// Open and a Save panel is only acceptable if the user is told which one they got.
    enum TeleportOutcome: Equatable {
        /// Open panel: pasted and Return sent — the original one-press behaviour.
        case jumped
        /// Save panel or unidentifiable: pasted into Go to Folder, Return left to the user.
        case pastedAwaitingReturn
        /// Go to Folder never opened, so nothing was pasted anywhere.
        case noGoToFolder
    }

    static func teleportHUD(label: String, app: String, rescued: Bool,
                            outcome: TeleportOutcome) -> String {
        // Names the SOURCE, not just the path: when the clipboard's Drive path overrode
        // Navigator's own folder, the one case where it guessed wrong must be visible.
        let what = (rescued ? "clipboard\u{2019}s Drive path " : "") + label
        switch outcome {
        case .jumped:
            return "Jumped to \(what) in \(app)"
        case .pastedAwaitingReturn:
            return "Pasted \(what) in \(app) \u{00B7} press Return to go \u{2014} Navigator won\u{2019}t, in case it saves"
        case .noGoToFolder:
            return "Copied \(what) \u{00B7} \(app) didn\u{2019}t open Go to Folder \u{2014} press \u{2318}\u{21E7}G then \u{2318}V"
        }
    }
}

// MARK: - Drag state invariant

/// The one rule every drag flag in the app has to obey: **drag state may only be set while
/// a drag can actually be in flight.** Anything still claiming "a drag is over me" outside
/// those windows is a leak, and a leaked drag flag is invisible — the app stays responsive
/// and only *drag and drop* quietly stops working until the process is restarted.
///
/// This is worth a testable rule of its own because the flags are set and cleared from
/// AppKit callbacks that are not symmetric. `draggingEntered`/`draggingExited` fire on the
/// destination, the source's session-end fires on the source, `acceptDrop` fires on
/// neither reliably (a cancelled drag never reaches it), and some of the notifications have
/// to be published on a deferred main-queue hop because writing SwiftUI state synchronously
/// inside a drag callback destroys the drop targeting. Enumerating every AppKit path that
/// could skip a clear is not possible from outside AppKit; asserting the invariant at
/// moments when no drag CAN be running is.
///
/// Pure and parameterised on the button mask instead of reading `NSEvent` itself, so the
/// decision can be tested without a real drag.
enum DragStateRules {
    /// The left button's bit in `NSEvent.pressedMouseButtons`.
    private static let leftButtonMask = 1

    static func leftButtonIsDown(_ pressedMouseButtons: Int) -> Bool {
        pressedMouseButtons & leftButtonMask != 0
    }

    /// How long the drag callbacks have to have been silent before the WEAKER boundary is
    /// allowed to act. A live drag over the file list calls `validateDrop` on every mouse
    /// move, so ongoing callbacks are the signal that a session is still running; only a
    /// pointer held perfectly still for this long looks the same as no drag at all.
    ///
    /// Generous on purpose. Costing this boundary some eagerness is free, because the
    /// `mouseDown` boundary is exact and fires on the user's very next click in the list —
    /// whereas being too eager here breaks a live drop, which is the one unacceptable
    /// outcome. Ordered the same way the risk is.
    static let quietPeriod: TimeInterval = 2

    /// May a safety net clear drag state right now?
    ///
    /// Two INDEPENDENT proofs that no drag can be running, either of which is enough. They
    /// are NOT equally strong, and that asymmetry is the whole reason this is a function:
    ///
    ///  • a fresh `mouseDown` — EXACT. At a mouseDown the button is down, so the button
    ///    test below would never fire here; but a drag session runs its own event-tracking
    ///    loop and swallows the events it tracks, so an ordinary mouseDown arriving at a
    ///    view at all proves no session is running. True even for a drag that started in
    ///    another app, where this app's views get dragging callbacks and never a mouseDown.
    ///    This is also the proof that survives Drag Lock and three-finger drag.
    ///
    ///  • no mouse button down, AND the drag callbacks have gone quiet — INFERRED, which is
    ///    why it needs both halves. The button test alone reads "no drag" during macOS's
    ///    three-finger drag and Drag Lock, where a session continues with NO button
    ///    pressed. That matters because the boundaries this branch serves — app-activation
    ///    and window-became-key — are NOT actually drag-free moments: hovering the Dock
    ///    icon mid-drag activates the app, and an alert opening mid-drag (a background job
    ///    finishing, say) makes a new window key. Firing there would call reload() straight
    ///    into a live drag and silently kill the drop — the exact bug the lock exists to
    ///    prevent, converted from intermittent to reproducible. The quiet period is what
    ///    keeps that from happening.
    static func shouldClearStaleDragState(dragStateSet: Bool, pressedMouseButtons: Int,
                                          isFreshMouseDown: Bool,
                                          secondsSinceDragCallback: TimeInterval) -> Bool {
        guard dragStateSet else { return false }
        if isFreshMouseDown { return true }
        return !leftButtonIsDown(pressedMouseButtons) && secondsSinceDragCallback >= quietPeriod
    }

    /// Is a dragging session we believe is still in flight provably ORPHANED?
    ///
    /// Bug this serves: "drag and drop stops working; restarting Navigator fixes it."
    /// Measured with a standalone AppKit probe — while AppKit believes a session is in
    /// flight, `beginDraggingSession` returns nil (Swift types the result non-optional, so
    /// the nil arrives as a bogus reference and simply nothing happens: no willBeginAt, no
    /// drop, no endedAt). One leaked session therefore refuses every later drag anywhere in
    /// the app, which is why only a relaunch clears it.
    ///
    /// The only boundary allowed to declare an orphan is a fresh mouseDown, and it is
    /// EXACT rather than inferred — same proof `shouldClearStaleDragState` already relies
    /// on: a session runs its own event-tracking loop and swallows the events it tracks, so
    /// an ordinary mouseDown reaching a view at all proves no session of ours is running.
    /// Deliberately NOT "the button is up": macOS Drag Lock and three-finger drag both
    /// continue a live session with no button pressed, and firing there would tear down a
    /// drag the user is still performing — turning an occasional bug into a constant one.
    ///
    /// `endWatchStillArmed` is the one thing that can make the mouseDown boundary lie. The
    /// polled end-of-session watch only fires once the button comes back up and then waits
    /// out a short grace delay, so a user who clicks again inside that window has a session
    /// whose end is legitimately still pending — not a leak. Suppressing the claim there
    /// keeps the log line trustworthy as a bug report.
    static func isDragSessionOrphaned(sessionInFlight: Bool, isFreshMouseDown: Bool,
                                      endWatchStillArmed: Bool) -> Bool {
        sessionInFlight && isFreshMouseDown && !endWatchStillArmed
    }

    /// How long AppKit's real `draggingSession(_:endedAt:operation:)` gets to arrive after
    /// the button comes up before the polled watchdog is allowed to call the session leaked.
    ///
    /// BUG (drag-and-drop wedge), second half: at the old 0.25s this watchdog BEAT the real
    /// callback on every healthy drag — the log showed both, watchdog first, genuine end a
    /// moment later. A last resort that wins every race is not a last resort; it meant the
    /// leaked-session path ran mid-teardown on every single drag instead of on the rare leak
    /// it was written for. The real callback lands in milliseconds when it lands at all, so
    /// seconds of slack costs nothing and makes the watchdog's line mean what it says.
    ///
    /// The cost of a long interval is that the PREVIOUS drag's watchdog is still armed when
    /// the next drag starts — which is exactly why the watchdog now presents a ticket
    /// (`DragSessionLedger`) instead of trusting an in-flight flag.
    static let endWatchdogGrace: TimeInterval = 3
}

/// Which of the two competing ends of one dragging session is allowed to speak.
///
/// BUG (drag and drop stops working until Navigator is relaunched), second half of it. Two
/// paths report the end of a drag: AppKit's own `draggingSession(_:endedAt:operation:)`,
/// and a polled watchdog for the sources AppKit never calls it on. They were both firing,
/// unreconciled, on every healthy drag.
///
/// Tickets rather than a Bool, and that is the part worth reading. Making the watchdog wait
/// long enough to genuinely lose the race widens the window in which the PREVIOUS drag's
/// watchdog is still armed as the NEXT drag begins. Against a plain "is something in
/// flight" flag that stale watchdog would end the new, LIVE drag — tearing down a drag the
/// user is still performing, which is the one outcome worse than the bug being fixed. A
/// ticket names exactly one session, so a late watchdog can only ever be silent.
struct DragSessionLedger {
    /// Monotonic and never reused, so a ticket identifies one session for the life of the
    /// process — a wrapped or recycled ticket would reintroduce the confusion it prevents.
    private var issued = 0
    private var open: (source: String, ticket: Int)?

    /// What started the session believed to still be running; nil means idle.
    var inFlightSource: String? { open?.source }

    /// How many sessions this ledger has ever opened. Diagnostics only: "12 drags this session,
    /// none in flight" and "12 drags, one in flight since the third" are the same log with
    /// completely different meanings, and the count is what separates them.
    var sessionsOpened: Int { issued }

    /// Drops the open session without logging or arbitration — the manual "Reset Drag & Drop"
    /// command, and nothing else. Deliberately NOT one of the two ends: neither end may be
    /// silent about a session it closes, and this one has to be, because the command logs its
    /// own before/after snapshot instead.
    mutating func abandon() -> String? {
        defer { open = nil }
        return open?.source
    }

    /// Opens a session and returns the ticket its watchdog must present to close it.
    mutating func begin(_ source: String) -> Int {
        issued += 1
        open = (source, issued)
        return issued
    }

    /// The authoritative end — AppKit's own callback, or a source-side signal that the drag
    /// is definitively over. It arrives for whatever session is open and so needs no ticket.
    /// Returns the source to log, or nil when the session is already closed and this end
    /// must stay silent (the idempotence: whichever end lands first wins).
    mutating func closeAuthoritatively() -> String? {
        defer { open = nil }
        return open?.source
    }

    /// The watchdog's end. Returns the source to log, or nil when it must stay silent —
    /// either the authoritative end already closed this session, or `ticket` names an OLDER
    /// session and the one now open is still running.
    mutating func closeIfCurrent(ticket: Int) -> String? {
        guard let o = open, o.ticket == ticket else { return nil }
        open = nil
        return o.source
    }
}

/// What to do about a dragging session AppKit refused to start.
///
/// BUG (drag and drop stops working until Navigator is relaunched), the recovery half.
/// `beginDraggingSession` returning nil means AppKit still believes an earlier drag is in
/// flight, and until now that was detected and merely logged. This is the ladder that turns
/// detection into repair: try once, then tell the user once, then shut up forever.
///
/// "Once" is counted per WEDGE, not per process — a drag that demonstrably starts again
/// clears the counters, so a second wedge later in the session still gets its own attempt
/// and its own notice. Never nagging is a requirement, not a nicety: a notice that repeats
/// on every failed drag would be worse than the silence it replaces.
enum DragWedgeRules {
    enum Action: Equatable {
        case none
        /// Nudge AppKit into reconciling the phantom session, then re-attempt the drag once.
        case recoverAndRetry
        /// Recovery has already been tried and the drag is still refused: say so, once.
        case notifyUser
    }

    static func action(refused: Bool, recoveryAttempted: Bool, userNotified: Bool) -> Action {
        guard refused else { return .none }
        if !recoveryAttempted { return .recoverAndRetry }
        return userNotified ? .none : .notifyUser
    }
}

/// THE BUG (drag and drop stops working until Navigator is relaunched), reduced to the one
/// fact that actually defines it.
///
/// ROOT CAUSE, found and fixed: `ClickTimingTableView.draggingEnded(_:)` called
/// `super.draggingEnded(sender)`, and NSTableView does not implement that optional method.
/// The unrecognized-selector exception was raised inside AppKit's own NSCoreDragCompletionProc,
/// swallowed by the try/catch AppKit wraps drags in, and the unwind skipped the call that
/// removes the session from NSCoreDragManager's registry. AppKit then believed a drag was
/// in flight forever, so `beginDraggingSession` returned nil process-wide.
///
/// So the ONE observable that means "wedged" is: AppKit still has the finished drag registered.
/// Two earlier proxies for it were measured to be wrong and must not come back:
///   • "the NSDraggingSession object is still alive" — retired sessions routinely stay alive
///     for ten seconds and more in a healthy process;
///   • "no `endedAt` callback arrived" — AppKit never sends it to an NSTableView that is also a
///     registered drop destination, which the file list has to be.
/// Either one alone fired on every healthy list-view drag, which is how the real signal got
/// lost the first two times this bug was chased.
enum DragLeakRules {
    /// How long after a drag ends AppKit still gets to be "finishing the slide-back animation"
    /// before a session it has not retired counts as never. A cancelled drag's slide-back is a
    /// few hundred ms; seconds are decisive.
    static let retirementGrace: TimeInterval = 5

    /// Whether a finished drag should be reported as leaked — i.e. whether the process is now
    /// wedged. Unlike the proxies above this one is not a heuristic: an entry AppKit has not
    /// removed is exactly what makes the next `beginDraggingSession` return nil.
    static func isLeaked(stillRegisteredWithAppKit: Bool,
                         secondsSinceDragEnd: TimeInterval) -> Bool {
        stillRegisteredWithAppKit && secondsSinceDragEnd >= retirementGrace
    }
}

// MARK: - Running build vs installed build

/// `rebuild.sh` deletes and recreates `/Applications/Navigator.app` while the old process
/// keeps running the binary it already mapped. Nothing in the app noticed: the in-app updater
/// compares the INSTALLED bundle's version against GitHub, so both read the same number and it
/// answers "up to date" while the process is executing hours-old code. That is not a
/// hypothetical — it is how a fixed drag-and-drop bug went on reproducing for an afternoon,
/// with the log showing behaviour the source no longer contained.
///
/// The executable's modification date rather than the version string, because during
/// development the version does NOT change between builds — the whole failure mode is two
/// different binaries claiming the same version. A hash would be equally sound and costs a
/// full read of a 19 MB fat binary on every app activation; a stat costs nothing.
enum RunningBuildRules {
    /// Filesystem timestamps and the copy that installs the bundle are not atomic with the
    /// launch that reads them, so an equal-or-barely-newer stamp must not count as a new
    /// build. Anything shorter than this reported the CURRENT build as stale on some launches.
    static let tolerance: TimeInterval = 2

    static func isStale(runningBuiltAt: Date, onDiskBuiltAt: Date) -> Bool {
        onDiskBuiltAt.timeIntervalSince(runningBuiltAt) > tolerance
    }

    /// Once per DETECTED BUILD, never once per activation. `alreadyNoticed` is the on-disk
    /// stamp the user was last told about, so a second rebuild while the notice is still
    /// pending gets its own notice and a hundred app switches get none.
    static func shouldNotify(runningBuiltAt: Date, onDiskBuiltAt: Date, alreadyNoticed: Date?) -> Bool {
        guard isStale(runningBuiltAt: runningBuiltAt, onDiskBuiltAt: onDiskBuiltAt) else { return false }
        guard let alreadyNoticed else { return true }
        return abs(onDiskBuiltAt.timeIntervalSince(alreadyNoticed)) > tolerance
    }

    /// Coarse, human units. A build age is read to answer "is that the one I just made?", and
    /// seconds of precision get in the way of that.
    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86_400)d \((s % 86_400) / 3600)h"
    }

    static func stamp(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    /// The one line that says which of two same-numbered builds is actually running. Used by
    /// the log, by Check for Updates… and by the diagnostics dump, so all three agree.
    static func describe(runningBuiltAt: Date, onDiskBuiltAt: Date) -> String {
        let running = "running \(stamp(runningBuiltAt)), installed \(stamp(onDiskBuiltAt))"
        guard isStale(runningBuiltAt: runningBuiltAt, onDiskBuiltAt: onDiskBuiltAt) else {
            return running + " — same build"
        }
        return running + " — the installed build is \(age(onDiskBuiltAt.timeIntervalSince(runningBuiltAt))) NEWER than the one running"
    }
}

// MARK: - Drop diagnostics

/// Why a drop that ARRIVED at a surface was not acted on.
///
/// The blind spot this closes: a drop Navigator silently declines and a drop that never
/// reached Navigator at all produced identical logs — nothing. The owner's report was "drag
/// and drop is broken again" against a log showing twelve clean drag sessions, because every
/// one of those lines is the SOURCE side. Destination-side refusals are where the silence was.
///
/// A closed set rather than free-text at each call site, so every surface names the same cause
/// the same way and the reasons can be asserted in tests instead of eyeballed in a log.
enum DropRejection: Equatable {
    /// The pasteboard offered nothing this surface can read at all.
    case noReadableTypes
    /// Only Navigator's own private drag tokens (`navreorder:` / `navtab:`) — a sidebar row or
    /// a tab released somewhere that only accepts files. Counted, because "1 token" is a
    /// mis-aimed reorder and "8 tokens" would mean something quite different.
    case noFileURLs(tokens: Int)
    /// A reorder token landed on a row that is not an entry in the favorites store, so there
    /// is nothing to reorder it against (Locations, Recents, Cloud, expanded subfolders).
    case notAReorderTarget
    /// Every item was the destination folder itself or lived inside it.
    case selfOrDescendant(count: Int)
    /// The drop resolved to no destination — the surface had no folder to hand.
    case missingTarget
    /// The surface takes files, but not THESE files (the style reference well wants an image).
    case wrongKind(String)
    /// Accepted, then found to have nothing left to do. The most deceptive failure of all:
    /// the drop "worked" and moved nothing.
    case nothingToDo(String)

    var reason: String {
        switch self {
        case .noReadableTypes:
            return "the pasteboard offered no types this surface can read"
        case .noFileURLs(let tokens):
            return "no file URLs on the pasteboard — \(tokens) private drag token(s) only (a sidebar row or a tab, released on a surface that only takes files)"
        case .notAReorderTarget:
            return "a reorder token landed on a row that is not a reorderable favorite"
        case .selfOrDescendant(let count):
            return "\(count) item(s) are the destination itself or live inside it"
        case .missingTarget:
            return "no destination folder resolved for this drop"
        case .wrongKind(let what):
            return "this surface accepts \(what) and none of the dropped items are"
        case .nothingToDo(let why):
            return "accepted but nothing to transfer — \(why)"
        }
    }

    /// The reason a surface that only takes files must decline, or nil when it can proceed.
    /// One rule for every such surface: the alternative was each of eight call sites deciding
    /// for itself what "unusable" means, which is how they came to disagree.
    static func forFileDrop(items: Int, fileURLs: Int) -> DropRejection? {
        if items == 0 { return .noReadableTypes }
        if fileURLs == 0 { return .noFileURLs(tokens: items) }
        return nil
    }
}

/// One dense line per drop event, in the style of the refusal-preconditions line: everything
/// needed to tell an arrival from a refusal from a no-op, and nothing that has to be
/// correlated across lines to be useful. A skimmable log, not a trace.
enum DropLogLine {
    enum Outcome: Equatable {
        /// Handled. The string says what was done with it ("into folder", "favorite reorder").
        case accepted(String)
        case refused(DropRejection)
        /// The drop was ACCEPTED — the handler returned true, the drag animation showed
        /// success — and then nothing happened. Its own category, because it is the failure the
        /// owner cannot see from the outside and the one a plain accept/reject log would hide:
        /// "drag and drop is broken" with a log full of clean drags is exactly this shape.
        case acceptedButInert(DropRejection)
    }

    static func text(surface: String, types: [String], items: Int, fileURLs: Int,
                     target: String?, outcome: Outcome) -> String {
        let head: String
        switch outcome {
        case .accepted:         head = "drop received: \(surface)"
        case .refused:          head = "drop REFUSED: \(surface)"
        case .acceptedButInert: head = "drop NO-OP: \(surface)"
        }
        // Types are the first thing to check when a drop from Photoshop or Chrome behaves
        // differently from the same drag out of Finder, so they are always present — even on
        // the accepted line, where they are the record of what a WORKING drop looked like.
        let payload = "\(items) item(s), \(fileURLs) usable file URL(s), types [\(types.joined(separator: ", "))]"
        let where_ = target.map { " → \($0)" } ?? " → (no target)"
        switch outcome {
        case .accepted(let what):                        return "\(head) — \(payload)\(where_) — \(what)"
        case .refused(let r), .acceptedButInert(let r):   return "\(head) — \(payload)\(where_) — \(r.reason)"
        }
    }
}

/// The transfer's own reporting, which the user-facing alert cannot replace: the alert shows
/// at most five failures and only when there are any, so a drop that moved two of three files
/// looked like a complete success. Per-file failures are logged with the underlying error at
/// the point they happen; this is the closing summary.
enum TransferLogLine {
    static func summary(move: Bool, moved: Int, copied: Int, failed: Int, skipped: Int,
                        total: Int, cancelled: Bool, target: String) -> String {
        let settled = move ? moved : copied
        var s = "transfer done: \(move ? "move" : "copy") \(settled)/\(total) → \(target)"
        if move, copied > 0 { s += ", \(copied) copied but not moved" }
        if failed > 0 { s += ", \(failed) FAILED" }
        if skipped > 0 { s += ", \(skipped) skipped (name conflict)" }
        if cancelled { s += ", CANCELLED by the user" }
        // The line that makes a silent no-op visible. Everything else about such a drop looks
        // exactly like a success: a progress sheet appeared, no error was raised, nothing moved.
        if settled == 0, failed == 0, !cancelled { s += " — NOTHING WAS TRANSFERRED" }
        return s
    }
}

// MARK: - Reset Drag & Drop

/// What the manual "Reset Drag & Drop" command is allowed to do, and what it must not claim.
///
/// Two honesty constraints, both of which the command is worthless without:
///   • it must be INERT during a live drag. Clearing the ledger and the spring state mid-drag
///     is precisely the failure this whole subsystem has been bitten by (a reload during a
///     drag discards its drop targeting), so a reset fired by accident would MANUFACTURE the
///     bug it is meant to relieve;
///   • it must not report success it cannot deliver. Our reset clears only state this app
///     owns. If AppKit's own registry is still holding a session, dragging stays broken no
///     matter what we clear, and saying "fixed" would send the owner back to a dead feature.
enum DragResetRules {
    /// Same asymmetry `DragStateRules` documents: the button being up is NOT proof no drag is
    /// running (Drag Lock and three-finger drag continue a session with no button pressed), so
    /// an open session whose callbacks are still fresh blocks the reset as well.
    static func mayReset(leftButtonDown: Bool, sessionInFlight: Bool,
                         secondsSinceDragActivity: TimeInterval) -> Bool {
        if leftButtonDown { return false }
        if sessionInFlight, secondsSinceDragActivity < DragStateRules.quietPeriod { return false }
        return true
    }

    enum Outcome: Equatable {
        /// Nothing is holding a session: dragging should work again.
        case cleared
        /// AppKit still lists the last session as in flight. Nothing this process can do fixes
        /// that — see DragSessionTracker for the measurements behind that claim.
        case relaunchRequired
        /// The private AppKit registry could not be read on this system, so the one observable
        /// that distinguishes the two cases above is unavailable. Say so rather than guess.
        case cannotTell
    }

    static func outcome(appKitStillHoldsSession: Bool?) -> Outcome {
        switch appKitStillHoldsSession {
        case .some(true):  return .relaunchRequired
        case .some(false): return .cleared
        case nil:          return .cannotTell
        }
    }

    static func message(_ o: Outcome) -> String {
        switch o {
        case .cleared:
            return "Navigator’s drag state has been cleared and macOS is not holding a drag, so dragging should work again. If it still doesn’t, the log now says why — send Drag Diagnostics."
        case .relaunchRequired:
            return "Navigator’s own drag state is cleared, but macOS still has a finished drag registered as in flight. Nothing Navigator can do clears that, so dragging will keep failing until Navigator is relaunched."
        case .cannotTell:
            return "Navigator’s drag state has been cleared. Whether macOS is still holding a drag of its own can’t be read on this version of macOS, so if dragging is still broken, relaunching is the fix."
        }
    }
}

// MARK: - Drag diagnostics dump

/// Everything about the drag subsystem's live state, in one clipboard-sized report.
///
/// Written to be pasted into a conversation with someone who cannot touch the machine — which
/// is the actual constraint this exists under. So: no interactive follow-up, no "check whether
/// X"; every observable that the last three rounds of this bug turned on is in here, including
/// the ones whose value is "cannot tell".
struct DragDiagnosticsSnapshot {
    var appVersion = ""
    /// The running-vs-installed comparison in full (see RunningBuildRules.describe) — first,
    /// because a report from a stale binary describes code that no longer exists.
    var buildComparison = ""
    var buildIsStale = false
    /// The source of a session the ledger still believes is open; nil when idle.
    var sessionInFlight: String?
    var sessionsOpened = 0
    var refusals = 0
    var leaksReported = 0
    var isDragActive = false
    /// How long ago that lock was last written, when it is known. A `true` written seconds ago is
    /// a live drag; the same `true` written twenty minutes ago is a stuck lock, and the whole
    /// value of the field is telling those two apart.
    var isDragActiveAge: TimeInterval?
    var springState = ""
    var mouseUpWatches = ""
    var keepAliveHeld = 0
    var lastSessionSequence: Int?
    /// nil means the private AppKit registry could not be read — a real and distinct answer.
    var appKitHoldsLastSession: Bool?
    var pressedMouseButtons = 0
    var logTail: [String] = []
}

enum DragDiagnosticsReport {
    /// Enough lines to hold a whole failed drag and the healthy ones before it, few enough to
    /// paste into a message without being trimmed.
    static let logTailLimit = 40

    /// The drag-relevant tail of the dev log. Filtered rather than dumped whole because the
    /// same log carries Imagen batches and network polling, and a report that has to be
    /// scrolled past is a report that gets skimmed.
    static func dragLines(from log: String, limit: Int = logTailLimit) -> [String] {
        let keys = ["drag", "drop", "spring", "tear-off", "transfer", "build"]
        let hits = log.split(separator: "\n", omittingEmptySubsequences: true).filter { line in
            let l = line.lowercased()
            return keys.contains { l.contains($0) }
        }
        return hits.suffix(limit).map(String.init)
    }

    static func text(_ s: DragDiagnosticsSnapshot) -> String {
        var out = ["Navigator drag & drop diagnostics"]
        out.append("app version: \(s.appVersion)")
        out.append("build: \(s.buildComparison)")
        if s.buildIsStale {
            // Stated as a warning and not just a fact: every other line below describes a
            // binary that is not the one on disk, and a diagnosis made against the wrong
            // source is worse than no diagnosis.
            out.append("WARNING: this report comes from a STALE running build — relaunch and reproduce before trusting anything below")
        }
        out.append("session in flight: \(s.sessionInFlight ?? "none")")
        out.append("sessions opened this process: \(s.sessionsOpened), refusals: \(s.refusals), leaks reported: \(s.leaksReported)")
        let lockAge = s.isDragActiveAge.map { ", last written \(RunningBuildRules.age($0)) ago" } ?? ""
        out.append("isDragActive (file list lock): \(s.isDragActive)\(lockAge)")
        out.append("spring loader: \(s.springState)")
        out.append("mouse-up watches: \(s.mouseUpWatches)")
        out.append("drag source keep-alive holding: \(s.keepAliveHeld) view(s)")
        out.append("pressed mouse buttons: \(s.pressedMouseButtons)")
        let seq = s.lastSessionSequence.map(String.init) ?? "none"
        switch s.appKitHoldsLastSession {
        case .some(true):
            out.append("AppKit registry: STILL HOLDS drag \(seq) as in flight — this process is wedged, relaunch is the only fix")
        case .some(false):
            out.append("AppKit registry: no in-flight drag (last session \(seq) was retired normally)")
        case nil:
            out.append("AppKit registry: cannot tell — NSCoreDragManager could not be read on this macOS (last session \(seq))")
        }
        out.append("")
        out.append("last \(s.logTail.count) drag-related log line(s):")
        out.append(contentsOf: s.logTail)
        return out.joined(separator: "\n") + "\n"
    }
}

// MARK: - Shared folder index (.navigator)
//
// A share costs ~89 ms per file for size/date — one network round trip each, and no macOS
// API batches it (see PERFORMANCE.md). But the ANSWER is the same for everyone on the team,
// so one person paying 59 s for artSource can spell it for everybody: 669 entries land in a
// 56 KB file that reads back in 1.2 s. Measured 51x.
//
// The safety property that makes this usable on a drive full of Windows users who have never
// heard of Navigator: THE INDEX NEVER DECIDES WHAT EXISTS. Presence always comes from a live
// readdir, which is free. The index only supplies attributes for names that readdir already
// confirmed. So a file someone added is simply unindexed and gets fetched; a file someone
// deleted has an entry nobody ever looks up. A stale index cannot invent or hide anything.
//
// The residual gap is a file edited IN PLACE — same name, new size. maxAge bounds how long a
// wrong size can survive, and visible-rows-first re-fetches whatever is actually on screen,
// so anything you look at is corrected from the server regardless.
enum ShareIndexRules {
    static let version = 3   // v3 separates fullSweptAt from dirMtime; older files are rewritten
    /// One hidden directory at the volume root rather than a file in every folder: the same
    /// read cost, one place to exclude from Perforce or delete. (Thumbs.db, the convention
    /// this follows, is 469 KB per folder; an index of 669 entries is 56 KB.)
    static let directoryName = ".navigator"
    /// How long an entry may be trusted for a file that still exists under the same name.
    static let maxAge: TimeInterval = 7 * 24 * 3600
    /// Never parse more than this from a shared location written by other machines.
    static let maxBytes = 8 << 20
    /// Below this an index isn't worth a round trip — readdir plus a few stats is cheaper.
    static let minEntriesToWrite = 40

    /// Stable filename for a folder, keyed on its path relative to the volume root so the
    /// index survives the share being mounted at a different point (/Volumes/Games vs
    /// Games-1, or a coworker's own mount name).
    static func filename(forRelative rel: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325            // FNV-1a, 64-bit
        for b in Array(rel.utf8) {
            h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3   // FNV-64 prime; grouped in 4s so the
                                                           // digit count is checkable at a glance
        }
        // String(format: "%016llx", h) mangles the top bits of a Swift UInt64 passed as a C
        // variadic — deterministic, so it still round-trips, but it threw away 24 bits of the
        // hash and that much collision resistance. Format it directly instead.
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex + ".json"
    }

    /// Split a live listing against what the index knows. Names the index has are free; names it
    /// doesn't are the only ones needing a round trip. This is what makes repair incremental:
    /// readdir hands us the truth about which files exist at no cost, so a folder where someone
    /// added three files costs three stats to repair, not 669.
    ///
    /// Names the index has but the listing doesn't are simply not carried forward — that is how
    /// deletions leave the index, without needing to be detected.
    static func repairPlan(liveNames: [String], indexedNames: Set<String>)
        -> (carryForward: [String], mustStat: [String]) {
        var carry: [String] = [], stat: [String] = []
        for n in liveNames {
            if indexedNames.contains(n) { carry.append(n) } else { stat.append(n) }
        }
        return (carry, stat)
    }

    /// An index is worth reading if we wrote the format and it isn't ancient.
    /// `fullSweptAt` is when every entry was last read from the server, NOT when the file was last
    /// touched. Incremental repairs deliberately do not advance it: carrying it forward is what
    /// guarantees a full sweep eventually happens, which is the only thing that catches a file
    /// edited IN PLACE (same name, same directory mtime, different size). Without that
    /// distinction an actively-changing folder would be patched forever and never re-read.
    static func isUsable(version v: Int, savedAt: Double, now: Double) -> Bool {
        v == version && now - savedAt < maxAge && savedAt <= now + 60   // tolerate small clock skew
    }

    /// Split the live listing into "the index can answer this" and "must be fetched".
    /// liveNames is the truth; indexedNames is whatever the file happened to contain.
    static func partition(liveNames: [String], indexedNames: Set<String>)
        -> (fromIndex: [String], mustFetch: [String]) {
        var fromIndex: [String] = [], mustFetch: [String] = []
        for n in liveNames {
            if indexedNames.contains(n) { fromIndex.append(n) } else { mustFetch.append(n) }
        }
        return (fromIndex, mustFetch)
    }

    /// Is the index complete enough that fetching the few names it missed beats re-sweeping the
    /// whole folder? A handful of new files is worth a handful of round trips; an index that only
    /// knows a third of the folder is not worth 400 individual fetches.
    static func coversEnoughToSkipSweep(fromIndex: Int, total: Int) -> Bool {
        total > 0 && Double(fromIndex) / Double(total) >= 0.8
    }

    /// Rewrite when there is nothing there, when what's there is stale, or when the folder
    /// changed. Not on every visit — that would put a 5 s write on the share per user per look.
    static func shouldWrite(existingSavedAt: Double?, now: Double, dirChanged: Bool, entryCount: Int) -> Bool {
        guard entryCount >= minEntriesToWrite else { return false }
        guard let saved = existingSavedAt else { return true }
        return dirChanged || (now - saved) > maxAge / 2
    }

    /// Does the index need rebuilding in the background after we've already shown its contents?
    ///
    /// The trigger is the folder's own mtime, and ONLY that: adding or removing a file bumps it,
    /// so it detects exactly the changes an index can get wrong about which files exist.
    ///
    /// Deliberately NOT "the live listing had names the index lacks". That looks like a sensible
    /// second trigger and is a trap: the index is written from the enumerator, which filters
    /// DOS-hidden files, while the live listing comes from readdir, which only filters dot-names.
    /// On a Windows-authored share those two never agree (measured 670 vs 672 on artSource —
    /// Thumbs.db and desktop.ini), so that condition is permanently true and would rebuild the
    /// whole folder in the background on EVERY visit, forever.
    static func needsBackgroundRefresh(indexDirMtime: Double?, actualDirMtime: Double?) -> Bool {
        guard let a = actualDirMtime, let i = indexDirMtime else { return false }
        return abs(a - i) > 1     // whole-second resolution over SMB
    }
}

// MARK: - Share URLs in shared files

enum ShareURLRules {
    /// Strip the user (and any password) from a share URL.
    ///
    /// The mount table reports `//alice@fileserver.example.com/Games`, so a mount URL derived
    /// from it carries whose account it was. Favorites get EXPORTED and handed to coworkers — a
    /// file that tells their Mac to authenticate as someone else is both a small privacy leak and
    /// a support call, because NetFS will try that account and fail. Sanitizing here makes it a
    /// rule rather than an accident of which dialog happened to create the favorite.
    static func withoutUser(_ raw: String) -> String {
        guard var c = URLComponents(string: raw), c.user != nil || c.password != nil else { return raw }
        c.user = nil
        c.password = nil
        return c.string ?? raw
    }
}

// MARK: - Why a mount failed

/// NetFSMountURLSync reports POSIX errno values. Telling a coworker "check the address and that
/// you're on the VPN" for every failure is a guess that makes them doubt the part they got right —
/// and on these shares the VPN is the usual culprit, so it's worth naming precisely.
/// A network folder that hangs because macOS is stuck trying to mount it, not because the share is
/// down.
///
/// Measured on a real domain share: /Volumes/Games listed instantly while /Volumes/Games/artSource
/// hung a plain `ls` indefinitely, with a mount_url helper for that exact path running for five and
/// a half minutes and never producing a mount. Those subfolders are DFS links — listing the parent
/// makes macOS auto-mount each one, and a referral whose target is unreachable simply never returns.
///
/// This matters because the existing "isn't responding" panel offered to RECONNECT THE SHARE, and
/// the share was never the problem: reconnecting a healthy parent does nothing for a wedged child.
/// The stuck helper has to be cancelled instead.
enum StuckMountRules {
    /// PIDs of mount helpers wedged on `path`, parsed from `ps -Ao pid=,command=` output.
    ///
    /// Matched on the MOUNTPOINT argument, which is the last path on the line, rather than anywhere
    /// in the command: the same line also carries the smb:// source, and matching that would let a
    /// helper working on a different mountpoint of the same share be killed.
    static func wedgedPIDs(psOutput: String, mountPoint path: String) -> [Int32] {
        var out: [Int32] = []
        let target = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !target.isEmpty, target != "/" else { return [] }
        for line in psOutput.split(separator: "\n") {
            let text = String(line)
            guard text.contains("mount_url") || text.contains("mount_smbfs") else { continue }
            // The mountpoint is the trailing argument. Compared whole so /Volumes/Games never
            // matches a helper for /Volumes/Games Extra.
            guard text.hasSuffix(" " + target) || text.hasSuffix("\t" + target) else { continue }
            let head = text.trimmingCharacters(in: .whitespaces)
            let pidText = head.prefix(while: { $0.isNumber })
            if let pid = Int32(pidText), pid > 1 { out.append(pid) }
        }
        return out
    }

    /// What to tell someone whose folder will not open, given whether a helper is wedged on it.
    static func explain(name: String, wedged: Bool) -> (title: String, detail: String, action: String?) {
        if wedged {
            // The copy here was WRONG in the first version and the correction is the point of this
            // comment. It said cancelling "releases the folder". It does not: SIGKILLing the helper
            // was measured, and macOS spawned a fresh automount within seconds of anything touching
            // the path again. Cancelling stops the wedged attempt; it cannot make an unreachable
            // server answer. So the honest action is to stop trying AND leave the folder alone.
            return ("“\(name)” points at a server that isn’t answering",
                    "The drive itself is fine. This folder is a link to another server, and that "
                    + "server hasn’t responded — so macOS keeps trying to connect and anything "
                    + "touching the folder waits with it. Leaving it alone is the fix until that "
                    + "server is back. No files are affected.",
                    "Stop Trying & Go Up")
        }
        return ("“\(name)” isn’t responding",
                "The network drive stopped answering. Reconnecting drops the stuck connection and "
                + "mounts the share again.",
                nil)
    }
}

enum MountFailureRules {
    enum Cause: Equatable { case unreachable, credentials, noSuchShare, cancelled, other }

    static func cause(errno rc: Int32) -> Cause {
        switch rc {
        // The server never answered. Off-VPN, this is what you get.
        case ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH, ETIMEDOUT, ECONNREFUSED, ECONNABORTED:
            return .unreachable
        case EAUTH, EACCES, EPERM:                      return .credentials
        case ENOENT, ENODEV:                            return .noSuchShare
        case ECANCELED:                                 return .cancelled
        default:                                        return .other
        }
    }

    /// NetFS's way of saying "that share is already mounted".
    ///
    /// It comes back as a FAILURE — rc=EEXIST with no mountpoint attached (measured against
    /// both live shares: rc=17 in ~0.8s) — so a caller that only looks at the mountpoint
    /// reads "already connected" as "couldn't connect", and either beeps at a drive that is
    /// sitting right there or puts up a connection-failed alert. It is a success; the
    /// mountpoint has to be read back out of the mount table.
    static func isAlreadyMounted(errno rc: Int32) -> Bool { rc == EEXIST }

    /// Is this failure one a human could actually answer? Only then is it worth a second
    /// mount attempt with UI.
    ///
    /// The silent attempt comes first because NetFS with AllowUI puts up its
    /// "Connecting to…"/authenticate window even when the keychain already holds the
    /// password — the Finder-looking dialog that appeared on every single reconnect.
    /// A server that is simply unreachable, or a share name that doesn't exist, cannot be
    /// fixed by typing: retrying those with UI only spends a second full SMB timeout before
    /// showing a dialog we can write better ourselves.
    static func needsUI(errno rc: Int32) -> Bool {
        switch cause(errno: rc) {
        case .credentials: return true
        // NetFS's own error codes (password expired, no supported auth mechanism, a bare
        // server URL that needs a share picked) all land here, and every one of them is
        // answerable.
        case .other:       return true
        case .unreachable, .noSuchShare, .cancelled: return false
        }
    }

    /// Headline and detail for the alert. `host` is shown so it's obvious which server is meant.
    static func message(for cause: Cause, host: String) -> (title: String, detail: String)? {
        switch cause {
        case .unreachable:
            return ("Can’t reach “\(host)”",
                    "The server didn’t respond. If this share is only available over the VPN, "
                    + "connect the VPN and try again — your address and password are probably fine.")
        case .credentials:
            return ("“\(host)” refused those credentials",
                    "The server was reachable, so the VPN is working. Check the username and "
                    + "password — use your normal work login, not a personal account.")
        case .noSuchShare:
            return ("“\(host)” has no share by that name",
                    "The server answered but doesn’t recognise the share. Check the part of the "
                    + "address after the server name.")
        case .cancelled:
            return nil          // the user closed the sheet on purpose; saying anything is noise
        case .other:
            return ("Couldn’t connect to “\(host)”",
                    "Check the address, and that you’re on the VPN if this share needs it.")
        }
    }
}

// MARK: - Team drives, pasted as text

/// Setting a coworker up used to mean opening Add Network Drive once per share and typing an
/// address each time. This parses the whole list in one paste, so onboarding is: connect the VPN,
/// paste, done.
enum TeamDrivesRules {
    struct Drive: Equatable { let label: String; let url: String }

    /// Accepted per line, blanks and `#` comments ignored:
    ///   smb://server/share
    ///   G Drive = smb://server/share
    /// Usernames are stripped (see ShareURLRules) so a list shared between people never tells
    /// someone else's Mac to authenticate as the author.
    static func parse(_ text: String) -> [Drive] {
        var out: [Drive] = []
        var seen = Set<String>()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var label: String?
            // "Label = url" — split on the FIRST '=' only, so a '=' inside the URL survives.
            if let eq = line.firstIndex(of: "="), line[line.startIndex..<eq].contains("://") == false {
                let l = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
                let r = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !l.isEmpty, !r.isEmpty { label = l; line = r }
            }
            let url = ShareURLRules.withoutUser(line)
            guard let scheme = url.split(separator: ":").first?.lowercased(),
                  ["smb", "afp", "cifs"].contains(String(scheme)),
                  url.contains("://"),
                  let u = URLComponents(string: url), (u.host?.isEmpty == false)
            else { continue }
            guard seen.insert(url.lowercased()).inserted else { continue }
            out.append(Drive(label: label ?? shareName(from: url), url: url))
        }
        return out
    }

    /// Last path component of the share, which is what people call the drive ("Games", "data").
    static func shareName(from url: String) -> String {
        let afterScheme = url.components(separatedBy: "://").last ?? url
        let parts = afterScheme.split(separator: "/").map(String.init)
        return parts.count > 1 ? parts[parts.count - 1] : (parts.first ?? url)
    }
}

// MARK: - Exporting a converted copy, without eating the original

enum ExportRules {
    /// Formats "Save a Copy As" offers. WebP is encoded by the external `cwebp` because
    /// CGImageDestination on macOS can DECODE WebP but not write it (verified: it is absent from
    /// CGImageDestinationCopyTypeIdentifiers()).
    enum Format: String, CaseIterable {
        case png, webp, jpeg, tiff, heic

        var ext: String { self == .jpeg ? "jpg" : rawValue }
        var menuTitle: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }
        /// Nil means there is no ImageIO encoder and an external tool is required.
        var uti: String? {
            switch self {
            case .png:  return "public.png"
            case .jpeg: return "public.jpeg"
            case .tiff: return "public.tiff"
            case .heic: return "public.heic"
            case .webp: return nil
            }
        }
        var isLossy: Bool { self == .jpeg || self == .heic || self == .webp }
        /// JPEG is the only one here that cannot carry alpha at all.
        var dropsAlpha: Bool { self == .jpeg }
    }

    /// Two paths pointing at the same file. Compared case-insensitively and in canonical
    /// composed form, because macOS filesystems are usually case-insensitive and APFS/HFS hand
    /// back decomposed unicode — "Ü" typed in a save panel is not the same bytes as the "Ü" in
    /// a directory listing, and a naive == would call them different and happily overwrite.
    static func isSameFile(_ a: String, _ b: String) -> Bool {
        a.precomposedStringWithCanonicalMapping.lowercased()
            == b.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Default name for the copy. Never the source's own name: exporting a PNG as a PNG used to
    /// pre-fill the original's exact filename, so one Return overwrote the original.
    /// `taken` reports whether a candidate already exists in the destination folder.
    static func suggestedName(sourceName: String, format: Format, taken: (String) -> Bool) -> String {
        let base = (sourceName as NSString).deletingPathExtension
        let first = "\(base).\(format.ext)"
        // A different extension is already distinct from the source, so only guard the collision.
        if !taken(first), !isSameFile(first, sourceName) { return first }
        var i = 2
        while true {
            let candidate = "\(base) \(i).\(format.ext)"
            if !taken(candidate), !isSameFile(candidate, sourceName) { return candidate }
            i += 1
            if i > 999 { return "\(base) copy.\(format.ext)" }   // pathological folder; still safe
        }
    }
}

// MARK: - Adobe generative credits

/// Navigator can spend Adobe generative credits (Firefly Generative Upscale is a *standard*
/// feature at 1 credit each). On an enterprise plan without premium access that allowance is
/// **25 a month** — measured, not assumed: the account page read "0/25 credits left, next reset
/// August 30, 2026". Three exploratory calls is over a tenth of a month, which is how this app
/// once drained a user's entire allowance without asking.
///
/// So: count every generative call Navigator issues, and never issue one without saying what it
/// costs and what has already been spent.
enum AdobeCreditRules {
    /// What Adobe charges for the things Navigator can trigger. Firefly Generative Upscale is
    /// absent from Adobe's premium table and from its "does not use credits" list, which makes it
    /// a standard feature — "1 credit per generation".
    static let fireflyUpscaleCost = 1

    /// The line shown before spending. Navigator knows what IT has spent exactly; it does not
    /// know Adobe's live balance and must never imply otherwise.
    static func confirmation(count: Int, cost: Int, spentThisCycle: Int,
                             allowance: Int) -> (title: String, detail: String) {
        let credits = count * cost
        let unit = credits == 1 ? "credit" : "credits"
        let title = count == 1
            ? "Upscaling this image uses \(credits) Adobe \(unit)."
            : "Upscaling \(count) images uses \(credits) Adobe \(unit)."
        var lines: [String] = []
        if spentThisCycle > 0 {
            lines.append("Navigator has spent \(spentThisCycle) this cycle" +
                         (allowance > 0 ? " of your \(allowance)." : "."))
            if allowance > 0, spentThisCycle + credits > allowance {
                lines.append("That would take you past your allowance.")
            }
        } else if allowance > 0 {
            lines.append("Your monthly allowance is \(allowance).")
        }
        lines.append("Navigator only counts its own spending, so check Adobe for the real balance.")
        return (title, lines.joined(separator: " "))
    }
}

// MARK: - Layerize batches

enum LayerizeBatchRules {
    /// How many layerize calls run at once.
    ///
    /// Each call takes 50–180 s, so a serial batch of ten is 8–30 minutes. fal.ai does not
    /// document a per-key concurrency limit, so this is deliberately conservative: three is a
    /// 3x speed-up while staying well clear of anything that looks like hammering, and a 429
    /// would cost a paid generation to discover. Raise it only with evidence.
    static let maxConcurrent = 3

    /// Output folder names for a batch, with collisions broken.
    ///
    /// The folder is derived from the file's base name, so `key.png` and `key.jpg` in the SAME
    /// directory both want `key_Layers`. Serially that silently mixed two images' layers into one
    /// folder; in parallel it is a race — two threads creating the same directory and writing
    /// files whose names can collide. Both get a distinct folder instead.
    ///
    /// `exists` reports whether a candidate is already taken on disk, so a re-run beside an
    /// unrelated folder of the same name doesn't clobber it. Input order is preserved.
    static func dedupedOutputDirs(_ proposed: [String], exists: (String) -> Bool = { _ in false }) -> [String] {
        var used = Set<String>()
        var out: [String] = []
        for p in proposed {
            if !used.contains(p), !exists(p) {
                used.insert(p); out.append(p); continue
            }
            // "…_Layers" -> "…_Layers 2", " 3", … Matches the Keep Both convention elsewhere.
            var i = 2
            var candidate = "\(p) \(i)"
            while used.contains(candidate) || exists(candidate) {
                i += 1
                candidate = "\(p) \(i)"
            }
            used.insert(candidate); out.append(candidate)
        }
        return out
    }

    /// Progress text for a parallel run. "3 of 10" is a lie when three are in flight at once.
    static func progressLabel(done: Int, running: Int, total: Int, current: String?) -> String {
        if total == 1 {
            return "Layerizing \(current ?? "image") — this takes a minute or two"
        }
        var s = "Layerizing \(done) of \(total) done"
        if running > 0 { s += ", \(running) running" }
        return s
    }
}

// MARK: - What a Layerize failure actually means

enum LayerizeErrorRules {
    /// Turn fal's 422 body into an honest explanation.
    ///
    /// The old text asserted one cause for every 422: "it rejects a tier that overshoots the input,
    /// and also anything below its ~1K output floor". A real batch disproved that. Five images,
    /// byte-for-byte comparable — all 632×791, all `auto_1K`, all 712–741 KB — and three produced
    /// 5, 9 and 11 layers while two were refused. Same size, same tier, same everything
    /// structural. The tier was never the problem, and saying so sent the user looking in the
    /// wrong place.
    ///
    /// fal says which it is, in the body. When it reports that the image "could not be processed
    /// for layer decomposition", that is the model declining THAT PICTURE — not a parameter fault
    /// — and it is worth saying plainly, because the fix is to retry or use a different image, not
    /// to fiddle with settings.
    /// fal's OWN message, extracted from the error body.
    ///
    /// Classifying on the whole body is a trap: fal echoes the request back inside `"input"`, so
    /// `"enable_safety_checker":true` puts the word "safety" in every single error — which made
    /// worthRetrying() treat every refusal as a safety rejection and skip the retry entirely.
    /// Only the `msg` field carries fal's verdict, so only that is classified.
    static func falMessage(in body: String) -> String {
        guard let r = body.range(of: #""msg"\s*:\s*"(([^"\\]|\\.)*)""#, options: .regularExpression) else {
            // No msg field — fall back to the body with the echoed request removed, so the same
            // trap can't reappear through a different key.
            if let inputAt = body.range(of: #""input"\s*:"#, options: .regularExpression) {
                return String(body[body.startIndex..<inputAt.lowerBound])
            }
            return body
        }
        return String(body[r])
    }

    static func explain422(body: String, tier: String) -> String {
        let b = falMessage(in: body).lowercased()
        if b.contains("could not be processed for layer decomposition") {
            return " — the Layerize model couldn’t decompose this particular image. "
                 + "Nothing is wrong with its size or format: images identical in size and tier "
                 + "succeed alongside it. Retrying sometimes works; otherwise the picture itself "
                 + "is one the model won’t split."
        }
        if b.contains("image_size") || b.contains("resolution") || b.contains("too small") || b.contains("too large") {
            return " — Layerize refused the \(tier) tier for this input. It rejects a tier that "
                 + "overshoots the image, and anything below its ~1K output floor."
        }
        if b.contains("safety") || b.contains("nsfw") || b.contains("flagged") {
            return " — fal's safety checker flagged this image, which is a content decision on "
                 + "their side rather than anything about the file."
        }
        return " — Layerize rejected the request. fal's own message follows."
    }

    /// The next resolution tier up, for escalating a stubborn refusal.
    ///
    /// Repeating an identical request catches a TRANSIENT refusal — SF2_Pearl was declined once and
    /// then succeeded unchanged. It cannot help a DETERMINISTIC one, so a second retry asks for a
    /// different output size instead, which changes what the model is being asked to do. Returns
    /// nil at the top tier, where there is nothing left to escalate to.
    static func nextTierUp(_ tier: String) -> String? {
        switch tier {
        case "auto_1K":   return "auto_1.5K"
        case "auto_1.5K": return "auto_2K"
        default:          return nil
        }
    }

    /// Is this failure worth one automatic retry?
    ///
    /// A model that declines a picture may well accept it on a second pass — the refusal is not a
    /// parameter error, so the same request can legitimately produce a different answer. A tier or
    /// safety rejection will not change, and retrying those only spends money.
    static func worthRetrying(body: String) -> Bool {
        let b = falMessage(in: body).lowercased()
        if b.contains("safety") || b.contains("nsfw") || b.contains("flagged") { return false }
        if b.contains("image_size") || b.contains("too small") || b.contains("too large") { return false }
        return b.contains("could not be processed for layer decomposition")
    }
}

// MARK: - Rebuilding a layered document from a _Layers folder

/// The arithmetic for putting Layerize's output back together as a real layered document.
///
/// Verified by reconstructing SF4_Blue from nothing but `_layers.json`: 86% of pixels within
/// 8/255 of the original and a mean difference of 6.6/255, the residual being resampling noise.
///
/// THE TRAP: a layer's PNG is NOT the size of its bounding box. Each element is rendered at its
/// own resolution — measured factors of 1.00x, 1.73x, 2.73x and 2.21x within a single image — which
/// is what fal means by "preserving each element's aspect ratio". A plugin that drops each PNG at
/// (left, top) at native size puts everything 2-3x too big and overlapping. The bounding box is
/// both the POSITION and the TARGET SIZE.
enum LayerAssemblyRules {
    /// Percentage to scale a layer by so it fills its bounding box. Photoshop's
    /// ArtLayer.resize takes percentages, not pixels.
    static func scalePercent(pngSide: Int, boxSide: Int) -> Double {
        guard pngSide > 0, boxSide > 0 else { return 100 }
        return Double(boxSide) / Double(pngSide) * 100
    }

    /// Width and height scale separately only if the render's aspect drifted from the box's.
    /// Reported so a caller can notice, because a big divergence means the bbox and the render
    /// disagree and the result will look stretched.
    static func aspectDrift(pngW: Int, pngH: Int, boxW: Int, boxH: Int) -> Double {
        guard pngW > 0, pngH > 0, boxW > 0, boxH > 0 else { return 0 }
        let a = Double(pngW) / Double(pngH), b = Double(boxW) / Double(boxH)
        return abs(a - b) / max(a, b)
    }

    /// Measured drift on real output was under 1%; anything past this is worth flagging rather
    /// than silently stretching a layer.
    static let maxTolerableDrift = 0.05

    /// Is a bounding box usable — inside the canvas and not degenerate?
    static func boxIsSane(_ box: [Int], canvasW: Int, canvasH: Int) -> Bool {
        guard box.count == 4 else { return false }
        let (l, t, r, b) = (box[0], box[1], box[2], box[3])
        return r > l && b > t && l >= 0 && t >= 0 && r <= canvasW && b <= canvasH
    }

    /// Name for the rebuilt document, beside the _Layers folder it came from.
    /// "Foo_Layers" -> "Foo_assembled.psd", so it never collides with the source image.
    static func assembledName(fromLayersFolder folder: String) -> String {
        var stem = folder
        if stem.hasSuffix("_Layers") { stem = String(stem.dropLast("_Layers".count)) }
        // A deduped folder ("Foo_Layers 2") keeps its distinguishing suffix.
        stem = stem.trimmingCharacters(in: .whitespaces)
        return stem.isEmpty ? "assembled.psd" : "\(stem)_assembled.psd"
    }

    /// True when the script produced a PSD but some layers didn't make it in. The rebuild succeeded,
    /// so it must not be reported as a failure — but staying silent would hand back a document that
    /// is quietly incomplete, which is how the old zero-byte-download bug went unnoticed for a whole
    /// batch. The script spells MISSING/FAILED in its OK line precisely so this can spot it.
    static func isPartial(_ message: String) -> Bool {
        message.contains("MISSING ") || message.contains("FAILED ")
    }
}

/// Naming the elements for Layerize, with a vision model's help.
///
/// fal's `prompt` decides WHAT comes back, but writing a good one means looking at the image and
/// listing its parts — which is exactly what the restyle path already asks Gemini to do. Measured on
/// a character: an empty prompt returned 4 blobs, the same image with a 16-element list returned 16
/// named parts at 0.64% uncovered, and the analysis cost $0.0007 — a rounding error next to the
/// 2-3 cents of the layerize call itself.
/// Ordering for version-manager directory names like "v26.5.0".
///
/// Exists because sorting those names as strings puts "v9.0.0" above "v26.5.0", so a machine with
/// both installed would be handed a years-old node. The same mistake was shipped in the Photoshop
/// script, where it surfaced as "Node.js isn't installed" on a machine running node 26.
enum NodeVersion {
    static func parts(_ name: String) -> [Int] {
        let trimmed = name.hasPrefix("v") || name.hasPrefix("V")
            ? String(name.dropFirst()) : name
        let fields = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        return (0..<3).map { i in
            i < fields.count ? (Int(fields[i].prefix(while: \.isNumber)) ?? 0) : 0
        }
    }

    /// True when `a` sorts before `b` in a newest-first list.
    static func isDescending(_ a: String, _ b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<3 where x[i] != y[i] { return x[i] > y[i] }
        // Equal numerically: fall back to the name so the sort stays deterministic.
        return a > b
    }
}

enum LayerizeElementRules {
    /// fal returns "the base image followed by up to 16 separated layers", so 16 is a hard ceiling.
    /// A longer list is not an error — the tail is simply never returned — so it is trimmed here and
    /// the caller is told what was dropped rather than left wondering where the hat went.
    static let maxElements = 16

    /// Asks for three granularities in one call, because the useful level depends on the image and
    /// on the job: a slot UI is already well served by the model's own "major elements", while a
    /// character for animation needs left and right split apart.
    ///
    /// The FIRST version of this prompt just asked for elements "ordered back to front (background
    /// first)" and produced lists that were half scenery — a slot mockup came back as "sky and sun,
    /// mountains and forests, lake and shore, boat hull and floor" plus the UI, spending four of ten
    /// slots on a background that layerize returns intact anyway. The prompt now states the budget
    /// and the fact that silence keeps something merged, which is the whole trick: naming nothing is
    /// how you keep the background whole. Measured on the same image, medium went from 10 elements
    /// (4 wasted) to 8 with none wasted, and `fine` fell from 25 to 15 — under the ceiling without
    /// truncating anything.
    /// Ask for JOBS, not sizes.
    ///
    /// Two earlier versions of this failed in instructive ways. The first ordered elements "back to
    /// front (background first)" and spent four of ten slots on sky, mountains, lake and boat hull —
    /// scenery that layerize hands back in the base for free. The second fixed that but kept fixed
    /// COUNTS ("coarse 3-6, medium 8-14, fine up to 16"), so an image with three genuinely useful
    /// pieces got padded to reach the number: a fish symbol came back with "pectoral fin" at the
    /// medium tier, which nobody wanted. The counts were the bug — a granularity slider is the wrong
    /// abstraction because usefulness is not a quantity, it is a purpose.
    ///
    /// So the model now proposes named JOBS suited to what it actually sees. The same fish symbol
    /// offers "structure" (frame / bass / splash — matching how these symbols are split by hand) and
    /// separately "animate" (jaw, fins, body). The pectoral fin is not junk, it was simply filed
    /// under the wrong job. A plain frame offers one element and says so instead of inventing five.
    static let systemPrompt = """
        You plan how to split a flat 2D image into layers for a game-art pipeline.

        HOW THE TOOL WORKS, and why it constrains you:
        - It returns a BASE image plus AT MOST 16 named elements.
        - Anything you do NOT name stays merged in the base, and the base is kept as the bottom
          layer. So the leftover background is ALWAYS returned — you never need to name it just to
          keep it.
        - Name a background ONLY when it is a distinct designed plate someone would reuse or replace
          on its own (a symbol's backdrop, a parallax band), NOT when it is ambient scenery sitting
          behind UI.

        Propose 1-4 DIFFERENT ways to split THIS image, each aimed at a real job someone would do:
         - structure: the reusable compositional pieces (backdrop / frame / subject / UI chrome)
         - extract:   lift the interactive or foreground items off a scene, leaving the scene whole
         - animate:   split ONE subject into moving parts (limbs, jaw, fins, held objects)
         - parallax:  split a background plate into depth bands
         - inventory: one layer per repeated item in a sheet or grid
        Only propose options that make sense for what you actually see. ONE option is a perfectly
        good answer.

        PICK ONE LEVEL PER THING inside any single option. Never list a container and its own parts
        together — "ornate frame with corner gems" and "top left corner gem" cannot both be layers,
        because the gems are inside the frame. The same goes for a subject: either the whole dragon
        as one layer, or its head, jaw, claw and tail as several, never both.

        RULES:
        - NEVER pad a list to reach a number. Return only elements that genuinely earn their own
          layer. Three good elements beat eight with filler. Do not invent sub-parts nobody asked
          for.
        - Order elements MOST VALUABLE FIRST; the list is truncated at 16.
        - If a job would need more than 16 elements, still give the best 16 and set "warning".

        Return STRICT JSON only, no prose, no markdown fence:
        {
          "kind": "<what this image is, short>",
          "options": [
            {"label": "<3-5 words>", "job": "structure|extract|animate|parallax|inventory",
             "why": "<one short line>", "elements": ["..."], "warning": "<optional>"}
          ]
        }
        Order options best-first for this image.
        """

    struct Option: Equatable {
        var label: String = ""
        var job: String = ""
        var why: String = ""
        var elements: [String] = []
        var warning: String = ""

        /// What the popup shows.
        ///
        /// Counts the BASE. Naming N elements yields N+1 layers, because everything unnamed comes
        /// back merged as the bottom layer — verified in a real run, where a manifest for two named
        /// elements contained z0 (no bounding box) plus the two. Reporting "2 layers" for that made
        /// it look like the background had been missed, when the background was layer one.
        var layerCount: Int { elements.count + 1 }
        var menuTitle: String {
            "\(label.isEmpty ? job : label)  (\(layerCount) layers)"
        }
    }

    struct Plan: Equatable {
        var kind: String = ""
        var options: [Option] = []
    }

    /// A gateway hiccup, not a real refusal — worth retrying rather than reporting.
    ///
    /// Observed in the wild: the vision endpoint answered `AI service HTTP 502: {"error":"Vertex
    /// 502: <!DOCTYPE html>…` mid-session and the dialog gave up on the first try, having spent the
    /// wait and produced nothing.
    static func isTransient(_ error: String) -> Bool {
        let e = error.lowercased()
        for code in ["http 502", "http 503", "http 504", "http 429"] where e.contains(code) { return true }
        for phrase in ["timed out", "timeout", "connection was lost", "network connection",
                       "bad gateway", "temporarily unavailable"] where e.contains(phrase) { return true }
        return false
    }

    /// Something a person can read. The service wraps upstream failures in JSON that contains a whole
    /// HTML error page, which floods the one line of status the dialog has.
    static func friendlyError(_ error: String) -> String {
        if isTransient(error) {
            return "the AI service is busy — try Analyze again in a moment"
        }
        // Cut at the first sign of markup, then cap: nobody needs a stack of HTML in a status line.
        var s = error
        if let r = s.range(of: "<!DOCTYPE") ?? s.range(of: "<html") {
            s = String(s[s.startIndex..<r.lowerBound])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " {}\"\\:,"))
        return s.count > 140 ? String(s.prefix(140)) + "…" : s
    }

    /// Parse the model's reply. Tolerates a ```json fence and surrounding prose, because "STRICT
    /// JSON only" is an instruction, not a guarantee.
    static func parse(_ reply: String) -> Plan? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              start < end else { return nil }
        let json = String(reply[start...end])
        guard let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        func str(_ o: [String: Any], _ k: String) -> String {
            (o[k] as? String ?? "").trimmingCharacters(in: .whitespaces)
        }
        let options: [Option] = (obj["options"] as? [[String: Any]] ?? []).compactMap { o in
            let els = (o["elements"] as? [Any] ?? []).compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !els.isEmpty else { return nil }      // an option that separates nothing is noise
            return Option(label: str(o, "label"), job: str(o, "job"), why: str(o, "why"),
                          elements: els, warning: str(o, "warning"))
        }
        guard !options.isEmpty else { return nil }
        return Plan(kind: str(obj, "kind"), options: options)
    }

    // There is deliberately NO automatic "do everything at once" option here.
    //
    // Merging the proposals in code produced incoherent requests: a dragon symbol came back asking
    // for "Outer gold square frame with corner green gems" AND "Top left corner green gem" as
    // separate layers, plus "Golden dragon head and body" alongside "Lower jaw" and "Body and tail
    // coil". A container and its own parts cannot both be layers, and code cannot tell that gems sit
    // inside a frame — only the model knows that, and substring matching catches just the trivial
    // cases ("bass fish" inside "bass fish body").
    //
    // Asking the MODEL to return a combined option did not work either. It was tried twice, the
    // second time as a required schema field with an explicit container-versus-parts rule, and both
    // times it returned the jobs as alternatives anyway — for a symbol whose two jobs need eight of
    // sixteen slots.
    //
    // So combining is left to the person, who can see the list and edit it. The dialog appends one
    // proposal's elements to another on request, and they resolve the overlap by deleting a line.

    /// Recover the element names from an instruction this class produced, so a second proposal can
    /// be appended to a first. Anything the person typed freehand that isn't in that shape is
    /// treated as one item, which keeps their words rather than discarding them.
    static func elements(inInstruction text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        let marker = "individual layers:"
        let body = t.range(of: marker).map { String(t[$0.upperBound...]) } ?? t
        return body.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Turn a list of element names into the instruction sent as `prompt`.
    ///
    /// "background" is dropped: it is the base image, which layerize returns anyway and which
    /// Navigator discards for a transparent input. Asking for it wastes one of the 16 slots.
    static func instruction(for names: [String]) -> (text: String, dropped: [String]) {
        let usable = names
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "background" }
        let kept = Array(usable.prefix(maxElements))
        let dropped = Array(usable.dropFirst(maxElements))
        guard !kept.isEmpty else { return ("", dropped) }
        return ("Separate these elements out from the image as individual layers: "
                + kept.joined(separator: ", "), dropped)
    }
}

/// Completeness checking for a layerize result.
///
/// fal's API reference states there is no guarantee of coverage, and measurement bears that out: two
/// runs of frame.png with the IDENTICAL prompt left 1.144% and 7.253% of the artwork with no layer
/// covering it, the worse one losing an entire frame rail. A decomposition therefore cannot be
/// trusted, it has to be measured — and measuring is free, local and deterministic, which is more
/// than can be said for anything prompt-based. A generic "separate everything, leave nothing out"
/// prompt was tried and produced no measurable improvement (1.378% vs 1.144%), so it isn't used;
/// what did work was feeding the measured gap back as a coordinate hint.
enum LayerCoverageRules {
    /// Only meaningful when the base was DISCARDED.
    ///
    /// With the base kept, fal's base is a real inpainted background holding everything it didn't
    /// separate, so the composite has no holes and nothing is truly lost — bluebird's boat deck
    /// measured 93% within 32/255 in the very region it was twice claimed to be missing from. It is
    /// only when the base is dropped (a transparent input, whose base is a blank plate) that an
    /// unseparated element actually disappears. That is the one case worth spending a repair call on.
    static func applies(keptBase: Bool) -> Bool { !keptBase }

    /// Repair only when the decomposition is UNAMBIGUOUSLY broken.
    ///
    /// The uncovered fraction turns out to be a weak predictor of whether a retry will help. Measured
    /// on frame.png: a 1.91% run repaired to 1.07% (helped) while a 1.06% run repaired to 1.06%
    /// (gained nothing and cost 139 seconds). Those two are adjacent with opposite outcomes, so a
    /// threshold tuned to sit between them would be fitting a mechanism to four noisy points — the
    /// same error that produced the invented tier ladder. What IS clear is the 7.64% run, which lost
    /// a whole frame rail and repaired to 1.64%, a 4.7x gain.
    ///
    /// So the bar is set where the evidence is unambiguous. Everything below it is reported and left
    /// alone: a 2-minute call is too expensive to spend on a coin flip, and coverage appears in the
    /// log either way so a borderline result can be re-run deliberately.
    static let repairThreshold = 0.05

    static func needsRepair(uncoveredFraction: Double) -> Bool {
        uncoveredFraction > repairThreshold
    }

    /// Two targeted retries at most. Measured on frame.png, each one paid for itself:
    /// 7.64% -> 1.91% -> 1.07% uncovered, at roughly two cents a call, and the second attempt is what
    /// finally filled in the top frame rail. A third was not measured, so it is not taken — and the
    /// strict-improvement guard means the only thing an unlucky roll costs is the call.
    static let maxRepairAttempts = 2

    /// fal's `prompt` accepts `<bbox>left top right bottom</bbox>` in NORMALIZED coordinates. Its own
    /// manifest reports normalized boxes in per-mille (0-1000), so per-mille is the convention used
    /// here — and this exact form recovered a top frame rail that two unprompted runs both lost.
    /// Returns nil for a degenerate box, so a bad measurement can never spend a call.
    /// `userText` is threaded through deliberately: a repair is a whole fresh decomposition, so
    /// dropping the user's element instruction here would hand back a repaired set that no longer
    /// separates what they asked for — a worse result that scores better on coverage.
    static func repairPrompt(gap: [Int], canvasW: Int, canvasH: Int, userText: String? = nil) -> String? {
        guard gap.count == 4, canvasW > 0, canvasH > 0 else { return nil }
        let l = max(0, min(1000, gap[0] * 1000 / canvasW))
        let t = max(0, min(1000, gap[1] * 1000 / canvasH))
        let r = max(0, min(1000, gap[2] * 1000 / canvasW))
        let b = max(0, min(1000, gap[3] * 1000 / canvasH))
        guard r > l, b > t else { return nil }
        return LayerizeRules.composePrompt(userText) + "\n"
             + "The region <bbox>\(l) \(t) \(r) \(b)</bbox> was left out of the previous "
             + "decomposition — return the element occupying it as its own separate layer."
    }

    /// Which attempt to keep. STRICTLY better only: a repair that covers no better must not replace
    /// the original, or a worse roll of the dice gets shipped in exchange for the extra call. The
    /// same prompt measured 1.144% then 7.253%, so this is not hypothetical.
    static func repairIsBetter(original: Double, repaired: Double) -> Bool {
        repaired < original
    }

    /// Did the repair keep what was actually asked for?
    ///
    /// Coverage alone is the wrong test. A repair is a whole fresh decomposition, so it can cover
    /// more of the picture while having separated DIFFERENT things — ask for "gold frame, leaping
    /// bass, water splash", get back a tighter-covering set that merged the fish into the background
    /// and split the frame in four. Adopting that on coverage would silently throw away the request
    /// and look like an improvement in the log.
    ///
    /// Matching is deliberately loose: fal renames freely ("leaping bass" comes back as "Jumping
    /// largemouth bass"), so a requested name counts as kept when any returned name shares a
    /// distinctive word with it. Short words are ignored because "the", "and", "left" match anything.
    static func repairKeptRequestedElements(requested: [String], returned: [String]) -> Bool {
        let wanted = requested
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "background" }
        guard !wanted.isEmpty else { return true }      // nothing specific was asked for

        func keywords(_ s: String) -> Set<String> {
            Set(s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 })
        }
        let returnedWords = returned.reduce(into: Set<String>()) { $0.formUnion(keywords($1)) }
        var kept = 0
        for w in wanted {
            let k = keywords(w)
            // A request with no distinctive word can't be checked; don't punish the repair for it.
            if k.isEmpty || !k.isDisjoint(with: returnedWords) { kept += 1 }
        }
        // Losing more than a third of what was asked for is a different result, not a better one.
        // Integer arithmetic on purpose: two-of-three is 0.6666… and would fail a `>= 0.67` test.
        return kept * 3 >= wanted.count * 2
    }

    /// One line for the log, so a run's completeness is on the record rather than inferred later.
    static func summary(uncoveredFraction: Double) -> String {
        String(format: "coverage %.2f%% uncovered", uncoveredFraction * 100)
    }

    /// A layer ready to be placed: its normalized per-mille box and its decoded pixels.
    struct Placement {
        let normalized: [Int]
        let image: CGImage
        init(normalized: [Int], image: CGImage) {
            self.normalized = normalized
            self.image = image
        }
    }

    /// Long-edge ceiling for the measurement raster, purely a memory bound: two RGBA contexts plus
    /// two masks at fal's maximum 6000x6000 input would be about 360 MB, and three images layerize
    /// concurrently. Below this there is NO resampling at all, which is the point — measuring at
    /// 700px reported 1.06% where the truth was 1.21%, and a check that UNDER-states gaps is biased
    /// in the one direction that matters, since it can skip a repair it should have made.
    static let measureLongEdgeCap = 2500

    /// Fraction of the SOURCE's opaque pixels that no layer covers, plus the bounding box of the
    /// largest connected gap cluster in source-pixel coordinates. Returns nil when the question
    /// doesn't apply — no layers, or a source with no opaque pixels to be missing from.
    ///
    /// Layers are placed by their NORMALIZED boxes against the source's own dimensions, so this never
    /// needs to know what canvas size fal chose. Verified equivalent to what the assembly script
    /// actually builds from `absolute` boxes: 1.21% measured on the real PSD versus 1.21% here.
    static func measure(source: CGImage, layers: [Placement]) -> (fraction: Double, gap: [Int])? {
        guard !layers.isEmpty, source.width > 0, source.height > 0 else { return nil }
        let longEdge = max(source.width, source.height)
        let scale = longEdge > measureLongEdgeCap ? Double(measureLongEdgeCap) / Double(longEdge) : 1.0
        let w = max(1, Int((Double(source.width) * scale).rounded()))
        let h = max(1, Int((Double(source.height) * scale).rounded()))

        func canvas() -> CGContext? {
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let comp = canvas(), let srcCtx = canvas() else { return nil }

        for l in layers {
            guard l.normalized.count == 4 else { continue }
            let x0 = Double(l.normalized[0]) / 1000 * Double(w)
            let y0 = Double(l.normalized[1]) / 1000 * Double(h)
            let x1 = Double(l.normalized[2]) / 1000 * Double(w)
            let y1 = Double(l.normalized[3]) / 1000 * Double(h)
            guard x1 > x0, y1 > y0 else { continue }
            // CoreGraphics' origin is bottom-left; fal's boxes are top-left.
            comp.draw(l.image, in: CGRect(x: x0, y: Double(h) - y1, width: x1 - x0, height: y1 - y0))
        }
        srcCtx.draw(source, in: CGRect(x: 0, y: 0, width: Double(w), height: Double(h)))

        guard let cRaw = comp.data, let sRaw = srcCtx.data else { return nil }
        let c = cRaw.assumingMemoryBound(to: UInt8.self)
        let s = sRaw.assumingMemoryBound(to: UInt8.self)
        var mask = [Bool](repeating: false, count: w * h)
        var gapCount = 0, srcCount = 0
        for p in 0..<(w * h) {
            let i = p * 4 + 3
            guard s[i] > 128 else { continue }       // only where the ORIGINAL has real content
            srcCount += 1
            guard c[i] < 32 else { continue }
            mask[p] = true
            gapCount += 1
        }
        guard srcCount > 0 else { return nil }
        let fraction = Double(gapCount) / Double(srcCount)
        guard gapCount > 0 else { return (0, [0, 0, 0, 0]) }

        // The box handed back is the LARGEST CONNECTED CLUSTER, not the extent of every gap pixel.
        // Measured on a real residual: one box around all 61,153 stray pixels spanned 98.3% of the
        // canvas — "the element occupying the whole image is missing", which is no hint at all. The
        // largest cluster of that same residual was 1.0% of the canvas and held 40% of the pixels.
        // Scattered specks are antialiasing seams; a genuinely missing element is one big blob.
        var seen = [Bool](repeating: false, count: w * h)
        var best = (size: 0, minX: 0, minY: 0, maxX: 0, maxY: 0)
        var queue: [Int] = []
        for start in 0..<(w * h) where mask[start] && !seen[start] {
            seen[start] = true
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            var size = 0, minX = w, minY = h, maxX = 0, maxY = 0
            var head = 0
            while head < queue.count {
                let p = queue[head]; head += 1
                let x = p % w, y = p / w
                size += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                // 4-connectivity keeps a solid element together while letting a 1px diagonal seam
                // fall apart into the noise it is.
                if x > 0, mask[p - 1], !seen[p - 1] { seen[p - 1] = true; queue.append(p - 1) }
                if x < w - 1, mask[p + 1], !seen[p + 1] { seen[p + 1] = true; queue.append(p + 1) }
                if y > 0, mask[p - w], !seen[p - w] { seen[p - w] = true; queue.append(p - w) }
                if y < h - 1, mask[p + w], !seen[p + w] { seen[p + w] = true; queue.append(p + w) }
            }
            if size > best.size { best = (size, minX, minY, maxX, maxY) }
        }
        guard best.size > 0 else { return (fraction, [0, 0, 0, 0]) }
        return (fraction, [Int(Double(best.minX) / scale), Int(Double(best.minY) / scale),
                           Int(Double(best.maxX + 1) / scale), Int(Double(best.maxY + 1) / scale)])
    }

    /// fal returns `bounding_box.normalized` as numbers that may decode as Int or Double.
    static func normalizedBox(_ bb: [String: Any]?) -> [Int]? {
        guard let arr = bb?["normalized"] as? [Any], arr.count == 4 else { return nil }
        let v = arr.compactMap { ($0 as? NSNumber)?.intValue }
        return v.count == 4 ? v : nil
    }
}

/// The Explorer habit of typing `cmd` in the address bar to get a shell where you are standing.
///
/// Only the keyword test lives here; resolving a URL to the directory a shell should open in is
/// already `openInTerminal(_:)` in main.swift, and duplicating it would give two answers to drift
/// apart.
enum TerminalRules {

    /// Address-bar words that mean "give me a shell here" rather than "navigate to a path".
    /// `cmd` is in the list because that is the Windows Explorer muscle memory this exists to
    /// serve; `terminal` because that is what the thing is called on this platform.
    ///
    /// Matching is on the WHOLE trimmed field, case-insensitively. A bare word is never a path
    /// Navigator resolves anyway (it has no notion of a relative cwd), so nothing is shadowed.
    static func isTerminalToken(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return s == "terminal" || s == "cmd" || s == "shell"
    }
}

// Readers run on filesystem workers while navigation and Cancel write on the UI thread.
// Lock the read-modify-write too, so advancing a generation cannot lose an invalidation.
@propertyWrapper
final class Synchronized<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(wrappedValue: Value) { value = wrappedValue }
    var wrappedValue: Value {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
        _modify { lock.lock(); defer { lock.unlock() }; yield &value }
    }
}

enum SearchBackendRules {
    static func usesRecursiveWalk(isNetwork: Bool, thisMac: Bool) -> Bool {
        isNetwork && !thisMac
    }

    // A directory's extension says nothing about its kind: Art.png is still a folder.
    static func matchesKind(tree: String?, isDirectory: Bool, fileTypeMatches: (String) -> Bool) -> Bool {
        guard let tree else { return true }
        if tree == "public.folder" { return isDirectory }
        return !isDirectory && fileTypeMatches(tree)
    }
}

// The UI timer must be able to drain matches even while nextObject is stuck on SMB.
final class SearchResultBuffer<Row>: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [Row] = []
    func append(_ row: Row) {
        lock.lock(); defer { lock.unlock() }
        rows.append(row)
    }
    func drain() -> [Row] {
        lock.lock(); defer { lock.unlock() }
        let result = rows
        rows.removeAll(keepingCapacity: true)
        return result
    }
}

/// Bounds outstanding child walks if the OS delays exit even after SIGKILL.
/// Admission is released after reaping, never merely after requesting cancellation.
final class WalkAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding = 0
    let limit: Int

    init(limit: Int = 4) { self.limit = limit }

    var current: Int { lock.lock(); defer { lock.unlock() }; return outstanding }

    /// False when the caller must NOT start a walk. Balance every true with `end()`.
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard outstanding < limit else { return false }
        outstanding += 1
        return true
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        // Clamped: a double end() must not make room that isn't there, or the bound silently
        // stops bounding.
        if outstanding > 0 { outstanding -= 1 }
    }
}

// MARK: - File creation

// Keep the worker's disk operations here so tests exercise the same names and partial
// successes that Browser registers for Undo, without needing a window or selection.
enum FileOperations {
    // Use Finder's xattr format so named colors retain their color index on disk.
    // Browser still ignores write failures as before; callers that need proof can catch them.
    static func writeTags(_ url: URL, _ names: [String]) throws {
        let colorIndex: [String: Int] = ["gray": 1, "grey": 1, "green": 2, "purple": 3,
                                       "blue": 4, "yellow": 5, "red": 6, "orange": 7]
        let attr = "com.apple.metadata:_kMDItemUserTags"
        let status: Int32
        if names.isEmpty {
            status = url.withUnsafeFileSystemRepresentation { removexattr($0, attr, 0) }
        } else {
            let entries = names.map { n in colorIndex[n.lowercased()].map { "\(n)\n\($0)" } ?? n }
            let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
            status = data.withUnsafeBytes { raw in
                url.withUnsafeFileSystemRepresentation { setxattr($0, attr, raw.baseAddress, data.count, 0, 0) }
            }
        }
        if status != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func uniqueDestination(_ directory: URL, _ name: String) -> URL {
        PathRules.uniqueDest(directory, name) { FileManager.default.fileExists(atPath: $0) }
    }

    static func newFolder(in directory: URL, name: String = "New Folder") throws -> URL {
        let target = uniqueDestination(directory, name)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    static func newFile(in directory: URL, name: String, contents: Data) throws -> URL {
        let target = uniqueDestination(directory, name)
        guard FileManager.default.createFile(atPath: target.path, contents: contents) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: "Navigator couldn't write to “\(directory.lastPathComponent)”."])
        }
        return target
    }

    static func duplicate(_ source: URL, in directory: URL) throws -> URL {
        let ext = source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent
        let target = uniqueDestination(directory, ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)")
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    static func makeAlias(_ source: URL, in directory: URL) throws -> URL {
        let target = uniqueDestination(directory, source.deletingPathExtension().lastPathComponent + " alias")
        let data = try source.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: target)
        return target
    }

    static func makeSymlink(_ source: URL, in directory: URL) throws -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let target = uniqueDestination(directory, ext.isEmpty ? "\(base) symlink" : "\(base) symlink.\(ext)")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
        return target
    }

    struct FolderSelection {
        let folder: URL
        let moved: [(from: URL, to: URL)]
        let failures: [String]
    }

    static func newFolder(in directory: URL, containing sources: [URL]) throws -> FolderSelection {
        let fm = FileManager.default
        let target = uniqueDestination(directory, sources.count == 1 ? "New Folder With Item" : "New Folder With Items")
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        var moved: [(from: URL, to: URL)] = []
        var failures: [String] = []
        for source in sources {
            let dest = target.appendingPathComponent(source.lastPathComponent)
            do { try fm.moveItem(at: source, to: dest); moved.append((source, dest)) }
            catch { failures.append("• \(source.lastPathComponent): \(error.localizedDescription)") }
        }
        // A completely failed batch must not leave an empty folder looking like success.
        if moved.isEmpty { try? fm.removeItem(at: target) }
        return FolderSelection(folder: target, moved: moved, failures: failures)
    }

    static func undoFolderSelection(_ result: FolderSelection) -> String? {
        let problem = restoreItems(result.moved.map { (from: $0.to, to: $0.from) })
        // Files added after creation belong to the user; Undo must not delete them.
        if (try? FileManager.default.contentsOfDirectory(atPath: result.folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: result.folder)
        }
        return problem
    }

    static func redoFolderSelection(_ result: FolderSelection) -> String? {
        try? FileManager.default.createDirectory(at: result.folder, withIntermediateDirectories: false)
        return restoreItems(result.moved)
    }
}

// The platform copy engine (copyfile) with byte-level progress: clones on
// APFS (instant), byte-copies across volumes / SMB / File Provider while
// reporting bytes, and preserves metadata — the same engine FileManager uses.
// Used for regular files so a large copy shows a real, moving bar.
func copyWithProgress(_ src: URL, _ dst: URL,
                             isCancelled: @escaping () -> Bool = { false },
                             onBytes: @escaping (Int64) -> Void) throws {
    final class Box {
        let cb: (Int64) -> Void; let cancelled: () -> Bool
        init(_ c: @escaping (Int64) -> Void, _ x: @escaping () -> Bool) { cb = c; cancelled = x }
    }
    let boxPtr = Unmanaged.passRetained(Box(onBytes, isCancelled)).toOpaque()
    defer { Unmanaged<Box>.fromOpaque(boxPtr).release() }
    let state = copyfile_state_alloc(); defer { copyfile_state_free(state) }
    let cb: copyfile_callback_t = { what, stage, st, _, _, ctx in
        if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let ctx {
            let box = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
            var copied: off_t = 0
            _ = copyfile_state_get(st, UInt32(COPYFILE_STATE_COPIED), &copied)
            box.cb(Int64(copied))
            // Honour Cancel *during* a single large file. Without this, hitting
            // Cancel closed the window while the copy ran on to completion.
            if box.cancelled() { return COPYFILE_QUIT }
        }
        return COPYFILE_CONTINUE
    }
    _ = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), boxPtr)
    _ = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(cb, to: UnsafeMutableRawPointer.self))
    // A destination created after the conflict check must never be overwritten.
    if copyfile(src.path, dst.path, state, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_EXCL)) != 0 {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                      userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
    }
}


/// After Effects' "Allow Scripts to Write Files and Access Network", read from its own
/// preferences file.
///
/// Worth a row of its own because of how it fails: with it OFF, a script's
/// `system.callSystem` is refused with
///   ReferenceError: Permission denied (is Preferences > Scripting & Expressions >
///   Allow Scripts to Write Files and Access Network enabled?)
/// and After Effects raises that as a MODAL dialog. Navigator runs After Effects hidden, so
/// the dialog could not be seen or answered and the job simply stopped. Verified on 26.5.0,
/// where the preferences file held Pref_SCRIPTING_FILE_NETWORK_SECURITY = "0".
enum AfterEffectsPrefsRules {
    /// nil when the key isn't present — After Effects writes this file on QUIT, so a fresh
    /// install that has never been quit has nothing to read, which is not the same as "off".
    static func scriptingFileAccessEnabled(prefsText: String) -> Bool? {
        guard let r = prefsText.range(of: "\"Pref_SCRIPTING_FILE_NETWORK_SECURITY\"") else { return nil }
        let tail = prefsText[r.upperBound...].prefix(40)
        guard let eq = tail.firstIndex(of: "=") else { return nil }
        // Values appear as "1"/"0" or as the bare 01/00 form this file also uses.
        let value = tail[tail.index(after: eq)...].prefix(8)
        if value.contains("1") { return true }
        if value.contains("0") { return false }
        return nil
    }
}

/// Keylight owns RGB/alpha recovery. The previous minimum-opacity extraction shifted
/// burstWhite's foreground green by +37.40/255 despite a near-perfect round trip.
/// Swift only converts AE's straight RGBA still and publishes the validated PNG.
enum ChromaKeyOutputRules {
    // AE has one project/render queue; simultaneous Finder and folder jobs must serialize.
    private static let renderLock = NSLock()

    static func failure(_ message: String) -> NSError {
        NSError(domain: "ChromaKey", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func load(_ url: URL) throws -> CGImage {
        guard let decoder = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(decoder, 0, nil) else {
            throw failure("Could not decode image: \(url.lastPathComponent)")
        }
        return image
    }

    static func foregroundBias(_ image: CGImage) throws -> [Double] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let decoded = bytes.withUnsafeMutableBytes { raw -> Bool in
            let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard decoded else { throw failure("Could not sample foreground colour") }
        let corners = [0, (image.width - 1) * 4, (image.height - 1) * image.width * 4, bytes.count - 4]
        let backing = (0..<3).map { c in Double(corners.map { bytes[$0 + c] }.sorted()[1]) }
        var bias = [0.5, 0.5, 0.5], bestDistance = 0.0
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] == 255 {
            var distance = 0.0, opaque = false
            for c in 0..<3 {
                let value = Double(bytes[i + c]), b = backing[c], delta = value - b
                distance += delta * delta
                // Only sample pixels requiring >=99% opacity in at least one channel.
                // Otherwise the bias contains backing: green rays never reach full opacity.
                if delta > 0 && delta >= 0.99 * (255 - b) { opaque = true }
                if delta < 0 && -delta >= 0.99 * b { opaque = true }
            }
            if opaque && distance > bestDistance {
                bestDistance = distance
                // Bias is a colour ratio; keep values away from plugin endpoint setters.
                bias = (0..<3).map { max(1, Double(bytes[i + $0])) / 510 }
            }
        }
        // Samples only select Keylight's bias. No RGB or alpha extraction occurs in Swift.
        return bias
    }

    /// Recover the true foreground colour by arithmetic instead of trusting despill.
    ///
    /// The source image is a composite over a known flat backing:  S = F·a + B·(1−a).
    /// Keylight estimates `a` well; what it does badly is the second half of its job,
    /// DESPILL — subtracting the screen colour from what it kept. On a magenta field
    /// that means taking red and blue out of everything, so a gold-and-crimson symbol
    /// came back uniformly green. The colour is not lost, though: given `a` and `B`,
    /// the equation above rearranges to F = (S − B·(1−a)) / a, which is exact.
    ///
    /// So the alpha is Keylight's — that is what it is good at — and the colour is
    /// computed. Nothing is clipped, so soft FX keep every transitional value, and
    /// nothing is classified, so this needs no guess about what kind of image it is.
    ///
    /// The division blows up as `a` approaches zero, where a pixel is almost entirely
    /// backing and carries almost no foreground to recover. Below `alphaFloor` the
    /// recovered value is noise and Keylight's despilled colour is kept instead, with a
    /// smooth crossfade up to `alphaFull` so the edge does not band.
    enum SpillRules {
        /// Below this, the pixel is too nearly pure backing to invert: 1/a amplifies
        /// any error in Keylight's alpha, and at a thin matte that error is all there is.
        static let alphaFloor: Double = 0.28
        /// At and above this, the computed foreground is used outright. Chosen from the
        /// real matte: on a keyed symbol the subject's body is spread across alpha
        /// 0.4-1.0 rather than sitting at 1.0, so recovery has to reach well below full
        /// opacity or most of the symbol keeps the despilled colour.
        static let alphaFull: Double = 0.50

        /// How much to trust the computed colour, 0…1.
        static func weight(alpha: UInt8) -> Double {
            let a = Double(alpha) / 255
            if a <= alphaFloor { return 0 }
            if a >= alphaFull { return 1 }
            let t = (a - alphaFloor) / (alphaFull - alphaFloor)
            return t * t * (3 - 2 * t)          // smoothstep, so the edge does not band
        }

        /// F = (S − B·(1−a)) / a, clamped to the representable range.
        static func foreground(source: RGB8, backing: RGB8, alpha: UInt8) -> RGB8 {
            let a = max(Double(alpha) / 255, 1.0 / 255)
            func ch(_ s: UInt8, _ b: UInt8) -> UInt8 {
                let v = (Double(s) - Double(b) * (1 - a)) / a
                return UInt8(max(0, min(255, v.rounded())))
            }
            return RGB8(ch(source.r, backing.r), ch(source.g, backing.g), ch(source.b, backing.b))
        }

        /// The colour to write: Keylight's where the matte is too thin to invert, the
        /// computed foreground where it is not, blended in between.
        static func recovered(keyed: RGB8, source: RGB8, backing: RGB8, alpha: UInt8) -> RGB8 {
            let w = weight(alpha: alpha)
            if w <= 0 { return keyed }
            let f = foreground(source: source, backing: backing, alpha: alpha)
            if w >= 1 { return f }
            func mix(_ k: UInt8, _ v: UInt8) -> UInt8 {
                UInt8(max(0, min(255, (Double(k) * (1 - w) + Double(v) * w).rounded())))
            }
            return RGB8(mix(keyed.r, f.r), mix(keyed.g, f.g), mix(keyed.b, f.b))
        }
    }

    /// The matte for a SOLID symbol: remove the field, not the colour.
    ///
    /// Keylight is a colour-difference keyer and knows nothing about WHERE anything is.
    /// Skin carries red and a sky carries blue — both halves of magenta — so it keyed a
    /// face and the sky behind it as partly transparent, as if the backing showed through,
    /// and the arithmetic then subtracted magenta that was never there. Measured on six
    /// generated symbols through this app's own path: 27–77% of each subject came back
    /// partly transparent, with colour errors of 33–83 levels, and a strong green cast.
    ///
    /// The rule a person applies is spatial, so this is:
    ///   - FIELD: what Keylight calls clear AND is connected to the image border, plus any
    ///     enclosed pocket whose core is the flat backing itself (the gap between a frame
    ///     and a figure). Magenta ARTWORK is never reachable from the border through clear
    ///     pixels, and its core is never the flat generated backing — measured, the best
    ///     tenth of a real hole sits 2–8 levels from the backing and artwork 19 or more —
    ///     so a neon symbol's pink glow survives.
    ///   - INTERIOR: everything the silhouette encloses. Fully opaque, source colour
    ///     exactly, because a pixel inside the symbol contains no backing at all.
    ///   - RIM: the few pixels in between. Both colours in that mix are known — the local
    ///     interior colour F and the backing B — so alpha is where the pixel sits on the
    ///     line from B to F, and its colour is recovered with THAT alpha. Keylight's alpha
    ///     under-reads at the rim, and recovering colour from it is what left a green
    ///     fringe. Where F and B are too alike to project (pink artwork against magenta),
    ///     Keylight's alpha is the only estimate there is, and it is kept.
    enum SolidSubjectMatte {
        static let clearBelow: UInt8 = 25     // Keylight alpha under this counts as clear
        static let opaqueFrom: UInt8 = 250
        static let holeMatch = 12.0           // a pocket is backing if its best tenth is this close
        static let distinct = 80.0            // |F − B| needed before projecting onto the line
        static let reach = 12                 // how far a soft edge may extend from the field
        static let rim = 6                    // how far out from the interior alpha is re-estimated

        /// `source` and `keyed` are straight (unpremultiplied) RGBA8 of `width*height*4`
        /// bytes. Returns straight RGBA8 of the same size.
        static func apply(source: [UInt8], keyed: [UInt8], width w: Int, height h: Int,
                          backing: RGB8) -> [UInt8] {
            let n = w * h
            precondition(source.count == n * 4 && keyed.count == n * 4)
            // `backing` is only the fallback; the field's own median replaces it below.
            var B = [Double(backing.r), Double(backing.g), Double(backing.b)]
            func toBacking(_ p: Int) -> Double {
                let i = p * 4
                let r = Double(source[i]) - B[0], g = Double(source[i+1]) - B[1], b = Double(source[i+2]) - B[2]
                return (r*r + g*g + b*b).squareRoot()
            }
            func neighbours4(_ p: Int, _ body: (Int) -> Void) {
                let x = p % w
                if x > 0 { body(p - 1) }
                if x < w - 1 { body(p + 1) }
                if p >= w { body(p - w) }
                if p < n - w { body(p + w) }
            }

            // Field: clear components touching the border, or whose core is the backing.
            var field = [Bool](repeating: false, count: n)
            var seen = [Bool](repeating: false, count: n)
            var stack: [Int] = []
            var enclosed: [[Int]] = []
            for start in 0..<n where !seen[start] && keyed[start*4+3] < clearBelow {
                var members: [Int] = []
                var touchesBorder = false
                seen[start] = true; stack.append(start)
                while let p = stack.popLast() {
                    members.append(p)
                    let x = p % w, y = p / w
                    if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesBorder = true }
                    neighbours4(p) { q in
                        if !seen[q] && keyed[q*4+3] < clearBelow { seen[q] = true; stack.append(q) }
                    }
                }
                if touchesBorder { for p in members { field[p] = true } } else { enclosed.append(members) }
            }
            // The backing, measured from the field itself rather than four corner pixels.
            // A generated backing drifts a few levels across the image, and the corner
            // estimate moved one real hole from 10.8 to 16.2 levels away — across the
            // line that decides whether it is removed.
            var samples: [[Int]] = [[], [], []]
            var k = 0
            for p in 0..<n where field[p] {
                k += 1
                if k % 7 != 0 { continue }
                for c in 0..<3 { samples[c].append(Int(source[p*4+c])) }
            }
            if !samples[0].isEmpty {
                for c in 0..<3 { samples[c].sort(); B[c] = Double(samples[c][samples[c].count / 2]) }
            }
            for members in enclosed {
                let d = members.map(toBacking).sorted()
                if d[d.count / 10] <= holeMatch { for p in members { field[p] = true } }
            }
            let backing = RGB8(UInt8(B[0]), UInt8(B[1]), UInt8(B[2]))

            // Soft edge: partial pixels reachable from the field through partial pixels.
            var edge = [Bool](repeating: false, count: n)
            var depth = [Int](repeating: -1, count: n)
            var queue: [Int] = []
            queue.reserveCapacity(n / 2)
            for p in 0..<n where field[p] { depth[p] = 0; queue.append(p) }
            var head = 0
            while head < queue.count {
                let p = queue[head]; head += 1
                if depth[p] >= reach { continue }
                neighbours4(p) { q in
                    if depth[q] < 0 && keyed[q*4+3] < opaqueFrom {
                        depth[q] = depth[p] + 1; edge[q] = true; queue.append(q)
                    }
                }
            }
            let interior = (0..<n).map { !field[$0] && !edge[$0] }

            // Rim: pixels within `rim` of the interior, each with its nearest interior pixel.
            var nearest = [Int](repeating: -1, count: n)
            var rimDepth = [Int](repeating: -1, count: n)
            queue.removeAll(keepingCapacity: true); head = 0
            for p in 0..<n where interior[p] { nearest[p] = p; rimDepth[p] = 0; queue.append(p) }
            while head < queue.count {
                let p = queue[head]; head += 1
                if rimDepth[p] >= rim { continue }
                let x = p % w, y = p / w
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let q = ny * w + nx
                    if rimDepth[q] < 0 { rimDepth[q] = rimDepth[p] + 1; nearest[q] = nearest[p]; queue.append(q) }
                } }
            }

            var out = [UInt8](repeating: 0, count: n * 4)
            func put(_ p: Int, _ r: Double, _ g: Double, _ b: Double, _ a: Double) {
                let i = p * 4
                out[i] = UInt8(max(0, min(255, r.rounded()))); out[i+1] = UInt8(max(0, min(255, g.rounded())))
                out[i+2] = UInt8(max(0, min(255, b.rounded()))); out[i+3] = UInt8(max(0, min(255, a.rounded())))
            }
            for p in 0..<n {
                let i = p * 4
                if interior[p] {
                    out[i] = source[i]; out[i+1] = source[i+1]; out[i+2] = source[i+2]; out[i+3] = 255
                    continue
                }
                if rimDepth[p] > 0 {
                    // Local interior colour: the mean over a 7×7 window, so one specular
                    // highlight does not paint a whole stretch of rim cream.
                    let x = p % w, y = p / w
                    var sum = [0.0, 0.0, 0.0], count = 0.0
                    for yy in max(0, y - 3)...min(h - 1, y + 3) { for xx in max(0, x - 3)...min(w - 1, x + 3) {
                        let q = yy * w + xx
                        guard interior[q] else { continue }
                        sum[0] += Double(source[q*4]); sum[1] += Double(source[q*4+1]); sum[2] += Double(source[q*4+2]); count += 1
                    } }
                    let q = nearest[p] * 4
                    let F = count > 0 ? sum.map { $0 / count }
                                      : [Double(source[q]), Double(source[q+1]), Double(source[q+2])]
                    let v = (0..<3).map { F[$0] - B[$0] }
                    let vv = v[0]*v[0] + v[1]*v[1] + v[2]*v[2]
                    if vv >= distinct * distinct {
                        let S = [Double(source[i]), Double(source[i+1]), Double(source[i+2])]
                        var a = max(0, min(1, ((S[0]-B[0])*v[0] + (S[1]-B[1])*v[1] + (S[2]-B[2])*v[2]) / vv))
                        // A pixel already judged to be field cannot be FAINTLY subject: a few
                        // percent here is the backing drifting a few levels, not coverage.
                        if field[p] && a < 0.08 { a = 0 }
                        // Own colour from the projected alpha; faint pixels fade to F, where
                        // the division would amplify noise more than it recovers colour.
                        var t = max(0, min(1, (a - 0.15) / 0.20)); t = t * t * (3 - 2 * t)
                        let c = (0..<3).map { k -> Double in
                            let own = max(0, min(255, B[k] + (S[k] - B[k]) / max(a, 0.001)))
                            return own * t + F[k] * (1 - t)
                        }
                        put(p, c[0], c[1], c[2], a * 255)
                        continue
                    }
                }
                // The field itself is gone rather than faintly tinted: Keylight leaves it
                // at alpha < 25 in its despilled colour, a haze on a dark reel.
                if field[p] && rimDepth[p] < 0 { continue }
                let a = keyed[i+3]
                let c = SpillRules.recovered(keyed: RGB8(keyed[i], keyed[i+1], keyed[i+2]),
                                             source: RGB8(source[i], source[i+1], source[i+2]),
                                             backing: backing, alpha: a)
                out[i] = c.r; out[i+1] = c.g; out[i+2] = c.b; out[i+3] = a
            }
            return out
        }
    }

    /// Any decoded image as straight RGBA8, row-packed, in the image's own RGB space.
    ///
    /// The interior repair used to demand the SOURCE already be 8-bit straight RGBA, and a
    /// symbol generated on a flat backing never is: it decodes as RGB with a padding byte
    /// (alphaInfo .noneSkipLast). So the repair returned nil without a word, and Keylight's
    /// green-cast output was published untouched — on every generated symbol.
    static func straightRGBA8(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Int(bytes[i+3])
            guard a > 0 && a < 255 else { continue }
            for c in 0..<3 { bytes[i+c] = UInt8(min(255, (Int(bytes[i+c]) * 255 + a / 2) / a)) }
        }
        return bytes
    }

    static func image(straightRGBA8 bytes: [UInt8], width: Int, height: Int, space: CGColorSpace?) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The flat backing colour, taken as the median of the four corners.
    ///
    /// Median rather than mean: one corner clipped by the subject would drag a mean
    /// toward the art, and the whole recovery is anchored on this value being right.
    static func backingColour(_ image: CGImage) throws -> RGB8 {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let decoded = bytes.withUnsafeMutableBytes { raw -> Bool in
            let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard decoded else { throw failure("Could not sample the backing colour") }
        let corners = [0, (image.width - 1) * 4,
                       (image.height - 1) * image.width * 4, bytes.count - 4]
        let m = (0..<3).map { c in corners.map { bytes[$0 + c] }.sorted()[1] }
        return RGB8(m[0], m[1], m[2])
    }

    /// Copy source RGB into the pixels the matte calls (near-)opaque. Returns nil when there is
    /// nothing to change or the images cannot be read in a compatible form, in which case the
    /// caller keeps the keyed image exactly as it is.
    ///
    /// Works on the RAW bytes, in the image's own alpha format. An earlier version rasterised
    /// both images through a premultiplied CGContext, which re-quantised the SOFT pixels by a
    /// fraction of a level (48.188 became 47.937) — and the soft pixels are precisely the ones
    /// Keylight's despill is working on, so they must come through untouched.
    static func restoreOpaqueInterior(keyed: CGImage, source: CGImage,
                                      backing: RGB8? = nil) throws -> CGImage? {
        let w = keyed.width, h = keyed.height
        guard source.width == w, source.height == h,
              keyed.bitsPerComponent == 8, keyed.bitsPerPixel == 32,
              source.bitsPerComponent == 8, source.bitsPerPixel == 32,
              keyed.alphaInfo == .last, source.alphaInfo == .last,
              let kData = keyed.dataProvider?.data as Data?,
              let sData = source.dataProvider?.data as Data? else { return nil }
        let kRow = keyed.bytesPerRow, sRow = source.bytesPerRow
        // 250, not 255. Measured on the sparkle's white core: of 126 neutral pixels, 110 keyed
        // to alpha 255 but 16 landed on 252-254, and a strict test left exactly those 16 still
        // reading rgb(255,255,143).
        //
        // ponytail: at alpha 250 the backing still contributes 5/255 = 2% of the pixel, so
        // taking the source colour is approximate there rather than exact — bounded at about
        // 5 levels, against the 112 it removes. Below 250 the approximation stops being worth
        // it and Keylight's despill is left alone. Solving F = (C - B(1-a))/a exactly would
        // need the backing colour plumbed back from the JSX, which is the upgrade if this
        // ceiling ever matters.
        let opaqueEnough: UInt8 = 250
        var bytes = [UInt8](kData)
        var restored = 0
        for y in 0..<h {
            for x in 0..<w {
                let k = y*kRow + x*4, sp = y*sRow + x*4
                let a = bytes[k+3]
                guard a > 0 else { continue }
                if let backing {
                    // Recover the colour from the compositing equation at EVERY pixel the
                    // matte kept, not just the fully opaque ones — see SpillRules. The old
                    // behaviour only repaired pixels at alpha >= 250, so an image whose
                    // matte never reached that (a solid symbol on a backing sharing its
                    // colours) kept Keylight's despilled result everywhere and came back
                    // the wrong colour entirely.
                    let out = SpillRules.recovered(
                        keyed: RGB8(bytes[k], bytes[k+1], bytes[k+2]),
                        source: RGB8(sData[sp], sData[sp+1], sData[sp+2]),
                        backing: backing, alpha: a)
                    if out != RGB8(bytes[k], bytes[k+1], bytes[k+2]) { restored += 1 }
                    bytes[k] = out.r; bytes[k+1] = out.g; bytes[k+2] = out.b
                } else {
                    guard a >= opaqueEnough else { continue }
                    if bytes[k] != sData[sp] || bytes[k+1] != sData[sp+1] || bytes[k+2] != sData[sp+2] { restored += 1 }
                    bytes[k] = sData[sp]; bytes[k+1] = sData[sp+1]; bytes[k+2] = sData[sp+2]
                }
            }
        }
        guard restored > 0 else { return nil }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: kRow, space: keyed.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: keyed.bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: keyed.renderingIntent)
    }

    static func publish(rendered: URL, source: URL, profile: KeylightProfile = .softFX) throws -> URL {
        var input = try load(source)
        let image = try load(rendered)
        guard image.width == input.width, image.height == input.height else {
            throw failure("After Effects changed the image dimensions")
        }
        guard [.last, .first, .premultipliedLast, .premultipliedFirst].contains(image.alphaInfo) else {
            throw failure("After Effects rendered without an alpha channel")
        }
        // Restore the colour of fully-opaque pixels from the source.
        //
        // Where the matte is fully opaque the pixel contains NO backing at all — the
        // compositing equation there is C = F*1 + B*0, so F = C exactly, and despill has
        // nothing to correct. Keylight despills it anyway, and with Despill Bias set to
        // protect a coloured subject that drags neutral highlights toward the bias colour.
        // Measured on the yellow sparkle: 126 core pixels that are rgb(255,255,255) in the
        // source came out rgb(255,255,143). Removing the bias is not the answer — without it
        // the sparkle's own yellow is stripped to grey across 89,800 pixels
        // (rgb(255,255,142) -> rgb(174,174,174)), so the bias is doing necessary work on the
        // SOFT pixels, which is where Keylight earns its place. This only touches the
        // interior, and only where the answer is arithmetically certain.
        let space = image.colorSpace
        let final: CGImage
        if profile == .solidSymbol {
            guard let src = straightRGBA8(input), let keyed = straightRGBA8(image),
                  let made = self.image(straightRGBA8: SolidSubjectMatte.apply(
                    source: src, keyed: keyed, width: input.width, height: input.height,
                    backing: try backingColour(input)), width: input.width, height: input.height, space: space)
            else { throw failure("Could not build the symbol matte") }
            final = made
        } else {
            // The soft-FX repair needs the source as straight RGBA; a generated PNG is RGB.
            if let bytes = straightRGBA8(input),
               let normal = self.image(straightRGBA8: bytes, width: input.width, height: input.height,
                                       space: input.colorSpace) { input = normal }
            final = try restoreOpaqueInterior(keyed: image, source: input,
                                              backing: try? backingColour(input)) ?? image
        }
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw failure("Could not encode PNG")
        }
        CGImageDestinationAddImage(encoder, final, nil)
        guard CGImageDestinationFinalize(encoder) else { throw failure("Could not finish PNG") }
        let out = source.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent + "_rmbg.png")
        // Validate before atomic replacement, so an AE failure preserves an earlier output.
        try (data as Data).write(to: out, options: .atomic)
        return out
    }

    /// How hard to clip the matte.
    ///
    /// These are not a preference, they are two different jobs, and one setting cannot
    /// do both. Measured on a generated symbol, same image, same key:
    ///
    ///   softFX       24.3% clear, 19.1% opaque, 56.6% PARTIAL
    ///   solidSymbol  70.8% clear, 27.4% opaque,  1.8% partial
    ///
    /// For a sparkle or a ray, that 56.6% is the asset — clipping it away is what the
    /// "hard cut" complaint was about, so FX keeps Clip Black 0 / Clip White 100 and
    /// preserves every transitional value. For a solid symbol it is a defect: the whole
    /// piece comes out semi-transparent and the reel shows through the giant's face.
    enum KeylightProfile {
        /// Preserve transitional alpha. Sparkles, rays, soft FX.
        case softFX
        /// Solid subject on a flat field: opaque interior, thin anti-aliased edge.
        case solidSymbol

        var clipBlack: Double { self == .softFX ? 0 : 10 }
        var clipWhite: Double { self == .softFX ? 100 : 80 }
    }

    /// Tell the keying script which colour to key, so it never samples one itself.
    ///
    /// As HEX, deliberately. In custom mode the script re-derives the colour from
    /// customKeyColorHex, whose default is "#00FF00" — so passing only customKeyColor keyed
    /// a magenta image for GREEN and removed nothing: every pixel came back opaque.
    static func keyColorConfig(_ backing: RGB8) -> [String: Any] {
        ["keyMode": "custom", "customKeyColorHex": String(format: "#%02X%02X%02X", backing.r, backing.g, backing.b)]
    }

    static func exportPNG(source: URL, scriptURL: URL, bundleID: String,
                          profile: KeylightProfile = .softFX,
                          onLaunch: ((@escaping () -> Bool) -> Void)? = nil) throws -> URL {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard source.pathExtension.lowercased() == "png" else { throw failure("Chroma Key needs a PNG") }
        let sourceImage = try load(source)
        let bias = try foregroundBias(sourceImage)
        // Hand After Effects the backing colour instead of letting it sample one. Its sampler
        // reads the image through an expression bridge, and doing that on a real image un-hid
        // After Effects — measured 1 of 1 runs, every run, against 0 for every step before
        // it. That is the flash in front of the user once per image of a batch. The colour is
        // the same four-corner measurement the script would make, and skipping the sampler also
        // skips its four quarter-second waits.
        let backing = try backingColour(sourceImage)
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("NavigatorKeylight-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let statusFile = scratch.appendingPathComponent("result.txt")
        let logFile = scratch.appendingPathComponent("keylight.log")
        var config: [String: Any] = ["sourceFile": source.path, "outputFolder": scratch.path,
            "outputName": "keyed", "automationMode": true, "showUi": false,
            "keylight": ["despillBias": bias,
                         "clipBlack": profile.clipBlack, "clipWhite": profile.clipWhite],
            "resultFile": statusFile.path, "logFile": logFile.path]
        config.merge(keyColorConfig(backing)) { _, new in new }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        // DoScriptFile is refused by AE's scripting security; DoScript SOURCE works.
        // No system.callSystem: TIFF-to-PNG conversion is entirely in ImageIO above.
        let jsx = "$.global.H5G_CHROMA_KEY_CONFIG = " + json + ";\n" + script
        guard ["com.adobe.AfterEffects.application", "com.adobe.AfterEffects"].contains(bundleID) else {
            throw failure("Unrecognised After Effects bundle identifier")
        }
        let appleScript = """
        on run argv
            with timeout of 3600 seconds
                tell application id "\(bundleID)" to DoScript item 1 of argv
            end timeout
        end run
        """
        let result = try ExternalProcess.run("/usr/bin/osascript", arguments: ["-e", appleScript, jsx],
                                            timeout: 3660, onLaunch: onLaunch).completed()
        guard result.status == 0 else { throw failure(result.err) }
        // AE DoScript returns 0 even when JSX fails: require its explicit completion file.
        let status = (try? String(contentsOf: statusFile, encoding: .utf8)) ?? "No completion status from After Effects"
        let log = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        guard status.hasPrefix("OK: ") else { throw failure(status + "\n" + log) }
        let rendered = URL(fileURLWithPath: String(status.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines))
        guard rendered.deletingLastPathComponent().standardizedFileURL == scratch.standardizedFileURL,
              ["tif", "png"].contains(rendered.pathExtension.lowercased()) else {
            throw failure("After Effects reported an unexpected output path")
        }
        return try publish(rendered: rendered, source: source, profile: profile)
    }
}

/// Which Photoshop to drive when more than one is installed.
///
/// Photoshop 2026 and Photoshop (Beta) claim the SAME bundle identifier,
/// "com.adobe.Photoshop" — verified on this machine, versions 27.10.0 and 27.11.0 living in
/// separate folders. So urlForApplication(withBundleIdentifier:) answers with whichever
/// LaunchServices happens to rank first, which was the Beta, and Remove BG drove a different
/// Photoshop from the one that was open on screen.
///
/// Nothing here names a year or a version. A future Photoshop is picked up by being newer,
/// and a machine with only the Beta installed still works — it is only ever preferred when
/// it is the only thing there.
enum PhotoshopChoiceRules {
    /// The index of the build to drive, or nil when there are none.
    ///
    /// Released beats prerelease; among equals, the highest version wins. Version strings
    /// are compared component by component as NUMBERS, because "27.10.0" is newer than
    /// "27.9.0" and a string comparison says the opposite.
    static func preferred(_ candidates: [(name: String, version: String)]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        let indices = candidates.indices
        let released = indices.filter { !isPrerelease(candidates[$0].name) }
        let pool = released.isEmpty ? Array(indices) : released
        return pool.max { a, b in
            isOlder(candidates[a].version, than: candidates[b].version)
        }
    }

    /// Adobe marks these in the application NAME — "Adobe Photoshop (Beta)". There is no flag
    /// in the bundle that says prerelease, so the name is what there is to go on.
    static func isPrerelease(_ name: String) -> Bool {
        let l = name.lowercased()
        return l.contains("beta") || l.contains("prerelease") || l.contains("(b)")
    }

    static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// macOS names the WRONG volume when a destination is read-only.
///
/// Verified against a read-only SMB share: NSCocoaErrorDomain 642, real destination volume
/// "Games", and the message reads «You can't save the file "normal.txt" because the volume
/// "Macintosh HD" is read only». Someone told that goes and inspects their startup disk,
/// which is fine, and learns nothing about the share that actually refused them.
enum TransferErrorRules {
    static let readOnlyVolumeCode = 642      // NSFileWriteVolumeReadOnlyError

    static func isReadOnlyVolume(domain: String, code: Int) -> Bool {
        domain == NSCocoaErrorDomain && code == readOnlyVolumeCode
    }

    static func readOnlyMessage(name: String, volume: String) -> String {
        "“\(volume)” is read-only, so “\(name)” can’t be written there. On a network share "
        + "this usually means you have read access to it but not write access."
    }
}

/// The failure text to show for a transfer error — macOS's own wording, except where it is
/// actively misleading (see TransferErrorRules).
func describeTransferFailure(_ error: Error, at destination: URL) -> String {
    let ns = error as NSError
    guard TransferErrorRules.isReadOnlyVolume(domain: ns.domain, code: ns.code) else {
        return error.localizedDescription
    }
    let dir = destination.deletingLastPathComponent()
    let volume = (try? dir.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    return TransferErrorRules.readOnlyMessage(name: destination.lastPathComponent,
                                              volume: volume ?? dir.path)
}

/// Remove a file together with the AppleDouble "._" sidecar that carries its extended
/// attributes on a filesystem which cannot store them natively (SMB, exFAT, FAT).
///
/// Removing the file does NOT take the sidecar with it. Measured on a non-Mac volume: every
/// failed copy left a hidden 4 KB "._.navigator-incoming-XXXX" behind, and on a shared drive
/// those accumulate forever with nobody able to guess what they were.
func removeWithAppleDouble(_ url: URL) {
    let fm = FileManager.default
    try? fm.removeItem(at: url)
    let name = url.lastPathComponent
    guard !name.hasPrefix("._") else { return }
    try? fm.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("._" + name))
}

/// Did a failed copy nonetheless put the whole file at the destination?
///
/// Regular files only: a directory's own size says nothing about whether its contents were
/// copied, so a half-copied folder must never pass this.
func arrivedComplete(_ src: URL, _ dst: URL) -> Bool {
    let fm = FileManager.default
    guard let s = try? fm.attributesOfItem(atPath: src.path),
          let d = try? fm.attributesOfItem(atPath: dst.path),
          (s[.type] as? FileAttributeType) == .typeRegular,
          (d[.type] as? FileAttributeType) == .typeRegular,
          let sSize = (s[.size] as? NSNumber)?.int64Value,
          let dSize = (d[.size] as? NSNumber)?.int64Value else { return false }
    return sSize == dSize
}

/// Copy just the bytes and the mode/timestamps — no extended attributes, no ACLs.
///
/// The fallback for a destination that cannot hold Mac metadata. COPYFILE_EXCL so it can
/// never overwrite something that appeared in the meantime.
func copyDataOnly(_ src: URL, _ dst: URL) -> Bool {
    copyfile(src.path, dst.path, nil,
             copyfile_flags_t(COPYFILE_DATA | COPYFILE_STAT | COPYFILE_EXCL)) == 0
}

// MARK: - Transfer planning and execution

enum ConflictPolicy { case keepBoth, replace, skip }

enum Transfer {
    struct Conflict { let source: URL; let destination: URL }
    enum Intent: Equatable {
        case skip, copy, move, renameToUnique(numbered: Bool), replaceWithStaging
    }
    enum UndoRecord: Equatable {
        case removeCreated(URL), moveBack(from: URL, to: URL)
    }
    enum UndoIntent: Equatable { case removeDestination, restoreSource(URL) }
    struct Item {
        let source: URL
        let destination: URL
        let move: Bool
        let intent: Intent
        // A template: execution records the actual destination and handles move's
        // copy-only fallback. Replacement deliberately does not retain the old file for Undo.
        var undo: UndoIntent? {
            intent == .skip ? nil : (move ? .restoreSource(source) : .removeDestination)
        }
    }

    // PRECONDITION: `sources` must not contain a folder that `directory` lives inside. A
    // folder copied into its own subtree recurses until the path length breaks — measured,
    // it produced a 117 KB tree before failing with a truncated-filename error. The check
    // needs symlink resolution, which is disk I/O, so it is enforced once on the worker
    // thread in performTransfer (Browser.isSelfOrDescendant) rather than here, where plan()
    // is meant to be pure. A new caller of plan() must do the same.
    //
    // conflictNames is the worker's original scan, not a filesystem query here.
    // Unique names remain an intent: resolving them on disk at execution time preserves
    // races and name reuse after a previous failure. previewDestination is pure too.
    static func plan(sources: [URL], into directory: URL, move: Bool,
                     conflictNames: Set<String>, decide: (Conflict) -> ConflictPolicy?) -> [Item] {
        var items: [Item] = []
        for source in sources {
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            let intent: Intent
            if !move && source.deletingLastPathComponent().path == directory.path {
                intent = .renameToUnique(numbered: true)
            } else if conflictNames.contains(source.lastPathComponent) {
                guard let policy = decide(Conflict(source: source, destination: destination)) else { return [] }
                switch policy {
                case .skip: intent = .skip
                case .keepBoth: intent = .renameToUnique(numbered: false)
                case .replace: intent = .replaceWithStaging
                }
            } else { intent = move ? .move : .copy }
            items.append(Item(source: source, destination: destination, move: move, intent: intent))
        }
        return items
    }

    static func previewDestination(_ item: Item, occupiedPaths: Set<String>) -> URL {
        destination(item, exists: { occupiedPaths.contains($0) })
    }

    private static func destination(_ item: Item, exists: (String) -> Bool) -> URL {
        guard case .renameToUnique(let numbered) = item.intent else { return item.destination }
        let dir = item.destination.deletingLastPathComponent(), name = item.source.lastPathComponent
        return numbered ? PathRules.numberedCopyDest(dir, name, exists: exists)
                        : PathRules.uniqueDest(dir, name, exists: exists)
    }

    enum Status: Equatable { case notProcessed, skipped, copied, moved, failed, cancelled }
    struct Outcome {
        let item: Item
        var destination: URL
        var status: Status = .notProcessed
        var failures: [String] = []
        /// The transfer SUCCEEDED but something about it is worth saying — currently only
        /// "the bytes are there, the Mac metadata is not". Deliberately separate from
        /// `failures`, which raises an error dialog: a file that arrived intact must not be
        /// reported to the user as a failure.
        var warnings: [String] = []
        var undo: UndoRecord? {
            switch status {
            case .copied: return .removeCreated(destination)
            case .moved: return .moveBack(from: destination, to: item.source)
            default: return nil
            }
        }
    }
    struct Result {
        var outcomes: [Outcome]
        var moved: [(from: URL, to: URL)] {
            outcomes.compactMap { if case .moveBack(let from, let to) = $0.undo { return (to, from) }; return nil }
        }
        var copied: [URL] {
            outcomes.compactMap { if case .removeCreated(let url) = $0.undo { return url }; return nil }
        }
        var failures: [(name: String, reason: String)] {
            outcomes.flatMap { o in o.failures.map { (o.item.source.lastPathComponent, $0) } }
        }
        var skipped: Int { outcomes.filter { $0.status == .skipped }.count }
        var warnings: [(name: String, reason: String)] {
            outcomes.flatMap { o in o.warnings.map { (o.item.source.lastPathComponent, $0) } }
        }
    }

    static func execute(_ plan: [Item], useBytes: Bool = false,
                        isCancelled: @escaping () -> Bool = { false },
                        onStart: (Int) -> Void = { _ in },
                        onBytes: @escaping (Int, Int64) -> Void = { _, _ in },
                        onFinish: (Int) -> Void = { _ in },
                        log: (String) -> Void = { _ in }) -> Result {
        let fm = FileManager.default
        var result = Result(outcomes: plan.map { Outcome(item: $0, destination: $0.destination) })
        for (i, item) in plan.enumerated() {
            if isCancelled() { break }
            onStart(i)
            let src = item.source, target = item.destination, name = src.lastPathComponent
            let dest = destination(item, exists: { fm.fileExists(atPath: $0) })
            result.outcomes[i].destination = dest
            var backup: URL?
            func restoreReplaced() {
                guard let stash = backup else { return }
                do { try fm.moveItem(at: stash, to: target) }
                catch {
                    log("transfer ROLLBACK FAILED for “\(name)”: original is still at \(stash.path) — \(error.localizedDescription)")
                    result.outcomes[i].failures.append("could not restore the original; it is in this folder as “\(stash.lastPathComponent)”")
                }
            }
            switch item.intent {
            case .skip:
                result.outcomes[i].status = .skipped
                continue
            case .copy, .move:
                if fm.fileExists(atPath: target.path) {
                    result.outcomes[i].status = .failed
                    result.outcomes[i].failures.append("destination appeared after the conflict check; retry the transfer")
                    continue
                }
            case .replaceWithStaging:
                let stash = target.deletingLastPathComponent().appendingPathComponent(".navigator-replacing-\(UUID().uuidString)")
                do { try fm.moveItem(at: target, to: stash); backup = stash }
                catch {
                    log("transfer SKIPPED “\(name)”: could not set the existing item aside — \(error.localizedDescription)")
                    result.outcomes[i].status = .failed
                    result.outcomes[i].failures.append("could not replace the existing item: \(error.localizedDescription)")
                    continue
                }
            case .renameToUnique: break
            }
            // A COPY is written to a staging name in the destination folder and renamed into
            // place only once it is whole.
            //
            // Publishing straight to the final name is what left a 0-BYTE file sitting under
            // the right name when a copy failed late — measured on a destination that cannot
            // hold the "._" sidecar for a 254-character name: FileManager creates the file,
            // then fails, and the data never arrives. That leftover is indistinguishable from
            // a file a competing process created a moment earlier, so it could neither be
            // trusted nor safely deleted, and the retry on top of it failed with "an item
            // with the same name already exists" — a message about a file this app had just
            // created, which buried the real reason. Staging removes the question entirely:
            // anything at the staging name is ours.
            //
            // A MOVE is deliberately NOT staged. Same-volume it is already atomic, and a
            // cross-volume one that fails leaves the source where it is; staging it would
            // instead park the data under a hidden name with the source already gone.
            let staged: URL? = item.move ? nil
                : dest.deletingLastPathComponent()
                      .appendingPathComponent(".navigator-incoming-\(UUID().uuidString.prefix(8))")
            let writeTo = staged ?? dest
            func discardStaging() { if let staged { removeWithAppleDouble(staged) } }
            var warning: String?
            do {
                if item.move { try fm.moveItem(at: src, to: dest) }
                else if useBytes { try copyWithProgress(src, writeTo, isCancelled: isCancelled, onBytes: { onBytes(i, $0) }) }
                else { try fm.copyItem(at: src, to: writeTo) }
            } catch {
                if isCancelled() {
                    discardStaging()
                    result.outcomes[i].status = .cancelled
                    // Nothing half-written is ever published under the real name, so the only
                    // thing that can be at the destination is something we did not put there.
                    result.outcomes[i].failures.append(
                        fm.fileExists(atPath: dest.path)
                        ? "cancelled; “\(dest.path)” was left alone — this transfer did not create it"
                        : "cancelled before it finished; nothing was left at the destination")
                    restoreReplaced()
                    break
                }
                discardStaging()                       // ours, unambiguously
                do {
                    try fm.copyItem(at: src, to: writeTo)
                } catch let second {
                    discardStaging()
                    // Last resort: the bytes without the Mac metadata. A destination that
                    // cannot hold extended attributes — a Samba share with them turned off, or
                    // a name whose "._" sidecar would exceed 255 characters — fails every
                    // other attempt for a tagged or downloaded file. Losing a Finder tag is
                    // not a reason to lose the file. COPYFILE_EXCL, so it cannot overwrite
                    // anything that appeared in the meantime.
                    guard copyDataOnly(src, writeTo) else {
                        discardStaging()
                        log("transfer FAILED: “\(name)” → \(dest.path) — \(second.localizedDescription) (first attempt: \(error.localizedDescription))")
                        result.outcomes[i].status = .failed
                        result.outcomes[i].failures.append(describeTransferFailure(second, at: dest))
                        restoreReplaced()
                        continue
                    }
                    warning = "copied, but “\(dest.lastPathComponent)” could not keep its Finder tags or other extended attributes — the destination does not support them"
                    log("transfer: “\(name)” copied WITHOUT extended attributes — \(second.localizedDescription)")
                }
            }
            // Publish. The destination is checked again here because the whole point of
            // staging is that this is the first moment the real name is touched.
            if let staged {
                guard !fm.fileExists(atPath: dest.path) else {
                    discardStaging()
                    result.outcomes[i].status = .failed
                    result.outcomes[i].failures.append("destination appeared after the conflict check; retry the transfer")
                    restoreReplaced()
                    continue
                }
                do { try fm.moveItem(at: staged, to: dest) }
                catch {
                    discardStaging()
                    log("transfer FAILED: “\(name)” copied but could not be put in place at \(dest.path) — \(error.localizedDescription)")
                    result.outcomes[i].status = .failed
                    result.outcomes[i].failures.append(describeTransferFailure(error, at: dest))
                    restoreReplaced()
                    continue
                }
                // The rename moves the file; its AppleDouble sidecar does not always follow —
                // measured, the sidecar for a 254-character destination would need a 256-
                // character name, so it stays behind under the staging name. The file is in
                // place and correct, but its extended attributes did not arrive, and a hidden
                // "._.navigator-incoming-XXXX" is now litter on a shared drive.
                let orphan = staged.deletingLastPathComponent()
                    .appendingPathComponent("._" + staged.lastPathComponent)
                if fm.fileExists(atPath: orphan.path) {
                    try? fm.removeItem(at: orphan)
                    if warning == nil {
                        warning = "copied, but “\(dest.lastPathComponent)” could not keep its Finder tags or other extended attributes — the destination does not support them"
                        log("transfer: “\(name)” arrived without its extended attributes — the destination could not name their sidecar")
                    }
                }
            }
            if let warning { result.outcomes[i].warnings.append(warning) }
            if item.move, fm.fileExists(atPath: src.path) {
                // The fallback path copied instead of moving, so the source is still there.
                do { try fm.removeItem(at: src); result.outcomes[i].status = .moved }
                catch {
                    result.outcomes[i].status = .copied
                    result.outcomes[i].failures.append("copied, but the source could not be removed: \(error.localizedDescription)")
                }
            } else {
                result.outcomes[i].status = item.move ? .moved : .copied
            }
            if result.outcomes[i].status == .failed { restoreReplaced() }
            else if let stash = backup {
                // Same AppleDouble trap as the staging name: removing the stash alone leaves
                // "._navigator-replacing-XXXX" on the share forever.
                removeWithAppleDouble(stash)
                if fm.fileExists(atPath: stash.path) {
                    log("transfer: replaced copy of “\(name)” left behind at \(stash.path)")
                }
            }
            onFinish(i)
        }
        return result
    }
}

/// What a refresh actually has to re-read.
///
/// A refresh is triggered by the directory's mtime changing, which on these filesystems means
/// an add, a remove or a rename - NOT a file's contents being rewritten. So the thing that
/// changed is the set of NAMES, and a row whose name is still there can keep the details it
/// already has.
///
/// This matters because of what per-file attributes cost on a share. NetworkColumnRules has
/// the full picture; the short version is 73-106 ms PER ENTRY, and it does not matter which
/// API asks - resourceValues, raw lstat, concurrent lstat and getattrlistbulk all land in the
/// same band, because macOS's SMB client queries each file rather than using the metadata
/// SMB2 already returned with the directory listing. Independently re-measured at 92.9
/// ms/entry (getattrlistbulk) and 98.3 ms/entry (Foundation) across five folders on
/// //corp-pure02/data, against 4.7 ms/entry for a names-only readdir of the same folders.
///
/// So re-reading every row to notice one new file costs about a minute in a 672-entry folder,
/// and reading names to find out WHICH rows are new costs about three seconds.
///
/// The trade is that a file whose CONTENTS changed without the directory changing keeps its
/// previous size and date until the next full load. That is the same thing Finder does, it
/// only applies to the silent background refresh, and an explicit Refresh still re-reads
/// everything.
enum RefreshRules {

    struct Plan: Equatable {
        /// Names present before and still present: keep the details already held.
        var reuse: [String]
        /// Names that appeared since the last listing: these need their attributes read.
        var fetch: [String]
        /// Names that are gone.
        var dropped: [String]
        /// Nothing appeared and nothing left, so no attribute work is needed at all.
        var isUnchanged: Bool { fetch.isEmpty && dropped.isEmpty }
    }

    /// `fresh` is the authoritative order - the listing is rebuilt in it, so a rename that
    /// moves a row does not leave it stranded at its old position.
    static func plan(existing: [String], fresh: [String]) -> Plan {
        let had = Set(existing), now = Set(fresh)
        var reuse: [String] = [], fetch: [String] = []
        reuse.reserveCapacity(fresh.count)
        for name in fresh {
            if had.contains(name) { reuse.append(name) } else { fetch.append(name) }
        }
        // Dropped keeps the ORDER it had, so a caller reporting "3 items removed" lists them
        // the way the user last saw them rather than in hash order.
        return Plan(reuse: reuse, fetch: fetch, dropped: existing.filter { !now.contains($0) })
    }
}

// ===== Google Drive stubs =====

/// What a Drive "stub" file on disk points at, and how to get the REAL document.
///
/// Google Drive for desktop does not store a Google-native file's content on disk. A
/// .gdoc/.gsheet/.gslides is ~190 bytes of JSON holding an id. Reading one means asking
/// Google to export it.
///
/// WHICH export matters more than it looks. Docs' plain-text export flattens every
/// table to one cell per line:
///
///     txt export          .docx export
///     \t0                 0\tWD1\t0\t1\t1
///     \tWD1
///     \t0
///
/// A GDD that declares its symbols in a table — the most common shape — is therefore
/// UNREADABLE through the text export, and readable through the .docx export, because
/// that one keeps the row. So Docs are fetched as .docx and read with the same reader a
/// local .docx goes through; Sheets as TSV, which is already the shape the row parser
/// wants; Slides as text, which is all a deck has.
public struct DriveStub: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case document, spreadsheet, presentation, drawing, form, site

        public init?(fileExtension ext: String) {
            switch ext.lowercased() {
            case "gdoc":    self = .document
            case "gsheet":  self = .spreadsheet
            case "gslides": self = .presentation
            case "gdraw":   self = .drawing
            case "gform":   self = .form
            case "gsite":   self = .site
            default:        return nil
            }
        }

        /// The path segment Google uses for this kind of file.
        var segment: String {
            switch self {
            case .document: return "document"
            case .spreadsheet: return "spreadsheets"
            case .presentation: return "presentation"
            case .drawing: return "drawings"
            case .form, .site: return ""
            }
        }

        /// The export format asked for, and the extension the answer is saved under.
        /// nil when there is no text to get.
        public var export: (format: String, fileExtension: String)? {
            switch self {
            // .docx, NOT txt — txt loses the tables, and the tables are the symbol set.
            case .document:     return ("docx", "docx")
            // Already tab-separated, which is exactly what the row reader parses.
            case .spreadsheet:  return ("tsv", "tsv")
            case .presentation: return ("txt", "txt")
            // A drawing is a picture and a form/site is not a document.
            case .drawing, .form, .site: return nil
            }
        }

        public var label: String {
            switch self {
            case .document: return "Google Doc"
            case .spreadsheet: return "Google Sheet"
            case .presentation: return "Google Slides"
            case .drawing: return "Google Drawing"
            case .form: return "Google Form"
            case .site: return "Google Site"
            }
        }

        /// Why this kind cannot be read, for the user rather than the log.
        public var cannotReadReason: String? {
            switch self {
            case .drawing: return "a Google Drawing is a picture, with no text to read"
            case .form:    return "a Google Form has no document text"
            case .site:    return "a Google Site is a website, not a document"
            default:       return nil
            }
        }
    }

    public let id: String
    public let resourceKey: String
    public let kind: Kind

    public init(id: String, resourceKey: String = "", kind: Kind) {
        self.id = id; self.resourceKey = resourceKey; self.kind = kind
    }

    /// Read a stub file's JSON. Drive writes the same shape for every type.
    ///
    /// Older stubs carry `resource_id` ("document:<id>") instead of `doc_id`, and files
    /// shared by link since 2021 carry a `resource_key` that the export refuses to work
    /// without.
    public static func parse(json: String, fileExtension ext: String) -> DriveStub? {
        guard let kind = Kind(fileExtension: ext),
              let d = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        else { return nil }
        var id = (o["doc_id"] as? String) ?? ""
        if id.isEmpty, let r = o["resource_id"] as? String {
            id = r.contains(":") ? String(r.split(separator: ":").last!) : r
        }
        guard !id.isEmpty else { return nil }
        return DriveStub(id: id, resourceKey: (o["resource_key"] as? String) ?? "", kind: kind)
    }

    /// The URL that returns the real content, or nil when there is none to get.
    public var exportURL: URL? {
        guard let e = kind.export, !kind.segment.isEmpty else { return nil }
        var s = "https://docs.google.com/\(kind.segment)/d/\(id)/export?format=\(e.format)"
        // A resource key is required for files shared by link; without it the export
        // answers 404 even though the document opens fine in a browser.
        if !resourceKey.isEmpty { s += "&resourcekey=\(resourceKey)" }
        return URL(string: s)
    }

    /// The document as a PERSON opens it, which is not the export endpoint.
    ///
    /// `exportURL` answers with a .docx download; handing that to a browser downloads a
    /// file instead of showing the document. The whole point of opening a GDD from the
    /// window is to read it, so this is the /edit page.
    public var viewURL: URL? {
        guard !kind.segment.isEmpty else { return nil }
        var s = "https://docs.google.com/\(kind.segment)/d/\(id)/edit"
        if !resourceKey.isEmpty { s += "?resourcekey=\(resourceKey)" }
        return URL(string: s)
    }

    /// The extension the downloaded file must be saved under for its reader to work.
    public var fileExtension: String { kind.export?.fileExtension ?? "bin" }

    /// A second format to try when the first export fails.
    ///
    /// Docs' plain-text export is lossy — it flattens tables — so it is the fallback and
    /// never the first choice. But a document that refuses to export as .docx and does
    /// export as text is a document read rather than a document lost, and the rule is
    /// that the tool reads the GDD.
    public var fallbackExportURL: URL? {
        guard kind == .document else { return nil }
        var s = "https://docs.google.com/document/d/\(id)/export?format=txt"
        if !resourceKey.isEmpty { s += "&resourcekey=\(resourceKey)" }
        return URL(string: s)
    }
}

/// What a scan of the GDD folder found, per document.
///
/// Two thirds of the documents in a real GDD folder declare no symbol set at all —
/// they are Power Bet variants, R&D notes and framework documents that describe a
/// mechanic layered onto an existing game. Listing them beside the ones that CAN be
/// turned into art just makes the picker a guessing game.
///
/// So this records what each document actually contained, and the picker hides the
/// empty ones. Deliberately NOT a hardcoded list of names: a GDD in progress gains its
/// symbol set later, documents get renamed, new ones arrive. A result is a measurement
/// with a date on it, it can be re-taken, and nothing is ever hidden that the user
/// cannot show again.
public struct GDDScanResult: Codable, Equatable, Sendable {
    /// doc id for a Drive file, path for a local one — survives a rename either way.
    public let key: String
    public let name: String
    public let symbolCount: Int
    public let checkedAt: Date
    /// Set when the document could not be read at all, as opposed to read and empty.
    /// An unreadable document is NOT hidden: "we failed" and "there is nothing there"
    /// are different answers and only one of them is the document's fault.
    public let failure: String?

    public init(key: String, name: String, symbolCount: Int, checkedAt: Date,
                failure: String? = nil) {
        self.key = key; self.name = name; self.symbolCount = symbolCount
        self.checkedAt = checkedAt; self.failure = failure
    }

    public var declaresNothing: Bool { failure == nil && symbolCount == 0 }
}

public enum GDDScanRules {
    /// Keys to hide: read successfully, and declared no symbols.
    public static func hiddenKeys(_ results: [GDDScanResult]) -> Set<String> {
        Set(results.filter(\.declaresNothing).map(\.key))
    }

    public static func encode(_ results: [GDDScanResult]) -> Data? {
        try? JSONEncoder().encode(results)
    }

    public static func decode(_ data: Data?) -> [GDDScanResult] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([GDDScanResult].self, from: data)) ?? []
    }

    /// A one-line summary for the window.
    public static func summary(_ results: [GDDScanResult]) -> String? {
        guard !results.isEmpty else { return nil }
        let empty = results.filter(\.declaresNothing).count
        let failed = results.filter { $0.failure != nil }.count
        var s = "\(results.count - empty - failed) of \(results.count) documents declare a symbol set"
        if empty > 0 { s += " · \(empty) declare none and are hidden" }
        if failed > 0 { s += " · \(failed) couldn’t be read" }
        return s
    }
}

/// Laying a theme out as one line of a macOS menu.
///
/// A menu item sizes itself to its content and ignores flexible space, so columns in a
/// Picker cannot be laid out — they have to be padded, in a monospaced row. Pure so the
/// alignment can be checked without opening a window.
public enum ThemeRowRules {
    public static let minNameWidth = 14
    public static let maxNameWidth = 36

    /// The name column width for a list: as wide as its widest name, within bounds, so
    /// the columns shrink with a filtered list instead of leaving a canyon of spaces.
    public static func nameWidth(forNames names: [String]) -> Int {
        min(max(names.map(\.count).max() ?? minNameWidth, minNameWidth), maxNameWidth)
    }

    /// "Piggy Banks              T1    👍 2"
    public static func label(name: String, tier: String, votes: Int, nameWidth: Int) -> String {
        var n = name
        if n.count > nameWidth { n = String(n.prefix(max(1, nameWidth - 1))) + "…" }
        let namePad = String(repeating: " ", count: max(0, nameWidth - n.count))
        // Two columns for the tier whether or not there is one, so a theme with no tier
        // does not shunt its vote count left and break the column.
        let t = String(tier.prefix(2))
        let tierPad = String(repeating: " ", count: max(0, 2 - t.count))
        let v = votes > 0 ? "👍 \(votes)" : ""
        return "\(n)\(namePad)   \(t)\(tierPad)   \(v)"
    }
}

// ===== Art styles =====

/// One rendering style a game's art can be drawn in.
///
/// Ported from the art-style list the previous HTML tool carried: written for slot
/// symbols on a phone, so every one of them is about HOW something is drawn — colour,
/// light, edge, surface — and none of them about WHAT is in the picture. That split is
/// the point. The theme says what the world is; this says how it is rendered, and the
/// two must never argue.
///
/// Styles built on a drawn contour — cel shading, anime line art, pixel outlines, neon
/// stroke work, vector keylines, card illustration — were removed at the studio's
/// request. A hard black outline is the single most complained-about artefact in this
/// pipeline; offering eight styles that mandate one was working against that. Separation
/// here comes from rim light and painted colour meeting, never a traced stroke.
///
/// The old list also held about forty entries named after specific games and studios —
/// "Nintendo Style", "Pokemon Style", "World of Warcraft Style". Those looks ARE here,
/// under the Video Game Styles category, rewritten as descriptions of the rendering.
///
/// Two reasons, and the second matters more. A studio's name in a prompt asks a model to
/// reproduce that studio's protected art in a commercial product. And it is a bad
/// instruction: "Nintendo Style" is as likely to draw Mario as it is to produce the
/// bright rounded finish that was actually wanted. "Rounded friendly forms, bright
/// primary dominance, glossy plastic-like highlight" cannot draw anyone's character and
/// says precisely what to do.
///
/// The originals also broke this list's own rule. Most described CONTENT, not rendering
/// — "hellish demon environments", "vampire hunter visual themes", "stadium
/// environments" — which in a slot symbol prompt drags a different game's subject matter
/// into the picture. Forty-three entries carried perhaps eighteen distinct RENDERINGS
/// between them; the duplicates were different subjects wearing the same technique.
public struct SlotArtStyle: Equatable, Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let category: String
    /// The rendering direction itself, as keywords. Goes straight into the prompt.
    public let keywords: String

    public init(id: String, name: String, category: String, keywords: String) {
        self.id = id; self.name = name; self.category = category; self.keywords = keywords
    }

    /// True when line work is part of THIS style rather than a defect in it.
    ///
    /// Cel shading, pixel art, vector casino art and card illustration all use a drawn
    /// contour on purpose. Suppressing it for them would be the same mistake as telling a
    /// framed symbol "no frame": two instructions in one prompt, pulling opposite ways.
    ///
    /// Read from the style's own words rather than a hand-kept list, so a style added
    /// later is classified by what it says it is.
    public var usesLineWork: Bool {
        let k = keywords.lowercased()
        for t in ["outline", "line art", "lineart", "keyline", "line work", "linework",
                  "contour line", "inked", "ink line"] where k.contains(t) { return true }
        return false
    }
}

public enum SlotArtStyles {
    public static let all: [SlotArtStyle] = [
        // Cartoon & Whimsical Styles
        SlotArtStyle(id: "whimsical-soft-palette", name: "Whimsical Soft Palette",
                     category: "Cartoon & Whimsical Styles",
                     keywords: "desaturated pastel palette, wet-blended watercolour transitions with visible bleed at the edges, diffuse light with no hard shadow, low overall contrast, organic curved forms, soft granulated paper texture, glow falling off gently"),
        SlotArtStyle(id: "playful-inviting", name: "Playful Inviting",
                     category: "Cartoon & Whimsical Styles",
                     keywords: "bright candy-toned fills, smooth airbrushed shading with soft round highlights, rounded thick-cornered forms, warm high-key light, gentle drop shadow under each mass, low texture noise, glossy sheen on curved surfaces"),
        SlotArtStyle(id: "quirky-humorous", name: "Quirky Humorous",
                     category: "Cartoon & Whimsical Styles",
                     keywords: "exaggerated proportion with oversized features and tiny extremities, bouncy asymmetric shapes, bright clashing hue pairs, chunky shading in two or three flat steps with a hard terminator, springy tapering forms, soft rounded highlights, low texture"),
        SlotArtStyle(id: "modern-fun", name: "Modern Fun",
                     category: "Cartoon & Whimsical Styles",
                     keywords: "clean flat-plus-gradient rendering, fresh saturated palette with one accent hue, smooth digital shading, crisp geometric edges, minimal texture, even frontal light, generous negative space, contemporary poster-like clarity"),

        // Realistic & Stylized Approaches
        SlotArtStyle(id: "realistic-stylized", name: "Realistic Stylized",
                     category: "Realistic & Stylized Approaches",
                     keywords: "photoreal material behaviour simplified into broad planes, accurate reflectance and falloff, natural palette with controlled saturation, subtle subsurface warmth in organic surfaces, fine detail concentrated at the focal feature"),
        SlotArtStyle(id: "calming-realistic", name: "Calming Realistic",
                     category: "Realistic & Stylized Approaches",
                     keywords: "soft diffuse light from a broad source, narrow value range in the mid-tones, gentle tonal transitions with no hard terminator, muted cool-leaning palette, matte surfaces with restrained specular, low contrast overall"),
        SlotArtStyle(id: "sharp-detailed", name: "Sharp Detailed",
                     category: "Realistic & Stylized Approaches",
                     keywords: "crisp high-definition edges, clean precise edge definition, tight focus across the whole form, strong local contrast, fine legible surface detail, hard-edged specular highlights, precise colour boundaries with no bleed"),
        SlotArtStyle(id: "luxurious-opulent", name: "Luxurious Opulent",
                     category: "Realistic & Stylized Approaches",
                     keywords: "deep gold and jewel-tone palette, high specular range with sharp reflections and warm bounce, polished metal and faceted gem surfaces, rich dark mid-tones, ornament rendered with real depth and cast shadow"),
        SlotArtStyle(id: "ornate-decorative", name: "Ornate Decorative",
                     category: "Realistic & Stylized Approaches",
                     keywords: "repeating ornamental pattern carried in low relief, controlled palette of two metals and one accent hue, crisp incised edges with shadow in every groove, narrow specular catching each raised contour, symmetrical construction, restrained saturation, patterned areas kept broad"),
        SlotArtStyle(id: "gritty-intense", name: "Gritty Intense",
                     category: "Realistic & Stylized Approaches",
                     keywords: "rough weathered surfaces with chipping, pitting and abrasion, desaturated earth palette, harsh directional light with hard shadow edges, heavy grain and dust, crushed blacks, worn matte finish with dull broken highlights"),

        // Atmospheric & Lighting Styles
        SlotArtStyle(id: "dramatic-mythical", name: "Dramatic Mythical",
                     category: "Atmospheric & Lighting Styles",
                     keywords: "strong single key light from low or behind, long cast shadows, wide value range from near-black to blown highlight, warm key against cool shadow, atmospheric haze separating depth, monumental scale cues"),
        SlotArtStyle(id: "soft-ethereal", name: "Soft Ethereal",
                     category: "Atmospheric & Lighting Styles",
                     keywords: "luminous diffuse glow with light appearing to come from within, pale cool palette, very soft edges and low contrast, bloom spreading around bright areas, translucent layered veils, no hard shadow anywhere"),
        SlotArtStyle(id: "cold-mysterious", name: "Cold Mysterious",
                     category: "Atmospheric & Lighting Styles",
                     keywords: "icy blue-cyan dominance, crystalline hard-edged highlights, cool shadow with almost no warm bounce, high clarity in the lights and deep density in the darks, frosted matte surfaces, breath-like haze in the depth"),
        SlotArtStyle(id: "warm-golden-lighting", name: "Warm Golden Lighting",
                     category: "Atmospheric & Lighting Styles",
                     keywords: "low warm key light raking across the form, amber and honey palette, long soft shadows, strong warm-to-cool shift from lit to shadow side, glowing bounce in the half-tones, gentle bloom on the brightest edges"),
        SlotArtStyle(id: "dynamic-lighting", name: "Dynamic Lighting",
                     category: "Atmospheric & Lighting Styles",
                     keywords: "multiple coloured light sources from opposing directions, strong light-to-shadow contrast, hard-edged coloured rim on opposite sides, energetic falloff, saturated shadows carrying the secondary hue, cinematic separation of planes"),

        // Bold & Vivid Styles
        SlotArtStyle(id: "vivid-bold", name: "Vivid Bold",
                     category: "Bold & Vivid Styles",
                     keywords: "maximum chroma with pure unmixed hues, flat broad colour masses, high hue contrast between adjacent shapes, minimal tonal shading, thick confident shape language, poster-like clarity at small size"),
        SlotArtStyle(id: "high-contrast-vintage", name: "High-Contrast Vintage",
                     category: "Bold & Vivid Styles",
                     keywords: "limited retro palette of three or four inks, heavy value separation with little mid-tone, slight registration offset and halftone dot texture, faded paper warmth, flat fills with simple hard shading"),
        SlotArtStyle(id: "bright-tropical", name: "Bright Tropical",
                     category: "Bold & Vivid Styles",
                     keywords: "hot saturated greens, corals and turquoise, strong overhead sun with short dense shadows, high chroma throughout, glossy wet-looking surfaces, sharp dappled highlights, vivid complementary pairings"),
        SlotArtStyle(id: "electric-neon", name: "Electric Neon",
                     category: "Bold & Vivid Styles",
                     keywords: "glowing additive light on a dark ground, fluorescent cyan magenta and lime, bright cores with wide soft bloom, deep near-black shadow, luminous saturated edges, colour bleeding into the surrounding darkness"),
        SlotArtStyle(id: "high-energy-dynamic", name: "High-Energy Dynamic",
                     category: "Bold & Vivid Styles",
                     keywords: "diagonal thrust in every shape, strong directional blur on secondary forms, high chroma with hot accent against cool field, hard contrast between lit and shadow, sharp leading edges and trailing softness"),
        SlotArtStyle(id: "bold-sultry", name: "Bold Sultry",
                     category: "Bold & Vivid Styles",
                     keywords: "deep jewel reds and blacks, low-key lighting with a single warm key, rich dark mid-tones, soft falloff on curved surfaces, satin sheen with broad gentle highlights, restrained detail and generous shadow"),
        SlotArtStyle(id: "thrilling-adventure", name: "Thrilling Adventure",
                     category: "Bold & Vivid Styles",
                     keywords: "warm golden key with deep shadow, dusty sunlit haze, saturated earth and brass palette, strong contrast between lit planes and shade, weathered surfaces with catching highlights, energetic diagonal light"),

        // Elegant & Sophisticated Styles
        SlotArtStyle(id: "sleek-elegant", name: "Sleek Elegant",
                     category: "Elegant & Sophisticated Styles",
                     keywords: "restrained palette of two or three close hues, smooth even gradients, polished surfaces with long clean specular sweeps, precise uncluttered forms, controlled mid-range contrast, generous empty space, no texture noise"),
        SlotArtStyle(id: "sleek-mysterious", name: "Sleek Mysterious",
                     category: "Elegant & Sophisticated Styles",
                     keywords: "low-key palette with one cool accent, most of the form falling into soft shadow, a single narrow highlight describing the silhouette, smooth glossy surfaces, gradual falloff, deep unbroken darks"),

        // Fantasy & Magical Styles
        SlotArtStyle(id: "kaleidoscope-magical", name: "Kaleidoscope Magical",
                     category: "Fantasy & Magical Styles",
                     keywords: "prismatic colour-shifting across surfaces, symmetrical repeating facet patterns, refracted rainbow dispersion at the edges, high chroma with iridescent transitions, glassy hard highlights, radial symmetry"),
        SlotArtStyle(id: "epic-heroic", name: "Epic Heroic",
                     category: "Fantasy & Magical Styles",
                     keywords: "strong low key light with a warm rim separating the form, wide value range, monumental proportion, saturated but controlled palette, broad confident shading masses, detail concentrated at the focal feature"),
        SlotArtStyle(id: "mystical-expansive", name: "Mystical Expansive",
                     category: "Fantasy & Magical Styles",
                     keywords: "deep space-like darks with luminous coloured mist, layered atmospheric depth with each plane lighter and cooler, glowing point highlights, soft-edged forms, low contrast in the distance and crisp in the front"),
        SlotArtStyle(id: "electric-divine", name: "Electric Divine",
                     category: "Fantasy & Magical Styles",
                     keywords: "radiant white-hot core with saturated coloured falloff, light emitted rather than reflected, sharp lens-like flare spikes, strong bloom, cool shadow against hot key, high contrast at the light source"),
        SlotArtStyle(id: "captivating-mythology-scifi", name: "Captivating Mythology Sci-Fi",
                     category: "Fantasy & Magical Styles",
                     keywords: "polished metal and stone side by side, cool cyan emissive accents on warm classical forms, hard specular on machined surfaces beside soft matte on carved ones, controlled palette, crisp panel and relief detail"),

        // Nature & Elemental Styles
        SlotArtStyle(id: "deep-nature-connected", name: "Deep Nature Connected",
                     category: "Nature & Elemental Styles",
                     keywords: "soft dappled light filtered through layers, muted green and earth palette, organic irregular shapes, matte surfaces with fine natural grain, humid atmospheric depth, gentle contrast and low specular"),
        SlotArtStyle(id: "dynamic-natural-forces", name: "Dynamic Natural Forces",
                     category: "Nature & Elemental Styles",
                     keywords: "turbulent directional motion in the forms, spray and particulate catching the light, high contrast between mass and highlight, cool desaturated palette with white foam or flare, hard-edged energy against soft haze"),

        // Cultural & Regional Styles
        SlotArtStyle(id: "exotic-colorful", name: "Exotic Colorful",
                     category: "Cultural & Regional Styles",
                     keywords: "dense saturated pattern in layered warm hues, flat decorative colour with fine linear ornament, strong hue contrast between adjacent bands, matte surfaces, even light, rich detail kept in broad readable zones"),
        SlotArtStyle(id: "oriental-fusion", name: "Oriental Fusion",
                     category: "Cultural & Regional Styles",
                     keywords: "ink-wash tonal gradation against flat colour fields, restrained palette of red black and gold, deliberate negative space, soft brush transitions beside hard graphic edges, gentle even light, matte paper grain, minimal specular"),
        SlotArtStyle(id: "simplified-celtic", name: "Simplified Celtic",
                     category: "Cultural & Regional Styles",
                     keywords: "interlaced knot ornament carved in low relief, restrained palette of stone grey with gold and moss, raking light picking out every incised groove, matte weathered surfaces, symmetrical construction, broad simple masses"),

        // Modern & Futuristic Styles
        SlotArtStyle(id: "high-energy-scifi", name: "High-Energy Sci-Fi",
                     category: "Modern & Futuristic Styles",
                     keywords: "cool blue-grey base with hot emissive accent strips, hard specular on brushed and anodised metal, machined bevels and panel seams, controlled reflections, high contrast between lit surfaces and deep shadow"),

        // Material & Texture Styles
        SlotArtStyle(id: "shiny-metallic", name: "Shiny Metallic",
                     category: "Material & Texture Styles",
                     keywords: "polished reflective metal with sharp mirrored highlights and dark reflected occlusion, gold silver and bronze tonal families, high specular contrast, crisp bevelled edges catching a hard light"),
        SlotArtStyle(id: "vintage-brass-wood", name: "Vintage Brass Wood",
                     category: "Material & Texture Styles",
                     keywords: "aged brass with patina in the recesses beside oiled grained wood, warm amber palette, soft directional light, satin rather than mirror specular, visible turned and riveted construction, fine honest wear"),
        SlotArtStyle(id: "crystalline-gem", name: "Crystalline Gem",
                     category: "Material & Texture Styles",
                     keywords: "faceted transparent surfaces with internal refraction and caustic sparkle, sharp facet boundaries, bright specular points, colour deepening through thickness, cool highlights against saturated core"),
        SlotArtStyle(id: "rugged-medieval", name: "Rugged Medieval",
                     category: "Material & Texture Styles",
                     keywords: "hammered iron and rough-hewn timber, desaturated earth palette, hard directional light raking the texture, heavy cast shadow in every recess, matte pitted surfaces, honest joinery and visible tool marks"),

        // Special Atmosphere Styles
        SlotArtStyle(id: "gothic-carnival", name: "Gothic Carnival",
                     category: "Special Atmosphere Styles",
                     keywords: "saturated crimson and violet against deep shadow, theatrical footlight from below, striped and scalloped ornament, high contrast with hot accent lights, glossy painted surfaces, uneasy tilted forms"),
        SlotArtStyle(id: "suspenseful-noir", name: "Suspenseful Noir",
                     category: "Special Atmosphere Styles",
                     keywords: "hard single-source light with sharp-edged shadow, near-monochrome palette with one warm accent, crushed blacks and blown highlights, venetian slat shadow patterns, high contrast and heavy vignette"),
        SlotArtStyle(id: "chilling-immersive", name: "Chilling Immersive",
                     category: "Special Atmosphere Styles",
                     keywords: "desaturated cold palette with sickly green undertone, weak diffuse light with heavy shadow, low contrast in the mid-tones and deep density in the darks, damp matte surfaces, fog thickening with depth"),
        SlotArtStyle(id: "eerie-thrilling", name: "Eerie Thrilling",
                     category: "Special Atmosphere Styles",
                     keywords: "cold underlit key throwing shadows upward, unnatural green-cyan accents against warm decay, sharp contrast at the light source with soft murk elsewhere, wet glistening surfaces, grain in the shadows"),
        SlotArtStyle(id: "gothic-romantic", name: "Gothic Romantic",
                     category: "Special Atmosphere Styles",
                     keywords: "deep crimson and black with candle-warm key, soft falloff on skin and velvet, heavy shadow enveloping the periphery, ornate relief detail catching narrow highlights, low-key with rich saturated darks"),

        // Energy & Light Effects
        SlotArtStyle(id: "glowing-luminous", name: "Glowing Luminous",
                     category: "Energy & Light Effects",
                     keywords: "self-illuminating surfaces with a bright core and wide soft bloom, light spilling onto neighbouring forms, saturated colour in the glow and desaturated white at the centre, dark surroundings for contrast"),
        SlotArtStyle(id: "high-energy-jewel", name: "High-Energy Jewel",
                     category: "Energy & Light Effects",
                     keywords: "intense saturated gem hues with hard sparkle points, sharp facet highlights, strong internal light, high chroma against dark settings, crisp edge definition, brilliant specular flashes"),
        SlotArtStyle(id: "radiant-prismatic", name: "Radiant Prismatic",
                     category: "Energy & Light Effects",
                     keywords: "white light split into spectral bands across the surface, smooth rainbow gradients with hard-edged transitions where facets break, bright bloom at the source, iridescent sheen shifting with curvature")
,

        // Video Game Styles
        SlotArtStyle(id: "hand-painted-heroic", name: "Hand-Painted Heroic",
                     category: "Video Game Styles",
                     keywords: "hand-painted texture with visible brush direction baked into the surface, exaggerated chunky silhouette, oversized forms and thick tapering shapes, warm rim light separating the subject from behind, rich saturated midtones, soft occlusion in the crevices, painterly detail that stays legible when small, heavy confident shapes over fine detail"),
        SlotArtStyle(id: "clean-stylized-3d", name: "Clean Stylized 3D",
                     category: "Video Game Styles",
                     keywords: "smooth matte surfaces with gentle falloff, soft ambient occlusion, rounded bevelled edges catching a soft highlight, bright saturated primaries, minimal texture noise, clean broad shapes, even studio-like key light, glossy accents on metal and glass only, polished toy-like finish"),
        SlotArtStyle(id: "dark-painterly-gothic", name: "Dark Painterly Gothic",
                     category: "Video Game Styles",
                     keywords: "low-key value range with the subject lit against deep shadow, desaturated palette broken by one hot accent, painterly texture with heavy impasto in the highlights, strong chiaroscuro, cold shadow and warm key, aged and pitted surfaces, atmospheric haze in the depth, dramatic downward lighting"),
        SlotArtStyle(id: "airbrushed-fantasy", name: "Airbrushed Fantasy",
                     category: "Video Game Styles",
                     keywords: "soft airbrushed blending with no visible brush marks, luminous atmospheric depth, delicate gradient transitions, cool ambient light with warm magical accent glow, fine jewel and fabric detail, glassy reflective highlights, cinematic rim lighting, refined polished finish"),
        SlotArtStyle(id: "gritty-photoreal", name: "Gritty Photoreal",
                     category: "Video Game Styles",
                     keywords: "physically based realistic materials, desaturated cool palette with crushed blacks, fine surface detail — scratches, grain, wear, dust, harsh directional light with hard shadow edges, shallow depth of field, subtle lens grain and vignette, muted colour grading, unstylised proportions"),
        SlotArtStyle(id: "period-muted-realism", name: "Period Muted Realism",
                     category: "Video Game Styles",
                     keywords: "muted earthy palette of ochre, stone grey and oxidised metal, realistic material rendering with age and patina, heavy architectural and ornamental detail, soft overcast light with gentle shadow falloff, restrained saturation, textural richness in cloth, leather and masonry, historical craftsmanship in every surface"),
        SlotArtStyle(id: "voxel-blocks", name: "Voxel Blocks",
                     category: "Video Game Styles",
                     keywords: "cubic voxel construction with visible blocky facets, flat per-face shading with no smoothing, low-resolution square textures, hard-edged geometric forms, simple directional light giving three distinct face values, chunky modular shapes"),
        SlotArtStyle(id: "bright-toy-3d", name: "Bright Toy 3D",
                     category: "Video Game Styles",
                     keywords: "rounded friendly forms with thick soft edges, bright primary colour dominance, smooth even shading with soft shadow, glossy plastic-like highlight, minimal surface texture, cheerful high-key lighting, generous simple shapes, clean and uncluttered"),
        SlotArtStyle(id: "clean-minimal", name: "Clean Minimal",
                     category: "Video Game Styles",
                     keywords: "flat colour with almost no shading, sparse restrained palette, simple geometric construction, generous empty space, crisp hard edges, no texture or noise, even flat lighting, iconographic simplified forms, immediate readability"),
        SlotArtStyle(id: "cold-industrial-scifi", name: "Cold Industrial Sci-Fi",
                     category: "Video Game Styles",
                     keywords: "cold blue-grey palette with emissive accent strips, brushed and anodised metal surfaces, panel seams and machined bevels, hard specular highlights on edges, functional geometric forms, controlled reflections, technical precision in every surface"),
        SlotArtStyle(id: "motion-streak", name: "Motion Streak",
                     category: "Video Game Styles",
                     keywords: "strong directional motion blur and speed streaks, stretched trailing highlights, high-contrast saturated colour, dynamic diagonal composition, sharp leading edge against a blurred tail, energetic light trails, exaggerated sense of velocity"),
    ]

    public static func byID(_ id: String?) -> SlotArtStyle? {
        guard let id, !id.isEmpty else { return nil }
        return all.first { $0.id == id }
    }

    /// Categories in their listed order, each with its styles — the order a picker shows.
    public static var byCategory: [(category: String, styles: [SlotArtStyle])] {
        var order: [String] = []
        for s in all where !order.contains(s.category) { order.append(s.category) }
        return order.map { c in (c, all.filter { $0.category == c }) }
    }

    /// Styles whose name or keywords contain `query`, for the search field.
    public static func search(_ query: String) -> [SlotArtStyle] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(q) || $0.category.lowercased().contains(q)
                || $0.keywords.lowercased().contains(q)
        }
    }
}

public enum SlotSymbolRole: String, Sendable, CaseIterable {
    case wild, highPay, mediumPay, lowPay, scatter, bonus, jackpot
    case wysiwyg, collector, multiplier, replacement, blank, unknown
    /// SF codes cover four different jobs, and the prefix alone cannot tell them apart —
    /// the design document's own words can. See SlotSymbolRole.refined(byNote:).
    case activator, adder

    /// How the role reads to a person, for the plan table.
    public var label: String {
        switch self {
        case .wild: return "Wild"
        case .highPay: return "High pay"
        case .mediumPay: return "Medium pay"
        case .lowPay: return "Low pay"
        case .scatter: return "Scatter"
        case .bonus: return "Bonus"
        case .jackpot: return "Jackpot"
        case .wysiwyg: return "WYSIWYG value"
        case .collector: return "Collector"
        case .activator: return "Activator"
        case .adder: return "Adder"
        case .multiplier: return "Multiplier"
        case .replacement: return "Replacement"
        case .blank: return "Blank"
        case .unknown: return "Unclassified"
        }
    }

    /// The job a special-feature symbol actually does, read from what the design document
    /// says about it rather than from its code.
    ///
    /// SF is one prefix covering four jobs. Defaulting every SF to "collector" is how an
    /// adder ends up drawn as a vessel with a running total it never has. When the
    /// document does not say, collector stays the default — but it is a default, not a
    /// deduction.
    public func refined(byNote note: String) -> SlotSymbolRole {
        guard self == .collector else { return self }
        let n = note.lowercased()
        // A note that denies its verb must not be read as asserting it: "Does not
        // activate a feature" was coming back .activator.
        for d in ["does not", "doesn't", "do not", "don't", "cannot", "can't", "never ",
                  "no longer", "rather than", "instead of"] where n.contains(d) {
            return .collector
        }
        // A symbol the document calls its most valuable is a PAYING symbol, whatever its
        // code says. 4490 writes "SFs - highest value, full body, full color, full
        // frames" — those are the game's premium characters, and drawing them as
        // collector pickups throws away the document's own ranking.
        for v in ["highest value", "highest paying", "high value", "premium", "top pay",
                  "most valuable"] where n.contains(v) {
            return .highPay
        }
        // What the symbol DOES comes before what it acts on. "Collects all multiplier
        // values" is a collector; matching "multipl" first made it a multiplier, and the
        // two get drawn differently.
        if n.contains("collect") || n.contains("gather") { return .collector }
        if n.contains("multipl") { return .multiplier }
        if n.contains("adds ") || n.contains("adder") || n.contains("addition") { return .adder }
        if n.contains("activat") || n.contains("trigger") || n.contains("unlock") { return .activator }
        return .collector
    }

    /// Roles whose members are DELIBERATELY one family, so sharing a word between them is
    /// the design working rather than a collision.
    ///
    /// Low pays are one family by rule — all royals, or all gems, or all pebbles. Jackpots
    /// are one shared construction separated by tier colour and name, which is what
    /// shipping games do and what the art direction now demands. Reporting "chest (JP1,
    /// JP2, JP3, JP4)" as a fault told the user their correct set was broken.
    public var isFamily: Bool { self == .lowPay || self == .jackpot || self == .wysiwyg }

    /// A blank is an empty reel position. Everything else is a picture someone has to draw.
    public var needsArt: Bool { self != .blank }

    /// Rough drawing order: the symbols that set the game's look come first, so a
    /// part-finished run still shows the art that decides whether the set is working.
    public var priority: Int {
        switch self {
        case .highPay: return 0
        case .wild: return 1
        case .collector: return 2
        case .activator, .adder: return 2
        case .scatter, .bonus: return 3
        case .mediumPay: return 4
        case .jackpot: return 5
        case .wysiwyg, .multiplier: return 6
        case .lowPay: return 7
        case .replacement: return 8
        case .blank, .unknown: return 9
        }
    }
}

/// One symbol slot, as the GDD defines it.
public struct SlotSymbol: Equatable, Sendable {
    public let code: String        // "HP1", "WD1", "JP3" — the GDD's own spelling
    public let index: Int          // its symbol-set index in the GDD
    public let role: SlotSymbolRole
    public let tier: Int?          // 1 for HP1, 3 for JP3; nil when the code carries no number
    public let note: String        // the GDD's own trailing comment, verbatim

    public init(code: String, index: Int, role: SlotSymbolRole, tier: Int?, note: String) {
        self.code = code; self.index = index; self.role = role; self.tier = tier; self.note = note
    }
}

/// Reading the "Symbol Set" block out of a GDD's exported plain text.
///
/// Both real formats in the wild are handled, because both exist in the same Drive
/// folder and differ in where the code sits relative to the comment marker:
///
///     * 1-4 HP1-4        // HPs                 (4260 Dodge — code before the //)
///     - 2-5 // MPs  (Standard MP symbols)       (4400 Chevy-Hot — code after it)
///
/// The second form also names a group rather than each member, so "2-5 // MPs" has
/// to become MP1…MP4 by counting the index range. Getting that wrong silently drops
/// four symbols from the game, which is exactly the kind of quiet miscount this
/// parser exists to prevent.

public enum GDDSymbolSetRules {
    /// Code prefix -> role. Order matters: longer prefixes first where one is a prefix
    /// of another.
    static let prefixes: [(String, SlotSymbolRole)] = [
        // Longest first: BWY1 is a bonus WYSIWYG, not a blank that happens to start
        // with B, and DHP a doubled high pay rather than an unknown.
        ("BWY", .wysiwyg), ("DHP", .highPay),
        ("WD", .wild), ("HP", .highPay), ("MP", .mediumPay), ("LP", .lowPay),
        ("SC", .scatter), ("BO", .bonus), ("BN", .bonus), ("JP", .jackpot),
        ("WY", .wysiwyg), ("SF", .collector), ("MU", .multiplier), ("BL", .blank),
        ("R", .replacement),
    ]

    /// The role a symbol code implies, plus its tier number when it carries one.
    /// Unknown codes are reported as `.unknown` rather than guessed into a role —
    /// a mis-roled symbol gets the wrong art direction, which is worse than being
    /// shown as unclassified and fixed by hand.
    public static func classify(_ code: String) -> (role: SlotSymbolRole, tier: Int?) {
        let up = code.uppercased()
        for (p, role) in prefixes where up.hasPrefix(p) {
            let rest = String(up.dropFirst(p.count))
            // "HP" + "1" is a tier; "HP" + "s" is the plural group name, not a tier.
            if rest.isEmpty { return (role, nil) }
            if let n = Int(rest) { return (role, n) }
            if rest == "S" { return (role, nil) }   // "MPs", "LPs"
            continue                                 // not really this prefix, keep looking
        }
        return (.unknown, nil)
    }

    /// Expand a code spec into individual codes.
    ///
    /// "HP1-4" -> HP1…HP4, "R1-2" -> R1, R2, "WD1" -> WD1, and a bare plural like
    /// "MPs" -> MP1…MPn where n is how many indices the line covers.
    static func expand(codeSpec: String, indexCount: Int) -> [String] {
        let s = codeSpec.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return [] }
        // "HP1-4" / "R1-2"
        if let dash = s.range(of: #"^([A-Za-z]+)(\d+)-(\d+)$"#, options: .regularExpression),
           dash.lowerBound == s.startIndex {
            let letters = s.prefix { $0.isLetter }
            let nums = s.dropFirst(letters.count).split(separator: "-").compactMap { Int($0) }
            // The span is bounded and must match how many indices the line covers.
            // Unbounded, a typo like "HP1-1000000000" tries to build a billion strings
            // on whatever thread is parsing; mismatched, "1-2 HP1-4" quietly produced
            // four symbols crammed onto two indices — two of them invented, and each
            // one an image someone would be charged for.
            if nums.count == 2, nums[0] <= nums[1], nums[1] - nums[0] < 64,
               nums[1] - nums[0] + 1 == indexCount {
                return (nums[0]...nums[1]).map { "\(letters)\($0)" }
            }
            return []   // reported by parseWithProblems — never dropped in silence
        }
        // "MPs" / "LPs" — a plural group, numbered by how many slots the line covers.
        if s.count >= 3, s.hasSuffix("s") || s.hasSuffix("S") {
            let stem = String(s.dropLast())
            if stem.allSatisfy({ $0.isLetter }), indexCount > 1 {
                return (1...indexCount).map { "\(stem.uppercased())\($0)" }
            }
        }
        // A single code. Over one index that is one symbol; over a range it is the same
        // group form as the plural above — "1-4 HP" means four high pays, and returning
        // a lone "HP" for it quietly turned four paid symbols into one.
        if s.allSatisfy({ $0.isLetter || $0.isNumber }) {
            if indexCount == 1 { return [s.uppercased()] }
            if s.allSatisfy({ $0.isLetter }) {
                return (1...indexCount).map { "\(s.uppercased())\($0)" }
            }
            return []   // "1-4 HP1" — a numbered code cannot cover four indices
        }
        return []
    }

    /// A symbol set typed by hand, for a game whose GDD does not exist yet.
    ///
    /// Not every game has a document to read. A producer who knows the set wants to say
    /// so directly — "WD, HP1-4, MP1-4, LP1-5, SC, BO, JP1-4" — and get on with it,
    /// rather than inventing a document for the tool's benefit.
    ///
    /// Accepts codes separated by commas, spaces or newlines, with ranges written the way
    /// the GDDs write them. Anything it cannot read is reported rather than dropped.
    public static func parseManual(_ text: String) -> (symbols: [SlotSymbol], problems: [String]) {
        let tokens = text
            .components(separatedBy: CharacterSet(charactersIn: ",\n\r\t "))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out: [SlotSymbol] = [], problems: [String] = [], seen = Set<String>()
        for token in tokens {
            // "HP1-4" -> HP1…HP4. indexCount is the span itself here, since a hand-typed
            // list has no reel indices to count against.
            let span: Int
            if let r = token.range(of: #"^[A-Za-z]+(\d+)-(\d+)$"#, options: .regularExpression),
               r.lowerBound == token.startIndex {
                let nums = token.drop { $0.isLetter }.split(separator: "-").compactMap { Int($0) }
                span = nums.count == 2 && nums[1] >= nums[0] ? nums[1] - nums[0] + 1 : 1
            } else { span = 1 }
            let codes = expand(codeSpec: token, indexCount: span)
            guard !codes.isEmpty else { problems.append(token); continue }
            for code in codes where !seen.contains(code) {
                seen.insert(code)
                let (role, tier) = classify(code)
                guard role != .unknown else { problems.append(code); continue }
                out.append(SlotSymbol(code: code, index: out.count, role: role, tier: tier, note: ""))
            }
        }
        return (out, problems)
    }

    /// A set to start from when there is no document — the shape most games take.
    public static let typicalSet = "WD, HP1-4, MP1-4, LP1-5, SC, BO, JP1-4"

    /// A symbol set laid out as a TABLE rather than a list.
    ///
    /// Exporting a Word table flattens it to one cell per line, so a "Name | Symbol ID"
    /// table arrives as a column of bare codes with their indices on the following
    /// lines — SF1 / 7 / 1 / (blank) / SF2 / 8 / 2. There is no "0 WD1 // wild" line
    /// anywhere, so the list parser finds nothing at all and the document reads as
    /// having no symbols.
    ///
    /// Requires several codes before believing it, because a single stray "R1" in prose
    /// is a reel, not a replacement symbol.
    static func parseTable(_ gddText: String, minimumCodes: Int = 4) -> [SlotSymbol] {
        var found: [(code: String, index: Int?)] = []
        let lines = gddText.components(separatedBy: .newlines)
        // Only inside a symbol table. Scanning the whole document meant any four bare
        // codes anywhere became a symbol set: "Reel definitions / R1 / R2 / R3 / R4"
        // returned four symbols, and a non-empty set is what stops the model fallback
        // from ever running — so the invented set was the one that got drawn and paid for.
        guard let head = lines.firstIndex(where: {
            $0.lowercased().contains("symbol")
        }) else { return [] }
        for (i, raw) in lines.enumerated() where i > head {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard isBareCode(line) else { continue }
            // The next non-empty line is the index when it is a plain number.
            var idx: Int? = nil
            var j = i + 1
            while j < lines.count, j <= i + 2 {
                let n = lines[j].trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { idx = Int(n); break }
                j += 1
            }
            found.append((line.uppercased(), idx))
        }
        var seen = Set<String>(), out: [SlotSymbol] = []
        for (n, f) in found.enumerated() where !seen.contains(f.code) {
            seen.insert(f.code)
            let (role, tier) = classify(f.code)
            guard role != .unknown else { continue }
            out.append(SlotSymbol(code: f.code, index: f.index ?? n, role: role,
                                  tier: tier, note: ""))
        }
        return out.count >= minimumCodes ? out.sorted { $0.index < $1.index } : []
    }

    /// True when a whole line is nothing but a symbol code.
    static func isBareCode(_ line: String) -> Bool {
        guard line.count >= 2, line.count <= 6 else { return false }
        let up = line.uppercased()
        // Casing is not a signal here — Word tables carry "HP1", "hp1" and "Hp1" alike.
        guard up.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        guard up.first?.isLetter == true, up.last?.isNumber == true else { return false }
        return classify(up).role != .unknown
    }

    /// Symbol codes the document TALKS about but never declares.
    ///
    /// Only codes from a family the set already has, and only numbered ones: a bare "LP"
    /// in a sentence is English, but a set holding WY1–WY3 next to prose saying "the
    /// wedges share the same IDs as WY1 - WY4" is a document that contradicts itself,
    /// and the missing symbol is one nobody will notice is absent until the art is due.
    ///
    /// This reports. It does not add them — a symbol mentioned in a sound cue may be a
    /// leftover from the game this one was cloned from, and inventing art for it costs
    /// real money. The judgement is the user's; the tool's job is to not hide it.
    public static func mentionedButNotDeclared(in gddText: String,
                                               symbols: [SlotSymbol]) -> [String] {
        guard !symbols.isEmpty else { return [] }
        let declared = Set(symbols.map(\.code))
        let families = Set(declared.map { String($0.prefix { $0.isLetter }) })
        var out = Set<String>()
        for tk in gddText.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let c = String(tk).uppercased()
            guard c.count >= 3, c.count <= 6, !declared.contains(c) else { continue }
            let letters = String(c.prefix { $0.isLetter })
            let digits = c.dropFirst(letters.count)
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
                  families.contains(letters) else { continue }
            out.insert(c)
        }
        return out.sorted()
    }

    /// Parse, and say what could not be read.
    ///
    /// A line the parser rejects is a symbol the game needs and will not get. Dropping it
    /// silently means the miscount only shows up when someone opens the folder and finds
    /// four symbols missing — so every rejected line inside the symbol-set block is
    /// reported, with its own text, for the user to judge.
    public static func parseWithProblems(_ gddText: String) -> (symbols: [SlotSymbol],
                                                                problems: [String]) {
        let symbols = parse(gddText)
        guard !symbols.isEmpty else { return (symbols, []) }
        let lines = gddText.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("symbol set")
        }) else { return (symbols, []) }

        var problems: [String] = [], misses = 0, seenAny = false
        for raw in lines.dropFirst(start + 1) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if parseLine(line) != nil { seenAny = true; misses = 0; continue }
            misses += 1
            // Report BEFORE deciding the block is over. This used to break first, so the
            // second consecutive rejection — the one that actually truncates the set —
            // was the one line guaranteed never to be shown. "1-4 HP1–4" then "5-9 LP1–5"
            // lost the low pays in silence.
            //
            // "Looks like an entry" has to be the same test parseLine applies, not just a
            // leading digit: the line that ENDS a symbol block is usually prose, and
            // "4x5 ways game, with 4 HP symbols" is not a dropped symbol.
            if seenAny, looksLikeEntry(line) { problems.append(String(line.prefix(120))) }
            if misses >= 2 && seenAny { break }          // the block has ended
        }
        return (symbols, problems)
    }

    // ===== The three shapes real GDDs actually use =====
    //
    // Measured, not guessed: every .docx in the team's GDD folder was run through the
    // app's own text extraction and read by hand. Of seven documents, ONE parsed. The
    // rest declare their symbols in shapes this parser had never been taught:
    //
    //   2750, 3520, 3690   a tab-separated table   "0\tWD1\t0\t1\t1"
    //   4490               a described list        "HP1 - main cowboy character, gold frame"
    //   3310               codes sharing one note  "LP1, LP2, LP3, and LP4 - bag"
    //   3140               a table keyed by code   "SF1\t7\t1"
    //
    // The described shapes matter twice over. They carry the symbol set AND the art
    // direction for each symbol — "gold frame", "silver frame", "Iron Jack, red" — which
    // is the whole point of reading the document rather than inventing a set.

    /// True when a field is a symbol code — "WD", "HP1", "WY12".
    ///
    /// Deliberately stricter than "starts with a known prefix": the prefix has to be
    /// followed by nothing or by digits, so "HPs" is a group name and "HOPJE" is a word.
    static func isSymbolCode(_ field: String) -> Bool {
        let up = field.uppercased()
        guard up.count >= 2, up.count <= 6, up.allSatisfy({ $0.isLetter || $0.isNumber }),
              up.first?.isLetter == true else { return false }
        let letters = up.prefix { $0.isLetter }
        let digits = up.dropFirst(letters.count)
        guard digits.allSatisfy(\.isNumber) else { return false }
        return classify(up).role != .unknown
    }

    /// Symbols declared as rows of a table: tab-separated columns, one of them a code.
    ///
    /// This is the most common shape in the real folder and the parser could not read a
    /// single one of them.
    static func parseRows(_ gddText: String) -> [SlotSymbol] {
        var out: [SlotSymbol] = [], seen = Set<String>()
        for raw in gddText.components(separatedBy: .newlines) {
            let fields = raw.components(separatedBy: "\t")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard fields.count >= 2, let ci = fields.firstIndex(where: isSymbolCode) else {
                continue
            }
            let code = fields[ci].uppercased()
            guard !seen.contains(code) else { continue }
            // The reel index is a plain number in a neighbouring column — before the code
            // in "0 WD1 0 1 1", after it in a table keyed by code.
            let idx = fields.prefix(ci).compactMap { Int($0) }.last
                ?? fields.dropFirst(ci + 1).compactMap { Int($0) }.first
            // Any non-numeric column after the code is a description worth keeping.
            let note = fields.dropFirst(ci + 1).first { Int($0) == nil && $0.count > 3 } ?? ""
            let (role, tier) = classify(code)
            seen.insert(code)
            out.append(SlotSymbol(code: code, index: idx ?? out.count,
                                  role: role.refined(byNote: note), tier: tier, note: note))
        }
        // Four is the floor for "this is a table, not a sentence that mentions WD".
        return out.count >= 4 ? out.sorted { $0.index == $1.index ? $0.code < $1.code
                                                                 : $0.index < $1.index } : []
    }

    /// Symbols declared as a described list — the shape that carries art direction.
    ///
    ///     HPs - high value colorized western characters, frame based tiering
    ///     HP1 - "hero" 1, main cowboy character, gold frame
    ///     LP1, LP2, LP3, and LP4 - bag
    ///
    /// A plural head ("HPs", "SFs") names the FAMILY. It declares no symbol of its own,
    /// but its description applies to every member, so it is kept and handed down — that
    /// line is where a document says how a whole tier is drawn.
    static func parseDescribedList(_ gddText: String) -> [SlotSymbol] {
        var out: [SlotSymbol] = [], seen = Set<String>()
        var family: [String: String] = [:]      // "HP" -> the family's own description

        for raw in gddText.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count < 400 else { continue }   // a paragraph, not a list entry
            guard let (head, note) = splitDescription(line) else { continue }

            // The head must be codes and joining words, nothing else. This is what keeps
            // ordinary prose that happens to contain a dash out of the symbol set.
            // Original case, deliberately. A document writes the family as "HPs" and a
            // real code as "WYS" — the lowercase s is the only thing telling them apart,
            // and uppercasing first turned every family header into a symbol.
            let tokens = head
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            guard !tokens.isEmpty, tokens.count <= 8 else { continue }
            let joiners: Set<String> = ["AND", "THE", "OR", "AMP"]
            var codes: [String] = []
            var plural: [String] = []
            var clean = true
            for t in tokens {
                if joiners.contains(t.uppercased()) { continue }
                // "HPs" / "SFs" — the family, not a symbol. Checked BEFORE the code test,
                // because "HPs" also passes as a code once it is uppercased.
                if t.hasSuffix("s"), t.count > 2, isSymbolCode(String(t.dropLast())) {
                    plural.append(String(t.dropLast()).uppercased()); continue
                }
                if isSymbolCode(t) { codes.append(t.uppercased()); continue }
                clean = false; break
            }
            guard clean else { continue }

            for p in plural where !note.isEmpty {
                family[String(p.prefix { $0.isLetter })] = note
            }
            for c in codes where !seen.contains(c) {
                seen.insert(c)
                let (role, tier) = classify(c)
                out.append(SlotSymbol(code: c, index: out.count, role: role,
                                      tier: tier, note: note))
            }
        }
        guard out.count >= 4 else { return [] }
        // Hand each family's description down to its members, behind their own.
        return out.map { s in
            let stem = String(s.code.prefix { $0.isLetter })
            let note = family[stem].map { s.note.isEmpty ? $0 : s.note + " — " + $0 } ?? s.note
            return SlotSymbol(code: s.code, index: s.index,
                              role: s.role.refined(byNote: note), tier: s.tier, note: note)
        }
    }

    /// Split "CODE(s) <separator> description" on the first real separator.
    ///
    /// Only a dash with space around it, or a colon. "HP1-4" must stay one token, and a
    /// hyphenated word inside a description is not a separator either.
    static func splitDescription(_ line: String) -> (head: String, note: String)? {
        for sep in [" - ", " \u{2013} ", " \u{2014} ", ": ", " -", ":"] {
            guard let r = line.range(of: sep) else { continue }
            let head = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let note = String(line[r.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "-\u{2013}\u{2014} \t"))
            guard !head.isEmpty, head.count <= 60 else { return nil }
            return (head, note)
        }
        return nil
    }

    /// Parse a whole GDD's plain text. Returns the symbols in symbol-set index order.
    ///
    /// Scans from a "Symbol Set" heading until the block stops looking like a list,
    /// so prose further down the document can't inject phantom symbols.
    /// Read a GDD's symbol set, whatever shape it is written in.
    ///
    /// Four readers, and the document decides which one applies: the one that finds the
    /// most symbols wins, ties going to the shape that carries the most information.
    /// Nothing here invents a symbol — every reader requires real evidence in the text,
    /// and a document none of them can read returns EMPTY so the caller has to say so.
    public static func parse(_ gddText: String) -> [SlotSymbol] {
        var best: [SlotSymbol] = []
        for c in [parseIndexedList(gddText),      // "0 WD1 // wild"
                  parseDescribedList(gddText),    // "HP1 - main cowboy, gold frame"
                  parseRows(gddText),             // "0\tWD1\t0\t1\t1"
                  parseTable(gddText)]            // bare codes in a column
        where c.count > best.count { best = c }
        return best
    }

    /// The indexed "Symbol Set" block: "0 WD1 // wild", "1-4 HP1-4 // HPs".
    static func parseIndexedList(_ gddText: String) -> [SlotSymbol] {
        let lines = gddText.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces)
              .lowercased().hasPrefix("symbol set")
        }) else { return [] }

        var out: [SlotSymbol] = []
        var seen = Set<String>()
        var misses = 0
        for raw in lines.dropFirst(start + 1) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let parsed = parseLine(line) else {
                misses += 1
                // Two consecutive non-list lines means the block is over. One is
                // tolerated because these documents carry stray blank-ish rows.
                if misses >= 2 && !out.isEmpty { break }
                continue
            }
            misses = 0
            for s in parsed where !seen.contains(s.code) {
                seen.insert(s.code); out.append(s)
            }
        }
        return out.sorted { $0.index == $1.index ? $0.code < $1.code : $0.index < $1.index }
    }

    /// True when a line has the SHAPE of a symbol-set entry — an index or range, then a
    /// break, then something. It says nothing about whether the rest parsed.
    ///
    /// This is the line between "a symbol we failed to read" and "the prose that follows
    /// the block". Both start with a digit; only the entry separates the index from what
    /// comes after it.
    static func looksLikeEntry(_ line: String) -> Bool {
        var s = line.replacingOccurrences(of: "\u{2013}", with: "-")
                    .replacingOccurrences(of: "\u{2014}", with: "-")
        while let f = s.first, f == "*" || f == "-" || f == "•" {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard let first = s.first, first.isNumber else { return false }
        let idxStr = s.prefix { $0.isNumber || $0 == "-" }
        let after = s.dropFirst(idxStr.count)
        guard let sep = after.first, sep.isWhitespace || sep == "/" else { return false }
        return !after.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// One symbol-set line -> the symbols it declares. nil when it isn't one.
    static func parseLine(_ line: String) -> [SlotSymbol]? {
        // Word turns "1-4" into "1\u{2013}4" on its own. Every range check below looks for
        // an ASCII hyphen, so an en dash made "1\u{2013}4 HP1\u{2013}4" unreadable — and a
        // .docx exported from Word is the normal input, not the exception.
        var s = line.replacingOccurrences(of: "\u{2013}", with: "-")
                    .replacingOccurrences(of: "\u{2014}", with: "-")
                    .replacingOccurrences(of: "\u{2212}", with: "-")
        // Drop a leading bullet: "* ", "- ", "• ".
        while let f = s.first, f == "*" || f == "-" || f == "•" {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard let first = s.first, first.isNumber else { return nil }

        // Index or index range at the head of the line.
        let idxStr = s.prefix { $0.isNumber || $0 == "-" }
        let idxParts = idxStr.split(separator: "-").compactMap { Int($0) }
        guard let lo = idxParts.first else { return nil }
        let hi = idxParts.count > 1 ? idxParts[1] : lo
        guard hi >= lo, hi - lo < 64 else { return nil }
        let count = hi - lo + 1

        // A real entry always separates the index from the code — "0 WD1", "2-5 // MPs".
        // Prose that merely opens with a digit does not: "4x5 ways game, with 4 HP
        // symbols…" parsed as index 4 plus a code "x5" and invented a symbol out of a
        // sentence. Requiring the break is what tells one from the other.
        let afterIndex = s.dropFirst(idxStr.count)
        guard let sep = afterIndex.first, sep.isWhitespace || sep == "/" else { return nil }

        var rest = String(afterIndex).trimmingCharacters(in: .whitespaces)
        // "* 0 — WD1 (Wild Symbol)" — some documents separate the index from the code
        // with a dash instead of just space. The em dash is already normalised to "-"
        // above, so this is one strip. It cannot eat a range: "1-4 HP1-4" keeps its dash
        // inside the index, and this only runs on what follows the index.
        while let f = rest.first, f == "-" {
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // The code may sit before the comment marker or after it.
        var codeSpec = "", note = ""
        if let cm = rest.range(of: "//") {
            let head = String(rest[..<cm.lowerBound]).trimmingCharacters(in: .whitespaces)
            let tail = String(rest[cm.upperBound...]).trimmingCharacters(in: .whitespaces)
            if head.isEmpty {
                // "- 2-5 // MPs  (Standard MP symbols)" — code is the first token after //.
                let tok = tail.prefix { !$0.isWhitespace && $0 != "(" }
                codeSpec = String(tok)
                note = String(tail.dropFirst(tok.count)).trimmingCharacters(in: .whitespaces)
            } else {
                codeSpec = head; note = tail
            }
        } else {
            let tok = rest.prefix { !$0.isWhitespace }
            codeSpec = String(tok)
            note = String(rest.dropFirst(tok.count)).trimmingCharacters(in: .whitespaces)
        }
        rest = ""
        // "0 WD1, // wild" — the comma belongs to the sentence, not the code. Left on, it
        // failed every branch of `expand` and the game silently lost its wild.
        codeSpec = codeSpec.trimmingCharacters(in: CharacterSet(charactersIn: ",;.:"))
        note = note.trimmingCharacters(in: CharacterSet(charactersIn: "()").union(.whitespaces))

        let codes = expand(codeSpec: codeSpec, indexCount: count)
        guard !codes.isEmpty else { return nil }
        // A line covering N indices should declare N codes; when it declares one
        // (a single symbol on a single index) that is fine too.
        return codes.enumerated().map { off, code in
            let (role, tier) = classify(code)
            // The document's own words decide what an SF actually does — see refined(byNote:).
            return SlotSymbol(code: code, index: lo + min(off, count - 1),
                              role: role.refined(byNote: note), tier: tier, note: note)
        }
    }
}

/// A theme as the H5G theme hub holds it. Everything here is text the hub already
/// shows on a card — Navigator does not invent any of it.
public struct GameTheme: Equatable, Hashable, Sendable {
    public let name: String          // "Jack and the Beanstalk"
    public let category: String      // "Fairytale"
    public let comparables: String   // "Megaways Jack"
    public let why: String           // the hub's market rationale
    public let look: String          // the hub's "Theme & look" paragraph — the art direction
    public let tier: String          // "T1"
    /// The card's reference artwork as a data: URL, when the hub has one. The written
    /// look says what the world is; this says how it is RENDERED.
    /// Filled in on demand, for the one theme the user picks — not during the list
    /// load. See ThemeHubClient for why that matters. The first of `artDataURLs`.
    public var artDataURL: String
    /// EVERY reference image on the card. A hub card can carry several — it shows a
    /// "+2" badge when it does — and the extras are as much the approved art as the
    /// first. The style is read from the first; the window cycles through all of them.
    public var artDataURLs: [String] = []
    /// Rendering style read off `artDataURL`, filled in before planning.
    public var styleFromArt: String = ""
    /// A style picked by hand, which OVERRIDES the one read from the reference art.
    ///
    /// It lives on the theme rather than being passed to each prompt builder because
    /// three different prompts need it — the planner, the symbol pass and the background
    /// pass — and threading it through three signatures is how one of them gets missed.
    /// That already happened once here: an anti-pattern list reached the symbol prompt
    /// and not the background prompt, and the backgrounds came back covered in invented
    /// lettering.
    public var chosenStyle: SlotArtStyle? = nil
    /// The hub card HAS artwork, whether or not it has been fetched yet. Lets the window
    /// tell "this theme has no reference art" apart from "it has some and we haven't
    /// fetched it", which are different things and were being shown identically.
    public var hasArt: Bool = false
    /// The team notes from the card — status, who is on it, links. The freshest thing on
    /// a hub card and the one most likely to say "art already started".
    public var notes: String = ""
    /// 👍 count on the card.
    public var votes: Int = 0
    /// The card's own badge, e.g. "T1 · Greenlight".
    public var status: String = ""

    public init(name: String, category: String = "", comparables: String = "",
                why: String = "", look: String = "", tier: String = "",
                artDataURL: String = "") {
        self.name = name; self.category = category; self.comparables = comparables
        self.why = why; self.look = look; self.tier = tier; self.artDataURL = artDataURL
    }

    /// Base64 payload of `artDataURL`, if it is one.
    public var artBase64: String? {
        guard let r = artDataURL.range(of: ";base64,") else { return nil }
        let b = String(artDataURL[r.upperBound...])
        return b.isEmpty ? nil : b
    }
}

/// What each symbol role has to look like.
///
/// Distilled from High 5 Games' own slot design guide (the "Symbol Types and
/// Hierarchy" and "Critical Symbol Category Differentiation Guide" sections). These
/// are the rules that make a set read as a set: a player has to tell an HP1 from an
/// MP1 apart at a glance, on a phone, without reading anything.
public enum SlotArtDirection {

    /// Rules every symbol obeys, whatever its role. Mostly about surviving downscale —
    /// the failure mode that kills slot art is detail that dissolves at reel size.
    /// Rules about LEGIBILITY, not about rendering.
    ///
    /// An earlier version of this dictated the medium — "vector-clean, NOT painterly" —
    /// taken from the design guide's advice on art that survives downscaling. Handed to
    /// the image model alongside a theme whose own reference art is a richly painted
    /// illustration, it won, and the set came back looking like clip art. The guide's
    /// point is that detail must survive at reel size, which is a constraint on
    /// COMPOSITION and CONTRAST; it is not an instruction to draw flat vector icons.
    /// How the art is rendered comes from the theme's reference artwork instead.
    public static let houseStyle = """
    CRAFT (these are about staying readable on a reel, not about the medium):
    - Richly rendered and finished to a high standard — this is premium commercial game art.
      Painted form, real material response, specular on metal and gem. Painterly and
      semi-3D are both correct. Unstructured detail is the failure, not rendering.
    - One clear focal point, and a strong closed silhouette that still reads as a solid
      black shape.
    - Strong value contrast and clean edge separation, so the symbol holds against a
      busy, dark, high-contrast reel field behind it.
    - Detail concentrated where it matters — the face, the ornament, the light — rather
      than spread evenly across every surface.
    - Nothing so fine it dissolves when the symbol is shown small: no hairline filigree,
      no micro-texture, no tiny writing, no thin scattered particles.
    - FILL THE FRAME. The symbol occupies the canvas it is generated in. A subject floating
      small in the middle of a big empty square is the single most common way generated
      slot art looks wrong beside hand-made art.
    - Leave a small, even breathing space so no part of the resting artwork touches or is
      clipped by the edge. That is a COMPOSITION margin and nothing else: it is not atlas
      padding, and it is not room for the symbol to move in later.
    - FRAMES: most slot symbols other than card royals sit in or on a frame, plaque or
      backing shape, and it is drawn as part of the symbol. Card royals usually carry no
      frame — the letterform is the symbol. When a frame is used it must be the SAME frame
      treatment across the tier, so the set reads as a set.
    - Compose so the symbol can be taken apart for the motion it will actually have —
      a head that turns, a lid that opens, a jewel that pulses, a wing that moves. There is
      no required number of parts: a symbol that only scales as a whole needs none. What
      matters is that wherever one piece overlaps another, the art beneath continues
      rather than stopping at the seam, so nothing tears open when it animates.
    - Sleek, rich and fun. Never childish, never cheap, never cluttered. A dimensional
      object with real material and real light on it, painted rather than drawn.
    - The subject is centred, upright and complete.
    - Give it a POSE, not a catalogue photograph. A character is caught mid-expression or
      mid-action — leaning in, turning, laughing, roaring — rather than standing square and
      lifeless. An object usually reads best turned slightly, with weight and gravity and
      light that describes its form. Face-on is right when the symbol is a plaque, badge,
      seal or value panel; everywhere else it tends to look like stock clip art.
    """

    /// How an EDGE is made, when the art is not meant to have drawn line work.
    ///
    /// The commonest complaint about generated slot art is a cartoon contour: a dark ink
    /// stroke hugging the silhouette, or a pale "die-cut sticker" band around the whole
    /// symbol. The prompt used to ask for "the same edge treatment" across the set
    /// without ever saying how an edge should be FORMED — and an outline is a perfectly
    /// sensible way to make a symbol read at 120px, so the model kept choosing it.
    ///
    /// Written as a positive specification because that is what Google's own prompting
    /// guide asks for: "Describe what you want, not what you don't want (e.g. 'empty
    /// street' instead of 'no cars')." The single exclusion at the end is deliberate and
    /// short — naming the artefact once is worth more than a blacklist, and there is no
    /// negativePrompt parameter on this model family to put it in.
    ///
    /// Two temptations are deliberately not used. "Soft edges" trades the artefact for an
    /// unreadable symbol. An unqualified "rim light" produces the same continuous bright
    /// perimeter under a different name — so the highlight is specified as broken and
    /// only on surfaces facing the key.
    public static func edgeTreatment(allowRimGlow: Bool = false) -> String {
        let highlights = allowRimGlow
            // The game's own approved art has a luminous rim. Forbidding it here would
            // contradict the style description sitting directly above it in the prompt —
            // and the reference art is the stronger authority on how this game looks.
            ? """
              - The rim light this style calls for is part of the artwork: let it follow the
                form, varying in width and intensity with the material and the curvature
                rather than tracing the outline at one even thickness.
              """
            : """
              - Edge highlights are SHORT AND BROKEN, only on the surfaces facing the key
                light, varying in width with the material and the curvature. Never a
                continuous bright band tracing the whole outline.
              """
        let exclusions = allowRimGlow
            ? "- No inked contour stroke around the subject, and no pale or white die-cut border."
            : """
              - No inked contour stroke around the subject, no pale or white die-cut border,
                and no glow following the silhouette.
              """
        return """
        EDGES — how the symbol separates from what is behind it:
        - The silhouette is where the painted surface ENDS. Carry each material's own
          colour, value and lighting all the way out to that boundary, so the edge is the
          meeting of two surfaces rather than a line drawn on top of the art.
        - Keep edges CRISP at the identifying features — the ones that say what this symbol
          is at a glance — and let them soften only where a form genuinely turns away.
        - SEPARATE THE SYMBOL WITH LIGHT, NOT WITH A LINE. A warm rim light catching the
          top and one side of the form, falling off where the form turns away, is how this
          symbol lifts off the reel — together with broad VALUE contrast against the field
          behind it, a distinctive silhouette with generous gaps between its major parts,
          and shading grouped into large coherent masses. That rim is lighting on the
          form; it is not a stroke drawn around it, and it varies in width and brightness
          with the material and the curvature instead of running at one even thickness.
        \(highlights.trimmingCharacters(in: .whitespacesAndNewlines))
        \(exclusions.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    /// What the drawing model must be told about the OTHER symbols it cannot see.
    ///
    /// Each image is generated on its own, in its own request, with no sight of its
    /// siblings — so unless it is told, every symbol is drawn as if it were the only one.
    /// That is how a set ends up with twelve individually decent symbols that plainly
    /// belong to twelve different games. These rules used to be sent to the PLANNER only,
    /// which decided the subjects and then had no say in how they were drawn.
    public static let setConsistency = """
    THIS SYMBOL IS ONE OF A SET — it will sit on the same reel as the others, and they
    must look like one game made by one artist:
    - ONE light direction across the whole set: key light from the upper left, consistent
      falloff, consistent shadow side.
    - ONE rendering treatment. Same paint quality, same edge treatment, same finish on
      metal and gem. Higher-paying symbols may carry MORE detail than lower ones — that is
      how the tiers read — but the way that detail is painted must not change.
    - ONE palette. Use the theme's colours; do not introduce a hue the theme has not
      established.
    - Matched OPTICAL weight: this symbol should look the same size beside the others,
      which is not the same as filling the same box.
    - It must hold against a busy, dark, high-contrast reel field behind it.
    - It must not look MORE expensive than a symbol that pays more than it does. A lower
      pay rendered in heavier gold than the high pays reverses the ladder and no single
      image can notice it happening.
    """

    /// The ways generated slot art goes wrong, stated as instructions rather than as
    /// warnings.
    ///
    /// These are production failure patterns, not a test for whether a machine made the
    /// picture. Several were hit in this project before they were written down: every
    /// special feature arriving as a swirling vortex, and a cutout destroying art that
    /// was meant to stay.
    public static let antiPatterns = """
    AVOID THESE SPECIFICALLY:
    - Draw the NAMED SUBJECT, and let it stay the subject. Reaching for generic ornament
      instead collapses every symbol in the set into the same one.
    - Take the shape from the SUBJECT, never from what the mechanic is called. A role name
      describes how the game counts a symbol; it says nothing about what the thing is.
    - No invented lettering, inscriptions, runes or pseudo-script. If a motif is cultural,
      use a real one from the theme rather than decorative squiggles that imitate writing.
    - Gloss is not form. Keep material-specific highlights — metal, gem, cloth, skin each
      behave differently — and keep anatomy, joins and ornament continuous and correct.
    - Concentrate detail at the focal feature and keep secondary surfaces broad. Fine
      detail spread everywhere reads as rich in a big preview and as noise on a reel.
    - Do not reproduce an existing game's symbol. Shipping games are a guide to treatment
      and function, never something to copy.
    """

    /// The set-level rules. Two symbols that share a silhouette are the single most
    /// common way a symbol set fails, so this is stated to the model every time.
    public static let setRules = """
    SET RULES:
    - Every symbol must be told apart INSTANTLY from every other one — by subject first,
      then by internal shape, colour and contrast. No two symbols may read as the same
      thing at a glance.
    - RESOLVE THAT SIDEWAYS, NOT UPWARD. When the obvious subject for a symbol is already
      taken by another one, reach for a DIFFERENT thing from the same world — another
      character in the story, a creature that belongs beside the first, the object this
      world is known for. Do not retreat into a token, emblem or abstraction of the
      subject that was taken: a set where one symbol is a real thing and the next is a
      badge bearing a picture of that thing has stopped being one world.
    - EVERY subject comes from THIS game's theme, and every one is rendered in the SAME
      art style. A symbol that would fit equally well in a different game is the wrong
      symbol, however well drawn.
    - A shared frame, bezel or backing plate across a tier is allowed and is common in
      shipping games; when one is used, the distinctness has to come from what sits
      inside it.
    - ONE light direction, ONE rendering treatment and ONE level of detail across every
      symbol in the game. Twelve individually good symbols that do not look like one game
      is the most common way a set fails.
    - Symbols must look optically the SAME SIZE beside each other — matched visual weight,
      not matched bounding boxes.
    - Value tiers must be obvious at a glance, top to bottom, without reading anything.
    - Higher-paying symbols run WARMER, HOTTER and RICHER than lower-paying ones: gold,
      amber, crimson and deep jewel tones at the top; cooler, plainer, more muted colour at
      the bottom. This is the house preference, not a law of the genre — shipping games do
      break it (Gems Bonanza pays cyan above orange) — so where the theme genuinely forbids
      it, an ice or deep-space game may keep a cool high pay and carry value through
      material richness, contrast and ornament instead.
    - The gap between HP1 and LP1 should be obvious side by side: HP1 is the single most
      desirable object in the game, LP1 is plain by comparison.
    - HP are the rulers; MP are allies (creatures/objects, never human); LP are the plain
      foundation.
    - All LP symbols are the SAME family — all card ranks, or all gems, or all icons.
      Never mixed.
    - Wild reads as transformation/energy. Scatter reads as a gateway you travel THROUGH.
      Bonus reads as a container you OPEN. Never swap these.
    - Do not separate two symbols by colour alone.
    """

    /// Role-specific direction, including the tier's own framing and ornament budget.
    public static func direction(for role: SlotSymbolRole, tier: Int?) -> String {
        switch role {
        case .wild:
            return """
            WILD — the symbol that substitutes for others.

            Draw a SPECIFIC SUBJECT from this theme, at the same level of reality as every \
            other symbol in the set: something a person could point at in this world. In \
            shipping games the wild is a character, creature or signature object — Big Bass \
            Bonanza's fisherman, Wild West Gold's sheriff, Book of Dead's book.

            IF THE OBVIOUS SUBJECT IS ALREADY TAKEN by a paying symbol, move SIDEWAYS in this \
            world, not upward into a token of it: another character from the same story, the \
            hero who belongs with those creatures, the one object this world is known for. A \
            paw print stands FOR a wolf; it is not a wolf, and it is a weaker symbol than the \
            huntsman, the moon-priest or the antler crown would be. Reaching for a badge, seal \
            or coin bearing the motif is the move to resist — it is what makes every game's \
            wild look like every other game's wild.

            So: pick the one figure or object that best stands for this world's power, and make \
            it unmistakably itself. The game prints a label over this symbol at runtime, so keep one area of the ARTWORK calm and uncluttered for it — no busy detail, no strong edge crossing it. Do NOT draw a band, bar, plate, box or panel for the text, and do not letter it yourself: a blank white strip across the picture is not a text zone, it is a mistake in the art. The strongest value contrast and \
            cleanest edge separation in the set.
            """
        case .highPay:
            let t = tier ?? 1
            let frame: String
            switch t {
            case 1: frame = "The tightest crop and the most ornate thing in the entire game. A character: head and upper shoulders only, eyes large and frontal, direct eye contact, an expression of authority. Or, if an object instead: the single most precious object in the game. Ornament concentrated in one or two places — a crown, a jewelled band — not spread over everything."
            case 2: frame = "A little wider than HP1 — head, neck and upper chest — and visibly less ornate. As an object: premium, but clearly second to HP1's. Where it looks is a character choice, not a rank: HP2 does not have to look away from the player."
            case 3: frame = "Wider still: a bust, with distinctive accessories that establish who or what this is. Noticeably simpler than HP2."
            default: frame = "The widest and plainest of the high pays — full costume or full object visible, clean lines, the least ornament of the four."
            }
            return """
            HIGH PAY \(t) of 4 — "the rulers". \(frame)
            Rich materials and precious-metal response. Angular, authoritative shape language.

            The four high pays are a LADDER and a player must be able to rank them at a glance,
            side by side, without knowing the paytable. Each step down loses something specific
            and visible: less precious material (gold, then bronze, then wood or stone), fewer
            gems, less ornament, cooler colour, less light on it. Do not make a lower tier
            smaller to say it is worth less — make it plainer.
            \(t == 1 ? "HP1 is the single most desirable object in the entire game. If it does not look like the thing the player most wants to land, it is wrong." : "")
            """
        case .mediumPay:
            let t = tier ?? 1
            return """
            MEDIUM PAY \(t) — the middle band of the paytable. Objects, creatures, characters \
            and artefacts are all fair game — there is no rule against a person here; what \
            matters is that it sits clearly between the high pays and the low pays. \
            Clearly richer than the low pays and clearly subordinate to the high pays: fewer \
            decorative elements than a high pay, more than a low pay, and less of them with each \
            step down the medium-pay tiers. Curved, organic shape language. Moderate saturation.
            """
        case .lowPay:
            let t = tier ?? 1
            return """
            LOW PAY \(t) — filler. The simplest, plainest symbols in the set, and the ones a
            player sees most often.

            Every low pay in this game belongs to ONE family. Pick a single family for all of
            them and do not mix:
              - ROYALS: card ranks A K Q J 10 7 5, styled to the theme
              - GEMSTONES: simple cut stones, one per rank
              - PEBBLES or tokens: plain but refined objects that read as holding some value
              - THEMED ITEMS: simple everyday objects from this world
            One pebble, one royal, one gem and one item in the same game is wrong. All of them
            must be the same kind of thing, differing only in which one it is.

            FRAMES: royals usually carry NO frame — the letterform IS the symbol. Every other
            low-pay family almost always sits in or on a frame, plaque or backing shape.

            The symbol must FILL the frame it is generated in. A low pay floating small in the
            middle of the canvas reads as a mistake beside the high pays. Two or three visual
            elements at most, and enough contrast to be counted instantly.
            """

        case .scatter:
            return """
            SCATTER — the symbol that is COUNTED wherever it lands, rather than paying along a \
            line. That is a rule about how the game EVALUATES it, not a shape, and it carries no \
            required form: take the subject from this game's own world and let the shape follow \
            from it.

            What it must be is INSTANTLY COUNTABLE — a player has to see three or four of them \
            scattered across the reels at a glance. So: one bold, unmistakable subject from this \
            theme, the highest colour contrast in the whole set against every other symbol, and \
            a shape that reads even partly obscured. The game prints a label over this symbol at runtime, so keep one area of the ARTWORK calm and uncluttered for it — no busy detail, no strong edge crossing it. Do NOT draw a band, bar, plate, box or panel for the text, and do not letter it yourself: a blank white strip across the picture is not a text zone, it is a mistake in the art.
            """
        case .bonus:
            return """
            BONUS — the symbol that triggers this game's bonus feature. A chest or a case is one \
            good answer, but it is not a requirement: shipping games use coins, emblems, badges \
            and characters just as often. Pick whatever this game's own bonus actually is about.

            The one hard rule: if this game ALSO has a separate scatter, the two must be \
            impossible to confuse at a glance — different subject, different colour, different \
            shape. The game prints a label over this symbol at runtime, so keep one area of the ARTWORK calm and uncluttered for it — no busy detail, no strong edge crossing it. Do NOT draw a band, bar, plate, box or panel for the text, and do not letter it yourself: a blank white strip across the picture is not a text zone, it is a mistake in the art.
            """
        case .jackpot:
            let names = [1: "GRAND", 2: "MAJOR", 3: "MINOR", 4: "MINI"]
            let t = tier ?? 1
            return """
            JACKPOT \(names[t] ?? "tier \(t)") — one of four prize tiers that must read as a FAMILY.

            Shipping games build all four from the SAME construction and separate them by colour \
            and by a printed tier name — Book of Dead GO Collect uses one gold-and-gem coin in \
            red, turquoise, purple and lime. Four unrelated treasures make the player guess which \
            outranks which, so keep the form shared and let colour carry the tier: \
            \(t == 1 ? "GRAND is the hottest and richest of the four." : t == 2 ? "MAJOR sits just below GRAND." : t == 3 ? "MINOR is cooler and calmer than MAJOR." : "MINI is the coolest and plainest of the four.")

            Perfect symmetry, one centre of attention, flawless material. The game prints a label over this symbol at runtime, so keep one area of the ARTWORK calm and uncluttered for it — no busy detail, no strong edge crossing it. Do NOT draw a band, bar, plate, box or panel for the text, and do not letter it yourself: a blank white strip across the picture is not a text zone, it is a mistake in the art.

            Not every game has four: some run Grand, Major and Minor only. Draw the tiers this \
            game actually defines, and nothing for a jackpot that exists only as a meter.
            """
        case .wysiwyg:
            return """
            WYSIWYG VALUE SYMBOL — it carries a cash value the game prints on it at runtime.

            Design the SUBJECT first — whatever THIS game's money looks like, taken from its \
            own world — then make sure part of its own surface is calm enough to read a value \
            over: the face of it, a flat facet, a panel that belongs to the object. The game prints the number \
            there at runtime. Do not draw a blank plate, band or rectangle for it, do not \
            surrender half the symbol to one, and put NO lettering or numerals in the art. A \
            value carrier does not have to look like a plaque.
            """
        case .collector, .activator, .adder:
            return """
            SPECIAL FEATURE SYMBOL — these are FOUR different jobs and the design document says
            which one this is. Draw the job it names, and do not blend them:

              - COLLECTOR: gathers values in from other symbols. Give it somewhere the gathered
                total visibly lands, left clean for the game to print a running number over.
                A character can do the collecting just as well as an object can.
              - ACTIVATOR: starts a feature. Its subject should be tied to the feature it
                triggers, with a readable difference between its resting and fired states, and a
                clear point the effect comes FROM. No running total unless it also collects.
              - ADDER: adds an amount to something else. Leave a clear zone for the increment
                and its unit, and make the direction of the effect readable. Must not be
                confusable with the collector or the multiplier.
              - MULTIPLIER: applies a factor. Controlled and precise rather than chaotic — that
                is the wild's job. Clear upright zone for the factor.

            In every case the number is printed by the game at runtime over the ARTWORK itself:
            keep that part of the subject calm enough to read a number against, draw no band,
            plate or box for it, and put no lettering or numerals in the art. This is the symbol
            players hunt for, so give it the highest contrast and the most distinctive silhouette
            you can.
            """

        case .multiplier:
            return """
            MULTIPLIER — "the amplifier". CONTROLLED, precise energy — mathematical, not chaotic \
            (that is the wild's job). The game prints the multiplier value over this symbol at \
            runtime, so part of the artwork itself must be calm enough to read a number over. \
            Do NOT draw a blank plate, band or rectangle for it — that is the same mistake as \
            leaving a bare panel, and it comes back as a white box in the middle of the symbol. \
            Reads as amplification and precision.
            """
        case .replacement:
            return """
            REPLACEMENT SYMBOL — a plain stand-in that sits quietly among the others. Same art \
            style and same visual weight as the low pays, deliberately unremarkable, and visibly \
            distinct from every named symbol in the set.
            """
        case .blank:
            return "BLANK — an empty reel position. No art is generated for this."
        case .unknown:
            return """
            UNCLASSIFIED SYMBOL — the design document did not say what this is. Draw a \
            handsome, thematically appropriate object in the game's style with a distinct \
            silhouette, and treat it as a medium pay.
            """
        }
    }
}

/// Choosing the flat colour a symbol is generated ON.
///
/// Nano Banana has no alpha — it flattens transparency to black — so symbols are
/// generated on a flat field and the background is taken off afterwards. Which field
/// colour is safe depends on the game's palette: keying green out of a beanstalk game
/// eats the beanstalk. One colour is chosen for the WHOLE set rather than per symbol,
/// so a single setting clears every asset.
enum SlotBackingRules {

    /// The three classic keys. Anything else risks a colour the model renders
    /// inconsistently across a batch, which defeats a single setting.
    static let candidates: [(name: String, rgb: RGB8)] = [
        ("chroma green", RGB8(0, 177, 64)),
        ("chroma blue", RGB8(0, 71, 187)),
        ("chroma magenta", RGB8(255, 0, 255)),
    ]

    /// The candidate furthest from everything in the palette.
    ///
    /// Scored by the palette colour it is CLOSEST to (max-min), not by an average:
    /// a backing that is far from most of a palette but near one prominent colour
    /// still destroys that colour when it is taken out.
    static func choose(palette: [RGB8]) -> (name: String, rgb: RGB8) {
        guard !palette.isEmpty else { return candidates[2] }   // magenta: rarest in game art
        return candidates.max { a, b in
            let da = palette.map { KeyColorRules.deltaE($0, a.rgb) }.min() ?? 0
            let db = palette.map { KeyColorRules.deltaE($0, b.rgb) }.min() ?? 0
            return da < db
        } ?? candidates[2]
    }

    /// "#1e8f3c" / "1e8f3c" -> RGB8. nil for anything else, so a model that answers
    /// with prose instead of a hex code is ignored rather than silently read as black.
    static func hex(_ s: String) -> RGB8? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("#") { t = String(t.dropFirst()) }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return RGB8(UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
    }
}

/// Whether a generated image actually came back at the resolution that was asked for.
///
/// Google documents an exact size-by-aspect table — 1:1 is 1024 / 2048 / 4096 for
/// 1K / 2K / 4K — and a short answer lands exactly on the 1K row, at the price of the
/// size that was asked for. So the size cannot be assumed; it is measured.
enum GeneratedSizeRules {

    /// The long edge each size name is asking for.
    static func targetLongEdge(_ size: String) -> Int {
        switch size {
        case "4K": return 4096
        case "2K": return 2048
        default: return 1024
        }
    }

    /// True when `longEdge` is meaningfully short of the request. The 0.9 slack is
    /// because a non-square ratio lands on numbers like 1536x2752 that are correct
    /// for the request without matching it exactly.
    static func isUndersized(longEdge: Int, requested: String) -> Bool {
        Double(longEdge) < Double(targetLongEdge(requested)) * 0.9
    }

    /// "2048x2048" for the plan table.
    static func describe(width: Int, height: Int) -> String { "\(width)x\(height)" }
}

/// One image to generate.
public struct AssetJob: Equatable, Sendable {
    public enum Kind: String, Sendable { case symbol, background }
    public let id: String            // "HP1", "bg_base"
    public let kind: Kind
    public let role: SlotSymbolRole  // .unknown for backgrounds
    public let tier: Int?
    public let title: String         // what it is, for the plan table
    public var subject: String       // the art subject — filled in by the planning pass
    public var silhouette: String    // one or two words, used to enforce distinctness
    /// Whether this symbol is drawn inside a frame, plaque or backing shape.
    ///
    /// Decided by the planner, because it depends on the low-pay family it chose: card
    /// royals carry no frame — the letterform is the symbol — while nearly everything
    /// else does. Generating the frame WITH the symbol is what stops the two drifting
    /// apart, which is the old pipeline's failure; separating them afterwards is what
    /// makes the frame reusable.
    public var hasFrame: Bool = false
    public let aspect: String        // "1:1" symbols; backgrounds follow BackgroundFormatRules
    public let size: String
    public var filename: String { "\(id).png" }

    public init(id: String, kind: Kind, role: SlotSymbolRole, tier: Int?, title: String,
                subject: String = "", silhouette: String = "", aspect: String, size: String,
                hasFrame: Bool = false) {
        self.id = id; self.kind = kind; self.role = role; self.tier = tier; self.title = title
        self.subject = subject; self.silhouette = silhouette; self.aspect = aspect; self.size = size
        self.hasFrame = hasFrame
    }
}

/// Turning a parsed GDD into the list of images to make.
public enum AssetPlanRules {

    /// Square 2K symbols by default. Backgrounds are not a fixed default — they are
    /// whatever covers the 1920x2532 portrait target, which works out as 3:4 at 4K.
    public static let symbolAspect = "1:1"
    public static let defaultSize = "2K"
    public static let sizes = ["1K", "2K", "4K"]
    public static let symbolAspects = ["1:1", "4:5", "5:4", "4:3", "3:4"]
    public static var backgroundAspects: [String] { BackgroundFormatRules.ratios.map(\.name) }
    public static var backgroundAspect: String { BackgroundFormatRules.best().aspect }
    public static var backgroundSize: String { BackgroundFormatRules.best().size }

    /// Symbol jobs, in the order they should be drawn — the symbols that decide
    /// whether the set is working come first.
    public static func symbolJobs(_ symbols: [SlotSymbol], size: String = defaultSize,
                                  aspect: String = symbolAspect) -> [AssetJob] {
        symbols.filter { $0.role.needsArt }
            .sorted {
                $0.role.priority == $1.role.priority
                    ? ($0.tier ?? 0, $0.code) < ($1.tier ?? 0, $1.code)
                    : $0.role.priority < $1.role.priority
            }
            .map {
                AssetJob(id: $0.code, kind: .symbol, role: $0.role, tier: $0.tier,
                         title: $0.note.isEmpty ? $0.role.label : $0.note,
                         aspect: aspect, size: size)
            }
    }

    /// Background jobs for the game's scenes.
    ///
    /// A MODE has to be named, not merely a word mentioned. "jackpot" alone matched
    /// every game that has a jackpot SYMBOL — which is most of them — and invented a
    /// jackpot scene nobody asked for, at 4K, on the bill.
    public static func backgroundJobs(gddText: String, size: String? = nil,
                                      aspect: String? = nil) -> [AssetJob] {
        let fmt = BackgroundFormatRules.best()
        let size = size ?? fmt.size, aspect = aspect ?? fmt.aspect
        let scenes = GDDScenes.scenes(in: gddText)
        return scenes.map {
            AssetJob(id: $0.id, kind: .background, role: .unknown, tier: nil, title: $0.title,
                     aspect: aspect, size: size)
        }
    }
}

/// Picking the aspect and resolution a BACKGROUND is generated at.
///
/// A slot background has a real target: 1920x2532, the portrait background size the
/// games are built to. The rule is to take the SMALLEST supported format whose
/// pixels still cover it, and among equals the one shaped most like it.
///
/// For 1920x2532 that works out as 3:4 at 4K (3547x4730). Nothing at 2K reaches it —
/// the tallest 2K option is 1774x2365, short on both edges — so a portrait
/// background is a 4K request whether or not the symbols are. That is also the
/// request Nano Banana honours most reliably: 4K came back full size every time it
/// was asked, while 2K came back halved about half the time.
///
/// The pixel maths is measured, not assumed: Nano Banana fits roughly S-by-S pixels
/// worth of image into the requested ratio, so a "2K" 9:16 comes back 1536x2752
/// (2048 x 0.75 by 2048 / 0.75). A 2K 1:1 comes back 2048x2048. Both confirmed on
/// live calls.
enum BackgroundFormatRules {

    /// The phone this is sized for.
    public static let defaultTarget = (w: 1920, h: 2532)

    /// Ratios worth offering for a background.
    ///
    /// 9:21 is deliberately absent. It is listed as a Nano Banana ratio and is the
    /// closest of all of them to a modern phone, but asking for it came back
    /// 768x1376 — which is 9:16, at half size. Offering a ratio the service quietly
    /// substitutes would be offering a setting that does nothing.
    static let ratios: [(name: String, value: Double)] = [
        ("9:16", 9.0 / 16), ("2:3", 2.0 / 3), ("3:4", 3.0 / 4), ("1:1", 1.0),
        ("4:3", 4.0 / 3), ("16:9", 16.0 / 9),
    ]

    static let sizes = ["1K", "2K", "4K"]

    /// The pixels a (ratio, size) request is expected to produce.
    static func pixels(ratio: Double, size: String) -> (w: Int, h: Int) {
        let s = Double(GeneratedSizeRules.targetLongEdge(size))
        let r = ratio.squareRoot()
        return (Int((s * r).rounded()), Int((s / r).rounded()))
    }

    /// The smallest size class that can cover `target`, and within it the ratio
    /// shaped most like `target`.
    ///
    /// Size first, then shape — NOT total pixels. Every 4K request yields the same
    /// pixel count whatever its ratio, but rounding leaves the areas differing by a
    /// thousand pixels or so, and ranking on area let that noise decide: 9:16 came out
    /// "smaller" than 3:4 and won, handing back a background a third too tall for a
    /// 3:4 target, to be thrown away in the crop.
    static func best(target: (w: Int, h: Int) = defaultTarget) -> (aspect: String, size: String) {
        let want = log(Double(target.w) / Double(target.h))
        for size in sizes {
            let fits = ratios.filter { r in
                let p = pixels(ratio: r.value, size: size)
                return p.w >= target.w && p.h >= target.h
            }
            if let pick = fits.min(by: { abs(log($0.value) - want) < abs(log($1.value) - want) }) {
                return (pick.name, size)
            }
        }
        return ("9:16", "4K")
    }

    /// True when what actually arrived is too small for the target.
    static func covers(width: Int, height: Int, target: (w: Int, h: Int) = defaultTarget) -> Bool {
        width >= target.w && height >= target.h
    }
}

/// Where a run's art is written.
///
/// The user picks a PARENT folder once and Navigator makes a folder per run inside
/// it, named for the game and the theme. Picking the exact output folder every time
/// is the kind of small friction that ends with three games' symbols in one folder,
/// all called HP1.png.
enum GDDOutputRules {

    /// Characters that are legal in a file name but miserable in one.
    static func safe(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
    }

    /// "4400 Chevy-Hot — Jack and the Beanstalk".
    static func folderName(game: String, theme: String) -> String {
        let g = safe(game), t = safe(theme)
        if g.isEmpty && t.isEmpty { return "Game assets" }
        if t.isEmpty { return g }
        if g.isEmpty { return t }
        return "\(g) — \(t)"
    }

    /// A name that does not collide with something already there. Two runs of the
    /// same game and theme are a normal thing to do — a second pass after changing a
    /// few subjects — and silently writing over the first one is not.
    static func uniqueName(_ base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }
        for n in 2...99 where !existing.contains("\(base) \(n)") { return "\(base) \(n)" }
        return "\(base) \(Int(Date().timeIntervalSince1970))"
    }
}

/// Putting a cut-out symbol back on the canvas it was drawn on.
///
/// Photoshop's background removal TRIMS to the subject: a 2048x2048 symbol comes back
/// 1653x1804. For one image that is fine, but a symbol SET has to register — every
/// symbol sitting in the same square, in the same place, so the reel does not jitter
/// when one lands next to another.
///
/// The position is not guessed. The symbol was generated on a flat field of a known
/// colour, so the pixels that are NOT that colour are the subject, and their bounding
/// box in the source is exactly where the trimmed cut-out came from.
enum SymbolCanvasRules {

    /// Squared distance between two colours, for the flat-field test. Plain RGB is
    /// the right measure here: the question is "is this pixel the backing we just
    /// asked for", not "do these look alike to a person".
    static func distanceSquared(_ a: RGB8, _ b: RGB8) -> Int {
        let dr = Int(a.r) - Int(b.r), dg = Int(a.g) - Int(b.g), db = Int(a.b) - Int(b.b)
        return dr*dr + dg*dg + db*db
    }

    /// Anything this far from the backing counts as subject. Generous, because the
    /// soft edge of the subject blends toward the backing and must not be clipped off
    /// the bounding box.
    static let subjectThreshold = 60 * 60

    /// The subject's bounding box in a flat-backed image, as (x, y, w, h).
    ///
    /// `sample` answers the pixel at (x, y). Returns nil when nothing differs from the
    /// backing — an empty image has no box, and inventing one would place the cut-out
    /// somewhere arbitrary.
    static func subjectBounds(width: Int, height: Int, backing: RGB8,
                              sample: (Int, Int) -> RGB8) -> (x: Int, y: Int, w: Int, h: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where distanceSquared(sample(x, y), backing) > subjectThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    /// Where to place a trimmed cut-out on the original canvas.
    ///
    /// Photoshop's trim and this bounding box are computed from the same picture but
    /// not by the same code, so they land within a pixel or two of each other rather
    /// than exactly. The cut-out is centred on the box when they disagree slightly,
    /// and the placement is REFUSED when they disagree a lot — a wrong offset is worse
    /// than an untrimmed file, because it is invisible until the reel spins.
    /// How far the two measurements may disagree: 5% of the canvas, or 24px, whichever
    /// is larger.
    ///
    /// A flat 24px was too strict. A soft-edged symbol — a glowing vortex — fades into
    /// the backing, so this scan's threshold keeps more of the glow than Photoshop's cut
    /// does, and the two disagreed by 56px on a 2048 canvas. Refusing that left exactly
    /// the symbols with soft edges untrimmed while the hard-edged ones were placed,
    /// which is the opposite of a consistent set. Centring within the box bounds the
    /// error at half the tolerance — about 1.4% of the canvas — which is invisible on a
    /// reel, and still refuses a cut-out that is nothing like the box.
    static func tolerance(canvas: (w: Int, h: Int)) -> Int {
        max(24, max(canvas.w, canvas.h) / 20)
    }

    static func placement(cutout: (w: Int, h: Int), bounds: (x: Int, y: Int, w: Int, h: Int),
                          canvas: (w: Int, h: Int), tolerance: Int? = nil)
        -> (x: Int, y: Int)? {
        let tolerance = tolerance ?? Self.tolerance(canvas: canvas)
        guard abs(cutout.w - bounds.w) <= tolerance, abs(cutout.h - bounds.h) <= tolerance
        else { return nil }
        let x = bounds.x + (bounds.w - cutout.w) / 2
        let y = bounds.y + (bounds.h - cutout.h) / 2
        guard x >= 0, y >= 0, x + cutout.w <= canvas.w, y + cutout.h <= canvas.h else { return nil }
        return (x, y)
    }
}

/// How hard to push the image service, and what to do when it pushes back.
///
/// Every number here is Google's, or explicitly marked as ours. Their API-errors page
/// recommends retrying "no more than two times" with a minimum one-second delay
/// increasing exponentially; their retry-strategy guide documents initial delay 1s,
/// base 2, maximum 60s, with jitter, and names 429, 408 and transient 5xx as the
/// retryable statuses while other 4xx are terminal.
///
/// Concurrency is NOT documented by Google for online image generation, and we sit
/// behind a metering proxy whose own limits we cannot see. So this takes the smallest
/// parallel step above the sequential baseline that was already working — two — and
/// gives up that second worker at the first sign of pushback, rather than discovering
/// a hidden ceiling by failing twenty images at once.
enum ImageRequestPolicy {

    /// How many images are in flight at once.
    ///
    /// Ours, not Google's — Google documents no concurrency limit for online image
    /// generation, and the metering proxy in front of it publishes none either. Measured
    /// rather than assumed: see the note on `widenAfterSuccesses`.
    /// Measured on a 19-image set, 1K, this machine alone on the service:
    ///
    ///     sequential   13.8s per image
    ///     4-wide        3.2s      61s total
    ///     8-wide        1.7s      32s total   no pushback, three runs
    ///    16-wide        1.4s      26s total   no pushback
    ///
    /// 16 works, and 8 is the setting. Past 8 the wall time is bounded by how long ONE
    /// image takes, so the last doubling bought six seconds — while putting twice the
    /// load on a service the whole studio shares, measured with nobody else on it.
    /// If pushback ever does arrive the pool narrows and recovers on its own, so this is
    /// a starting point rather than a ceiling.
    static let concurrency = 8
    /// Consecutive successes before the pool takes a worker back after being narrowed.
    /// Narrow fast, widen slowly — the usual shape for a limit nobody will tell you.
    static let widenAfterSuccesses = 4
    /// Ours: stagger the workers so they do not start in lockstep.
    static let staggerSeconds: Double = 1

    /// Google: "retrying no more than two times" — so three attempts in total.
    static let maxAttempts = 3
    static let initialBackoff: Double = 1
    static let backoffMultiplier: Double = 2
    static let maxBackoff: Double = 60

    /// Google: 429, 408 and transient 5xx are retryable; other 4xx are terminal.
    static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || (status >= 500 && status < 600)
    }

    /// Our own error strings carry the status inline — "AI service HTTP 429: …".
    static func status(inMessage m: String) -> Int? {
        guard let r = m.range(of: #"HTTP (\d{3})"#, options: .regularExpression) else { return nil }
        return Int(m[r].dropFirst(5))
    }

    /// True when an error message describes something worth trying again.
    ///
    /// An error with NO status is a transport failure — a dropped connection or a
    /// timeout. Those are deliberately NOT retried: the request may already have been
    /// generated and metered, and a blind replay would pay for it twice.
    static func shouldRetry(errorMessage m: String) -> Bool {
        guard let s = status(inMessage: m) else { return false }
        return isRetryable(status: s)
    }

    /// Delay before attempt `n` (1-based), with jitter. The jitter distribution is not
    /// documented; 0-1s added preserves the documented one-second minimum.
    static func backoff(forAttempt n: Int, jitter: Double) -> Double {
        let base = initialBackoff * pow(backoffMultiplier, Double(max(0, n - 1)))
        return min(maxBackoff, base) + max(0, min(1, jitter))
    }
}

/// The part of a GDD that says what the special symbols DO.
///
/// The symbol-set list gives codes and one-line comments; the prose further down is
/// where a game actually lives — that 4400's collector shoots fireballs at a glass
/// panel over a "Hot Reel", that its upgraded scatter is ringed, that its bonus reels
/// carry red scatters. Handing the planner only the codes throws all of that away and
/// gets back symbols that would suit any game at all. This finds those passages and
/// keeps a bounded amount of them.
enum GDDFeatureContext {

    /// Headings that introduce the prose worth keeping.
    static let headings = ["special symbols", "special feature", "features", "bonus features",
                           "free spins", "base features", "spinning & winning", "presentation",
                           "feature -", "upgraded symbols"]

    /// Lines that are machine detail rather than game description.
    static func isNoise(_ line: String) -> Bool {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.isEmpty { return true }
        // Code, JSON and tables carry no art meaning and eat the budget fast.
        if l.hasPrefix("*") && l.contains("//") { return true }
        if l.contains("{") || l.contains("}") || l.contains(";") { return true }
        if l.hasPrefix("int ") || l.hasPrefix("struct ") || l.hasPrefix("enum ") { return true }
        return false
    }

    /// The document, with machine noise stripped, bounded generously.
    ///
    /// This used to capture 2,500 characters and only from lines following a short list
    /// of headings — a list that did not include "Symbols". 4490 survived only because it
    /// happens to write "Presentation" above its symbol block; a document that puts its
    /// symbol descriptions under a plain "Symbols" heading lost them entirely, and the
    /// planner then invented subjects for symbols the document had already described.
    ///
    /// The ceiling was set when the model had a small window and long context was
    /// expensive. gemini-3.8-flash takes 1,048,576 tokens, and Google's own long-context
    /// guidance is to keep the relevant document whole and put the task after it rather
    /// than pre-chunking. A 25,000-character GDD is a rounding error against that window.
    ///
    /// Noise filtering stays: code blocks, JSON and reel tables carry no art meaning.
    public static func excerpt(_ gddText: String, limit: Int = 40000) -> String {
        let lines = gddText.components(separatedBy: .newlines)
        var out: [String] = [], total = 0, capturing = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            // Every heading now opens the capture, and capture starts immediately: the
            // planner should see the whole document, not the part after a keyword.
            if headings.contains(where: { lower.hasPrefix($0) }) { capturing = true; continue }
            _ = capturing
            guard !isNoise(line) else { continue }
            // A heading-looking line that is not one of ours ends the passage.
            if line.count < 40 && line.hasSuffix(":") { continue }
            let piece = String(line.prefix(300))
            if total + piece.count > limit { break }
            out.append(piece); total += piece.count
        }
        return out.joined(separator: "\n")
    }
}

/// Whether a design document actually states what its symbols pay.
///
/// Everything downstream assumes HP1 outranks HP4 because of the number in the code.
/// That is a NAMING convention, not a fact about the game: a document can number its
/// symbols by reel-strip index, and nothing in the code list proves the order. Where
/// the document says nothing about pay, the ranking is still used — there is no better
/// signal — but the user is told it was assumed rather than read.
enum GDDPayOrder {

    /// Phrases that mean a paytable is present.
    static let markers = ["paytable", "pay table", "pays ", "payout", "x bet", "multiplier of bet",
                          "5 of a kind", "4 of a kind", "3 of a kind", "5oak", "4oak", "3oak"]

    /// True when the document appears to state pay values or a pay order.
    static func isStated(in gddText: String) -> Bool {
        let t = gddText.lowercased()
        return markers.contains { t.contains($0) }
    }

    /// What to tell the user about where the ranking came from.
    static func note(for gddText: String, symbols: [SlotSymbol]) -> String? {
        let ranked = symbols.filter { $0.tier != nil && ($0.role == .highPay || $0.role == .mediumPay
                                                         || $0.role == .lowPay || $0.role == .jackpot) }
        guard ranked.count > 1, !isStated(in: gddText) else { return nil }
        return "This document doesn’t state pay values, so the value order was taken from the "
             + "code numbering (HP1 above HP4, JP1 above JP4). Check it against the paytable."
    }
}

/// The distinct SCENES a game has, read from its design document.
///
/// Every slot has a base game, so that one is assumed. The rest are not: a game may
/// have free games, a separate bonus round, a pick screen, a hold-and-spin, or several
/// of those, and each is its own background. The first version of this matched six
/// fixed phrases and could never return more than three scenes — it read 4400's
/// "Jackpot Pick" as nothing at all, because the phrase it knew was "jackpot picker".
///
/// Each scene still has to be NAMED by the document. Nothing here invents a screen the
/// game does not describe, because every extra background is a paid 4K image.
enum GDDScenes {

    /// Phrases that name a mode, and the scene each belongs to. Longest first, so
    /// "free spins bonus" is one scene rather than matching "bonus" separately.
    static let modes: [(phrase: String, id: String, title: String)] = [
        ("free spins bonus", "bg_freegames", "Free spins background"),
        ("free spins game", "bg_freegames", "Free spins background"),
        ("free games", "bg_freegames", "Free games background"),
        ("free spins", "bg_freegames", "Free spins background"),
        ("hold and spin", "bg_holdspin", "Hold and spin background"),
        ("hold & spin", "bg_holdspin", "Hold and spin background"),
        ("loot link", "bg_lootlink", "Loot Link background"),
        ("jackpot pick", "bg_jackpot", "Jackpot pick background"),
        ("jackpot wheel", "bg_jackpot", "Jackpot wheel background"),
        ("jackpot round", "bg_jackpot", "Jackpot round background"),
        ("jackpot game", "bg_jackpot", "Jackpot game background"),
        ("jackpot screen", "bg_jackpot", "Jackpot screen background"),
        ("pick screen", "bg_pick", "Pick screen background"),
        ("picker screen", "bg_pick", "Pick screen background"),
        ("bonus round", "bg_bonus", "Bonus round background"),
        ("bonus game", "bg_bonus", "Bonus game background"),
        ("bonus mode", "bg_bonus", "Bonus mode background"),
    ]

    /// Scenes the document names, base game first. Deduplicated by scene id, so a
    /// document saying "free games" six times still gets one background.
    /// True when the words immediately before a mode name deny it.
    ///
    /// A GDD says what a game does NOT have as readily as what it does, and "No free
    /// spins or bonus game." was building two paid 4K backgrounds for screens that do
    /// not exist. Only the short run of text ahead of the phrase is considered — a "no"
    /// in the previous sentence is about something else.
    static func isNegated(_ t: String, at r: Range<String.Index>) -> Bool {
        // Scope is the SENTENCE, not a fixed window. A denial governs a whole list —
        // "no free spins or bonus game" denies both — so walking back word by word and
        // stopping at the first ordinary word missed the second item every time.
        // What a PREVIOUS sentence denied is a different matter, hence the boundary.
        var lead = String(t[t.startIndex..<r.lowerBound])
        if let cut = lead.lastIndex(where: { $0 == "." || $0 == ";" || $0 == "\n" }) {
            lead = String(lead[lead.index(after: cut)...])
        }
        let words = lead.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        let deny: Set<String> = ["no", "not", "none", "without", "never", "excludes",
                                 "omits", "lacks", "neither", "nor"]
        guard let last = words.lastIndex(where: { deny.contains($0) }) else { return false }
        // "There is no wild, but free spins are awarded" — the turn reverses the denial.
        let after = Set(words[words.index(after: last)...])
        return after.isDisjoint(with: ["but", "however", "although", "though", "instead",
                                       "whereas", "aside", "except"])
    }

    public static func scenes(in gddText: String) -> [(id: String, title: String)] {
        var out: [(String, String)] = [("bg_base", "Base game background")]
        var seen: Set<String> = ["bg_base"]
        let t = gddText.lowercased()
        // Once a phrase has matched a span of text, nothing else may match inside it.
        // "free spins bonus game" is ONE mode; without this it matched "free spins
        // bonus" and then "bonus game" again, and the game got two backgrounds for one
        // screen — at 4K each.
        var claimed: [Range<String.Index>] = []
        for m in modes {
            var from = t.startIndex
            while let r = t.range(of: m.phrase, range: from..<t.endIndex) {
                if !claimed.contains(where: { $0.overlaps(r) }), !isNegated(t, at: r) {
                    claimed.append(r)
                    if !seen.contains(m.id) { seen.insert(m.id); out.append((m.id, m.title)) }
                }
                from = r.upperBound
            }
        }
        return out
    }
}

/// The symbol set a game ACTUALLY shipped, read from its production asset manifest.
///
/// Some GDDs never list their symbols — 2690 Supercoco's only symbol codes appear in
/// feature prose and inside a sound cue — so reading the document is the wrong place to
/// look for the truth about that game. The truth is in the art it shipped, and that is
/// recorded per game in a plain-text manifest of every PNG:
///
///     .../art/base/highPaySymbol/
///      +-- base_HP1_static.png [240x240px]
///     .../art/base/lowPaySymbol/
///      +-- base_LP_1-static.png [240x240px]
///     .../art/base/specialSymbol/
///      +-- base_SF_1-front-static.png [240x240px]
///
/// Which is eleven symbols for that game, against the two its document yields.
enum GameAssetManifest {

    /// Folder names that say what a symbol IS, which is more reliable than the filename.
    static let folderRoles: [(String, SlotSymbolRole)] = [
        ("highpaysymbol", .highPay), ("mediumpaysymbol", .mediumPay), ("midpaysymbol", .mediumPay),
        ("lowpaysymbol", .lowPay), ("specialsymbol", .collector), ("wildsymbol", .wild),
        ("scattersymbol", .scatter), ("bonussymbol", .bonus), ("jackpotsymbol", .jackpot),
        ("wysiwygsymbol", .wysiwyg),
    ]

    /// "base_HP1_static.png" -> HP1.  "base_LP_1-static.png" -> LP1.
    /// "base_SF_1-front-static.png" -> SF1.
    static func code(inFilename name: String) -> String? {
        let up = name.uppercased()
        // The code is a known prefix followed by an optional underscore and a number.
        for (prefix, _) in GDDSymbolSetRules.prefixes {
            guard let r = up.range(of: "(^|[_-])" + prefix + "_?([0-9]+)",
                                   options: .regularExpression) else { continue }
            let hit = up[r]
            let digits = hit.drop { !$0.isNumber }
            guard !digits.isEmpty else { continue }
            return prefix + digits
        }
        return nil
    }

    /// Symbols the manifest shows the game shipped.
    ///
    /// Only the symbol folders are read: a manifest lists fonts, meters, bezels and
    /// buttons too, and none of those is a reel symbol.
    public static func symbols(fromManifest text: String) -> [SlotSymbol] {
        var out: [SlotSymbol] = [], seen = Set<String>()
        var folderRole: SlotSymbolRole? = nil
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\\", with: "")
            let lower = line.lowercased()
            // A folder line resets the context for the files beneath it.
            if lower.contains("/art/") || lower.hasSuffix("/") {
                folderRole = folderRoles.first { lower.contains($0.0) }?.1
                if !lower.contains(".png") { continue }
            }
            guard lower.contains(".png"), let role = folderRole else { continue }
            guard let file = line.components(separatedBy: " ").first(where: {
                $0.lowercased().hasSuffix(".png")
            }) ?? line.components(separatedBy: CharacterSet(charactersIn: " │├└─")).first(where: {
                $0.lowercased().hasSuffix(".png")
            }) else { continue }
            guard let code = code(inFilename: file), !seen.contains(code) else { continue }
            seen.insert(code)
            let tier = GDDSymbolSetRules.classify(code).tier
            out.append(SlotSymbol(code: code, index: out.count, role: role, tier: tier,
                                  note: "from the game's shipped art"))
        }
        return out
    }

    /// The manifest file for a game number, among a folder's worth of them.
    ///
    /// They are named "<number>_<name>_production.txt", so the number is the key.
    public static func fileName(forGame number: String, among files: [String]) -> String? {
        let n = number.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        return files.first { $0.hasPrefix(n + "_") && $0.lowercased().hasSuffix(".txt") }
    }

    /// The leading game number in a document's name — "4400 Chevy-Hot GDD" -> "4400".
    public static func gameNumber(inName name: String) -> String? {
        let digits = name.prefix { $0.isNumber }
        return digits.count >= 3 ? String(digits) : nil
    }
}

/// Whether a symbol set is believable as a slot game's.
///
/// 2690 Supercoco has no symbol-set section at all. Its only symbol codes appear in
/// prose ("scatters HP1 symbols") and inside a SOUND CUE parenthetical ("when WD1 has
/// been consumed"), so reading it produced a two-symbol game — one wild, one high pay —
/// and the window reported that as fact. The shipped art for that game is eleven
/// symbols. No real slot machine has two.
///
/// This cannot know the right answer; it can know when the answer is not credible and
/// say so, which is the difference between a wrong number and a wrong number nobody
/// questioned.
enum GDDSymbolPlausibility {

    /// Below this, a symbol set is almost certainly incomplete rather than small.
    static let leastCredible = 5

    /// What is missing that essentially every slot game has.
    static func concerns(_ symbols: [SlotSymbol]) -> [String] {
        guard !symbols.isEmpty else { return [] }
        var out: [String] = []
        let drawable = symbols.filter { $0.role.needsArt }
        if drawable.count < leastCredible {
            out.append("only \(drawable.count) symbol\(drawable.count == 1 ? "" : "s") — a slot "
                     + "game normally has eight or more")
        }
        let roles = Set(symbols.map(\.role))
        if !roles.contains(.lowPay) { out.append("no low pays") }
        if !roles.contains(.highPay) { out.append("no high pays") }
        return out
    }

    /// Whether the document says, in its own words, that it only covers what a feature
    /// ADDS to a game that already shipped.
    ///
    /// Six Power Bet GDDs in the folder carry the same sentence: "<game> is already a
    /// released product, so this GDD will only focus on the new additions to the game."
    /// 4230 DaVinci PB then lists five symbols — three wilds, a bonus, a jackpot — and
    /// nothing else, because the low and high pays shipped with the base game years ago.
    /// The document is complete; it is just not a whole game.
    ///
    /// Without this, the window called that document incomplete and told the user to
    /// check it against the art list, which reads as "the tool could not read this" when
    /// the truth is "the tool read all of it, and this is all there is".
    static func declaresItselfAnAddendum(_ gddText: String) -> Bool {
        let t = gddText.lowercased()
        // Long, distinctive sentences only. A short token like "base game" appears in
        // every GDD in the folder and would mark all of them.
        return t.contains("already a released product")
            || t.contains("only focus on the new additions")
            || t.contains("consists of the base game rules from")
    }

    /// One sentence for the user, or nil when the set looks normal.
    static func warning(_ symbols: [SlotSymbol], inferred: Bool,
                        gddText: String = "") -> String? {
        let c = concerns(symbols)
        guard !c.isEmpty else { return nil }
        if declaresItselfAnAddendum(gddText) {
            let n = symbols.filter { $0.role.needsArt }.count
            return "This document only covers what the feature ADDS to a game that "
                 + "already shipped — it says so itself. So \(c.joined(separator: " and "))"
                 + " is expected here, not a failure to read it: these \(n) are the new "
                 + "symbols. The rest of the set belongs to the base game, so take its "
                 + "art list or its own GDD for those."
        }
        let head = inferred
            ? "This document has no symbol list, and what could be read from it looks incomplete: "
            : "This symbol set looks incomplete: "
        return head + c.joined(separator: ", ")
             + ". Check it against the game's own art list before generating anything."
    }
}

/// The two prompts this feature is built on: one that DESIGNS the symbol set, and
/// one that DRAWS a single symbol.
///
/// They are split because they are different jobs. Deciding that HP1 should be the
/// giant's golden harp — and that nothing else in the set may be harp-shaped — is a
/// language problem best done once, with every symbol visible at the same time. That
/// is the only way silhouette collisions can be avoided at all; a per-image prompt
/// cannot know what the other twenty images look like.
public enum GDDAssetPrompts {

    /// The designer pass. Sees the whole set at once, and answers with JSON.
    public static let planningSystem = """
    You are a senior art director for social casino slot machine games at High 5 Games. \
    You design symbol sets that are sleek, rich and fun to look at — never childish, never \
    cluttered, never generic. A player takes in a whole reel at a glance, so what matters \
    most is that every symbol is instantly told apart from every other one, and that the \
    value order is obvious without reading anything.

    You will be given a game's symbol slots and a theme. Assign a specific art subject to \
    every slot. Answer with JSON only — no commentary, no markdown fences.
    """

    /// The planning request. `jobs` carries the slots; the model fills in the subjects.
    /// The shape the planner must answer in.
    ///
    /// Only the ENVELOPE is constrained — the fields must exist and be strings. `subject`
    /// and `silhouette` are deliberately unbounded: the published work on forced
    /// structured output finds the cost falls on creative content when the content itself
    /// is constrained, and enumerating acceptable subjects would defeat the entire task.
    public static func planSchema(ids: [String]) -> [String: Any] {
        // Mirrors the shape apply(planJSON:to:) reads — "assets", with a palette
        // alongside it. A schema that describes a DIFFERENT shape to the one the parser
        // expects produces perfectly valid JSON that fills nothing, which is exactly what
        // happened the first time: 0 of 20 slots, no error anywhere.
        [
            "type": "OBJECT",
            "properties": [
                "palette": [
                    "type": "ARRAY",
                    "description": "Five hex colours, #rrggbb, for the whole set.",
                    "items": ["type": "STRING"],
                ],
                "assets": [
                    "type": "ARRAY",
                    "description": "One entry per slot, using these exact ids: "
                                 + ids.joined(separator: ", "),
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "id": ["type": "STRING"],
                            "subject": ["type": "STRING",
                                        "description": "One vivid sentence naming the "
                                                     + "subject and its framing."],
                            "silhouette": ["type": "STRING",
                                           "description": "Its shape in one or two words."],
                            "frame": ["type": "BOOLEAN"],
                        ],
                        "required": ["id", "subject", "silhouette", "frame"],
                    ],
                ],
            ],
            "required": ["assets"],
        ]
    }

    public static func planning(theme: GameTheme, gameName: String, jobs: [AssetJob],
                                gddText: String = "") -> String {
        let features = GDDFeatureContext.excerpt(gddText)
        let slotLines = jobs.map { j -> String in
            let t = j.tier.map { " (tier \($0))" } ?? ""
            return "- \(j.id): \(j.kind == .background ? "BACKGROUND" : j.role.label)\(t) — \(j.title)"
        }.joined(separator: "\n")

        return """
        GAME: \(gameName)
        \(features.isEmpty ? "" : """

        WHAT THIS GAME DOES — from its own design document. Use it. A symbol that plays a
        part in one of these features should LOOK like it does that job:
        \(features)
        """)

        THEME: \(theme.name)\(theme.category.isEmpty ? "" : "  [\(theme.category)]")
        ART DIRECTION (follow it closely):
        \(styleBlock(theme))
        \(theme.comparables.isEmpty ? "" : "Comparable games: \(theme.comparables)\n")\
        \(theme.why.isEmpty ? "" : "Why this theme works: \(theme.why)\n")

        \(SlotArtDirection.setRules)

        WHAT EACH ROLE HAS TO BE — these decide the SUBJECT, so they belong to you, not
        just to whoever draws it:
        \(roleBrief(for: jobs))

        SLOTS TO FILL (\(jobs.count)):
        \(slotLines)

        For EVERY slot above, choose the single art subject that fills it. Rules:
        - Subjects must come from this theme's own world, and they must be the INTERESTING
          choices from it. No generic casino filler, and no obvious first answer taken because
          it was the first answer — a wild is not automatically a vortex, a scatter is not
          automatically a glowing portal, a bonus is not automatically a treasure chest.
        - Every subject must have a DIFFERENT silhouette from every other subject in this set.
          Name each silhouette in one or two words and make sure no two match.
        - Respect the value hierarchy and make it VISIBLE. The four high pays must be rankable
          at a glance by what they are made of and how ornate they are; HP1 is the single most
          desirable object in this world. Higher pays run warmer, hotter and richer than lower
          pays unless the theme genuinely forbids it. All low pays must be ONE family, and they
          are the plainest things in the set.
        - Backgrounds are scenes, not objects, with an empty middle where the reels will sit.

        Answer with this JSON and nothing else:
        {
          "palette": ["#rrggbb", "#rrggbb", "#rrggbb", "#rrggbb", "#rrggbb"],
          "assets": [
            {"id": "<slot id>", "subject": "<one vivid sentence naming the subject and its framing>",
             "silhouette": "<one or two words>", "frame": true}
          ]
        }
        "palette" is the 5 dominant colours this game's art will actually use.
        "frame" says whether that symbol is drawn inside a frame, plaque or backing shape.
        Card royals carry NO frame — the letterform is the symbol — and backgrounds never do.
        Almost everything else does, and the frame must be the same treatment across a tier.
        Include every slot id exactly once.
        """
    }

    /// A one-line brief per role present in this set.
    ///
    /// The planner picks the SUBJECTS, so any rule that constrains what a symbol may BE
    /// has to reach the planner — not only the prompt that draws it. Left out, the
    /// planner chose four unrelated jackpot objects (crown, chalice, chest, medallion)
    /// while the drawing prompt was separately insisting the four be one family: an
    /// instruction that arrived far too late to be followed.
    static func roleBrief(for jobs: [AssetJob]) -> String {
        var lines: [String] = []
        let roles = Set(jobs.filter { $0.kind == .symbol }.map(\.role))
        if roles.contains(.jackpot) {
            lines.append("- JACKPOTS: GRAND, MAJOR, MINOR and MINI must be ONE FAMILY — the same "
                       + "object or construction, separated by colour and by the tier name the "
                       + "game prints on them. Do NOT pick four unrelated treasures; a player "
                       + "cannot rank a crown against a chalice against a chest.")
        }
        if roles.contains(.wild) {
            lines.append("- WILD: a specific character, emblem, animal or signature object from "
                       + "this theme. NOT a vortex, swirl, spiral or abstract energy — that is "
                       + "the weakest answer and every game already has one.")
        }
        if roles.contains(.lowPay) {
            lines.append("- LOW PAYS: choose ONE family for all of them and say which — royals "
                       + "(A K Q J 10 7 5), gemstones, pebbles/tokens, or simple themed items. "
                       + "Never a mixture: one pebble plus one royal plus one gem plus one item "
                       + "is wrong. They are filler symbols and should be the plainest things "
                       + "in the set.")
        }
        if roles.contains(.highPay) {
            lines.append("- HIGH PAYS: rankable at a glance, HP1 the most desirable object in "
                       + "the game and each one below it visibly less so.")
        }
        if roles.contains(.scatter) && roles.contains(.bonus) {
            lines.append("- SCATTER and BONUS must be impossible to confuse: different subject, "
                       + "different colour, different shape.")
        }
        if roles.contains(.wysiwyg) || roles.contains(.collector) || roles.contains(.multiplier)
            || roles.contains(.activator) || roles.contains(.adder) {
            lines.append("- WYSIWYG, COLLECTOR, ACTIVATOR, ADDER and MULTIPLIER symbols carry a "
                       + "number the game prints at runtime, so their subject needs a calm area "
                       + "for it — not a blank plate drawn into the art.")
        }
        if jobs.filter({ $0.role == .wysiwyg }).count > 1 {
            lines.append("- The WYSIWYG symbols are ONE FAMILY at different value tiers, like the "
                       + "jackpots: same object, separated by material and colour, not two "
                       + "unrelated things. But they must still be tellable apart instantly — "
                       + "two coins that differ only in a flame will read as the same symbol.")
        }
        return lines.isEmpty ? "- (nothing role-specific for this set)" : lines.joined(separator: "\n")
    }

    /// The drawing pass, for one symbol or background.
    ///
    /// The backing colour is stated in the strongest terms the prompt can manage,
    /// because the entire alpha pipeline downstream depends on it: the symbol is keyed
    /// off this colour in After Effects afterwards, and any of that colour inside the
    /// art itself is punched out along with the background.
    static func image(job: AssetJob, theme: GameTheme,
                      backing: (name: String, rgb: RGB8)) -> String {
        let hex = String(format: "#%02X%02X%02X", backing.rgb.r, backing.rgb.g, backing.rgb.b)
        if job.kind == .background {
            return """
            A slot machine game BACKGROUND for "\(theme.name)".

            SCENE: \(job.subject)

            \(styleBlock(theme))

            This background must look like it belongs to the SAME GAME as that game's symbols: \
            same light direction (key from the upper left), same rendering treatment, same \
            palette, same world. It is the stage those symbols stand on.

            Composition: vertical mobile game background. Keep the CENTRE of the image calm, \
            simple and uncluttered — the spinning reels sit there and must stay readable, and \
            the symbols on top of it must stay legible against it, so keep the centre lower in \
            contrast than the edges. Put the interest at the top, bottom and edges. Deep, rich, \
            atmospheric. No characters in the centre.

            ABSOLUTELY NO LETTERING. No game title, no logo, no wordmark, no signage, no
            inscriptions, no runes, no invented script, no numerals — not on a banner, not
            carved into stone, not on a pillar, not anywhere. A background with the game's
            name painted across it cannot be shipped: the title is a separate asset the game
            draws on top. This is the single most common way a generated background is
            wasted.

            No UI, no buttons, no meters, no reel frames, no symbols.

            \(SlotArtDirection.antiPatterns)
            """
        }
        return """
        A single slot machine game SYMBOL for "\(theme.name)".

        SUBJECT: \(job.subject)
        SILHOUETTE: \(job.silhouette)
        \(job.title.isEmpty ? "" : "WHAT THE DESIGN DOCUMENT CALLS IT: \(job.title)")

        \(styleBlock(theme))

        \(SlotArtDirection.direction(for: job.role, tier: job.tier))

        \(job.hasFrame
          ? "FRAME: draw this symbol inside a frame, plaque or backing shape, as part of the same picture — the frame and the subject must be lit and painted together so they belong to each other. Use the same frame treatment every symbol of this tier uses."
          : "NO FRAME: this symbol stands on its own, with no border, plaque or backing shape around it.")

        \(SlotArtDirection.setConsistency)

        \(SlotArtDirection.houseStyle)

        \(SlotArtDirection.antiPatterns)

        BACKDROP: the symbol sits alone on a completely flat, uniform \(backing.name) field, \
        exactly \(hex), edge to edge, with no gradient, no vignette, no shadow cast onto it and \
        no pattern. Do NOT use \(backing.name) anywhere in the symbol itself.

        That field is a BACKDROP and it will be cut away. It is not part of the design. If this \
        symbol needs a backing plate, frame or plaque behind its subject, DRAW one — as artwork, \
        in the theme's own materials — rather than letting the flat field stand in for it. A \
        symbol that relies on the backdrop as its background is destroyed the moment it is cut \
        out.
        \(exclusions(job))
        """
    }

    /// The closing DON'T list, which has to agree with everything above it.
    ///
    /// It used to be one fixed line, and it contradicted the prompt it closed. A framed
    /// symbol was told "draw this symbol inside a frame, plaque or backing shape" and
    /// then, last thing before the model starts drawing, "NO frame or border around the
    /// symbol". A card royal — which the low-pay direction explicitly allows, and whose
    /// letterform IS the symbol — was told "NO text, NO numbers, NO lettering".
    ///
    /// The last instruction in a prompt is the one that carries, so these were not
    /// harmless: they were the instruction the model actually followed, on images
    /// someone paid for.
    static func exclusions(_ job: AssetJob) -> String {
        var no = ["NO watermark", "NO drop shadow", "NO reel", "NO user interface"]
        if !job.hasFrame { no.insert("NO frame or border around the symbol", at: 0) }
        if isRoyal(job) {
            // The rank is the subject. Everything else that reads as text still isn't.
            return "The rank character is the subject and must be drawn. Apart from it: "
                 + no.joined(separator: ", ")
                 + ", NO extra lettering, NO numbers other than the rank. "
                 + "One symbol only, centred, complete."
        }
        no.insert("NO text, NO numbers, NO lettering", at: 0)
        return no.joined(separator: ", ") + ". One symbol only, centred, complete."
    }

    /// A card royal — A, K, Q, J, 10, 9 — whose letterform is the artwork.
    static func isRoyal(_ job: AssetJob) -> Bool {
        // Keywords only. Matching bare rank letters against the subject looked obvious
        // and was wrong immediately: "a giant" contains "a", so the most common word in
        // English turned a high pay into a royal and dropped "NO text" from its prompt.
        // A royal always says so in words — the planner is told to name it.
        let t = (job.subject + " " + job.silhouette).lowercased()
        for k in ["royal", "card rank", "playing card", "card suit", "rank symbol"]
        where t.contains(k) { return true }
        // "letter A", "rank K", "the 10" — the rank named, not merely present.
        let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for (i, w) in words.enumerated() where w == "letter" || w == "rank" {
            if i + 1 < words.count,
               ["a", "k", "q", "j", "10", "9"].contains(words[i + 1]) { return true }
        }
        return false
    }

    /// A SHORT drawing prompt — the whole brief in roughly 200 words.
    ///
    /// The full prompt is ~1,460 words and 29 bullet rules. Measured: a rule added to it
    /// to stop the model drawing a cartoon contour changed nothing across 59 images
    /// (43.9% -> 43.5% of the silhouette carrying a dark rim). Google's guidance is to
    /// write a specific brief rather than a rule list, and the plausible reading is that
    /// a 29-rule contract dilutes every clause in it.
    ///
    /// Structure follows that guidance: subject and rendering together at the top, then
    /// geometry, then the backdrop, then one short exclusion line. Nothing here is new
    /// direction — it is the same requirements, stated once each instead of argued.
    static func imageShort(job: AssetJob, theme: GameTheme,
                           backing: (name: String, rgb: RGB8)) -> String {
        let hex = String(format: "#%02X%02X%02X", backing.rgb.r, backing.rgb.g, backing.rgb.b)
        let lit = wantsLineWork(theme)
            ? ""
            : "Lit, not inked: it is separated from the background by light and by painted "
            + "colour meeting, with a rim light along the lit edges and no drawn contour. "
        let style = theme.chosenStyle.map { "\($0.name). \($0.keywords)" }
            ?? (theme.styleFromArt.split(separator: "\n").first.map(String.init) ?? theme.look)
        if job.kind == .background {
            return """
            Draw a slot-machine game BACKGROUND: \(job.subject).

            RENDERING: \(style) \(lit)\(theme.look)

            A deep scene with its focus and detail around the edges and the CENTRE kept \
            calm and uncluttered — the reels sit over the middle and must stay readable. \
            One consistent light direction. No characters in the centre, no text, no \
            lettering of any kind, no user interface, no reel frames.
            """
        }
        let frame = job.hasFrame
            ? "It sits in a frame or plaque drawn as part of the same picture, lit and painted with it."
            : "It stands on its own, with no border or backing shape."
        // The role's direction, trimmed to whole sentences. A hard character cut left
        // the brief ending "less precious material (gold, then bronze, then wood or".
        let full = SlotArtDirection.direction(for: job.role, tier: job.tier)
            .split(separator: "\n").dropFirst().joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        var role = ""
        for sentence in full.split(separator: ".", omittingEmptySubsequences: true) {
            let next = role + sentence.trimmingCharacters(in: .whitespaces) + ". "
            if next.count > 340 { break }
            role = next
        }
        if role.isEmpty { role = String(full.prefix(200)) }
        return """
        Draw ONE slot-machine game symbol: \(job.subject).

        RENDERING: \(style) \(lit)\(theme.look)

        \(role.trimmingCharacters(in: .whitespaces))
        \(frame)
        Centred, upright and complete, filling the frame with a clear distinctive \
        silhouette. Give it a pose with life in it rather than a catalogue photograph. \
        Concentrate detail at the focal feature and keep the other surfaces broad, so it \
        still reads at 120 pixels on a phone.

        BACKDROP: a completely flat, uniform \(backing.name) field, exactly \(hex), edge \
        to edge, no gradient and no shadow. Do NOT use \(backing.name) anywhere in the \
        symbol. That field will be cut away, so draw any plate or frame the symbol needs.

        \(exclusions(job))
        """
    }

    /// The art direction, strongest evidence first.
    ///
    /// `styleFromArt` is read off the theme's OWN reference artwork on the hub and is
    /// the only part that describes how the art is rendered, so it leads. Without it
    /// the model has nothing but adjectives about colour and invents the medium.
    static func styleBlock(_ theme: GameTheme) -> String {
        var out = ""
        // A chosen style REPLACES the one read from the reference art — it never joins
        // it. Two rendering directions in one prompt is the single most reliable way to
        // get art that matches neither, and this pair would contradict directly: one
        // says "painterly, warm, soft-edged", the other "crisp flat cel shading".
        //
        // THEME & LOOK stays either way. That describes the WORLD, not the rendering,
        // and picking a style is not a decision to draw a different game.
        if let style = theme.chosenStyle {
            out += """
            ART STYLE — match this closely. It governs the rendering of every asset in \
            this set, and it replaces any other reading of how this game looks:
            \(style.name). \(style.keywords)

            """
        } else if !theme.styleFromArt.isEmpty {
            out += """
            ART STYLE — match this closely. It is taken from this game's own approved \
            reference artwork, and it governs the rendering:
            \(theme.styleFromArt)

            """
        }
        out += "THEME & LOOK: \(theme.look)"
        if !theme.comparables.isEmpty { out += "\nComparable games: \(theme.comparables)" }
        // The edge spec goes through styleBlock because all three prompts already call
        // it — the planner, the symbol pass and the background pass. Adding it to each
        // of them separately is how the anti-pattern list reached the symbols and not
        // the backgrounds, and the backgrounds came back covered in invented lettering.
        if wantsLineWork(theme) == false {
            // The single sentence that matters goes INTO the style definition, at the top,
            // rather than only appearing as a rule among twenty-nine others further down.
            // Measured: the rule on its own, two paragraphs later, changed nothing —
            // 43.9% of the silhouette carrying a dark rim before, 43.5% after.
            out = "RENDERING: this art is lit, not inked — forms are separated from the "
                + "background by light and by painted colour meeting, with a rim light "
                + "along the lit edges and no drawn contour anywhere.\n\n" + out
            out += "\n\n" + SlotArtDirection.edgeTreatment(allowRimGlow: wantsRimGlow(theme))
        }
        return out
    }

    /// True when line work belongs to this game's art rather than being a defect in it.
    ///
    /// A chosen style says so in its own keywords. With no chosen style the rendering
    /// comes from the theme's reference artwork, so that description is checked the same
    /// way — if the approved art for this game is inked, suppressing ink would fight the
    /// very thing the style was read from.
    /// True when a luminous rim along the silhouette belongs to this game's art.
    ///
    /// Found by running it: Wild Wolves' approved artwork was described as having "a
    /// bright golden luminous rim-glow following the outer silhouettes", and the prompt
    /// then told the model, two paragraphs later, to draw no glow following the
    /// silhouette. A rim glow is a legitimate treatment; the die-cut sticker band and the
    /// inked contour are not, and those stay forbidden either way.
    static func wantsRimGlow(_ theme: GameTheme) -> Bool {
        let terms = ["rim-glow", "rim glow", "rim light", "rim-light", "rim lighting",
                     "luminous rim", "glowing rim", "halo", "bloom"]
        if let s = theme.chosenStyle {
            return mentionsUnnegated(terms, in: s.keywords)
        }
        if let v = verdict("RIM-GLOW", in: theme.styleFromArt) { return v.hasPrefix("yes") }
        return mentionsUnnegated(terms, in: theme.styleFromArt)
    }

    static func wantsLineWork(_ theme: GameTheme) -> Bool {
        if let s = theme.chosenStyle { return s.usesLineWork }
        // The style read ends with a machine-readable verdict. Prefer it: the prose
        // around it is written fresh every time and says the same thing five ways.
        // EITHER signal counts, rather than the verdict silencing the prose.
        //
        // Measured on real cards: Dragon Fantasy's "intricate embossed relief" made the
        // verdict flip none/outline/outline across three reads of the SAME artwork, so
        // whether suppression applied was a coin toss. Tightening the criterion fixed
        // that but then answered "none" for Snow Queen, whose own description says
        // "delicate, crisp dark line art" — which would have put the prompt back in the
        // business of contradicting itself, telling the model "lit, not inked" directly
        // under a style paragraph describing ink.
        //
        // So the verdict decides the ambiguous cases and the prose vetoes it when the
        // description plainly says otherwise.
        // "contour" alone is NOT one of these. In art writing a contour is the edge of a
        // form — "soft contours", "smooth contour shading" — not a drawn line, and it
        // misread Wild Bears as inked when its own verdict said none. Only phrases that
        // can only mean a DRAWN mark qualify. Same over-broad matching that once read
        // "velocity" as containing a city and the article "a" as a card rank.
        let terms = ["outline", "line art", "lineart", "keyline", "line work",
                     "linework", "contour line", "inked contour", "ink contour",
                     "ink line", "cel shad", "cel-shad"]
        if let v = verdict("EDGE-TREATMENT", in: theme.styleFromArt), v.contains("outline") {
            return true
        }
        return mentionsUnnegated(terms, in: theme.styleFromArt)
    }

    /// Read a trailing "KEY: value" verdict out of a style description.
    static func verdict(_ key: String, in text: String) -> String? {
        for raw in text.split(separator: "\n").reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix(key.lowercased() + ":") else { continue }
            return String(line.dropFirst(key.count + 1))
                .trimmingCharacters(in: .whitespaces).lowercased()
        }
        return nil
    }

    /// True when a term appears and is NOT negated by the words just before it.
    ///
    /// The fallback path used a bare substring test, and a description reading "No drawn
    /// contour; forms are separated by painted colour" therefore matched "contour" and
    /// concluded the art was inked — turning the suppression OFF on exactly the artwork
    /// that needed it. The same mistake as reading "no free spins" as a free-spins mode.
    static func mentionsUnnegated(_ terms: [String], in text: String) -> Bool {
        let k = text.lowercased()
        for t in terms {
            var from = k.startIndex
            while let r = k.range(of: t, range: from..<k.endIndex) {
                let back = k.index(r.lowerBound, offsetBy: -24, limitedBy: k.startIndex)
                    ?? k.startIndex
                let lead = String(k[back..<r.lowerBound])
                let negated = ["no ", "not ", "without ", "none", "never ", "free of ",
                               "absent", "lacks"].contains { lead.contains($0) }
                if !negated { return true }
                from = r.upperBound
            }
        }
        return false
    }

    /// Ask the model to read a symbol set out of a document that has no machine-readable
    /// one.
    ///
    /// The GDDs are not written to one template. Some list "0 WD1 // wild symbol", some
    /// carry a Word table that exports as a column of bare codes, and some simply say
    /// "Symbols (16 total) / 4 high-value symbols / 4 low-value symbols / Wild — …" in
    /// prose. No parser is going to cover the third kind, and refusing those games is
    /// worse than spending a fraction of a cent reading them properly.
    static let symbolExtractionSystem = """
    You are a slot machine producer who reads Game Design Documents and works out the \
    full list of art assets the game needs. You are good at this because you know these \
    documents are inconsistent: some list their symbols, many do not, and the ones that \
    do not still contain the answer — in the feature prose, in the sound-asset names, in \
    the paytable, in what the mechanics require to exist. You reconstruct the set from \
    whatever the document gives you, and you say plainly what you inferred rather than \
    what you read. You answer with JSON only — no commentary, no markdown fences.
    """

    static func symbolExtraction(gddText: String, limit: Int = 14000) -> String {
        """
        Work out every SYMBOL this game needs art for, and what each one is FOR.

        Many of these documents have no symbol list at all. That is normal and it is not a
        reason to give up: reconstruct the set from everything the document does contain.

        WHERE THE ANSWER HIDES WHEN THERE IS NO LIST:
        - Feature prose: "there are 2 special trigger symbols", "a front, a mid and an end
          wild piece", "four high-value symbols", "the collector gathers the coins".
        - Sound and asset naming: "base_HP (1-3)" means three high pays, HP1 to HP3.
          "base_SF_1 / SF_2 / SF_3" means three special-feature pieces.
        - Mechanics that REQUIRE a symbol to exist: a jackpot ladder implies a symbol per
          tier; a collect feature implies something collected and something collecting.
        - The paytable, if there is one.

        Do NOT treat a code mentioned in passing as a symbol definition on its own. A code
        inside a sound cue — "(when WD1 has been consumed)" — tells you a wild exists; it
        does not tell you the game has exactly one symbol.

        CODES: use the document's own where it gives them. Otherwise use the convention:
        WD wild, HP1..HPn high pays (HP1 highest), MP1..MPn medium pays, LP1..LPn low pays,
        SC scatter, BO bonus, JP1..JP4 jackpots (Grand, Major, Minor, Mini), WY WYSIWYG
        cash-value symbols, SF collector/activator/adder, MU multiplier, R replacement,
        BL blank.

        For EACH symbol also say what it DOES and what it INTERACTS with, in the game's own
        terms — that is what makes the art purposeful rather than decorative. A collector
        that gathers coins should look like it gathers; a wild that extends a chain should
        look like a piece of that chain.

        Answer with this JSON and nothing else:
        {"symbols":[
          {"code":"HP1","role":"highPay","does":"<what it does, or empty>",
           "interacts":"<what it works with, or empty>","confident":true}
        ]}
        role is one of: wild, highPay, mediumPay, lowPay, scatter, bonus, jackpot,
        wysiwyg, collector, activator, adder, multiplier, replacement, blank.
        "confident" is false when you inferred the symbol rather than found it stated.
        Do not invent symbols the game has no use for, and do not list blanks as art.

        DOCUMENT:
        \(String(gddText.prefix(limit)))
        """
    }

    /// Turn that answer into symbols. Unknown roles fall back to the code's own prefix
    /// rather than being dropped, so a model that answers with a good code and a bad role
    /// still produces a usable slot.
    static func symbols(fromExtraction json: [String: Any]) -> [SlotSymbol] {
        var out: [SlotSymbol] = [], seen = Set<String>()
        for case let e as [String: Any] in (json["symbols"] as? [Any] ?? []) {
            guard let code = (e["code"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  !code.isEmpty, !seen.contains(code) else { continue }
            seen.insert(code)
            let byCode = GDDSymbolSetRules.classify(code)
            let role = (e["role"] as? String).flatMap { SlotSymbolRole(rawValue: $0) }
            // What it does and what it works with, joined into the note the planner and
            // the artist both read. A collector that gathers coins should look like it
            // gathers; that only happens if the behaviour survives extraction.
            let does = (e["does"] as? String) ?? (e["note"] as? String) ?? ""
            let with = (e["interacts"] as? String) ?? ""
            var note = does
            if !with.isEmpty { note += note.isEmpty ? "works with \(with)" : " — works with \(with)" }
            if (e["confident"] as? Bool) == false { note += note.isEmpty ? "inferred" : " (inferred)" }
            out.append(SlotSymbol(code: code, index: out.count,
                                  role: (role ?? byCode.role).refined(byNote: does),
                                  tier: byCode.tier, note: note))
        }
        return out
    }

    /// Pull the planner's JSON out of whatever it actually answered with.
    ///
    /// Models wrap JSON in ``` fences, or open with a sentence, often enough that
    /// treating the reply as raw JSON fails intermittently — and an intermittent
    /// failure halfway through a 20-symbol run is worse than no feature at all.
    public static func json(fromModelReply reply: String) -> [String: Any]? {
        var s = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = s.range(of: "```") {
            let after = s[f.upperBound...]
            // ```json\n{...}\n```
            let body = after.drop { $0 != "\n" }
            if let close = body.range(of: "```") {
                s = String(body[..<close.lowerBound])
            } else { s = String(body) }
        }
        guard let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}"), open < close
        else { return nil }
        let slice = String(s[open...close])
        return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
    }

    /// Merge the planner's answer back onto the jobs. Returns the filled jobs plus the
    /// ids it failed to answer for, so the caller can say exactly what is missing
    /// instead of generating a symbol with an empty subject.
    static func apply(planJSON: [String: Any], to jobs: [AssetJob])
        -> (jobs: [AssetJob], missing: [String], palette: [RGB8]) {
        var bySubject: [String: (String, String)] = [:]
        var frames: [String: Bool] = [:]
        for case let a as [String: Any] in (planJSON["assets"] as? [Any] ?? []) {
            guard let id = a["id"] as? String else { continue }
            bySubject[id] = ((a["subject"] as? String ?? ""), (a["silhouette"] as? String ?? ""))
            frames[id] = (a["frame"] as? Bool) ?? ((a["frame"] as? NSNumber)?.boolValue ?? false)
        }
        var out: [AssetJob] = [], missing: [String] = []
        for var j in jobs {
            let subj = (bySubject[j.id]?.0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subj.isEmpty else {
                // CLEAR it rather than leaving the previous run's subject in place.
                // Designing the set a second time and getting a shorter answer used to
                // leave the old subject sitting there — reported as missing, but still
                // carrying text, so generation drew it anyway and charged for it.
                missing.append(j.id)
                j.subject = ""; j.silhouette = ""
                out.append(j); continue
            }
            j.subject = subj
            j.silhouette = (bySubject[j.id]?.1 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            j.hasFrame = frames[j.id] ?? false
            out.append(j)
        }
        let palette = (planJSON["palette"] as? [Any] ?? [])
            .compactMap { ($0 as? String).flatMap(SlotBackingRules.hex) }
        return (out, missing, palette)
    }

    /// Silhouettes the planner reused. Empty is the goal; anything here is a real
    /// defect in the set the user should see before spending credits on it.
    /// Words too generic to make two symbols alike on their own.
    static let weakWords: Set<String> = ["golden", "gold", "magic", "magical", "glowing",
                                         "enchanted", "ornate", "giant", "great", "the",
                                         "shining", "sparkling", "bright", "large", "small"]

    /// The words in a silhouette that actually distinguish it.
    static func significantWords(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !weakWords.contains($0) })
    }

    public static func silhouetteClashes(_ jobs: [AssetJob]) -> [String: [String]] {
        var byShape: [String: [String]] = [:]
        for j in jobs where j.kind == .symbol {
            let k = j.silhouette.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            byShape[k, default: []].append(j.id)
        }
        var out = byShape.filter { $0.value.count > 1 }

        // Exact matches are the easy half. "Fireball Coin" and "Flaming Coin" are two
        // different strings and two symbols that will look the same on a reel, and a
        // plain equality check waves them straight through — which is what happened in a
        // real plan. Two silhouettes sharing a meaningful noun are reported too.
        let named = jobs.filter { $0.kind == .symbol && !$0.silhouette.isEmpty }
        for i in named.indices {
            for k in named.indices where k > i {
                guard named[i].silhouette.lowercased() != named[k].silhouette.lowercased()
                else { continue }
                // Sharing a word inside a family role is the POINT, not a fault — low pays
                // are one family by rule, jackpots are one shared construction. Flagging
                // "wooden (LP1…LP4)" or "chest (JP1…JP4)" told the user their correct set
                // was broken. Two members of a family clash only when literally identical.
                if named[i].role == named[k].role && named[i].role.isFamily { continue }
                let shared = significantWords(named[i].silhouette)
                    .intersection(significantWords(named[k].silhouette))
                guard let word = shared.sorted().first else { continue }
                out[word, default: []].append(contentsOf: [named[i].id, named[k].id])
            }
        }
        return out.mapValues { Array(Set($0)).sorted() }.filter { $0.value.count > 1 }
    }
}
