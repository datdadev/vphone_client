import Foundation

/// Mirrors the bridge/vphone.sock wire protocol -- see bridge/src/server.ts
/// and vphone-cli's VPhoneHostControl.swift.
struct BridgeResponse: Decodable {
    let ok: Bool
    let t: String?
    let error: String?
    /// True if a raw binary WS frame with the JPEG bytes immediately follows this one.
    let hasImage: Bool?
    /// The coordinate space touch commands must be expressed in, reported by the
    /// host so the client never has to infer it from the compact image size.
    let screenWidth: Int?
    let screenHeight: Int?
    /// Encoded video dimensions (may differ from the touch coordinate space
    /// if the stream is scaled down).
    let videoWidth: Int?
    let videoHeight: Int?
    /// Echoed back by the bridge's ping handler for RTT measurement.
    let ts: Double?
    let path: String?
    let vms: [VMSummary]?
    let info: VMInfo?
}

struct VMSummary: Decodable, Identifiable {
    let name: String
    var id: String { name }
}

struct VMInfo: Decodable {
    let name: String
    let cpuCount: Int
    let memoryMB: Int
}

enum HardwareKey: String {
    case home, power, volup, voldown
    /// iOS has no app-switcher key; the host synthesises it as a double Home.
    case appSwitcher = "appswitcher"
}
