import AppKit
import XCTest
@testable import Token_Coffee

final class DashboardScreenPlacementTests: XCTestCase {
    func testEachDisplayRetainsItsOwnFrameAndLayoutAcrossReloadAndRearrangement() throws {
        let suite = "DashboardScreenPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let left = NSRect(x: -2560, y: 0, width: 2560, height: 1440)
        let right = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let first = DashboardScreenPlacement(frame: NSRect(x: -2300, y: 700, width: 900, height: 600), layout: .gallery)
        let second = DashboardScreenPlacement(frame: NSRect(x: 300, y: 400, width: 1000, height: 700), layout: .overview)
        first.save(defaults: defaults, key: "left", screenFrame: left)
        second.save(defaults: defaults, key: "right", screenFrame: right)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(DashboardScreenPlacement(defaults: reloaded, key: "left", screenFrame: left)?.frame, first.frame)
        XCTAssertEqual(DashboardScreenPlacement(defaults: reloaded, key: "right", screenFrame: right)?.frame, second.frame)
        XCTAssertEqual(DashboardScreenPlacement(defaults: reloaded, key: "left", screenFrame: left)?.layout, .gallery)
        XCTAssertEqual(DashboardScreenPlacement(defaults: reloaded, key: "right", screenFrame: right)?.layout, .overview)
        let moved = NSRect(x: 2560, y: 300, width: 2560, height: 1440)
        XCTAssertEqual(DashboardScreenPlacement(defaults: reloaded, key: "left", screenFrame: moved)?.frame,
                       first.frame.offsetBy(dx: 5120, dy: 300))
        XCTAssertNil(DashboardScreenPlacement(defaults: reloaded, key: "new", screenFrame: right))
    }

    func testNewDisplayStartsAtTopRightAfterFittingSize() {
        let visible = NSRect(x: -1440, y: 40, width: 1440, height: 830)
        let placement = DashboardScreenPlacement.topRight(size: CGSize(width: 2000, height: 1600),
            layout: .gallery, visibleFrame: visible, count: 6)
        XCTAssertEqual(placement.frame.maxX, visible.maxX - 8, accuracy: 0.01)
        XCTAssertEqual(placement.frame.maxY, visible.maxY - 8, accuracy: 0.01)
        XCTAssertTrue(visible.contains(placement.frame))
    }

    func testSmallerDisplayKeepsRestoredWindowInsideVisibleArea() {
        let visible = NSRect(x: -1440, y: 40, width: 1440, height: 830)
        let placement = DashboardScreenPlacement(frame: NSRect(x: 2000, y: 1500, width: 2000, height: 1600), layout: .gallery)
        let fitted = placement.fitted(to: visible, count: 6)
        XCTAssertTrue(visible.insetBy(dx: 7.99, dy: 7.99).contains(fitted.frame))
        XCTAssertEqual(fitted.layout.tiles(count: 6, primary: 0, secondary: 1, in: fitted.frame.size).count, 6)
    }
}
