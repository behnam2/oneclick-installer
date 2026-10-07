# OneClick Installer

A single interactive Bash script to set up your own VPN server with one command — no manual configuration needed. Select an option from the menu and you're good to go.

## What It Can Install

| Option | Description |
|---|---|
| **Docker** | Full Docker Engine + Compose plugin (with an optional DNS workaround for servers located in Iran) |
| **SoftEther VPN** | SoftEther VPN Server (x86_64), compiled and installed as a systemd service |
| **v2ray** | Containerized V2Ray in two roles: **Bridge** (entry server, e.g. in Iran) and **Upstream** (exit server abroad) |
| **Squid Proxy** | Containerized Squid forward proxy with basic auth, IP allowlist and optional upstream chaining |
| **IPsec VPN** | IPsec/L2TP & IKEv2 server via [hwdsl2/setup-ipsec-vpn](https://github.com/hwdsl2/setup-ipsec-vpn) |
| **P-Node** | Xray/SSH node agent via [miladrahimi/p-node](https://github.com/miladrahimi/p-node) |
| **P-Manager** | Web-based Xray/SSH proxy management panel via [miladrahimi/p-manager](https://github.com/miladrahimi/p-manager) |
| **vpn-ui Panel** | Multi-protocol VPN panel via [Sir-MmD/vpn-ui](https://github.com/Sir-MmD/vpn-ui) |
| **SNI Proxy** | DNS-based sanctions bypass (dnsmasq + sniproxy + dnsproxy + xray), inspired by [shervinamd/sni-proxy](https://github.com/shervinamd/sni-proxy) |

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
4) Install Squid Proxy
5) Install IPsec VPN
6) Install P-Node
7) Install P-Manager
8) Install vpn-ui Panel
9) Install SNI Proxy
10) Exit
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

## Squid Proxy (HTTP/SOCKS forward proxy with auth)

Choose **Install Squid Proxy** to deploy the [squid-proxy-auth](https://github.com/behnam2/squid-proxy-auth) container. The script asks for:

- **Username / password** — proxy authentication
- **Listen port** — default `3128`
- **Instance name** — configs are written to `squid/<name>/`
- **Allowed IPs** (optional) — comma-separated source IPs that skip authentication
- **Upstream cache_peer** (optional) — chain through another proxy, e.g. `203.0.113.5 3128`, with an option to force **all** traffic through it

Example after setup:

```bash
curl -x http://myuser:mypass@<server>:3128 https://example.com
```

Manage it like any compose project:

```bash
cd squid/squidproxy
docker compose logs -f
docker compose down
```

The generated `.env` file (mode `600`) contains your credentials — keep it private.

## IPsec VPN

Choose **Install IPsec VPN** to deploy an IPsec/L2TP and IKEv2 server using the well-known [hwdsl2/setup-ipsec-vpn](https://github.com/hwdsl2/setup-ipsec-vpn) script.

The script optionally asks for a PSK, username and password — leave any of them empty to auto-generate random credentials. Credentials are printed at the end of the installation; save them.

Client setup guides: see the upstream repo's README.

## P-Node & P-Manager

These two work together — [P-Manager](https://github.com/miladrahimi/p-manager) is the central web panel, [P-Node](https://github.com/miladrahimi/p-node) is the agent you install on each node server.

### P-Node (option 6)

Installs via the official one-line installer. At the end it prints JSON blobs (Full / Xray-only / SSH-only) — paste the matching one into P-Manager's **Add Node** input.

### P-Manager (option 7)

Clones the repo into `/opt/p-manager` (customizable) and runs `make setup`. Then:

- Admin panel: `http://<server>:8080`
- Default credentials: `admin` / `password` — **change immediately**
- Config file: `/opt/p-manager/configs/main.json`

If the directory already exists, the option runs `make update` instead.

## vpn-ui Panel

Choose **Install vpn-ui Panel** to deploy [Sir-MmD/vpn-ui](https://github.com/Sir-MmD/vpn-ui) — a multi-protocol panel (L2TP/IPsec, PPTP, OpenVPN, OpenConnect, SSTP, IKEv2, WireGuard, AmneziaWG, MTProto, SSH tunnel, GRE) via the official `deploy.sh`.

After installation, run `vpn-ui` for the management menu. Uninstall with:

```bash
sudo /opt/vpn-ui/vpn-ui-amd64 --uninstall
```

## SNI Proxy

Choose **Install SNI Proxy** to set up DNS-based sanctions bypass, inspired by [shervinamd/sni-proxy](https://github.com/shervinamd/sni-proxy). Client devices just change their DNS to this server — no apps needed.

The script asks for:

| Prompt | Description |
|---|---|
| Server public IP | Auto-detected from `hostname -I` |
| VMESS server address/port/UUID | Your outbound server — e.g. an **Upstream-server** from option 3 |
| VMESS ws path | Default `/` |
| Instance name | Default `sni-proxy`; configs go to `sni-proxy/<name>/` |

It then generates the Xray outbound config, creates an isolated Docker network (`<name>-net`, `192.168.25.0/24`), and starts three containers: `xray` (SOCKS outbound), `dnsproxy` (DoH upstream) and `sni` (dnsmasq + sniproxy on ports 53/80/443).

After installation, point your clients' DNS to the server IP.

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
