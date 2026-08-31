# Touch Bar on a T1 MacBookPro14,2 — the working sequence

Verified on **Omarchy**, kernel **7.1.8-arch1-3**, gcc 16.2.1, 2026-08-18.

No published report of the Touch Bar working on a T1 Mac under Omarchy exists. The reports
that do exist fail earlier, with the iBridge in recovery mode (`05ac:1281`) because a
full-disk install destroyed the T1 firmware on Apple's ESP. **Prerequisite: `lsusb` must
show `05ac:8600`.** If it shows `1281`, none of this applies — restore the ESP first.

## The two things that actually blocked it

Neither is the thing the community discusses.

**1. A self-deadlock in the driver.** `apple_ib_set_tb_mode()` calls
`usb_set_configuration()` while holding `appleib_tbmode_lock`. That call re-binds every
interface driver synchronously in the same task, re-entering `appleib_hid_probe()` →
`apple_ib_set_tb_mode()` → the same mutex. Unkillable `D` state, hangs `sysinit.target`,
blocks shutdown. See `README.md`, Fix 2.

It can also be **side-stepped without patching**: the deadlock only fires when the USB
configuration actually changes. Loading with `tb_mode_param=keyboard` selects the config the
device already boots in, takes the early return, and never calls the dangerous function.
That is what this recipe does.

**2. `hid-sensor-hub` steals the interface.** This is the part nothing documents. The
iBridge exposes two HID interfaces, and at boot the generic drivers claim both:

```
[1.118] hid-generic    0003:05AC:8600.0001
[1.121] hid-generic    0003:05AC:8600.0002
[1.158] hid-sensor-hub 0003:05AC:8600.0002   <- keeps it
```

`apple_ibridge` reclaims `.0001` on load but **not** `.0002`, which carries the Touch Bar
and ALS reports. So `appletb_probe()` never finds a device: no sysfs group is created, no
Touch Bar input device appears, and the strip stays dark — with no error anywhere. It looks
exactly like a driver that loaded fine and did nothing.

Handing `.0002` over is what lights up the Touch Bar.

## The sequence

```bash
# 0. prerequisite
lsusb | grep 05ac                       # must be 05ac:8600, not 1281

# 1. modules must NOT be in /etc/modules-load.d/ during this. If one wedges at boot it
#    hangs sysinit.target and only a forced power-off recovers.

# 2. decompress (insmod ignores modprobe's blacklist; zst modules must be unpacked)
K=/lib/modules/$(uname -r)/updates/dkms
mkdir -p /tmp/tbmods
for m in apple-ibridge apple-ib-tb apple-ib-als; do zstd -qdf "$K/$m.ko.zst" -o "/tmp/tbmods/$m.ko"; done

# 3. coordinator first, in keyboard mode so it cannot deadlock
sudo insmod /tmp/tbmods/apple-ibridge.ko tb_mode_param=keyboard
sudo insmod /tmp/tbmods/apple-ib-tb.ko

# 4. THE KEY STEP — take interface .0002 back from hid-sensor-hub
DEV=0003:05AC:8600.0002
printf '%s' "$DEV" | sudo tee /sys/bus/hid/drivers/hid-sensor-hub/unbind   >/dev/null
printf '%s' "$DEV" | sudo tee /sys/bus/hid/drivers/apple-ibridge-hid/bind  >/dev/null

# 5. reload apple_ib_tb so it re-probes now that the device exists
sudo rmmod apple_ib_tb
sudo insmod /tmp/tbmods/apple-ib-tb.ko
```

## Confirming success

```bash
for d in /sys/bus/hid/devices/*05AC*8600*; do
  printf '%s -> %s\n' "$(basename "$d")" "$(basename "$(readlink -f "$d/driver")")"
done
```

Both interfaces must read `apple-ibridge-hid`:

```
0003:05AC:8600.0001 -> apple-ibridge-hid
0003:05AC:8600.0002 -> apple-ibridge-hid
```

`appletb_probe()` succeeded if the writable controls exist, which they do not otherwise:

