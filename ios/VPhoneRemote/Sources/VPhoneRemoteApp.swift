import SwiftUI

@main
struct VPhoneRemoteApp: App {
    @StateObject private var connection = ConnectionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connection)
        }
    }
}
