import Foundation

/// Abstraction over `FileManager.startDownloadingUbiquitousItem(at:)` so the
/// keep-downloaded behavior can be exercised in tests without real iCloud files.
protocol UbiquitousItemDownloader {
    func startDownloadingUbiquitousItem(at url: URL) throws
}

extension FileManager: UbiquitousItemDownloader {}
