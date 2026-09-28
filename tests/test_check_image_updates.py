import importlib.util
import json
import subprocess
import sys
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "check-image-updates.py"


def load_module():
    spec = importlib.util.spec_from_file_location("check_image_updates", SCRIPT_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_parse_stack_images_maps_services_to_version_and_digest_vars(tmp_path):
    module = load_module()
    compose = tmp_path / "compose.yaml.j2"
    vars_file = tmp_path / "vars.yml"
    compose.write_text(
        """
services:
  traefik:
    image: traefik:{{ traefik_version }}@sha256:{{ traefik_digest }}
  seerr:
    image: ghcr.io/seerr-team/seerr:{{ seerr_version }}@sha256:{{ seerr_digest }}
""".lstrip()
    )
    vars_file.write_text(
        """
traefik_version: "v3.7.6"
traefik_digest: "abc123"
seerr_version: "v3.3.0"
seerr_digest: "def456"
""".lstrip()
    )

    images = module.parse_stack_images(compose, vars_file)

    assert [(image.service, image.repository, image.current_tag, image.digest_var, image.current_digest) for image in images] == [
        ("traefik", "traefik", "v3.7.6", "traefik_digest", "abc123"),
        ("seerr", "ghcr.io/seerr-team/seerr", "v3.3.0", "seerr_digest", "def456"),
    ]


def test_parse_stack_images_reports_missing_digest_for_mutable_refs(tmp_path):
    module = load_module()
    compose = tmp_path / "compose.yaml.j2"
    vars_file = tmp_path / "vars.yml"
    compose.write_text(
        """
services:
  traefik:
    image: traefik:{{ traefik_version }}
""".lstrip()
    )
    vars_file.write_text('traefik_version: "v3.7.6"\n')

    image = module.parse_stack_images(compose, vars_file)[0]
    rows = module.compare_images([image], tag_provider=lambda img: ["v3.7.6"], digest_provider=lambda img: "abc123")

    assert rows[0].status == "missing-digest"


def test_latest_semver_tag_prefers_current_prefix():
    module = load_module()

    assert module.latest_semver_tag(["3.7.6", "v3.7.7", "v3.7.6"], current_tag="v3.7.6") == "v3.7.7"
    assert module.latest_semver_tag(["5.2.1", "5.2.2", "latest"], current_tag="5.2.1") == "5.2.2"


def test_latest_semver_tag_handles_suffixed_linuxserver_tags():
    module = load_module()

    # LinuxServer publishes Jellyfin 12.x only as suffixed tags.
    tags = ["10.11.11", "10.11.11ubu2604-ls44", "12.0ubu2604-ls48", "12.1ubu2604-ls50", "latest"]
    assert module.latest_semver_tag(tags, current_tag="12.1ubu2604-ls50") == "12.1ubu2604-ls50"
    assert module.latest_semver_tag(tags, current_tag="12.0ubu2604-ls48") == "12.1ubu2604-ls50"


def test_latest_semver_tag_prefers_bare_tags_when_current_is_bare():
    module = load_module()

    tags = ["1.6.0", "1.6.1", "1.6.2", "1.6.2-development"]
    assert module.latest_semver_tag(tags, current_tag="1.6.0") == "1.6.2"


def test_parse_version_compares_suffixed_tags():
    module = load_module()

    assert module.parse_version("12.1ubu2604-ls50") == (12, 1)
    assert module.parse_version("12.1ubu2604-ls50") > module.parse_version("10.11.11")
    assert module.parse_version("12.0ubu2604-ls48") < module.parse_version("12.1ubu2604-ls50")


def test_compare_images_reports_updates_without_network():
    module = load_module()
    image = module.StackImage(
        service="sonarr",
        repository="linuxserver/sonarr",
        version_var="sonarr_version",
        current_tag="4.0.17",
        digest_var="sonarr_digest",
        current_digest="abc123",
    )

    rows = module.compare_images(
        [image],
        tag_provider=lambda img: ["4.0.17", "4.0.19"],
        digest_provider=lambda img: "abc123",
    )

    assert rows[0].latest_tag == "4.0.19"
    assert rows[0].status == "update"


def test_compare_images_reports_digest_drift():
    module = load_module()
    image = module.StackImage(
        service="traefik",
        repository="traefik",
        version_var="traefik_version",
        current_tag="v3.7.6",
        digest_var="traefik_digest",
        current_digest="old",
    )

    rows = module.compare_images(
        [image],
        tag_provider=lambda img: ["v3.7.6"],
        digest_provider=lambda img: "new",
    )

    assert rows[0].registry_digest == "new"
    assert rows[0].status == "digest-drift"


def test_compare_images_reports_current_when_tag_and_digest_match():
    module = load_module()
    image = module.StackImage(
        service="traefik",
        repository="traefik",
        version_var="traefik_version",
        current_tag="v3.7.6",
        digest_var="traefik_digest",
        current_digest="abc123",
    )

    rows = module.compare_images(
        [image],
        tag_provider=lambda img: ["v3.7.6"],
        digest_provider=lambda img: "abc123",
    )

    assert rows[0].status == "current"


def test_registry_digest_uses_manifest_list_digest(monkeypatch):
    module = load_module()
    image = module.StackImage(
        service="socket-proxy",
        repository="tecnativa/docker-socket-proxy",
        version_var="socket_proxy_version",
        current_tag="v0.5.0",
    )
    manifest = {
        "digest": "sha256:manifest-list",
        "manifests": [
            {"digest": "sha256:linux-386", "platform": {"os": "linux", "architecture": "386"}},
            {"digest": "sha256:linux-amd64", "platform": {"os": "linux", "architecture": "amd64"}},
        ],
    }

    def fake_run(command, **kwargs):
        assert command == [
            "docker",
            "buildx",
            "imagetools",
            "inspect",
            "tecnativa/docker-socket-proxy:v0.5.0",
            "--format",
            "{{json .Manifest}}",
        ]
        return subprocess.CompletedProcess(command, 0, stdout=json.dumps(manifest), stderr="")

    monkeypatch.setattr(module.subprocess, "run", fake_run)

    assert module.registry_digest(image) == "manifest-list"
