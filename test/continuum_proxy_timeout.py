"""Render the real installer fragment; test its deadline contract and nginx."""
import http.server
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]


def render(port=8787):
    installer = pathlib.Path(os.environ.get("INSTALLER_UNDER_TEST", ROOT / "installers/install-continuum.sh"))
    source = installer.read_text()
    match = re.search(r'FRAGMENT_CONTENT="\$\(cat <<NGINX\n(.*?)\nNGINX\n\)"', source, re.S)
    if not match:
        raise AssertionError("installer fragment was not found")
    script = f'APPS_ROOT=/apps; CONTINUUM_AGENT_PORT={port}\ncat <<NGINX\n{match[1]}\nNGINX\n'
    return subprocess.check_output(["bash", "-c", script], text=True)


def agent_location(fragment):
    match = re.search(r"location /agent/ \{.*?\n\}", fragment, re.S)
    if not match:
        raise AssertionError("agent proxy location was not found")
    return match[0]


class TimeoutContract(unittest.TestCase):
    def test_actual_installer_deadlines(self):
        location = agent_location(render())
        for directive, seconds in (("connect", 5), ("read", 120), ("send", 120)):
            self.assertRegex(location, rf"proxy_{directive}_timeout\s+{seconds}s;")
        self.assertNotRegex(location, r"proxy_read_timeout\s+60s;")

    def test_existing_mount_and_upstream_are_preserved(self):
        fragment = render(18787)
        self.assertIn("location /continuum/", fragment)
        self.assertIn("alias /apps/continuum/current/", fragment)
        self.assertIn("http://127.0.0.1:18787/", agent_location(fragment))
        self.assertIn("client_max_body_size 1m;", fragment)

    @unittest.skipUnless(shutil.which("nginx"), "nginx needed for real proxy test")
    def test_delayed_chat_survives_the_old_cutoff(self):
        # Scale all proxy timeouts 1:100. A 75-second equivalent reply lies
        # inside the agent's 100-second budget but beyond the old 60-second
        # proxy limit. No model, credentials, wallet or paid request is used.
        class Provider(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length", 0)))
                time.sleep(0.75)
                body = json.dumps({"reply": "gm", "path": self.path}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except BrokenPipeError:
                    pass

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        location = agent_location(render(server.server_port))
        location = re.sub(
            r"(proxy_(?:read|send|connect)_timeout\s+)(\d+)s;",
            lambda m: f"{m[1]}{int(m[2]) * 10}ms;", location,
        )
        with tempfile.TemporaryDirectory(prefix="continuum-nginx-test-") as tmp:
            conf = pathlib.Path(tmp) / "nginx.conf"
            conf.write_text(
                f"pid {tmp}/nginx.pid;\nerror_log stderr;\nevents {{}}\n"
                f"http {{ access_log off; server {{ listen 127.0.0.1:{port};\n{location}\n}} }}\n"
            )
            subprocess.run(["nginx", "-t", "-p", tmp, "-c", str(conf)], check=True, capture_output=True)
            proc = subprocess.Popen(
                ["nginx", "-p", tmp, "-c", str(conf), "-g", "daemon off;"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            try:
                ready_by = time.monotonic() + 3
                while True:
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            break
                    except OSError:
                        if proc.poll() is not None or time.monotonic() >= ready_by:
                            self.fail("nginx did not start")
                        time.sleep(0.02)
                request = urllib.request.Request(
                    f"http://127.0.0.1:{port}/agent/api/chat",
                    data=b'{"message":"gm"}',
                    headers={"Content-Type": "application/json"},
                )
                with urllib.request.urlopen(request, timeout=3) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(json.load(response), {"reply": "gm", "path": "/api/chat"})
            finally:
                proc.terminate()
                proc.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
