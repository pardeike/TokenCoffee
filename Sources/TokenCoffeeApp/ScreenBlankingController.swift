import AppKit
import CoreGraphics
import IOKit
import OSLog
import TokenCoffeeCore

@MainActor
final class ScreenBlankingController: NSObject {
    private static let logger = Logger(subsystem: "com.pardeike.TokenCoffee", category: "DisplayPower")
    private let idleTimeProvider: () -> TimeInterval
    private let lidClosedProvider: () -> Bool
    private let action: (DisplayPowerAction) -> Void
    private let observesSystemEvents: Bool
    private let now: () -> Date
    private let cover: any ScreenBlackoutPresenting
    private var timer: Timer?
    private var mode = PowerSessionMode.off
    private var sleepThreshold: TimeInterval?
    private var coverThreshold: TimeInterval?
    private var lastAction: DisplayPowerAction?
    private var resumedAt: Date?
    private var lastLidClosed = false
    private var notificationPort: IONotificationPortRef?
    private var lidObserver: io_object_t = 0
    var hasScheduledCheck: Bool { timer != nil }

    init(
        idleTimeProvider: @escaping () -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        },
        lidClosedProvider: (() -> Bool)? = nil,
        observesSystemEvents: Bool = true,
        now: @escaping () -> Date = { Date() },
        cover: (any ScreenBlackoutPresenting)? = nil,
        action: @escaping (DisplayPowerAction) -> Void
    ) {
        self.idleTimeProvider = idleTimeProvider
        self.lidClosedProvider = lidClosedProvider ?? Self.systemLidClosed
        self.observesSystemEvents = observesSystemEvents
        self.now = now
        self.cover = cover ?? ScreenBlackoutPresenter()
        self.action = action
        super.init()
        self.cover.onDismiss = { [weak self] in
            guard let self else { return }
            self.resumedAt = self.now()
            self.lastAction = nil
            self.checkNow()
        }
    }

    func setConfiguration(powerMode: PowerSessionMode, blackoutDelay: ScreenBlackoutDelay,
                          displaySleepDelay: ScreenBlackoutDelay = .oneMinute) {
        let previous = mode
        mode = powerMode
        sleepThreshold = displaySleepDelay.inactivityThreshold
        coverThreshold = blackoutDelay.inactivityThreshold
        Self.logger.info("Configuration: mode=\(powerMode.rawValue, privacy: .public), sleep=\(displaySleepDelay.rawValue, privacy: .public), cover=\(blackoutDelay.rawValue, privacy: .public)")
        if mode == .off {
            shutdown()
            return
        }
        if previous == .off { startObserving() }
        checkNow()
    }

    func shutdown() {
        mode = .off
        stopTimer()
        cover.hide()
        send(.restore)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let notificationPort {
            if let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            if lidObserver != 0 { IOObjectRelease(lidObserver); lidObserver = 0 }
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
    }

    func checkNow() {
        guard mode != .off else { return }
        let closed = lidClosedProvider()
        if lastLidClosed && !closed { resumedAt = now() }
        lastLidClosed = closed
        let idle = min(idleTimeProvider(), resumedAt.map { max(0, now().timeIntervalSince($0)) } ?? .infinity)
        if mode == .keepAwakeDisplay {
            if let coverThreshold, idle >= coverThreshold {
                stopTimer()
                cover.show()
                send(.dimAll)
            } else {
                cover.hide()
                send(closed ? .dim : .restore)
                scheduleCheck(in: coverThreshold.map { $0 - idle })
            }
            return
        }
        cover.hide()
        if closed {
            stopTimer()
            send(.sleep)
            return
        }
        guard let threshold = sleepThreshold else {
            stopTimer()
            send(.restore)
            return
        }
        if idle >= threshold {
            stopTimer()
            send(.sleep)
        } else {
            send(.restore)
            scheduleCheck(in: threshold - idle)
        }
    }

    private func scheduleCheck(in interval: TimeInterval?) {
        guard let interval else { stopTimer(); return }
        let deadline = now().addingTimeInterval(max(0.05, interval))
        if let timer, abs(timer.fireDate.timeIntervalSince(deadline)) < 0.1 { return }
        stopTimer()
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = nil
                self?.checkNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func send(_ action: DisplayPowerAction) {
        guard lastAction != action else { return }
        lastAction = action
        Self.logger.info("Action: \(action.rawValue, privacy: .public)")
        self.action(action)
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func startObserving() {
        guard observesSystemEvents else { return }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayWoke),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(root) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, _, _ in
            guard let context else { return }
            let controller = Unmanaged<ScreenBlankingController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if controller.cover.isVisible || controller.lidClosedProvider() { controller.lastAction = nil }
                controller.checkNow()
            }
        }, Unmanaged.passUnretained(self).toOpaque(), &lidObserver)
        guard result == KERN_SUCCESS else { IONotificationPortDestroy(port); return }
        notificationPort = port
        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    @objc func displayWoke() {
        if mode == .keepAwake { resumedAt = now() }
        lastAction = nil
        checkNow()
    }

    private static func systemLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString,
            kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }
}
