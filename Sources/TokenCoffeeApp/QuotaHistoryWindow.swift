import Foundation

enum QuotaHistoryWindow {
    static let duration: TimeInterval = 7 * 24 * 60 * 60

    static func startDate(resetDate: Date) -> Date {
        resetDate.addingTimeInterval(-duration)
    }
}
