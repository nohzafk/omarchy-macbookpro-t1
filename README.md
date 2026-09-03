# Omarchy on a T1 MacBook Pro (2016–2017, Touch Bar)

Getting **Omarchy** — and Linux generally — working properly on a MacBook Pro with the Apple
**T1** chip, including the parts everyone says are impossible.

Verified on a **MacBookPro14,2** (13-inch 2017, Touch Bar), kernel **7.1.8-arch1-3**, gcc
16.2.1. Should apply to any T1 machine: `MacBookPro13,1/13,2/13,3` and
`MacBookPro14,1/14,2/14,3`.

## Results

| | Status | Notes |
| --- | --- | --- |
| **Touch Bar** | ✅ working | Esc + F1–F12, persists across reboot. Two driver bugs fixed here |
| **Wi-Fi 5 GHz** | ✅ working | Plus a **26 dB** signal improvement |
| **Audio** — speakers & mic | ✅ working | Including on `14,2`, which trackers list as unsupported |
| Webcam | ✅ working | No driver needed, once the T1 firmware survives |
| Keyboard, trackpad | ✅ working | Mainline `applespi` |
| Suspend / resume | ✅ working | Including USB-C, with one kernel parameter |
| Fans, temperature sensors | ✅ working | Firmware-managed; `mbpfan` is **not** needed |
| macOS dual boot | ✅ working | Never wipe the disk — see below |
| Bluetooth | ✅ working | Nothing to do |
| Ambient light sensor | ⚪ possible | Module builds; needs userspace tooling to be useful |
| **Touch ID** | ❌ | No Linux driver exists |

---

## Read this before you install anything

**The T1 has no firmware in ROM.** macOS writes it to the EFI System Partition at
`EFI/APPLE/EMBEDDEDOS/combined.memboot` (~30 MB), and Apple's boot firmware loads it into
the chip at every power-on.

The T1 drives **four** devices:

- Touch Bar
- FaceTime webcam
- Touch ID
- Ambient light sensor

**A full-disk install erases that partition.** The T1 then enumerates as
`05ac:1281 Apple Mobile Device [Recovery Mode]` instead of `05ac:8600 iBridge`, and all four
devices stop working. No driver can fix it, because the firmware is *absent*, not unbound.
Only reinstalling macOS rewrites it.

This is the single most important fact about Linux on a T1 Mac, and Omarchy's own manual
never mentions it — it attributes the losses to "T1 hardware being unsupported". That
framing is why community reports list the webcam as dead too: a plain UVC device with no
reason to fail, except a T1 with no firmware.

```bash
# The check that governs everything. Run it after any install.
lsusb | grep 05ac
#   05ac:8600  -> good, firmware loaded
#   05ac:1281  -> T1 in recovery mode, the four devices are gone
```

No `lsusb`? Omarchy doesn't ship `usbutils`. Read sysfs instead:

```bash
for d in /sys/bus/usb/devices/*/; do
  [ "$(cat "$d/idVendor" 2>/dev/null)" = "05ac" ] &&
    echo "05ac:$(cat "$d/idProduct" 2>/dev/null) $(cat "$d/product" 2>/dev/null)"
done
```

**Back the ESP up first, from macOS.** Two formats, before you touch anything:

```bash
sudo diskutil mount disk0s1
mkdir -p ~/esp-backup && cd ~/esp-backup
tar -C /Volumes/EFI -cf - EFI | gzip -6 > esp-files.tar.gz
sudo dd if=/dev/rdisk0s1 bs=1m 2>/dev/null | gzip -6 > esp-raw.img.gz
shasum -a 256 ./*.gz > SHA256SUMS.txt
tar tzf esp-files.tar.gz | grep combined.memboot   # prove the firmware is inside
```

Copy that off the machine. Verify with the **tar stream**, not the raw image — a raw image of
a mounted FAT volume is never bit-stable, and two dumps minutes apart legitimately differ in
tail blocks where macOS writes Spotlight metadata.

These backups are machine-specific firmware and are **not** in this repo.

---

## Part 1 — Make room, from macOS

