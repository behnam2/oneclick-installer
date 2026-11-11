# ipsec-vpn-setup

Vendored copies of the IPsec/L2TP + IKEv2 setup scripts from
[hwdsl2/setup-ipsec-vpn](https://github.com/hwdsl2/setup-ipsec-vpn), used by
**oneclick-installer** so installation does not depend on the upstream repo at
run time.

- `vpnsetup.sh` — wrapper that downloads the OS-specific script
- `vpnsetup_ubuntu.sh` — Ubuntu/Debian installer
- `vpnuninstall.sh` — uninstaller

These scripts are licensed under **CC BY-SA 3.0** (see `LICENSE.md`) by
Lin Song, based on the work of Thomas Sarlandie. All copyright notices are
preserved. If you redistribute modified versions, keep the same license and
attribution.

Optional environment variables: `VPN_IPSEC_PSK`, `VPN_USER`, `VPN_PASSWORD`,
`VPN_SWAN_VER` (Libreswan version).
