#!/usr/bin/env bash
# /usr/lib/pve-mod/apt-hook.sh
#
# Installed to /etc/apt/apt.conf.d/99-pve-mod by pve-mod-configure when the
# user enables the apt hook. Re-applies PVE file patches after any dpkg run
# (e.g. after a pve-manager upgrade overwrites patched files).

/usr/lib/pve-mod/apply-patches.sh || true
