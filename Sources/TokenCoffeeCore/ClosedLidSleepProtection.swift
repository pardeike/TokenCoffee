import Foundation
import Darwin
import IOKit
import Security
import OSLog

public enum DisplayPowerAction: String, Sendable {
    case sleep = "SLEEP"
    case dim = "DIM"
    case dimAll = "DIM_ALL"
    case restore = "RESTORE"
    case wake = "WAKE"
}

/// The launch agent owns its power changes until the connection closes or the app exits.
@MainActor
public final class ClosedLidSleepProtection {
    nonisolated public static let agentIdentifier = "com.pardeike.TokenCoffee.SleepGuard"
    nonisolated private static let logger = Logger(subsystem: "com.pardeike.TokenCoffee", category: "SleepAgent")
    private final class Connection: @unchecked Sendable {
        let handle: FileHandle
        var expectedStop = false // Accessed only on the main actor.
        init(_ handle: FileHandle) { self.handle = handle }
    }
    private var connection: Connection?
    private var completion: Task<Void, Error>?
    private let socketURL: URL
    private let verifiesPeer: Bool
    private var ready = false
    private var pendingDisplayAction: DisplayPowerAction?
    public var onUnexpectedExit: (() -> Void)?
    public var onDisplayFailure: (() -> Void)?

