# Improvements in this fork

This branch (`feature/nvidia-gpu-temps`) adds NVIDIA GPU temperature support
to [`Meliox/PVE-mods`](https://github.com/Meliox/PVE-mods)'s
`pve-mod-gui-sensors.sh`.

---

## 1. NVIDIA GPU temperature widget (`thermalGpu`)

**File**: `pve-mod-gui-sensors.sh`

Two additions to the install script:

### a) Sensor JSON injection

When `nvidia-smi` is present on the host, inject one entry per GPU into
`Nodes.pm`'s `$res->{sensorsOutput}` JSON before the existing
`lm-sensors` payload:

```json
"GPU0 RTX 3090": {
  "Adapter": "NVIDIA",
  "GPU Core": { "temp1_input": 47.0 }
}
```

Each GPU appears as `GPU<idx> <model>` (with the `NVIDIA GeForce ` prefix
stripped). Calls `nvidia-smi --query-gpu=index,name,temperature.gpu` once
per request.

### b) ExtJS `thermalGpu` widget

Adds a new widget under the StatusView that filters sensor keys starting
with `GPU` and renders each as `GPU<idx>:&nbsp;<temp>°C` with the
existing TempHelper (Fahrenheit conversion supported).

Color thresholds:
- ≥ 85 °C — yellow / bold
- ≥ 95 °C — red / bold

The widget is only emitted when the install script's GPU detection
succeeds, so non-NVIDIA hosts behave exactly like upstream.

---

## How to install this fork

```bash
wget https://raw.githubusercontent.com/svilendotorg/PVE-mods/feature/nvidia-gpu-temps/pve-mod-gui-sensors.sh
bash pve-mod-gui-sensors.sh install
```

Then clear your browser cache and reload the Proxmox web UI. The new
"GPU Thermal State" row appears in the node summary.

To track upstream:

```bash
git clone https://github.com/svilendotorg/PVE-mods
cd PVE-mods
git remote add upstream https://github.com/Meliox/PVE-mods.git
git fetch upstream
git rebase upstream/main
git push --force-with-lease
```
