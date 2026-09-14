import Combine
import Foundation
import TokenCoffeeCore

@MainActor
final class LinkedDashboardModel: ObservableObject {
    let geometry = DashboardLayoutState()
    @Published private(set) var accounts: [LinkedUsageAccount] = []
    @Published private(set) var diagrams: [LinkedUsageDiagram] = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var refreshingAccounts = Set<UUID>()
    var refreshing: Bool { !refreshingAccounts.isEmpty }
    @Published private(set) var linking = false
    private var linkingAccountID: UUID?
    @Published private(set) var accountMessage: String?
    private var loginID: UUID?
    @Published var page = 0
    let predictors: PredictorStore
    private var predictorSubscription: AnyCancellable?
    private let defaults: UserDefaults
    private let service: LinkedUsageService
    let power: AppModel?
    private var task: Task<Void, Never>?

    init(service: LinkedUsageService, defaults: UserDefaults = .standard, power: AppModel? = nil) {
        self.service = service
        self.power = power
        self.defaults = defaults
        predictors = PredictorStore(defaults: defaults)
        geometry.setCount(defaults.integer(forKey: "linkedDashboard.diagramCount"))
        predictorSubscription = predictors.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var pageCount: Int { max(1, (predictors.items.count + 5) / 6) }
    var pagePredictors: [Predictor] { Array(predictors.items.dropFirst(page * 6).prefix(6)) }
    func diagram(for predictor: Predictor) -> LinkedUsageDiagram? { diagrams.first { $0.id == predictor.sourceID } }
    var sources: [PredictorSource] {
        var values = accounts.flatMap { account in
            account.values.map { PredictorSource(accountID: account.id, scopeID: $0.scopeID, title: $0.title) }
        }
        for diagram in diagrams where !values.contains(where: { $0.id == diagram.id }) {
            values.append(PredictorSource(accountID: diagram.accountID, scopeID: diagram.scopeID, title: diagram.title))
        }
        for predictor in predictors.items where accounts.contains(where: { $0.id == predictor.accountID })
            && !values.contains(where: { $0.id == predictor.sourceID }) {
            values.append(PredictorSource(accountID: predictor.accountID, scopeID: predictor.scopeID,
                title: predictor.sourceTitle.isEmpty ? predictor.scopeID : predictor.sourceTitle))
        }
        return values
    }

    func start() {
        geometry.start()
        task = Task { [weak self, service] in
            if self?.power != nil {
                do { try await service.adoptExistingCodex() }
                catch { self?.accountMessage = "Existing Codex login could not be adopted. " + LinkedAccountError.message(for: error) }
            }
            let accounts = await service.accounts()
            self?.accounts = accounts
            self?.diagrams = await service.cachedDiagrams()
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
    }
    func stop() { task?.cancel(); task = nil; geometry.stop() }

    func refresh(_ accountID: UUID? = nil) async {
        if accountID != nil { accountMessage = nil }
        accounts = await service.accounts()
        if diagrams.isEmpty { diagrams = await service.cachedDiagrams() }
        let inspected = geometry.inspectedAccount.flatMap { pagePredictors.indices.contains($0) ? pagePredictors[$0].id : nil }
        for account in accounts where accountID == nil || account.id == accountID {
            guard !Task.isCancelled else { return }
            guard !refreshingAccounts.contains(account.id), !(accountID == nil && linking && linkingAccountID == account.id) else { continue }
            refreshingAccounts.insert(account.id)
            defer { refreshingAccounts.remove(account.id) }
            do {
                let readings = try await service.refresh(account.id)
                diagrams.removeAll { $0.accountID == account.id }
                diagrams.append(contentsOf: readings)
                let order = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ($1.id, $0) })
                diagrams.sort {
                    let a = order[$0.accountID] ?? 0, b = order[$1.accountID] ?? 0
                    if a != b { return a < b }
                    if $0.scopeID == "session" || $1.scopeID == "session" { return $0.scopeID == "session" && $1.scopeID != "session" }
                    if $0.scopeID == "general" || $1.scopeID == "general" { return $0.scopeID == "general" && $1.scopeID != "general" }
                    return $0.scopeID < $1.scopeID
                }
                errors[account.id] = nil
            } catch {
                // Keep the last valid readings visible and clearly stale.
                errors[account.id] = LinkedAccountError.message(for: error)
            }
        }
        accounts = await service.accounts()
        if let warning = await service.maintenanceMessage() { accountMessage = warning }
        // Preserve the former single-account experience on first normal launch.
        // An explicit empty predictor list, including an imported one, stays empty.
        if power != nil, defaults.data(forKey: "linkedDashboard.predictors") == nil,
           let legacy = accounts.first(where: \.usesLegacyHistory),
           let diagram = diagrams.first(where: { $0.accountID == legacy.id && $0.scopeID == "general" }) {
            _ = predictors.save(Predictor(accountID: legacy.id, scopeID: "general", sourceTitle: diagram.title,
                name: legacy.name, color: .mint))
        }
        // Resolve once for the complete account batch, not transient 1/2/3-tile
        // states during startup which would overwrite the saved arrangement.
        if predictors.needsImport, errors.isEmpty, !accounts.isEmpty {
            let hidden = Set(defaults.stringArray(forKey: "linkedDashboard.hidden") ?? [])
            predictors.importExisting(diagrams.filter { !hidden.contains($0.id) }.map {
                Predictor(accountID: $0.accountID, scopeID: $0.scopeID, sourceTitle: $0.title, name: title($0),
                          color: .suggested(for: provider($0)))
            })
        }
        if !predictors.needsImport { syncGeometry() }
        if let inspected { geometry.inspectedAccount = pagePredictors.firstIndex { $0.id == inspected } }
    }

