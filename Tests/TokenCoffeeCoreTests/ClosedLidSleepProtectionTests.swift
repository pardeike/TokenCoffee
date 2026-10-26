import Foundation
import XCTest
@testable import TokenCoffeeCore

final class ClosedLidSleepProtectionTests: XCTestCase {
    private struct Fixture {
        let socket: URL
        let commands: URL
        let process: Process
    }

    private func fixture(_ reply: String = "READY") throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tc-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent("agent.sock")
        let commands = directory.appendingPathComponent("commands")
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", """
        import socket,sys
        server=socket.socket(socket.AF_UNIX)
        server.bind(sys.argv[1])
        server.listen(4)
        print('READY',flush=True)
        while True:
            connection,_=server.accept()
            with connection:
                connection.sendall((sys.argv[3]+'\\n').encode())
                with connection.makefile('r') as incoming:
                    for line in incoming:
                        with open(sys.argv[2],'a') as recorded: recorded.write(line)
                try: connection.sendall(b'STOPPED\\n')
                except BrokenPipeError: pass
        """, socket.path, commands.path, reply]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        addTeardownBlock {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try FileManager.default.removeItem(at: directory)
        }
        // The fixture announces its listener. No timer or startup sleep is needed.
        let announced = try output.fileHandleForReading.read(upToCount: 6)
        XCTAssertEqual(announced, Data("READY\n".utf8))
        return Fixture(socket: socket, commands: commands, process: process)
    }

    @MainActor func testNativeSocketStartsAndStopsWithAcknowledgedCleanup() async throws {
        let fixture = try fixture()
        let protection = ClosedLidSleepProtection(socketURL: fixture.socket, verifiesPeer: false)
        defer { protection.close() }
        try await protection.setEnabled(true)
        try await protection.setEnabled(false)
    }

    @MainActor func testInvalidStartupReplyClosesTheConnection() async throws {
        let fixture = try fixture("ERROR permission")
        let protection = ClosedLidSleepProtection(socketURL: fixture.socket, verifiesPeer: false)
        defer { protection.close() }
        do {
            try await protection.setEnabled(true)
            XCTFail("An unsuccessful startup must not report protection")
        } catch ClosedLidSleepProtection.Failure.startFailed {}
        try await protection.setEnabled(false)
    }

    @MainActor func testDisplayCommandsAreQueuedUntilStartupAndWrittenInOrder() async throws {
        let fixture = try fixture()
        let protection = ClosedLidSleepProtection(socketURL: fixture.socket, verifiesPeer: false)
        defer { protection.close() }
        try protection.perform(.dimAll)
        try await protection.setEnabled(true)
        try protection.perform(.restore)
        try protection.perform(.sleep)
        try await protection.setEnabled(false)
        let commands = try String(contentsOf: fixture.commands, encoding: .utf8)
        XCTAssertEqual(commands, "DIM_ALL\nRESTORE\nSLEEP\n")
    }

    @MainActor func testMissingAgentReportsSetupRequired() async throws {
        let protection = ClosedLidSleepProtection(socketURL: URL(fileURLWithPath: "/tmp/" + UUID().uuidString), verifiesPeer: false)
        do {
            try await protection.setEnabled(true)
            XCTFail("A missing agent must not report protection")
        } catch ClosedLidSleepProtection.Failure.setupRequired {}
    }

    @MainActor func testReleasingTheOwnerDisconnectsWithoutAnExplicitShutdown() async throws {
        let fixture = try fixture()
        let socket = fixture.socket
        try await Task.detached {
            let first = await ClosedLidSleepProtection(socketURL: socket, verifiesPeer: false)
            try await first.setEnabled(true)
        }.value
        let next = ClosedLidSleepProtection(socketURL: fixture.socket, verifiesPeer: false)
        defer { next.close() }
        try await next.setEnabled(true)
        try await next.setEnabled(false)
    }

    @MainActor func testUnexpectedDisconnectNotifiesTheApp() async throws {
        let fixture = try fixture()
        let protection = ClosedLidSleepProtection(socketURL: fixture.socket, verifiesPeer: false)
        defer { protection.close() }
        let disconnected = expectation(description: "The app observes an unexpected agent exit")
        protection.onUnexpectedExit = { disconnected.fulfill() }
        try await protection.setEnabled(true)
        fixture.process.terminate()
        await fulfillment(of: [disconnected], timeout: 5)
    }

    @MainActor func testForeignAgentIsRejectedBeforeItCanReportProtection() async throws {
        let fixture = try fixture()
        let protection = ClosedLidSleepProtection(socketURL: fixture.socket, verifiesPeer: true)
        defer { protection.close() }
        do {
            try await protection.setEnabled(true)
            XCTFail("A foreign executable must not impersonate the signed agent")
        } catch ClosedLidSleepProtection.Failure.startFailed {}
    }
}
