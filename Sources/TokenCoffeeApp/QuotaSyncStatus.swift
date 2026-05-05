import Foundation

enum QuotaSyncStatus: Equatable, Sendable {
    case localOnly
    case syncing
    case synced(Date)
    case unavailable(String)
    case failed(String)
}
