import XCTest
@testable import Lineform

final class AIResponseParserTests: XCTestCase {
    func testParsesPlainJSON() {
        XCTAssertEqual(AIResponseParser.segments(from: #"{"segments":["a","b c"]}"#, expectedCount: 2), ["a", "b c"])
    }

    func testParsesFencedJSONWithPreamble() {
        XCTAssertEqual(AIResponseParser.segments(from: "Sure!\n```json\n{\"segments\":[\"x\"]}\n```", expectedCount: 1), ["x"])
        XCTAssertEqual(AIResponseParser.segments(from: "{\"segments\":[\"{brace}\"]} trailing", expectedCount: 1), ["{brace}"])
    }

    func testUnusableRepliesAreRefused() {
        for reply in ["", "Sure! Here you go.", "{}", #"{"segments":"x"}"#, #"{"segments":[1]}"#,
                      "}{", "{not json}", #"{"segments":["x", null]}"#, "[\"x\"]", String(repeating: "{", count: 10_000)] {
            XCTAssertNil(AIResponseParser.segments(from: reply, expectedCount: 1), reply.prefix(40).description)
        }
        XCTAssertNil(AIResponseParser.segments(from: #"{"segments":["a","b"]}"#, expectedCount: 1))
        XCTAssertNil(AIResponseParser.segments(from: #"{"segments":["a"]}"#, expectedCount: 2))
    }

    func testSentenceIndicesAreBoundedAndCapped() {
        XCTAssertEqual(AIResponseParser.sentenceIndices(from: #"{"sentences":[0,2,2,99,1]}"#, sentenceCount: 6), [0, 1])
        XCTAssertEqual(AIResponseParser.sentenceIndices(from: #"{"sentences":[3]}"#, sentenceCount: 1), [], "out of range")
        XCTAssertEqual(AIResponseParser.sentenceIndices(from: #"{"sentences":[1, 2]}"#, sentenceCount: 2), [0], "cap is at least 1")
        XCTAssertEqual(AIResponseParser.sentenceIndices(from: #"{"sentences":[]}"#, sentenceCount: 3), [])
    }

    func testSentenceIndicesSurviveHostileNumbers() {
        let reply = #"{"sentences":[1e308, -1, 1.5, "2", true, 9223372036854775807, 3]}"#
        XCTAssertEqual(AIResponseParser.sentenceIndices(from: reply, sentenceCount: 9), [2])
        XCTAssertNil(AIResponseParser.sentenceIndices(from: "no json", sentenceCount: 3))
        XCTAssertNil(AIResponseParser.sentenceIndices(from: #"{"sentences":"1"}"#, sentenceCount: 3))
    }
}
