import json
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "init-services.sh"


@pytest.fixture
def prowlarr_api():
    profiles = [
        {"id": 3, "name": "Standard", "minimumSeeders": 1, "enableRss": False,
         "enableAutomaticSearch": True, "enableInteractiveSearch": True},
        {"id": 8, "name": "Rare", "minimumSeeders": 1, "enableRss": True,
         "enableAutomaticSearch": False, "enableInteractiveSearch": True},
    ]
    calls = []
    options = {"discard_updates": False}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def handle_request(self):
            assert self.headers["X-Api-Key"] == "test-api-key"
            size = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(size)) if size else None
            calls.append((self.command, self.path, payload))
            if self.command == "GET" and self.path == "/api/v1/appprofile":
                response = profiles
            elif self.command == "GET" and self.path == "/api/v1/appprofile/3":
                response = profiles[0]
            elif self.command == "PUT" and self.path == "/api/v1/appprofile/3":
                assert isinstance(payload, dict)
                if not options["discard_updates"]:
                    profiles[0] = payload
                response = payload
            elif self.command == "POST" and self.path == "/api/v1/command":
                response = {"id": 1, "status": "queued"}
            else:
                self.send_error(404)
                return
            body = json.dumps(response).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

        do_GET = handle_request
        do_PUT = handle_request
        do_POST = handle_request

    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server, profiles, calls, options
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


def apply_profile(tmp_path, api, minimum=10):
    server, _, _, _ = api
    script = tmp_path / "scripts" / "init-services.sh"
    script.parent.mkdir(exist_ok=True)
    shutil.copyfile(SCRIPT_PATH, script)
    config = tmp_path / "config" / "init" / "prowlarr.json"
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text(json.dumps({"syncProfile": {"name": "Standard", "minimumSeeders": minimum}}))
    (tmp_path / ".env").write_text(
        f"PROWLARR_PORT={server.server_port}\nPROWLARR_API_KEY='test-api-key'\n"
    )
    return subprocess.run(
        ["bash", "-c", 'source "$1"; apply_prowlarr_sync_profile', "bash", str(script)],
        text=True, capture_output=True, timeout=10,
    )


def test_sync_profile_preserves_other_settings_and_is_idempotent(tmp_path, prowlarr_api):
    _, profiles, calls, _ = prowlarr_api
    original = json.loads(json.dumps(profiles))
    for _ in range(2):
        result = apply_profile(tmp_path, prowlarr_api)
        assert result.returncode == 0, result.stderr
    assert profiles[0] == {**original[0], "minimumSeeders": 10}
    assert profiles[1] == original[1]
    assert len([call for call in calls if call[0] == "PUT"]) == 1
    syncs = [call[2] for call in calls if call[0] == "POST"]
    assert syncs == [{"name": "ApplicationIndexerSync", "forceSync": True}] * 2
    assert not (tmp_path / "config" / ".init-state").exists()
    main = SCRIPT_PATH.read_text().split("main() {", 1)[1]
    assert "  setup_prowlarr\n  apply_prowlarr_sync_profile\n" in main


@pytest.mark.parametrize("minimum", [-1, "10", True])
def test_invalid_minimum_does_not_call_api(tmp_path, prowlarr_api, minimum):
    result = apply_profile(tmp_path, prowlarr_api, minimum)
    assert result.returncode != 0
    assert "non-negative integer" in result.stderr
    assert prowlarr_api[2] == []


def test_missing_named_profile_does_not_modify_another_profile(tmp_path, prowlarr_api):
    prowlarr_api[1][0]["name"] = "Renamed"
    result = apply_profile(tmp_path, prowlarr_api)
    assert result.returncode != 0
    assert "Expected one Prowlarr sync profile" in result.stderr
    assert all(call[0] == "GET" for call in prowlarr_api[2])


def test_failed_readback_does_not_request_sync(tmp_path, prowlarr_api):
    prowlarr_api[3]["discard_updates"] = True
    result = apply_profile(tmp_path, prowlarr_api)
    assert result.returncode != 0
    assert "did not persist" in result.stderr
    assert not any(call[0] == "POST" for call in prowlarr_api[2])
