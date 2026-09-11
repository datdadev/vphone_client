import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connection: ConnectionManager

    var body: some View {
        switch connection.status {
        case .connected:
            // No NavigationStack chrome here -- the remote screen owns the
            // entire display, with its own overlay controls (see RemoteScreenView).
            RemoteScreenView()
        default:
            NavigationStack {
                SettingsView()
                    .navigationTitle("VPhone Remote")
            }
        }
    }
}
