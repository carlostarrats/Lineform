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

var pipedDirectory: URL {
    LineformCLIPaths.pipedDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
}

/// Delete piped files older than 7 days. Runs opportunistically on each invocation because the
/// sandboxed app cannot enumerate this (real, out-of-container) directory. Age-only: a 7-day-old
/// piped file being actively open is not a realistic concern. Best-effort; never fatal.
func cleanUpStalePipedFiles() {
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(
        at: pipedDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return }
    let entries: [(url: URL, modified: Date)] = contents.compactMap { url in
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        return (url, modified)
    }
    let stale = LineformPipedHousekeeping.stale(
        entries: entries,
        now: Date(),
        olderThan: 7 * 24 * 60 * 60,
        openDocumentURLs: []
    )
    for url in stale { try? fm.removeItem(at: url) }
}

func openInApp(_ urls: [URL]) -> Never {
    guard let app = enclosingAppURL() else {
        fail("lineform: could not locate Lineform.app — reinstall via Lineform → Install Command Line Tool…")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", app.path] + urls.map(\.path)
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fail("lineform: failed to open Lineform")
    }
    exit(process.terminationStatus == 0 ? 0 : 1)
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
    let maxBytes = 10_000_000
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