Omarchy's installer offers a **Free space install** that leaves existing partitions alone.
That is what preserves the T1 firmware. You need unallocated space for it.

```bash
# 1. free up space. Delete large things you have backed up, empty the Trash, and clear
#    local Time Machine snapshots — APFS will not shrink while they hold space.
tmutil listlocalsnapshots /
sudo tmutil deletelocalsnapshots <each-date>

# 2. shrink the APFS container. Cannot go below what is in use.
sudo diskutil apfs resizeContainer disk0s2 110g

# 3. verify. disk0s1 MUST still be ~314.6 MB.
diskutil list
```

### Two surprises during the resize

**Reported usage inflates alarmingly.** `Capacity In Use` climbed from 82 GB to **221 GB**
mid-shrink, because APFS relocates blocks out of the region being freed and both copies exist
at once. It collapses back on commit. Do not interrupt it.

**It takes ~20 minutes, not seconds** — `fsck` on every volume, then real data movement.
Never run it attached to an SSH session with a timeout; the partition map is written last, so
an interruption before that leaves the container at its original size, but do not rely on
luck. Detach it:

```bash
ssh host 'nohup setsid bash -c "sudo diskutil apfs resizeContainer disk0s2 110g \
  > /tmp/resize.log 2>&1" >/dev/null 2>&1 & echo started'
```

### How much to give macOS

Keep macOS. It is the only way to rewrite T1 firmware locally, and it takes Apple firmware
updates. Give it its current usage plus 25–30 GB. Omarchy itself installs into about 20 GB,
so being generous costs nothing.

Note the split is effectively **one-way**: Omarchy's partitions land *after* macOS, so
shrinking macOS later leaves an unusable gap rather than giving Omarchy room.

---

## Part 2 — Install Omarchy

**Skip Omarchy's "disable Secure Boot" step.** It cannot be done on a T1 machine: Secure Boot
arrived with the T2, and Startup Security Utility has no such pane. The manual is wrong on
this point for these models.

1. Insert the USB. Restart holding **Option**.
2. Pick the orange **EFI Boot** entry. If your install USB is plugged in you will see *two*
   identically-labelled entries — Apple's picker does not distinguish them.
3. At the disk screen choose **Free space install**, not the whole-drive option.
4. **Read the confirmation screen.** It should create a new EFI partition in your free space.
   **Abort if it lists the ~314.6 MB EFI partition as formatted or modified.**
5. Keep LUKS encryption enabled.

Result on a working install — note Omarchy makes its **own** 2 GB ESP and leaves Apple's
alone:

```
nvme0n1p1   300M  vfat          <- Apple's ESP, T1 firmware, UNTOUCHED
nvme0n1p2  102G   apfs          <- macOS, still bootable
nvme0n1p3    2G   vfat  /boot   <- Omarchy's own ESP
nvme0n1p4  129G   crypto_LUKS   <- Omarchy root
```

### Omarchy will not appear in Apple's boot picker

It boots as the firmware default, but holding Option shows only "Macintosh HD". Apple's
picker lists a generic "EFI Boot" entry only when it finds `\EFI\BOOT\BOOTX64.EFI`, and
Omarchy never creates it — it registers an NVRAM variable instead.

**Do not hold Option on the first reboot.** A normal power-on follows that NVRAM variable
and lands in Omarchy. Holding Option is what hides it, which makes the next step look
impossible. Once you are in, fix the picker permanently:

```bash
sudo mkdir -p /boot/EFI/BOOT
sudo cp /boot/EFI/limine/limine_x64.efi /boot/EFI/BOOT/BOOTX64.EFI
```

Do **not** also place a `limine.conf` next to it. Limine prefers a config beside its
executable, and a second copy drifting from the real one at the ESP root is a known cause of
unbootable Omarchy installs.

### Kernel parameters belong in a drop-in

`/boot/limine.conf` is **regenerated** by `limine-entry-tool` on any kernel or initramfs
change — including a package removal that rebuilds the UKI. Edits there vanish silently. Use:

