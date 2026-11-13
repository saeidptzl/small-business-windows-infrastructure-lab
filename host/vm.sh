#!/usr/bin/env bash
# Start, stop and inspect the two lab VMs with QEMU/KVM as an unprivileged user.
#
#   host/vm.sh install dc01|cl01   first boot from the Windows ISO (unattended setup)
#   host/vm.sh start   dc01|cl01   normal boot from disk
#   host/vm.sh stop    dc01|cl01   ACPI shutdown, waits up to 3 minutes
#   host/vm.sh kill    dc01|cl01   hard stop
#   host/vm.sh status               state of both VMs
#   host/vm.sh console dc01|cl01   how to see the screen
#
# Networking: one e1000e NIC per VM on a QEMU "dgram" link over Unix sockets.
# That link exists only between the two QEMU processes: no TAP, bridge, NAT,
# DHCP or route to the host LAN/Internet. Management uses QMP and the guest
# agent over local Unix sockets, not the network.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=host/lab.env
source "$HERE/lab.env"
lab_env_exports

die() { echo "error: $*" >&2; exit 1; }
labctl() { "$LAB_PYTHON" "$HERE/labctl.py" "$@"; }

vm_dir()  { echo "$LAB_RUNTIME/vms/$1"; }
unit()    { echo "smallbiz-$1"; }
is_running() { systemctl --user is-active --quiet "$(unit "$1")"; }

check_vm() { [[ "$1" == dc01 || "$1" == cl01 ]] || die "VM must be dc01 or cl01"; }

preflight() {
  [[ -x "$QEMU_BIN" ]] || die "qemu-system-x86_64 not found (run host/00-get-userspace-qemu.sh or install qemu-system-x86)"
  [[ -r /dev/kvm && -w /dev/kvm ]] || die "no read/write access to /dev/kvm"
  [[ -f "$OVMF_CODE" && -f "$OVMF_VARS_TEMPLATE" ]] || die "OVMF Secure Boot firmware not found in $OVMF_DIR"
  mkdir -p "$LAB_RUN_DIR" && chmod 700 "$LAB_RUN_DIR"
}

ensure_disks() {
  local vm="$1" d; d="$(vm_dir "$vm")"
  mkdir -p "$d"
  if [[ "$vm" == dc01 ]]; then
    [[ -f "$d/os.qcow2" ]]     || "$QEMU_IMG" create -q -f qcow2 "$d/os.qcow2" "${DC01_OS_DISK_GB}G"
    [[ -f "$d/data.qcow2" ]]   || "$QEMU_IMG" create -q -f qcow2 "$d/data.qcow2" "${DC01_DATA_DISK_GB}G"
    [[ -f "$d/backup.qcow2" ]] || "$QEMU_IMG" create -q -f qcow2 "$d/backup.qcow2" "${DC01_BACKUP_DISK_GB}G"
  else
    [[ -f "$d/os.qcow2" ]]     || "$QEMU_IMG" create -q -f qcow2 "$d/os.qcow2" "${CL01_OS_DISK_GB}G"
  fi
  [[ -f "$d/OVMF_VARS.fd" ]] || cp "$OVMF_VARS_TEMPLATE" "$d/OVMF_VARS.fd"
}

start_swtpm() {
  # Windows 11 requires TPM 2.0: emulate one with swtpm (state kept per VM).
  local d; d="$(vm_dir cl01)"
  [[ -x "$SWTPM_BIN" ]] || die "swtpm not found"
  mkdir -p "$d/tpm"
  local s="$LAB_RUN_DIR/cl01-swtpm.sock"
  rm -f "${s:?}"
  systemctl --user reset-failed "$(unit cl01)-swtpm" 2>/dev/null || true
  systemd-run --user --quiet --collect --unit "$(unit cl01)-swtpm" \
    --setenv=LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" \
    "$SWTPM_BIN" socket --tpm2 --tpmstate "dir=$d/tpm" \
      --ctrl "type=unixio,path=$s" --terminate --log "file=$d/swtpm.log,level=1"
  for _ in $(seq 50); do [[ -S "$s" ]] && return 0; sleep 0.1; done
  die "swtpm socket did not appear"
}

