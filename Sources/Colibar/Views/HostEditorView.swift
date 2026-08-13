import ColibarCore
import SwiftUI

/// Popover for mapping one container to a .test hostname. The suffix is
/// fixed — whatever the user types is normalized into "<something>.test".
struct HostEditorView: View {
    @EnvironmentObject private var appState: AppState
    let container: DockerContainer
    @Binding var isPresented: Bool

    @State private var name: String
    @State private var port: Int

    init(container: DockerContainer, isPresented: Binding<Bool>, existing: CustomHostMapping?) {
        self.container = container
        _isPresented = isPresented
        if let existing {
            _name = State(initialValue: String(existing.host.dropLast(".test".count)))
            _port = State(initialValue: existing.port)
        } else {
            // Suggest service.project ("mailpit.goodbite") or the container name.
            let suggestion: String
            if let project = container.composeProject {
                let service = ProjectDomain.hostLabel(container.composeService ?? container.name)
                suggestion = "\(service).\(ProjectDomain.hostLabel(project))"
            } else {
                suggestion = ProjectDomain.hostLabel(container.name)
            }
            _name = State(initialValue: suggestion)
            _port = State(initialValue: ProjectDomain.webPort(for: container) ?? container.hostPorts.first ?? 80)
        }
    }

    private var normalizedHost: String? {
        ProjectDomain.normalizeHostName(name)
    }

    private var existingMapping: CustomHostMapping? {
        appState.hostMapping(for: container)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Host for \(container.displayName)")
                .font(.headline)

            HStack(spacing: 2) {
                TextField("myapp", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Text(".test")
                    .foregroundStyle(.secondary)
            }

            Picker("Port", selection: $port) {
                ForEach(container.hostPorts, id: \.self) { candidate in
                    Text(":\(String(candidate))").tag(candidate)
                }
            }
            .pickerStyle(.segmented)

            if let host = normalizedHost {
                Text("\(host) → localhost:\(String(port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("Saving updates /etc/hosts — macOS will ask for your password.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack {
                if existingMapping != nil {
                    Button("Remove", role: .destructive) {
                        appState.removeHostMapping(for: container)
                        isPresented = false
                    }
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let host = normalizedHost else { return }
                    appState.setHostMapping(for: container, host: host, port: port)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(normalizedHost == nil || container.hostPorts.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
