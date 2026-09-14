import CryptoKit
import Foundation
import TokenCoffeeCore

actor LinkedHistoryCloudSync: LinkedHistorySync {
    private let root: URL
    private var services: [String: CloudQuotaSampleSyncService] = [:]
    init(root: URL) { self.root = root }

    func sync(account: LinkedUsageAccount, scope: String, samples: [QuotaSample], snapshot: RateLimitSnapshot) async -> LinkedHistorySyncResult {
        let legacy = account.usesLegacyHistory && scope == "general"
        let key = Self.zoneKey(accountKey: account.cloudKey, scope: scope)
        let service: CloudQuotaSampleSyncService
        if let existing = services[key] { service = existing }
        else {
            service = legacy ? CloudQuotaSampleSyncService() : CloudQuotaSampleSyncService(
                stateStore: CloudQuotaSampleSyncStateStore(fileURL: root.appendingPathComponent("cloud-state/\(CloudQuotaSampleSyncStateStore.environmentName)/\(key).json")),
                zoneName: "Account_" + key)
            services[key] = service
        }
        let result = await service.sync(localSamples: samples, currentSnapshot: snapshot)
        if legacy {
            do { try QuotaSampleStore.defaultStore().write(result.samples) }
            catch { return LinkedHistorySyncResult(samples: result.samples, message: "Local history save failed") }
        }
        let message: String
        switch result.status {
        case .localOnly: message = "Local history"
        case .syncing: message = "iCloud syncing"
        case .synced: message = "iCloud synced"
        case .rateLimited: message = "iCloud waiting"
        case .unavailable, .failed: message = "iCloud unavailable · history kept locally"
        }
        return LinkedHistorySyncResult(samples: result.samples, message: message)
    }

    static func zoneKey(accountKey: String, scope: String) -> String {
        SHA256.hash(data: Data((accountKey + ":" + scope).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