build_args() {
  local vm="$1" mode="$2" d peer ram cpus mac vnc
  d="$(vm_dir "$vm")"
  if [[ "$vm" == dc01 ]]; then peer=cl01; ram=$DC01_RAM_MB; cpus=$DC01_CPUS; mac=$DC01_MAC; vnc=$DC01_VNC_DISPLAY
  else peer=dc01; ram=$CL01_RAM_MB; cpus=$CL01_CPUS; mac=$CL01_MAC; vnc=$CL01_VNC_DISPLAY; fi

  ARGS=("${QEMU_DATA_ARGS[@]}"
    -name "$vm,process=smallbiz-$vm"
    -machine q35,accel=kvm,smm=on,vmport=off
    -global driver=cfi.pflash01,property=secure,value=on
    -global ICH9-LPC.disable_s3=1 -global ICH9-LPC.disable_s4=1
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,unit=1,file=$d/OVMF_VARS.fd"
    # svm=off: no nested virtualisation, so Windows does not start VBS/Hyper-V inside the lab.
    -cpu host,svm=off,hv-relaxed=on,hv-vapic=on,hv-spinlocks=0x1fff,hv-time=on,hv-vpindex=on,hv-synic=on,hv-stimer=on,hv-frequencies=on,hv-tlbflush=on,hv-ipi=on,hv-runtime=on,hv-reset=on
    -smp "$cpus" -m "$ram"
    -rtc base=localtime,driftfix=slew -global kvm-pit.lost_tick_policy=discard
    -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0
    -device VGA,vgamem_mb=32
    -device ahci,id=sata
    -drive "id=os,if=none,file=$d/os.qcow2,format=qcow2,cache=writeback,discard=unmap,detect-zeroes=unmap"
    -device ide-hd,drive=os,bus=sata.0,serial=SB-OS-$vm,rotation_rate=1,bootindex=1
    # Isolated lab LAN: datagrams between the two QEMU processes only.
    -netdev "dgram,id=lan,local.type=unix,local.path=$LAB_RUN_DIR/$vm-lan.sock,remote.type=unix,remote.path=$LAB_RUN_DIR/$peer-lan.sock"
    -device "e1000e,netdev=lan,mac=$mac"
    # Management channel: QEMU guest agent over virtio-serial (not a network).
    -device virtio-serial-pci,id=vser
    -chardev "socket,id=qga0,path=$LAB_RUN_DIR/$vm-qga.sock,server=on,wait=off"
    -device virtserialport,bus=vser.0,chardev=qga0,name=org.qemu.guest_agent.0
    -qmp "unix:$LAB_RUN_DIR/$vm-qmp.sock,server=on,wait=off"
  )
  if [[ "$vm" == dc01 && "$mode" == run ]]; then
    # Data (D:) and backup (E:) disks are added after setup so setup only sees one disk.
    ARGS+=(-drive "id=data,if=none,file=$d/data.qcow2,format=qcow2,cache=writeback,discard=unmap"
           -device ide-hd,drive=data,bus=sata.1,serial=SB-DATA,rotation_rate=1
           -drive "id=backup,if=none,file=$d/backup.qcow2,format=qcow2,cache=writeback,discard=unmap"
           -device ide-hd,drive=backup,bus=sata.2,serial=SB-BACKUP,rotation_rate=1)
  fi
  if [[ "$vm" == cl01 ]]; then
    ARGS+=(-chardev "socket,id=chrtpm,path=$LAB_RUN_DIR/cl01-swtpm.sock"
           -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0)
  fi
  if [[ "$mode" == install ]]; then
    local iso; if [[ "$vm" == dc01 ]]; then iso="$SERVER_ISO"; else iso="$CLIENT_ISO"; fi
    [[ -f "$iso" ]] || die "installation ISO not found: $iso (see host/01-get-media.sh)"
    [[ -f "$VIRTIO_ISO" ]] || die "virtio-win ISO not found: $VIRTIO_ISO"
    [[ -f "$d/config.iso" ]] || die "config ISO missing: run host/build-config-iso.sh $vm"
    ARGS+=(-drive "id=cd0,if=none,media=cdrom,readonly=on,file=$iso"
           -device ide-cd,drive=cd0,bus=sata.3,bootindex=0
           -drive "id=cd1,if=none,media=cdrom,readonly=on,file=$d/config.iso"
           -device ide-cd,drive=cd1,bus=sata.4
           -drive "id=cd2,if=none,media=cdrom,readonly=on,file=$VIRTIO_ISO"
           -device ide-cd,drive=cd2,bus=sata.5)
  fi
  case "$LAB_DISPLAY" in
    gtk) ARGS+=(-display gtk,zoom-to-fit=on) ;;
    *)   ARGS+=(-display none -vnc "127.0.0.1:$vnc") ;;   # loopback only
  esac
}

