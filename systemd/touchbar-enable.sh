#!/bin/bash
# Bring up the Apple T1 Touch Bar. Run late, from a systemd oneshot.
#
# WHY THIS EXISTS AND WHY IT RUNS LATE
#   At boot the generic HID drivers claim both iBridge interfaces, and hid-sensor-hub keeps
#   the interface carrying the Touch Bar reports. apple_ibridge reclaims the other interface,
#   so appletb_probe never finds a device: no sysfs group, no input device, dark strip, and
#   no error anywhere. HID instance numbers change on every re-enumeration, so discover the
#   remaining interface by its driver instead of assuming .0001/.0002.
#
#   It runs after multi-user.target on purpose. Loading these modules from
#   /etc/modules-load.d/ hangs sysinit.target if anything wedges, and the only recovery is a
#   forced power-off. Late and slow beats early and fatal.
#
#   insmod, not modprobe: /etc/modprobe.d/apple-ibridge.conf blacklists the coordinator so
#   its ACPI alias cannot pull it in early with the default mode. insmod ignores the
#   blacklist, which keeps that guard intact while still loading it deliberately.
set -uo pipefail

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

# /sys/bus/hid/devices/<id> is a SYMLINK into /sys/devices/... and `find` does not follow
# symlinks, so `find /sys/bus/hid/devices -name fnmode` finds nothing even when the
# attribute exists. Resolve the link instead. Getting this wrong reported a false failure
# and triggered a pointless module reload that leaked a stale input device each time.
tb_attr_dir() {
	local dev real
	for dev in /sys/bus/hid/devices/*:05AC:8600.*; do
		[ -e "$dev" ] || continue
		real=$(readlink -f "$dev" 2>/dev/null) || continue
		[ -e "$real/fnmode" ] && { printf '%s' "$real"; return 0; }
	done
	return 1
}

KDIR="/lib/modules/$(uname -r)/updates/dkms"
WORK=/run/touchbar
HIDDRV=/sys/bus/hid/drivers

rebind_candidate() {
	local cur dev driver
	for dev in /sys/bus/hid/devices/*:05AC:8600.*; do
		[ -e "$dev" ] || continue
		driver=$(readlink -f "$dev/driver" 2>/dev/null) || driver=""
		cur=${driver##*/}
		[ "$cur" = "apple-ibridge-hid" ] && continue
		printf '%s' "${dev##*/}"
		return 0
	done
	return 1
}

# ── 0. is the T1 even alive? ─────────────────────────────────────────────────────────────
found=""
for d in /sys/bus/usb/devices/*/; do
	[ "$(cat "$d/idVendor" 2>/dev/null)" = "05ac" ] || continue
	p=$(cat "$d/idProduct" 2>/dev/null)
	[ "$p" = "8600" ] && found=ok
	[ "$p" = "1281" ] && { log "T1 is in RECOVERY MODE (05ac:1281) — ESP firmware missing. Nothing to do."; exit 0; }
done
[ -n "$found" ] || { log "no iBridge (05ac:8600) present — nothing to do"; exit 0; }
log "iBridge present"

# ── 1. unpack the DKMS modules (rebuilt on every kernel update, so unpack fresh) ─────────
mkdir -p "$WORK"
for m in apple-ibridge apple-ib-tb apple-ib-als; do
	if [ -f "$KDIR/$m.ko.zst" ]; then
		zstd -qdf "$KDIR/$m.ko.zst" -o "$WORK/$m.ko" || { log "failed to unpack $m"; exit 1; }
	elif [ -f "$KDIR/$m.ko" ]; then
		cp -f "$KDIR/$m.ko" "$WORK/$m.ko"
	else
		log "module $m not found in $KDIR — is the DKMS build present?"; exit 1
	fi
done
log "modules unpacked"

# ── 2. coordinator first, in keyboard mode ───────────────────────────────────────────────
# tb_mode_param=keyboard picks the USB configuration the device already boots in, so
# apple_ib_set_tb_mode() takes its early return and avoids unnecessary re-enumeration.
if ! grep -q '^apple_ibridge ' /proc/modules; then
	timeout 45 insmod "$WORK/apple-ibridge.ko" tb_mode_param=keyboard || { log "apple_ibridge failed to load"; exit 1; }
	log "apple_ibridge loaded (keyboard mode)"
fi

# fnmode/idle/dim are settable at load time even though their sysfs entries are 0444.
if ! grep -q '^apple_ib_tb ' /proc/modules; then
	timeout 45 insmod "$WORK/apple-ib-tb.ko" fnmode=0 idle_timeout=-1 dim_timeout=-1 || { log "apple_ib_tb failed to load"; exit 1; }
	log "apple_ib_tb loaded"
fi

# ── 3. take the remaining interface back from whichever generic driver holds it ──────────
IBDEV=$(rebind_candidate || true)
if [ -n "$IBDEV" ]; then
	cur=$(basename "$(readlink -f "/sys/bus/hid/devices/$IBDEV/driver" 2>/dev/null)" 2>/dev/null || echo none)
	log "interface $IBDEV currently owned by: $cur"
	if [ -e "$HIDDRV/$cur/unbind" ]; then
		printf '%s' "$IBDEV" > "$HIDDRV/$cur/unbind" 2>/dev/null && log "unbound from $cur"
		sleep 1
	fi
	if [ -e "$HIDDRV/apple-ibridge-hid/bind" ]; then
		printf '%s' "$IBDEV" > "$HIDDRV/apple-ibridge-hid/bind" 2>/dev/null && log "bound to apple-ibridge-hid"
		sleep 2
	fi

else
	log "no non-apple iBridge interface needs rebinding"
fi

# ── 4. re-probe apple_ib_tb now that the device exists ───────────────────────────────────
# Its probe already ran and found nothing, so it needs a reload to try again.
if ! tb_attr_dir >/dev/null; then
	log "no writable controls yet — reloading apple_ib_tb to re-probe"
	timeout 30 rmmod apple_ib_tb 2>/dev/null || log "rmmod apple_ib_tb failed (continuing)"
	sleep 1
	timeout 45 insmod "$WORK/apple-ib-tb.ko" fnmode=0 idle_timeout=-1 dim_timeout=-1 || log "reload failed"
	sleep 2
fi

# ── 5. settings, and report ──────────────────────────────────────────────────────────────
if d=$(tb_attr_dir); then
	printf '%s' '0'  > "$d/fnmode"       2>/dev/null || true
	printf '%s' '-1' > "$d/idle_timeout" 2>/dev/null || true
	printf '%s' '-1' > "$d/dim_timeout"  2>/dev/null || true
	log "SUCCESS: fnmode=$(cat "$d/fnmode") idle=$(cat "$d/idle_timeout") dim=$(cat "$d/dim_timeout")"
else
	log "FAILED: appletb_probe still did not complete; the strip will be dark"
fi

for d in /sys/bus/hid/devices/*05AC*8600*; do
	log "  $(basename "$d") -> $(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null || echo NONE)"
done
awk '/^N: Name=.*Touch Bar/{n=$0} /^H: Handlers=/{if (n) {print "  " n " " $0; n=""}}' /proc/bus/input/devices | while read -r l; do log "$l"; done
