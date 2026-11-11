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

# ---------- Embedded templates (self-contained; no external files needed) ----------

function _write_file { local p="$1"; mkdir -p "$(dirname "$p")"; cat > "$p"; }

function tpl_v2ray_bridge_compose_write {
	_write_file "$1" << '__EOF_V2RAY_BRIDGE_COMPOSE__'
version: "3"

services:
  v2ray:
    container_name: Name
    image: b3hnam/v2ray:v4.45.2
    restart: always
    environment:
      - v2ray.vmess.aead.forced=false
    ports:
      - "Bport:Bport"
    volumes:
      - ./config/:/etc/v2ray/
      - ./logs:/var/log/v2ray/
__EOF_V2RAY_BRIDGE_COMPOSE__
}

function tpl_v2ray_bridge_config_write {
	_write_file "$1" << '__EOF_V2RAY_BRIDGE_CONFIG__'
{
  "log": {
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 1010,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      }
    },
    {
      "listen": "0.0.0.0",
      "port": 1110,
      "protocol": "http",
      "settings": {}
    },
    {
      "listen": "0.0.0.0",
      "port": 1210,
      "protocol": "shadowsocks",
      "settings": {
        "password": "<SHADOWSOCKS-PASSWORD>",
        "method": "aes-128-gcm",
        "level": 0,
        "network": "tcp,udp"
      }
    },
    {
      "listen": "0.0.0.0",
      "port": BRIDGE-PORT,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "BRIDGE-UUID",
            "alterId": 0,
            "security": "aes-128-gcm"
          }
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vmess",
      "settings": {
        "vnext": [
          {
            "address": "UPSTREAM-IP",
            "port": UPSTREAM-PORT,
            "users": [
              {
                "id": "UPSTREAM-UUID",
                "alterId": 0,
                "security": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws"
      },
      "mux": {
        "enabled": true
      }
    },
    {
      "protocol": "freedom",
      "tag": "freedom"
    }
  ],
  "dns": {
    "servers": [
      "8.8.8.8",
      "8.8.4.4",
      "localhost"
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "outboundTag": "freedom",
        "domain": [
          "regexp:.*\\.ir$",
          "regexp:.*\\.cab$"
        ]
      }
    ]
  }
}
__EOF_V2RAY_BRIDGE_CONFIG__
}

function tpl_v2ray_bridge_clients_write {
	_write_file "$1" << '__EOF_V2RAY_BRIDGE_CLIENTS__'
#!/usr/bin/python3

import base64
import json
import re
from pathlib import Path
from urllib.request import urlopen

path = Path(__file__).parent
file = open(str(path.joinpath('config/config.json')), 'r', encoding='utf-8')
config = json.load(file)

ip = urlopen("https://ipv4.icanhazip.com/").read().decode().rstrip()

for inbound in config['inbounds']:
    if inbound['protocol'] == 'socks':
        print("SOCKS: 127.0.0.1:{}".format(str(inbound['port'])))
    if inbound['protocol'] == 'http':
        print("HTTP: 127.0.0.1:{}".format(str(inbound['port'])))
    if inbound['protocol'] == 'shadowsocks':
        port = str(inbound['port'])
        method = inbound['settings']['method']
        password = inbound['settings']['password']
        security = base64.b64encode((method + ":" + password).encode('ascii')).decode('ascii')
        link = "ss://{}@{}:{}#{}:{}".format(security, ip, port, ip, port)
        print("\nShadowsocks:\n" + link)
    if inbound['protocol'] == 'vmess':
        port = str(inbound['port'])
        uuid = inbound['settings']['clients'][0]['id']
        security = inbound['settings']['clients'][0]['security']
        ps = "{}:{}".format(ip, port)
        c = {"add": ip, "aid": "0", "host": "", "id": uuid, "net": "tcp", "path": "", "port": port, "ps": ps,
             "tls": "none", "type": "none", "v": "2"}
        j = json.dumps(c)
        link = "vmess://" + base64.b64encode(j.encode('ascii')).decode('ascii')
        print("\nVMESS:\n" + link)
__EOF_V2RAY_BRIDGE_CLIENTS__
}

function tpl_v2ray_upstream_compose_write {
	_write_file "$1" << '__EOF_V2RAY_UPSTREAM_COMPOSE__'
version: "3"

services:
  v2ray:
    container_name: Name
    image: b3hnam/v2ray:v4.45.2
    restart: always
    environment:
      - v2ray.vmess.aead.forced=false
    ports:
      - "Uport:Uport"
    volumes:
      - ./config/:/etc/v2ray/
      - ./logs:/var/log/v2ray/
__EOF_V2RAY_UPSTREAM_COMPOSE__
}

function tpl_v2ray_upstream_config_write {
	_write_file "$1" << '__EOF_V2RAY_UPSTREAM_CONFIG__'
{
  "log": {
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": UPSTREAM-PORT,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "UPSTREAM-UUID",
            "alterId": 0,
            "security": "auto"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/"
        }
      },
      "mux": {
        "enabled": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "freedom"
    }
  ],
  "dns": {
    "servers": [
      "8.8.8.8",
      "8.8.4.4",
      "localhost"
    ]
  }
}
__EOF_V2RAY_UPSTREAM_CONFIG__
}

function tpl_sni_compose_write {
	_write_file "$1" << '__EOF_SNI_COMPOSE__'
name: ${COMPOSE_PROJECT_NAME}

services:
  dnsproxy:
    image: ${DNSPROXY_IMAGE_NAME:-b3hnam/dnsproxy}:${DNSPROXY_IMAGE_VERSION:-v0.84.2}
    container_name: ${COMPOSE_PROJECT_NAME}-dnsproxy
    environment:
      - SOCKS_IP=${XRAY_CONTAINER_IP}
      - SOCKS_PORT=${SOCKS_SERVICE_PORT}
    volumes:
      - ./dnsproxy-config.yaml:/service/config.yaml
    extra_hosts:
      - "cloudflare-dns.com:104.16.248.249"
      - "dns.google:8.8.8.8"
      - "dns.adguard.com:94.140.14.14"
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    dns: 1.1.1.1
    networks:
      sninet:
        ipv4_address: ${DNS_PROXY_CONTAINER_IP}
    depends_on:
      - xray
    restart: always

  sni:
    image: ${SNI_IMAGE_NAME:-b3hnam/sni-proxy}:${SNI_IMAGE_VERSION:-v1.5.0}
    container_name: ${COMPOSE_PROJECT_NAME}-sni
    environment:
      - SNI_HOST_IP=${SNI_HOST_IP}
      - DNS_PROXY_IP=${DNS_PROXY_CONTAINER_IP}
      - SOCKS_IP=${XRAY_CONTAINER_IP}
      - SOCKS_PORT=${SOCKS_SERVICE_PORT}
    volumes:
      - ./dnsmasq.conf:/etc/dnsmasq.sample
      - ./sniproxy.conf:/etc/sniproxy.sample
    ports:
      - "${SNI_HOST_IP}:53:53"
      - "${SNI_HOST_IP}:53:53/udp"
      - "${SNI_HOST_IP}:80:80"
      - "${SNI_HOST_IP}:443:443"
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    networks:
      sninet:
        ipv4_address: ${SNI_CONTAINER_IP}
    depends_on:
      - dnsproxy
    restart: unless-stopped

  xray:
    image: ${XRAY_IMAGE_NAME:-b3hnam/xray}:${XRAY_IMAGE_VERSION:-v26.3.27}
    container_name: ${COMPOSE_PROJECT_NAME}-xray
    volumes:
      - ./xray-config.json:/etc/xray/config.json
    dns: 1.1.1.1
    networks:
      sninet:
        ipv4_address: ${XRAY_CONTAINER_IP}
    restart: unless-stopped

networks:
  sninet:
    external: true
    name: ${SNI_NETWORK_NAME}
__EOF_SNI_COMPOSE__
}

