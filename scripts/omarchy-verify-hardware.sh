#!/usr/bin/env bash
# Report the hardware state of a MacBookPro14,2 running Omarchy.
# Read-only: it changes nothing. Run it after the install and after each fix.
#
# Optional: lm_sensors (sensors), iw, wpctl. Missing tools are reported as SKIP, never as
# failing hardware. The T1 check needs no packages: it reads sysfs directly, because
# Omarchy does not install usbutils by default.

set -uo pipefail

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
skip() { printf '  \033[36mSKIP\033[0m  %s\n' "$1"; }

have() { command -v "$1" &>/dev/null; }

# Snapshot lsmod ONCE. Never pipe `lsmod` into `grep -q`: grep exits at the first match,
# lsmod takes SIGPIPE, and `set -o pipefail` reports failure. Whether that happens depends
# on where the module sits in 7 KB of output, so the bug silently lies about some modules
# and not others.
LSMOD=$(lsmod)
mod() { grep -q "$1" <<<"$LSMOD"; }

echo "== model =="
cat /sys/class/dmi/id/product_name 2>/dev/null || echo "unknown"

echo
echo "== T1 / iBridge =="
# usbutils is not installed by default on Omarchy, so read sysfs instead. It needs no
# packages and works before the network is up.
apple_usb() {
  local d v p
  for d in /sys/bus/usb/devices/*/; do
    v=$(cat "$d/idVendor" 2>/dev/null) || continue
    [ "$v" = "05ac" ] || continue
    p=$(cat "$d/idProduct" 2>/dev/null)
    printf '%s:%s %s\n' "$v" "$p" "$(cat "$d/product" 2>/dev/null)"
  done
}
usb=$(apple_usb)
if grep -q '05ac:8600' <<<"$usb"; then
  ok "T1 present as 05ac:8600, firmware loaded"
elif grep -q '05ac:1281' <<<"$usb"; then
  bad "T1 in RECOVERY MODE (05ac:1281) - ESP firmware is missing"
  echo "        Touch Bar, webcam, Touch ID and ALS cannot work until it is restored."
  echo "        See docs/omarchy-macbookpro14-2.md section 8."
elif [ -z "$usb" ]; then
  warn "no Apple USB device present at all (neither 8600 nor 1281)"
else
  warn "Apple USB devices found, but no iBridge:"
  sed 's/^/        /' <<<"$usb"
fi

echo
echo "== Omarchy automatic fixes =="
if have pacman; then
  pacman -Q macbook12-spi-driver-dkms &>/dev/null \
    && ok "macbook12-spi-driver-dkms installed" \
    || bad "macbook12-spi-driver-dkms missing"
else
  skip "pacman not found"
fi

if [[ -f /etc/mkinitcpio.conf.d/macbook_spi_modules.conf ]]; then
  ok "SPI initramfs config: $(cat /etc/mkinitcpio.conf.d/macbook_spi_modules.conf)"
else
  bad "SPI initramfs config missing"
fi

systemctl is-enabled omarchy-nvme-suspend-fix.service &>/dev/null \
  && ok "NVMe suspend fix enabled" \
  || warn "NVMe suspend fix not enabled"

grep -q 'feature_disable=0x82000' /etc/modprobe.d/brcmfmac.conf 2>/dev/null \
  && ok "brcmfmac WPA handshake fix present" \
  || warn "brcmfmac WPA handshake fix missing"

echo
echo "== input =="
mod '^applespi' \
  && ok "applespi loaded (internal keyboard and trackpad)" \
  || bad "applespi not loaded - the internal keyboard will not work"

echo
echo "== Touch Bar stack =="
for m in apple_ibridge apple_ib_tb apple_ib_als; do
  mod "^$m" && ok "$m loaded" || warn "$m not loaded"
done
if systemctl is-enabled usbmuxd.service &>/dev/null; then
  warn "usbmuxd is enabled - it blocks iBridge HID initialisation. Mask it."
else
  ok "usbmuxd masked or absent"
fi
[[ -f /etc/modprobe.d/apple-ibridge.conf ]] \
  && ok "usbhid quirk present" \
  || warn "usbhid quirk missing (/etc/modprobe.d/apple-ibridge.conf)"

echo
echo "== webcam =="
if compgen -G "/dev/video*" >/dev/null; then
  ok "video device present: $(echo /dev/video*)"
else
  warn "no /dev/video* - expected if the T1 is in recovery mode"
fi

echo
echo "== audio =="
mod cs8409 && ok "cs8409 codec module loaded (Cirrus CS8409 bound)" || warn "cs8409 not loaded"
if have wpctl; then
  wpctl status 2>/dev/null | sed -n '/Sinks:/,/^$/p' | head -8
else
  skip "wpctl not found"
fi

echo
echo "== thermal =="
mod applesmc && ok "applesmc loaded (fan and SMC sensors)" || warn "applesmc not loaded"
systemctl is-active mbpfan &>/dev/null && ok "mbpfan running" || warn "mbpfan not running"
if have sensors; then
  sensors 2>/dev/null | grep -iE 'fan|Core|Package' | head -6
else
  skip "sensors not installed. Install with: sudo pacman -S lm_sensors"
fi

echo
echo "== wifi =="
if ! have iw; then
  skip "iw not installed"
else
  iw dev 2>/dev/null | grep -E 'Interface|ssid'
  IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
  if [[ -n ${IFACE:-} ]]; then
    ok "interface $IFACE present"
    echo "        (5 GHz check needs root: sudo iw dev $IFACE scan | grep -c 'freq: 5')"

    # band selection: tied autoconnect priorities silently favour 2.4 GHz on boot
    if have nmcli; then
      if nmcli -t -f TYPE,AUTOCONNECT-PRIORITY connection show 2>/dev/null \
           | awk -F: '$1 == "802-11-wireless" && $2 != "0"' | grep -q .; then
        ok "a wifi profile carries a non-zero autoconnect-priority"
      else
        warn "all wifi profiles at autoconnect-priority 0 -- NetworkManager breaks the tie on last-connected, which favours 2.4 GHz"
      fi
    fi
  else
    warn "no wireless interface found"
  fi
fi

echo
echo "== suspend =="
cat /sys/power/mem_sleep 2>/dev/null || skip "/sys/power/mem_sleep unreadable"
# Resolve the NVMe's PCI address instead of assuming 01:00.0: on the 15-inch
# (13,3 / 14,3) that slot is the Radeon and the NVMe sits at 02:00.0.
NVME_PCI=$(basename "$(readlink -f /sys/class/nvme/nvme0/device 2>/dev/null)" 2>/dev/null)
if [[ -n $NVME_PCI && -f /sys/bus/pci/devices/$NVME_PCI/d3cold_allowed ]]; then
  v=$(cat "/sys/bus/pci/devices/$NVME_PCI/d3cold_allowed")
  [[ $v == 0 ]] && ok "NVMe $NVME_PCI d3cold_allowed = 0 (correct)" \
    || warn "NVMe $NVME_PCI d3cold_allowed = $v (expect 0; Omarchy's fix targets 01:00.0, which is the GPU on 13,3/14,3)"
else
  skip "no NVMe controller found in sysfs"
fi
if [[ -f /sys/bus/pci/devices/0000:01:00.0/class ]] \
  && [[ $(cat /sys/bus/pci/devices/0000:01:00.0/class) == 0x0300* ]]; then
  ok "discrete GPU at 01:00.0 (15-inch): see README Part 8 for the s2idle recipe"
  grep -qw 'pcie_port_pm=off' /proc/cmdline \
    && ok "pcie_port_pm=off (Thunderbolt bridges stay out of D3)" \
    || warn "pcie_port_pm=off missing: Thunderbolt xHCI will not survive suspend"
  [[ -x /usr/lib/systemd/system-sleep/macbook-t1-thunderbolt ]] \
    && ok "thunderbolt sleep hook installed" \
    || warn "thunderbolt sleep hook missing"
fi
