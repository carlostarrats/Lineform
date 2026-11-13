# Connect Your AI + AI Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a writer connect their own AI (Claude, ChatGPT, Google, or any OpenAI-compatible
server) from one window, then right-click a selection to Trim / Cut in half / Rewrite / Proofread
(reviewed as dimmed removals with per-change pills) or Mark weak or long sentences — with Markdown
structure never sent where excluded and never changed, and no network traffic unless connected and
the writer chose an action.

**Architecture:** A new `Lineform/AI/` group holds the connection (`AIConnectionStore`, Keychain),
two small HTTP clients (native Anthropic Messages, one OpenAI-compatible chat-completions client),
the action protocol (prompt, parser, diff), and the review session. The structure rule lives in
`Lineform/Editor/MarkdownStructureMap.swift`, built only from the repo's existing definitions
(`MarkdownWritingToolsProtection`, `MarkdownRangeAnalyzer`, `MarkdownInlineSyntax`,
`MarkdownBlockGrouping`, `markdownSourceLines`). Only prose segments are sent; replies are
re-assembled around the original structure and verified byte-for-byte. Review is an OVERLAY: a
read-only `AIReviewTextView` laid over the editor renders document + suggestions; the document
buffer only changes when a change is accepted, through the editor's normal undoable edit path, and
the finished action is recorded once with `DocumentHistoryController.recordAccepted`.

**Tech Stack:** Swift 5, SwiftUI + AppKit, TextKit 1, `URLSession`, Security.framework (Keychain),
XCTest, Python 3 stdlib (stub server). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-12-bring-your-own-ai-design.md` §3, §4, §4.1, §4.2, §4.3,
§7, §8. History (plan 1, shipped) is `docs/superpowers/plans/2026-11-12-history.md`; its current
behaviour is `docs/architecture/editor-behavior.md` § History (focus + counter; ignore the spec's
dot/blue History visuals). This plan is parts 2 + 3 of 3.

## Global Constraints

- **No network unless connected AND the writer chose an action.** Nothing at launch, at window
  creation, on opening Connect Your AI, or on pressing Connect (connecting does not test the key).
  Nothing is wired in `applicationDidFinishLaunching` (the test host is the app). No test touches
  the real network or the real Keychain.
- **AI UI is absent, not disabled, when nothing is connected** (context-menu group, cards).
- Keys live in the Keychain only (`SystemAIKeychain`, generic password, service
  `"<bundle id>.ai"`, account = `AIProvider.rawValue`, not synchronizable, legacy file keychain —
  no `kSecUseDataProtectionKeychain`, no new entitlement). Never UserDefaults, never files.
- One active connection. Connecting a provider deletes any other provider's key.
- Endpoints / models (each a single constant on `AIProvider`; verify each against the provider's
  docs when implementing and change only the constant):
  - Claude: `https://api.anthropic.com/v1/messages`, header `anthropic-version: 2026-10-21`,
    model `claude-sonnet-5-5`, keys page `https://platform.claude.com/settings/keys`.
  - ChatGPT: `https://api.openai.com/v1/chat/completions`, model `gpt-5-mini`, keys page
    `https://platform.openai.com/api-keys`.
  - Google: `https://generativelanguage.googleapis.com/v1beta/openai/chat/completions`, model
    `gemini-2.5-flash`, keys page `https://aistudio.google.com/apikey`.
  - Other: user address; `http` only for `localhost`, `127.0.0.1`, `::1` and `*.local`; `https`
    for anything else.
- Limits (`AILimits`): response ≤ **262,144 bytes** counted as bytes arrive; prose sent ≤
  **24,000 UTF-16 units** and ≤ **400 segments**; request timeout **60 s**, resource **120 s**;
  Anthropic `max_tokens` **16,000**. AI replies are plain text: never rendered as Markdown/HTML.
- **Markdown structure (spec §4.2 table) is never sent where excluded and never changed.** Only
  `MarkdownStructureMap` decides what is prose. A revised segment containing a line terminator
  (`\n`, `\r`, U+2028, U+2029, U+0085) or any `Cc` character, or that changes the structure
  signature of its block, is dropped. After composition the whole-document signature must equal the
  original or the suggestion is refused.
- Edits go `shouldChangeText` → `textStorage.replaceCharacters` → `didChangeText`, never
  `applyWholeTextReplacement`; ranges on composed-character boundaries; line endings and BOM are
  structure, so they are never in a replacement.
- The document is read-only during review; suggestions never enter the editor's text storage until
  accepted. Mark changes nothing.
- AI actions, review and Mark run in **Write** mode only (an action chosen in Split switches to
  Write first; leaving Write ends review). Unavailable while History mode is on and inside a
  `.word` History passage (spec §5).
- No full-width bar at the top of window content: progress and review cards float as overlays at
  the bottom of `editorContent`, never at the top.
- Reuse existing inks: removed text `HistoryPalette.recededInk`, Mark wash `HistoryPalette.tint`,
  pills `theme.textColor` (current) / `HistoryPalette.recededInk` (others). No new colours.
- Hook keys in `doCommand(by:)` / `insertNewline` / `insertText`, never `keyDown`. Never put
  SwiftUI accessibility modifiers on `MarkdownTextViewRepresentable`. Hit-tested affordances get
  `accessibilityCustomActions`; progress is announced (`.announcementRequested`), never written
  into a text view's AX value.
- All chrome strings `String(localized:)` with English as key, translated into es, fr, de, ja,
  zh-Hans in `Lineform/Localizable.xcstrings`; `AIProvider`/`AIAction` rawValues are persisted
  identity and never localized (`title`/`displayName` properties instead). Brand names (Claude,
  ChatGPT, Google, Anthropic, OpenAI) are not translated.
- Every `-only-testing` run includes `LineformTests/LocalizationSourceSweepTests` and
  `LineformTests/LocalizationCatalogTests`.
- New `.swift` files are added to `Lineform.xcodeproj/project.pbxproj` by hand (objectVersion 56,
  no synced groups): PBXBuildFile `1F000001…<serial>`, PBXFileReference `1F000002…<serial>`, group
  child, Sources phase. Next free serial is **`04DD`**, taken in order across tasks. The new
  `Lineform/AI` PBXGroup is `1F00000700000000000004DD` (child of the `Lineform` group); files
  start at `04DE`.
- Never construct an `NSWindow` in default-plan tests. Test command base:
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`.

## Review Focus

1. **The text changes while the AI is thinking** (the writer types, live reload, a tab switch).
   The reply must be discarded, never applied to shifted ranges. → Task 6
   `testResponseDiscardedWhenTextChangedWhileRunning`.
2. **The same phrase appears twice in the selection** and both get the same suggestion. Accepting
   the second must edit only the second. → Task 6
   `testAcceptingOneOfTwoIdenticalChangesEditsOnlyThatOne`.
3. **A chatty or broken model** (preamble, ```json fences, wrong segment count, `{}`, numbers
   instead of strings, newlines inside a segment, a 10× longer segment). Fenced/preambled JSON is
   accepted; everything else is refused or dropped per segment, never applied. → Task 5
   `testParsesFencedJSONWithPreamble`, `testUnusableRepliesAreRefused`; Task 4
   `testGuardDropsLineBreaksControlCharactersAndRunaways`.
4. **Emoji, combining marks and CJK at the edges of a change.** Change ranges must never split a
   composed character. → Task 5 `testChangesNeverSplitComposedCharacters`.
5. **Live reload or a document swap during review.** Nothing stale is applied, no History is
   recorded from a replaced text, the overlay goes away. → Task 6
   `testAbandonOnReloadAppliesNothingAndRecordsNoHistory`.

---

### Task 1: Connection model and Keychain store

**Files:**
- Create: `Lineform/AI/AIProvider.swift`, `Lineform/AI/AIConnectionStore.swift`,
  `Lineform/AI/AIKeychain.swift`
- Create: `LineformTests/AITestDoubles.swift` (shared fakes; extended by later tasks)
- Test: `LineformTests/AIConnectionStoreTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj` (AI group + 5 files),
  `Lineform/Localizable.xcstrings`