function tpl_sni_sniproxy_write {
	_write_file "$1" << '__EOF_SNI_SNIPROXY__'
user daemon
pidfile /var/tmp/sniproxy.pid

error_log {
    filename /var/log/sniproxy/sniproxy.log
}

access_log {
    filename /var/log/sniproxy/sniproxy.log
}

listener 80 {
    proto http
}

listener 443 {
    proto tls
}

table {
    .* *
}

resolver {
  mode ipv4_only
  nameserver {DNS_PROXY_IP}
}
__EOF_SNI_SNIPROXY__
}

function tpl_sni_dnsproxy_write {
	_write_file "$1" << '__EOF_SNI_DNSPROXY__'
# This is the yaml configuration file for dnsproxy with minimal working
# configuration, all the options available can be seen with ./dnsproxy --help.
# To use it within dnsproxy specify the --config-path=/<path-to-config.yaml>
# option.  Any other command-line options specified will override the values
# from the config file.
---
#bootstrap:
  #- "8.8.8.8:53"
listen-addrs:
  - "0.0.0.0"
listen-ports:
  - 53
max-go-routines: 0
ratelimit: 0
ratelimit-subnet-len-ipv4: 24
ratelimit-subnet-len-ipv6: 64
udp-buf-size: 0
upstream:
  #- "1.1.1.1:53"
  #- "https://dns.google/dns-query"
  #- "https://dns.adguard.com/dns-query"
  #- "tcp://1.1.1.1"
  - "https://cloudflare-dns.com/dns-query"
timeout: '10s'
__EOF_SNI_DNSPROXY__
}

