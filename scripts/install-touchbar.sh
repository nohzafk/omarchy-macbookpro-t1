#!/bin/bash
# DKMS-install appleibridge and enable the late Touch Bar oneshot.
# Must not load these modules at sysinit (see drivers/appleibridge/WORKING-RECIPE.md).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
KVER=$(uname -r)

echo "==> DKMS sources (do not rebuild initramfs — these must not load at sysinit)"
rm -rf /usr/src/appleibridge-0.1
mkdir -p /usr/src/appleibridge-0.1
cp "$ROOT"/drivers/appleibridge/{apple-ib-als.c,apple-ib-tb.c,apple-ibridge.c,apple-ibridge.h,Makefile,dkms.conf} \
  /usr/src/appleibridge-0.1/

if dkms status appleibridge/0.1 2>/dev/null | grep -q installed; then
  dkms remove -m appleibridge -v 0.1 --all || true
fi
dkms add -m appleibridge -v 0.1
dkms build -m appleibridge -v 0.1 -k "$KVER"
dkms install -m appleibridge -v 0.1 -k "$KVER"
dkms status appleibridge

echo "==> blacklist so they cannot load during sysinit"
cat >/etc/modprobe.d/apple-ibridge.conf <<'EOF'
# T1 Touch Bar modules must load late via touchbar.service (insmod), never at boot.
blacklist apple_ibridge
blacklist apple_ib_tb
blacklist apple_ib_als
EOF

echo "==> late enable script + service"
install -m755 "$ROOT/systemd/touchbar-enable.sh" /usr/local/sbin/touchbar-enable.sh
install -m644 "$ROOT/systemd/touchbar.service" /etc/systemd/system/touchbar.service
systemctl daemon-reload
systemctl enable touchbar.service
echo "==> starting Touch Bar now (safe: after multi-user)"
systemctl start touchbar.service
sleep 2
systemctl status touchbar.service --no-pager -l || true
echo
echo "==> journal"
journalctl -u touchbar.service -n 40 --no-pager
echo
echo "==> HID drivers"
for d in /sys/bus/hid/devices/*05AC*8600*; do
  echo "  $(basename "$d") -> $(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null || echo NONE)"
done
grep -A2 'Touch Bar' /proc/bus/input/devices || echo "(no Touch Bar input device yet)"
