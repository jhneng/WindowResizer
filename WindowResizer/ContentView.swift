import SwiftUI

struct ContentView: View {
    @StateObject private var store = PresetStore()
    @State private var apps: [RunningTarget] = []
    @State private var selectedPID: pid_t?
    @State private var customW = ""
    @State private var customH = ""
    @State private var newLabel = ""
    @State private var status = ""
    @State private var trusted = WindowResizer.hasPermission()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Window Resizer").font(.headline)

            if !trusted {
                permissionBanner
            }

            Divider()

            // App picker
            Picker("Target app", selection: $selectedPID) {
                Text("Select…").tag(pid_t?.none)
                ForEach(apps) { app in
                    Text(app.name).tag(pid_t?.some(app.id))
                }
            }
            Button("Refresh app list") { reload() }
                .font(.caption)

            Divider()

            // Position snapping
            Text("Position").font(.subheadline.bold())
            HStack {
                Button("◧ Left")  { snap(.left) }
                Button("Center")  { snap(.center) }
                Button("Right ◨") { snap(.right) }
            }
            .disabled(selectedPID == nil)

            Divider()

            // Custom size
            Text("Custom size").font(.subheadline.bold())
            HStack {
                TextField("Width", text: $customW).frame(width: 70)
                Text("×")
                TextField("Height", text: $customH).frame(width: 70)
                Button("Apply") { applyCustom() }
                    .disabled(selectedPID == nil)
            }

            // Save current custom as preset
            HStack {
                TextField("Preset name", text: $newLabel).frame(width: 100)
                Button("Save preset") { saveCustomAsPreset() }
                    .font(.caption)
                    .disabled(customW.isEmpty || customH.isEmpty || newLabel.isEmpty)
            }

            Divider()

            // Presets
            Text("Presets").font(.subheadline.bold())
            ForEach(store.presets) { preset in
                HStack {
                    Button("\(preset.label)  (\(preset.width)×\(preset.height))") {
                        apply(width: preset.width, height: preset.height)
                    }
                    .disabled(selectedPID == nil)
                    Spacer()
                    Button(role: .destructive) { store.remove(preset) }
                        label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }

            if !status.isEmpty {
                Divider()
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding()
        .frame(width: 320)
        .onAppear { reload() }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accessibility access required")
                .font(.caption.bold()).foregroundStyle(.orange)
            Text("Enable “Window Resizer”, then click Re-check.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Request Access") { requestAccess() }
                    .font(.caption)
                Button("Open Settings") { WindowResizer.openAccessibilitySettings() }
                    .font(.caption)
                Button("Re-check") {
                    trusted = WindowResizer.hasPermission()
                }.font(.caption)
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        apps = WindowResizer.runningApps()
        trusted = WindowResizer.hasPermission()
        if let pid = selectedPID, !apps.contains(where: { $0.id == pid }) {
            selectedPID = nil
        }
    }

    private func requestAccess() {
        WindowResizer.requestPermission()
        trusted = WindowResizer.hasPermission()
        if trusted {
            status = "Accessibility access granted."
        } else {
            status = "Approve Window Resizer in Accessibility, then click Re-check."
        }
    }

    private func snap(_ s: WindowResizer.Snap) {
        guard let pid = selectedPID else { return }
        Task {
            do {
                try await WindowResizer.snap(pid: pid, to: s)
                status = "Snapped \(s)."
                trusted = true
            } catch {
                status = error.localizedDescription
                trusted = WindowResizer.hasPermission()
            }
        }
    }

    private func applyCustom() {
        guard let w = Int(customW), let h = Int(customH) else {
            status = "Width and height must be numbers."; return
        }
        guard w > 0, h > 0 else {
            status = "Width and height must be positive."; return
        }
        apply(width: w, height: h)
    }

    private func saveCustomAsPreset() {
        guard let w = Int(customW), let h = Int(customH), w > 0, h > 0 else { return }
        store.add(label: newLabel, width: w, height: h)
        newLabel = ""
    }

    private func apply(width: Int, height: Int) {
        guard let pid = selectedPID else { return }
        Task {
            do {
                try await WindowResizer.resize(pid: pid, to: CGSize(width: width, height: height))
                status = "Set to \(width)×\(height)."
                trusted = true
            } catch {
                status = error.localizedDescription
                trusted = WindowResizer.hasPermission()
            }
        }
    }
}