function tpl_sni_dnsmasq_write {
	_write_file "$1" << '__EOF_SNI_DNSMASQ__'
bind-dynamic
bogus-priv
domain-needed
log-queries
log-facility=-
#log-facility=/dnsmasq.log
local-ttl=60

address=/httpbin.org/{SNI_HOST_IP}
address=/000webhost.com/{SNI_HOST_IP}
address=/3docean.net/{SNI_HOST_IP}
address=/academy.yoast.com/{SNI_HOST_IP}
address=/accounts.google.com/{SNI_HOST_IP}
address=/aclanthology.org/{SNI_HOST_IP}
address=/adobe.com/{SNI_HOST_IP}
address=/adobelogin.com/{SNI_HOST_IP}
address=/adservice.google.com/{SNI_HOST_IP}
address=/ads.google.com/{SNI_HOST_IP}
address=/ai.google/{SNI_HOST_IP}
address=/akamaized.net/{SNI_HOST_IP}
address=/alexa.com/{SNI_HOST_IP}
address=/algolia.com/{SNI_HOST_IP}
address=/algolia.net/{SNI_HOST_IP}
address=/algolianet.com/{SNI_HOST_IP}
address=/alpinelinux.org/{SNI_HOST_IP}
address=/altera.com/{SNI_HOST_IP}
address=/altn.com/{SNI_HOST_IP}
address=/amazonaws.com/{SNI_HOST_IP}
address=/amazon.com/{SNI_HOST_IP}
address=/amd.com/{SNI_HOST_IP}
address=/amp.dev/{SNI_HOST_IP}
address=/analytics.google.com/{SNI_HOST_IP}
address=/android.com/{SNI_HOST_IP}
address=/androidstudio.googleblog.com/{SNI_HOST_IP}
address=/ant.design/{SNI_HOST_IP}
address=/anydesk.com/{SNI_HOST_IP}
address=/apache.org/{SNI_HOST_IP}
address=/api.daily.dev/{SNI_HOST_IP}
address=/api.envato.com/{SNI_HOST_IP}
address=/api.exactmetrics.com/{SNI_HOST_IP}
address=/api.facebook.com/{SNI_HOST_IP}
address=/api.flock.com/{SNI_HOST_IP}
address=/api.monsterinsights.com/{SNI_HOST_IP}
address=/api.myip.com/{SNI_HOST_IP}
address=/apis.google.com/{SNI_HOST_IP}
address=/api.telegram.org/{SNI_HOST_IP}
address=/api.tinify.com/{SNI_HOST_IP}
address=/api.wordpress.com/{SNI_HOST_IP}
address=/api.zarinpal.com/{SNI_HOST_IP}
address=/appengine.google.com/{SNI_HOST_IP}
address=/apple.com/{SNI_HOST_IP}
address=/apps.admob.com/{SNI_HOST_IP}
address=/appspot.com/{SNI_HOST_IP}
address=/arcgis.com/{SNI_HOST_IP}
address=/arpriceplugin.com/{SNI_HOST_IP}
address=/artbees.net/{SNI_HOST_IP}
address=/assets.gumroad.com/{SNI_HOST_IP}
address=/atlassian.com/{SNI_HOST_IP}
address=/atlassian.net/{SNI_HOST_IP}
address=/audiojungle.net/{SNI_HOST_IP}
address=/aws.amazon.com/{SNI_HOST_IP}
address=/azul.com/{SNI_HOST_IP}
address=/b4x.com/{SNI_HOST_IP}
address=/baeldung.com/{SNI_HOST_IP}
address=/balena.io/{SNI_HOST_IP}
address=/battlecode.org/{SNI_HOST_IP}
address=/bazel.build/{SNI_HOST_IP}
address=/beta.yoast.com/{SNI_HOST_IP}
address=/bigbluebutton.org/{SNI_HOST_IP}
address=/bintray.com/{SNI_HOST_IP}
address=/bitbucket.org/{SNI_HOST_IP}
address=/bit.dev/{SNI_HOST_IP}
address=/bit.ly/{SNI_HOST_IP}
address=/bitsrc.io/{SNI_HOST_IP}
address=/bitvise.com/{SNI_HOST_IP}
address=/bluemix.net/{SNI_HOST_IP}
address=/books.google.com/{SNI_HOST_IP}
address=/bootstrapcdn.com/{SNI_HOST_IP}
address=/bootswatch.com/{SNI_HOST_IP}
address=/branch.io/{SNI_HOST_IP}
address=/bugsnag.com/{SNI_HOST_IP}
address=/build.envato.com/{SNI_HOST_IP}
address=/business.google.com/{SNI_HOST_IP}
address=/c9.io/{SNI_HOST_IP}
address=/caddy.community/{SNI_HOST_IP}
address=/caddyserver.com/{SNI_HOST_IP}
address=/cdn-images.yoast.com/{SNI_HOST_IP}
address=/cdn.yoast.com/{SNI_HOST_IP}
address=/centos.org/{SNI_HOST_IP}
address=/chaquo.com/{SNI_HOST_IP}
address=/chat.yoast.com/{SNI_HOST_IP}
address=/chromium.org/{SNI_HOST_IP}
address=/cirros-cloud.net/{SNI_HOST_IP}
address=/cisco.com/{SNI_HOST_IP}
address=/clamav.net/{SNI_HOST_IP}
address=/classroom.google.com/{SNI_HOST_IP}
address=/clients2.google.com/{SNI_HOST_IP}
address=/clients6.google.com/{SNI_HOST_IP}
address=/clients.google.com/{SNI_HOST_IP}
address=/cljdoc.org/{SNI_HOST_IP}
address=/cloudbees.com/{SNI_HOST_IP}
address=/cloudera.com/{SNI_HOST_IP}
address=/cloudfront.net/{SNI_HOST_IP}
address=/cloud.google.com/{SNI_HOST_IP}
address=/cnet.com/{SNI_HOST_IP}
address=/cocalc.com/{SNI_HOST_IP}
address=/codecanyon.net/{SNI_HOST_IP}
address=/codecov.io/{SNI_HOST_IP}
address=/code.google.com/{SNI_HOST_IP}
address=/codegrepper.com/{SNI_HOST_IP}
address=/codepen.io/{SNI_HOST_IP}
address=/codesandbox.io/{SNI_HOST_IP}
address=/code.videolan.org/{SNI_HOST_IP}
address=/codex.cs.yale.edu/{SNI_HOST_IP}
address=/coinbase.com/{SNI_HOST_IP}
address=/compiles.overleaf.com/{SNI_HOST_IP}
address=/conan.io/{SNI_HOST_IP}
address=/consul.io/{SNI_HOST_IP}
address=/convertio.co/{SNI_HOST_IP}
address=/convertio.me/{SNI_HOST_IP}
address=/core.telegram.org/{SNI_HOST_IP}
address=/count.ly/{SNI_HOST_IP}
address=/coursehero.com/{SNI_HOST_IP}
address=/coursera-apps.org/{SNI_HOST_IP}
address=/coursera.com/{SNI_HOST_IP}
address=/coursera.org/{SNI_HOST_IP}
address=/cp.maxcdn.com/{SNI_HOST_IP}
address=/cppstories.com/{SNI_HOST_IP}
address=/crashlytics.com/{SNI_HOST_IP}
address=/csb.app/{SNI_HOST_IP}
address=/curd.io/{SNI_HOST_IP}
address=/dartlang.org/{SNI_HOST_IP}
address=/database.clamav.net/{SNI_HOST_IP}
address=/datacamp.com/{SNI_HOST_IP}
address=/datastudio.google.com/{SNI_HOST_IP}
address=/debian.org/{SNI_HOST_IP}
address=/dell.com/{SNI_HOST_IP}
address=/demandbase.com/{SNI_HOST_IP}
address=/demo.phlox.pro/{SNI_HOST_IP}
address=/demo.themegrill.com/{SNI_HOST_IP}
address=/demo.yoast.com/{SNI_HOST_IP}
address=/deno.land/{SNI_HOST_IP}
address=/deployer.org/{SNI_HOST_IP}
address=/design.google.com/{SNI_HOST_IP}
address=/developer.chrome.com/{SNI_HOST_IP}
address=/developer.google.com/{SNI_HOST_IP}
address=/developer.samsung.com/{SNI_HOST_IP}
address=/developers.google.com/{SNI_HOST_IP}
address=/dev.to/{SNI_HOST_IP}
address=/digikey.com/{SNI_HOST_IP}
address=/digitalocean.com/{SNI_HOST_IP}
address=/dl.google.com/{SNI_HOST_IP}
address=/dl-ssl.google.com/{SNI_HOST_IP}
address=/dns.google/{SNI_HOST_IP}
address=/dns.google.com/{SNI_HOST_IP}
address=/docker.com/{SNI_HOST_IP}
address=/docker.io/{SNI_HOST_IP}
address=/docs.datastax.com/{SNI_HOST_IP}
address=/docs.google.com/{SNI_HOST_IP}
address=/domains.google.com/{SNI_HOST_IP}
address=/dot.tk/{SNI_HOST_IP}
address=/doubleclickbygoogle.com/{SNI_HOST_IP}
address=/doubleclick.net/{SNI_HOST_IP}
address=/download.01.org/{SNI_HOST_IP}
address=/download.virtualbox.org/{SNI_HOST_IP}
address=/earthengine.google.com/{SNI_HOST_IP}
address=/econce.com/{SNI_HOST_IP}
address=/edgesuite.net/{SNI_HOST_IP}
address=/edx.org/{SNI_HOST_IP}
address=/elastic.co/{SNI_HOST_IP}
address=/element14.com/{SNI_HOST_IP}
address=/en25.com/{SNI_HOST_IP}
address=/enterprisedb.com/{SNI_HOST_IP}
address=/envato.com/{SNI_HOST_IP}
address=/envato.market/{SNI_HOST_IP}
address=/envato-static.com/{SNI_HOST_IP}
address=/epicgames.com/{SNI_HOST_IP}
address=/eslint.org/{SNI_HOST_IP}
address=/events.google.com/{SNI_HOST_IP}
address=/exactmetrics.com/{SNI_HOST_IP}
address=/exceedlms.com/{SNI_HOST_IP}
address=/explainshell.com/{SNI_HOST_IP}
address=/expo.dev/{SNI_HOST_IP}
address=/expo.io/{SNI_HOST_IP}
address=/expressjs.com/{SNI_HOST_IP}
address=/fabric.io/{SNI_HOST_IP}
address=/facebook.com/{SNI_HOST_IP}
address=/fbsbx.com/{SNI_HOST_IP}
address=/fedoramagazine.org/{SNI_HOST_IP}
address=/fedoraproject.org/{SNI_HOST_IP}
address=/feeds.yoast.com/{SNI_HOST_IP}
address=/fiber.google.com/{SNI_HOST_IP}
address=/#fillter/{SNI_HOST_IP}
address=/firebase.com/{SNI_HOST_IP}
address=/firebase.google.com/{SNI_HOST_IP}
address=/flaticon.com/{SNI_HOST_IP}
address=/flurry.com/{SNI_HOST_IP}
address=/fluttercrashcourse.com/{SNI_HOST_IP}
address=/flutter.dev/{SNI_HOST_IP}
address=/flutter.io/{SNI_HOST_IP}
address=/flutter-io.cn/{SNI_HOST_IP}
address=/flutterlearn.com/{SNI_HOST_IP}
address=/fodev.org/{SNI_HOST_IP}
address=/fontawesome.com/{SNI_HOST_IP}
address=/fortinet.com/{SNI_HOST_IP}
address=/forums.cpanel.net/{SNI_HOST_IP}
address=/freecodecamp.org/{SNI_HOST_IP}
address=/freedesktop.org/{SNI_HOST_IP}
address=/freenom.com/{SNI_HOST_IP}
address=/fsdn.com/{SNI_HOST_IP}
address=/fuchsia.dev/{SNI_HOST_IP}
address=/fusioncharts.com/{SNI_HOST_IP}
address=/gallery.io/{SNI_HOST_IP}
address=/gcr.io/{SNI_HOST_IP}
address=/geforce.com/{SNI_HOST_IP}
address=/getbootstrap.com/{SNI_HOST_IP}
address=/getcaddy.com/{SNI_HOST_IP}
address=/getliner.com/{SNI_HOST_IP}
address=/getwooplugins.com/{SNI_HOST_IP}
address=/githubapp.com/{SNI_HOST_IP}
address=/githubassets.com/{SNI_HOST_IP}
address=/github.com/{SNI_HOST_IP}
address=/github.io/{SNI_HOST_IP}
address=/githubusercontent.com/{SNI_HOST_IP}
address=/gitlab.com/{SNI_HOST_IP}
address=/gitlab.io/{SNI_HOST_IP}
address=/gitlab-static.net/{SNI_HOST_IP}
address=/gitpod.io/{SNI_HOST_IP}
address=/glitch.com/{SNI_HOST_IP}
address=/glitch.me/{SNI_HOST_IP}
address=/goanimate.com/{SNI_HOST_IP}
address=/godbolt.org/{SNI_HOST_IP}
address=/go.dev/{SNI_HOST_IP}
address=/godoc.org/{SNI_HOST_IP}
address=/golang.org/{SNI_HOST_IP}
address=/googleadservices.com/{SNI_HOST_IP}
address=/google.ai/{SNI_HOST_IP}
address=/google-analytics.com/{SNI_HOST_IP}
address=/googleapis.com/{SNI_HOST_IP}
address=/googlesource.com/{SNI_HOST_IP}
address=/googletagmanager.com/{SNI_HOST_IP}
address=/googletagservices.com/{SNI_HOST_IP}
address=/googleusercontent.com/{SNI_HOST_IP}
address=/gopkg.in/{SNI_HOST_IP}
address=/grabcad.com/{SNI_HOST_IP}
address=/gradle-dn.com/{SNI_HOST_IP}
address=/gradle.org/{SNI_HOST_IP}
address=/grafana.com/{SNI_HOST_IP}
address=/graphicriver.net/{SNI_HOST_IP}
address=/graphql.org/{SNI_HOST_IP}
address=/gravatar.com/{SNI_HOST_IP}
address=/gravityforms.com/{SNI_HOST_IP}
address=/gstatic.com/{SNI_HOST_IP}
address=/gurobi.com/{SNI_HOST_IP}
address=/gvt1.com/{SNI_HOST_IP}
address=/hackerrank.com/{SNI_HOST_IP}
address=/hackthebox.eu/{SNI_HOST_IP}
address=/heroku.com/{SNI_HOST_IP}
address=/highcharts.com/{SNI_HOST_IP}
address=/hotjar.com/{SNI_HOST_IP}
address=/hp.com/{SNI_HOST_IP}
address=/hpe.com/{SNI_HOST_IP}
address=/huawei.com/{SNI_HOST_IP}
address=/huggingface.co/{SNI_HOST_IP}
address=/hyper.is/{SNI_HOST_IP}
address=/i18next.com/{SNI_HOST_IP}
address=/ibm.com/{SNI_HOST_IP}
address=/ieee.org/{SNI_HOST_IP}
address=/ifconfig.co/{SNI_HOST_IP}
address=/igdb.com/{SNI_HOST_IP}
address=/incredibuild.com/{SNI_HOST_IP}
address=/intel.com/{SNI_HOST_IP}
address=/intellij.net/{SNI_HOST_IP}
address=/intranet.yoast.com/{SNI_HOST_IP}
address=/invis.io/{SNI_HOST_IP}
address=/invisionapp.com/{SNI_HOST_IP}
address=/ipinfo.io/{SNI_HOST_IP}
address=/iplocation.net/{SNI_HOST_IP}
address=/ipwhois.app/{SNI_HOST_IP}
address=/is.gd/{SNI_HOST_IP}
address=/issuetracker.google.com/{SNI_HOST_IP}
address=/i.stack.imgur.com/{SNI_HOST_IP}
address=/i-support.yoast.com/{SNI_HOST_IP}
address=/ivi.ru/{SNI_HOST_IP}
address=/ivi.tv/{SNI_HOST_IP}
address=/jaspersoft.com/{SNI_HOST_IP}
address=/javacardos.com/{SNI_HOST_IP}
address=/java.com/{SNI_HOST_IP}
address=/jenkins-ci.org/{SNI_HOST_IP}
address=/jenkins.org/{SNI_HOST_IP}
address=/jenkov.com/{SNI_HOST_IP}
address=/jetbrains.com/{SNI_HOST_IP}
address=/jetbrains.space/{SNI_HOST_IP}
address=/jetpack.com/{SNI_HOST_IP}
address=/jetpack.wordpress.com/{SNI_HOST_IP}
address=/jfrog.io/{SNI_HOST_IP}
address=/jfrog.org/{SNI_HOST_IP}
address=/jhipster.tech/{SNI_HOST_IP}
address=/jitpack.io/{SNI_HOST_IP}
address=/jitsi.org/{SNI_HOST_IP}
address=/justpaste.it/{SNI_HOST_IP}
address=/jwplayer.com/{SNI_HOST_IP}
address=/k8s.io/{SNI_HOST_IP}
address=/kaggle.com/{SNI_HOST_IP}
address=/kaggle.io/{SNI_HOST_IP}
address=/kaggle.net/{SNI_HOST_IP}
address=/kaggleusercontent.com/{SNI_HOST_IP}
address=/kb-cdn.yoast.com/{SNI_HOST_IP}
address=/kb.yoast.com/{SNI_HOST_IP}
address=/khanacademy.org/{SNI_HOST_IP}
address=/khronos.org/{SNI_HOST_IP}
address=/kinsta.com/{SNI_HOST_IP}
address=/kite.com/{SNI_HOST_IP}
address=/kubernetes.io/{SNI_HOST_IP}
address=/labix.org/{SNI_HOST_IP}
address=/laravel.com/{SNI_HOST_IP}
address=/launchpad.net/{SNI_HOST_IP}
address=/lb.yoast.com/{SNI_HOST_IP}
address=/leafletjs.com/{SNI_HOST_IP}
address=/leech.com/{SNI_HOST_IP}
address=/lego.yoast.com/{SNI_HOST_IP}
address=/lenovo.com/{SNI_HOST_IP}
address=/libraries.io/{SNI_HOST_IP}
address=/lightstep.com/{SNI_HOST_IP}
address=/lit.dev/{SNI_HOST_IP}
address=/livefyre.com/{SNI_HOST_IP}
address=/local.yoast.com/{SNI_HOST_IP}
address=/logrocket.com/{SNI_HOST_IP}
address=/maas.io/{SNI_HOST_IP}
address=/macromedia.com/{SNI_HOST_IP}
address=/mailchimp.com/{SNI_HOST_IP}
address=/mailgun.com/{SNI_HOST_IP}
address=/mariadb.com/{SNI_HOST_IP}
address=/marketingplatform.google.com/{SNI_HOST_IP}
address=/marketplace.envato.com/{SNI_HOST_IP}
address=/material.io/{SNI_HOST_IP}
address=/mathworks.com/{SNI_HOST_IP}
address=/maven.google.com/{SNI_HOST_IP}
address=/maven.org/{SNI_HOST_IP}
address=/mbed.com/{SNI_HOST_IP}
address=/medium.com/{SNI_HOST_IP}
address=/mendeley.com/{SNI_HOST_IP}
address=/metasploit.com/{SNI_HOST_IP}
address=/mi.com/{SNI_HOST_IP}
address=/microblink.com/{SNI_HOST_IP}
address=/microchip.com/{SNI_HOST_IP}
address=/micropyramid.com/{SNI_HOST_IP}
address=/microsoft.com/{SNI_HOST_IP}
address=/minio.io/{SNI_HOST_IP}
address=/dl.minio.io/{SNI_HOST_IP}
address=/mit.edu/{SNI_HOST_IP}
address=/mongodb.com/{SNI_HOST_IP}
address=/mongodb.org/{SNI_HOST_IP}
address=/mozilla.net/{SNI_HOST_IP}
address=/mozilla.org/{SNI_HOST_IP}
address=/mybridge.co/{SNI_HOST_IP}
address=/myfonts.net/{SNI_HOST_IP}
address=/mysql.com/{SNI_HOST_IP}
address=/my.yoast.com/{SNI_HOST_IP}
address=/nativescript.org/{SNI_HOST_IP}
address=/nestjs.com/{SNI_HOST_IP}
address=/netacad.com/{SNI_HOST_IP}
address=/netbeans.org/{SNI_HOST_IP}
address=/netdevgroup.com/{SNI_HOST_IP}
address=/netflix.com/{SNI_HOST_IP}
address=/netflix.net/{SNI_HOST_IP}
address=/newrelic.com/{SNI_HOST_IP}
address=/nextjs.org/{SNI_HOST_IP}
address=/nflxext.com/{SNI_HOST_IP}
address=/nflximg.net/{SNI_HOST_IP}
address=/nflxso.net/{SNI_HOST_IP}
address=/nflxvideo.net/{SNI_HOST_IP}
address=/nginx.com/{SNI_HOST_IP}
address=/ngrok.com/{SNI_HOST_IP}
address=/ngrok.io/{SNI_HOST_IP}
address=/ni.com/{SNI_HOST_IP}
address=/nip.io/{SNI_HOST_IP}
address=/nirsoft.net/{SNI_HOST_IP}
address=/nodejs.org/{SNI_HOST_IP}
address=/nodesource.com/{SNI_HOST_IP}
address=/npmjs.org/{SNI_HOST_IP}
address=/nvcr.io/{SNI_HOST_IP}
address=/nvidia.com/{SNI_HOST_IP}
address=/oauth2.googleapis.com/{SNI_HOST_IP}
address=/oddrun.ir/{SNI_HOST_IP}
address=/ojrq.net/{SNI_HOST_IP}
address=/onesignal.com/{SNI_HOST_IP}
address=/onlinesim.ru/{SNI_HOST_IP}
address=/opendev.org/{SNI_HOST_IP}
address=/openreview.net/{SNI_HOST_IP}
address=/openvpn.net/{SNI_HOST_IP}
address=/optimize.google.com/{SNI_HOST_IP}
address=/optimizely.com/{SNI_HOST_IP}
address=/oracle.com/{SNI_HOST_IP}
address=/origin.com/{SNI_HOST_IP}
address=/overleaf.com/{SNI_HOST_IP}
address=/packagecloud.io/{SNI_HOST_IP}
address=/packagesource.com/{SNI_HOST_IP}
address=/packagist.org/{SNI_HOST_IP}
address=/packtpub.com/{SNI_HOST_IP}
address=/parsely.com/{SNI_HOST_IP}
address=/payments.google.com/{SNI_HOST_IP}
address=/paypal.com/{SNI_HOST_IP}
address=/paypalobjects.com/{SNI_HOST_IP}
address=/pdf2go.com/{SNI_HOST_IP}
address=/photodune.net/{SNI_HOST_IP}
address=/php.net/{SNI_HOST_IP}
address=/pingdom.com/{SNI_HOST_IP}
address=/play.google.com/{SNI_HOST_IP}
address=/plotly.com/{SNI_HOST_IP}
address=/polymer-project.org/{SNI_HOST_IP}
address=/preview.codecanyon.net/{SNI_HOST_IP}
address=/preview.themeforest.net/{SNI_HOST_IP}
address=/proandroiddev.com/{SNI_HOST_IP}
address=/programiz.com/{SNI_HOST_IP}
address=/pscdn.co/{SNI_HOST_IP}
address=/pub.dev/{SNI_HOST_IP}
address=/public-api.wordpress.com/{SNI_HOST_IP}
address=/pypa.io/{SNI_HOST_IP}
address=/pypi.org/{SNI_HOST_IP}
address=/pythonhosted.org/{SNI_HOST_IP}
address=/python.org/{SNI_HOST_IP}
address=/pytorchlightning.ai/{SNI_HOST_IP}
address=/qt.io/{SNI_HOST_IP}
address=/quay.io/{SNI_HOST_IP}
address=/quilljs.com/{SNI_HOST_IP}
address=/rapid7.com/{SNI_HOST_IP}
address=/reactjs.org/{SNI_HOST_IP}
address=/react-select.com/{SNI_HOST_IP}
address=/reality.ai/{SNI_HOST_IP}
address=/realm.io/{SNI_HOST_IP}
address=/red.com/{SNI_HOST_IP}
address=/reduxframework.com/{SNI_HOST_IP}
address=/redux.io/{SNI_HOST_IP}
address=/releases.hashicorp.com/{SNI_HOST_IP}
address=/remove.bg/{SNI_HOST_IP}
address=/repo.packagist.org/{SNI_HOST_IP}
address=/review.yoast.com/{SNI_HOST_IP}
address=/rstudio.com/{SNI_HOST_IP}
address=/ruby-doc.org/{SNI_HOST_IP}
address=/rubygems.org/{SNI_HOST_IP}
address=/salesforce.com/{SNI_HOST_IP}
address=/scdn.co/{SNI_HOST_IP}
address=/schema.org/{SNI_HOST_IP}
address=/segment.com/{SNI_HOST_IP}
address=/seleniumhq.org/{SNI_HOST_IP}
address=/sendgrid.com/{SNI_HOST_IP}
address=/sentry.io/{SNI_HOST_IP}
address=/serialport.io/{SNI_HOST_IP}
address=/serverfault.com/{SNI_HOST_IP}
address=/services.google.com/{SNI_HOST_IP}
address=/sites.google.com/{SNI_HOST_IP}
address=/slidesgo.com/{SNI_HOST_IP}
address=/socket.io/{SNI_HOST_IP}
address=/softlayer.com/{SNI_HOST_IP}
address=/softonic.com/{SNI_HOST_IP}
address=/sonatype.org/{SNI_HOST_IP}
address=/sourceforge.net/{SNI_HOST_IP}
address=/spamassassin.apache.org/{SNI_HOST_IP}
address=/sparkjava.com/{SNI_HOST_IP}
address=/spiceworks.com/{SNI_HOST_IP}
address=/splunk.com/{SNI_HOST_IP}
address=/spotify.com/{SNI_HOST_IP}
address=/spring.io/{SNI_HOST_IP}
address=/sstatic.net/{SNI_HOST_IP}
address=/stackexchange.com/{SNI_HOST_IP}
address=/stackoverflow.com/{SNI_HOST_IP}
address=/stackshare.io/{SNI_HOST_IP}
address=/statuspage.io/{SNI_HOST_IP}
address=/storage.googleapis.com/{SNI_HOST_IP}
address=/store.theplusaddons.com/{SNI_HOST_IP}
address=/stripe.com/{SNI_HOST_IP}
address=/stripe.network/{SNI_HOST_IP}
address=/sun.com/{SNI_HOST_IP}
address=/superuser.com/{SNI_HOST_IP}
address=/surveys.google.com/{SNI_HOST_IP}
address=/swaggerhub.com/{SNI_HOST_IP}
address=/swift.org/{SNI_HOST_IP}
address=/symfony.com/{SNI_HOST_IP}
address=/tabnine.com/{SNI_HOST_IP}
address=/tagmanager.google.com/{SNI_HOST_IP}
address=/teamtreehouse.com/{SNI_HOST_IP}
address=/teamviewer.com/{SNI_HOST_IP}
address=/telegram.org/{SNI_HOST_IP}
address=/telerik.com/{SNI_HOST_IP}
address=/tensorflow.org/{SNI_HOST_IP}
address=/terrytao.wordpress.com/{SNI_HOST_IP}
address=/themeforest.net/{SNI_HOST_IP}
address=/thinkwithgoogle.com/{SNI_HOST_IP}
address=/ti.com/{SNI_HOST_IP}
address=/timedoctor.com/{SNI_HOST_IP}
address=/tinyjpg.com/{SNI_HOST_IP}
address=/tinypng.com/{SNI_HOST_IP}
address=/tinyurl.com/{SNI_HOST_IP}
address=/toggl.com/{SNI_HOST_IP}
address=/towardsdatascience.com/{SNI_HOST_IP}
address=/tracking.yoast.com/{SNI_HOST_IP}
address=/translate.yoast.com/{SNI_HOST_IP}
address=/travis-ci.com/{SNI_HOST_IP}
address=/travis-ci.org/{SNI_HOST_IP}
address=/traviscistatus.com/{SNI_HOST_IP}
address=/trellocdn.com/{SNI_HOST_IP}
address=/trello.com/{SNI_HOST_IP}
address=/twilio.com/{SNI_HOST_IP}
address=/typoci.com/{SNI_HOST_IP}
address=/ubuntu.com/{SNI_HOST_IP}
address=/udemycdn-a.com/{SNI_HOST_IP}
address=/udemycdn.com/{SNI_HOST_IP}
address=/udemy.com/{SNI_HOST_IP}
address=/unity3d.com/{SNI_HOST_IP}
address=/unity.com/{SNI_HOST_IP}
address=/unrealengine.com/{SNI_HOST_IP}
address=/unsplash.com/{SNI_HOST_IP}
address=/upd.merkulov.design/{SNI_HOST_IP}
address=/upwork.com/{SNI_HOST_IP}
address=/vagrantup.com/{SNI_HOST_IP}
address=/videohive.net/{SNI_HOST_IP}
address=/videolan.org/{SNI_HOST_IP}
address=/virtualbox.org/{SNI_HOST_IP}
address=/visualping.io/{SNI_HOST_IP}
address=/vmcdn.com/{SNI_HOST_IP}
address=/vmware.com/{SNI_HOST_IP}
address=/vuejs.org/{SNI_HOST_IP}
address=/vuetifyjs.com/{SNI_HOST_IP}
address=/vuforia.com/{SNI_HOST_IP}
address=/wakatime.com/{SNI_HOST_IP}
address=/wallpaperget.com/{SNI_HOST_IP}
address=/wandb.ai/{SNI_HOST_IP}
address=/waze.com/{SNI_HOST_IP}
address=/webcatalog.app/{SNI_HOST_IP}
address=/web.dev/{SNI_HOST_IP}
address=/websiteforstudents.com/{SNI_HOST_IP}
address=/wikia.com/{SNI_HOST_IP}
address=/withgoogle.com/{SNI_HOST_IP}
address=/wordfence.com/{SNI_HOST_IP}
address=/wordpress.com/{SNI_HOST_IP}
address=/wordpress.org/{SNI_HOST_IP}
address=/wpastra.com/{SNI_HOST_IP}
address=/wpfakedomain2562.com/{SNI_HOST_IP}
address=/wtfismyip.com/{SNI_HOST_IP}
address=/www.analytics.google.com/{SNI_HOST_IP}
address=/www.arpriceplugin.com/{SNI_HOST_IP}
address=/www.cdn-images.yoast.com/{SNI_HOST_IP}
address=/www.cdn.yoast.com/{SNI_HOST_IP}
address=/www.codecanyon.net/{SNI_HOST_IP}
address=/www.envato.com/{SNI_HOST_IP}
address=/www.exactmetrics.com/{SNI_HOST_IP}
address=/www.facebook.com/{SNI_HOST_IP}
address=/www.googleapis.com/{SNI_HOST_IP}
address=/www.instagram.com/{SNI_HOST_IP}
address=/www.jetpack.com/{SNI_HOST_IP}
address=/www.kb-cdn.yoast.com/{SNI_HOST_IP}
address=/www.kb.yoast.com/{SNI_HOST_IP}
address=/www.learndash.com/{SNI_HOST_IP}
address=/www.my.yoast.com/{SNI_HOST_IP}
address=/www.onesignal.com/{SNI_HOST_IP}
address=/www.origin.com/{SNI_HOST_IP}
address=/www.paypal.com/{SNI_HOST_IP}
address=/www.preview.themeforest.net/{SNI_HOST_IP}
address=/www.radiustheme.com/{SNI_HOST_IP}
address=/www.review.yoast.com/{SNI_HOST_IP}
address=/www.themeforest.net/{SNI_HOST_IP}
address=/www.tracking.yoast.com/{SNI_HOST_IP}
address=/www.vmware.com/{SNI_HOST_IP}
address=/www.wordfence.com/{SNI_HOST_IP}
address=/www.yoa.st/{SNI_HOST_IP}
address=/www.yoast.com/{SNI_HOST_IP}
address=/xiaomi.com/{SNI_HOST_IP}
address=/xip.io/{SNI_HOST_IP}
address=/xkcd.com/{SNI_HOST_IP}
address=/yajrabox.com/{SNI_HOST_IP}
address=/yarnpkg.com/{SNI_HOST_IP}
address=/yithemes.com/{SNI_HOST_IP}
address=/yoa.st/{SNI_HOST_IP}
address=/yoast.com/{SNI_HOST_IP}
address=/zeit.co/{SNI_HOST_IP}
address=/zend.com/{SNI_HOST_IP}
address=/zeplin.io/{SNI_HOST_IP}
address=/zoom.us/{SNI_HOST_IP}
server={DNS_PROXY_IP}
__EOF_SNI_DNSMASQ__
}

