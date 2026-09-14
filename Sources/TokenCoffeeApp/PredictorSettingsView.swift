import SwiftUI
import TokenCoffeeCore

struct PredictorSettingsView: View {
    @ObservedObject var model: LinkedDashboardModel
    @ObservedObject var store: PredictorStore
    @ObservedObject var state: ManagementState

    private var selected: Predictor? {
        state.newPredictor ?? store.items.first { $0.id == state.predictorID }
    }
    private var selectedIndex: Int? { store.items.firstIndex { $0.id == state.predictorID } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PredictorTable(items: store.items, selected: state.predictorID, canMove: !state.dirty,
                    subtitle: source, select: { id in
                    guard id != state.predictorID else { return }
                    state.navigate {
                        state.predictorID = id; state.newPredictor = nil; state.editorVersion = UUID()
                    }
                }, move: { offsets, destination, id in
                    store.move(from: offsets, to: destination)
                    state.predictorID = id; state.editorVersion = UUID()
                    model.predictorsChanged()
                })
                Divider()
                HStack(spacing: 8) {
                    Button { state.navigate { add() } } label: { Image(systemName: "plus").frame(width: 12, height: 14) }
                        .help("Add predictor").accessibilityLabel("Add predictor")
                        .disabled(model.sources.isEmpty || store.error != nil)
                        .accessibilityIdentifier("predictors.add")
                    Button { state.navigate { remove() } } label: { Image(systemName: "minus").frame(width: 12, height: 14) }
                        .help("Remove predictor").accessibilityLabel("Remove predictor")
                        .disabled(selectedIndex == nil).accessibilityIdentifier("predictors.remove")
                    Spacer()
                    Button { move(-1) } label: { Image(systemName: "arrow.up") }
                        .disabled(selectedIndex == nil || selectedIndex == 0)
                        .help("Move up").accessibilityLabel("Move up").accessibilityIdentifier("predictors.up")
                    Button { move(1) } label: { Image(systemName: "arrow.down") }
                        .disabled(selectedIndex == nil || selectedIndex == store.items.count - 1)
                        .help("Move down").accessibilityLabel("Move down").accessibilityIdentifier("predictors.down")
                }.padding(10)
                Text("Drag rows to change dashboard order.")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
            }.frame(width: 270)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let draft = selected {
                        PredictorEditor(model: model, initial: draft, isNew: state.newPredictor != nil,
                            changed: { state.dirty = $0 }) { updated in
                            if store.save(updated) {
                                state.dirty = false; state.newPredictor = nil; state.predictorID = updated.id
                                state.editorVersion = UUID(); model.predictorsChanged()
                            }
                        } cancel: {
                            state.dirty = false; state.newPredictor = nil
                            state.predictorID = state.predictorID ?? store.items.first?.id
                            state.editorVersion = UUID()
                        }.id(state.editorVersion)
                    } else {
                        Text("Select a predictor or add one with the plus button.").foregroundStyle(.secondary)
                    }
                    if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
                    Text("Removing a predictor keeps its account and usage history.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(22)
            }
        }
        .onAppear { if state.predictorID == nil { state.predictorID = store.items.first?.id } }
    }

    private func source(_ item: Predictor) -> String {
        let account = model.accounts.first { $0.id == item.accountID }
        let value = model.sources.first { $0.id == item.sourceID }?.title ?? item.scopeID
        return [account?.provider ?? "Account unavailable", account?.name, value].compactMap { $0 }.joined(separator: " · ")
    }

    private func add() {
        guard let value = model.sources.first,
              let account = model.accounts.first(where: { $0.id == value.accountID }) else { return }
        state.newPredictor = Predictor(accountID: value.accountID, scopeID: value.scopeID,
            sourceTitle: value.title, name: account.name + " · " + value.title,
            color: .suggested(for: account.provider))
        state.predictorID = nil
        state.editorVersion = UUID()
        state.dirty = true
    }

    private func remove() {
        guard let index = selectedIndex else { return }
        store.remove(store.items[index].id)
        state.predictorID = store.items.isEmpty ? nil : store.items[min(index, store.items.count - 1)].id
        state.newPredictor = nil
        state.editorVersion = UUID()
        model.predictorsChanged()
    }

    private func move(_ offset: Int) {
        guard let id = state.predictorID else { return }
        state.navigate { store.move(id, by: offset); model.predictorsChanged() }
    }
}

