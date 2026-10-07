#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function sudocheck {
	if [ "$(id -u)" != "0" ]; then
		echo "Please run this script as root (e.g. sudo -i or sudo bash script.sh)"
		exit 1
	fi
}

function os_version_check {
	if grep -qi "ubuntu" /etc/os-release; then
		echo "Detected Ubuntu."
	else
		echo "This script is tested on Ubuntu. Your distro may not be supported."
		read -r -p "Continue anyway? [y/N]: " prompt
		prompt="${prompt,,}"
		if [ "$prompt" != "y" ] && [ "$prompt" != "yes" ]; then
			echo "OK, have a good day!"
			exit 0
		fi
	fi
}

function location_check {
	while true; do
		read -r -p "Is this server located in Iran? [y/N]: " iran
		iran="${iran,,}"
		case "$iran" in
			y|yes) IS_IRAN=1; return 0 ;;
			n|no|"") IS_IRAN=0; return 0 ;;
			*) echo "Please answer y or n." ;;
		esac
	done
}

function install_docker {
	os_version_check
	sudocheck

	apt-get update && apt-get install -y \
		ca-certificates \
		curl \
		gnupg \
		lsb-release

	# Iran: use Shecan DNS to reach Docker repos (sanctions workaround)
	location_check
	if [ "$IS_IRAN" = "1" ]; then
		echo "Setting Shecan DNS (178.22.122.100) for this session..."
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

	echo "Docker installed successfully!"
	docker version
}

function install_softether {
	sudocheck
	os_version_check

	if [ "$(uname -m)" != "x86_64" ]; then
		echo "This installer only supports x86_64 architecture."
		exit 1
	fi

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

	echo "SoftEther VPN Server installed and started!"
	echo "Manage it with: /usr/local/vpnserver/vpncmd"
}

function install_v2ray_bridge {
	sudocheck

	read -r -p "Enter your upstream server IP: " UIP
	read -r -p "Enter your upstream server port: " Uport
	read -r -p "Enter your upstream UUID: " UPuuid
	read -r -p "Enter your bridge listen port: " Bport
	read -r -p "Instance name: " name

	local dir="$SCRIPT_DIR/v2ray/v2ray-bridge-$name"
	cp -r "$SCRIPT_DIR/v2ray/v2ray-bridge-server" "$dir"

	# Generate random shadowsocks password
	local ss_pass
	ss_pass="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)"

	sed -i "s/Bport/$Bport/g" "$dir/docker-compose.yml"
	sed -i "s/Name/$name/g" "$dir/docker-compose.yml"
	sed -i "s/BRIDGE-PORT/$Bport/g" "$dir/config/config.json"
	sed -i "s/UPSTREAM-IP/$UIP/g" "$dir/config/config.json"
	sed -i "s/UPSTREAM-PORT/$Uport/g" "$dir/config/config.json"
	sed -i "s/BRIDGE-UUID/$(uuidgen)/g" "$dir/config/config.json"
	sed -i "s/UPSTREAM-UUID/$UPuuid/g" "$dir/config/config.json"
	sed -i "s/<SHADOWSOCKS-PASSWORD>/$ss_pass/g" "$dir/config/config.json"

	pushd "$dir" > /dev/null
	docker compose up -d
	python3 clients.py
	popd > /dev/null

	echo "Bridge server '$name' is up! Config saved to: $dir"
}

function install_v2ray_upstream {
	sudocheck

	read -r -p "Enter your upstream UUID: " UPuuid
	read -r -p "Enter your upstream port: " Uport
	read -r -p "Instance name: " name

	local dir="$SCRIPT_DIR/v2ray/v2ray-upstream-$name"
	cp -r "$SCRIPT_DIR/v2ray/v2ray-upstream-server" "$dir"

	sed -i "s/Uport/$Uport/g" "$dir/docker-compose.yml"
	sed -i "s/Name/$name/g" "$dir/docker-compose.yml"
	sed -i "s/UPSTREAM-PORT/$Uport/g" "$dir/config/config.json"
	sed -i "s/UPSTREAM-UUID/$UPuuid/g" "$dir/config/config.json"

	pushd "$dir" > /dev/null
	docker compose up -d
	popd > /dev/null

	echo "Upstream server '$name' is up! Config saved to: $dir"
}

function install_v2ray {
	if ! command -v docker &> /dev/null; then
		echo "Docker is not installed. Please install Docker first (option 1)."
		return 1
	fi
	if ! docker compose version &> /dev/null; then
		echo "docker compose plugin not found. Please install Docker first (option 1)."
		return 1
	fi

	while true; do
		select role in "Bridge-server (Iran/entry)" "Upstream-server (exit)" "Back"; do
			case $REPLY in
				1) install_v2ray_bridge; break ;;
				2) install_v2ray_upstream; break ;;
				3) return 0 ;;
				*) echo "Invalid option." ;;
			esac
		done
	done
}

function install_squid {
	sudocheck

	if ! command -v docker &> /dev/null; then
		echo "Docker is not installed. Please install Docker first (option 1)."
		return 1
	fi
	if ! docker compose version &> /dev/null; then
		echo "docker compose plugin not found. Please install Docker first (option 1)."
		return 1
	fi

	read -r -p "Proxy username: " PROXY_USERNAME
	read -r -p "Proxy password: " PROXY_PASSWORD
	read -r -p "Listen port [3128]: " PROXY_PORT
	PROXY_PORT="${PROXY_PORT:-3128}"
	read -r -p "Instance name [squidproxy]: " name
	name="${name:-squidproxy}"
	read -r -p "Allowed IPs without auth (comma-separated, empty for none): " ALLOWED_IPS
	read -r -p "Upstream cache_peer (e.g. '203.0.113.5 3128', empty for none): " CACHE_PEER

	local never_direct=""
	if [ -n "$CACHE_PEER" ]; then
		read -r -p "Force ALL traffic through the peer? [y/N]: " nd
		nd="${nd,,}"
		[ "$nd" = "y" ] || [ "$nd" = "yes" ] && never_direct="1"
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
	echo "Squid proxy '$name' is up on port $PROXY_PORT!"
	echo "Test it:  curl -x http://$PROXY_USERNAME:****@<this-server>:$PROXY_PORT https://example.com"
	echo "Manage:   cd $dir && docker compose logs -f"
}

# --- Main menu ---
echo "=== OneClick Installer ==="
while true; do
	select option in "Install Docker" "Install SoftEther" "Install v2ray" "Install Squid Proxy" "Exit"; do
		case $REPLY in
			1) install_docker; break ;;
			2) install_softether; break ;;
			3) install_v2ray; break ;;
			4) install_squid; break ;;
			5) echo "Have a nice day :)"; exit 0 ;;
			*) echo "Invalid option." ;;
		esac
	done
done