function tpl_sni_xray_write {
	_write_file "$1" << '__EOF_SNI_XRAY__'
{
  "log": {
    "access": "",
    "error": "",
    "loglevel": "error"
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "port": 1080,
      "listen": "::",
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true,
        "ip": "127.0.0.1"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vmess",
      "settings": {
        "vnext": [
          {
            "address": "SERVER_ADDRESS",
            "port": SERVER_PORT,
            "users": [
              {
                "id": "SERVER_UUID",
                "alterId": 0,
                "security": "auto"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "WS_PATH"
        }
      },
      "mux": {
        "enabled": true
      }
    },
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIP"
      }
    }
  ],
  "dns": {
    "servers": [
      "1.0.0.1",
      "localhost"
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "direct"
      }
    ]
  }
}
__EOF_SNI_XRAY__
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
	tpl_v2ray_bridge_compose_write "$dir/docker-compose.yml"
	tpl_v2ray_bridge_config_write  "$dir/config/config.json"
	tpl_v2ray_bridge_clients_write "$dir/clients.py"

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
	tpl_v2ray_upstream_compose_write "$dir/docker-compose.yml"
	tpl_v2ray_upstream_config_write  "$dir/config/config.json"

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
		select role in "Bridge server (Iran — entry node)" "Upstream server (foreign — exit node)" "Back to main menu" "Quit"; do
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

	step "Installing IPsec/L2TP & IKEv2 VPN"
	local VPN_IPSEC_PSK VPN_USER VPN_PASSWORD VPN_SWAN_VER
	ask VPN_IPSEC_PSK "IPsec PSK (empty = random)" "" || { warn "Cancelled."; return 1; }
	ask VPN_USER      "VPN username (empty = random)" "" || { warn "Cancelled."; return 1; }
	read -r -s -p "VPN password (empty = random, input hidden): " VPN_PASSWORD
	echo ""
	stty sane 2>/dev/null || true   # restore terminal echo after hidden input
	ask VPN_SWAN_VER  "Libreswan version (empty = latest supported, e.g. 4.15)" "" || { warn "Cancelled."; return 1; }

	# validate the version if the user gave one (upstream requires 4.15+)
	if [ -n "$VPN_SWAN_VER" ]; then
		if ! printf '%s\n%s\n' "4.15" "$VPN_SWAN_VER" | sort -C -V; then
			warn "Libreswan version '$VPN_SWAN_VER' is too old (must be 4.15+)."
			if ! confirm "Use the latest supported version instead?"; then
				warn "Cancelled."
				return 1
			fi
			VPN_SWAN_VER=""
		fi
	fi

	export VPN_IPSEC_PSK VPN_USER VPN_PASSWORD VPN_SWAN_VER
	local ipsec_script="$SCRIPT_DIR/ipsec-vpn/vpnsetup_ubuntu.sh"
	if [ ! -f "$ipsec_script" ]; then
		error "IPsec installer script not found at $ipsec_script"
		return 1
	fi
	# run in a subshell so the script's 'exit' doesn't kill our script
	( bash "$ipsec_script" ) || warn "The IPsec installer reported a non-zero status."
	stty sane 2>/dev/null || true

	success "IPsec VPN installed! Credentials are shown above — save them."
}

