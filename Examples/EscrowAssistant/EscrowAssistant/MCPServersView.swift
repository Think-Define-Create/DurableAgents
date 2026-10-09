import DurableMCP
import SwiftUI

/// Optional MCP server list. Account names only. This screen does not open a connection.
struct MCPServersView: View {
    let directory: URL
    @State private var servers: [MCPServerConfig] = []
    @State private var name = ""
    @State private var transport = "http"
    @State private var command = ""
    @State private var url = ""
    @State private var allow = ""
    @State private var envName = ""
    @State private var envAccount = ""
    @State private var headerName = ""
    @State private var headerAccount = ""
    @State private var message: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Saved servers stay on this device. The chat does not call them. Put secret-account names here, not the secret itself. An empty allowlist exposes no tools. Destructive tools, and tools with no hints, still wait for approval when a host connects. Treat tool descriptions as untrusted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if servers.isEmpty {
                    Text("No MCP servers yet.")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("mcpEmpty")
                } else {
                    ForEach(servers, id: \.name) { server in
                        serverRow(server)
                    }
                }
                form
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("mcpError")
                }
            }
            .padding(16)
        }
        .background(colorScheme == .dark ? Color.black : Color(red: 0.96, green: 0.95, blue: 0.92))
        .navigationTitle("MCP servers")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server.name)
                .font(.subheadline.weight(.semibold))
            Text("\(server.transport) · \(server.allow.count) allowed")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Remove") {
                servers.removeAll { $0.name == server.name }
                persist()
            }
            .font(.caption)
            .accessibilityIdentifier("mcpRemove-\(server.name)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.05))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a server")
                .font(.subheadline.weight(.semibold))
            TextField("Name", text: $name, prompt: Text("files"))
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("mcpName")
            Picker("Transport", selection: $transport) {
                Text("HTTP").tag("http")
                Text("stdio").tag("stdio")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("mcpTransport")
            if transport == "stdio" {
                TextField("Command", text: $command, prompt: Text("/usr/local/bin/server"))
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mcpCommand")
                Text("stdio runs on a Mac or Linux host. This iPhone build only saves the command.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("URL", text: $url, prompt: Text("https://mcp.example/mcp"))
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mcpURL")
            }
            TextField("Allowlist", text: $allow, prompt: Text("read_file, list_dir"))
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("mcpAllow")
            Text("Remote tool names, separated by commas.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("Env variable", text: $envName, prompt: Text("TOKEN"))
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("mcpEnvName")
            TextField("Env secret account", text: $envAccount, prompt: Text("files-token"))
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("mcpEnvAccount")
            TextField("Header name", text: $headerName, prompt: Text("Authorization"))
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("mcpHeaderName")
            TextField("Header secret account", text: $headerAccount, prompt: Text("files-auth"))
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("mcpHeaderAccount")
            Button("Save server") {
                saveForm()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("mcpSave")
        }
    }

    private var fileURL: URL {
        directory.appendingPathComponent("mcp-servers.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            servers = []
            return
        }
        do {
            servers = try JSONDecoder().decode([MCPServerConfig].self, from: data)
            message = nil
        } catch {
            servers = []
            message = "The MCP config file could not be read."
        }
    }

    private func saveForm() {
        let allowed = allow.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var env: [String: String] = [:]
        var headers: [String: String] = [:]
        if !envName.isEmpty || !envAccount.isEmpty {
            guard !envName.isEmpty, !envAccount.isEmpty else {
                message = "An environment secret needs both a variable name and an account name."
                return
            }
            env[envName] = envAccount
        }
        if !headerName.isEmpty || !headerAccount.isEmpty {
            guard !headerName.isEmpty, !headerAccount.isEmpty else {
                message = "A header secret needs both a header name and an account name."
                return
            }
            headers[headerName] = headerAccount
        }
        let config = MCPServerConfig(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            transport: transport,
            command: transport == "stdio" ? command.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            url: transport == "http" ? url.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            envSecrets: env,
            headerSecrets: headers,
            allow: allowed
        )
        do {
            try config.validate()
        } catch {
            message = String(describing: error)
            return
        }
        servers.removeAll { $0.name == config.name }
        servers.append(config)
        servers.sort { $0.name < $1.name }
        persist()
        name = ""
        command = ""
        url = ""
        allow = ""
        envName = ""
        envAccount = ""
        headerName = ""
        headerAccount = ""
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(servers)
            try data.write(to: fileURL, options: .atomic)
            message = nil
        } catch {
            message = "The MCP config could not be saved."
        }
    }
}
