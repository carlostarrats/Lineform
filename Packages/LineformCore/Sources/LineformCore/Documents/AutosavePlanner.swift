import Foundation

/// Decides what an autosave does with a document's file: nothing yet, create it, write it, or
/// rename it so its name keeps following the first line.
///
/// A pure state machine: the caller reports each text it is about to save, with the names already
/// in the folder, and carries out the action it gets back. The rules:
/// - With no file and no text (nothing but whitespace), nothing happens: an Untitled document with
///   nothing typed creates no file.
/// - With no file and some text, the file is created, named from the first line
///   (`DocumentNaming.baseName(fromText:)`), unique in the folder.
/// - While the name still follows the first line, a first line whose base name changed renames the
///   file; any other change writes it.
/// - Once the user renames the file (`markRenamedByUser()`), or for a file that was opened rather
///   than created, the name never changes again; every change writes.
public struct AutosavePlanner: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case create(fileName: String)
        case write
        case rename(to: String)
    }

    /// The document's file name, nil until the first `.create`.
    public private(set) var fileName: String?
    /// True while the file name follows the first line.
    public private(set) var isNamedFromFirstLine: Bool
    /// The base name the current file name was derived from, before it was made unique. Compared
    /// with each new first line, so "Notes 2.md" (named "Notes" next to an existing "Notes.md")
    /// is not renamed while the first line still says "Notes".
    private var namedBase: String?

    public init(existingFileName: String?, isNamedFromFirstLine: Bool) {
        self.fileName = existingFileName
        self.isNamedFromFirstLine = isNamedFromFirstLine
        self.namedBase = existingFileName.map { ($0 as NSString).deletingPathExtension }
    }

    /// The action for saving `text`. `existingNames` are the file names in the folder (the
    /// document's own file may be among them).
    public mutating func textChanged(_ text: String, existingNames: Set<String>) -> Action {
        guard let fileName else {
            guard let base = DocumentNaming.baseName(fromText: text) else { return .none }
            let name = DocumentNaming.uniqueFileName(base: base, existingNames: existingNames)
            self.fileName = name
            namedBase = base
            return .create(fileName: name)
        }
        guard isNamedFromFirstLine,
              let base = DocumentNaming.baseName(fromText: text),
              base != namedBase
        else { return .write }

        // The document's own name is free for it to keep: without this, a case-only change
        // ("hello" to "Hello") would collide with itself and become "Hello 2.md".
        let ownKey = Self.comparisonKey(fileName)
        let others = existingNames.filter { Self.comparisonKey($0) != ownKey }
        let name = DocumentNaming.uniqueFileName(base: base, existingNames: others)
        namedBase = base
        guard name != fileName else { return .write }
        self.fileName = name
        return .rename(to: name)
    }

    /// The user renamed the file: its name never follows the first line again.
    public mutating func markRenamedByUser() {
        isNamedFromFirstLine = false
    }

    /// Someone else (the Files app, another device) moved or renamed the file to `newFileName`.
    /// That is the user's choice of name, so automatic renaming stops.
    public mutating func fileWasRenamed(to newFileName: String) {
        fileName = newFileName
        namedBase = (newFileName as NSString).deletingPathExtension
        markRenamedByUser()
    }

    /// The same comparison `DocumentNaming.uniqueFileName` uses: case- and normalisation-blind,
    /// as the default APFS volume is.
    private static func comparisonKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