function install_pnode {
	sudocheck

	step "Installing P-Node"
	local pn_src="$SCRIPT_DIR/p-node"
	if [ ! -f "$pn_src/p-node" ]; then
		error "P-Node bundle not found at $pn_src"
		return 1
	fi

	# install deps then copy the runtime bundle into the next free p-node-N dir
	apt-get -y update
	apt-get -y install make wget curl jq openssl cron iptables

	local i=1 pn_dir
	while [ -d "/opt/p-node-$i" ]; do i=$((i + 1)); done
	pn_dir="/opt/p-node-$i"
	info "Installing into $pn_dir ..."
	cp -r "$pn_src" "$pn_dir"
	( bash "$pn_dir/scripts/setup.sh" ) || warn "P-Node setup reported a non-zero status."
	stty sane 2>/dev/null || true
	( bash "$pn_dir/scripts/info.sh" ) || true

	echo ""
	success "P-Node installed!"
	info "Copy the JSON printed above into P-Manager -> 'Add Node'."
}

function install_pmanager {
	sudocheck

	step "Installing P-Manager"
	local pm_src="$SCRIPT_DIR/p-manager"
	if [ ! -f "$pm_src/p-manager" ]; then
		error "P-Manager bundle not found at $pm_src"
		return 1
	fi
	local pm_dir
	ask pm_dir "Install directory" "/opt/p-manager" || { warn "Cancelled."; return 1; }

	if [ -d "$pm_dir" ]; then
		warn "Directory $pm_dir already exists — re-running setup..."
		( bash "$pm_dir/scripts/setup.sh" ) || warn "P-Manager setup reported a non-zero status."
		stty sane 2>/dev/null || true
		return 0
	fi

	apt-get -y update
	apt-get -y install make wget curl jq openssl cron openssh-client

	cp -r "$pm_src" "$pm_dir"
	( bash "$pm_dir/scripts/setup.sh" ) || warn "P-Manager setup reported a non-zero status."
	stty sane 2>/dev/null || true

	echo ""
	success "P-Manager installed! Admin panel: http://<this-server>:8080"
	warn "Default credentials: admin / password  (change them immediately!)"
	info "Config file: $pm_dir/configs/main.json"
}