```bash
sudo tee /etc/limine-entry-tool.d/macbook-t1.conf <<'EOF'
KERNEL_CMDLINE[default]+=" pcie_ports=compat"
EOF
sudo limine-update
```

---

## Part 3 — What Omarchy already does, and one bug it has

For `MacBookPro13,*` and `14,*` the installer automatically applies:

| Script | Effect |
| --- | --- |
| `fix-spi-keyboard.sh` | `macbook12-spi-driver-dkms` + initramfs modules |
| `fix-suspend-nvme.sh` | `d3cold_allowed=0`, the documented NVMe suspend fix |
| `fix-brcmfmac-supplicant.sh` | `feature_disable=0x82000` for the WPA handshake |
| `fix-t2.sh` | **correctly skipped** — gated on a T2 PCI ID a T1 does not have |

**The bug:** `fix-spi-keyboard.sh` installs `macbook12-spi-driver-dkms` **without
`linux-headers`**, so DKMS has no kernel build directory and silently produces nothing —
empty `/var/lib/dkms/`, no build logs. `fix-bcm43xx.sh` in the same tree gets this right.
Nobody notices because `applespi` is mainline since 5.3, so the keyboard works anyway; only
the Touch Bar and ALS are lost.

That package cannot build on a current kernel regardless (four API changes). Remove it — it
will fail on every kernel update and its module names collide with the working fork:

```bash
sudo dkms remove -m macbook12-spi-driver -v 0+git.315 --all
sudo pacman -R macbook12-spi-driver-dkms
modinfo -n applespi   # confirm mainline still provides it
```

---

## Part 4 — Wi-Fi: 5 GHz **and** a 26 dB signal fix

Everyone frames BCM43602 as "no 5 GHz on Linux, unfixable". That is the wrong diagnosis. The
adapter is not misconfigured, it is **unconfigured**.

**The tell is the MAC address:**

```bash
ip link show wlp2s0 | grep ether
# 00:90:4c:xx:xx:xx  -> Broadcom's OUI = NO NVRAM LOADED AT ALL
```

`00:90:4C` is Broadcom's generic placeholder. If you see it, the chip came up with no board
configuration — which costs you the 5 GHz band *and* the TX power tables and RF calibration.
That is why such machines are also **deaf**: few APs in a scan, weak signal, failing file
transfers. It reads as "I'm far from the router".

Measured, same spot, before and after:

| | Without NVRAM | With NVRAM |
| --- | --- | --- |
| MAC | `00:90:4c:xx:xx:xx` | the real Apple MAC |
| Bands | `Band 1` only | `Band 1` + `Band 2` |
| Signal | **-74 dBm** | **-42 dBm** |
| Link rate | 2.4 GHz rates | **324 Mbit/s** |
| Reliability | `scp` failed 4× in a row | stable |

See [`firmware/`](firmware/) for the file and the install procedure. Get your real MAC from
**macOS** (System Information → Wi-Fi) — under Linux without NVRAM the adapter reports the
placeholder, not the truth.

Two traps:

**`no clm_blob available (err=-2)` is a red herring.** For `linux-firmware` builds the
regulatory data is compiled into `brcmfmac43602-pcie.bin`; there is no separate blob. The
message appears on perfectly healthy systems. Do not fabricate that file — an injected
generic blob has been reported to crash the chip. For the same reason `country 99: DFS-UNSET`
on the phy is normal, as is a global domain that never reaches it — 5 GHz runs at full rate in
exactly that state. On current Arch, `/etc/conf.d/wireless-regdom` is vestigial: `crda` is gone
and no service reads that file.

**The driver cannot be reloaded live.** NetworkManager holds it, so `modprobe -r brcmfmac`
returns "Module brcmfmac is in use" and the NVRAM is never re-read. **Only a fresh boot picks
it up.** Since Wi-Fi may be your only route in, arm a failsafe before rebooting: a systemd
oneshot that waits ~100 s, checks `nmcli -t -f STATE general`, and deletes the NVRAM if the
network did not come up. **Disable it once confirmed**, or a future boot with a slow
NetworkManager will false-positive and delete a working file.

