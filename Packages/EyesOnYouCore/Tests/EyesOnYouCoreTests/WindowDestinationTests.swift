import XCTest
@testable import EyesOnYouCore

/// The `window:` destination prefix exists so apps whose only machine-readable
/// signal is the window title (Claude, GitHub Desktop, Xcode) can still show what
/// they were working on, instead of collapsing into "via proxy node".
final class WindowDestinationTests: XCTestCase {
    func testWindowKeysSurviveNormalization() {
        XCTAssertEqual(
            DestinationKey.make(hostname: "window:AppModel.swift — EyesOnYou", address: nil),
            "window:AppModel.swift — EyesOnYou"
        )
        // Prefix is normalized, title casing preserved.
        XCTAssertEqual(
            DestinationKey.make(hostname: "WINDOW:Refactor plan", address: nil),
            "window:Refactor plan"
        )
    }

    func testMakeLabeledProducesAWindowKey() {
        XCTAssertEqual(
            DestinationKey.makeLabeled(prefix: "window", title: "Refactor plan"),
            "window:Refactor plan"
        )
    }

    func testDisplayTitleStripsThePrefix() {
        XCTAssertEqual(
            TelemetryAggregator.displayTitle(forDestination: "window:Refactor plan"),
            "Refactor plan"
        )
    }

    func testWindowKeyIsNotConfusedWithAHostname() {
        // A real hostname must still lowercase; a window title must not.
        XCTAssertEqual(DestinationKey.make(hostname: "GitHub.com", address: nil), "github.com")
        XCTAssertEqual(
            DestinationKey.make(hostname: "window:GitHub Desktop — main", address: nil),
            "window:GitHub Desktop — main"
        )
    }
}
