#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Colors & messaging ----------
if [ -t 1 ]; then
	C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
	C_BLU=$'\033[0;34m'; C_CYN=$'\033[0;36m'; C_RST=$'\033[0m'
else
	C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_CYN=""; C_RST=""
fi

info()    { echo "${C_BLU}[*]${C_RST} $*"; }
success() { echo "${C_GRN}[+]${C_RST} $*"; }
warn()    { echo "${C_YLW}[!]${C_RST} $*"; }
error()   { echo "${C_RED}[-]${C_RST} $*" >&2; }
step()    { echo ""; echo "${C_CYN}==> $*${C_RST}"; }

# Generic cancel marker: users can type 'b' (back) or 'q' (quit) at any prompt.
__CANCEL=0

# ---------- Helpers ----------
function sudocheck {
	if [ "$(id -u)" != "0" ]; then
		error "This script must be run as root (use: sudo bash script.sh)"
		exit 1
	fi
}

function os_version_check {
	if grep -qi "ubuntu" /etc/os-release; then
		info "Detected Ubuntu."
	else
		warn "This script is tested on Ubuntu. Your distro may not be fully supported."
		if ! confirm "Continue anyway?"; then
			info "Aborted. Have a good day!"
			exit 0
		fi
	fi
}

# confirm "Question?" -> returns 0 on yes, 1 on no (default: no)
function confirm {
	local q="$1" ans
	read -r -p "$q [y/N]: " ans
	ans="${ans,,}"
	[ "$ans" = "y" ] || [ "$ans" = "yes" ]
}

# ask VAR_NAME "Prompt" [default] [required]
# - empty input keeps the default
# - 'b' => returns 1 (back), 'q' => exit script
# - if 'required' is passed as 4th arg, empty without default re-asks
function ask {
	local var="$1" prompt="$2" default="${3:-}" required="${4:-}" value
	while true; do
		if [ -n "$default" ]; then
			read -r -p "$prompt [$default] (b=back, q=quit): " value
		else
			read -r -p "$prompt (b=back, q=quit): " value
		fi
		value="${value:-$default}"
		case "${value,,}" in
			q|quit|exit) info "Goodbye!"; exit 0 ;;
			b|back) __CANCEL=1; return 1 ;;
		esac
		if [ -n "$value" ] || [ "$required" != "required" ]; then
			printf -v "$var" '%s' "$value"
			return 0
		fi
		warn "This field is required."
	done
}

# require_docker: returns 1 (with guidance) if docker/compose missing
function require_docker {
	if ! command -v docker &> /dev/null; then
		error "Docker is not installed. Run option 1 (Install Docker) first."
		return 1
	fi
	if ! docker compose version &> /dev/null; then
		error "The docker compose plugin is missing. Run option 1 (Install Docker) first."
		return 1
	fi
	return 0
}

