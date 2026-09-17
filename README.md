# Media Server

This project deploys a self-hosted media server on a VPS using Ansible for bootstrap and Docker Compose for the stack.

**Stack:** Traefik, Jellyfin, Seerr, Radarr, Sonarr, Prowlarr, Bazarr, qBittorrent

> **WARNING** I do not condone the use of this technology for downloading illegal or copyrighted content. This is purely for fun and not for doing anything illegal.

## Architecture

```
Users → Traefik (HTTPS)
          ├── Seerr      (https://your-domain)
          └── Jellyfin   (https://jellyfin.your-domain)

Internal (media-network):
  Seerr → Jellyfin, Radarr, Sonarr
  Prowlarr → Radarr, Sonarr
  Radarr/Sonarr → qBittorrent → /content/torrents
  Radarr/Sonarr/Jellyfin → /content/media
  Bazarr → Radarr, Sonarr → subtitles into /content/media
```

Ansible handles VPS bootstrap (Docker, firewall, directories, config templating). Docker Compose runs all services from a single [`compose.yaml.j2`](compose.yaml.j2). A one-shot [`scripts/init-services.sh`](scripts/init-services.sh) configures Jellyfin libraries, *arr apps, Bazarr, and Seerr via their APIs.

## Prerequisites

- A VPS with a non-root user and SSH access
- [Ansible](https://docs.ansible.com/ansible/latest/index.html) on your local machine
- DNS A records for `your-domain` and `jellyfin.your-domain` pointing at the VPS

Install the required Ansible collection:

```zsh
ansible-galaxy collection install -r requirements.yml
```

## Deployment

Copy the example inventory and fill in your values:

```zsh
cp inventory.example.ini inventory.ini
```

```ini
[media]
<ip_address>

[media:vars]
ansible_user=<user>
ansible_ssh_private_key_file=<private_key>

# Server
server_domain=<server_domain>
admin_email=<admin_email>
server_name=<server_name>
frontend_title=<name_in_website>
timezone=<your_timezone>

# Optional. Passwords and *arr API keys are auto-generated
# when omitted; set them here to choose your own.
# qbittorrent_password=<XXXX>
# jellyfin_password=<XXXX>
```

The passwords and *arr API keys are optional: when omitted they are
auto-generated and stored in `.credentials/` next to your inventory
(gitignored), so re-runs reuse the same values. Seerr has no separate login —
it reuses the Jellyfin username/password. If your VPS uses a non-standard SSH
port, set
`ssh_port` in the inventory **before** the first run — the firewall only
allows the configured port.

> **Note:** Deployment assumes a VPS with a non-root user. Running everything as root creates security issues.

Run the playbook:

```zsh
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml
```

### Partial runs (tags)

```zsh
# Bootstrap only (Docker, firewall, directories, config)
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml --tags setup

# Re-template config and start/restart containers
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml --tags config,compose

# Verify service health endpoints
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml --tags verify

# Re-run API initialisation (idempotent)
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml --tags init
```

### Updates

Image versions and manifest-list digests are pinned in [`vars.yml`](vars.yml).
Check available semver tags and digest drift:

```zsh
scripts/check-image-updates.py
```

Bump the tag and digest deliberately, then re-template the generated compose
file, pull the updated image on that run only, recreate the stack, and verify
the health endpoints:

```zsh
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml --syntax-check
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml --check --diff --tags config
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml -e compose_pull_policy=always --tags config,compose,verify
```

After deployment, inspect the running stack on the server:

```zsh
cd ~/<server_name>
docker compose ps
docker compose logs --since=10m --tail=100
```

### Rollback

If an image bump breaks a service, revert the version pin in [`vars.yml`](vars.yml)
and redeploy the generated compose file:

```zsh
git revert <update-commit>
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml --tags config,compose,verify
```

If a container starts but the app data looks wrong after a migration, stop before
making more changes and restore that app's config directory from your VPS backup.
The directories to restore are under `~/<server_name>/jellyfin`,
`~/<server_name>/seerr`, `~/<server_name>/torrent/config`, and
`~/<server_name>/media-management`.

## Local / LAN Deployment

The stack can also run on a local PC/LAN instead of a VPS, e.g. on a home
server. In `[media:vars]`:

```ini
[media]
localhost ansible_connection=local

[media:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=<your_local_user>
server_domain=media.local
timezone=<your_timezone>

# Bind admin UIs to the LAN instead of localhost-only. Keep the firewall on and
# restrict Docker-published admin ports to trusted CIDRs/interfaces.
bind_host=0.0.0.0
trusted_lan_cidrs=["192.168.1.0/24"]
admin_ingress_interfaces=["eth0"]

# Store media on a dedicated external/secondary storage directory; the
# playbook rejects broad system paths such as /, /home, /etc, /usr, and /var.
content_dir=/mnt/external-drive/content

# Skip UFW only if you manage equivalent Docker-aware firewall rules yourself.
# enable_firewall=false
```

`bind_host` must be either `127.0.0.1` (localhost-only, the default — used
behind Traefik on a VPS) or `0.0.0.0` (all interfaces, for LAN access).
Anything else fails validation, since service initialisation always connects
to the freshly-started containers via `127.0.0.1` — Docker's port publishing
only forwards traffic addressed to the bound IP, so a specific LAN IP here
would make init unable to reach its own services.

qBittorrent's peer port is **not** published by default, because Docker-published
ports can bypass normal UFW incoming-policy expectations. To expose it
deliberately, set `publish_bittorrent_peer_ports=true` and choose
`qbittorrent_peer_bind_host`/`qbittorrent_peer_port`; provider-side VPN port
forwarding is preferred when qBittorrent is routed through Gluetun.

Route qBittorrent's traffic through a VPN with `vpn_enabled=true` — see the
VPN section in [`inventory.example.ini`](inventory.example.ini) for the full
set of options for both named providers (NordVPN, Mullvad, etc.) and a
manually-configured WireGuard peer.

## Prowlarr

Prowlarr is not pre-configured with indexers. After deploy, set up SSH port forwarding to Prowlarr and add indexers manually:

```zsh
ssh -L 9696:127.0.0.1:9696 <user>@<ip_address>
```

Open `http://localhost:9696`, go to **Indexers → Add Indexer**, and add a few public indexers.

The `Standard` sync profile requires at least **10 reported seeders** for automatic
Sonarr/Radarr torrent grabs. Override `torrent_minimum_seeders` in your inventory
to change this threshold. Service initialisation reapplies it on every run and
requests an indexer sync; other sync profiles and quality rules are preserved.
Indexer counts can be stale, so this filters low-seed releases but does not
guarantee a working swarm. qBittorrent also excludes slow torrents from its queue
limits so stalled downloads are less likely to block other work.

## Subtitles

Bazarr downloads **English** subtitles automatically for everything Radarr and
Sonarr track. The init step boots Bazarr, reads back the API key it generates on
first run, then configures the Radarr/Sonarr connections, subtitle providers, and
an English language profile set as the **default** for all series and movies — so
new downloads and the existing library are both covered, with no manual setup.

Providers default to **Podnapisi** and **Gestdown** (both anonymous, no account).
Everything is defined in [`config/init/bazarr.json.j2`](config/init/bazarr.json.j2):
add provider ids to `enabledProviders`, or add languages to `languagesEnabled` and
the profile `items` to fetch more than English. Bazarr's admin UI is localhost-only:

```zsh
ssh -L 6767:127.0.0.1:6767 <user>@<ip_address>   # then open http://localhost:6767
```

> Bazarr only sees media that Radarr/Sonarr already track. Files sitting in
> `/content/media` that were never added to the *arr apps won't get subtitles until
> they are imported.

## Customisation

Override defaults in [`vars.yml`](vars.yml) (ports, paths, usernames, pinned image versions). Secrets belong in `inventory.ini`, not in the repo.

## Streaming quality profiles

The init script creates named, **Seerr-selectable quality profiles** in Radarr
and Sonarr that bake in release rules to keep grabs playable on a given client
without server-side transcoding (important on a low-power VPS with no GPU). Each
is a normal quality profile with a set of "blocked" custom formats scored
`-10000`, so matching releases are never grabbed.

Out of the box one profile is defined — **Chromecast 2018** (H.264, ≤1080p,
progressive only: blocks HEVC, DTS/TrueHD, 4K, and interlaced/raw `1080i`/`Raw-HD`
captures so a 2018 Chromecast direct-plays everything):

- **To cast a title:** in the Seerr request dialog, open **Advanced** and pick
  **Chromecast 2018**.
- **Otherwise:** request normally — the default profile (`HD - 720p/1080p`) is
  left unrestricted, for playback on clients that decode HEVC/DTS natively.

Admins get the Advanced profile picker by default; regular users always get the
default profile. Profiles are defined under `qualityProfiles` in
[`config/init/radarr.json.j2`](config/init/radarr.json.j2) and
[`config/init/sonarr.json.j2`](config/init/sonarr.json.j2) — each clones a base
profile (`cloneFrom`) and lists the custom formats to block. Add an entry to
define your own (e.g. an `Apple TV` profile); the init step is an idempotent
reconciler, so re-running creates/updates them and clears any stale scores.

```zsh
# Apply profile changes after editing the init JSON
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml --tags config,init
```

Notes:

- **Off by default:** normal requests are *not* restricted, so remember to pick
  **Chromecast 2018** for anything you'll cast. To make it the safe default
  instead, point Seerr's default `activeProfileName` (in
  [`seerr.json.j2`](config/init/seerr.json.j2)) at `Chromecast 2018`.
- **One file per title**, chosen at download time — you can't keep both a cast
  copy and a 4K copy of the same movie without a separate Radarr instance, and a
  full-quality grab will still fail to cast on this server since it can't transcode.
- Matching is by release title (except 4K, which uses the parsed resolution), so
  it is best-effort — the same trade-off as any *arr custom format — and only
  affects **future** grabs.

## DNS

Traefik obtains TLS certificates via ACME. Ensure these hostnames resolve to your VPS before the first deploy:

- `{{ server_domain }}` — Seerr
- `jellyfin.{{ server_domain }}` — Jellyfin