launch() {
  local vm="$1" mode="$2"
  check_vm "$vm"; preflight
  is_running "$vm" && die "$vm is already running"
  ensure_disks "$vm"
  rm -f "${LAB_RUN_DIR:?}/$vm-lan.sock" "${LAB_RUN_DIR:?}/$vm-qmp.sock" "${LAB_RUN_DIR:?}/$vm-qga.sock"
  [[ "$vm" == cl01 ]] && start_swtpm
  build_args "$vm" "$mode"
  local log; log="$(vm_dir "$vm")/qemu.log"
  systemctl --user reset-failed "$(unit "$vm")" 2>/dev/null || true
  systemd-run --user --quiet --collect --unit "$(unit "$vm")" \
    --setenv=LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" --setenv=QEMU_MODULE_DIR="${QEMU_MODULE_DIR:-}" \
    --setenv=DISPLAY="${DISPLAY:-}" --setenv=WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
    --setenv=XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
    --property=StandardOutput="append:$log" --property=StandardError="append:$log" \
    "$QEMU_BIN" "${ARGS[@]}"
  for _ in $(seq 50); do [[ -S "$LAB_RUN_DIR/$vm-qmp.sock" ]] && break; sleep 0.1; done
  is_running "$vm" || { tail -20 "$log" >&2; die "$vm failed to start"; }
  echo "$vm started ($mode mode, unit $(unit "$vm"))"
  if [[ "$mode" == install ]]; then
    # Press Enter for the first 30 s: it answers "Press any key to boot from CD or DVD...",
    # confirms the Windows Boot Manager entry and, if the firmware fell back to its boot menu,
    # picks the highlighted DVD entry. If a VM still waits at a menu, open the console
    # (host/vm.sh console <vm>) and press Enter.
    labctl spam "$vm" ret 30 --interval 0.7 >/dev/null
    echo "$vm: booted from the installation ISO; unattended setup is running"
  fi
}

stop_vm() {
  local vm="$1"; check_vm "$vm"
  is_running "$vm" || { echo "$vm is not running"; return 0; }
  labctl powerdown "$vm" >/dev/null || true
  for _ in $(seq 180); do is_running "$vm" || { echo "$vm stopped"; return 0; }; sleep 1; done
  die "$vm did not shut down within 3 minutes (use: host/vm.sh kill $vm)"
}

case "${1:-}" in
  install) launch "${2:?vm}" install ;;
  start)   launch "${2:?vm}" run ;;
  stop)    stop_vm "${2:?vm}" ;;
  kill)    check_vm "${2:?vm}"; systemctl --user stop "$(unit "$2")" || true; echo "$2 killed" ;;
  status)  for v in dc01 cl01; do printf '%s: ' "$v"; if is_running "$v"; then labctl status "$v"; else echo stopped; fi; done ;;
  console)
    check_vm "${2:?vm}"
    if [[ "$2" == dc01 ]]; then n=$DC01_VNC_DISPLAY; else n=$CL01_VNC_DISPLAY; fi
    echo "VNC: 127.0.0.1:590$n (any VNC viewer, e.g. 'gvncviewer 127.0.0.1:$n' or GNOME Connections)"
    echo "Or restart the VM with LAB_DISPLAY=gtk to get a window instead." ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