function install_vpnui {
	sudocheck

	step "Installing vpn-ui panel"
	local deploy="$SCRIPT_DIR/vpn-ui/deploy.sh"
	if [ ! -f "$deploy" ]; then
		error "vpn-ui deploy script not found at $deploy"
		return 1
	fi
	( bash "$deploy" ) || warn "The vpn-ui installer reported a non-zero status."
	stty sane 2>/dev/null || true

	echo ""
	success "vpn-ui installed! Management menu: run 'vpn-ui'"
}

function install_sniproxy {
	sudocheck
	require_docker || return 1

	step "Setting up SNI Proxy"
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
	tpl_sni_compose_write   "$dir/docker-compose.yml"
	tpl_sni_sniproxy_write  "$dir/sniproxy.conf"
	tpl_sni_dnsproxy_write  "$dir/dnsproxy-config.yaml"
	tpl_sni_dnsmasq_write   "$dir/dnsmasq.conf"
	tpl_sni_xray_write      "$dir/xray-config.json"

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

function install_mtproto {
	sudocheck
	require_docker || return 1

	step "Setting up Telegram MTProto proxy"
	info "A lightweight, censorship-resistant MTProto proxy with FakeTLS."
	echo ""

	local MTG_PORT MTG_DOMAIN name default_ip PUBLIC_IP
	default_ip="$(hostname -I | awk '{print $1}')"
	ask MTG_PORT   "Proxy listen port" "443" || { warn "Cancelled."; return 1; }
	ask MTG_DOMAIN "Camouflage/fronting domain (e.g. cloudflare.com, google.com)" "cloudflare.com" || { warn "Cancelled."; return 1; }
	ask name       "Instance name" "mtproto" || { warn "Cancelled."; return 1; }
	ask PUBLIC_IP  "Public IP shown in share links" "$default_ip" || { warn "Cancelled."; return 1; }

	# validate port
	if ! [[ "$MTG_PORT" =~ ^[0-9]+$ ]] || [ "$MTG_PORT" -lt 1 ] || [ "$MTG_PORT" -gt 65535 ]; then
		error "Invalid port: $MTG_PORT"
		return 1
	fi

	local MTG_IMAGE="b3hnam/mtg:2.2.8"

	step "Generating FakeTLS secret for domain '$MTG_DOMAIN'"
	local MTG_SECRET
	MTG_SECRET="$(docker run --rm "$MTG_IMAGE" generate-secret --hex "$MTG_DOMAIN" 2>/dev/null | tr -d '[:space:]')"
	if [ -z "$MTG_SECRET" ]; then
		error "Failed to generate a secret. Check your internet/Docker Hub access."
		return 1
	fi
	success "Secret generated"

	local dir="$SCRIPT_DIR/mtproto/$name"
	mkdir -p "$dir"

	cat > "$dir/config.toml" << EOF
# mtg (MTProto proxy) configuration
# Telegram MTProto proxy configuration
secret = "$MTG_SECRET"
bind-to = "0.0.0.0:3128"

# Blocklist includes RFC1918 bogons — disable it so local clients can connect.
[defense.blocklist]
enabled = false
EOF

	cat > "$dir/docker-compose.yml" << EOF
services:
  mtg:
    image: ${MTG_IMAGE}
    container_name: ${name}
    restart: unless-stopped
    command: run /config.toml
    ports:
      - "${MTG_PORT}:3128"
    volumes:
      - ./config.toml:/config.toml:ro
    healthcheck:
      test: ["CMD", "/mtg", "doctor", "/config.toml"]
      interval: 60s
      timeout: 15s
      retries: 3
      start_period: 10s
EOF

	# keep credentials private
	{
		echo "MTG_PORT=$MTG_PORT"
		echo "MTG_DOMAIN=$MTG_DOMAIN"
		echo "MTG_SECRET=$MTG_SECRET"
		echo "PUBLIC_IP=$PUBLIC_IP"
	} > "$dir/.env"
	chmod 600 "$dir/.env" "$dir/config.toml"

	step "Starting container"
	pushd "$dir" > /dev/null
	docker compose up -d
	popd > /dev/null

	# build share links
	local tg_base="https://t.me/proxy?server=${PUBLIC_IP}&port=${MTG_PORT}&secret=${MTG_SECRET}"

	echo ""
	success "MTProto proxy '$name' is up on port $MTG_PORT!"
	echo ""
	echo "  ${C_CYN}Share link (Telegram):${C_RST}"
	echo "  $tg_base"
	echo ""
	echo "  ${C_CYN}Direct tg:// link:${C_RST}"
	echo "  tg://proxy?server=${PUBLIC_IP}&port=${MTG_PORT}&secret=${MTG_SECRET}"
	echo ""
	echo "  Secret (hex): $MTG_SECRET"
	echo "  Domain front: $MTG_DOMAIN"
	echo ""
	info "Manage: cd $dir && docker compose logs -f"
	info "More links/QR: docker exec $name /mtg access /config.toml"
}

# ---------- Uninstallers ----------
function uninstall_v2ray {
	sudocheck
	require_docker || return 1

	local found=0 d
	for d in "$SCRIPT_DIR"/v2ray/v2ray-bridge-* "$SCRIPT_DIR"/v2ray/v2ray-upstream-*; do
		[ -d "$d" ] || continue
		found=1
		local name
		name="$(basename "$d")"
		if confirm "Remove $name?"; then
			pushd "$d" > /dev/null
			docker compose down -v 2>/dev/null || true
			popd > /dev/null
			rm -rf "$d"
			success "Removed $name"
		fi
	done
	[ "$found" = "0" ] && info "No v2ray instances found."
}

function uninstall_squid {
	sudocheck
	require_docker || return 1

	local found=0 d
	for d in "$SCRIPT_DIR"/squid/*/; do
		[ -d "$d" ] || continue
		found=1
		local name
		name="$(basename "$d")"
		if confirm "Remove squid instance '$name' (and its cache volume)?"; then
			pushd "$d" > /dev/null
			docker compose down -v 2>/dev/null || true
			popd > /dev/null
			rm -rf "$d"
			success "Removed squid instance '$name'"
		fi
	done
	[ "$found" = "0" ] && info "No squid instances found."
}

function uninstall_sniproxy {
	sudocheck
	require_docker || return 1

	local found=0 d
	for d in "$SCRIPT_DIR"/sni-proxy/*/; do
		[ -d "$d" ] || continue
		found=1
		local name net
		name="$(basename "$d")"
		net="${name}-net"
		if confirm "Remove SNI proxy '$name'?"; then
			pushd "$d" > /dev/null
			docker compose down 2>/dev/null || true
			popd > /dev/null
			docker network rm "$net" 2>/dev/null || true
			rm -rf "$d"
			success "Removed SNI proxy '$name'"
		fi
	done
	[ "$found" = "0" ] && info "No SNI proxy instances found."
}

function uninstall_softether {
	sudocheck

	if [ ! -d /usr/local/vpnserver ]; then
		info "SoftEther is not installed."
		return 0
	fi
	if confirm "Remove SoftEther VPN Server?"; then
		systemctl stop vpnserver 2>/dev/null || /etc/init.d/vpnserver stop 2>/dev/null || true
		systemctl disable vpnserver 2>/dev/null || true
		update-rc.d -f vpnserver remove 2>/dev/null || true
		rm -f /etc/init.d/vpnserver
		rm -rf /usr/local/vpnserver
		systemctl daemon-reload
		success "SoftEther VPN Server removed"
	fi
}

function uninstall_ipsec {
	sudocheck

	step "Uninstalling IPsec VPN"
	warn "This permanently deletes all VPN config and removes Libreswan + xl2tpd."
	if ! confirm "Continue with IPsec VPN removal?"; then
		warn "Cancelled."
		return 1
	fi

	local unst="$SCRIPT_DIR/ipsec-vpn/vpnuninstall.sh"
	if [ -f "$unst" ]; then
		( bash "$unst" ) || warn "The IPsec uninstaller reported a non-zero status."
		stty sane 2>/dev/null || true
	else
		warn "Bundled uninstaller not found; removing packages..."
		systemctl stop ipsec xl2tpd 2>/dev/null || true
		systemctl disable ipsec xl2tpd 2>/dev/null || true
		apt-get -y remove --purge libreswan xl2tpd 2>/dev/null || true
	fi
	success "IPsec VPN removed"
}

function uninstall_pmanager {
	sudocheck

	local pm_dir
	ask pm_dir "P-Manager install directory" "/opt/p-manager" || { warn "Cancelled."; return 1; }
	if [ -d "$pm_dir" ] && [ -f "$pm_dir/Makefile" ]; then
		if confirm "Uninstall P-Manager from $pm_dir?"; then
			( make -C "$pm_dir" uninstall ) || warn "P-Manager uninstaller reported a non-zero status."
			success "P-Manager uninstalled"
		fi
	else
		info "No P-Manager installation found at $pm_dir"
	fi
}

function uninstall_pnode {
	sudocheck

	# p-node official installer clones into p-node-N dirs (cwd, $HOME, /opt)
	local found=0 d
	for d in /opt/p-node-* /root/p-node-* "$HOME"/p-node-* ./p-node-*; do
		[ -d "$d" ] || continue
		[ -f "$d/Makefile" ] || continue
		found=1
		if confirm "Uninstall P-Node at $d?"; then
			( make -C "$d" uninstall ) || warn "P-Node uninstaller at $d reported a non-zero status."
			success "P-Node at $d uninstalled"
		fi
	done
	[ "$found" = "0" ] && info "No p-node installations found (searched /opt, /root, \$HOME, cwd)."
}

function uninstall_mtproto {
	sudocheck
	require_docker || return 1

	local found=0 d
	for d in "$SCRIPT_DIR"/mtproto/*/; do
		[ -d "$d" ] || continue
		found=1
		local name
		name="$(basename "$d")"
		if confirm "Remove MTProto proxy '$name'?"; then
			pushd "$d" > /dev/null
			docker compose down 2>/dev/null || true
			popd > /dev/null
			rm -rf "$d"
			success "Removed MTProto proxy '$name'"
		fi
	done
	[ "$found" = "0" ] && info "No MTProto proxy instances found."
}

function uninstall_vpnui {
	sudocheck

	if [ -f /opt/vpn-ui/vpn-ui-amd64 ]; then
		if confirm "Uninstall vpn-ui panel?"; then
			( /opt/vpn-ui/vpn-ui-amd64 --uninstall ) || warn "vpn-ui uninstaller reported a non-zero status."
			success "vpn-ui uninstalled"
		fi
	else
		info "vpn-ui not found at /opt/vpn-ui"
	fi
}

function uninstall_menu {
	while true; do
		step "Uninstall — choose a service"
		select u in "v2ray instances" "Squid instances" "SNI Proxy instances" "MTProto proxy instances" "SoftEther VPN" "IPsec VPN" "P-Manager" "P-Node" "vpn-ui Panel" "Back to main menu" "Quit"; do
			case $REPLY in
				1) uninstall_v2ray; break ;;
				2) uninstall_squid; break ;;
				3) uninstall_sniproxy; break ;;
				4) uninstall_mtproto; break ;;
				5) uninstall_softether; break ;;
				6) uninstall_ipsec; break ;;
				7) uninstall_pmanager; break ;;
				8) uninstall_pnode; break ;;
				9) uninstall_vpnui; break ;;
				10) return 0 ;;
				11) info "Goodbye!"; exit 0 ;;
				*) error "Invalid option. Pick 1-11." ;;
			esac
		done
	done
}

# --- Main menu ---
clear
echo "${C_CYN}=== OneClick Installer ===${C_RST}"
info "Pick an option. Inside prompts: 'b' = back, 'q' = quit."
while true; do
	echo ""
	select option in "Install Docker" "Install SoftEther" "Install v2ray" "Install Squid Proxy" "Install IPsec VPN" "Install P-Node" "Install P-Manager" "Install vpn-ui Panel" "Install SNI Proxy" "Install MTProto (Telegram) Proxy" "Uninstall a service" "Exit"; do
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
			10) install_mtproto; break ;;
			11) uninstall_menu; break ;;
			12) info "Have a nice day :)"; exit 0 ;;
			*) error "Invalid option. Pick 1-12." ;;
		esac
	done
done