### The NVRAM enables the band, it does not choose it

This is the step that makes a correct install look like a failed one.

If your router presents 2.4 GHz and 5 GHz as **separate SSIDs** and you have connected to
both at some point, NetworkManager holds two profiles that both default to
`autoconnect-priority` 0. With the priorities tied it falls through to the last-connected
timestamp — and that is self-reinforcing. Every boot picks 2.4 GHz, connecting refreshes
that profile's timestamp, so 2.4 GHz wins again more strongly next time. **Each reboot
makes it worse, not better.**

The symptom is indistinguishable from "the NVRAM did not persist": you reboot, you are on
2.4 GHz, and the obvious conclusion is the wrong one.

Priority is evaluated before the timestamp, so one number settles it permanently:

```bash
# both profiles at 0? that is the bug
nmcli -f NAME,TYPE,AUTOCONNECT-PRIORITY connection show

nmcli connection modify "<YOUR_SSID>_5G" connection.autoconnect-priority 10
```

Leave the 2.4 GHz profile at 0 with autoconnect on. It becomes a fallback rather than a
competitor, and it reaches further than 5 GHz does.

**Do not pin the band or the BSSID to force the issue:**

```bash
# do NOT do this
nmcli connection modify "<YOUR_SSID>_5G" 802-11-wireless.band a
nmcli connection modify "<YOUR_SSID>_5G" 802-11-wireless.bssid AA:BB:CC:DD:EE:FF
```

Pinning either one removes NetworkManager's ability to fall back. A boot where 5 GHz does
not answer then hangs in `connecting (configuring)` instead of coming up on 2.4 GHz. If
Wi-Fi is your only route into the machine, that turns a working fallback into a lockout.

Measured after the fix: 5220 MHz, -43 dBm, 300 Mbit/s, chosen automatically on boot.

`boardflags3=0x00000300` was sufficient here. Several guides insist `0xC0000303` is required
for dual band; it was not. If 5 GHz does not appear, that is the next single variable.

---

## Part 5 — Audio

The Cirrus **CS8409** codec binds from mainline, and PipeWire shows a sink — but the speakers
stay silent, because the in-tree quirk table targets **Dell** subsystems (`0x1028`) only. No
kernel version will ever drive Apple's amplifiers unaided.

