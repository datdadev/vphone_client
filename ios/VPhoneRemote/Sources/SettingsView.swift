import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var connection: ConnectionManager

    @State private var host: String = ""
    @State private var port: String = "8787"
    @State private var token: String = ""

    var body: some View {
        Form {
            Section("Bridge (on the Mac)") {
                TextField("Host (Tailscale IP or MagicDNS name)", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                SecureField("Bridge token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Button("Connect") {
                    guard let portNumber = Int(port) else { return }
                    connection.connect(host: host, port: portNumber, token: token)
                }
                .disabled(host.isEmpty || token.isEmpty || Int(port) == nil)
            }

            if case .error(let message) = connection.status {
                Section("Last error") {
                    Text(message).foregroundStyle(.red)
                }
            }
        }
        .onAppear {
            host = connection.host.isEmpty ? host : connection.host
            port = String(connection.port)
            token = KeychainStore.load() ?? ""
        }
    }
}
