#!/usr/bin/env bash
# Shared permission handling for the wizard, module hooks and dpkg trigger.

intel_gpu_can_collect() {
    local bin="$1" out rc
    if out=$(runuser -u www-data -- timeout 3 "$bin" -J -s 500 -o - 2>&1); then
        rc=0
    else
        rc=$?
    fi
    [[ "$rc" == "0" || "$rc" == "124" ]] || return 1
    [[ "$out" != *"Failed to initialize PMU"* && "$out" != *"Permission denied"* ]] || return 1
    # A timed-out JSON stream has no closing array bracket. Decode its first
    # complete sample instead of accepting the absence of known error strings.
    printf '%s' "$out" | perl -MJSON::PP -0777 -e '
        my $text = <STDIN>;
        $text =~ s/^\s*\[\s*//;
        my ($sample) = eval { JSON::PP->new->decode_prefix($text) };
        exit 1 if $@ || ref($sample) ne "HASH" || ref($sample->{engines}) ne "HASH";
    '
}

intel_gpu_permission_error() {
    echo "[pve-mods] ERROR: Intel GPU permission: $*" >&2
    return 1
}

# Returns the hook convention: 0 unchanged, 100 restored, 1 failed.
intel_gpu_restore_permission() {
    local bin caps
    bin=$(command -v intel_gpu_top) || {
        intel_gpu_permission_error "intel_gpu_top is missing; install intel-gpu-tools."
        return 1
    }
    command -v getcap >/dev/null && command -v setcap >/dev/null || {
        intel_gpu_permission_error "getcap/setcap are missing; install libcap2-bin."
        return 1
    }
    caps=$(getcap "$bin") || {
        intel_gpu_permission_error "could not read capabilities on $bin."
        return 1
    }
    caps="${caps#"$bin" }"
    if [[ "$caps" =~ (^|[[:space:]])[^[:space:]=]*cap_perfmon[^[:space:]=]*=([eip]+) \
            && "${BASH_REMATCH[2]}" == *e* && "${BASH_REMATCH[2]}" == *p* ]]; then
        return 0
    fi
    if ! setcap "${caps:-=} cap_perfmon+ep" "$bin"; then
        intel_gpu_permission_error "could not grant CAP_PERFMON to $bin."
        return 1
    fi
    echo "[pve-mods] Restored CAP_PERFMON on $bin for enabled Intel GPU monitoring."
    return 100
}

intel_gpu_revoke_permission() {
    local bin caps
    bin=$(command -v intel_gpu_top) || return 0
    command -v getcap >/dev/null && command -v setcap >/dev/null || {
        intel_gpu_permission_error "cannot revoke CAP_PERFMON without libcap2-bin."
        return 1
    }
    caps=$(getcap "$bin") || {
        intel_gpu_permission_error "could not read capabilities on $bin."
        return 1
    }
    [[ "$caps" == *cap_perfmon* ]] || return 0
    caps="${caps#"$bin" }"
    if ! setcap "$caps cap_perfmon-eip" "$bin"; then
        intel_gpu_permission_error "could not revoke CAP_PERFMON on $bin."
        return 1
    fi
    echo "[pve-mods] Removed CAP_PERFMON from $bin."
    return 100
}

intel_gpu_read_conf() {
    local value
    [[ -f "$1" ]] || { echo 0; return; }
    value=$(awk -F= -v sec="[$2]" -v key="$3" '
        /^\[/ { active = ($0 == sec) }
        active && /^[^#=]+=/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
            if ($1 == key) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }
        }
    ' "$1")
    echo "${value:-0}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    [[ "${PVE_MODs_ROOT:-/}" == "/" ]] || exit 0
    main_conf="${PVE_MODs_MAIN_CONF:-/etc/pve-mods/pve-mods.conf}"
    mod_conf="${MOD_CONF:-${PVE_MODs_CONFD_DIR:-/etc/pve-mods/conf.d}/node_info.conf}"
    action=intel_gpu_revoke_permission
    if [[ "$(intel_gpu_read_conf "$main_conf" modules node_info)" == "1" \
            && "$(intel_gpu_read_conf "$mod_conf" gpu intel_enabled)" == "1" \
            && "$(intel_gpu_read_conf "$mod_conf" debug intel_mode)" != "1" ]]; then
        action=intel_gpu_restore_permission
    fi
    if "$action"; then
        exit 0
    else
        rc=$?
        [[ "$rc" == "100" ]] || exit "$rc"
        systemctl restart pveproxy || {
            intel_gpu_permission_error "could not restart pveproxy after restoring permission."
            exit 1
        }
        if systemctl is-active --quiet pve-mods-gpu-history.service; then
            systemctl restart pve-mods-gpu-history.service || {
                intel_gpu_permission_error "could not restart the GPU history collector."
                exit 1
            }
        fi
    fi
fi
