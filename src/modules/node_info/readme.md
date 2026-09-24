# node_info

Extends the Proxmox VE node status view with live hardware sensor data. A background daemon collects data from the configured sources and exposes it through the PVE API.

## Features

### Temperature Sensors (lm-sensors)

Reads hardware sensor data via `lm-sensors` and enriches each chip/adapter entry with context. CPU, RAM, HDD/SSD, NVME are directly supported and other temperature sensors can be bundled and displayed together.


#### Memory
RAM temperatures support both DDR5 (`spd5118`) and DDR3/4 (`jc42`/SODIMM) sensors, displayed per-DIMM with its slot number.
SODIMMs (DDR3/4) are normally detected automatically. DDR5 may need the sensor to be exposed manually.

Note: This is an example and you must replace registers with your findings.

1) Install the required package for investigation: ```apt-get install i2c-tools```
2) Load the modprobe modules: ```modprobe spd5118; modprobe i2c-dev```
3) Find the SMBus, by listing the available I²C/SMBus adapters: ```i2cdetect -l```
4) Look for the motherboard's SMBus, for example: ```i2c-0 smbus SMBus I801 adapter at 0000:00:1f.4```. Note the bus number ```0``` following "i2c-".
5) Scan the corresponding SMBus ```i2cdetect -y 0``` and note all addresses:
```
     0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f
00:                         08 -- -- -- -- -- -- --
10: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
20: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
30: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
40: -- -- -- -- 44 -- -- -- 48 -- -- -- -- -- -- --
50: 50 -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
60: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
70: -- -- -- -- -- -- -- --
```
6) Investigate the register from the corresponding addresses, 5x are typically used by spd5118, e.g. `50` here.
7) Run ```i2cget -y 0 0x50 0x00 b```. This returns `0x51`. 51 identifies DDR5 SDRAM.
7) Manually instantiate the device: ```echo spd5118 0x50 > /sys/bus/i2c/devices/i2c-0/new_device```
8) Verify temperatures in sensors: ```sensors```:
```
spd5118-i2c-0-50 Adapter: SMBus I801 adapter at 0000:00:1f.4 temp1: +41.5°C (low = +0.0°C, high = +55.0°C) (crit low = +0.0°C, crit = +85.0°C)
```
9) Make it persistent at boot:
```
cat > /etc/modules-load.d/spd5118.conf <<'EOF'
spd5118
EOF
```
```
cat > /etc/udev/rules.d/99-spd5118.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="i2c", KERNEL=="i2c-0", RUN+="/bin/sh -c 'echo spd5118 0x50 > /sys/bus/i2c/devices/i2c-0/new_device'"
EOF
```
10) Remove apt-get remove i2c-dev

To uninstall delete the module load and udev rule.

### NVIDIA GPU

Polls `nvidia-smi` on a configurable interval. Supports multiple GPUs. Metrics can be stored in RRD for historical graphing.

| Metric | Unit |
|--------|------|
| GPU temperature | °C |
| GPU utilisation | % |
| Memory utilisation | % |
| Memory used / total | MiB |
| Power draw / limit | W |
| Fan speed | % |

### Intel GPU

Polls `intel_gpu_top` for each detected Intel GPU card. Metrics can be stored in RRD for historical graphing.

| Metric | Unit |
|--------|------|
| Requested / actual frequency | MHz |
| Interrupt rate | irq/s |
| RC6 residency | % |
| GPU power / package power | W |
| Engine busy/semaphore/wait (Render, Blitter, Video, VideoEnhance) | % |

#### Security concern: the `CAP_PERFMON` capability

`intel_gpu_top` needs the `CAP_PERFMON` capability to read the GPU's performance-monitoring counters. `pveproxy` — and therefore this mod's collector processes, which it forks — runs as the unprivileged `www-data` user, not root. Without `CAP_PERFMON`, `intel_gpu_top` fails with `Permission denied` and the Intel GPU collector produces no data.

To make Intel GPU monitoring work, `pve-mod-configure` checks whether `www-data` can already run `intel_gpu_top` and, **only with your explicit confirmation**, grants the capability directly to the binary:

```sh
setcap cap_perfmon+ep /usr/bin/intel_gpu_top
```

