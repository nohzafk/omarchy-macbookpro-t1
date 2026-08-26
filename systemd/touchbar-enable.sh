#!/bin/bash
# Bring up the Apple T1 Touch Bar. Run late, from a systemd oneshot.
#
# WHY THIS EXISTS AND WHY IT RUNS LATE
#   At boot the generic HID drivers claim both iBridge interfaces, and hid-sensor-hub keeps
#   .0002 — the interface carrying the Touch Bar reports. apple_ibridge reclaims only .0001,
#   so appletb_probe never finds a device: no sysfs group, no input device, dark strip, and
#   no error anywhere. This takes .0002 back.
#
#   It runs after multi-user.target on purpose. Loading these modules from
#   /etc/modules-load.d/ hangs sysinit.target if anything wedges, and the only recovery is a
#   forced power-off. Late and slow beats early and fatal.
#
#   insmod, not modprobe: the kernel cmdline blacklists these modules so nothing can pull
#   them in early by accident. insmod ignores the blacklist, which keeps that guard intact
#   while still letting this script load them deliberately.
set -uo pipefail

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

# /sys/bus/hid/devices/<id> is a SYMLINK into /sys/devices/... and `find` does not follow
# symlinks, so `find /sys/bus/hid/devices -name fnmode` finds nothing even when the
# attribute exists. Resolve the link instead. Getting this wrong reported a false failure
# and triggered a pointless module reload that leaked a stale input device each time.
tb_attr_dir() {
	local real
	real=$(readlink -f "/sys/bus/hid/devices/0003:05AC:8600.0001" 2>/dev/null) || return 1
	[ -n "$real" ] && [ -e "$real/fnmode" ] && { printf '%s' "$real"; return 0; }
	return 1
}


KDIR=""
for _d in \
	"/lib/modules/$(uname -r)/updates/dkms" \
	"/lib/modules/$(uname -r)/updates" \
	"/lib/modules/$(uname -r)/extra"; do
	if [ -f "$_d/apple-ibridge.ko.zst" ] || [ -f "$_d/apple-ibridge.ko" ]; then
		KDIR="$_d"
		break
	fi
done
[ -n "$KDIR" ] || KDIR="/lib/modules/$(uname -r)/updates/dkms"
log "using modules from $KDIR"
WORK=/run/touchbar
IBDEV=0003:05AC:8600.0002
HIDDRV=/sys/bus/hid/drivers

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
# apple_ib_set_tb_mode() takes its early return and never calls usb_set_configuration().
# That call re-binds interface drivers in the same task and re-enters the function, which
# self-deadlocks on appleib_tbmode_lock in unpatched builds.
if ! grep -q '^apple_ibridge ' /proc/modules; then
	timeout 45 insmod "$WORK/apple-ibridge.ko" tb_mode_param=keyboard || { log "apple_ibridge failed to load"; exit 1; }
	log "apple_ibridge loaded (keyboard mode)"
fi

# fnmode/idle/dim are settable at load time even though their sysfs entries are 0444.
if ! grep -q '^apple_ib_tb ' /proc/modules; then
	timeout 45 insmod "$WORK/apple-ib-tb.ko" fnmode=0 idle_timeout=-1 dim_timeout=-1 || { log "apple_ib_tb failed to load"; exit 1; }
	log "apple_ib_tb loaded"
fi

# ── 3. take interface .0002 back from whichever generic driver holds it ──────────────────
cur=$(basename "$(readlink -f "/sys/bus/hid/devices/$IBDEV/driver" 2>/dev/null)" 2>/dev/null || echo none)
log "interface .0002 currently owned by: $cur"
if [ "$cur" != "apple-ibridge-hid" ]; then
	if [ -e "$HIDDRV/$cur/unbind" ]; then
		printf '%s' "$IBDEV" > "$HIDDRV/$cur/unbind" 2>/dev/null && log "unbound from $cur"
		sleep 1
	fi
	if [ -e "$HIDDRV/apple-ibridge-hid/bind" ]; then
		printf '%s' "$IBDEV" > "$HIDDRV/apple-ibridge-hid/bind" 2>/dev/null && log "bound to apple-ibridge-hid"
		sleep 2
	fi
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
