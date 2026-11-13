#!/usr/bin/env bash
# Build the small "LABCFG" ISO that Windows Setup reads during the unattended install:
#   autounattend.xml            rendered from host/unattend/<vm>-autounattend.xml.tmpl
#   bootstrap/                  first-logon script (guest agent + copy scripts)
#   lab/                        the repository's scripts/ folder -> C:\LabSetup in the guest
# Usage: host/build-config-iso.sh dc01|cl01
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=host/lab.env
source "$HERE/lab.env"
lab_env_exports

vm="${1:?usage: build-config-iso.sh dc01|cl01}"
[[ "$vm" == dc01 || "$vm" == cl01 ]] || { echo "VM must be dc01 or cl01" >&2; exit 1; }
[[ -x "$XORRISO_BIN" ]] || { echo "xorriso not found" >&2; exit 1; }

"$LAB_PYTHON" "$HERE/labctl.py" init-secrets >/dev/null
out_dir="$LAB_RUNTIME/vms/$vm"
stage="$out_dir/config-stage"
mkdir -p "$out_dir"
rm -rf "${stage:?}"
mkdir -p "$stage/bootstrap" "$stage/lab"

export SERVER_IMAGE_INDEX CLIENT_IMAGE_INDEX
"$LAB_PYTHON" "$HERE/labctl.py" render-unattend "$HERE/unattend/$vm-autounattend.xml.tmpl" "$stage/autounattend.xml" >/dev/null
cp "$HERE/bootstrap/"*.ps1 "$stage/bootstrap/"
cp -r "$LAB_REPO_ROOT/scripts/." "$stage/lab/"

"$XORRISO_BIN" -as mkisofs -quiet -V LABCFG -J -joliet-long -r -o "$out_dir/config.iso" "$stage"
# The staged answer file contains passwords: keep only the ISO (inside lab-runtime, mode 600).
rm -rf "${stage:?}"
chmod 600 "$out_dir/config.iso"
echo "built $out_dir/config.iso"
