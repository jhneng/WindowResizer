import Foundation
import Combine

struct Preset: Identifiable, Codable, Hashable {
    var id = UUID()
    var label: String
    var width: Int
    var height: Int
}

@MainActor
final class PresetStore: ObservableObject {
    @Published var presets: [Preset] {
        didSet { save() }
    }

    private let key = "savedPresets"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Preset].self, from: data) {
            presets = decoded
        } else {
            presets = [
                Preset(label: "720p",   width: 1280, height: 720),
                Preset(label: "1080p",  width: 1920, height: 1080),
                Preset(label: "Square", width: 1000, height: 1000),
            ]
        }
    }

    func add(label: String, width: Int, height: Int) {
        presets.append(Preset(label: label, width: width, height: height))
    }

    func remove(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
