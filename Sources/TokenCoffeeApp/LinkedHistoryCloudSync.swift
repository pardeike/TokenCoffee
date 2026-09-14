import CryptoKit
import Foundation
import TokenCoffeeCore

actor LinkedHistoryCloudSync: LinkedHistorySync {
    private let root: URL
    private var services: [String: CloudQuotaSampleSyncService] = [:]
    init(root: URL) { self.root = root }

    func sync(account: LinkedUsageAccount, scope: String, samples: [QuotaSample], snapshot: RateLimitSnapshot) async -> LinkedHistorySyncResult {
        let key = Self.zoneKey(accountKey: account.cloudKey, scope: scope)
        let service: CloudQuotaSampleSyncService
        if let existing = services[key] { service = existing }
        else {
            service = CloudQuotaSampleSyncService(
                stateStore: CloudQuotaSampleSyncStateStore(fileURL: root.appendingPathComponent("cloud-state/\(CloudQuotaSampleSyncStateStore.environmentName)/\(key).json")),
                zoneName: Self.zoneName(account: account, scope: scope))
            services[key] = service
        }
        let result = await service.sync(localSamples: samples, currentSnapshot: snapshot)
        // Keep the existing local consumer path, never the unowned legacy cloud
        // zone. The same provider account uses the same zone on every device.
        if account.usesLegacyHistory && scope == "general" {
            do {
                try Self.mirrorLegacyFile(samples: result.samples, store: QuotaSampleStore.defaultStore(),
                    archive: root.appendingPathComponent("legacy-unattributed-history.jsonl"))
            }
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

    static func zoneName(account: LinkedUsageAccount, scope: String) -> String {
        "Account_" + zoneKey(accountKey: account.cloudKey, scope: scope)
    }

    static func mirrorLegacyFile(samples: [QuotaSample], store: QuotaSampleStore, archive: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: store.fileURL.path), !manager.fileExists(atPath: archive.path) {
            try manager.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: store.fileURL, to: archive)
        }
        try store.write(samples)
    }
}
