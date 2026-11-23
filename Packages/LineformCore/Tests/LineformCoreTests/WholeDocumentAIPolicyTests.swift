import XCTest
@testable import LineformCore
import LineformCoreTestSupport

/// Ask AI for the whole document (nothing selected): one length policy for the Mac and the
/// iPhone. Up to 1,500 words it runs; above that the writer confirms first; past `AILimits` it is
/// refused before anything is read or sent.
@MainActor
final class WholeDocumentAIPolicyTests: XCTestCase {
    private var suiteName = ""
    private var factoryCalls = 0

    override func tearDown() {
        if !suiteName.isEmpty { UserDefaults().removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    private func words(_ count: Int) -> String {
        Array(repeating: "word", count: count).joined(separator: " ") + "."
    }

    private func make(_ text: String, _ behavior: FakeAIClient.Behavior)
        -> (AIActionController, FakeAIEditorSurface, FakeAIClient, InMemoryAIKeychain) {
        suiteName = "WholeDocumentAIPolicyTests.\(UUID().uuidString)"
        let keychain = InMemoryAIKeychain()
        let store = AIConnectionStore(defaults: UserDefaults(suiteName: suiteName)!, keychain: keychain)
        XCTAssertNil(store.connect(.claude, key: "test-key-not-real"))
        let fake = FakeAIClient(behavior)
        let controller = AIActionController(connectionStore: store) { [unowned self] _ in
            self.factoryCalls += 1
            return fake
        }
        let surface = FakeAIEditorSurface(text)
        controller.editor = surface
        return (controller, surface, fake, keychain)
    }

    func testShortDocumentRuns() async throws {
        XCTAssertEqual(WholeDocumentAIPolicy.confirmWordCount, 1_500)
        XCTAssertEqual(WholeDocumentAIPolicy.decision(for: words(1_500)), .run)
        XCTAssertEqual(WholeDocumentAIPolicy.decision(for: "# Notes\n\nA short note."), .run)

        let text = "# Notes\n\nThe big dog ran.\n\nThe big cat sat."
        let (controller, surface, fake, _) = make(text, FakeAIClient.revising { _, s in
            s.replacingOccurrences(of: "big", with: "small")
        })
        controller.runWholeDocument(.rephrase, text: text, note: nil)
        await controller.runTask?.value
        guard case .reviewing(let session) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertEqual(session.selectionRange, NSRange(location: 0, length: (text as NSString).length),
                       "the range is the whole document")
        XCTAssertEqual(FakeAIClient.segments(in: fake.prompts[0]), ["Notes", "The big dog ran.", "The big cat sat."])
        controller.handle(.acceptCurrent)
        XCTAssertEqual(surface.string, "# Notes\n\nThe small dog ran.\n\nThe small cat sat.")
    }

    /// Words are what is sent: the prose, not the Markdown around it.
    func testOver1500WordsConfirms() {
        XCTAssertEqual(WholeDocumentAIPolicy.decision(for: words(1_501)), .confirm(words: 1_501))
        XCTAssertEqual(WholeDocumentAIPolicy.decision(for: words(1_600)), .confirm(words: 1_600))
        let structured = "```\n" + words(3_000) + "\n```\n\n" + words(1_400)
        XCTAssertEqual(WholeDocumentAIPolicy.decision(for: structured), .run, "code is never sent, so never counted")
        XCTAssertEqual(WholeDocumentAIPolicy.confirmationTitle(words: 1_600, recipient: "Claude"),
                       "Send the whole document (1,600 words) to Claude?")
        XCTAssertEqual(WholeDocumentAIPolicy.sendTitle, "Send")
        XCTAssertEqual(WholeDocumentAIPolicy.cancelTitle, "Cancel")
        XCTAssertEqual(WholeDocumentAIPolicy.recipient(for: .claude, otherEndpoint: nil), "Claude")
        XCTAssertEqual(WholeDocumentAIPolicy.recipient(for: .other, otherEndpoint: URL(string: "http://localhost:11434/v1")),
                       "localhost")
        XCTAssertEqual(WholeDocumentAIPolicy.recipient(for: .other, otherEndpoint: nil), "Your AI")
    }

    /// 5,000 words is past `AILimits`: refused with the limit message before the Keychain is
    /// read, a client made or a request sent.
    func testOverLimitRefusesWithoutKeychainRead() async {
        let text = words(5_000)
        XCTAssertEqual(WholeDocumentAIPolicy.decision(for: text), .refuse)
        let many = Array(repeating: "Line.", count: AILimits.maxSegments + 1).joined(separator: "\n\n")
        XCTAssertEqual(WholeDocumentAIPolicy.decision(for: many), .refuse)
        XCTAssertEqual(WholeDocumentAIPolicy.refusalMessage, "Select a part of the document — about 4,000 words at most.")

        let (controller, surface, fake, keychain) = make(text, .reply("{}"))
        let readsBefore = keychain.readCount
        controller.runWholeDocument(.rephrase, text: text, note: "tighten it")
        await controller.runTask?.value
        XCTAssertEqual(controller.state, .message(WholeDocumentAIPolicy.refusalMessage))
        XCTAssertEqual(keychain.readCount, readsBefore, "the Keychain is not read")
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertTrue(fake.prompts.isEmpty)
        XCTAssertEqual(surface.announcements.last, WholeDocumentAIPolicy.refusalMessage)

        // The Mac's command refuses before opening the comment card, through the same card.
        let (refusing, _, _, refusingKeychain) = make(text, .reply("{}"))
        refusing.refuseWholeDocument()
        XCTAssertEqual(refusing.state, .message(WholeDocumentAIPolicy.refusalMessage))
        XCTAssertEqual(refusingKeychain.readCount, 0)

        // Find counts sentences, not segments: a document the policy passes can still be over
        // the limit for Find, and says so in the whole-document words.
        let sentences = Array(repeating: "Go.", count: AILimits.maxSegments + 1).joined(separator: " ")
        XCTAssertEqual(WholeDocumentAIPolicy.decision(for: sentences), .run)
        let (finding, _, findFake, _) = make(sentences, .reply("{}"))
        finding.runWholeDocument(.markLong, text: sentences, note: nil)
        await finding.runTask?.value
        XCTAssertEqual(finding.state, .message(WholeDocumentAIPolicy.refusalMessage))
        XCTAssertTrue(findFake.prompts.isEmpty)
    }

    /// The whole document is reviewed under the same invariants as a selection: only prose is
    /// sent, a reply that would change structure never reaches the document, and an honest one
    /// keeps every construct byte-for-byte.
    func testWholeDocumentReviewProtectsStructure() async {
        let text = "---\ntitle: Notes\n---\n# Heading here\n\n- First item is here.\n\n```swift\nlet x = 1\n```\n\nA [link](https://example.com) in prose.\r\n"
        let (mangling, mangledSurface, mangleFake, _) = make(text, FakeAIClient.revising { _, s in "**" + s + "\n# new" })
        mangling.runWholeDocument(.rephrase, text: text, note: nil)
        await mangling.runTask?.value
        let sent = FakeAIClient.segments(in: mangleFake.prompts[0])
        XCTAssertFalse(sent.joined().contains("let x"), "code is never sent")
        XCTAssertFalse(sent.joined().contains("https://"), "link addresses are never sent")
        XCTAssertFalse(sent.joined().contains("title:"), "front matter is never sent")
        if case .reviewing = mangling.state { XCTFail("a structure-changing reply must not open a review") }
        XCTAssertEqual(mangledSurface.string, text)
        XCTAssertTrue(mangledSurface.editCalls.isEmpty)

        let (honest, honestSurface, _, _) = make(text, FakeAIClient.revising { _, s in
            s.replacingOccurrences(of: "here", with: "there")
        })
        honest.runWholeDocument(.rephrase, text: text, note: nil)
        await honest.runTask?.value
        honest.handle(.acceptCurrent)
        XCTAssertEqual(honestSurface.string, text.replacingOccurrences(of: "here", with: "there"))
        XCTAssertEqual(MarkdownStructureMap.signature(of: honestSurface.string as NSString,
                                                      scope: NSRange(location: 0, length: (honestSurface.string as NSString).length)),
                       MarkdownStructureMap.signature(of: text as NSString, scope: NSRange(location: 0, length: (text as NSString).length)))
        XCTAssertEqual(honestSurface.collapsedSelections.last, (honestSurface.string as NSString).length - 2,
                       "the caret lands at the document's text end, before its trailing line ending")
    }
}
