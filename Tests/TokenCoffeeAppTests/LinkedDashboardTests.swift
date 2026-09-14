import AppKit
import XCTest
import TokenCoffeeCore
@testable import Token_Coffee

final class LinkedDashboardTests: XCTestCase {
    func testCloudHistoryKeysSeparateAccountsAndScopes() {
        let personal = LinkedHistoryCloudSync.zoneKey(accountKey: "personal", scope: "general")
        XCTAssertEqual(personal, LinkedHistoryCloudSync.zoneKey(accountKey: "personal", scope: "general"))
        XCTAssertNotEqual(personal, LinkedHistoryCloudSync.zoneKey(accountKey: "work", scope: "general"))
        XCTAssertNotEqual(personal, LinkedHistoryCloudSync.zoneKey(accountKey: "personal", scope: "session"))
        XCTAssertEqual(personal.count, 64)
    }
    func testCountChangeGrowsSelectedArrangementBeforeShrinkingCharts() {
        let original = CGSize(width: 318, height: 708)
        let screen = CGSize(width: 1800, height: 1300)
        let added = PrototypeLayout.resolveCountChange(original, retaining: .tallOverview, count: 6, fitting: screen)
        XCTAssertEqual(added.layout, .tallOverview)
        XCTAssertGreaterThan(added.size.height, original.height)
        XCTAssertLessThanOrEqual(added.size.height, screen.height)
        let removed = PrototypeLayout.resolveCountChange(added.size, retaining: added.layout, count: 5, fitting: screen)
        XCTAssertEqual(removed.layout, .tallOverview)
        XCTAssertEqual(removed.size, added.size, "Keep the user's usable size after removal")
        let constrained = PrototypeLayout.resolveCountChange(original, retaining: .tallOverview, count: 6,
            fitting: CGSize(width: 800, height: 600))
        XCTAssertLessThanOrEqual(constrained.size.height, 600)
        XCTAssertLessThanOrEqual(constrained.size.width, 800)
    }

    @MainActor func testNativeListMoveInsertionSemanticsAndPersistence() throws {
        let suite = "PredictorTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PredictorStore(defaults: defaults)
        let items = (0..<5).map { Predictor(accountID: UUID(), scopeID: "general", name: "\($0)", color: .blue) }
        items.forEach { XCTAssertTrue(store.save($0)) }
        store.move(from: IndexSet(integer: 0), to: 5)
        XCTAssertEqual(store.items.map(\.name), ["1", "2", "3", "4", "0"])
        store.move(from: IndexSet([1, 3]), to: 0)
        XCTAssertEqual(store.items.map(\.name), ["2", "4", "1", "3", "0"])
        XCTAssertEqual(PredictorStore(defaults: defaults).items, store.items)
        store.move(from: IndexSet(integer: 10), to: 0)
        XCTAssertEqual(store.items.count, 5)
    }

    @MainActor func testNativeTableDragUsesStableIdentityAndRejectsUnsavedEdits() throws {
        let item = Predictor(accountID: UUID(), scopeID: "general", name: "Personal", color: .blue)
        var view = PredictorTable(items: [item], selected: item.id, canMove: true,
            subtitle: { _ in "Codex" }, select: { _ in }, move: { _, _, _ in })
        let coordinator = view.makeCoordinator()
        let writer = try XCTUnwrap(coordinator.tableView(NSTableView(), pasteboardWriterForRow: 0) as? NSPasteboardItem)
        XCTAssertEqual(writer.string(forType: PredictorTable.Coordinator.pasteboardType), item.id.uuidString)
        XCTAssertNil(coordinator.tableView(NSTableView(), pasteboardWriterForRow: 1))
        view = PredictorTable(items: [item], selected: item.id, canMove: false,
            subtitle: { _ in "Codex" }, select: { _ in }, move: { _, _, _ in })
        coordinator.parent = view
        XCTAssertNil(coordinator.tableView(NSTableView(), pasteboardWriterForRow: 0))
    }

