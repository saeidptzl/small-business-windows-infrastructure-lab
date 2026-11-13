#!/usr/bin/env bash
# Option A (recommended when you have sudo):
#   sudo apt install qemu-system-x86 qemu-utils ovmf swtpm xorriso
#   and skip this script: host/lab.env falls back to the system binaries.
#
# Option B (no sudo, Ubuntu/Debian only) - what was used on the reference host:
#   download the same Ubuntu packages with `apt-get download` and unpack them with
#   `dpkg -x` into $LAB_RUNTIME/qemu-root. Nothing is installed system-wide.
#   KVM still works as long as your user can read/write /dev/kvm (desktop sessions on
#   Ubuntu get this through a logind ACL; check with: getfacl /dev/kvm).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=host/lab.env
source "$HERE/lab.env"

PKGS=(qemu-system-x86 qemu-system-common qemu-system-data qemu-utils seabios ipxe-qemu
      ovmf-generic swtpm swtpm-libs libtpms0 xorriso libisoburn1t64 libburn4t64 libisofs6t64
      libpmem1 libndctl6 libdaxctl1 libfdt1 librdmacm1t64 libibverbs1 libslirp0 libaio1t64)

root="$LAB_RUNTIME/qemu-root"
pkgdir="$LAB_RUNTIME/pkgs"
mkdir -p "$root" "$pkgdir"
cd "$pkgdir"
for p in "${PKGS[@]}"; do
  apt-get download "$p" >/dev/null && echo "downloaded $p"
done
for deb in ./*.deb; do dpkg -x "$deb" "$root"; done

export LD_LIBRARY_PATH="$root/usr/lib/x86_64-linux-gnu:$root/usr/lib/x86_64-linux-gnu/swtpm"
missing="$(ldd "$root/usr/bin/qemu-system-x86_64" | grep 'not found' || true)"
if [[ -n "$missing" ]]; then
  echo "Missing libraries (download them the same way):"; echo "$missing"; exit 1
fi
"$root/usr/bin/qemu-system-x86_64" --version | head -1
"$root/usr/bin/swtpm" --version
ls "$root/usr/share/OVMF/"
[[ -r /dev/kvm && -w /dev/kvm ]] && echo "/dev/kvm: OK" || echo "WARNING: no access to /dev/kvm"
