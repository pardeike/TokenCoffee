#!/usr/bin/env python3
"""Exercise process-exit cleanup without changing the Mac's power settings."""
import os
from pathlib import Path
import signal
import socket
import select
import subprocess
import sys
import tempfile
import time
import unittest


class SleepGuardTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.state = self.root / "state"
        self.state.write_text("0\n")
        self.brightness = self.root / "brightness"
        self.brightness.write_text("0.75\n")
        self.env = dict(os.environ, SLEEP_GUARD_TEST_DIRECTORY=str(self.root),
                        SLEEP_GUARD_TEST_STATE=str(self.state))

    def start(self, parent=None):
        process = subprocess.Popen([sys.argv[1], "guard", str(parent or os.getpid())],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=self.env, text=True)
        self.addCleanup(lambda: self.stop(process))
        return process

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.stdin.close()
            process.wait(timeout=5)
        if process.stdin and not process.stdin.closed:
            process.stdin.close()
        process.stdout.close()
        process.stderr.close()

    def test_eof_restores_sleep(self):
        guard = self.start()
        self.assertEqual(guard.stdout.readline(), "READY\n")
        self.assertEqual(self.state.read_text().strip(), "1")
        guard.stdin.close()
        self.assertEqual(guard.wait(timeout=5), 0)
        self.assertEqual(self.state.read_text().strip(), "0")

    def test_app_exit_restores_sleep_even_with_open_input(self):
        app = subprocess.Popen(["/bin/cat"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
        self.addCleanup(lambda: app.poll() is None and app.kill())
        guard = self.start(app.pid)
        self.assertEqual(guard.stdout.readline(), "READY\n")
        app.kill()
        app.wait(timeout=5)
        app.stdin.close()
        self.assertEqual(guard.wait(timeout=5), 0)
        self.assertEqual(self.state.read_text().strip(), "0")

    def test_preexisting_sleep_override_is_preserved(self):
        self.state.write_text("1\n")
        guard = self.start()
        self.assertEqual(guard.stdout.readline(), "READY\n")
        guard.stdin.close()
        self.assertEqual(guard.wait(timeout=5), 0)
        self.assertEqual(self.state.read_text().strip(), "1")
        self.assertFalse((self.root / "owned").exists())

    def test_permission_failure_does_not_claim_success(self):
        self.env["SLEEP_GUARD_TEST_DENY"] = "1"
        guard = self.start()
        self.assertEqual(guard.stdout.readline(), "ERROR permission\n")
        self.assertEqual(guard.wait(timeout=5), 1)
        self.assertEqual(self.state.read_text().strip(), "0")

    def test_recovery_after_guard_is_killed(self):
        guard = self.start()
        self.assertEqual(guard.stdout.readline(), "READY\n")
        guard.kill()
        guard.wait(timeout=5)
        self.assertEqual(self.state.read_text().strip(), "1")
        subprocess.run([sys.argv[1], "recover"], env=self.env, check=True, timeout=5)
        self.assertEqual(self.state.read_text().strip(), "0")
        self.assertFalse((self.root / "owned").exists())

    def test_termination_signal_restores_sleep(self):
        guard = self.start()
        self.assertEqual(guard.stdout.readline(), "READY\n")
        guard.send_signal(signal.SIGTERM)
        self.assertEqual(guard.wait(timeout=5), 0)
        self.assertEqual(self.state.read_text().strip(), "0")

    def test_second_owner_is_rejected_and_recovery_does_not_interrupt(self):
        guard = self.start()
        self.assertEqual(guard.stdout.readline(), "READY\n")
        second = self.start()
        self.assertEqual(second.stdout.readline(), "ERROR busy\n")
        self.assertEqual(second.wait(timeout=5), 1)
        subprocess.run([sys.argv[1], "recover"], env=self.env, check=True, timeout=5)
        self.assertEqual(self.state.read_text().strip(), "1")

    def send(self, process, command):
        process.stdin.write(command + "\n")
        process.stdin.flush()

    def await_brightness(self, expected):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            text = self.brightness.read_text().strip()
            if text and abs(float(text) - expected) < .001:
                return
            time.sleep(.01)
        self.fail("Brightness did not reach the requested value")

    def test_dim_and_restore_keep_system_sleep_protection(self):
        guard = self.start()
        self.assertEqual(guard.stdout.readline(), "READY\n")
        self.send(guard, "DIM_ALL")
        self.await_brightness(0)
        self.assertEqual(self.state.read_text().strip(), "1")
        self.send(guard, "RESTORE")
        self.await_brightness(.75)
        self.assertEqual(self.state.read_text().strip(), "1")

    def test_app_exit_restores_owned_brightness(self):
        guard = self.start()
        self.assertEqual(guard.stdout.readline(), "READY\n")
        self.send(guard, "DIM")
        self.await_brightness(0)
        guard.stdin.close()
        self.assertEqual(guard.wait(timeout=5), 0)
        self.assertEqual(float(self.brightness.read_text()), .75)

    def test_changed_brightness_is_preserved_on_exit(self):
        guard = self.start()
        self.assertEqual(guard.stdout.readline(), "READY\n")
        self.send(guard, "DIM")
        self.await_brightness(0)
        self.brightness.write_text("0.5\n")
        guard.stdin.close()
        self.assertEqual(guard.wait(timeout=5), 0)
        self.assertEqual(float(self.brightness.read_text()), .5)

    def test_crash_recovery_restores_brightness_and_sleep(self):
        guard = self.start()
        self.assertEqual(guard.stdout.readline(), "READY\n")
        self.send(guard, "DIM")
        self.await_brightness(0)
        guard.kill()
        guard.wait(timeout=5)
        subprocess.run([sys.argv[1], "recover"], env=self.env, check=True, timeout=5)
        self.assertEqual(float(self.brightness.read_text()), .75)
        self.assertEqual(self.state.read_text().strip(), "0")

    def test_display_sleep_does_not_release_system_override(self):
        guard = self.start()
        self.assertEqual(guard.stdout.readline(), "READY\n")
        self.send(guard, "SLEEP")
        deadline = time.monotonic() + 3
        while not (self.root / "display-action").exists() and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual((self.root / "display-action").read_text().strip(), "sleep")
        self.assertEqual(self.state.read_text().strip(), "1")

    def test_desktop_needs_no_privileged_sleep_setting(self):
        self.env["SLEEP_GUARD_TEST_DESKTOP"] = "1"
        self.env["SLEEP_GUARD_TEST_DENY"] = "1"
        guard = self.start()
        self.assertEqual(guard.stdout.readline(), "READY\n")
        self.assertEqual(self.state.read_text().strip(), "0")
        self.send(guard, "DIM_ALL")
        self.await_brightness(0)
        guard.stdin.close()
        self.assertEqual(guard.wait(timeout=5), 0)
        self.assertEqual(float(self.brightness.read_text()), .75)

    def server(self):
        process = subprocess.Popen([sys.argv[1], "serve"], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: self.stop_server(process))
        self.assertTrue(select.select([process.stdout], [], [], 5)[0], "The agent did not announce its listener")
        self.assertEqual(process.stdout.readline(), b"LISTENING\n")
        self.assertTrue((self.root / "agent.sock").exists())
        return process

    @staticmethod
    def stop_server(process):
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        process.stdout.close()
        process.stderr.close()

    def connect(self):
        connection = socket.socket(socket.AF_UNIX)
        self.addCleanup(connection.close)
        connection.settimeout(5)
        connection.connect(str(self.root / "agent.sock"))
        stream = connection.makefile("rb")
        self.addCleanup(stream.close)
        return connection, stream

    def test_agent_idle_and_disconnected_sessions_do_not_hold_sleep_override(self):
        self.server()
        self.assertEqual(self.state.read_text().strip(), "0")
        self.assertEqual((self.root / "agent.sock").stat().st_mode & 0o777, 0o600)
        for _ in range(2):
            connection, stream = self.connect()
            self.assertEqual(stream.readline(), b"READY\n")
            self.assertEqual(self.state.read_text().strip(), "1")
            connection.sendall(b"DIM\n")
            self.await_brightness(0)
            connection.shutdown(socket.SHUT_WR)
            self.assertEqual(stream.readline(), b"STOPPED\n")
            self.assertEqual(self.state.read_text().strip(), "0")
            self.assertEqual(float(self.brightness.read_text()), .75)
            stream.close()
            connection.close()

    def test_agent_rejects_an_untrusted_peer_before_changing_power(self):
        self.env["SLEEP_GUARD_TEST_REJECT_PEER"] = "1"
        self.server()
        _, stream = self.connect()
        self.assertEqual(stream.readline(), b"ERROR identity\n")
        self.assertEqual(self.state.read_text().strip(), "0")

    def test_installer_probe_verifies_foreign_identity_rejection(self):
        self.env["SLEEP_GUARD_TEST_REJECT_PEER"] = "1"
        self.server()
        subprocess.run([sys.argv[1], "probe"], env=self.env, check=True, timeout=5)
        self.assertEqual(self.state.read_text().strip(), "0")

    def test_agent_restart_restores_an_interrupted_socket_session(self):
        process = self.server()
        connection, stream = self.connect()
        self.assertEqual(stream.readline(), b"READY\n")
        connection.sendall(b"DIM\n")
        self.await_brightness(0)
        process.kill()
        process.wait(timeout=5)
        self.assertEqual(self.state.read_text().strip(), "1")
        # A new launchd invocation must replace the stale socket and restore first.
        self.server()
        self.assertEqual(self.state.read_text().strip(), "0")
        self.assertEqual(float(self.brightness.read_text()), .75)

    def test_agent_signal_restores_an_active_session(self):
        process = self.server()
        connection, stream = self.connect()
        self.assertEqual(stream.readline(), b"READY\n")
        connection.sendall(b"DIM\n")
        self.await_brightness(0)
        process.terminate()
        process.wait(timeout=5)
        self.assertEqual(self.state.read_text().strip(), "0")
        self.assertEqual(float(self.brightness.read_text()), .75)

    def test_agent_rejects_a_second_session_without_interrupting_the_owner(self):
        self.server()
        first, stream = self.connect()
        self.assertEqual(stream.readline(), b"READY\n")
        _, second = self.connect()
        self.assertEqual(second.readline(), b"ERROR busy\n")
        self.assertEqual(self.state.read_text().strip(), "1")
        first.shutdown(socket.SHUT_WR)
        self.assertEqual(stream.readline(), b"STOPPED\n")
        self.assertEqual(self.state.read_text().strip(), "0")

    def test_agent_restores_settings_when_its_client_process_is_killed(self):
        server = self.server()
        client = subprocess.Popen([sys.executable, "-u", "-c", """
import socket,sys
connection=socket.socket(socket.AF_UNIX)
connection.connect(sys.argv[1])
print(connection.recv(64).decode().strip(),flush=True)
connection.sendall(b'DIM\\n')
sys.stdin.read()
""", str(self.root / "agent.sock")], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(lambda: self.stop_client(client))
        self.assertTrue(select.select([client.stdout], [], [], 5)[0])
        self.assertEqual(client.stdout.readline(), b"READY\n")
        self.await_brightness(0)
        client.kill()
        client.wait(timeout=5)
        deadline = time.monotonic() + 5
        while self.state.read_text().strip() != "0" and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(self.state.read_text().strip(), "0")
        self.assertEqual(float(self.brightness.read_text()), .75)
        self.assertIsNone(server.poll(), "Client death must leave the agent available")

    @staticmethod
    def stop_client(process):
        process.stdin.close()
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=5)
        process.stdout.close()


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
