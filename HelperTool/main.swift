import AppKit
import Foundation

// Thin CLI wrapper. Pure decisions live in Lineform/CommandLineTool/LineformCommandLine.swift
// (shared with the app module for testing); this file only does IO + process hand-off. It is
// NOT a member of any Xcode target — packaging/build-release.sh compiles it together with that
// shared file into Lineform.app/Contents/Helpers/lineform.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// The absolute path of this running executable, regardless of how it was invoked (bare name
/// via $PATH, relative, or absolute). `CommandLine.arguments[0]` is unreliable (it's argv[0],
/// typically the bare name under $PATH lookup), so use `_NSGetExecutablePath`.
func runningExecutableURL() -> URL {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&buffer, &size) == 0 {
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }
    return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
}

/// The .app that contains this helper (…/Contents/Helpers/lineform → …/X.app).
func enclosingAppURL() -> URL? {
    let real = runningExecutableURL()
    let app = real.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app : nil
}

func appVersion(_ app: URL) -> String {
    let plist = app.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist),
          let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
          let version = info["CFBundleShortVersionString"] as? String else { return "unknown" }
    return version
}

/// Resolved through the SHARED definition, so the helper and the app can never disagree about
/// where piped files live. Under the sandbox this is the App Group container; unsandboxed
/// (Debug) it falls back to the home-relative path.
var pipedDirectory: URL {
    LineformCLIPaths.sharedPipedDirectory()
}

/// Delete piped files whose last activity is older than 7 days. Runs opportunistically on each
/// invocation. Uses the later of modification and access time, so a file that is open in the app
/// (autosave refreshes mtime) or was recently read is kept. Best-effort; never fatal.
///
/// This stays in the helper now that the directory is the shared App Group container: both sides
/// can reach it, and the helper is the process that knows a pipe just happened. (It used to live
/// here because the sandboxed app could not enumerate the real out-of-container path at all.)
func cleanUpStalePipedFiles() {
    let fm = FileManager.default
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .contentAccessDateKey]
    guard let contents = try? fm.contentsOfDirectory(
        at: pipedDirectory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
    ) else { return }
    let entries: [(url: URL, lastActivity: Date)] = contents.compactMap { url in
        guard let values = try? url.resourceValues(forKeys: keys),
              let modified = values.contentModificationDate else { return nil }
        return (url, max(modified, values.contentAccessDate ?? modified))
    }
    let stale = LineformPipedHousekeeping.stale(
        entries: entries,
        now: Date(),
        olderThan: 7 * 24 * 60 * 60
    )
    for url in stale { try? fm.removeItem(at: url) }
}

/// Hand the documents to Lineform through LaunchServices.
///
/// `NSWorkspace`, NOT a spawned `/usr/bin/open`: once the helper is sandboxed the child would
/// inherit the sandbox, and going through LaunchServices directly is the supported path. It also
/// matters that the helper never READS these files — it only stats them and passes the URLs. The
/// sandbox restricts reading file *data*, so a sandboxed helper can hand over a path it could not
/// itself open, and the app receives its own grant exactly as for a Finder double-click.
func openInApp(_ urls: [URL]) -> Never {
    guard let app = enclosingAppURL() else {
        fail("lineform: could not locate Lineform.app — reinstall via Lineform → Install Command Line Tool…")
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    let semaphore = DispatchSemaphore(value: 0)
    var failure: Error?
    NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { _, error in
        failure = error
        semaphore.signal()
    }
    semaphore.wait()
    if failure != nil { fail("lineform: failed to open Lineform") }
    exit(0)
}

/// Read stdin but stop once we exceed the limit, so a huge/infinite pipe is not fully buffered.
func readStdinBounded(limit: Int) -> Data {
    var data = Data()
    let handle = FileHandle.standardInput
    while data.count <= limit {
        let chunk = handle.readData(ofLength: 64 * 1024)
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    return data
}

cleanUpStalePipedFiles()

let args = Array(CommandLine.arguments.dropFirst())
switch LineformCLICommand.parse(args) {
case .help:
    print(LineformCLIMessages.usage)
    exit(0)
case .version:
    print(enclosingAppURL().map(appVersion) ?? "unknown")
    exit(0)
case .invalid(let flag):
    fail("lineform: unknown option: \(flag)")
case .open(let paths):
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    var urls: [URL] = []
    for path in paths {
        let url = LineformCLIPaths.resolve(path, relativeTo: base)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            fail(LineformCLIMessages.noSuchFile(path))
        }
        if isDir.boolValue { fail(LineformCLIMessages.isDirectory(path)) }
        urls.append(url)
    }
    openInApp(urls)
case .readStdin:
    let maxBytes = LineformPipeValidation.maxPipedBytes
    let data = readStdinBounded(limit: maxBytes)
    switch LineformPipeValidation.validate(data, maxBytes: maxBytes) {
    case .empty: fail(LineformCLIMessages.emptyInput)
    case .notText: fail(LineformCLIMessages.notText)
    case .tooLarge: fail(LineformCLIMessages.tooLarge)
    case .ok: break
    }
    try? FileManager.default.createDirectory(at: pipedDirectory, withIntermediateDirectories: true)
    let name = LineformCLIPaths.pipedFileName(
        timestamp: LineformCLIPaths.pipedTimestamp(from: Date()),
        unique: UUID().uuidString.prefix(8).lowercased()
    )
    let fileURL = pipedDirectory.appendingPathComponent(name)
    do {
        try data.write(to: fileURL)
    } catch {
        fail("lineform: could not write piped input")
    }
    openInApp([fileURL])
}
