import XCTest
@testable import Token_Coffee

final class PrototypeTests: XCTestCase {
    func testEveryCompositionKeepsAllAccountsVisibleWithoutOverlap() {
        for layout in PrototypeLayout.allCases {
            for count in 1...4 {
                for primary in 0..<count {
                    let tiles = layout.tiles(count: count, primary: primary, secondary: (primary + 1) % count)
                    XCTAssertEqual(Set(tiles.map(\.id)), Set(0..<count))
                    for (index, tile) in tiles.enumerated() {
                        XCTAssertGreaterThanOrEqual(tile.frame.width, 120, "\(layout) \(count)")
                        XCTAssertGreaterThanOrEqual(tile.frame.height, 44, "\(layout) \(count)")
                        XCTAssertTrue(CGRect(origin: .zero, size: layout.size).contains(tile.frame))
                        for peer in tiles.dropFirst(index + 1) { XCTAssertFalse(tile.frame.intersects(peer.frame)) }
                    }
                }
            }
        }
    }
    func testDefaultsRemainUsableAndScreenLimitsAreRespected() {
        for layout in PrototypeLayout.allCases {
            let result = PrototypeLayout.resolve(layout.size, retaining: layout, count: 4, fitting: CGSize(width: 1400, height: 1000))
            XCTAssertEqual(result.layout, layout)
            XCTAssertEqual(result.size.width, layout.size.width, accuracy: 0.01)
            XCTAssertEqual(result.size.height, layout.size.height, accuracy: 0.01)
        }
        let candidate = PrototypeLayout.resolve(CGSize(width: 2000, height: 2000), retaining: .overview,
                                               count: 4, fitting: CGSize(width: 800, height: 600))
        XCTAssertLessThanOrEqual(candidate.size.width, 800.01)
        XCTAssertLessThanOrEqual(candidate.size.height, 600.01)
    }
    func testSmallResizeChangesKeepCurrentCandidate() {
        for layout in PrototypeLayout.allCases {
            for delta in [-2.0, 2.0] {
                XCTAssertEqual(PrototypeLayout.resolve(CGSize(width: layout.size.width + delta, height: layout.size.height - delta),
                                                       retaining: layout, count: 4, fitting: CGSize(width: 1400, height: 1000)).layout, layout)
            }
        }
    }
    func testLargerGridAndStripsKeepExactDraggedSize() {
        for (layout, size) in [(PrototypeLayout.overview, CGSize(width: 900, height: 650)),
                               (.strip, CGSize(width: 1200, height: 240)),
                               (.tallOverview, CGSize(width: 500, height: 1100))] {
            let result = PrototypeLayout.resolve(size, retaining: layout, count: 4, fitting: CGSize(width: 1800, height: 1300))
            XCTAssertEqual(result.layout, layout)
            XCTAssertEqual(result.size, size)
        }
    }
    func testTallGridReflowsWithoutChangingWindowSize() {
        let size = CGSize(width: 640, height: 1100)
        let result = PrototypeLayout.resolve(size, retaining: .overview, count: 4, fitting: CGSize(width: 1800, height: 1300))
        XCTAssertNotEqual(result.layout, .overview)
        XCTAssertEqual(result.size, size)
        for tile in result.layout.tiles(count: 4, primary: 0, secondary: 1, in: result.size) {
            XCTAssertGreaterThanOrEqual(tile.frame.width / tile.frame.height, 1)
        }
    }
    func testShrinkingCanReachPocket() {
        let result = PrototypeLayout.resolve(PrototypeLayout.pocket.size, retaining: .overview, count: 4,
                                             fitting: CGSize(width: 1800, height: 1300))
        XCTAssertEqual(result.layout, .pocket)
        XCTAssertEqual(result.size, PrototypeLayout.pocket.size)
    }
    func testCorrectedSizesRemainValidAcrossCountsAndRoles() {
        let screen = CGSize(width: 1800, height: 1300)
        for count in 1...4 {
            for width in stride(from: 280, through: 1800, by: 190) {
                for height in stride(from: 144, through: 1300, by: 140) {
                    let proposed = CGSize(width: width, height: height)
                    let result = PrototypeLayout.resolve(proposed, retaining: .overview, count: count, fitting: screen)
                    let again = PrototypeLayout.resolve(result.size, retaining: result.layout, count: count, fitting: screen)
                    XCTAssertEqual(again.layout, result.layout)
                    XCTAssertEqual(again.size.width, result.size.width, accuracy: 0.01)
                    XCTAssertEqual(again.size.height, result.size.height, accuracy: 0.01)
                    for primary in 0..<count {
                        let tiles = result.layout.tiles(count: count, primary: primary, secondary: (primary + 1) % count, in: result.size)
                        for tile in tiles {
                            XCTAssertGreaterThanOrEqual(tile.frame.width, tile.kind.minimumSize.width - 0.01)
                            XCTAssertGreaterThanOrEqual(tile.frame.height, tile.kind.minimumSize.height - 0.01)
                            let aspect = tile.frame.width / tile.frame.height
                            XCTAssertGreaterThanOrEqual(aspect, tile.kind.aspectRange.lowerBound - 0.001)
                            XCTAssertLessThanOrEqual(aspect, tile.kind.aspectRange.upperBound + 0.001)
                        }
                    }
                }
            }
        }
    }
    func testScreenExactlyAtMinimumCannotReturnOversizedFrame() {
        let result = PrototypeLayout.resolve(CGSize(width: 2000, height: 2000), retaining: .overview,
                                             count: 4, fitting: PrototypeLayout.pocket.size)
        XCTAssertEqual(result.layout, .pocket)
        XCTAssertEqual(result.size, PrototypeLayout.pocket.size)
    }
    @MainActor func testCornerTargetsDoNotInterceptControlsOrGraphs() {
        let view = PrototypeResizeCorners(frame: CGRect(x: 0, y: 0, width: 900, height: 650))
        for point in [CGPoint(x: 2, y: 2), CGPoint(x: 898, y: 2), CGPoint(x: 2, y: 648), CGPoint(x: 898, y: 648)] {
            XCTAssertTrue(view.hitTest(point) === view)
        }
        XCTAssertNil(view.hitTest(CGPoint(x: 450, y: 325)))
        XCTAssertNil(view.hitTest(CGPoint(x: 876, y: 628)))
    }
    @MainActor func testBackPreservesExplicitResizeAndResumesOverview() {
        let model = PrototypeModel()
        model.inspect(2)
        model.layout = .strip
        model.windowSize = CGSize(width: 1200, height: 240)
        XCTAssertEqual(model.tiles.map(\.id), [2])
        model.back()
        XCTAssertNil(model.inspectedAccount)
        XCTAssertEqual(model.layout, .strip)
        XCTAssertEqual(model.windowSize, CGSize(width: 1200, height: 240))
        XCTAssertEqual(model.tiles.count, 4)
        model.inspect(3)
        model.setCount(2)
        XCTAssertNil(model.inspectedAccount)
    }
    @MainActor func testActivityOnlyMovesWhenVisibleUnpausedAndInFocusLayouts() {
        let model = PrototypeModel()
        model.advance(by: 60)
        XCTAssertEqual(model.primary, 0)
        model.visible = true
        model.hovering = true
        model.advance(by: 60)
        XCTAssertEqual(model.primary, 0)
        model.hovering = false
        model.advance(by: 30)
        XCTAssertEqual(model.primary, 1)
        model.layout = .overview
        model.advance(by: 60)
        XCTAssertEqual(model.primary, 1)
        model.layout = .gallery
        model.inspect(0)
        model.advance(by: 60)
        XCTAssertEqual(model.primary, 1)
        model.back()
        model.scenario = .quiet
        model.advance(by: 60)
        XCTAssertEqual(model.primary, 1)
    }
}