    func predictorsChanged() {
        geometry.back()
        syncGeometry()
    }
    func nextPage() { page = (page + 1) % pageCount; geometry.back(); syncGeometry() }
    private func syncGeometry() {
        page = min(page, pageCount - 1)
        if geometry.count != max(1, pagePredictors.count) { geometry.setCount(pagePredictors.count) }
        defaults.set(geometry.count, forKey: "linkedDashboard.diagramCount")
    }
    func title(_ diagram: LinkedUsageDiagram) -> String {
        guard let account = accounts.first(where: { $0.id == diagram.accountID }) else { return diagram.title }
        let suffix = account.provider == "Claude" ? " · " + diagram.title : ""
        return account.name + suffix
    }

    func provider(_ diagram: LinkedUsageDiagram) -> String {
        accounts.first { $0.id == diagram.accountID }?.provider ?? ""
    }

    func rename(_ account: LinkedUsageAccount, to name: String) async -> Bool {
        do { accounts = try await service.rename(account.id, to: name); return true }
        catch { return false }
    }

    func beginAccountLogin(provider: String, replacing id: UUID?) async throws -> LinkedAccountLogin {
        guard !refreshing, !linking else { throw LinkedAccountError.busy }
        linking = true
        linkingAccountID = id
        accountMessage = nil
        do {
            let login = try await service.beginLogin(provider: provider, replacing: id)
            loginID = login.id
            return login
        } catch { linking = false; linkingAccountID = nil; throw error }
    }

    func completeAccountLogin(_ login: LinkedAccountLogin, code: String) async throws -> UUID {
        let id: UUID
        do { id = try await service.completeLogin(login.id, code: code) }
        catch {
            if case LinkedAccountError.invalidCode = error { throw error }
            await cancelAccountLogin()
            throw error
        }
        loginID = nil
        linkingAccountID = id
        defer { linking = false; linkingAccountID = nil }
        accounts = await service.accounts()
        // Finish the first read before dismissing the sheet. A usage failure
        // doesn't undo a successful login or force another browser authorization.
        // Keep background polling off this account until that first read finishes.
        await refresh(id)
        accountMessage = await service.maintenanceMessage() ?? (errors[id] == nil
            ? "Account connected and usage updated. Existing predictors are unchanged."
            : "Account connected, but usage could not be fetched. See the account error above and retry Refresh Usage.")
        return id
    }

    func cancelAccountLogin() async {
        if let loginID { await service.cancelLogin(loginID) }
        loginID = nil; linking = false; linkingAccountID = nil
    }

    func removeAccount(_ account: LinkedUsageAccount) async -> Bool {
        guard !refreshing, !linking else { return false }
        do {
            accounts = try await service.remove(account.id)
            diagrams.removeAll { $0.accountID == account.id }
            errors[account.id] = nil
            accountMessage = await service.maintenanceMessage()
                ?? "Account removed. Its predictors and history were kept. Reassign or remove those predictors separately."
            return true
        } catch { accountMessage = LinkedAccountError.message(for: error); return false }
    }
}
