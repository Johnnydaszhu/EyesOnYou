import XCTest
@testable import EyesOnYouIPC

/// The activation request targets `extensionBundleID`; if that string is ever
/// wrong, `OSSystemExtensionRequest` fails pointing at an extension that does not
/// exist — with no obvious cause. It is derived, not hardcoded, so cover the
/// derivation.
final class BundleIdentityTests: XCTestCase {
    func testHostIDPassesThroughForTheAppProcess() {
        XCTAssertEqual(
            EyesOnYouConstants.normalizedHostBundleID("com.latenightking.EyesOnYou"),
            "com.latenightking.EyesOnYou"
        )
    }

    func testExtensionProcessNormalizesBackToItsHost() {
        // Same type is linked into the extension, where Bundle.main is the
        // extension itself — it must not compound the suffix.
        let host = EyesOnYouConstants.normalizedHostBundleID(
            "com.latenightking.EyesOnYou.NetworkExtension"
        )
        XCTAssertEqual(host, "com.latenightking.EyesOnYou")
        XCTAssertEqual(
            host + EyesOnYouConstants.extensionBundleIDSuffix,
            "com.latenightking.EyesOnYou.NetworkExtension"
        )
    }

    func testMissingOrEmptyBundleIDFallsBackToPlaceholder() {
        XCTAssertEqual(
            EyesOnYouConstants.normalizedHostBundleID(nil),
            "com.example.EyesOnYou"
        )
        XCTAssertEqual(
            EyesOnYouConstants.normalizedHostBundleID(""),
            "com.example.EyesOnYou"
        )
    }

    func testAdHocPlaceholderStillDerivesAMatchingPair() {
        let host = EyesOnYouConstants.normalizedHostBundleID("com.example.EyesOnYou")
        XCTAssertEqual(
            host + EyesOnYouConstants.extensionBundleIDSuffix,
            "com.example.EyesOnYou.NetworkExtension"
        )
    }
}
