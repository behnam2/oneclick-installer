# p-manager-setup

Runtime bundle of [miladrahimi/p-manager](https://github.com/miladrahimi/p-manager)
(static Go binary + web assets), used by **oneclick-installer**.

- `p-manager` — static linux/amd64 binary
- `third_party/xray-linux-64/xray` — xray engine
- `web/` — panel web assets (served relative to the working dir)
- `scripts/setup.sh`, `scripts/uninstall.sh` — service setup and removal
- `configs/` — default/example config

Install: copy to e.g. `/opt/p-manager` and run `scripts/setup.sh` as root
(or `make setup`). Admin panel: `http://<host>:8080` (default `admin` / `password`).

Licensed under **MIT** (see `LICENSE.md`).