**Interfaces:**
- Produces:
  - `enum AIProvider: String, CaseIterable, Codable, Identifiable { case claude, chatGPT = "chatgpt", google, other }`
    with `var displayName: String` ("Claude", "ChatGPT", "Google" verbatim; "Other" localized),
    `var companyName: String?` ("Anthropic", "OpenAI", "Google", nil), `var createKeyURL: URL?`,
    `var endpoint: URL?` (nil for `.other`), `var defaultModel: String?` (nil for `.other`),
    `var wireProtocol: AIWireProtocol` (values: Global Constraints).
  - `enum AIWireProtocol: Equatable { case anthropicMessages, openAIChatCompletions }`
  - `struct AIConnection: Equatable { let provider: AIProvider; let endpoint: URL; let model: String; let apiKey: String? }`
  - `protocol AIKeychain: AnyObject { func readKey(for provider: AIProvider) -> String?; @discardableResult func writeKey(_ key: String, for provider: AIProvider) -> Bool; func deleteKey(for provider: AIProvider) }`
  - `final class SystemAIKeychain: AIKeychain` — `init(service: String = (Bundle.main.bundleIdentifier ?? "com.lineform.app") + ".ai")`.
  - `enum AIEndpointValidation { static func chatCompletionsURL(from input: String) -> Result<URL, AIConnectError>; static func allowsPlainHTTP(host: String) -> Bool }`
    — requires an `http`/`https` scheme; appends `/chat/completions` unless the path already ends
    in it; `http` only when `allowsPlainHTTP` (`localhost`, `127.0.0.1`, `::1`, suffix `.local`).
  - `enum AIConnectError: Error, Equatable { case missingKey, invalidAddress, insecureAddress, keychainFailed }`
    with `var message: String` (localized: "Paste your API key first.", "Enter an address that
    starts with http:// or https://.", "Plain http:// is only allowed for a server on this Mac. Use
    https:// for other addresses.", "Lineform couldn't save the key in your Keychain.").
  - `@MainActor final class AIConnectionStore: ObservableObject`
    - `static let shared = AIConnectionStore(defaults: .standard, keychain: SystemAIKeychain())`
    - `init(defaults: UserDefaults, keychain: AIKeychain)` — reads UserDefaults ONLY.
    - `@Published private(set) var connectedProvider: AIProvider?`; `var isConnected: Bool`
    - `private(set) var otherEndpoint: URL?`, `private(set) var otherModel: String?`
    - `func connect(_ provider: AIProvider, key: String) -> AIConnectError?` (big three; key trimmed)
    - `func connectOther(address: String, key: String?, model: String?) -> AIConnectError?`
    - `func disconnect()` — deletes every provider's key, clears the defaults below.
    - `func resolvedConnection() -> AIConnection?` — the only Keychain read; called at action
      time. `.other` with an empty model resolves to model `"default"`.
    - Defaults keys: `Lineform.ai.provider`, `Lineform.ai.otherEndpoint`, `Lineform.ai.otherModel`.
  - Test double (`AITestDoubles.swift`): `final class InMemoryAIKeychain: AIKeychain` with
    `private(set) var readCount: Int`.

- [ ] **Step 1: Write the failing tests** (each on a fresh `UserDefaults(suiteName:)`):

```swift
func testInitReadsNoKeychainAndStartsDisconnected()   // keychain.readCount == 0; isConnected == false
func testConnectStoresKeyInKeychainNotDefaults()      // keychain has "sk-test"; no defaults value contains "sk-test"
func testConnectingAnotherProviderReplacesTheFirst()  // connect(.claude), connect(.google) → provider == .google; readKey(.claude) == nil
func testDisconnectRemovesKeyAndProvider()
func testConnectRejectsEmptyKey()                     // connect(.claude, key: "  ") == .missingKey; isConnected == false
func testPlainHTTPAllowedOnlyForLocalHosts() {
    XCTAssertEqual(try AIEndpointValidation.chatCompletionsURL(from: "http://localhost:11434/v1").get().absoluteString,
                   "http://localhost:11434/v1/chat/completions")
    XCTAssertEqual(try AIEndpointValidation.chatCompletionsURL(from: "https://example.com/v1/chat/completions").get().absoluteString,
                   "https://example.com/v1/chat/completions")
    XCTAssertEqual(AIEndpointValidation.chatCompletionsURL(from: "http://192.168.1.5:1234/v1"), .failure(.insecureAddress))
    XCTAssertEqual(AIEndpointValidation.chatCompletionsURL(from: "ftp://x"), .failure(.invalidAddress))
}
func testOtherConnectsWithoutAKey()                   // connectOther("http://127.0.0.1:8765/v1", nil, nil) == nil; resolved.apiKey == nil; model == "default"
func testRelaunchRestoresConnectedProvider()          // second store on same defaults → .claude
func testResolvedConnectionUsesProviderDefaults()     // .claude → endpoint "https://api.anthropic.com/v1/messages", model "claude-sonnet-5-5"
```

- [ ] **Step 2: Run to verify they fail** — base command plus
  `-only-testing:LineformTests/AIConnectionStoreTests` and the two localization gates.
  Expected: build failure, `AIConnectionStore` not found.
- [ ] **Step 3: Implement** the three files and the pbxproj entries; add the new strings with all
  five translations. `SystemAIKeychain` uses `SecItemCopyMatching` / `SecItemAdd` /
  `SecItemUpdate` / `SecItemDelete` with `kSecClassGenericPassword`,
  `kSecAttrAccessibleWhenUnlocked`, `kSecAttrSynchronizable: false`.
- [ ] **Step 4: Run to verify they pass.** Expected: 9 tests, 0 failures; both gates pass.
- [ ] **Step 5: Commit** — `git commit -m "Add AI connection store and Keychain"`.

---

### Task 2: HTTP clients and the local stub server

**Files:**
- Create: `Lineform/AI/AIClient.swift` (protocol, `AIPrompt`, `AIClientError`, `AILimits`,
  `AIClientFactory`), `Lineform/AI/AIHTTPTransport.swift`,
  `Lineform/AI/AnthropicMessagesClient.swift`, `Lineform/AI/OpenAICompatibleClient.swift`
- Create: `scripts/ai-stub-server.py`
- Test: `LineformTests/AIClientTests.swift`; extend `LineformTests/AITestDoubles.swift`
- Modify: pbxproj (4 files), `Lineform/Localizable.xcstrings`

**Interfaces:**
- Consumes: `AIConnection`, `AIProvider`, `AIWireProtocol` (Task 1).
- Produces:
  - `struct AIPrompt: Equatable { let system: String; let user: String }`
  - `protocol AIClient: Sendable { func complete(_ prompt: AIPrompt) async throws -> String }`
  - `enum AILimits` — `maxResponseBytes = 262_144`, `maxProseUTF16 = 24_000`, `maxSegments = 400`,
    `requestTimeout: TimeInterval = 60`, `resourceTimeout: TimeInterval = 120`,
    `anthropicMaxTokens = 16_000`.
  - `enum AIClientError: Error, Equatable { case unauthorized, rateLimited, modelNotFound, server(status: Int), timedOut, offline, responseTooLarge, unusableResponse, refused, cancelled }`
    with `var message: String` localized (e.g. unauthorized: "The key wasn't accepted. Check it in
    Connect Your AI."; modelNotFound: "The server didn't recognise the model. Enter a model name in
    Connect Your AI."; refused: "The AI declined this request."; unusableResponse: "The AI's reply
    couldn't be used. Nothing was changed."; offline: "Couldn't reach the AI. Check your
    connection."; timedOut: "The AI took too long to answer."; rateLimited: "The AI is busy or your
    usage limit was reached. Try again later."; server: "The AI service returned an error (%lld).";
    responseTooLarge: "The AI's reply was too large to use."; cancelled: no message shown).
  - `protocol AIHTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }`
  - `final class URLSessionAITransport: AIHTTPTransport` —
    `init(byteLimit: Int = AILimits.maxResponseBytes, configuration: URLSessionConfiguration = .ephemeral)`;
    sets `httpCookieStorage = nil`, `urlCache = nil`, `httpShouldSetCookies = false`, the two
    timeouts; streams with `bytes(for:)` and throws `.responseTooLarge` the moment the count passes
    the limit (never trusts `expectedContentLength`); maps `URLError` (`.timedOut` → `.timedOut`;
    `.notConnectedToInternet`, `.cannotConnectToHost`, `.cannotFindHost`, `.networkConnectionLost`
    → `.offline`; `.cancelled` / `CancellationError` → `.cancelled`).
  - `struct AnthropicMessagesClient: AIClient` — `init(connection: AIConnection, transport: AIHTTPTransport)`.
    POST, headers `x-api-key`, `anthropic-version: 2026-10-21`, `content-type: application/json`;
    body `{"model","max_tokens":16000,"system","messages":[{"role":"user","content":<user>}],"output_config":{"effort":"low"}}`
    (no `thinking`, no `temperature`). Reply: `stop_reason == "refusal"` → `.refused`;
    `"max_tokens"` → `.unusableResponse`; else the `text` of every `content` block whose `type` is
    `"text"`, joined; other block types ignored.
  - `struct OpenAICompatibleClient: AIClient` — same init. Header `Authorization: Bearer <key>`
    only when the key is non-empty; body `{"model","messages":[{"role":"system",…},{"role":"user",…}]}`.
    Reply: `choices[0].message.content` (String); `finish_reason == "length"` →
    `.unusableResponse`, `"content_filter"` → `.refused`.
  - Both: status 401/403 → `.unauthorized`, 404 → `.modelNotFound`, 429 → `.rateLimited`, other
    non-2xx → `.server(status:)`; undecodable JSON → `.unusableResponse`.
  - `enum AIClientFactory { static func client(for connection: AIConnection, transport: AIHTTPTransport = URLSessionAITransport()) -> AIClient }`
  - Test doubles: `final class FakeAITransport: AIHTTPTransport` (records `requests`, returns a
    scripted `(status, body)`), `final class StubURLProtocol: URLProtocol` (serves a scripted body
    to a session built with `configuration.protocolClasses = [StubURLProtocol.self]`).

`scripts/ai-stub-server.py` (Python 3 stdlib, `http.server`, no dependencies): serves
`POST /v1/chat/completions` and `/chat/completions` on `127.0.0.1:<--port, default 8765>` in the
OpenAI shape. It reads the last user message as JSON (Task 5's payload) and answers
deterministically: `trim` removes the words "very", "really", "just", "quite"; `cutInHalf` keeps
the first ⌈n/2⌉ words of each segment; `rewrite` replaces "good"→"fine" and "big"→"large";
`proofread` replaces "teh"→"the" and " ,"→","; `weakestSentences` returns `[1]`; `longSentences`
returns the 1-based index of the sentence with the most words. Flags: `--mangle` (adds `**`, `#`,
`` ` ``, `|`, `\*`, a `\n` and `[x](y)` into every segment), `--delay SECONDS`, `--status CODE`,
`--junk` (replies `"Sure! Here you go."`). Prints one line per request: action and segment count,
never the text.

- [ ] **Step 1: Write the failing tests**

```swift
func testAnthropicRequestShape()              // URL, POST, x-api-key, anthropic-version == "2026-10-21", no Authorization; body model/max_tokens 16000/system/1 user message
func testAnthropicJoinsTextBlocksAndIgnoresThinking()  // content [thinking, text "a", text "b"] → "ab"
func testAnthropicRefusalStopReason()          // → .refused
func testOpenAICompatibleRequestShapeForEachProvider() // chatGPT + google URLs and "Bearer k"; .other with nil key → no Authorization header
func testOpenAICompatibleParsesFirstChoice()
func testStatusCodesMapToErrors()              // 401,403 → .unauthorized; 404 → .modelNotFound; 429 → .rateLimited; 500 → .server(status: 500)
func testTransportAbortsPastByteLimit()        // StubURLProtocol body of limit+1 bytes, byteLimit 1024 → .responseTooLarge
func testTransportSendsNoCookies()             // request built has no Cookie header; configuration.httpCookieStorage == nil
```

- [ ] **Step 2: Run to verify they fail** (`-only-testing:LineformTests/AIClientTests` + gates).
  Expected: build failure.
- [ ] **Step 3: Implement** the clients, transport, factory, doubles and the stub script
  (`chmod +x`).
- [ ] **Step 4: Run to verify they pass.** Expected: 8 tests, 0 failures. Then check the stub:
  `python3 scripts/ai-stub-server.py --port 8765 &` and
  `curl -s localhost:8765/v1/chat/completions -d '{"model":"x","messages":[{"role":"user","content":"{\"action\":\"trim\",\"segments\":[\"a very good day\"]}"}]}'`
  Expected: `choices[0].message.content` decodes to `{"segments":["a good day"]}`. Stop the server.
- [ ] **Step 5: Commit** — `git commit -m "Add AI HTTP clients and local stub server"`.

---

### Task 3: Connect Your AI window

**Files:**
- Create: `Lineform/AI/ConnectAIView.swift`, `Lineform/AI/ConnectAIPresentation.swift`,
  `Lineform/AI/ConnectAIWindowController.swift`
- Modify: `Lineform/App/AppCommands.swift` (`CommandGroup(replacing: .appInfo)` :418 — after
  Settings…; `AppMenuConfiguration.allEnglishTitleKeys` :145), `Lineform/App/MainMenuIconDecorator.swift`
  (icon table ~:401), `Lineform/Localizable.xcstrings`, pbxproj
- Test: `LineformTests/ConnectAIPresentationTests.swift`; existing `MainMenuIconDecoratorTests`

**Interfaces:**
- Consumes: `AIConnectionStore`, `AIProvider`, `AIConnectError` (Task 1).
- Produces:
  - `enum ConnectAIPresentation` (all `String(localized:)`): `windowTitle = "Connect Your AI"`;
    `createKeyTitle = "Create an API key"`; `keyLabel = "API key"`; `addressLabel = "Address"`;
    `optionalKeyLabel = "API key (optional)"`; `optionalModelLabel = "Model (optional)"`;
    `connectedText = "Connected"`; `disconnectTitle = "Disconnect"`; `doneTitle = "Done"`;
    `privacyNote = "Lineform sends only the text you act on, only when you choose an AI action, directly to the provider you connected, under your account and that provider's terms. Lineform's developer receives nothing."`;
    `static func billingNote(for provider: AIProvider) -> String` — Claude: "A Claude Pro or Max
    subscription doesn't cover this. API keys are billed per use by Anthropic."; ChatGPT: "A ChatGPT
    Plus or Pro subscription doesn't cover this. API keys are billed per use by OpenAI."; Google:
    "A Gemini subscription doesn't cover this. API keys are billed per use by Google."; Other: "Use a
    model on this Mac — Ollama, LM Studio, llama.cpp — or any OpenAI-compatible server.";
    `static func connectButtonTitle(for provider: AIProvider, otherHost: String?) -> String` —
    "Connect — Lineform will send the text you choose to %@" with the company name, the Other host,
    or (no host yet) "Connect — Lineform will send the text you choose to that address".
  - `AppMenuConfiguration.connectAICommandTitle = String(localized: "Connect Your AI…")`.
  - `@MainActor final class ConnectAIWindowController: NSWindowController` — `static let shared`,
    `func show()`. One window, created on first `show()`: `[.titled, .closable]`, content
    680×460, `isRestorable = false`, `isReleasedWhenClosed = false`, centred on first show, title
    `ConnectAIPresentation.windowTitle`, content `NSHostingController(rootView: ConnectAIView(store: .shared, onDone: close))`.
  - `struct ConnectAIView: View` — `init(store: AIConnectionStore, onDone: @escaping () -> Void)`.

Layout (Luz's `ConnectAIView` as the visual reference, without logos — rows are text only, no
brand marks bundled): header "Connect Your AI" 24pt semibold; left list 180pt — Claude, ChatGPT,
Google, Other — the connected one with a `checkmark.circle.fill` labelled "Connected"; right pane
for the selected provider: the billing note, a `Link` "Create an API key" (big three), a
`SecureField` key, the privacy note (secondary, 12pt), and a `.borderedProminent` button titled
`connectButtonTitle(...)` — this button is the consent step. Other shows Address, API key
(optional), Model (optional). An `AIConnectError` shows inline under the field. When the selected
provider is connected: "Connected" plus Disconnect instead of the field. Footer: Done (default
button). Opening the window makes no network request and reads no Keychain item.

- [ ] **Step 1: Write the failing tests**

```swift
func testConnectButtonNamesWhatIsSentAndToWhom() {
    XCTAssertTrue(ConnectAIPresentation.connectButtonTitle(for: .claude, otherHost: nil).contains("Anthropic"))
    XCTAssertTrue(ConnectAIPresentation.connectButtonTitle(for: .chatGPT, otherHost: nil).contains("OpenAI"))
    XCTAssertTrue(ConnectAIPresentation.connectButtonTitle(for: .google, otherHost: nil).contains("Google"))
    XCTAssertTrue(ConnectAIPresentation.connectButtonTitle(for: .other, otherHost: "localhost").contains("localhost"))
    XCTAssertTrue(ConnectAIPresentation.connectButtonTitle(for: .claude, otherHost: nil).contains("text you choose"))
}
func testBillingNoteSaysSubscriptionDoesNotCoverIt()   // big three each contain "doesn't cover"
func testCopyIsTranslatedInEveryLanguage()             // via Bundle(path: "<lang>.lproj") for es/fr/de/ja/zh-Hans: windowTitle and privacyNote differ from English
func testEveryProviderHasEndpointModelAndKeyPage()     // big three non-nil; .other nil
```
  `MainMenuIconDecoratorTests.testConfiguredCommandTitlesAllHaveIcons` covers the new row once it
  is in `allEnglishTitleKeys`.

- [ ] **Step 2: Run to verify they fail** (`-only-testing:` `ConnectAIPresentationTests`,
  `MainMenuIconDecoratorTests`, both gates). Expected: build failure.
- [ ] **Step 3: Implement** the view, presentation, window controller, the menu button
  (`ConnectAIWindowController.shared.show()`), `"Connect Your AI…"` in `allEnglishTitleKeys`, icon
  `"connect your ai": "sparkles"` in the decorator, and all translations (keep the German connect
  label short enough for one line at 680pt).
- [ ] **Step 4: Run to verify they pass**; then `xcodebuild build …`. Manual: launch the fresh
  build (`open -a "$BUILT_PRODUCTS_DIR/Lineform.app"`), open Lineform ▸ Connect Your AI…, connect
  Claude with a dummy key, relaunch, confirm it shows Connected, Disconnect, confirm the key is gone
  (`security find-generic-password -s com.lineform.app.debug.ai` finds nothing). Watch
  `nettop -p Lineform` throughout: no connections.
- [ ] **Step 5: Commit** — `git commit -m "Add Connect Your AI window"`.

---

### Task 4: Markdown structure map and guard

**Files:**
- Create: `Lineform/Editor/MarkdownStructureMap.swift`
- Modify: `Lineform/Editor/MarkdownRangeAnalyzer.swift:3` (`MarkdownTokenKind` gains
  `CaseIterable`), `Lineform/Preview/MarkdownInlineSyntax.swift` (`escapedMarker` private →
  internal; no behaviour change), pbxproj
- Test: `LineformTests/MarkdownStructureMapTests.swift`, `LineformTests/MarkdownStructureInventoryTests.swift`

**Interfaces:**
- Produces:
  - `struct ProseSegment: Equatable { let range: NSRange; let text: String }` — document UTF-16
    coordinates; `text` has no leading/trailing whitespace (edge whitespace stays in the document).
  - `enum MarkdownStructureMap`
    - `static func structureRanges(in text: NSString, scope: NSRange) -> [NSRange]` — sorted,
      coalesced; covers every non-prose unit of the lines touching `scope`.
    - `static func proseSegments(in text: String, selection: NSRange) -> [ProseSegment]` —
      selection minus structure, split at line boundaries, edge-trimmed, empties dropped.
    - `static func signature(of text: NSString, scope: NSRange) -> [String]` — the structure
      substrings in order.
    - `enum TokenProtection { case structure, prose }`;
      `static func protection(of kind: MarkdownTokenKind) -> TokenProtection` — exhaustive switch,
      no `default`; only `.linkText` is `.prose` (`.imageText` is structure: alt text is left alone).
    - `enum BlockProtection { case whole, markersOnly }`;
      `static func protection(of block: MarkdownBlock) -> BlockProtection` — exhaustive switch:
      `.lines`, `.blockquote`, `.callout`, `.list`, `.table` → `.markersOnly`; every other case → `.whole`.
  - `enum MarkdownStructureGuard`
    - `static func admissibleRevisions(_ revisions: [String], for segments: [ProseSegment], in text: String) -> [String?]`
      — nil for a revision that is empty after trimming, contains a line terminator or `Cc`
      character, is longer than `2 × original + 200` UTF-16 units, or changes `signature` of its
      block (the contiguous non-blank lines around it) when spliced in together with the revisions
      already admitted on that block.
    - `static func verify(original: String, revised: String) -> Bool` — whole-document
      `signature` equality.

Structure = the union of (each from the existing definition named):
1. `MarkdownWritingToolsProtection.protectedRanges(in:intersecting:)` — front matter, fenced code
   (any language, incl. mermaid and its front matter), display and inline math with `$…$`,
   `$$…$$`, `\(…\)`, `\[…\]`.
2. `MarkdownSyntaxHighlighter.tokens(in:scope:)` kinds whose `protection(of:)` is `.structure`
   (heading/list/checkbox/blockquote markers, code spans, code fences, link destinations, image
   text and destinations).
3. `MarkdownInlineSyntax`: every `image` match whole; every `link` match minus group 1; every
   `bold`, `italic`, `italicAsterisk`, `strikethrough` match minus group 1; every `code` match;
   every `escapedMarker` match.
4. Line level (lines from `markdownSourceLines`): the line terminator and a line-0 BOM; leading
   indentation; trailing whitespace and a trailing `\` (hard breaks); blank lines; horizontal
   rules (`MarkdownHorizontalRule.isRule(lines:index:)`); setext underlines (a line of only `=` or
   only `-` under a non-blank paragraph line).
5. Blocks from `markdownBlocks(in:lineRanges:)`: `.whole` blocks entirely; in `.table` blocks the
   delimiter row entirely and, in other rows, every unescaped `|` with the whitespace touching it;
   in `.callout` the `[!KIND]` token (`MarkdownCallout`'s pattern).
6. Not rendered by Lineform today but listed in spec §4.2, defined ONCE here: raw HTML tags
   `</?[A-Za-z][A-Za-z0-9-]*(\s[^<>\n]*)?/?>` and comments `<!--[^\n]*?-->`; footnote markers
   `\[\^[^\]\s]+\]:?`.

- [ ] **Step 1: Write the failing tests** (segment texts listed are `proseSegments(…).map(\.text)`
  for the whole text selected):

```swift
func testHeadingMarkerIsStructure()          // "## Section title\n" → ["Section title"]
func testListTaskAndNestedIndentation()      // "- [ ] Buy milk\n  1. Nested item\n" → ["Buy milk", "Nested item"]
func testBlockquoteAndCallout()              // "> [!NOTE] Heads up\n> Body text\n" → ["Heads up", "Body text"]
func testEmphasisDelimitersAreStructure()    // "This is **very** good" → ["This is", "very", "good"]
func testLinkTextIsProseDestinationIsNot()   // "See [the docs](https://x.y \"T\") now" → ["See", "the docs", "now"]
func testImageIsWhollyStructure()            // "![Alt text](img.png) after" → ["after"]
func testInlineCodeAndAllMathAreStructure()  // "Use `x` and $a^2$ or \\(b^2\\) here" → ["Use", "and", "or", "here"]
func testBlocksAreNeverSent()                // front matter, ``` code, ```mermaid, $$ block, \[ … \] block, then "Prose." → ["Prose."]
func testTableCellsAreProsePipesAreNot()     // "| A | B |\n|---|:-:|\n| one | two |\n" → ["A", "B", "one", "two"]
func testEscapesHardBreaksHTMLFootnotes()    // "Keep \\* this  \nNext<br>line[^1]\n" → ["Keep", "this", "Next", "line"]
func testRuleAndSetextUnderline()            // "Title\n===\n\n---\n\nText" → ["Title", "Text"]
func testCRLFAndBOM()                        // "\u{FEFF}# Title\r\nBody line\r\n" → ["Title", "Body line"], exact NSRanges; signature contains "\u{FEFF}" and "\r\n"
func testScopedStructureMatchesWholeDocument() // structureRanges(scope: line k) == whole-document ranges ∩ line k, for every line of the fixture
func testGuardAdmitsProseOnlyRevision()      // "This is" → "This was" admitted
func testGuardDropsRevisionThatAddsStructure() // each of "**x**", "# x", "`x`", "x | y" (in a table cell), "\\*x", "[a](b)", "$x$" → nil
func testGuardDropsLineBreaksControlCharactersAndRunaways() // "a\nb", "a\u{2028}b", "a\u{7}b", 10× length → nil
func testVerifyDetectsChangedStructure()     // verify("# A", "## A") == false; verify("# A", "# B") == true
// MarkdownStructureInventoryTests
func testEveryTokenKindIsClassified()        // for kind in MarkdownTokenKind.allCases: protection(of:) — only .linkText is .prose
func testEveryBlockKindIsClassified()        // one fixture producing each MarkdownBlock case via markdownBlocks; protection(of:) as listed
```

- [ ] **Step 2: Run to verify they fail** (`-only-testing:` both classes,
  `MarkdownSpellCheckPerformanceTests`, `LineformTextViewWritingToolsTests`, both gates).
  Expected: build failure.
- [ ] **Step 3: Implement** `MarkdownStructureMap` and `MarkdownStructureGuard`. Split lines only
  with `markdownSourceLines(in:)`; never `CharacterSet.newlines`. Do not change any existing
  definition's behaviour — this file only composes them. The exhaustive switches are the
  "new construct without a rule fails" gate: a new `MarkdownTokenKind` or `MarkdownBlock` case
  stops the build here.
- [ ] **Step 4: Run to verify they pass.** Expected: all pass, the perf test and Writing Tools
  tests unchanged.
- [ ] **Step 5: Commit** — `git commit -m "Add Markdown structure map and guard for AI edits"`.

---

### Task 5: Action prompts, reply parsing, and changes

**Files:**
- Create: `Lineform/AI/AIAction.swift`, `Lineform/AI/AIActionPrompt.swift`,
  `Lineform/AI/AIResponseParser.swift`, `Lineform/AI/AIChangeBuilder.swift`,
  `Lineform/AI/AISentenceSplitter.swift`
- Modify: pbxproj, `Lineform/Localizable.xcstrings`
- Test: `LineformTests/AIActionPromptTests.swift`, `LineformTests/AIResponseParserTests.swift`,
  `LineformTests/AIChangeBuilderTests.swift`

**Interfaces:**
- Consumes: `AIPrompt` (Task 2), `ProseSegment`, `MarkdownStructureMap`, `MarkdownStructureGuard` (Task 4).
- Produces:
  - `enum AIAction: String, CaseIterable { case trim, cutInHalf, rewrite, proofread, markWeakest = "weakestSentences", markLong = "longSentences" }`
    — `var title: String` localized ("Trim", "Cut in half", "Rewrite", "Proofread", "Weakest
    sentences", "Long sentences"); `var isMark: Bool`; `var progressVerb: String` ("Trimming…",
    "Cutting…", "Rewriting…", "Proofreading…", "Marking…").
  - `enum AIActionPrompt`
    - `static func editPrompt(_ action: AIAction, segments: [String]) -> AIPrompt` — user =
      `{"action":<rawValue>,"segments":[…]}` (JSONSerialization, sorted keys).
    - `static func markPrompt(_ action: AIAction, sentences: [String]) -> AIPrompt` — user =
      `{"action":<rawValue>,"sentences":[…]}`.
    - System text (exact): edit — "You edit prose for a writer. The user message is JSON with an
      action and a list of segments: consecutive pieces of one passage. Markdown formatting between
      segments was removed and will be restored by the app. Reply with JSON only, in the form
      {\"segments\": [...]}, with exactly the same number of strings in the same order. Never add
      Markdown, line breaks, quotes around the passage, or commentary. Keep the writer's language
      and voice." followed by one line per action — trim: "Remove needless words. Keep the meaning.
      Change as little as possible."; cutInHalf: "Make the passage about half as long. Keep the
      most important points."; rewrite: "Rewrite for clarity and flow. Keep the meaning and about
      the same length."; proofread: "Fix only spelling, typos, grammar slips and prose punctuation.
      Change nothing else." Mark — "You review prose for a writer. The user message is JSON with an
      action and a numbered list of sentences (the first is 1). Reply with JSON only, in the form
      {\"sentences\": [numbers]}. Choose at most a third of them." plus weakest: "Choose the
      weakest sentences: vague, flat or unclear."; long: "Choose sentences too long to read
      comfortably."
  - `enum AIResponseParser`
    - `static func segments(from reply: String, expectedCount: Int) -> [String]?` — takes the
      text from the first `{` to the last `}` (tolerates fences and preambles), decodes with
      `JSONSerialization`; nil unless `segments` is an array of exactly `expectedCount` strings.
    - `static func sentenceIndices(from reply: String, sentenceCount: Int) -> [Int]?` — 1-based in,
      0-based out, deduped, sorted, in range, capped at `max(1, ⌈sentenceCount / 3⌉)` (first ones
      kept); nil when not decodable.
  - `struct AIChange: Equatable, Identifiable { let id: Int; var range: NSRange; let original: String; let replacement: String }`
  - `enum AIChangeBuilder { static func changes(segments: [ProseSegment], revisions: [String?], in text: String) -> [AIChange] }`
    — word-level diff per segment; tokens are letter/number runs (an apostrophe between letters
    stays in the word), whitespace runs, and single other Characters; LCS over tokens, falling back
    to one whole-segment change when `n × m > 4_000_000`; consecutive differing tokens form one
    change; two changes separated only by whitespace tokens merge; ids sequential in document
    order; nil revision → no changes.
  - `struct AISentence: Equatable { let range: NSRange; let prose: String }`;
    `enum AISentenceSplitter { static func sentences(in text: String, selection: NSRange) -> [AISentence] }`
    — `enumerateSubstrings(.bySentences)` over each non-blank block's full lines inside the
    selection; `prose` = the sentence's prose segments joined with one space; sentences with empty
    prose skipped; `range` edge-trimmed.

- [ ] **Step 1: Write the failing tests**

```swift
// AIActionPromptTests
func testEditPromptCarriesActionAndSegmentsAsJSON()   // decode user → ["action": "trim", "segments": ["a", "b"]]
func testMarkPromptNumbersNothingItself()             // sentences array passed through; system contains "the first is 1"
func testEveryActionHasLocalizedTitle()               // titles resolve via catalog for es/fr/de/ja/zh-Hans
// AIResponseParserTests
func testParsesPlainJSON()
func testParsesFencedJSONWithPreamble()               // "Sure!\n```json\n{\"segments\":[\"x\"]}\n```" → ["x"]
func testUnusableRepliesAreRefused()                  // "", "Sure! Here you go.", "{}", "{\"segments\":\"x\"}", "{\"segments\":[1]}", count 2 vs 1 → nil
func testSentenceIndicesAreBoundedAndCapped()         // "{\"sentences\":[0,2,2,99,1]}", count 6 → [0, 1]
// AIChangeBuilderTests
func testSingleWordReplacement()                      // "The quick brown fox" → "The fast brown fox": one change, original "quick", replacement "fast"
func testDeletionIsOneChange()                        // "really very good" → "good": one change, original "really very ", replacement ""
func testChangesSeparatedByWhitespaceMerge()          // "big red car" → "small blue car": one change "big red" → "small blue"
func testChangesUseDocumentRangesAcrossSegments()     // "## Good title\n\nA good day" with "good"→"fine" in both → two changes at the right document offsets
func testChangesNeverSplitComposedCharacters()        // "café 👍🏽 ok" → "cafe 👍🏽 okay": every change.range == rangeOfComposedCharacterSequences(for: change.range)
func testIdenticalRevisionProducesNoChanges()
func testDroppedRevisionProducesNoChanges()           // revisions [nil]
func testSentencesSpanEmphasis()                      // "This is **very** good. Next one." → 2 sentences; first prose "This is very good."
```

- [ ] **Step 2: Run to verify they fail** (the three classes + gates). Expected: build failure.
- [ ] **Step 3: Implement** the five files and translations.
- [ ] **Step 4: Run to verify they pass.** Expected: all pass.
- [ ] **Step 5: Commit** — `git commit -m "Add AI action prompts, reply parsing and change diff"`.

---

### Task 6: Action controller and review session

**Files:**
- Create: `Lineform/AI/AIReviewSession.swift`, `Lineform/AI/AIActionController.swift`
- Modify: `Lineform/Documents/DocumentHistoryEngine.swift` (add `isInsideWordPassage`),
  `Lineform/Editor/DocumentHistoryController.swift` (add `allowsAIAction`), pbxproj,
  `Lineform/Localizable.xcstrings`
- Test: `LineformTests/AIReviewSessionTests.swift`, `LineformTests/AIActionControllerTests.swift`,
  `LineformTests/DocumentHistoryEngineTests.swift` (one test); extend `AITestDoubles.swift`

**Interfaces:**
- Consumes: Tasks 1, 2, 4, 5; `DocumentHistoryController.recordAccepted(range:original:accepted:text:)`,
  `isHistoryModeActive`.
- Produces:
  - `DocumentHistoryEngine.isInsideWordPassage(_ range: NSRange) -> Bool` (live ranges of `.word`
    passages containing `range`); `DocumentHistoryController.allowsAIAction(on range: NSRange) -> Bool`
    — false in History mode or inside a word passage.
  - `struct AIReviewEdit: Equatable { let range: NSRange; let replacement: String }`
  - `enum AIDecision: Equatable { case accepted, rejected }`
  - `struct AIReviewSession: Equatable`
    - `init(action: AIAction, changes: [AIChange], selectionRange: NSRange, originalSelection: String)`
    - `private(set) var changes: [AIChange]` (ranges always in CURRENT document coordinates),
      `decisions: [Int: AIDecision]`, `keptOriginals: Set<Int>`, `currentID: Int?`,
      `selectionRange: NSRange`; `let action`, `let originalSelection`
    - `var pending: [AIChange]`, `var hasDecided: Bool`, `var isFinished: Bool`,
      `var acceptedAny: Bool`, `var position: (current: Int, total: Int)` (1-based among all)
    - `mutating func accept(_ id: Int) -> AIReviewEdit?` — returns the edit; shifts later
      changes and `selectionRange` by the length delta.
    - `mutating func reject(_ id: Int)`, `mutating func toggleKeep(_ id: Int)`
    - `mutating func acceptRemaining() -> [AIReviewEdit]` — in DESCENDING location order.
    - `mutating func rejectRemaining()`, `mutating func move(by delta: Int)` (pending only, wraps)
    - A kept change's edit replacement is `original + separator + replacement`, separator `" "`
      when both are non-empty and neither touching character is whitespace, else `""`. A kept pure
      deletion yields no edit.
  - `enum AIReviewCommand: Equatable { case accept(Int), reject(Int), toggleKeep(Int), acceptCurrent, next, previous, acceptRemaining, rejectRemaining, end, typed(String) }`
  - `@MainActor protocol AIEditorSurface: AnyObject { var string: String { get }; func applyAIEdits(_ edits: [AIReviewEdit], actionName: String); func insertTypedText(_ text: String); func announceAI(_ message: String) }`
  - `@MainActor final class AIActionController: ObservableObject`
    - `init(connectionStore: AIConnectionStore, clientFactory: @escaping (AIConnection) -> AIClient = { AIClientFactory.client(for: $0) })`
    - `enum State: Equatable { case idle, running(AIAction, AIProvider), reviewing(AIReviewSession), marking([NSRange]), message(String) }`
    - `@Published private(set) var state: State`; `weak var editor: AIEditorSurface?`;
      `weak var history: DocumentHistoryController?`; `private(set) var runTask: Task<Void, Never>?`
    - `func isAvailable(for range: NSRange, text: String) -> Bool` — connected, non-empty range,
      not running/reviewing, `history?.allowsAIAction(on:) != false`, ≥ 1 prose segment.
    - `func run(_ action: AIAction, range: NSRange, text: String)`
    - `func cancel()`, `func handle(_ command: AIReviewCommand)`, `func dismissMarks()`,
      `func dismissMessage()`
    - `func endReview()` — undecided changes rejected; records History if anything was accepted.
    - `func abandon()` — reload wins: cancels, drops review/marks, records nothing.

Behaviour:
- `run` builds segments (`proseSegments`) or sentences (`AISentenceSplitter`); over
  `AILimits.maxProseUTF16`/`maxSegments` → `.message("Select less text — about 4,000 words at most.")`
  with no request; `resolvedConnection() == nil` → `.message("Connect your AI again in Lineform ▸ Connect Your AI….")`.
  It snapshots `text`; on reply, `editor.string != snapshot` → `.message("The text changed while
  Lineform was waiting. Nothing was changed.")`.
- Edit reply → `AIResponseParser.segments` → `MarkdownStructureGuard.admissibleRevisions` →
  `AIChangeBuilder.changes`; the composed text must pass `MarkdownStructureGuard.verify` or
  `.message(AIClientError.unusableResponse.message)`; no changes → `.message("No changes suggested.")`.
  Mark reply → `.marking(ranges)`; empty → `.message("Nothing to mark.")`.
- Accept/reject apply through `editor.applyAIEdits` (one call per decision; Accept Remaining is ONE
  call with all edits = one undo step; action name "Accept Suggestion" / "Accept Suggestions").
  When the session finishes, `endReview` runs `history?.recordAccepted(range: session.selectionRange,
  original: session.originalSelection, accepted: <substring at selectionRange>, text: editor.string)`
  once, only if `acceptedAny`.
- `.typed(s)` → `endReview()`, then `editor.insertTypedText(s)`. Errors from the client become
  `.message(error.message)`; `.cancelled` → `.idle`. Announce state changes through `announceAI`
  ("3 changes suggested", "Change 2 of 3", "Review ended").

- [ ] **Step 1: Write the failing tests** (`FakeAIClient` returns scripted replies or suspends until
  cancelled and records prompts; `FakeAIEditorSurface` holds `string`, applies and records edits;
  History via `DocumentHistoryController(store: NullPassageHistoryStore())`):

```swift
// AIReviewSessionTests
func testAcceptShiftsLaterChangesAndSelection()
func testKeepingDimmedTextKeepsOriginalAndInsertion()   // "big"→"large" kept → edit replacement "big large"
func testAcceptRemainingReturnsDescendingEdits()
func testHasDecidedAfterFirstDecision()                 // false, then true after reject(0)
func testMoveWrapsOverPendingOnly()
// AIActionControllerTests
func testNoRequestWhenDisconnected()                    // isAvailable == false; run → factory never called
func testRunProducesReviewWithChanges()
func testAcceptingOneOfTwoIdenticalChangesEditsOnlyThatOne() // "It works. It works." both → "It runs." ; accept(1) → "It works. It runs."
func testAcceptRemainingIsOneEditCall()                 // surface.editCalls.count == 1 with 3 edits
func testEscapeEndsReviewLeavingTextUnchanged()         // .end with nothing accepted → string unchanged, no edit calls
func testOneActionRecordsOneHistoryPassage()            // 2 of 3 accepted → one passage, versions [original, accepted], authors [.you, .ai]
func testNothingAcceptedRecordsNoHistory()              // hasHistory == false
func testResponseDiscardedWhenTextChangedWhileRunning() // mutate surface.string before the fake replies → state .message, no edits
func testCancelStopsTheRequest()                        // suspended fake; cancel() → .idle; fake observed cancellation
func testMarkHighlightsWithoutChangingText()            // .marking(ranges of sentence 1); no edit calls
func testOversizedSelectionIsRefusedWithoutARequest()
func testMangledStructureNeverReachesTheDocument()      // fixture: front matter, headings, nested list, tasks, table, link, image, code span, fence, mermaid, $…$, $$, \(…\), \[…\], callout, CRLF, BOM; fake inserts "**", "#", "\n", "|", "`", "\\*", "[x](y)" into every segment; acceptRemaining → MarkdownStructureMap.signature(whole) unchanged, "\r\n" count unchanged, BOM first
func testHonestEditsApplyAndKeepStructure()             // same fixture, prose-only edits → text changed, signature unchanged
func testAbandonOnReloadAppliesNothingAndRecordsNoHistory()
func testNotAvailableInsideWordPassageOrHistoryMode()
// DocumentHistoryEngineTests
func testInsideWordPassageDetection()
```

- [ ] **Step 2: Run to verify they fail** (the three classes + gates). Expected: build failure.
- [ ] **Step 3: Implement** the session, controller, the two History hooks and the strings.
- [ ] **Step 4: Run to verify they pass**, plus `DocumentHistoryControllerTests`. Expected: all pass.
- [ ] **Step 5: Commit** — `git commit -m "Add AI action controller and review session"`.

---

### Task 7: AI in the text view

**Files:**
- Create: `Lineform/Editor/LineformTextView+AI.swift`
- Modify: `Lineform/Editor/LineformTextView.swift` — stored properties (near :114-133),
  `doCommand(by:)` (:271), `shouldChangeText(in:replacementString:)` (:284), `applyTypography`
  (re-ink marks on theme change, :349), `menu(for:)` (:815), `LineformTextContextMenuPresentation`
  (:2001); `Lineform/Editor/MarkdownTextViewRepresentable.swift` — `makeNSView` (:38) /
  `updateNSView` (:75) push handlers and marks like `historyDisplay`; pbxproj; strings
- Test: `LineformTests/LineformTextViewAITests.swift`

**Interfaces:**
- Consumes: `AIAction`, `AIReviewEdit`, `AIEditorSurface`, `AIActionController` (Task 6),
  `HistoryPalette.tint(for:)`.
- Produces on `LineformTextView`:
  - `var aiAvailabilityHandler: ((NSRange) -> Bool)?`, `var aiCommandHandler: ((AITextCommand) -> Void)?`
  - `var aiMarkRanges: [NSRange]` (setting an equal value is a no-op), `var isAIRequestRunning: Bool`,
    `var isAIReviewActive: Bool`; storage `var isApplyingAIEdit = false`
  - `enum AITextCommand: Equatable { case run(AIAction, NSRange), cancel, dismissMarks }`
  - `extension LineformTextView: AIEditorSurface` — `applyAIEdits(_:actionName:)` inside
    `performAIEdit {}`, one `beginUndoGrouping`/`endUndoGrouping`, each edit (descending) through
    `shouldChangeText` → `textStorage.replaceCharacters` → `didChangeText`, then
    `undoManager?.setActionName(actionName)`; `insertTypedText` makes itself first responder and
    `insertText(_:replacementRange:)` at the selection; `announceAI` posts `.announcementRequested`.
  - `LineformTextContextMenuPresentation.aiRewriteMenuTitle = String(localized: "Rewrite")`,
    `aiMarkMenuTitle = String(localized: "Mark")` (conditional rows, so not in `commandTitles(for:)`).
  - `MarkdownTextViewRepresentable` init gains `aiController: AIActionController? = nil`; it sets
    `aiController.editor = textView`, the two handlers, and from `state`: `aiMarkRanges`
    (`.marking`), `isAIRequestRunning` (`.running`), `isAIReviewActive` (`.reviewing`).

Behaviour:
- Context menu: after Paste and the History item, when `aiAvailabilityHandler?(selectedRange()) == true`:
  separator; submenu "Rewrite" ▸ Trim · Cut in half · Rewrite; "Proofread"; submenu "Mark" ▸
  Weakest sentences · Long sentences. Items carry the `AIAction` as `representedObject`, action
  `runAIAction(_:)`; submenus carry `MainMenuIconDecorator.excludedMenuIdentifier`. Absent (not
  disabled) otherwise.
- `doCommand`: after History's handling, `cancelOperation:` → `.cancel` while running, else
  `.dismissMarks` while marks are shown.
- `shouldChangeText`: while `isAIReviewActive && !isApplyingAIEdit` refuse (backstop — the review
  overlay holds focus); while marks are shown, a real edit (`replacementString != nil`) sends
  `.dismissMarks` and proceeds.
- Marks: layout-manager TEMPORARY `.backgroundColor` = `HistoryPalette.tint(for:)`; text storage
  never touched; cleared when empty.

- [ ] **Step 1: Write the failing tests** (`LineformTextView()` without a window; an undo test
  delegate returning one `UndoManager`):

```swift
func testContextMenuHasNoAIItemsWhenDisconnected()   // handler nil or false → no "Proofread", no "Mark"
func testContextMenuOffersAIGroupForSelection()      // "Rewrite" submenu == ["Trim", "Cut in half", "Rewrite"], "Proofread", "Mark" submenu == ["Weakest sentences", "Long sentences"]
func testNoAIItemsForEmptySelection()
func testChoosingAnItemSendsRun()                    // .run(.trim, selectedRange)
func testEscapeCancelsRunningRequest()               // isAIRequestRunning; doCommand(cancelOperation:) → .cancel
func testApplyAIEditsIsOneUndoStep()                 // two edits, one undo → original text
func testApplyAIEditsPreservesCRLFAndBOM()
func testUserEditsRefusedDuringReview()              // isAIReviewActive; insertText("x") → text unchanged
func testMarksAreTemporaryAttributesOnly()           // textStorage attributes unchanged; temp .backgroundColor present; cleared on []
func testTypingDismissesMarks()                      // insertText("a") → handler got .dismissMarks; text contains "a"
```

- [ ] **Step 2: Run to verify they fail** (`LineformTextViewAITests`,
  `LineformTextViewWritingToolsTests`, `LineformTextViewHistoryTests`, gates). Expected: build failure.
- [ ] **Step 3: Implement.** Keep `keyDown` untouched; reuse `LineformTextView`'s existing
  composed-character alignment before each replace.
- [ ] **Step 4: Run to verify they pass.** Expected: all pass, existing context-menu and History
  tests unchanged.
- [ ] **Step 5: Commit** — `git commit -m "Add AI actions and marks to the text view"`.

---

### Task 8: Review overlay, cards, and editor wiring

**Files:**
- Create: `Lineform/AI/AIReviewComposition.swift`, `Lineform/AI/AIReviewTextView.swift`,
  `Lineform/AI/AIReviewPillCell.swift`, `Lineform/AI/AIReviewSurfaceRepresentable.swift`,
  `Lineform/AI/AIReviewCards.swift`
- Modify: `Lineform/Editor/EditorContainerView.swift` — `@StateObject` beside `historyController`
  (:77), `markdownEditor(...)` (:1339, pass `aiController`, overlay the review surface),
  `editorPrimaryShell` (:968, card overlay `.bottom`), `applyReload` (:2241 → `abandon()`),
  `resetTransientDocumentState` (:2448 → `endReview()` BEFORE `historyController.close`), the two
  `noteWholeTextReplacement()` writers (:1100, :1120 → `abandon()`), display-mode change (:402 →
  `endReview()`), History enter (:2425 → `endReview()` first); `Lineform/Info.plist` only if Step 5
  requires it; pbxproj; strings
- Test: `LineformTests/AIReviewCompositionTests.swift`, `LineformTests/AIReviewPillCellTests.swift`,
  `LineformTests/AIReviewCardPresentationTests.swift`, `LineformTests/ReleaseResourceTests.swift` (one test)

**Interfaces:**
- Consumes: `AIReviewSession`, `AIReviewCommand`, `AIActionController.State` (Task 6), Task 7 wiring.
- Produces:
  - `struct AIReviewComposition: Equatable { let string: String; let removedRanges: [Int: NSRange]; let pillIndices: [Int: Int]; static func build(text: String, session: AIReviewSession) -> AIReviewComposition }`
    — for each PENDING change in order: the original (in `removedRanges` unless kept), the
    replacement, then one U+FFFC for its pill. Decided changes contribute nothing (already applied
    or gone).
  - `final class AIReviewPillCell: NSTextAttachmentCell` — `init(changeID: Int, isCurrent: Bool, ink: NSColor)`;
    `static let size = NSSize(width: 38, height: 18)` plus a 3pt leading gap; capsule outline 1pt;
    `checkmark` left and `xmark` right (SF Symbols, 9pt, same ink); a 0.75pt vertical divider at the
    centre whose ends stop 1pt short of the outline's inner top and bottom; no fill.
    `enum Part { case accept, reject }`; `func part(at point: NSPoint, in cellFrame: NSRect) -> Part`;
    `static func dividerRect(in cellFrame: NSRect) -> NSRect`.
  - `final class AIReviewTextView: NSTextView` — not editable, not selectable, spell checking off,
    `writingToolsBehavior = .none` (macOS 15+), `undoManager` returns a private empty manager,
    `menu(for:)` returns nil. `var commandHandler: ((AIReviewCommand) -> Void)?`;
    `func present(_ composition: AIReviewComposition, currentID: Int?, profile: ReadingProfile)` —
    highlights with `MarkdownSyntaxHighlighter().highlight(textView:profile:)`, dims
    `removedRanges` with temporary `.foregroundColor` `HistoryPalette.recededInk`, pills via
    `NSTextAttachment` + `AIReviewPillCell` (current: `theme.textColor`, others `recededInk`);
    `func matchGeometry(of editor: NSTextView)` — copies `textContainerInset`,
    `lineFragmentPadding`, container size, frame width, `defaultParagraphStyle`, background.
    Input: `moveLeft:`/`moveRight:` → `.previous`/`.next`, `insertNewline:` → `.acceptCurrent`,
    `cancelOperation:` → `.end`, `insertText` → `.typed`; `mouseDown` on a pill → `.accept`/`.reject`
    by `part(at:)`, on a dimmed range → `.toggleKeep`. `accessibilityCustomActions`: Accept Change,
    Reject Change, Keep Removed Text, Next Change, Previous Change, Accept All/Remaining, Reject
    All/Remaining, End Review (titles follow `hasDecided`).
  - `struct AIReviewSurfaceRepresentable: NSViewRepresentable` — returns an `NSScrollView` holding
    an `AIReviewTextView`; on make copies the editor's clip-view origin and becomes first responder;
    on dismantle sets the editor's origin to its own and makes the editor first responder.
  - `enum AIReviewCardPresentation` — `static func buttonTitles(hasDecided: Bool) -> (accept: String, reject: String)`
    ("Accept All"/"Reject All" → "Accept Remaining"/"Reject Remaining");
    `static func positionText(current: Int, total: Int) -> String` ("%lld of %lld");
    `static func progressText(for action: AIAction, provider: AIProvider) -> String`
    ("Trimming with Claude…"; Other: "Trimming with your AI…"); `cancelHint = "Esc to cancel"`;
    `markHint = "Esc clears marks"`.
  - `struct AIReviewCard: View` — `init(position: Int, total: Int, hasDecided: Bool, usesDarkChrome: Bool, onAcceptRemaining: @escaping () -> Void, onRejectRemaining: @escaping () -> Void)`;
    shown only when `changes.count > 1`.
  - `struct AIStatusCard: View` — `init(text: String, hint: String?, showsProgress: Bool, usesDarkChrome: Bool, onClose: @escaping () -> Void)`
    for running / message / marking. Both cards use `AnnouncementCard`'s chrome and `edgeInset`,
    `usesDarkChrome` threaded; overlay `.bottom` of `editorContent`; the AI card hides the
    announcement/default-app card while up (one bottom card at a time).

Behaviour: the overlay is shown only while `state == .reviewing` and the display mode is Write; its
text before the first change is identical to the document, so lines line up. A run chosen in
Split switches to Write first. Window close and tab close call `endReview()`.

- [ ] **Step 1: Write the failing tests**

```swift
// AIReviewCompositionTests
func testCompositionSplicesInsertionsAndPills()   // "a big day" with big→large → "a biglarge\u{FFFC} day", removed == "big"
func testTextBeforeFirstChangeIsIdentical()       // composition.string.hasPrefix(prefix before change 0)
func testKeptOriginalIsNotDimmed()
func testDecidedChangesContributeNothing()
// AIReviewPillCellTests
func testLeftHalfAcceptsRightHalfRejects()
func testDividerStopsShortOfEdges()               // dividerRect.minY == outline inner minY + 1; maxY == inner maxY - 1
func testPillInksMeetContrastOnEveryTheme()       // Theme.builtIn: contrastRatio(textColor, page) >= 4.5; recededInk >= 3.0
// AIReviewCardPresentationTests
func testButtonsSayAllUntilFirstDecisionThenRemaining()
func testPositionAndProgressTextAreLocalized()    // es/fr/de/ja/zh-Hans via .lproj bundles
// ReleaseResourceTests
func testATSAllowsAtMostLocalNetworking()         // NSAppTransportSecurity absent, or exactly ["NSAllowsLocalNetworking": true]; never NSAllowsArbitraryLoads*
```

- [ ] **Step 2: Run to verify they fail** (the four classes + gates). Expected: build failure.
- [ ] **Step 3: Implement** the five files and the container wiring.
- [ ] **Step 4: Run to verify they pass**, then `xcodebuild build …`. Expected: pass;
  `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Manual QA with the stub (record results in the PR).** Start
  `python3 scripts/ai-stub-server.py`, launch the fresh build with
  `open -a "$BUILT_PRODUCTS_DIR/Lineform.app" fixture.md` (the Task 6 fixture saved as a file), connect
  **Other** at `http://127.0.0.1:8765/v1`. If the first action fails with
  `NSURLErrorAppTransportSecurityRequiresSecureConnection` (-1022), add `NSAppTransportSecurity` ▸
  `NSAllowsLocalNetworking = YES` to `Lineform/Info.plist` (no entitlement change) and repeat; also
  try `http://localhost:8765/v1`. Check: before connecting, no AI items and `nettop` silent at
  launch; each action; pills ✓/✕; click a dimmed piece; ←/→, Return, Esc; card "1 of N" →
  Remaining after one decision; one ⌘Z per accept and one for Accept Remaining; Proofread on
  `teh ,`; Mark both kinds, Esc and typing clear; Esc cancels with `--delay 10`; `--status 401`,
  `--junk` and `--mangle` messages (mangle: file bytes outside prose unchanged — `diff` the
  structure); History row appears after an accept and holds original + accepted; edit the file
  externally during review → overlay leaves, nothing applied. Repeat review in Paper, Quiet and
  Night, with Automatic Dark Mode, and in a CRLF file. VoiceOver: custom actions on the overlay,
  announcements.
- [ ] **Step 6: Commit** — `git commit -m "Add AI review overlay, cards and editor wiring"`.

---

### Task 9: Privacy, App Review, docs, and the full gate

**Files:**
- Modify: `CLAUDE.md` (tracked as `Claude.md` — `git add Claude.md`),
  `docs/architecture/editor-behavior.md`, `docs/architecture/app-integration.md`,
  `Lineform/Resources/Privacy.md`, `Lineform/Resources/Help.md`,
  `Lineform/Resources/AppStoreMetadata.md` (review notes, if it carries them),
  `docs/release/app-store-release.md` (§5 App Privacy, §6 review notes); local untracked
  `POSITIONING_AND_MARKETING.md` (edit, do not commit)
- Test: `LineformTests/ReleaseResourceTests.swift` (one test)

**Interfaces:**
- Consumes: everything above. Produces documentation only, plus
  `testPrivacyDocDescribesAIConnection` (bundled `Privacy.md` contains "Connect Your AI" and
  "Keychain").

- [ ] **Step 1: Write the failing test** `testPrivacyDocDescribesAIConnection`; run it with the
  gates; expected FAIL.
- [ ] **Step 2: Check App Review 5.1.2.** Read the current App Review Guidelines §5.1.2 (sharing
  personal data with third parties, including third-party AI). Confirm the Connect button's label
  (Task 3) is an explicit, prior disclosure of what is sent and to whom, and that nothing is sent
  before it. Record the guideline wording checked and the conclusion in
  `docs/release/app-store-release.md` §6. If Apple requires more than this (e.g. a per-action
  prompt), STOP and bring it to the owner — do not add UI on your own.
- [ ] **Step 3: Update the docs.**
  - `CLAUDE.md`: one feature line ("Bring your own AI: Lineform ▸ Connect Your AI… connects Claude,
    ChatGPT, Google or an OpenAI-compatible server with the user's key (Keychain); right-click
    Rewrite ▸ Trim/Cut in half/Rewrite, Proofread, Mark ▸ Weakest/Long sentences, reviewed as a
    read-only overlay"). Invariants: **AI never changes Markdown structure** — only
    `MarkdownStructureMap` prose is sent, revisions pass `MarkdownStructureGuard`, the whole-document
    signature is verified, and a new `MarkdownTokenKind`/`MarkdownBlock` needs a protection rule;
    **no network unless connected and user-initiated** — nothing at launch, on opening the window,
    or on Connect; suggestions never enter the text storage until accepted; one AI action records
    one History passage; keys only in the Keychain.
  - `docs/architecture/editor-behavior.md`: new "AI actions and review" section (state machine,
    overlay, read-only rule, undo shape, History recording, Mark, the decisions listed in this plan's
    hand-off) and `app-integration.md`: Connect window, Keychain, endpoints/models, ATS outcome,
    network rule, test-host rule.
  - `Privacy.md` / `Help.md`: what is sent (only the prose of the selection), to whom, when, under
    whose terms; keys in Keychain; how to disconnect; that structure, code, math and front matter
    are never sent.
  - `app-store-release.md` §5: whether App Privacy stays **Data Not Collected** (the developer
    receives nothing; text goes from the user's Mac to the provider the user chose under the user's
    own account). Write the reasoning; if it is not clearly still accurate, flag it for the owner.
  - `POSITIONING_AND_MARKETING.md` (local): replace "No AI inside" claims with "No AI built in.
    Connect your own if you want it."
- [ ] **Step 4: Run the default test plan once** (warn the user first: the CLI run can trigger a
  macOS Documents-access prompt): the base command with no `-only-testing`. Expected: report exact
  pass/fail counts; 0 failures.
- [ ] **Step 5: Commit** — `git commit -m "Document bring-your-own AI, privacy and App Review"`.
