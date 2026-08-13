import ColibarCore
import SwiftUI

/// Editor for one Colima instance's resources. Colima only reads
/// --cpus/--memory/--disk on `colima start`, so applying stops a running
/// instance and starts it again with the new values.
struct InstanceConfigView: View {
    @EnvironmentObject private var appState: AppState
    let instance: ColimaInstance

    @State private var cpus: Int
    @State private var memoryGiB: Int
    @State private var diskGiB: Int
    private let originalDiskGiB: Int

    init(instance: ColimaInstance) {
        self.instance = instance
        let currentCPUs = instance.cpus ?? 2
        let currentMemory = Self.gib(instance.memoryBytes) ?? 2
        let currentDisk = Self.gib(instance.diskBytes) ?? 100
        _cpus = State(initialValue: currentCPUs)
        _memoryGiB = State(initialValue: currentMemory)
        _diskGiB = State(initialValue: currentDisk)
        originalDiskGiB = currentDisk
    }

    private static func gib(_ bytes: Int64?) -> Int? {
        guard let bytes, bytes > 0 else { return nil }
        return max(1, Int((Double(bytes) / Double(1 << 30)).rounded()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.tint)
                Text("Resources — \(instance.name)")
                    .font(.headline)
            }

            resourceStepper("CPUs", value: $cpus, range: 1...32, unit: "")
            resourceStepper("Memory", value: $memoryGiB, range: 1...128, unit: "GiB")
            resourceStepper("Disk", value: $diskGiB, range: originalDiskGiB...500, unit: "GiB")

            VStack(alignment: .leading, spacing: 4) {
                if instance.isRunning {
                    Label(
                        "Applying stops and restarts the VM — running containers will restart.",
                        systemImage: "exclamationmark.triangle"
                    )
                }
                Label("Disk can grow but never shrink.", systemImage: "internaldrive")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") {
                    appState.editingInstance = nil
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(instance.isRunning ? "Apply & Restart" : "Apply & Start") {
                    appState.applyInstanceConfig(
                        instance, cpus: cpus, memoryGiB: memoryGiB, diskGiB: diskGiB
                    )
                    appState.editingInstance = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!changed && instance.isRunning)
            }
        }
        .padding(12)
    }

    private var changed: Bool {
        cpus != (instance.cpus ?? cpus)
            || memoryGiB != (Self.gib(instance.memoryBytes) ?? memoryGiB)
            || diskGiB != originalDiskGiB
    }

    private func resourceStepper(
        _ label: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 70, alignment: .leading)
            Spacer()
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue)\(unit.isEmpty ? "" : " \(unit)")")
                    .monospacedDigit()
                    .frame(minWidth: 60, alignment: .trailing)
            }
        }
    }
}