```
/sys/devices/pci0000:00/0000:00:14.0/usb1/1-3/1-3:1.2/0003:05AC:8600.0001/fnmode
```

And two input devices appear:

```
N: Name="Apple Touch Bar (MBP14,3)"   H: Handlers=event14
N: Name="Apple Touch Bar (MBP14,3)"   H: Handlers=event15
```

`apple_ib_tb` showing `refcount=0` is **normal** — it attaches through `apple_ibridge`'s
sub-driver mechanism, not as a module dependency. Do not read that as failure.

## Useful settings

Write these to the HID device directory found above, **not** to
`/sys/module/apple_ib_tb/parameters/`, which is `0444` read-only:

```bash
D=/sys/devices/pci0000:00/0000:00:14.0/usb1/1-3/1-3:1.2/0003:05AC:8600.0001
printf '%s' '0'  | sudo tee "$D/fnmode"        # Esc + F1-F12 always
printf '%s' '-1' | sudo tee "$D/idle_timeout"  # never blank
printf '%s' '-1' | sudo tee "$D/dim_timeout"   # never dim
```

| `fnmode` | Shows |
| --- | --- |
| 0 | Esc + F1-F12, always |
| 1 | media keys; F-keys while Fn held |
| 2 | F-keys; media keys while Fn held |
| 3 | media keys only |

Use `printf '%s' '-1'`, not `printf -1` — the latter parses `-1` as an option.

## Persistence — solved

`systemd/touchbar-enable.sh` plus `systemd/touchbar.service` in this repo. Install with:

```bash
sudo install -m 644 systemd/apple-ibridge.conf  /etc/modprobe.d/apple-ibridge.conf
sudo install -m 755 systemd/touchbar-enable.sh /usr/local/sbin/touchbar-enable.sh
sudo install -m 644 systemd/touchbar.service   /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now touchbar.service
journalctl -u touchbar.service -n 20
```

Expect `SUCCESS: fnmode=0 idle=-1 dim=-1` and both interfaces owned by
`apple-ibridge-hid`.

Three design choices, each for a reason paid for the hard way:

**Ordered after `multi-user.target`, not `modules-load.d`.** Loading these modules from
`/etc/modules-load.d/` hangs `sysinit.target` if anything wedges, the login screen never
appears, and the only recovery is a forced power-off. Running late means a failure costs a
dark Touch Bar and nothing else. The strip comes up a few seconds after login.

**`insmod`, not `modprobe`.** The kernel cmdline still blacklists these modules, so nothing
can pull them in early by accident. `insmod` ignores the blacklist, which keeps that guard
in place while letting the service load them deliberately.

**Idempotent.** It checks what is already loaded and who owns `.0002` before changing
anything, so re-running against a working system is a no-op. Verified.

Module parameters are set at load time — `fnmode=0 idle_timeout=-1 dim_timeout=-1` — because
the sysfs entries under `/sys/module/apple_ib_tb/parameters/` are `0444` read-only. The
writable copies on the HID device are then set as well, belt and braces.

### One bug worth not repeating

`/sys/bus/hid/devices/<id>` is a **symlink** into `/sys/devices/...`, and `find` does not
follow symlinks. So

```bash
find /sys/bus/hid/devices -maxdepth 2 -name fnmode     # finds nothing, even when it exists
```

That produced a false "appletb_probe did not complete" report while the Touch Bar was
visibly working, and triggered a pointless module reload — each of which leaks another
stale `Apple Touch Bar (MBP14,3)` input device (event14, event15, event16 accumulated this
way). Resolve the link instead:

```bash
real=$(readlink -f /sys/bus/hid/devices/0003:05AC:8600.0001)
[ -e "$real/fnmode" ]
```

### Known rough edge

Each `apple_ib_tb` reload adds another `Apple Touch Bar (MBP14,3)` input device without
removing the previous one. Harmless in practice — the newest one works — but a clean boot
should show exactly one, and more than one means the module was reloaded.