    @MainActor func testManagementWindowIsFixedAndIndependentOfDashboardGeometry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"accounts":[]}"#.utf8).write(to: root.appendingPathComponent("accounts.json"))
        let suite = "PredictorTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = try LinkedDashboardModel(service: LinkedUsageService(root: root), defaults: defaults)
        let original = model.geometry.windowSize
        let controller = ManagementWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.miniaturizable))
        XCTAssertEqual(window.contentMinSize, ManagementWindowController.contentSize)
        XCTAssertEqual(window.contentMaxSize, ManagementWindowController.contentSize)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, ManagementWindowController.contentSize)
        XCTAssertEqual(model.geometry.windowSize, original)
        XCTAssertEqual(controller.state.section, .predictors)
        let loginSheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(loginSheet)
        XCTAssertFalse(controller.windowShouldClose(window), "Closing the parent must not strand a pending login")
        window.endSheet(loginSheet)
    }
    func testFiveAndSixChartsFitWithoutLosingAnyChart() {
        let screen = CGSize(width: 1800, height: 1300)
        for count in 5...6 {
            for layout in PrototypeLayout.allCases {
                let result = PrototypeLayout.resolve(layout.size, retaining: layout, count: count, fitting: screen)
                for primary in 0..<count {
                    let tiles = result.layout.tiles(count: count, primary: primary, secondary: (primary + 1) % count, in: result.size)
                    XCTAssertEqual(Set(tiles.map(\.id)), Set(0..<count))
                    for (i, tile) in tiles.enumerated() {
                        XCTAssertTrue(CGRect(origin: .zero, size: result.size).contains(tile.frame))
                        XCTAssertGreaterThanOrEqual(tile.frame.width, tile.kind.minimumSize.width - 0.01)
                        XCTAssertGreaterThanOrEqual(tile.frame.height, tile.kind.minimumSize.height - 0.01)
                        XCTAssertTrue(tile.kind.aspectRange.contains(tile.frame.width / tile.frame.height)
                            || abs(tile.frame.width / tile.frame.height - tile.kind.aspectRange.lowerBound) < 0.001
                            || abs(tile.frame.width / tile.frame.height - tile.kind.aspectRange.upperBound) < 0.001)
                        for peer in tiles.dropFirst(i + 1) { XCTAssertFalse(tile.frame.intersects(peer.frame)) }
                    }
                }
            }
        }
        let result = PrototypeLayout.resolve(CGSize(width: 900, height: 650), retaining: .overview, count: 5, fitting: screen)
        XCTAssertEqual(result.size, CGSize(width: 900, height: 650))
        let tiles = result.layout.tiles(count: 5, primary: 0, secondary: 1, in: result.size)
        XCTAssertEqual(tiles[0].frame.width, 876)
        XCTAssertEqual(tiles[1].frame.width, tiles[2].frame.width)
        XCTAssertEqual(tiles[3].frame.width, tiles[4].frame.width)
    }

    @MainActor func testMissingSessionUsesDashesButZeroIsARealReading() {
        let window = RateLimitWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: nil)
        for primary in [nil, window] {
            let snapshot = RateLimitSnapshot(limitId: "codex", limitName: nil, primary: primary, secondary: window,
                credits: nil, planType: nil, rateLimitReachedType: nil)
            let tile = UsageTileView(title: "Personal", provider: "Codex", snapshot: snapshot, samples: [],
                projection: QuotaProjectionEngine.make(snapshot: snapshot, samples: []), now: Date(),
                kind: .detail, status: nil, prominent: false, inspecting: false)
            XCTAssertEqual(tile.sessionText, primary == nil ? "--" : "5h 0%")
        }
    }

    @MainActor func testRestoredDiagramCountIsAvailableBeforeWindowRestoration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"accounts":[]}"#.utf8).write(to: root.appendingPathComponent("accounts.json"))
        let name = "LinkedDashboardTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(3, forKey: "linkedDashboard.diagramCount")
        defaults.set(["account:general"], forKey: "linkedDashboard.hidden")
        let model = try LinkedDashboardModel(service: LinkedUsageService(root: root), defaults: defaults)
        XCTAssertEqual(model.geometry.count, 3)
        XCTAssertTrue(model.predictors.needsImport)
        XCTAssertEqual(model.geometry.primary, 0)
        XCTAssertFalse(model.geometry.visible)
    }

    @MainActor func testPredictorsPersistIndependentNamesColorsOrderAndEmptyList() throws {
        let suite = "PredictorTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PredictorStore(defaults: defaults)
        XCTAssertFalse(store.needsImport)
        let account = UUID()
        let first = Predictor(accountID: account, scopeID: "session", name: "Five hours", color: .purple)
        var second = Predictor(accountID: account, scopeID: "general", name: "Weekly", color: .mint)
        XCTAssertTrue(store.save(first))
        XCTAssertTrue(store.save(second))
        store.move(second.id, by: -1)
        XCTAssertEqual(store.items.map(\.id), [second.id, first.id])
        second.name = "Personal allowance"
        second.color = .pink
        XCTAssertTrue(store.save(second))
        let restored = PredictorStore(defaults: defaults)
        XCTAssertEqual(restored.items, [second, first])
        XCTAssertEqual(restored.items.map(\.accountID), [account, account])
        XCTAssertEqual(restored.items.map(\.scopeID), ["general", "session"])
        restored.remove(first.id)
        restored.remove(second.id)
        let empty = PredictorStore(defaults: defaults)
        XCTAssertEqual(empty.items, [])
        XCTAssertFalse(empty.needsImport)
        empty.importExisting([first])
        XCTAssertTrue(empty.items.isEmpty, "An intentionally empty dashboard must not repopulate")
    }

    @MainActor func testPredictorImportOnlyOnceAndDuplicateSourcesHaveIndependentIdentity() throws {
        let suite = "PredictorTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(5, forKey: "linkedDashboard.diagramCount")
        let store = PredictorStore(defaults: defaults)
        let first = Predictor(accountID: UUID(), scopeID: "session", name: "One", color: .blue)
        let second = Predictor(accountID: first.accountID, scopeID: "session", name: "Two", color: .orange)
        store.importExisting([first])
        store.importExisting([second])
        XCTAssertEqual(store.items, [first])
        XCTAssertTrue(store.save(second))
        store.move(first.id, by: -1)
        store.move(second.id, by: 1)
        XCTAssertEqual(store.items, [first, second])
        store.remove(first.id)
        XCTAssertEqual(store.items, [second])
        for name in ["", "  ", "line\nbreak", String(repeating: "a", count: 61)] {
            var invalid = second
            invalid.name = name
            XCTAssertFalse(store.save(invalid))
        }
        XCTAssertEqual(store.items, [second])
    }

    @MainActor func testCorruptPredictorListIsNotSilentlyOverwritten() throws {
        let suite = "PredictorTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data("not json".utf8)
        defaults.set(data, forKey: "linkedDashboard.predictors")
        let store = PredictorStore(defaults: defaults)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.save(Predictor(accountID: UUID(), scopeID: "general", name: "Test", color: .blue)))
        XCTAssertEqual(defaults.data(forKey: "linkedDashboard.predictors"), data)
    }

    @MainActor func testUnavailablePredictorsKeepTheirSlotsAndPageOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"accounts":[]}"#.utf8).write(to: root.appendingPathComponent("accounts.json"))
        let suite = "PredictorTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = try LinkedDashboardModel(service: LinkedUsageService(root: root), defaults: defaults)
        let items = (0..<7).map { Predictor(accountID: UUID(), scopeID: "general", sourceTitle: "General", name: "Chart \($0)", color: .blue) }
        items.forEach { XCTAssertTrue(model.predictors.save($0)) }
        model.predictorsChanged()
        XCTAssertEqual(model.pageCount, 2)
        XCTAssertEqual(model.pagePredictors, Array(items.prefix(6)))
        XCTAssertEqual(model.geometry.count, 6)
        XCTAssertNil(model.diagram(for: items[0]))
        XCTAssertTrue(model.sources.isEmpty, "Removed accounts keep their tiles but must not be offered as new data sources")
        model.nextPage()
        XCTAssertEqual(model.pagePredictors, [items[6]])
        model.predictors.remove(items[6].id)
        model.predictorsChanged()
        XCTAssertEqual(model.page, 0)
        XCTAssertEqual(model.geometry.count, 6)
        XCTAssertEqual(model.pagePredictors, Array(items.prefix(6)))
    }
}
