import Dispatch
import Foundation
import NetworkExtension
import OSLog

// Apple recommends entering Network Extension system-extension mode as early as possible.
NEProvider.startSystemExtensionMode()

let log = Logger(subsystem: "com.example.EyesOnYou", category: "SystemExtension")
log.info("EyesOnYou Network Extension starting")

// Bootstrap only local, bounded work here. Provider start methods own their
// lifecycle-specific initialization. A production runtime would also start the
// signed XPC listener and load small immutable configuration metadata.

dispatchMain()