    public init() {
        socketURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".sleep-agent.sock")
        verifiesPeer = true
    }

    init(socketURL: URL, verifiesPeer: Bool) {
        self.socketURL = socketURL
        self.verifiesPeer = verifiesPeer
    }

    isolated deinit {
        if let connection { shutdown(connection.handle.fileDescriptor, SHUT_RDWR) }
    }

    public enum Failure: LocalizedError {
        case setupRequired, startFailed, stoppedUnexpectedly, displayUnavailable

        public var errorDescription: String? {
            switch self {
            case .setupRequired:
                "Sleep protection needs setup. Ordinary awake mode is still active."
            case .startFailed:
                "Sleep protection could not connect to its agent. Check its installation and sleep-setting permission."
            case .stoppedUnexpectedly:
                "Sleep protection stopped. Turn awake mode off and on to try again."
            case .displayUnavailable:
                "Token Coffee could not change the display's power or brightness. The Mac is still kept awake."
            }
        }
    }

    public func setEnabled(_ enabled: Bool) async throws {
        if !enabled {
            guard let connection else { return }
            connection.expectedStop = true
            ready = false
            let finishing = completion
            // Half-close lets the agent restore its settings and acknowledge completion.
            shutdown(connection.handle.fileDescriptor, SHUT_WR)
            let deadline = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, self.connection === connection else { return }
                shutdown(connection.handle.fileDescriptor, SHUT_RDWR)
            }
            defer { deadline.cancel() }
            try await finishing?.value
            return
        }
        try Task.checkCancellation()
        guard connection == nil else { return }
        let url = socketURL, verifiesPeer = verifiesPeer
        let handle = try await Task.detached { try Self.connect(to: url, verifiesPeer: verifiesPeer) }.value
        let session = Connection(handle)
        connection = session
        do {
            try await Task.detached {
                let reply = try Self.readReply(handle)
                guard reply == "READY" else {
                    let code = ["ERROR identity", "ERROR permission", "ERROR restore", "ERROR busy"].contains(reply ?? "") ? reply! : "unknown"
                    Self.logger.error("Agent startup failed: \(code, privacy: .public)")
                    throw Failure.startFailed
                }
                var timeout = timeval()
                guard setsockopt(handle.fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                                 socklen_t(MemoryLayout<timeval>.size)) == 0 else { throw Failure.startFailed }
            }.value
            try Task.checkCancellation()
            ready = true
            let reader = Task.detached { [weak self] in
                while let reply = try Self.readReply(handle) {
                    if reply == "STOPPED" { return true }
                    if reply == "DISPLAY_ERROR" {
                        await MainActor.run { [weak self] in
                            guard let self, self.connection === session else { return }
                            self.onDisplayFailure?()
                        }
                    }
                }
                return false
            }
            completion = Task { [weak self] in
                let stopped = (try? await reader.value) == true
                try? handle.close()
                if let self, self.connection === session {
                    self.ready = false
                    self.connection = nil
                    self.completion = nil
                    if !session.expectedStop { self.onUnexpectedExit?() }
                }
                if !stopped { throw Failure.stoppedUnexpectedly }
            }
            if let pendingDisplayAction { try perform(pendingDisplayAction) }
        } catch {
            close()
            try? handle.close()
            throw error
        }
    }

    /// Synchronous termination wakes the agent immediately. It also watches our PID.
    public func close() {
        ready = false
        if let connection {
            connection.expectedStop = true
            shutdown(connection.handle.fileDescriptor, SHUT_RDWR)
        }
        connection = nil
        completion = nil
    }

    public func perform(_ action: DisplayPowerAction) throws {
        if action != .wake { pendingDisplayAction = action }
        guard ready, let connection else { return }
        try connection.handle.write(contentsOf: Data((action.rawValue + "\n").utf8))
    }

    nonisolated private static func connect(to url: URL, verifiesPeer: Bool) throws -> FileHandle {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(url.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.setupRequired }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            path.withUnsafeBytes { target.copyBytes(from: $0) }
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.startFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw Failure.startFailed }
            var enabled: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                             socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw Failure.startFailed }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                             socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                             socklen_t(MemoryLayout<timeval>.size)) == 0 else { throw Failure.startFailed }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw Failure.setupRequired }
            if verifiesPeer { try verifyAgent(descriptor) }
            return handle
        } catch {
            try? handle.close()
            throw error
        }
    }

    nonisolated private static func verifyAgent(_ descriptor: Int32) throws {
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid(),
              getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { throw Failure.startFailed }
        var audit = audit_token_t()
        size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &audit, &size) == 0 else { throw Failure.startFailed }
        let token = withUnsafeBytes(of: &audit) { Data($0) }
        func checked(_ status: OSStatus, _ operation: String) throws {
            guard status == errSecSuccess else {
                logger.error("Agent identity check \(operation, privacy: .public) failed: OSStatus \(status, privacy: .public)")
                throw Failure.startFailed
            }
        }
        var ownCode: SecCode?, ownStatic: SecStaticCode?, ownInfo: CFDictionary?, agent: SecCode?, requirement: SecRequirement?
        try checked(SecCodeCopySelf([], &ownCode), "own-code")
        guard let ownCode else { throw Failure.startFailed }
        try checked(SecCodeCopyStaticCode(ownCode, [], &ownStatic), "own-static-code")
        guard let ownStatic else { throw Failure.startFailed }
        try checked(SecCodeCopySigningInformation(ownStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &ownInfo), "own-team")
        guard let team = (ownInfo as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            logger.error("Agent identity check failed: missing signing team")
            throw Failure.startFailed
        }
        // Use the kernel-held signature. The sandbox cannot read the agent's executable on disk.
        // The audit token binds the requirement to this process instance, even if a PID is reused.
        let attributes = [kSecGuestAttributePid: pid as Any, kSecGuestAttributeAudit: token,
                          kSecGuestAttributeDynamicCode: true] as CFDictionary
        try checked(SecCodeCopyGuestWithAttributes(nil, attributes, [], &agent), "peer-code")
        guard let agent else { throw Failure.startFailed }
        let expression = "anchor apple generic and identifier \"\(agentIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        try checked(SecRequirementCreateWithString(expression as CFString, [], &requirement), "peer-requirement")
        guard let requirement else { throw Failure.startFailed }
        try checked(SecCodeCheckValidity(agent, [], requirement), "peer-validity")
    }

    nonisolated private static func readReply(_ handle: FileHandle) throws -> String? {
        var reply = Data()
        while reply.count < 128 {
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else { return nil }
            if byte == Data([10]) { return String(data: reply, encoding: .utf8) }
            reply.append(byte)
        }
        throw Failure.startFailed
    }

    /// Exercise the signed sandboxed app, native agent, permission, and kernel state.
    public static func verify(holdForCrashCheck: Bool = false) async throws {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { throw Failure.startFailed }
        let lidProperty = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue()
        IOObjectRelease(root)
        let expectsKernelOverride = lidProperty != nil
        func disabled() throws -> Bool {
            let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            guard root != IO_OBJECT_NULL else { throw Failure.startFailed }
            defer { IOObjectRelease(root) }
            guard let value = IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool else {
                throw Failure.startFailed
            }
            return value
        }
        guard try !disabled() else { throw Failure.startFailed }
        let protection = ClosedLidSleepProtection()
        defer { protection.close() }
        try await protection.setEnabled(true)
        guard try disabled() == expectsKernelOverride else { throw Failure.startFailed }
        if holdForCrashCheck {
            // The delivery harness can kill this isolated owner without opening account data.
            try protection.perform(.dimAll)
            try FileHandle.standardOutput.write(contentsOf: Data("READY\n".utf8))
            try await Task.sleep(for: .seconds(30))
        }
        try await protection.setEnabled(false)
        guard try !disabled() else { throw Failure.startFailed }
    }
}
