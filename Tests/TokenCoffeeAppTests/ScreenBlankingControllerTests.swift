import AppKit
import TokenCoffeeCore
import XCTest
@testable import Token_Coffee

@MainActor
final class ScreenBlankingControllerTests: XCTestCase {
    func testMacAwakeUsesItsOwnDisplaySleepDeadline() {
        var idle: TimeInterval = 59.99
        var actions: [DisplayPowerAction] = []
        let cover = FakeScreenBlackoutPresenter()
        let controller = ScreenBlankingController(idleTimeProvider: { idle }, lidClosedProvider: { false },
            observesSystemEvents: false, cover: cover, action: { actions.append($0) })
        defer { controller.shutdown() }

        controller.setConfiguration(powerMode: .keepAwake, blackoutDelay: .off, displaySleepDelay: .oneMinute)
        XCTAssertTrue(controller.hasScheduledCheck)
        idle = 60
        controller.checkNow()
        XCTAssertEqual(actions, [.restore, .sleep])
        XCTAssertFalse(cover.isVisible)
        XCTAssertFalse(controller.hasScheduledCheck)
        for _ in 0..<10 { controller.checkNow() }
        XCTAssertEqual(actions, [.restore, .sleep], "Idle state must issue no redundant actions")
    }

    func testMacAwakeSleepsDisplayImmediatelyWhenLidCloses() {
        var closed = false
        var actions: [DisplayPowerAction] = []
        let controller = ScreenBlankingController(idleTimeProvider: { 0 }, lidClosedProvider: { closed },
            observesSystemEvents: false, cover: FakeScreenBlackoutPresenter(), action: { actions.append($0) })
        defer { controller.shutdown() }
        controller.setConfiguration(powerMode: .keepAwake, blackoutDelay: .off, displaySleepDelay: .off)
        closed = true
        controller.checkNow()
        XCTAssertEqual(actions, [.restore, .sleep])
        XCTAssertFalse(controller.hasScheduledCheck)
    }

    func testScreenOnDimsClosedLidWithoutSleepingOrCoveringWhenCoverIsOff() {
        var closed = false
        var actions: [DisplayPowerAction] = []
        let cover = FakeScreenBlackoutPresenter()
        let controller = ScreenBlankingController(idleTimeProvider: { 600 }, lidClosedProvider: { closed },
            observesSystemEvents: false, cover: cover, action: { actions.append($0) })
        defer { controller.shutdown() }
        controller.setConfiguration(powerMode: .keepAwakeDisplay, blackoutDelay: .off)
        closed = true
        controller.checkNow()
        controller.checkNow()
        closed = false
        controller.checkNow()
        XCTAssertEqual(actions, [.restore, .dim, .restore])
        XCTAssertFalse(actions.contains(.sleep))
        XCTAssertFalse(cover.isVisible)
        XCTAssertFalse(controller.hasScheduledCheck)
    }

    func testOptionalCoverDimsIdleScreensAndInputRestoresThem() {
        var idle: TimeInterval = 60
        var actions: [DisplayPowerAction] = []
        let cover = FakeScreenBlackoutPresenter()
        let controller = ScreenBlankingController(idleTimeProvider: { idle }, lidClosedProvider: { false },
            observesSystemEvents: false, cover: cover, action: { actions.append($0) })
        defer { controller.shutdown() }
        controller.setConfiguration(powerMode: .keepAwakeDisplay, blackoutDelay: .oneMinute)
        XCTAssertTrue(cover.isVisible)
        XCTAssertEqual(actions, [.dimAll])
        XCTAssertFalse(controller.hasScheduledCheck)
        for _ in 0..<10 { controller.checkNow() }
        XCTAssertEqual(actions, [.dimAll])
        idle = 0
        cover.dismiss()
        XCTAssertFalse(cover.isVisible)
        XCTAssertEqual(actions.last, .restore)
        XCTAssertTrue(controller.hasScheduledCheck)
    }

    func testDisplayWakeAllowsAFullIdleDelayBeforeSleepingAgain() {
        var date = Date(timeIntervalSince1970: 1_000)
        var actions: [DisplayPowerAction] = []
        let controller = ScreenBlankingController(idleTimeProvider: { 600 }, lidClosedProvider: { false },
            observesSystemEvents: false, now: { date }, cover: FakeScreenBlackoutPresenter(),
            action: { actions.append($0) })
        defer { controller.shutdown() }
        controller.setConfiguration(powerMode: .keepAwake, blackoutDelay: .off)
        XCTAssertEqual(actions.last, .sleep)
        controller.displayWoke()
        XCTAssertEqual(actions.last, .restore)
        date.addTimeInterval(60)
        controller.checkNow()
        XCTAssertEqual(actions.last, .sleep)
    }

    func testOffRestoresBrightnessAndRemovesAllScheduledWork() {
        var actions: [DisplayPowerAction] = []
        let cover = FakeScreenBlackoutPresenter()
        let controller = ScreenBlankingController(idleTimeProvider: { 60 }, lidClosedProvider: { true },
            observesSystemEvents: false, cover: cover, action: { actions.append($0) })
        controller.setConfiguration(powerMode: .keepAwakeDisplay, blackoutDelay: .oneMinute)
        controller.setConfiguration(powerMode: .off, blackoutDelay: .oneMinute)
        XCTAssertEqual(actions.last, .restore)
        XCTAssertFalse(cover.isVisible)
        XCTAssertFalse(controller.hasScheduledCheck)
    }

    func testSleepAndCoverMenusHaveIndependentMeaning() throws {
        let sleep = PanelControlMenu.displaySleepMenuItem(selectedDelay: .oneMinute) { _ in }
        let cover = PanelControlMenu.screenBlackoutMenuItem(selectedDelay: .off) { _ in }
        XCTAssertEqual(sleep.title, "Display sleep")
        XCTAssertEqual(try XCTUnwrap(sleep.submenu).items.first?.title, "Never")
        XCTAssertEqual(cover.title, "Screen blackout")
        XCTAssertEqual(try XCTUnwrap(cover.submenu).items.first?.title, "Off")
        XCTAssertEqual(sleep.submenu?.items[1].state, .on)
        XCTAssertEqual(cover.submenu?.items[0].state, .on)
    }
}

@MainActor
private final class FakeScreenBlackoutPresenter: ScreenBlackoutPresenting {
    private(set) var isVisible = false
    var onDismiss: (() -> Void)?
    func show() { isVisible = true }
    func hide() { isVisible = false }
    func dismiss() { hide(); onDismiss?() }
}
