#!/usr/bin/env bash

# This script's working directory
SCRIPT_CWD="$(dirname "$(readlink -f "$0")")"

MODS="pve-mod-gui-sensors.sh pve-mod-nag-screen.sh"

ACTION=${1:-install}
for m in $MODS; do
	"$SCRIPT_CWD/$m" $ACTION
done
