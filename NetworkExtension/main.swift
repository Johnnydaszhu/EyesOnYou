import Foundation
import NetworkExtension
import OSLog

// Enter Network Extension system-extension mode as early as possible.
NEProvider.startSystemExtensionMode()

let log = Logger(subsystem: "com.example.EyesOnYou", category: "SystemExtension")
log.info("EyesOnYou Network Extension starting (Filter + Transparent Proxy providers)")

// Shared runtime bootstrap is intentionally minimal here.
// Filter/Proxy provider start methods own lifecycle-specific initialization.
// Fail-open: if rule snapshots cannot load, providers allow / do not claim flows.

dispatchMain()
