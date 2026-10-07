# OneClick Installer

A single interactive Bash script to set up your own VPN server with one command — no manual configuration needed. Select an option from the menu and you're good to go.

## What It Can Install

| Option | Description |
|---|---|
| **Docker** | Full Docker Engine + Compose plugin (with an optional DNS workaround for servers located in Iran) |
| **SoftEther VPN** | SoftEther VPN Server (x86_64), compiled and installed as a systemd service |
| **v2ray** | Containerized V2Ray in two roles: **Bridge** (entry server, e.g. in Iran) and **Upstream** (exit server abroad) |

## Requirements

- Ubuntu (tested on 20.04+; other distros may work with a warning)
- Root access (`sudo -i` or run as root)
- For the v2ray option: Docker (use option 1 first)

## Quick Start

```bash
git clone https://github.com/behnam2/oneclick-installer.git
cd oneclick-installer
sudo bash script.sh
```

Then pick an option from the menu:

```
=== OneClick Installer ===
1) Install Docker
2) Install SoftEther
3) Install v2ray
4) Exit
```

## v2ray: Bridge & Upstream Architecture

This repo ships a two-hop V2Ray setup — useful when you want clients to connect to a local (bridge) server which forwards traffic to a foreign (upstream) server:

```
Client → Bridge server (VMESS/SOCKS/HTTP/Shadowsocks) → Upstream server (VMESS+WS) → Internet
```

### 1. Set up the Upstream server (abroad, run first)

Choose **Install v2ray → Upstream-server**. You'll be asked for:

- **Upstream UUID** — a shared secret; generate one with `uuidgen` (save it, the bridge needs it)
- **Upstream port** — the port VMESS listens on (e.g. `443`)
- **Instance name** — a label; configs are written to `v2ray/v2ray-upstream-<name>/`

### 2. Set up the Bridge server (local entry point)

Choose **Install v2ray → Bridge-server**. You'll be asked for:

- **Upstream IP / port / UUID** — from step 1
- **Bridge port** — the VMESS port clients connect to
- **Instance name** — configs are written to `v2ray/v2ray-bridge-<name>/`

After the container starts, the script prints ready-to-import client links:

- `vmess://...` (TCP, direct to bridge)
- `ss://...` (Shadowsocks, random auto-generated password)
- Local `SOCKS` (`127.0.0.1:1010`) and `HTTP` (`127.0.0.1:1110`) inbounds

The bridge config also routes `*.ir` and `*.cab` domains directly (bypassing the upstream).

### Managing instances

Each instance is a plain docker-compose project:

```bash
cd v2ray/v2ray-bridge-myserver
docker compose logs -f
docker compose restart
docker compose down
```

## Notes & Security

- Run the script as **root** — it checks and refuses otherwise.
- The SoftEther installer downloads a pinned binary (`v4.38-9760`) from this account's `Needed-Files` repo.
- When you select "server is in Iran" during Docker installation, the script temporarily prepends the [Shecan](https://shecan.ir) DNS resolver to work around Docker Hub sanctions; your original `resolv.conf` is backed up to `/etc/resolv.conf.bak`.
- Generated instance folders and logs are gitignored — keep your UUIDs and passwords private.
- The V2Ray images use `b3hnam/v2ray:v4.45.2` (V2Ray 4.x core).

## Roadmap

The script is under active development — more protocols and options are planned. Contributions, issues and suggestions are welcome!

## License

Apache License 2.0 — see [LICENSE](LICENSE).
