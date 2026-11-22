import Foundation

/// Picks the folder a new document saves into: the Documents folder of Lineform's iCloud
/// container when iCloud Drive is available to the app, otherwise the app's own Documents folder
/// (which the Files app shows under On My iPhone › Lineform).
///
/// iCloud being off is a fully working state, not an error. Debug builds carry no iCloud
/// entitlement, so they always get the on-device folder.
public struct DocumentFolderResolver {
    /// The iCloud container identifier, shared with the Mac app.
    static let containerIdentifier = "iCloud.com.lineform.app"

    private let ubiquityDocumentsURL: () -> URL?
    private let localDocumentsURL: URL

    /// - Parameters:
    ///   - ubiquityDocumentsURL: the container's `Documents` folder, or nil when iCloud is
    ///     unavailable. Asked on every `saveFolder()` call, so turning iCloud on or off is seen.
    ///   - localDocumentsURL: the on-device fallback.
    public init(ubiquityDocumentsURL: @escaping () -> URL?, localDocumentsURL: URL) {
        self.ubiquityDocumentsURL = ubiquityDocumentsURL
        self.localDocumentsURL = localDocumentsURL
    }

    /// The iCloud Documents folder when there is one, otherwise the local folder. With the live
    /// resolver this may block on the ubiquity lookup: call it off the main thread.
    public func saveFolder() -> URL {
        ubiquityDocumentsURL() ?? localDocumentsURL
    }

    /// The iCloud Documents folder alone, or nil when iCloud is unavailable. Same blocking rule
    /// as `saveFolder()`.
    public func iCloudFolder() -> URL? {
        ubiquityDocumentsURL()
    }

    /// The on-device folder, whether or not iCloud is available.
    public var deviceFolder: URL { localDocumentsURL }

    /// The resolver the app uses: `url(forUbiquityContainerIdentifier:)` for Lineform's container
    /// plus `Documents`, falling back to the user-domain Documents directory. Apple requires the
    /// ubiquity lookup off the main thread, so call `saveFolder()` from a background task.
    public static func live(fileManager: FileManager = .default) -> DocumentFolderResolver {
        let local = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return DocumentFolderResolver(
            ubiquityDocumentsURL: {
                fileManager.url(forUbiquityContainerIdentifier: containerIdentifier)?
                    .appendingPathComponent("Documents", isDirectory: true)
            },
            localDocumentsURL: local
        )
    }
}