function install_docker {
	os_version_check
	sudocheck

	step "Installing Docker Engine"
	apt-get update && apt-get install -y \
		ca-certificates \
		curl \
		gnupg \
		lsb-release

	# Iran: use Shecan DNS to reach Docker repos (sanctions workaround)
	if confirm "Is this server located in Iran (apply DNS workaround)?"; then
		info "Applying Shecan DNS (178.22.122.100). Backup saved to /etc/resolv.conf.bak"
		cp /etc/resolv.conf /etc/resolv.conf.bak
		sed -i '1 i\nameserver 178.22.122.100' /etc/resolv.conf
	fi

	mkdir -m 0755 -p /etc/apt/keyrings
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
	echo \
		"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
		$(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

	apt-get update
	apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

	success "Docker installed successfully!"
	docker version
}

function install_softether {
	sudocheck
	os_version_check

	if [ "$(uname -m)" != "x86_64" ]; then
		error "This installer only supports x86_64 architecture."
		return 1
	fi

	step "Installing SoftEther VPN Server"
	apt-get update -y
	apt-get install -y build-essential gnupg2 gcc make wget

	local tarball="softether-vpnserver-v4.38-9760-rtm-2021.08.17-linux-x64-64bit.tar.gz"
	wget "https://github.com/behnam2/Needed-Files/raw/main/$tarball"
	tar -xvzf "$tarball"
	rm -f "$tarball"

	pushd vpnserver > /dev/null
	make
	popd > /dev/null

	mv vpnserver /usr/local/
	pushd /usr/local/vpnserver/ > /dev/null
	chmod 600 ./*
	chmod 700 vpnserver
	chmod 700 vpncmd

	cat << 'EOF' > /etc/init.d/vpnserver
#!/bin/sh
# chkconfig: 2345 99 01
# description: SoftEther VPN Server
DAEMON=/usr/local/vpnserver/vpnserver
LOCK=/var/lock/subsys/vpnserver
test -x $DAEMON || exit 0
case "$1" in
start)
$DAEMON start
touch $LOCK
;;
stop)
$DAEMON stop
rm -f $LOCK
;;
restart)
$DAEMON stop
sleep 3
$DAEMON start
;;
*)
echo "Usage: $0 {start|stop|restart}"
exit 1
esac
exit 0
EOF

	chmod 755 /etc/init.d/vpnserver
	/etc/init.d/vpnserver start
	update-rc.d vpnserver defaults
	systemctl daemon-reload
	systemctl enable vpnserver
	popd > /dev/null

	success "SoftEther VPN Server installed and started!"
	info "Manage it with: /usr/local/vpnserver/vpncmd"
}

function install_v2ray_bridge {
	sudocheck

	step "Setting up v2ray Bridge server (entry)"
	info "Leave any field empty and type 'b' to go back, 'q' to quit."

	local UIP Uport UPuuid Bport name
	ask UIP    "Upstream server IP" "" required || { warn "Cancelled."; return 1; }
	ask Uport  "Upstream server port" "" required || { warn "Cancelled."; return 1; }
	ask UPuuid "Upstream UUID (empty = generate random)" "" || { warn "Cancelled."; return 1; }
	UPuuid="${UPuuid:-$(uuidgen)}"
	ask Bport  "Bridge listen port" "" required || { warn "Cancelled."; return 1; }
	ask name   "Instance name" "bridge" || { warn "Cancelled."; return 1; }

	local dir="$SCRIPT_DIR/v2ray/v2ray-bridge-$name"
	cp -r "$SCRIPT_DIR/v2ray/v2ray-bridge-server" "$dir"

	local ss_pass bridge_uuid
	ss_pass="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)"
	bridge_uuid="$(uuidgen)"

	sed -i "s/Bport/$Bport/g" "$dir/docker-compose.yml"
	sed -i "s/Name/$name/g" "$dir/docker-compose.yml"
	sed -i "s/BRIDGE-PORT/$Bport/g" "$dir/config/config.json"
	sed -i "s/UPSTREAM-IP/$UIP/g" "$dir/config/config.json"
	sed -i "s/UPSTREAM-PORT/$Uport/g" "$dir/config/config.json"
	sed -i "s/BRIDGE-UUID/$bridge_uuid/g" "$dir/config/config.json"
	sed -i "s/UPSTREAM-UUID/$UPuuid/g" "$dir/config/config.json"
	sed -i "s/<SHADOWSOCKS-PASSWORD>/$ss_pass/g" "$dir/config/config.json"

	pushd "$dir" > /dev/null
	docker compose up -d
	python3 clients.py
	popd > /dev/null

	echo ""
	success "Bridge server '$name' is up! Config saved to: $dir"
	echo "  Bridge UUID (clients):      $bridge_uuid"
	echo "  Upstream UUID:              $UPuuid"
	echo "  Shadowsocks password:       $ss_pass"
	echo "  SOCKS/HTTP local ports:     1010 / 1110"
}

function install_v2ray_upstream {
	sudocheck

	step "Setting up v2ray Upstream server (exit)"
	local UPuuid Uport name
	ask UPuuid "Upstream UUID (empty = generate random)" "" || { warn "Cancelled."; return 1; }
	UPuuid="${UPuuid:-$(uuidgen)}"
	ask Uport  "Upstream port" "" required || { warn "Cancelled."; return 1; }
	ask name   "Instance name" "upstream" || { warn "Cancelled."; return 1; }

	local dir="$SCRIPT_DIR/v2ray/v2ray-upstream-$name"
	cp -r "$SCRIPT_DIR/v2ray/v2ray-upstream-server" "$dir"

	sed -i "s/Uport/$Uport/g" "$dir/docker-compose.yml"
	sed -i "s/Name/$name/g" "$dir/docker-compose.yml"
	sed -i "s/UPSTREAM-PORT/$Uport/g" "$dir/config/config.json"
	sed -i "s/UPSTREAM-UUID/$UPuuid/g" "$dir/config/config.json"

	pushd "$dir" > /dev/null
	docker compose up -d
	popd > /dev/null

	echo ""
	success "Upstream server '$name' is up! Config saved to: $dir"
	echo "  Upstream UUID: $UPuuid"
	echo "  Upstream port: $Uport"
	info "Use this UUID when setting up Bridge servers (option 3 -> Bridge)."
}

function install_v2ray {
	require_docker || return 1

	while true; do
		step "v2ray — choose a role"
		select role in "Bridge-server (Iran/entry)" "Upstream-server (exit)" "Back to main menu" "Quit"; do
			case $REPLY in
				1) install_v2ray_bridge; break ;;
				2) install_v2ray_upstream; break ;;
				3) return 0 ;;
				4) info "Goodbye!"; exit 0 ;;
				*) error "Invalid option. Pick 1-4." ;;
			esac
		done
	done
}

function install_squid {
	sudocheck
	require_docker || return 1

	step "Setting up Squid proxy"
	local PROXY_USERNAME PROXY_PASSWORD PROXY_PORT name ALLOWED_IPS CACHE_PEER
	ask PROXY_USERNAME "Proxy username" "" required || { warn "Cancelled."; return 1; }
	ask PROXY_PASSWORD "Proxy password" "" required || { warn "Cancelled."; return 1; }
	ask PROXY_PORT     "Listen port" "3128" || { warn "Cancelled."; return 1; }
	ask name           "Instance name" "squidproxy" || { warn "Cancelled."; return 1; }
	ask ALLOWED_IPS    "Allowed IPs without auth (comma-separated, empty for none)" "" || { warn "Cancelled."; return 1; }
	ask CACHE_PEER     "Upstream cache_peer (e.g. '203.0.113.5 3128', empty for none)" "" || { warn "Cancelled."; return 1; }

	local never_direct=""
	if [ -n "$CACHE_PEER" ] && confirm "Force ALL traffic through the peer?"; then
		never_direct="1"
	fi

	local dir="$SCRIPT_DIR/squid/$name"
	mkdir -p "$dir"

	{
		echo "PROXY_USERNAME=$PROXY_USERNAME"
		echo "PROXY_PASSWORD=$PROXY_PASSWORD"
		echo "PROXY_PORT=$PROXY_PORT"
		echo "CONTAINER_NAME=$name"
		echo "CACHE_VOLUME_NAME=$name-cache"
		[ -n "$ALLOWED_IPS" ] && echo "ALLOWED_IPS=$ALLOWED_IPS"
		[ -n "$CACHE_PEER" ] && echo "CACHE_PEER=$CACHE_PEER"
		[ -n "$never_direct" ] && echo "CACHE_PEER_NEVER_DIRECT=1"
	} > "$dir/.env"
	chmod 600 "$dir/.env"

	cat << 'EOF' > "$dir/docker-compose.yml"
services:
  squid:
    image: b3hnam/squid-proxy-auth:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${PROXY_PORT}:3128"
    environment:
      PROXY_USERNAME: ${PROXY_USERNAME}
      PROXY_PASSWORD: ${PROXY_PASSWORD}
      ALLOWED_IPS: ${ALLOWED_IPS:-}
      CACHE_PEER: ${CACHE_PEER:-}
      CACHE_PEER_NEVER_DIRECT: ${CACHE_PEER_NEVER_DIRECT:-}
    volumes:
      - squid-cache:/var/spool/squid

volumes:
  squid-cache:
    name: ${CACHE_VOLUME_NAME}
EOF

	pushd "$dir" > /dev/null
	docker compose up -d
	popd > /dev/null

	echo ""
	success "Squid proxy '$name' is up on port $PROXY_PORT!"
	info "Test it:  curl -x http://$PROXY_USERNAME:****@<this-server>:$PROXY_PORT https://example.com"
	info "Manage:   cd $dir && docker compose logs -f"
}

function install_ipsec {
	sudocheck

	step "Installing IPsec/L2TP & IKEv2 VPN (hwdsl2/setup-ipsec-vpn)"
	local VPN_IPSEC_PSK VPN_USER VPN_PASSWORD
	ask VPN_IPSEC_PSK "IPsec PSK (empty = random)" "" || { warn "Cancelled."; return 1; }
	ask VPN_USER      "VPN username (empty = random)" "" || { warn "Cancelled."; return 1; }
	read -r -s -p "VPN password (empty = random, input hidden): " VPN_PASSWORD
	echo ""
	stty sane 2>/dev/null || true   # restore terminal echo after hidden input

	export VPN_IPSEC_PSK VPN_USER VPN_PASSWORD
	wget -q https://get.vpnsetup.net -O /tmp/vpnsetup.sh
	# run in a subshell so the upstream script's 'exit' doesn't kill our script
	( sh /tmp/vpnsetup.sh ) || warn "The IPsec installer reported a non-zero status."
	stty sane 2>/dev/null || true
	rm -f /tmp/vpnsetup.sh

	success "IPsec VPN installed! Credentials are shown above — save them."
}

function install_pnode {
	sudocheck

	step "Installing P-Node (miladrahimi/p-node)"
	info "Using the official one-line installer..."
	( curl -fsSL https://raw.githubusercontent.com/miladrahimi/p-node/master/scripts/install.sh | bash ) || warn "The P-Node installer reported a non-zero status."
	stty sane 2>/dev/null || true

	echo ""
	success "P-Node installed!"
	info "Copy the JSON printed above into P-Manager -> 'Add Node'."
}

function install_pmanager {
	sudocheck

	step "Installing P-Manager (miladrahimi/p-manager)"
	local pm_dir
	ask pm_dir "Install directory" "/opt/p-manager" || { warn "Cancelled."; return 1; }

	if [ -d "$pm_dir" ]; then
		warn "Directory $pm_dir already exists — running 'make update' instead..."
		make -C "$pm_dir" update
		return 0
	fi

	apt-get -y update
	apt-get -y install make wget curl jq vim git openssl cron openssh-client

	git clone https://github.com/miladrahimi/p-manager.git "$pm_dir"
	make -C "$pm_dir" setup

	echo ""
	success "P-Manager installed! Admin panel: http://<this-server>:8080"
	warn "Default credentials: admin / password  (change them immediately!)"
	info "Config file: $pm_dir/configs/main.json"
}

function install_vpnui {
	sudocheck

	step "Installing vpn-ui panel (Sir-MmD/vpn-ui)"
	info "Using the official deploy script..."
	( curl -Ls https://raw.githubusercontent.com/Sir-MmD/vpn-ui/refs/heads/main/deploy.sh | bash ) || warn "The vpn-ui installer reported a non-zero status."
	stty sane 2>/dev/null || true

	echo ""
	success "vpn-ui installed! Management menu: run 'vpn-ui'"
}

function install_sniproxy {
	sudocheck
	require_docker || return 1

	step "Setting up SNI Proxy (inspired by shervinamd/sni-proxy)"
	info "Bypass geo-restricted services by changing DNS settings only."
	info "You need a VMESS (ws) outbound, e.g. an upstream from option 3."
	echo ""

	local SNI_HOST_IP XRAY_SERVER XRAY_PORT XRAY_UUID XRAY_PATH name
	local default_ip
	default_ip="$(hostname -I | awk '{print $1}')"
	ask SNI_HOST_IP "This server's public IP" "$default_ip" || { warn "Cancelled."; return 1; }
	ask XRAY_SERVER "VMESS server address" "" required || { warn "Cancelled."; return 1; }
	ask XRAY_PORT   "VMESS server port" "443" || { warn "Cancelled."; return 1; }
	ask XRAY_UUID   "VMESS UUID (empty = generate random)" "" || { warn "Cancelled."; return 1; }
	XRAY_UUID="${XRAY_UUID:-$(uuidgen)}"
	ask XRAY_PATH   "VMESS ws path" "/" || { warn "Cancelled."; return 1; }
	ask name        "Instance name" "sni-proxy" || { warn "Cancelled."; return 1; }

	local dir="$SCRIPT_DIR/sni-proxy/$name"
	mkdir -p "$dir"
	cp "$SCRIPT_DIR/sni-proxy/sniproxy.conf" \
	   "$SCRIPT_DIR/sni-proxy/dnsproxy-config.yaml" \
	   "$SCRIPT_DIR/sni-proxy/dnsmasq.conf" \
	   "$SCRIPT_DIR/sni-proxy/docker-compose.yml" \
	   "$SCRIPT_DIR/sni-proxy/xray-config.json" "$dir/"

	sed -i "s|SERVER_ADDRESS|$XRAY_SERVER|g" "$dir/xray-config.json"
	sed -i "s|SERVER_PORT|$XRAY_PORT|g" "$dir/xray-config.json"
	sed -i "s|SERVER_UUID|$XRAY_UUID|g" "$dir/xray-config.json"
	sed -i "s|WS_PATH|$XRAY_PATH|g" "$dir/xray-config.json"

	local net_name="${name}-net"
	local subnet="192.168.25.0/24"
	local gateway="192.168.25.254"
	local sni_ip="192.168.25.10"
	local dns_ip="192.168.25.11"
	local xray_ip="192.168.25.12"

	{
		echo "COMPOSE_PROJECT_NAME=$name"
		echo "SNI_HOST_IP=$SNI_HOST_IP"
		echo "SNI_NETWORK_NAME=$net_name"
		echo "SNI_CONTAINER_IP=$sni_ip"
		echo "DNS_PROXY_CONTAINER_IP=$dns_ip"
		echo "XRAY_CONTAINER_IP=$xray_ip"
		echo "SOCKS_SERVICE_PORT=1080"
	} > "$dir/.env"
	chmod 600 "$dir/.env"

	if ! docker network inspect "$net_name" &> /dev/null; then
		docker network create \
			--driver=bridge \
			--subnet="$subnet" \
			--ip-range="$subnet" \
			--gateway="$gateway" \
			"$net_name"
	fi

	pushd "$dir" > /dev/null
	docker compose pull
	docker compose up -d
	popd > /dev/null

	echo ""
	success "SNI Proxy '$name' is up!"
	echo "  VMESS outbound: $XRAY_SERVER:$XRAY_PORT (UUID: $XRAY_UUID, path: $XRAY_PATH)"
	info "Now set the DNS of your client devices to: $SNI_HOST_IP"
	info "Manage: cd $dir && docker compose logs -f"
}

# --- Main menu ---
clear
echo "${C_CYN}=== OneClick Installer ===${C_RST}"
info "Pick an option. Inside prompts: 'b' = back, 'q' = quit."
while true; do
	echo ""
	select option in "Install Docker" "Install SoftEther" "Install v2ray" "Install Squid Proxy" "Install IPsec VPN" "Install P-Node" "Install P-Manager" "Install vpn-ui Panel" "Install SNI Proxy" "Exit"; do
		case $REPLY in
			1) install_docker; break ;;
			2) install_softether; break ;;
			3) install_v2ray; break ;;
			4) install_squid; break ;;
			5) install_ipsec; break ;;
			6) install_pnode; break ;;
			7) install_pmanager; break ;;
			8) install_vpnui; break ;;
			9) install_sniproxy; break ;;
			10) info "Have a nice day :)"; exit 0 ;;
			*) error "Invalid option. Pick 1-10." ;;
		esac
	done
done
