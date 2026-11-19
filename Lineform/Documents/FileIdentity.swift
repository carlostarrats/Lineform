import Foundation

/// Whether two URLs name the same file on disk. Shared by the Save As destination guard and by
/// open-time tab dedupe (`EditorTabStore.locate`) so "already open" means the same thing in both —
/// if they disagreed, a file could slip past dedupe and then be refused at save, or vice versa.
enum FileIdentity {
    /// Both sides are first put through `resolvingSymlinksInPath()`, which is the only thing that
    /// follows a symlink at the LAST path component — `canonicalPath` resolves symlinked ancestors
    /// but hands back the link's own path for the leaf, so without this an `alias.md` tab and the
    /// `note.md` it points at look like two files. It is safe to use here, unlike inside
    /// `comparisonKey`, precisely because it is applied to BOTH sides before anything else, so it
    /// can't pull the two keys in opposite directions.
    ///
    /// Sameness is deliberately decided by PATH and not by file identity (inode): two HARD LINKS to
    /// one inode are not the same file for our purposes. Every write in this app is a safe-save —
    /// `Data.write(.atomic)` and `NSDocument`'s save alike write a temp file and rename it into
    /// place — which REPLACES the directory entry and breaks the link rather than overwriting shared
    /// bytes, so the other tab's file is left untouched. Verified by measurement across every write
    /// this fronts: `.saveOperation`, `.saveAsOperation`, autosave-in-place and `Data.write(.atomic)`
    /// all leave a new inode with the sibling intact. Matching on inode would refuse a harmless save,
    /// and a wrong refusal has no in-app override.
    static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        key(for: lhs) == key(for: rhs)
    }

    /// The comparison key on its own, so a caller matching ONE url against many (tab dedupe) can
    /// resolve the query once instead of re-walking the file system for every candidate — each call
    /// is up to four disk round-trips on the main thread, and iCloud/network volumes make that felt.
    static func key(for url: URL) -> String {
        comparisonKey(for: url.standardizedFileURL.resolvingSymlinksInPath())
    }

    /// A path normalized far enough that two spellings of one file compare equal. Plain path
    /// comparison is not enough: macOS volumes are case-INSENSITIVE by default, so `Notes.md` and
    /// `notes.md` are one file and a string compare would miss the clobber.
    ///
    /// `canonicalPath` returns the true on-disk casing and resolves symlinked ancestors, so a
    /// case-only difference matches on a case-insensitive volume and does NOT match on a
    /// case-sensitive one (where they really are two files). It exists only for a file that is on
    /// disk, so a not-yet-created destination normalizes its PARENT directory instead and re-attaches
    /// the file name.
    ///
    /// The parent is resolved through symlinks BEFORE being canonicalized, because `canonicalPath`
    /// will not resolve a symlinked directory that is the last component it is handed — so `/tmp`
    /// would stay `/tmp` and `/tmp/ghost.md` vs `/private/tmp/ghost.md` (one directory, two
    /// spellings) would produce two keys. The `canonicalPath` call on the already-resolved parent is
    /// belt-and-braces: no case is known where it changes the result, since `resolvingSymlinksInPath`
    /// also folds case for components that exist.
    ///
    /// KNOWN GAPS (accepted), all requiring NEITHER side to exist: a difference only in the FILE
    /// NAME's case; a last component that is itself a symlink; and a parent chain that isn't on disk
    /// either (`/tmp/nope/x.md` vs `/private/tmp/nope/x.md`). Every one needs a path that isn't on
    /// disk — and both overwriting and opening mean it is, and `NSSavePanel` only ever yields an
    /// existing parent — so none is reachable. Do not "fix" the case gap by lowercasing: that would
    /// wrongly refuse legitimate saves on a case-sensitive volume, with no in-app override.
    private static func comparisonKey(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        if let canonical = try? standardized.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return canonical
        }
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        let canonicalParent = (try? parent.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? parent.path
        return canonicalParent + "/" + standardized.lastPathComponent
    }
}
