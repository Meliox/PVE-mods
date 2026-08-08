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
