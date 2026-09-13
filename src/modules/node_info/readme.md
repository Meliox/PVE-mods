# node_info

Extends the Proxmox VE node status view with live hardware sensor data. A background daemon collects data from the configured sources and exposes it through the PVE API.

## Features

### Temperature Sensors (lm-sensors)

Reads hardware sensor data via `lm-sensors` and enriches each chip/adapter entry with context. CPU, RAM, HDD/SSD, NVME are directly supported and other temperature sensors can be bundled and displayed together.

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
