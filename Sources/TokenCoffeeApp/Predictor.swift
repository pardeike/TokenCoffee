import SwiftUI
import TokenCoffeeCore

/// Presentation only. Credentials and history stay with the account and scope.
struct Predictor: Codable, Equatable, Identifiable {
    var id = UUID()
    var accountID: UUID
    var scopeID: String
    var sourceTitle: String = ""
    var name: String
    var color: PredictorColor

    var sourceID: String { accountID.uuidString + ":" + scopeID }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.count <= 60 && !name.contains(where: { $0.isNewline }) && !scopeID.isEmpty
    }
}

struct PredictorSource: Identifiable {
    let accountID: UUID
    let scopeID: String
    let title: String
    var id: String { accountID.uuidString + ":" + scopeID }
}

enum PredictorColor: String, CaseIterable, Codable, Identifiable {
    case terracotta, mint, blue, cyan, purple, pink, orange, graphite
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var value: Color {
        switch self {
        case .terracotta: UsageProviderStyle.color(for: "Claude")
        case .mint: UsageProviderStyle.color(for: "Codex")
        case .blue: .blue
        case .cyan: .cyan
        case .purple: .purple
        case .pink: .pink
        case .orange: .orange
        case .graphite: .secondary
        }
    }
    static func suggested(for provider: String) -> Self { provider == "Claude" ? .terracotta : .mint }
}

/// The array is the dashboard order, including temporarily unavailable sources.
@MainActor
final class PredictorStore: ObservableObject {
    @Published private(set) var items: [Predictor]
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let key = "linkedDashboard.predictors"
    private(set) var needsImport: Bool

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            do {
                let loaded = try JSONDecoder().decode([Predictor].self, from: data)
                guard loaded.allSatisfy(\.isValid), Set(loaded.map(\.id)).count == loaded.count else {
                    throw CocoaError(.coderReadCorrupt)
                }
                items = loaded
            } catch {
                items = []
                self.error = "Could not read saved predictors. The saved list has not been changed."
            }
            needsImport = false
        } else {
            items = []
            needsImport = defaults.object(forKey: "linkedDashboard.diagramCount") != nil
        }
    }

    @discardableResult func save(_ predictor: Predictor) -> Bool {
        guard predictor.isValid else { return false }
        var updated = items
        var clean = predictor
        clean.name = clean.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = updated.firstIndex(where: { $0.id == clean.id }) { updated[index] = clean }
        else { updated.append(clean) }
        return write(updated)
    }

    func remove(_ id: UUID) { _ = write(items.filter { $0.id != id }) }

    func move(_ id: UUID, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + offset) else { return }
        var updated = items
        let item = updated.remove(at: index)
        updated.insert(item, at: index + offset)
        _ = write(updated)
    }

    func move(from offsets: IndexSet, to destination: Int) {
        guard offsets.allSatisfy(items.indices.contains), (0...items.count).contains(destination) else { return }
        var updated = items
        updated.move(fromOffsets: offsets, toOffset: destination)
        _ = write(updated)
    }

    func importExisting(_ existing: [Predictor]) {
        guard needsImport, error == nil else { return }
        _ = write(existing)
    }

    private func write(_ updated: [Predictor]) -> Bool {
        // Never replace unreadable saved preferences with an accidental empty list.
        guard error == nil, let data = try? JSONEncoder().encode(updated) else { return false }
        defaults.set(data, forKey: key)
        items = updated
        needsImport = false
        return true
    }
}