private struct PredictorEditor: View {
    @ObservedObject var model: LinkedDashboardModel
    @State private var draft: Predictor
    @State private var suggestedName: String
    @State private var suggestedColor: PredictorColor
    let isNew: Bool
    let initial: Predictor
    let changed: (Bool) -> Void
    let save: (Predictor) -> Void
    let cancel: () -> Void

    init(model: LinkedDashboardModel, initial: Predictor, isNew: Bool, changed: @escaping (Bool) -> Void,
         save: @escaping (Predictor) -> Void, cancel: @escaping () -> Void) {
        self.model = model
        _draft = State(initialValue: initial)
        _suggestedName = State(initialValue: initial.name)
        _suggestedColor = State(initialValue: initial.color)
        self.isNew = isNew
        self.initial = initial
        self.changed = changed
        self.save = save
        self.cancel = cancel
    }

    private var values: [PredictorSource] { model.sources.filter { $0.accountID == draft.accountID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Add Predictor" : "Edit Predictor").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Account").font(.caption)
                Picker("Account", selection: $draft.accountID) {
                    if !model.accounts.contains(where: { $0.id == draft.accountID }) {
                        Text("Account unavailable").tag(draft.accountID)
                    }
                    ForEach(model.accounts) { Text($0.provider + " · " + $0.name).tag($0.id) }
                }.labelsHidden().accessibilityIdentifier("predictor.account")
                Text("Value").font(.caption)
                Picker("Value", selection: $draft.scopeID) {
                    if !values.contains(where: { $0.scopeID == draft.scopeID }) {
                        Text(draft.scopeID.isEmpty ? "No values available" : draft.scopeID + " · unavailable").tag(draft.scopeID)
                    }
                    ForEach(values) { Text($0.title).tag($0.scopeID) }
                }.labelsHidden().accessibilityIdentifier("predictor.value")
                if model.diagram(for: draft) == nil {
                    Text("This value is currently unavailable. Its predictor will keep its place until readings resume.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption)
                TextField("Predictor name", text: $draft.name).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("predictor.name")
                if !draft.isValid { Text("Choose a value and use a name of 1–60 characters on one line.").font(.caption).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Colour · " + draft.color.title).font(.caption)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 28, maximum: 32))], alignment: .leading, spacing: 8) {
                    ForEach(PredictorColor.allCases) { color in
                        Button { draft.color = color } label: {
                            Circle().fill(color.value).frame(width: 24, height: 24)
                                .overlay { if draft.color == color { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).shadow(radius: 1) } }
                        }.buttonStyle(.plain).help(color.title).accessibilityLabel(color.title)
                            .accessibilityValue(draft.color == color ? "Selected" : "")
                            .accessibilityIdentifier("predictor.color." + color.rawValue)
                    }
                }
                Text("Used for the title and usage line. Forecast and warning colours keep their meaning.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(isNew ? "Add" : "Save") { save(draft) }
                    .disabled(!draft.isValid)
                    .accessibilityIdentifier("predictor.save")
                Button("Cancel", action: cancel).accessibilityIdentifier("predictor.cancel")
            }
        }
        .onChange(of: draft.accountID) { _, _ in
            draft.scopeID = values.first?.scopeID ?? ""
            draft.sourceTitle = values.first?.title ?? ""
            if isNew { suggestPresentation() }
        }
        .onChange(of: draft.scopeID) { _, _ in
            draft.sourceTitle = values.first { $0.scopeID == draft.scopeID }?.title ?? ""
            if isNew { suggestPresentation() }
        }
        .onChange(of: draft) { _, value in changed(isNew || value != initial) }
    }

    private func suggestPresentation() {
        guard let account = model.accounts.first(where: { $0.id == draft.accountID }) else { return }
        let name = account.name + " · " + draft.sourceTitle
        let color = PredictorColor.suggested(for: account.provider)
        if draft.name == suggestedName { draft.name = name }
        if draft.color == suggestedColor { draft.color = color }
        suggestedName = name
        suggestedColor = color
    }
}