Use [`davidjo/snd_hda_macbookpro`](https://github.com/davidjo/snd_hda_macbookpro), which is
actively maintained and explicitly supports kernel 7.x:

```bash
sudo pacman -S --needed base-devel git wget dkms linux-headers
git clone https://github.com/davidjo/snd_hda_macbookpro.git
cd snd_hda_macbookpro
sudo ./install.cirrus.driver.sh -i     # -i = DKMS, survives kernel updates
sudo reboot
```

It downloads ~150 MB of kernel source, so run it detached from any SSH session.

**It works on `MacBookPro14,2`**, which `Dunedan/mbp-2016-linux` lists as unsupported. That
entry appears to derive from the driver's own quirk line being commented out:

```c
//SND_PCI_QUIRK(0x106b, 0x3600, "MacBookPro 14,2", CS8409_MBP143),   // disabled
  SND_PCI_QUIRK(0x106b, 0x3900, "MacBookPro 14,3", CS8409_MBP143),   // enabled
```

Uncommenting it is **not** necessary — the runtime code has explicit branches for subsystem
`0x106b3600` with their own GPIO mask.

**The microphone ships muted.** It reads as broken hardware:

```bash
wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0
wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 100%
```

Capture level is low by design on this hardware; go above 100% or use `easyeffects` if
needed.

---

## Part 6 — The Touch Bar

This is the part with no prior published success on a T1 under Omarchy. Two bugs blocked it,
and **neither is what the community discusses.**

Full detail in [`drivers/appleibridge/`](drivers/appleibridge/); the short version:

### Bug 1 — the driver self-deadlocks

`apple_ib_set_tb_mode()` calls `usb_set_configuration()` **while holding**
`appleib_tbmode_lock`. That call rebuilds the USB configuration and re-binds every interface
driver synchronously *in the same task*, re-entering `appleib_hid_probe()` → the same
function → the same mutex:

```
INFO: task modprobe:24033 is blocked on a mutex likely owned by task modprobe:24033.
```

The task is unkillable (`D` state), it hangs `sysinit.target` so the login screen never
appears, and it blocks shutdown — recovery is a forced power-off.

Patched here. It can also be **side-stepped with no patch**: the deadlock only fires when the
configuration actually changes, so `tb_mode_param=keyboard` selects the config the device
already boots in and takes the early return.

### Bug 2 — `hid-sensor-hub` silently steals the interface

**This is why the problem looks unsolvable.** The iBridge exposes two HID interfaces. At boot
the generic drivers claim both, and `hid-sensor-hub` keeps `.0002` — the one carrying the
Touch Bar reports:

```
[1.118] hid-generic    0003:05AC:8600.0001
[1.121] hid-generic    0003:05AC:8600.0002
[1.158] hid-sensor-hub 0003:05AC:8600.0002   <- keeps it
```

`apple_ibridge` reclaims `.0001` on load but **not** `.0002`, so `appletb_probe()` never
finds a device.

The failure mode is the problem: **the modules load, they bind, `lsmod` looks correct,
`dmesg` shows no error, and the strip stays dark.** There is nothing to search for. Anyone
reaching this point reasonably concludes T1 Touch Bar support does not exist on Linux.

The only tell is the *absence* of the writable sysfs controls that a successful probe
creates. Hand the interface over:

```bash
DEV=0003:05AC:8600.0002
printf '%s' "$DEV" | sudo tee /sys/bus/hid/drivers/hid-sensor-hub/unbind  >/dev/null
printf '%s' "$DEV" | sudo tee /sys/bus/hid/drivers/apple-ibridge-hid/bind >/dev/null
```

### Install

`drivers/appleibridge/` is **patched kernel source**, not a script you run. Do this
from inside Omarchy. The bugs above are already fixed in those files; the service
is what actually lights the strip.

**0. Confirm the T1 is alive.** You want `05ac:8600`. If you see `1281`, stop —
firmware is gone and no driver will help.

```bash
for d in /sys/bus/usb/devices/*/; do
  [ "$(cat "$d/idVendor" 2>/dev/null)" = "05ac" ] &&
    echo "05ac:$(cat "$d/idProduct" 2>/dev/null) $(cat "$d/product" 2>/dev/null)"
done
```

Remove Omarchy's broken SPI DKMS package if it is present. It collides with this
driver:

```bash
sudo dkms remove -m macbook12-spi-driver -v 0+git.315 --all
sudo pacman -R macbook12-spi-driver-dkms
modinfo -n applespi   # confirm mainline still provides it
```

**1. Get this repo onto the machine.**

```bash
sudo pacman -S --needed git base-devel linux-headers dkms zstd
git clone https://github.com/nohzafk/omarchy-macbookpro-t1.git
cd omarchy-macbookpro-t1
```

A USB copy of the tree works the same way. The `sudo cp` below is relative to the
repo root.

**2. Build the modules with DKMS.**

```bash
sudo mkdir -p /usr/src/appleibridge-0.1
sudo cp drivers/appleibridge/{*.c,*.h,Makefile,dkms.conf} /usr/src/appleibridge-0.1/
sudo dkms add -m appleibridge -v 0.1
sudo dkms build -m appleibridge -v 0.1
sudo dkms install -m appleibridge -v 0.1
```

**3. Install the service that takes interface `.0002` back.** Building is not
enough. At boot `hid-sensor-hub` steals the Touch Bar reports; the modules load,
`dmesg` looks fine, and the strip stays dark. The service fixes that.

```bash
sudo install -m 755 systemd/touchbar-enable.sh /usr/local/sbin/touchbar-enable.sh
sudo install -m 644 systemd/touchbar.service   /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now touchbar.service
journalctl -u touchbar.service -n 20 --no-pager
```

Expect `SUCCESS: fnmode=0 idle=-1 dim=-1` and both interfaces owned by
`apple-ibridge-hid`. The strip appears a few seconds after login, Esc + F1–F12.

Do **not** put these modules in `/etc/modules-load.d/`. If they wedge at boot they
hang `sysinit.target` and the only recovery is a forced power-off. The service
runs after `multi-user.target` on purpose: a failure then costs a dark strip,
not an unbootable machine.

### Things that look like failure but are not

- `apple_ib_tb` reporting `refcount=0` — it attaches through `apple_ibridge`'s sub-driver
  mechanism, not as a module dependency.
- `/sys/module/apple_ib_tb/parameters/*` being unwritable — those are `0444`. The writable
  copies live on the HID device directory.
- `find /sys/bus/hid/devices -name fnmode` finding nothing — that path is a **symlink** and
  `find` does not follow symlinks. Use `readlink -f`.

`fnmode=0` gives Esc + F1–F12 always, which is the useful mode.

---

## Part 7 — Missing Esc and F-keys, without the Touch Bar

If Part 6 already lit the strip, skip this. Esc and F1–F12 exist on the Touch Bar,
and Omarchy's volume/brightness bindings (`XF86*`) work.

If the strip is still dark, those keys **do not exist on the keyboard**. Caps Lock
is the only nearby key you can turn into Escape. Volume, brightness, mute and
keyboard light have no hardware keys at all until you bind them to something else.

Omarchy 4.x / Quattro uses Lua. The user file is `~/.config/hypr/input.lua` (also
reachable via Super+Space → Setup → Input). It ships as an all-commented template.
Omarchy's default already sets `kb_options = "compose:caps,..."` — Caps Lock is
the compose key — so you **replace** that option, you do not add a second line.

**Escape from Caps Lock:**

```lua
-- ~/.config/hypr/input.lua
hl.config({
  input = {
    kb_options = "caps:escape",
  },
})
```

Then `hyprctl reload`. Tap Caps Lock; it should send Escape (exit insert mode in
vim, close menus). You lose Caps Lock itself and Omarchy's compose-on-Caps
shortcut. Move compose to Right Alt if you still want it:

```lua
hl.config({
  input = {
    kb_options = "caps:escape,compose:ralt",
  },
})
```

**Volume and brightness without F-keys.** Omarchy binds those to `XF86*` keycodes
the Touch Bar emits. With a dark strip they never fire. Add fallbacks in
`~/.config/hypr/bindings.lua`. Super+Ctrl+Up/Down/Left are free; Super+Ctrl+L
is already Lock, so do not use Left for anything you will hit by accident.

```lua
-- ~/.config/hypr/bindings.lua
o.bind("SUPER + CTRL + UP",    "Volume up",   "omarchy-swayosd-client --output-volume raise", { repeating = true })
o.bind("SUPER + CTRL + DOWN",  "Volume down", "omarchy-swayosd-client --output-volume lower", { repeating = true })
o.bind("SUPER + CTRL + RIGHT", "Brightness up",   "omarchy-brightness-display +5%", { repeating = true })
o.bind("SUPER + SHIFT + DOWN", "Brightness down", "omarchy-brightness-display 5%-", { repeating = true })
```

`hyprctl reload` again. Dictation, if you use it, is already `SUPER + CTRL + X`
and does not need F9.

**A TTY (`Ctrl+Alt+F2`) is unavailable** on a Touch Bar machine with a dark
strip. Keep a USB keyboard for recovery.

---

## Part 8 — Suspend, USB-C, fans

### Suspend

Omarchy already applies the NVMe fix (`d3cold_allowed=0`). You do not install
anything else.

Suspend from the session: **Super+Escape** → Suspend. Closing the lid also works
once logind is set to suspend on lid close.

Resume looks hung if you only open the lid. Wait ~15 seconds **and press a
key**. Opening the lid alone does not finish the wake. Give it a full minute
before a forced power-off.

### USB-C after resume

Without `pcie_ports=compat`, two Thunderbolt xHCI controllers fail to reset
(`Host halt failed, -19`) and USB-C stays dead until reboot. That parameter
belongs in a limine **drop-in**, not in `/boot/limine.conf` — that file is
regenerated. If you skipped it in Part 2:

```bash
sudo tee /etc/limine-entry-tool.d/macbook-t1.conf <<'EOF'
KERNEL_CMDLINE[default]+=" pcie_ports=compat"
EOF
sudo limine-update
sudo reboot
```

Confirm it is on the running kernel, then that three xHCI controllers bound:

```bash
cat /proc/cmdline | tr ' ' '\n' | grep pcie_ports
dmesg | grep -i xhci
```

Plug something into USB-C after a resume. If it enumerates, the parameter took.

### Fans

Do **not** install `mbpfan`. `applesmc` loads itself and the SMC already runs
both fans in firmware (`fan*_manual = 0`). On this machine they moved 2101 →
3660 RPM under load while temperature fell 68 → 61 °C. `mbpfan` only lets you
reshape a curve that already works.

```bash
lsmod | grep applesmc
# optional, if lm_sensors is installed:
sensors
```

---

## Verification

[`scripts/omarchy-verify-hardware.sh`](scripts/) checks everything read-only and labels each
result, reporting missing tools as SKIP rather than as failing hardware. It reads the T1 ID
from sysfs, so it works without `usbutils`.

---

## Corrections to guides you will find elsewhere

| Common claim | Reality on a T1 |
| --- | --- |
| "Set Secure Boot to No Security in Startup Security Utility" | Impossible. Secure Boot arrived with the T2; the pane does not exist |
| "T1 Touch Bar and sound do not work" | Both work. See Parts 5 and 6 |
| "Install `mbpfan` or the CPU will throttle" | Wrong. The SMC manages fans in firmware |
| "Use `s2idle` to fix suspend" | Not the fix here. The NVMe `d3cold` fix is, and it is automatic |
| "No 5 GHz on BCM43602, unfixable" | Fixable, and it also recovers ~26 dB of signal |
| "Audio does not work on `MacBookPro14,2`" | It does |
| "Extract Wi-Fi firmware from macOS per the t2linux guide" | Not applicable. BCM43602 firmware ships in `linux-firmware`; only the NVRAM is missing |
| "5 GHz worked once, then stopped surviving reboots" | Not the firmware. NetworkManager's priority tie-break silently prefers 2.4 GHz; set `autoconnect-priority` on the 5 GHz profile |
| "Install `broadcom-wl`" | Do not. Wrong driver for this chip, and Omarchy's own installer excludes 43602 from it |
| "`tiny-dfr` / `hid-appletb-kbd` for the Touch Bar" | T2-only. They do nothing on a T1 |

---

## Which driver fork to use

Every alternative lineage is older and does not build on a current kernel:

| Repo | Last commit |
| --- | --- |
| `t2linux/apple-ib-drv` master | 2018-03-14 |
| `t2linux/apple-ib-drv` `ibridge-reviews` | 2019-07-19 |
| `kekrby/apple-ibridge` | 2021-09-20 |
| **`F13-Kr1pt0n/macbook-pro-touchbar-driver`** | **2025-09-02** ← basis for this repo |

None ship `applespi`, correctly — that driver is mainline since 5.3.

---

## Credits

- [`F13-Kr1pt0n/macbook-pro-touchbar-driver`](https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver)
  — the Touch Bar driver this repo patches
- [`roadrunner2/macbook12-spi-driver`](https://github.com/roadrunner2/macbook12-spi-driver)
  — the original iBridge and SPI work
- [`davidjo/snd_hda_macbookpro`](https://github.com/davidjo/snd_hda_macbookpro) — CS8409 audio
- [`Dunedan/mbp-2016-linux`](https://github.com/Dunedan/mbp-2016-linux) — the per-model status
  tracker, and the source of the ESP firmware insight
- [MikeRatcliffe's gist](https://gist.github.com/MikeRatcliffe/9614c16a8ea09731a9d5e91685bd8c80)
  — the BCM43602 NVRAM
- [Omarchy](https://omarchy.org) — the distribution

Driver code is GPL-2.0, as upstream. Documentation is offered freely; corrections and reports
from other T1 models are very welcome.
