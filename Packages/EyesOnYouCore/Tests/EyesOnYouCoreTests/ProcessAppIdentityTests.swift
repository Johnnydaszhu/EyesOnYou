import XCTest
@testable import EyesOnYouCore

final class ProcessAppIdentityTests: XCTestCase {
    func testCanonicalSigningIDMapsChromeHelpers() {
        XCTAssertEqual(
            ProcessAppIdentity.canonicalSigningID("com.google.Chrome.helper"),
            "com.google.Chrome"
        )
        XCTAssertEqual(
            ProcessAppIdentity.canonicalSigningID("com.google.Chrome.helper.renderer"),
            "com.google.Chrome"
        )
        XCTAssertEqual(
            ProcessAppIdentity.canonicalSigningID("com.google.Chrome"),
            "com.google.Chrome"
        )
    }

    func testOutermostAppBundlePrefersChromeOverHelper() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/"
            + "Google Chrome Framework.framework/Versions/150.0.7871.182/"
            + "Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        let url = ProcessAppIdentity.outermostAppBundleURL(fromExecutablePath: path)
        XCTAssertEqual(url?.path, "/Applications/Google Chrome.app")
    }

    func testResolveFromChromeHelperPath() throws {
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: chromeURL.path))

        let helperPath = chromeURL.path + "/Contents/Frameworks/"
            + "Google Chrome Framework.framework/Versions/Current/"
            + "Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: helperPath))

        let resolved = ProcessAppIdentity.resolve(executablePath: helperPath, lsofCommand: "Google")
        XCTAssertEqual(resolved?.signingIdentifier, "com.google.Chrome")
        XCTAssertNotEqual(resolved?.displayName, "Google")
        XCTAssertFalse(resolved?.displayName.lowercased().contains("helper") ?? true)
    }

    func testTruncatedLsofCommandGoogleMapsToChrome() {
        let resolved = ProcessAppIdentity.resolve(executablePath: "/tmp/missing-binary", lsofCommand: "Google")
        XCTAssertEqual(resolved?.signingIdentifier, "com.google.Chrome")
        XCTAssertEqual(resolved?.displayName, "Google Chrome")
    }

    func testBrowserIdentityRecognizesCanonicalChrome() {
        let helper = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "com.google.Chrome.helper")
        XCTAssertTrue(BrowserIdentity.isBrowser(helper))
        let chrome = AppIdentityKey(teamIdentifier: "EQHXZ8M8AV", signingIdentifier: "com.google.Chrome")
        XCTAssertTrue(BrowserIdentity.isBrowser(chrome))
    }
}
