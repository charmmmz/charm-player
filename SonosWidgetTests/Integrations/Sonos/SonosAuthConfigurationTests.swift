import XCTest
@testable import SonosWidget

final class SonosAuthConfigurationTests: XCTestCase {
    func testMissingClientIDReportsActionableMessage() {
        let message = SonosAuth.oauthConfigurationFailureMessage(
            clientID: "",
            clientSecret: "secret",
            redirectURI: "https://example.com/callback.html"
        )

        XCTAssertEqual(
            message,
            "Sonos OAuth client ID is missing. Check Config/SonosSecrets.xcconfig."
        )
    }

    func testMissingClientSecretReportsActionableMessage() {
        let message = SonosAuth.oauthConfigurationFailureMessage(
            clientID: "client",
            clientSecret: "",
            redirectURI: "https://example.com/callback.html"
        )

        XCTAssertEqual(
            message,
            "Sonos OAuth client secret is missing. Check Config/SonosSecrets.xcconfig."
        )
    }

    func testMissingRedirectURIReportsActionableMessage() {
        let message = SonosAuth.oauthConfigurationFailureMessage(
            clientID: "client",
            clientSecret: "secret",
            redirectURI: "   "
        )

        XCTAssertEqual(
            message,
            "Sonos OAuth redirect URI is missing. Check Config/SonosSecrets.xcconfig."
        )
    }

    func testInvalidRedirectURIReportsActionableMessage() {
        let message = SonosAuth.oauthConfigurationFailureMessage(
            clientID: "client",
            clientSecret: "secret",
            redirectURI: "not a url"
        )

        XCTAssertEqual(
            message,
            "Sonos OAuth redirect URI is not a valid URL. Check Config/SonosSecrets.xcconfig."
        )
    }

    func testCompleteConfigurationHasNoFailureMessage() {
        let message = SonosAuth.oauthConfigurationFailureMessage(
            clientID: "client",
            clientSecret: "secret",
            redirectURI: "https://example.com/callback.html"
        )

        XCTAssertNil(message)
    }

    func testExampleSecretsUseStableRedirectURIEscaping() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRoot = try XCTUnwrap(
            sequence(first: testFileURL.deletingLastPathComponent()) { directory in
                let parent = directory.deletingLastPathComponent()
                return parent.path == directory.path ? nil : parent
            }
            .first { directory in
                FileManager.default.fileExists(
                    atPath: directory
                        .appendingPathComponent("Config")
                        .appendingPathComponent("SonosSecrets.example.xcconfig")
                        .path
                )
            }
        )
        let exampleURL = repositoryRoot
            .appendingPathComponent("Config")
            .appendingPathComponent("SonosSecrets.example.xcconfig")
        let example = try String(contentsOf: exampleURL, encoding: .utf8)

        XCTAssertTrue(example.contains("SLASH = /"))
        XCTAssertTrue(example.contains("SONOS_OAUTH_REDIRECT_URI = https:$(SLASH)$(SLASH)your-domain.example/oauth/callback.html"))
        XCTAssertFalse(example.contains("https:/$()/"))
    }
}