This is narrower than running as root or via `sudo`/setuid: it applies to this one binary only, and only grants the ability to read performance-monitoring counters — no write, filesystem, or other privileges are added. It is still a privilege increase for `www-data`, a network-facing service account, so weigh the trade-off before opting in:

- Decline the prompt (or leave Intel GPU monitoring disabled) to keep `www-data` at its default privilege level; the collector simply reports no Intel GPU data.
- The capability is removed automatically when the module is disabled or the package is uninstalled.

To remove it manually at any other time (e.g. without disabling the module):

```sh
setcap -r /usr/bin/intel_gpu_top
```

**Known limitation:** upgrading the `intel-gpu-tools` package replaces the `intel_gpu_top` binary, which resets the capability. This is not reapplied automatically. If GPU stats stop appearing after a package update, re-run `pve-mod-configure` (the collector also logs a warning to the journal when it can't collect data for this reason).

### AMD GPU

Placeholder — device discovery and collection are not yet implemented.

### UPS (Network UPS Tools)

Polls `upsc` for a configured NUT device and exposes all key-value pairs returned by the daemon. Supports any UPS accessible via NUT (local or remote).

Configuration: `device_name=ups@localhost`

### System Information

Reads hardware identity from `dmidecode` (cached at configure time, no runtime root required).

| `type` | Data source | Fields exposed |
|--------|-------------|----------------|
| `1` | DMI System | Manufacturer, Product Name, Serial Number |
| `2` | DMI Baseboard | Manufacturer, Product Name, Serial Number |

## Requirements

Each feature requires the corresponding tool to be installed on the Proxmox host:

| Feature | Required tool |
|---------|---------------|
| Temperature sensors | `lm-sensors` (`sensors` binary) |
| NVIDIA GPU | `nvidia-smi` |
| Intel GPU | `intel-gpu-tools` (`intel_gpu_top` binary) |
| UPS | `nut-client` (`upsc` binary) |
| System information | `dmidecode` (run once via `pve-mod-configure`) |

## Debug Mode

Each collector supports a debug mode that reads from a local file instead of executing the real tool. Useful for development and testing without physical hardware.

### Per-collector debug files

Set the collector's `_mode` flag to `1` in the `[debug]` section of `/etc/pve-mod/conf.d/node_info.conf` and populate its file(s) with sample data, captured from a real host via the commands below:

| Collector | Enable flag | File | Content | Example to generate it |
|-----------|-------------|------|---------|-------------------------|
| Temperature sensors | `lm_sensors_mode` | `lm_sensors_output_file` | Raw `sensors -j` JSON output | `sensors -j > /tmp/sensors-output.json` |
| Intel GPU | `intel_mode` | `intel_devices_file` | Device list, one line per GPU (`intel_gpu_top -L` format) | `intel_gpu_top -L > /tmp/intel-gpu-devices.json` |
| | | `intel_output_file` | Continuous `intel_gpu_top` stats output | `intel_gpu_top -d /dev/dri/card0 -s 1000 -l > /tmp/intel-gpu-output.txt` |
| NVIDIA GPU | `nvidia_mode` | `nvidia_devices_file` | Device list CSV | `nvidia-smi --query-gpu=index,name --format=csv > /tmp/nvidia-smi-devices.csv` |
| | | `nvidia_output_file` | Stats CSV | `nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,power.limit,fan.speed --format=csv,nounits > /tmp/nvidia-smi-output.csv` |
| AMD GPU | `amd_mode` | `amd_devices_file` | Placeholder — collector not yet implemented | — |
| UPS | `ups_mode` | `ups_output_file` | Raw `upsc` key: value output (despite the `.json` name, it's plain text, not JSON) | `upsc ups@192.168.1.50 > /tmp/ups-output.json` |

### Verbose module logging (mod_debug)

Set `mod_debug=1` in the `[debug]` section of `/etc/pve-mod/conf.d/node_info.conf`, then restart `pveproxy` (`systemctl restart pveproxy`) — the setting is only read at startup. With it enabled, the mod logs each internal step (collector start/stop, cache hits, file reads, etc.) to the journal, viewable with:

```sh
journalctl -u pveproxy -f
```

Set `log_enabled=1` (and optionally `log_file`) in the same section to also persist this output to a file.
