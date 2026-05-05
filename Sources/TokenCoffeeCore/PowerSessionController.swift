import Foundation
import IOKit
import IOKit.pwr_mgt

public enum PowerSessionMode: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case off
    case keepAwake
    case keepAwakeDisplay

    public var id: String { rawValue }
}

public enum PowerAssertionKind: Equatable, Sendable {
    case preventIdleSystemSleep
    case preventIdleDisplaySleep
}

public protocol PowerAssertionClient: AnyObject {
    func createAssertion(kind: PowerAssertionKind, name: String) throws -> UInt32
    func releaseAssertion(_ id: UInt32)
    func setClamshellSleepDisabled(_ disabled: Bool) throws
}

public final class PowerSessionController {
    private let client: PowerAssertionClient
    private var systemAssertion: UInt32?
    private var displayAssertion: UInt32?
    private var clamshellDisabled = false

    public init(client: PowerAssertionClient = IOKitPowerAssertionClient()) {
        self.client = client
    }

    deinit {
        releaseAssertions()
        if clamshellDisabled {
            try? client.setClamshellSleepDisabled(false)
        }
    }

    public func apply(mode: PowerSessionMode) throws {
        releaseAssertions()

        if mode == .off {
            try setClamshellDisabled(false)
            TokenCoffeeDefaults.setClosedDisplayModeEnabled(false)
            return
        }

        systemAssertion = try client.createAssertion(
            kind: .preventIdleSystemSleep,
            name: "Token Coffee - System"
        )

        if mode == .keepAwakeDisplay {
            displayAssertion = try client.createAssertion(
                kind: .preventIdleDisplaySleep,
                name: "Token Coffee - Display"
            )
        }

        try setClamshellDisabled(true)
        TokenCoffeeDefaults.setClosedDisplayModeEnabled(true)
    }

    private func releaseAssertions() {
        if let displayAssertion {
            client.releaseAssertion(displayAssertion)
            self.displayAssertion = nil
        }
        if let systemAssertion {
            client.releaseAssertion(systemAssertion)
            self.systemAssertion = nil
        }
    }

    private func setClamshellDisabled(_ disabled: Bool) throws {
        guard clamshellDisabled != disabled else {
            return
        }
        try client.setClamshellSleepDisabled(disabled)
        clamshellDisabled = disabled
    }
}

public final class IOKitPowerAssertionClient: PowerAssertionClient {
    public enum IOKitPowerError: Error, Equatable, LocalizedError, Sendable {
        case assertionCreateFailed(Int32)
        case rootDomainUnavailable
        case rootDomainOpenFailed(Int32)
        case clamshellCallFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case let .assertionCreateFailed(code):
                "Power assertion creation failed with IOKit code \(code)."
            case .rootDomainUnavailable:
                "IOPMrootDomain is unavailable."
            case let .rootDomainOpenFailed(code):
                "Could not open IOPMrootDomain, IOKit code \(code)."
            case let .clamshellCallFailed(code):
                "Could not change clamshell sleep state, IOKit code \(code)."
            }
        }
    }

    public init() {}

    public func createAssertion(kind: PowerAssertionKind, name: String) throws -> UInt32 {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            assertionType(for: kind),
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            throw IOKitPowerError.assertionCreateFailed(result)
        }
        return assertionID
    }

    public func releaseAssertion(_ id: UInt32) {
        IOPMAssertionRelease(id)
    }

    public func setClamshellSleepDisabled(_ disabled: Bool) throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else {
            throw IOKitPowerError.rootDomainUnavailable
        }
        defer { IOObjectRelease(service) }

        var connection = io_connect_t()
        let openResult = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard openResult == KERN_SUCCESS else {
            throw IOKitPowerError.rootDomainOpenFailed(openResult)
        }
        defer { IOServiceClose(connection) }

        var input = [UInt64(disabled ? 1 : 0)]
        var outputCount: UInt32 = 0
        let callResult = IOConnectCallScalarMethod(
            connection,
            UInt32(kPMSetClamshellSleepState),
            &input,
            UInt32(input.count),
            nil,
            &outputCount
        )

        guard callResult == KERN_SUCCESS else {
            throw IOKitPowerError.clamshellCallFailed(callResult)
        }
    }

    private func assertionType(for kind: PowerAssertionKind) -> CFString {
        switch kind {
        case .preventIdleSystemSleep:
            kIOPMAssertPreventUserIdleSystemSleep as CFString
        case .preventIdleDisplaySleep:
            kIOPMAssertPreventUserIdleDisplaySleep as CFString
        }
    }
}

public enum TokenCoffeeDefaults {
    public static let domain = "com.pardeike.TokenCoffee"
    public static let closedDisplayModeEnabledKey = "closedDisplayModeEnabled"

    public static func setClosedDisplayModeEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: closedDisplayModeEnabledKey)
    }
}
