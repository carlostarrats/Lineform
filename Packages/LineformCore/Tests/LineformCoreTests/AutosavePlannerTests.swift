import XCTest
@testable import LineformCore

final class AutosavePlannerTests: XCTestCase {
    private func newDocument() -> AutosavePlanner {
        AutosavePlanner(existingFileName: nil, isNamedFromFirstLine: true)
    }

    func testEmptyUntitledCreatesNothing() {
        var planner = newDocument()

        XCTAssertEqual(planner.textChanged("", existingNames: []), .none)
        XCTAssertEqual(planner.textChanged("  \n\t\n", existingNames: []), .none)
        XCTAssertNil(planner.fileName)
    }

    func testFirstTextCreatesNamedFile() {
        var planner = newDocument()

        XCTAssertEqual(planner.textChanged("# Shopping list\n- eggs", existingNames: []), .create(fileName: "Shopping list.md"))
        XCTAssertEqual(planner.fileName, "Shopping list.md")
        XCTAssertTrue(planner.isNamedFromFirstLine)
    }

    func testFirstTextCreatesUniqueName() {
        var planner = newDocument()

        XCTAssertEqual(planner.textChanged("Notes", existingNames: ["notes.md"]), .create(fileName: "Notes 2.md"))
    }

    /// The first keystroke names the file "H.md"; the next ones rename it as the line grows, and a
    /// change with the same first line then only writes.
    func testEditingFirstLineRenamesWhileAutoNamed() {
        var planner = newDocument()

        XCTAssertEqual(planner.textChanged("H", existingNames: []), .create(fileName: "H.md"))
        XCTAssertEqual(planner.textChanged("Hello", existingNames: ["H.md"]), .rename(to: "Hello.md"))
        XCTAssertEqual(planner.fileName, "Hello.md")
        XCTAssertEqual(planner.textChanged("Hello\nworld", existingNames: ["Hello.md"]), .write)
    }

    /// A case-only change of the first line renames the file to the new case, not to " 2".
    func testCaseOnlyFirstLineChangeRenamesToTheNewCase() {
        var planner = newDocument()
        _ = planner.textChanged("hello", existingNames: [])

        XCTAssertEqual(planner.textChanged("Hello", existingNames: ["hello.md"]), .rename(to: "Hello.md"))
    }

    /// A name made unique ("Notes 2.md") is not renamed while the first line still says "Notes".
    func testUniquedNameIsKeptWhileTheFirstLineIsUnchanged() {
        var planner = newDocument()
        _ = planner.textChanged("Notes", existingNames: ["Notes.md"])

        XCTAssertEqual(planner.textChanged("Notes\nmore", existingNames: ["Notes.md", "Notes 2.md"]), .write)
        XCTAssertEqual(planner.fileName, "Notes 2.md")
    }

    func testUserRenameStopsAutoRename() {
        var planner = newDocument()
        _ = planner.textChanged("Draft", existingNames: [])

        planner.markRenamedByUser()

        XCTAssertFalse(planner.isNamedFromFirstLine)
        XCTAssertEqual(planner.textChanged("A new title", existingNames: ["Draft.md"]), .write)
        XCTAssertEqual(planner.textChanged("Another title", existingNames: ["Draft.md"]), .write)
        XCTAssertEqual(planner.fileName, "Draft.md")
    }

    /// An opened file, and a file renamed elsewhere, are never renamed automatically.
    func testOpenedOrExternallyRenamedFileOnlyWrites() {
        var opened = AutosavePlanner(existingFileName: "Kept.md", isNamedFromFirstLine: false)
        XCTAssertEqual(opened.textChanged("# Something else", existingNames: ["Kept.md"]), .write)

        var created = newDocument()
        _ = created.textChanged("Draft", existingNames: [])
        created.fileWasRenamed(to: "Chosen.md")
        XCTAssertEqual(created.fileName, "Chosen.md")
        XCTAssertEqual(created.textChanged("Different", existingNames: ["Chosen.md"]), .write)
    }

    func testOtherLinesOnlyWrite() {
        var planner = newDocument()
        _ = planner.textChanged("Title\nbody", existingNames: [])

        XCTAssertEqual(planner.textChanged("Title\nbody, longer", existingNames: ["Title.md"]), .write)
        XCTAssertEqual(planner.textChanged("Title\n", existingNames: ["Title.md"]), .write)
        // Emptying the document keeps its file and name.
        XCTAssertEqual(planner.textChanged("", existingNames: ["Title.md"]), .write)
        XCTAssertEqual(planner.fileName, "Title.md")
    }

    func testRenameAvoidsExistingName() {
        var planner = newDocument()
        _ = planner.textChanged("A", existingNames: [])

        XCTAssertEqual(planner.textChanged("B", existingNames: ["A.md", "b.md"]), .rename(to: "B 2.md"))
    }
}
