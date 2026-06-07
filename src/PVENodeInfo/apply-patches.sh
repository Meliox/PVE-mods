#!/usr/bin/env bash
# /usr/lib/pve-mod/apply-patches.sh
#
# Applies pve-mod patches to Proxmox VE system files.
# Reads /etc/pve-mod/pve-mod.conf to determine which modules are enabled.
# Idempotent: safe to call multiple times (e.g. from apt hook after PVE upgrade).

CONF_FILE="/etc/pve-mod/pve-mod.conf"
BACKUP_DIR="/var/lib/pve-mod/backup"
NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
PVE_MANAGER_JS="/usr/share/pve-manager/js/pvemanagerlib.js"
PVE_MOD_JS="/usr/share/pve-manager/js/PveMod_PveNodeStatusView.js"
PROXMOXLIB_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
PROXMOXLIB_MIN_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.min.js"
GPU_RRD_DIR="/var/lib/rrdcached/db/pve-mod-gpu"

info() { echo "[pve-mod] $*"; }
warn() { echo "[pve-mod] WARNING: $*" >&2; }

# Read one value from the INI config file; prints $default if not found.
read_conf() {
    local section="$1" key="$2" default="${3:-0}"
    if [[ ! -f "$CONF_FILE" ]]; then
        echo "$default"
        return
    fi
    local val
    val=$(awk -F= -v sec="[$section]" -v k="$key" '
        /^\[/ { in_sec = ($0 == sec) }
        in_sec && /^[^#=]+=/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
            if ($1 == k) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                print $2; exit
            }
        }
    ' "$CONF_FILE")
    echo "${val:-$default}"
}

backup_file() {
    local src="$1"
    [[ -f "$src" ]] || return 0
    local name ts
    name=$(basename "$src")
    ts=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$BACKUP_DIR"
    cp "$src" "$BACKUP_DIR/${name}.${ts}"
    info "Backed up $(basename "$src") → $BACKUP_DIR/${name}.${ts}"
}

# ── Read enabled modules ──────────────────────────────────────────────────────
NODE_INFO=$(read_conf modules node_info 0)
NAG_SCREEN=$(read_conf modules nag_screen 0)
GPU_HISTORY=$(read_conf gpu gpu_history 0)

CHANGED=false

# ── node-info: Nodes.pm ───────────────────────────────────────────────────────
if [[ "$NODE_INFO" == "1" ]]; then
    if ! grep -qF "use PVE::API2::PVEMod_SensorInfo" "$NODES_PM" 2>/dev/null; then
        backup_file "$NODES_PM"
        python3 - "$NODES_PM" <<'PYEOF'
import sys, re

path = sys.argv[1]
content = open(path).read()

if 'use PVE::API2::PVEMod_SensorInfo' in content:
    sys.exit(0)

m = re.search(r'^([ \t]*)my \$dinfo = df\(\'\/\', 1\);', content, re.MULTILINE)
if not m:
    print("ERROR: Anchor 'my $dinfo = df' not found in Nodes.pm", file=sys.stderr)
    sys.exit(1)

indent = m.group(1)
insertion = (
    f"{indent}# Collect sensor data from PveMod_SensorInfo\n"
    f"{indent}use PVE::API2::PVEMod_SensorInfo;\n"
    f"{indent}$res->{{PveMod_JsonSensorInfo}} = PVE::API2::PVEMod_SensorInfo::get_sensors_info();\n"
    f"{indent}$res->{{PveMod_Version}} = PVE::API2::PVEMod_SensorInfo::get_pve_mod_version();\n"
    f"{indent}$res->{{PveMod_graphicsInfo}} = PVE::API2::PVEMod_SensorInfo::get_graphics_info();\n"
    f"{indent}$res->{{PveMod_upsInfo}} = PVE::API2::PVEMod_SensorInfo::get_ups_info();\n"
    f"{indent}$res->{{PveMod_systemInfo}} = PVE::API2::PVEMod_SensorInfo::get_system_information();\n"
)
content = content[:m.start()] + insertion + content[m.start():]
open(path, 'w').write(content)
PYEOF
        info "Patched Nodes.pm"
        CHANGED=true
    fi

    # ── node-info: pvemanagerlib.js ───────────────────────────────────────────
    if ! grep -qF "PveMod_PveNodeStatusView.js" "$PVE_MANAGER_JS" 2>/dev/null; then
        backup_file "$PVE_MANAGER_JS"
        python3 - "$PVE_MANAGER_JS" <<'PYEOF'
import sys, re

path = sys.argv[1]
content = open(path).read()

if 'PveMod_PveNodeStatusView.js' in content:
    sys.exit(0)

# Comment out original StatusView definition
content = re.sub(
    r"(?m)^(Ext\.define\('PVE\.node\.StatusView',.*?^}\);)",
    lambda m: '\n'.join('// ' + line for line in m.group(1).split('\n')),
    content, flags=re.DOTALL
)

# Comment out original Summary definition
content = re.sub(
    r"(?m)^(Ext\.define\('PVE\.node\.Summary',.*?^}\);)",
    lambda m: '\n'.join('// ' + line for line in m.group(1).split('\n')),
    content, flags=re.DOTALL
)

# Insert dynamic loader before the now-commented StatusView block
loader = (
    "// Load custom PVE.node.StatusView from external module\n"
    "Ext.Loader.loadScript({\n"
    "    url: '/pve2/js/PveMod_PveNodeStatusView.js',\n"
    "    onLoad: function() { },\n"
    "    onError: function() { console.error('Failed to load PveMod_PveNodeStatusView.js'); }\n"
    "});\n"
)
content = re.sub(
    r"(// Ext\.define\('PVE\.node\.StatusView',)",
    loader + r'\1',
    content, count=1
)
open(path, 'w').write(content)
PYEOF
        info "Patched pvemanagerlib.js"
        CHANGED=true
    fi
fi

# ── node-info: GPU RRD history ────────────────────────────────────────────────
if [[ "$NODE_INFO" == "1" && "$GPU_HISTORY" == "1" ]]; then
    if ! grep -qF "gpurrddata" "$NODES_PM" 2>/dev/null; then
        # Register method in the node sub-path list
        sed -i "s/{ name => 'rrddata' },/{ name => 'rrddata' },\n            { name => 'gpurrddata' },/" "$NODES_PM"

        # Append gpurrddata method definition after the rrddata code block
        python3 - "$NODES_PM" <<'PYEOF'
import sys, re

path = sys.argv[1]
content = open(path).read()

if 'gpurrddata' in content:
    sys.exit(0)

method = r"""
__PACKAGE__->register_method({
    name => 'gpurrddata',
    path => 'gpurrddata',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    description => "Read GPU RRD statistics",
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            card => {
                description => "The GPU card identifier (e.g. card0, nvidia0).",
                type => 'string',
                pattern => '[a-zA-Z0-9]+',
            },
            timeframe => {
                description => "Specify the time frame you are interested in.",
                type => 'string',
                enum => ['hour', 'day', 'week', 'month', 'year', 'decade'],
            },
            cf => {
                description => "The RRD consolidation function",
                type => 'string',
                enum => ['AVERAGE', 'MAX'],
                optional => 1,
            },
        },
    },
    returns => {
        type => "array",
        items => {
            type => "object",
            properties => {},
        },
    },
    code => sub {
        my ($param) = @_;
        my $nodename = PVE::INotify::nodename();
        my $card = $param->{card};
        die "invalid card name\n" unless $card =~ /^[a-zA-Z0-9]+$/;
        return PVE::RRD::create_rrd_data(
            "pve-mod-gpu/$nodename/$card", $param->{timeframe}, $param->{cf},
        );
    },
});
"""

# Insert before the final 1; at end of file
content = re.sub(r'\n1;\s*$', method + '\n1;\n', content)
open(path, 'w').write(content)
PYEOF

        mkdir -p "$GPU_RRD_DIR"
        chown www-data:www-data "$GPU_RRD_DIR" 2>/dev/null || true
        info "Installed gpurrddata API endpoint"
        CHANGED=true
    fi
fi

# ── nag-screen: proxmoxlib.js ─────────────────────────────────────────────────
if [[ "$NAG_SCREEN" == "1" ]]; then
    if ! grep -qF "// disable subscription nag screen" "$PROXMOXLIB_JS" 2>/dev/null; then
        backup_file "$PROXMOXLIB_JS"
        python3 - "$PROXMOXLIB_JS" <<'PYEOF'
import sys, re

path = sys.argv[1]
content = open(path).read()

if '// disable subscription nag screen' in content:
    sys.exit(0)

m = re.search(r'(checked_command:\s*function\s*\(orig_cmd\)\s*\{)', content)
if not m:
    print("ERROR: checked_command pattern not found in proxmoxlib.js", file=sys.stderr)
    sys.exit(1)

insert = "\n\t\t\t// disable subscription nag screen\n\t\t\torig_cmd();\n\t\t\treturn;"
pos = m.end()
content = content[:pos] + insert + content[pos:]
open(path, 'w').write(content)
PYEOF
        info "Patched proxmoxlib.js (nag screen)"
        CHANGED=true
    fi

    if [[ ! -L "$PROXMOXLIB_MIN_JS" ]]; then
        backup_file "$PROXMOXLIB_MIN_JS"
        mv "$PROXMOXLIB_MIN_JS" "$BACKUP_DIR/proxmoxlib.min.js.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        ln -sf "$PROXMOXLIB_JS" "$PROXMOXLIB_MIN_JS"
        info "Symlinked proxmoxlib.min.js → proxmoxlib.js"
        CHANGED=true
    fi
fi

# ── restart pveproxy if anything changed ──────────────────────────────────────
if [[ "$CHANGED" == "true" ]]; then
    info "Restarting pveproxy..."
    systemctl restart pveproxy 2>/dev/null || true
fi
