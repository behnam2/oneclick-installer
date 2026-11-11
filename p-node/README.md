# p-node-setup

Runtime bundle of [miladrahimi/p-node](https://github.com/miladrahimi/p-node)
(static Go binary + helpers), used by **oneclick-installer**.

- `p-node` — static linux/amd64 binary
- `third_party/xray-linux-64/xray` — xray engine used by p-node
- `scripts/setup.sh`, `scripts/uninstall.sh`, `scripts/info.sh` — service setup,
  removal and info output
- `configs/`, `storage/` — default config and runtime dirs

Install: copy this directory to the server (e.g. `p-node-1/`) and run
`scripts/setup.sh` as root (or `make setup`). `scripts/info.sh` prints the JSON
to paste into P-Manager.

Licensed under **MIT** (see `LICENSE.md`).
