import XCTest
@testable import Lineform

/// Guards the two `.xctestplan` files against silent drift. The hosted-window test
/// quarantine hangs on CLASS-NAME STRINGS in JSON that xcodebuild never validates:
/// if a hosted class is renamed (or a new one is added to only one plan), the
/// default plan silently un-skips crash-prone tests into CI while the hosted plan
/// silently runs nothing. This test — which runs in the DEFAULT plan — fails
/// loudly instead. It locates the plans via `#filePath`, so it works anywhere the
/// source checkout exists (dev machines, CI).
final class TestPlanGuardTests: XCTestCase {
    private struct Plan: Decodable {
        struct Target: Decodable {
            var skippedTests: [String]?
            var selectedTests: [String]?
        }

        var testTargets: [Target]
    }

    private func loadPlan(named name: String) throws -> Plan {
        // #filePath = <repo>/LineformTests/TestPlanGuardTests.swift; plans live at the repo root.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(name))
        return try JSONDecoder().decode(Plan.self, from: data)
    }

    func testHostedQuarantineListsStayComplementaryAndReal() throws {
        let defaultPlan = try loadPlan(named: "Lineform.xctestplan")
        let hostedPlan = try loadPlan(named: "LineformHosted.xctestplan")

        let skipped = Set(defaultPlan.testTargets.flatMap { $0.skippedTests ?? [] })
        let selected = Set(hostedPlan.testTargets.flatMap { $0.selectedTests ?? [] })

        // The two plans must partition the same set: exactly what the default plan
        // skips is what the hosted plan runs.
        XCTAssertFalse(skipped.isEmpty, "The default plan should quarantine the hosted-window tests.")
        XCTAssertEqual(
            skipped,
            selected,
            "Lineform.xctestplan's skippedTests and LineformHosted.xctestplan's selectedTests have drifted — update both in lockstep."
        )

        // Every quarantined name must be a real XCTestCase subclass in this bundle,
        // so a class rename that misses the plans breaks HERE instead of silently
        // un-skipping crash-prone tests into the default suite.
        for name in skipped {
            let cls: AnyClass? = NSClassFromString("LineformTests.\(name)") ?? NSClassFromString(name)
            XCTAssertNotNil(
                cls,
                "Test plans reference '\(name)' but no such test class exists — a rename must update both .xctestplan files."
            )
            if let cls {
                XCTAssertTrue(cls is XCTestCase.Type, "'\(name)' in the test plans is not an XCTestCase subclass.")
            }
        }
    }
}
