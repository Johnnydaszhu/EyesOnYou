import Foundation
import SwiftUI

/// Centralized user-facing product name and logo.
enum AppBrand {
    static let displayName = "EyesOnYou"
    /// Asset catalog image name for the product mark.
    static let logoImageName = "AppLogo"

    static var logo: Image {
        Image(logoImageName)
    }
}
