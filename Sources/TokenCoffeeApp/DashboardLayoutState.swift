import Combine
import Foundation
import TokenCoffeeCore

/// Geometry and navigation shared by real and dummy dashboards, not their data.
@MainActor
class DashboardLayoutState: ObservableObject {
    @Published var layout: PrototypeLayout = .gallery
    @Published var windowSize = PrototypeLayout.gallery.size
    @Published var previewSize = PrototypeLayout.gallery.size
    @Published var resizing = false
    @Published var count = 4
    @Published var primary = 0
    @Published var secondary = 1
    @Published var inspectedAccount: Int?
    @Published var showingAbout = false
    @Published var hovering = false
    @Published var menuOpen = false
    @Published var visible = false
    @Published var powerMode: PowerSessionMode = .off
    private var clockTask: Task<Void, Never>?
    private var elapsed: TimeInterval = 0

    var paused: Bool { resizing || hovering || menuOpen || inspectedAccount != nil || showingAbout || !visible }
    var tiles: [PrototypeTile] { layout.tiles(count: count, primary: primary, secondary: secondary, detail: inspectedAccount,
        in: resizing ? previewSize : windowSize) }
    func start() {
        stop()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                self?.advance(by: 1)
            }
        }
    }
    func stop() { clockTask?.cancel(); clockTask = nil }
    func advance(by interval: TimeInterval) {
        guard !paused, layout.followsActivity, count > 1 else { return }
        elapsed += interval
        if elapsed >= 30 {
            primary = (primary + 1) % count
            secondary = (primary + 1) % count
            elapsed = 0
        }
    }
    func setCount(_ value: Int) {
        count = min(6, max(1, value))
        primary = min(primary, count - 1)
        secondary = count > 1 ? (primary + 1) % count : primary
        if let inspectedAccount, inspectedAccount >= count { self.inspectedAccount = nil }
        elapsed = 0
    }
    func inspect(_ id: Int) { inspectedAccount = id; showingAbout = false }
    func back() { inspectedAccount = nil; showingAbout = false }
}
