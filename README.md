# A GNSS-disciplined NTP, NTS and PTP time server on a Raspberry Pi 5 with Ubuntu 26.04 LTS

*Building on Austin's guides, with automatic offset calibration, an active "CPU oven", a PTP grandmaster and authenticated time*

---

> **About the examples in this guide.** Hostnames (`timepi`, `timepi.local`), IP addresses (`192.168.1.50`,
> `192.168.1.0/24`), the monitor NTP servers and certificate names are **examples** to illustrate the
> configuration. Replace them with your own values. Measured numbers (latencies, offsets, temperatures) come from
> my unit and show what to expect; your hardware will differ, which is why the offsets are measured, not copied.

## Where this started

This build stands on three articles by Austin at *Austin's Nerdy Things*. All of the information here builds on them:

1. [**Microsecond accurate NTP with a Raspberry Pi and PPS GPS**](https://austinsnerdythings.com/2021/04/19/microsecond-accurate-ntp-with-a-raspberry-pi-and-pps-gps/) (2021)
   is the original recipe. It wires a GPS's PPS output to GPIO 18 (`dtoverlay=pps-gpio,gpiopin=18`), runs gpsd on the
   serial port, and has chrony combine the coarse NMEA time (`refclock SHM 0`) with the precise PPS pulse
   (`refclock PPS /dev/pps0`). It also introduces the idea of watching the NMEA source with `noselect` to find its delay.
2. [**Revisiting Microsecond Accurate NTP for Raspberry Pi with GPS PPS in 2025**](https://austinsnerdythings.com/2025/02/14/revisiting-microsecond-accurate-ntp-for-raspberry-pi-with-gps-pps-in-2025/)
   brings that up to date. It moves to the Pi 5 and timing receivers such as the u-blox LEA-M8T, and uses
   `lock NMEA … trust`. It raises the baud rate so the time-of-day message isn't attributed to the wrong second, tunes
   the NMEA offset from `statistics.log`, and makes the point that **temperature** limits how good a Pi clock can be.
3. [**Nanosecond accurate PTP server (grandmaster) and client tutorial for Raspberry Pi**](https://austinsnerdythings.com/2025/02/18/nanosecond-accurate-ptp-server-grandmaster-and-client-tutorial-for-raspberry-pi/) (2025)
   turns the Pi 5's Ethernet hardware clock into a PTP grandmaster with `ptp4l` + `phc2sys`. It includes the systemd
   units and the interrupt-coalescing tweak (`ethtool -C eth0 tx-usecs 4 rx-usecs 4`) used here almost unchanged.

If you're new to GPS/PPS timekeeping, read them first. This guide combines all three into one hands-off server
on **Ubuntu Server 26.04 LTS**, fixes a few things that bit me along the way, and adds **NTS** (authenticated time).

## What's different from the original guides

| Area | Austin's guides | This build |
|---|---|---|
| OS | Raspberry Pi OS (Raspbian / Debian 12) | **Ubuntu Server 26.04 LTS** (kernel 7.0, piboot-try A/B boot, AppArmor), supported until 2031 |
| NMEA offset | Found by watching NMEA for hours (`delay 0.325`, 2021) or by plotting an hour of `statistics.log` and picking the average (`offset 0.511`, 2025) | **Measured automatically** on the serial port, refined against PPS, cross-checked against Internet servers, with **automatic rollback** (`gps-baud-change.sh`) |
| Baud rate | `PMTK251` via `gpsctl` (MediaTek receivers); setting lost on power loss | **u-blox `UBX-CFG-PRT`** via `ubxtool`, saved to the receiver, **re-applied at boot** before gpsd/chrony start (`gps-baud.service`). Offset recalibrated in the same step. |
| Serial traffic | NMEA sentences | gpsd runs the u-blox in **binary UBX** (~520 bytes/epoch); latency at 9600 baud **drifts with the satellite count**; 115200 baud fixes it |
| NMEA refclock | selectable (`poll 0 filter 3`, later `poll 2`) | `noselect`: the coarse source can never be used on its own, not even briefly at boot |
| Thermal | Enclosure + newspaper, **powersave** governor (performance overheated and crashed); temperature-controlled enclosure listed as a next step | **Active temperature control**: PI-controlled CPU heater holds the SoC (and the crystal next to it) at **60 °C ± 0.6**, fan at a **fixed** speed, **70 °C hard cutoff**. This makes the **performance** governor safe. |
| CPU isolation | not covered | chronyd at **SCHED_FIFO 50 on CPU0**, PPS IRQ on CPU0, heater confined to CPUs 1–3 at **SCHED_IDLE** |
| Sanity check | chrony's own statistics / Grafana | Three Internet NTP servers as **`noselect` monitors**: an independent reference visible in every `chronyc sources` |
| GNSS loss | not covered | `local stratum 10 orphan`: the box doesn't keep claiming stratum 1 |
| PTP timescale | `phc2sys -O 0` (PHC follows the UTC system clock), `timeSource 0x10`; the chrony client marks the PHC `tai` | PHC carries **TAI** (`phc2sys -O 37`), grandmaster announces `currentUtcOffsetValid 1`, `ptpTimescale 1`, `timeSource 0x20` (GNSS), so clients that treat PTP as TAI (like that `tai` refclock) get the right time |
| PTP on Ubuntu | — | ptp4l's AppArmor profile: config under `/etc/linuxptp/`, local override so `pmc` gets answers |
| Authentication | not covered | **NTS (RFC 8915)** with a local CA. Clients can verify they're talking to this clock. |

---

## 1. Architecture

```
                 ┌──────────────── Raspberry Pi 5 (Ubuntu 26.04 LTS, NVMe boot) ─────┐
 GNSS antenna    │                                                                    │
     │           │  /dev/ttyAMA0 ──► gpsd ──SHM 0──► chronyd ◄── /dev/pps0 (GPIO18)  │
 ┌───┴────────┐  │  (UBX @115200)        "NMEA"     │  ▲  "PPS" (lock NMEA)          │
 │ u-blox     │──┤                                  │  │                             │
 │ LEA-M8T    │  │       CLOCK_REALTIME (UTC) ──► NTP clients :123, NTS-KE :4460     │
 │ (TIM 1.10) │──┤ PPS                              │                                │
 └────────────┘  │                     phc2sys -O 37 ▼                               │
                 │                       /dev/ptp0 (eth0 PHC, TAI) ◄── ptp4l ──► PTP │
                 │  time-burner (CPUs 1-3, SCHED_IDLE) keeps the SoC/crystal at 60 °C│
                 └────────────────────────────────────────────────────────────────────┘
```

**Hardware**
- Raspberry Pi 5 Model B, NVMe SSD, official Active Cooler (PWM fan)
- GNSS HAT with a **u-blox LEA-M8T** timing receiver (firmware TIM 1.10, protocol 22.00) and an outdoor antenna
- Serial on GPIO 14/15 (`/dev/ttyAMA0`), PPS on **GPIO 18**: the same pins as in Austin's guides

**Software (tested versions)**

| Package | Version | Role |
|---|---|---|
| Ubuntu Server for Raspberry Pi | 26.04.1 LTS, kernel 7.0.0-1020-raspi | OS |
| `chrony` | 4.8 | NTP + NTS server, PPS/SHM refclocks |
| `gpsd` | 3.27.5 | receiver driver; also ships `ubxtool` and `gpsctl` |
| `gpsd-clients`, `gpsd-tools` | 3.27.5 | `gpspipe` / `gpsmon`, `cgps`; pull in `python3-gps` and `python3-serial` (needed by `ubxtool`) |
| `pps-tools` | 1.0.2 | `ppstest` |
| `linuxptp` | 4.4 | `ptp4l`, `phc2sys`, `pmc`, `phc_ctl` (ships AppArmor profiles) |
| `linux-tools-raspi` (+ `linux-tools-common`) | matches the kernel | `cpupower` |
| `ethtool` | 6.19 | interrupt coalescing, timestamping capabilities |
| `python3` | 3.14 | CPU oven |
| `tzdata` | 2026e | leap-second list |

**How the time is built.** The PPS pulse marks *exactly when* each second starts, at nanosecond level, but
says nothing about *which* second it is. The serial messages say which second it is, but arrive late and with
jitter. chrony's `lock NMEA` uses PPS for the phase and the serial time only to *number* the pulses. That works
as long as the serial time, after its offset correction, is well within ±0.5 s of the truth. Much of this build
is about keeping it there automatically.

---

## 2. Install the OS and packages

1. Flash **Ubuntu Server 26.04 LTS for Raspberry Pi** (arm64) with Raspberry Pi Imager. Set the hostname
   (here: `timepi`), user and SSH key.
2. Boot, update and install:
   ```bash
   sudo apt update && sudo apt full-upgrade -y
   # timing stack
   sudo apt install -y chrony gpsd gpsd-clients gpsd-tools python3-gps python3-serial \
                       pps-tools linuxptp linux-tools-raspi linux-tools-common ethtool python3 openssl
   # optional, for troubleshooting
   sudo apt install -y jq tcpdump
   sudo systemctl disable --now ModemManager.service   # it probes serial ports
   ```
   chrony is Ubuntu's default time daemon, so there's no ntpd or timesyncd to remove. `python3-gps` and
   `python3-serial` would come in with `gpsd-clients` anyway; they're listed because `ubxtool` (used by
   `gps-baud-change.sh`) needs them to talk to the receiver's serial port directly.

   Every command this guide and its scripts use, and where it comes from:

   | Command | Package | Used for |
   |---|---|---|
   | `gpsd`, `ubxtool`, `gpsctl` | `gpsd` | receiver driver; u-blox configuration (baud rate, save) |
   | `gpspipe` | `gpsd-clients` | raw/JSON stream, checking the receiver |
   | `gpsmon`, `cgps` | `gpsd-tools` | interactive receiver status |
   | `ppstest` | `pps-tools` | checking the PPS pulse |
   | `chronyd`, `chronyc` | `chrony` | NTP/NTS server |
   | `ptp4l`, `phc2sys`, `pmc`, `phc_ctl` | `linuxptp` | PTP grandmaster |
   | `cpupower` | `linux-tools-common` + `linux-tools-raspi` | performance governor |
   | `ethtool` | `ethtool` | interrupt coalescing, timestamping capabilities |
   | `python3` | `python3` | CPU oven, calibration helper |
   | `openssl` | `openssl` | NTS certificates |
   | `apparmor_parser` | `apparmor` (preinstalled) | reloading the ptp4l profile |
   | `chrt`, `taskset`, `renice`, `pgrep`, `ss`, `systemd-analyze` | `util-linux`, `bsdutils`, `procps`, `iproute2`, `systemd` (preinstalled) | priorities, CPU pinning, checks |

---

## 3. Boot configuration

Ubuntu 26.04 boots the Pi through **piboot-try**: kernel, initrd, device-tree overlays and the kernel command line
live in `/boot/firmware/current/` (and `new/` while a kernel update is being trialled). `config.txt` stays at the
top level and already contains `os_prefix=current/` plus a `[tryboot]` section. Leave those lines alone.

**`/boot/firmware/config.txt`**: append to the final `[all]` section (the first two lines are from Austin's guides):

```ini
# GNSS: UART on GPIO14/15 (/dev/ttyAMA0), PPS on GPIO18
enable_uart=1
dtoverlay=pps-gpio,gpiopin=18

# Constant fan speed: the CPU oven is the only temperature controller (setpoint 60 C).
# Fan stays at PWM 125 between ~30 and 70 C and ramps up above 70 C only as overheat protection.
dtparam=fan_temp0=35000,fan_temp0_hyst=5000,fan_temp0_speed=125
dtparam=fan_temp1=70000,fan_temp1_hyst=5000,fan_temp1_speed=175
dtparam=fan_temp2=75000,fan_temp2_hyst=5000,fan_temp2_speed=225
dtparam=fan_temp3=80000,fan_temp3_hyst=5000,fan_temp3_speed=255
```

**`/boot/firmware/current/cmdline.txt`**: Raspberry Pi OS uses `raspi-config` for this. On Ubuntu, edit the file
directly: **remove** `console=serial0,115200` and keep `console=tty1`, so the kernel console doesn't talk to the
GNSS receiver. piboot-try copies this file forward on kernel updates. If `/boot/firmware/new/` exists, edit its
`cmdline.txt` too. Example result:

```
multipath=off dwc_otg.lpm_enable=0 console=tty1 root=LABEL=writable rootfstype=ext4 rootwait fixrtc
```

Then:

```bash
sudo systemctl disable --now serial-getty@ttyAMA0.service
echo pps-gpio | sudo tee /etc/modules-load.d/pps-gpio.conf
sudo reboot
```

Check the hardware:

```bash
ls /boot/firmware/current/overlays/pps-gpio.dtbo
sudo ppstest /dev/pps0          # one "assert" per second
gpsmon /dev/ttyAMA0             # fix and satellites (Ctrl-C)
ethtool -T eth0                 # hardware-transmit / hardware-receive, PTP Hardware Clock: 0
```

---

## 4. gpsd

**`/etc/default/gpsd`**:

```bash
DEVICES="/dev/ttyAMA0"
GPSD_OPTIONS="-n"
USBAUTO="false"
START_DAEMON="true"
```

`-n` makes gpsd poll the receiver even with no clients, so chrony always gets SHM samples. Unlike in Austin's
guides, `/dev/pps0` is **not** listed: chrony reads the PPS device directly, and only one program needs it.

```bash
sudo systemctl enable --now gpsd.socket gpsd.service
```

### What's actually on the wire

With a u-blox receiver, gpsd switches it to **binary UBX** output. The `$GP…` sentences you see in
`gpspipe -r` are generated by gpsd itself. A raw capture of the serial port shows each epoch is:

| UBX message | Bytes/epoch |
|---|---|
| NAV-PVT | 100 |
| NAV-SAT | 8 + **12 per satellite** (304 with 24 satellites) |
| NAV-POSECEF, NAV-DOP, NAV-VELECEF, NAV-TIMEGPS, NAV-EOE | ~120 |
| **Total** | **~520** |

At 9600 baud (~960 bytes/s) that's ~0.55 s on the wire. My unit delivered each epoch at **~0.64 s** past the second,
and **each extra satellite adds ~12.5 ms**: the latency drifted between 0.64 and 0.71 s over a single day as the
constellation changed. A hand-tuned offset can't follow that, which is why the baud rate goes to 115200 (section 7).

---

## 5. chrony

**`/etc/chrony/chrony.conf`** (example values; the NMEA offset is measured in section 7):

```conf
confdir /etc/chrony/conf.d

# Serve the LAN (example subnet; tighten to yours)
allow 192.168.1.0/24

# If GNSS is lost, fall back to orphan mode instead of claiming stratum 1 forever
local stratum 10 orphan

# Coarse time from gpsd (SHM 0): only used to number the PPS pulses, never selected on its own.
# The offset is the serial latency as seen by chrony; gps-baud-change.sh measures and writes it.
refclock SHM 0 refid NMEA offset 0.106 precision 1e-1 poll 0 noselect
# The real reference: PPS on GPIO18. The offset is ~0 by definition; never "tune" it.
refclock PPS /dev/pps0 refid PPS lock NMEA offset 0.0 poll 3 trust prefer

# Independent cross-check only (never selected). Example servers; pick ones near you.
server time.cloudflare.com iburst noselect
server time.google.com iburst noselect
server 0.pool.ntp.org iburst noselect

keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
ntsdumpdir /var/lib/chrony

# NTS server (section 10)
ntsserverkey /etc/chrony/nts/timepi.key
ntsservercert /etc/chrony/nts/timepi-fullchain.crt

log tracking statistics
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1 3
leapseclist /usr/share/zoneinfo/leap-seconds.list
```

Why these choices:

- **The offset belongs on the NMEA line, never on the PPS line.** Austin's guides do this right (`delay`/`offset` on
  `SHM 0`). I learned it the hard way: an old config of mine had the correction on the PPS refclock (`offset 0.3979`).
  chrony locked to that shifted second boundary with nanosecond *precision* and reported stratum 1, ±150 ns, 12 µs
  dispersion. Measured against three Internet servers, it was **602 ms wrong** (1 − 0.3979 = 0.6021).
- **`noselect` on NMEA**: the coarse source only labels pulses. Without `noselect`, chrony may select it briefly at
  boot, before PPS is usable.
- **`noselect` Internet monitors**: they never steer the clock, but `chronyc sources` always shows them next to PPS.
  That 602 ms error would have been obvious at a glance. They also show a broken boot immediately (gpsd not running
  → all monitors at the same large offset).
- The Ubuntu image ships pool/NTS client sources in `/etc/chrony/sources.d/`. With no `sourcedir` line they aren't
  used. If you keep `sourcedir`, add `noselect` to them.

---

## 6. CPU isolation and priorities

`/usr/local/bin/pps-optimize.sh` (companion file) runs at boot and every time chrony restarts:

- `cpupower frequency-set -g performance`: no frequency switching latency. The CPU oven (section 8) keeps
  performance mode from overheating, the problem described in the 2025 NTP article.
- PPS interrupt pinned to CPU0, **looked up by name** (`pps@` in `/proc/interrupts`): the IRQ number differs
  between kernels and boots.
- Every `chronyd` process (on 26.04 that includes the `chronyd-starter` wrapper) at **SCHED_FIFO 50 on CPU0**.
- `ksoftirqd/0` reniced to −10.

`/etc/systemd/system/pps-optimize.service`:

```ini
[Unit]
Description=PPS NTP Performance Optimization
After=chrony.service
Requires=chrony.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/pps-optimize.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
```

`Requires=` makes it re-run when chrony restarts, so the real-time priority is never lost.

---

## 7. Baud rate and automatic offset calibration

The 2025 NTP article changes the baud rate with `PMTK251` via `gpsctl`. That command is specific to **MediaTek**
receivers; a u-blox ignores it. (My own first script also had `"$PMTK251,…"` in double quotes, so bash expanded
`$PMTK251` to an empty string. It never worked on any receiver.) The u-blox way is `UBX-CFG-PRT`, which is what
`ubxtool -S <baud>` sends. A commenter on Austin's post suggests the same.

Changing the baud changes the latency, and the latency must match chrony's NMEA offset, or PPS gets the wrong
second. So `gps-baud-change.sh` (companion file) does it as one transaction:

1. Stop gpsd. chrony's NMEA samples go stale, chrony stops using PPS and holds over on its disciplined frequency.
2. Detect the current baud (validating UBX/NMEA checksums), send `UBX-CFG-PRT`, verify, save the receiver config.
3. **Measure the latency directly on the serial port**: arrival time of `UBX-NAV-EOE` (end of epoch, which is what
   makes gpsd report the fix) minus the epoch's `iTOW`. No hours of watching and no plotting.
4. Write the offset into chrony.conf, restart chrony and gpsd, wait for PPS lock.
5. Refine the offset from chrony's own NMEA-vs-PPS residual (this absorbs how gpsd timestamps the epoch).
6. Cross-check against the Internet monitors; **roll back** baud and chrony.conf on any failure.

Modes: `gps-baud-change.sh [BAUD]` (default 115200), `--measure` (latency only), `--boot` (used by the service
below). The target baud is stored in `/etc/default/gps-baud`, and runs are logged to `/var/log/gps-baud-change.log`.

The measurement was validated against chrony before it was trusted: at 9600 baud it measured **0.6433 s**, against
**0.640 s** derived from chrony's statistics. Example run:

```
receiver at 115200 baud, chrony NMEA offset 0.134
NMEA latency at 115200 baud: median 0.1485 s (min 0.1408, max 0.1557, n=11)
chrony NMEA offset 0.134 -> 0.148; restarting chrony, starting gpsd
NMEA residual vs PPS: -0.041764710 s
refining NMEA offset 0.148 -> 0.106
done: receiver at 115200 baud, chrony NMEA offset 0.106, monitors median |offset| 0.000229673 s
```

| | 9600 baud | 115200 baud |
|---|---|---|
| Serial latency (my unit) | 0.643 s, 26 ms spread, drifts with satellites | 0.149 s, 15 ms spread |
| NMEA vs PPS after calibration | drifted to −66…−77 ms | about ±1 ms |
| Margin to the ±0.5 s cliff | ~0.42 s and shrinking | ~0.5 s |

Re-run `sudo gps-baud-change.sh 115200` (same baud = recalibrate only) after a gpsd or kernel update; both can shift
the effective latency by tens of milliseconds.

**Making it survive power loss.** The LEA-M8T runs from ROM, so whether a saved baud survives a power cut depends on
its backup battery. `gps-baud.service` re-applies the target baud **before** gpsd and chrony start:

```ini
[Unit]
Description=Set u-blox GNSS receiver baud rate (must match chrony NMEA offset)
# Run early, before gpsd.socket/sockets.target. Default dependencies would order
# this after basic.target -> sockets.target -> gpsd.socket and create a cycle.
DefaultDependencies=no
After=sysinit.target dev-ttyAMA0.device
Wants=dev-ttyAMA0.device
Before=gpsd.socket gpsd.service chrony.service shutdown.target
Conflicts=shutdown.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/gps-baud-change.sh --boot
RemainAfterExit=yes
TimeoutStartSec=60
[Install]
WantedBy=multi-user.target
```

`DefaultDependencies=no` matters. Without it, systemd sees an ordering cycle and silently drops `gpsd.socket` at
boot. No gpsd means no NMEA, which means no PPS. Check with `systemd-analyze verify gps-baud.service gpsd.socket`.

**First calibration on a fresh box.** The latency is unknown and the clock may be wrong, so bootstrap from the Internet:

1. Temporarily remove `noselect` from the three `server` lines and comment out the PPS line;
   `sudo systemctl restart chrony`; wait until `chronyc tracking` shows a few ms or better.
2. Install the scripts (section 11) and record the current baud: `echo GPS_BAUD=9600 | sudo tee /etc/default/gps-baud`.
3. `sudo gps-baud-change.sh --measure`, then put the measured value in the NMEA `offset`.
4. Restore the PPS line and `noselect`, restart chrony.
5. `sudo gps-baud-change.sh 115200`, then `sudo systemctl enable gps-baud.service`.

---

## 8. The CPU oven: active temperature control

Between PPS pulses, and during any GNSS outage, the system clock runs on the Pi's own crystal, which sits next to
the SoC. Its frequency moves with temperature. Austin's 2025 article fights this passively with an enclosure, and notes
that the performance governor overheated his Pi. Here the temperature is **actively regulated** instead: a small
daemon burns just enough CPU time on cores 1–3 to hold the SoC at 60 °C.

`time_burner.py` (companion file) design:

- **Smooth heat**: 50 ms PWM period per worker, phases **staggered** across the three workers, so total power is
  close to constant instead of synchronised bursts.
- **Never in the way**: workers are `SCHED_IDLE` on CPUs 1–3 only (`CPUAffinity=1-3` for the whole service). Any
  real work preempts them instantly; CPU0 belongs to chrony and the PPS IRQ.
- **Control**: PI loop every 1 s on the average of ~10 sensor reads (the sensor has 0.55 °C steps), clamped
  integral with conditional integration (real anti-windup), bumpless start at 25 % duty, `time.monotonic()`
  throughout so chrony clock steps can't disturb it.
- **Safety**: heater off at ≥ 70 °C or if the sensor can't be read. The kernel fan curve still ramps above 70 °C,
  and kernel throttling at 85 °C is untouched.
- **One controller per variable**: the Pi 5's default fan curve has a trip point at exactly 60 °C. With the
  default curve, the fan and the oven fight over the same temperature. Hence the fixed fan speed in `config.txt`.
- One log line every 5 minutes (mean, σ, min/max, duty).

`/etc/systemd/system/time-burner.service`:

```ini
[Unit]
Description=CPU Thermal Stabilization for NTP (oscillator temperature control)
After=multi-user.target
[Service]
Type=simple
User=root
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 /usr/local/bin/time_burner.py --target 60 --max-temp 70 --workers 3 --cpus 1,2,3
CPUAffinity=1-3
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
```

Measured on my unit:

| | First heater version (200 ms bursts, auto fan) | Final version (staggered 50 ms PWM, fixed fan) |
|---|---|---|
| Mean SoC temperature (setpoint 60 °C) | 60.56 °C | **60.01 °C** |
| σ at 10 Hz | 0.76 °C | **0.61 °C** |
| CPU used | ~0.96 core | ~0.65 core |
| Log volume | 5 lines/s (it filled 3.9 GB of journal) | 1 line / 5 min |

Choose the setpoint so the heater has headroom both ways. With the fan fixed at PWM 125 it needs ~25 % duty to
hold 60 °C here: high enough above idle temperature for a warm room, low enough for a cold one.

chrony logs `tracking` and `statistics`. Comparing the frequency column of `/var/log/chrony/tracking.log` with the
oven's temperature over a day shows what it buys, and whether chrony's `tempcomp` would add anything.

---

## 9. PTP grandmaster

This section follows Austin's PTP tutorial: the same `ptp-gm.conf`, the same `ptp4l-grandmaster` /
`phc2sys-grandmaster` units and the same coalescing service. It changes three things.

**1. Timescale.** PTP carries **TAI** (currently UTC + 37 s), and grandmasters announce the UTC offset. The tutorial
runs `phc2sys -O 0`, so the PHC follows the UTC system clock, while its chrony *client* marks the PHC as `tai`.
Those two disagree by 37 s. Here the PHC is set to TAI (`-O 37`), and the grandmaster announces
`currentUtcOffset 37`, `currentUtcOffsetValid 1` and `ptpTimescale 1`. A client that treats PTP as TAI (a chrony
`refclock PHC … tai`, or `phc2sys -w`) then lands on the right UTC.

**2. `timeSource 0x20`** (GPS/GNSS) instead of `0x10` (atomic clock), as a commenter on the tutorial points out.

**3. Ubuntu's AppArmor.** The ptp4l profile only allows configuration under `/etc/linuxptp/`, and it denies ptp4l's
replies to `pmc` (socket `/run/pmc.<pid>`). Without a local override, the `SET GRANDMASTER_SETTINGS_NP` below can't be
confirmed.

**`/etc/linuxptp/ptp-gm.conf`**:
```ini
[global]
verbose               1
time_stamping         hardware
serverOnly            1
priority1             128
clockClass            6
# 0x20 = GNSS
timeSource            0x20
```
(`serverOnly` is the current name for `masterOnly`. If hardware timestamping misbehaves, commenters on the tutorial
report that `hwts_filter full` helps; it wasn't needed here.)

**`/etc/apparmor.d/local/usr.sbin.ptp4l`**:
```
# allow ptp4l to answer pmc management clients (reply socket /run/pmc.<pid>)
@{run}/pmc.[0-9]* rw,
```
```bash
sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.ptp4l
```

**`/etc/systemd/system/ptp4l-grandmaster.service`**:
```ini
[Unit]
Description=Precision Time Protocol (PTP) service (Grandmaster)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/sbin/ptp4l -f /etc/linuxptp/ptp-gm.conf -i eth0
ExecStartPost=/bin/sh -c 'sleep 3; /usr/sbin/pmc -u -b 0 "SET GRANDMASTER_SETTINGS_NP clockClass 6 clockAccuracy 0x21 offsetScaledLogVariance 0x4e5d currentUtcOffset 37 leap61 0 leap59 0 currentUtcOffsetValid 1 ptpTimescale 1 timeTraceable 1 frequencyTraceable 1 timeSource 0x20"'
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
```

**`/etc/systemd/system/phc2sys-grandmaster.service`**:
```ini
[Unit]
Description=sync PHC with system clock (grandmaster)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
# PHC = system clock (UTC) + 37 s = TAI
ExecStart=/usr/sbin/phc2sys -s CLOCK_REALTIME -c eth0 -O 37 --step_threshold=0.5
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
```

**`/etc/systemd/system/ptp_nic_coalesce.service`** (from the tutorial; the Pi's default is 49 µs):
```ini
[Unit]
Description=NIC coalesce minimize
Requires=network.target
After=network.target
[Service]
ExecStart=/usr/sbin/ethtool -C eth0 tx-usecs 4 rx-usecs 4
Type=oneshot
[Install]
WantedBy=multi-user.target
```

> When a leap second is announced, `currentUtcOffset` and `-O` must change together (37 → 38).

---

## 10. NTS: authenticated time

Plain NTP has no authentication: anything on the network that answers UDP 123, or sits in the path, can feed clients
a wrong time. **NTS (RFC 8915)** fixes that. The client runs a TLS 1.3 key exchange (NTS-KE, TCP 4460), verifies the
server certificate, then authenticates every NTP packet with the keys it received. The time path itself gets no extra
round trips.

Clients verify the certificate against the configured name, just like HTTPS. A LAN box has no public DNS name, so this
build uses a **local CA**. Clients trust only the CA, and the server certificate can be renewed without touching them.
Put your own hostname(s) and IP in `subjectAltName` (the values below are examples):

```bash
sudo mkdir -p /etc/chrony/nts/ca && sudo chmod 700 /etc/chrony/nts/ca && cd /etc/chrony/nts

# CA (once; 10 years). The CA key never leaves this box.
sudo openssl ecparam -name prime256v1 -genkey -noout -out ca/timepi-ca.key
sudo chmod 600 ca/timepi-ca.key
sudo openssl req -x509 -new -key ca/timepi-ca.key -sha256 -days 3650 \
  -subj "/CN=timepi local NTS CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" -out timepi-ca.crt

# Server certificate (825 days). Re-run this block to renew.
sudo openssl ecparam -name prime256v1 -genkey -noout -out timepi.key
sudo openssl req -new -key timepi.key -subj "/CN=timepi" -out /tmp/timepi.csr
printf '%s\n' "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
  "extendedKeyUsage=serverAuth" "subjectAltName=DNS:timepi,DNS:timepi.local,IP:192.168.1.50" \
  | sudo tee /tmp/timepi.ext >/dev/null
sudo openssl x509 -req -in /tmp/timepi.csr -CA timepi-ca.crt -CAkey ca/timepi-ca.key -CAcreateserial \
  -days 825 -sha256 -extfile /tmp/timepi.ext -out timepi.crt
sudo sh -c 'cat timepi.crt timepi-ca.crt > timepi-fullchain.crt'
sudo chown root:_chrony timepi.key && sudo chmod 640 timepi.key
sudo rm -f /tmp/timepi.csr /tmp/timepi.ext
```

The `ntsserverkey`/`ntsservercert` lines are already in the chrony.conf above. Ubuntu's chronyd AppArmor profile
allows `/etc/chrony/**`, so no profile change is needed. `ntsdumpdir` keeps the server keys across restarts, so
clients' cookies stay valid.

**Clients** (chrony ≥ 4.0): copy `timepi-ca.crt` to `/etc/chrony/certs/` and configure

```conf
ntstrustedcerts /etc/chrony/certs/timepi-ca.crt
server timepi.local iburst nts
```

`chronyc -N authdata` on the client should show mode `NTS` with cookies. Quick test without changing a client's config:

```bash
sudo chronyd -Q -t 20 "ntstrustedcerts /path/to/timepi-ca.crt" "server timepi.local iburst nts"
openssl s_client -connect 192.168.1.50:4460 -alpn ntske/1 -CAfile timepi-ca.crt -verify_hostname timepi.local -brief </dev/null
```

Windows' `w32tm` doesn't speak NTS; those machines keep using plain NTP, which is still served.

---

## 11. Install the scripts and enable everything

The longer scripts are companion files next to this post:

| File | Install to |
|---|---|
| `time_burner.py` | `/usr/local/bin/time_burner.py` (mode 755) |
| `time-burner.service` | `/etc/systemd/system/time-burner.service` |
| `gps-baud-change.sh` | `/usr/local/bin/gps-baud-change.sh` (mode 755) |
| `gps-baud.service` | `/etc/systemd/system/gps-baud.service` |
| `pps-optimize.sh` | `/usr/local/bin/pps-optimize.sh` (mode 755) |

```bash
sudo systemctl daemon-reload
sudo systemd-analyze verify gps-baud.service gpsd.socket   # must not report an ordering cycle
sudo systemctl enable --now chrony gps-baud ptp_nic_coalesce ptp4l-grandmaster \
                            phc2sys-grandmaster pps-optimize time-burner
sudo reboot
```

Always reboot after changing anything in the boot path. Ordering problems only show up at boot.

---

## 12. Verification and results

```bash
systemctl --failed                                             # nothing timing-related
chronyc -n sources                                             # '#* PPS' ±<1 µs; NMEA within a few ms; monitors within a few ms
chronyc tracking                                               # Reference ID 50505300 (PPS), Stratum 1, Leap status Normal
sudo pmc -u -b 0 'GET TIME_PROPERTIES_DATA_SET'                # currentUtcOffsetValid 1, ptpTimescale 1, timeSource 0x20
sudo phc_ctl eth0 cmp                                          # offset ≈ -37000000000 ns (PHC is TAI)
sudo journalctl -k -b | grep -c 'apparmor="DENIED"'            # should not grow
ps -eo pid,comm,cls,rtprio,psr | grep chronyd                  # FF 50 on CPU 0
grep pps /proc/interrupts                                      # counts only in the CPU0 column
journalctl -u time-burner -n 3 -o cat                          # mean ≈ 60.0 C
cat /sys/class/hwmon/hwmon*/pwm1                               # 125
sudo ss -ltnp | grep 4460                                      # NTS-KE listening
sudo chronyc serverstats | grep -E 'NTS-KE|Authenticated'
openssl x509 -in /etc/chrony/nts/timepi.crt -noout -enddate    # renew before this date
grep 'File expires' /usr/share/zoneinfo/leap-seconds.list
```

From another machine. This is the check that matters most, because it doesn't rely on anything the box says about itself:

```powershell
w32tm /stripchart /computer:timepi          /samples:5 /dataonly
w32tm /stripchart /computer:time.google.com /samples:5 /dataonly   # should agree within ~1 ms
```

**Example results from my unit:**

| Check | Result |
|---|---|
| chrony | PPS selected, stratum 1, PPS ±83–124 ns, skew 0.005 ppm, system time within ~40 ns of the reference |
| NMEA vs PPS | −1.3 ms (offset 0.106 s at 115200 baud) |
| Internet monitors | median 0.23 ms |
| From a Windows PC: Pi vs time.google.com | agree within ~0.1 ms |
| PTP | PHC = UTC + 37.000000 s (TAI); phc2sys ±70 ns; grandmaster properties valid/traceable/GNSS; no AppArmor denials |
| NTS | NTS-KE on TCP 4460 (IPv4 + IPv6); authenticated sessions via hostname and IP; client without the CA rejected; TLS 1.3 verified from the LAN; wrong hostname rejected |
| Receiver | u-blox LEA-M8T, 115200 baud, 3D fix |
| Temperature | 60.01 °C, σ 0.62 °C; fan PWM 125 (~5500 rpm) |

---

## 13. Pitfalls I hit on the way

1. **A clock's self-report is not a measurement.** Stratum 1, ±150 ns, 12 µs dispersion, and 602 ms wrong, because
   the correction was on the PPS refclock. Three `noselect` Internet servers would have shown it instantly.
2. **UTC vs TAI on PTP.** A grandmaster whose PHC holds UTC, combined with clients that assume TAI, gives a 37 s
   error without a single error message.
3. **Bandwidth is latency.** 520 bytes/s through a 960 bytes/s link gives a latency that depends on how many
   satellites are in view.
4. **Vendor commands and shell quoting.** `PMTK` does nothing on a u-blox, and `"$PMTK251"` in double quotes is an
   empty variable. A baud script that silently never worked was the root of my hand-tuned offset.
5. **Two controllers, one variable.** The Pi 5 fan's 60 °C trip point and a 60 °C oven setpoint fight each other.
6. **A boot-order cycle is silent.** A oneshot unit ordered `Before=gpsd.socket` with default dependencies made
   systemd drop gpsd at boot. The Internet monitors showed the clock 319 ms off within a minute.
7. **AppArmor on Ubuntu.** ptp4l's profile restricts config to `/etc/linuxptp/` and blocks pmc replies. "Permission
   denied" for a root-readable file is the giveaway: check `journalctl -k | grep DENIED`.
8. **IRQ numbers aren't stable.** Look the PPS interrupt up by name.
9. **Correct time is only half the job.** With NTS, clients can verify that the time really comes from this clock.

---

## References

This guide builds on these three articles. Many thanks to Austin for writing them up:

1. Austin, *Microsecond accurate NTP with a Raspberry Pi and PPS GPS*, Austin's Nerdy Things, 19 April 2021.
   <https://austinsnerdythings.com/2021/04/19/microsecond-accurate-ntp-with-a-raspberry-pi-and-pps-gps/>
2. Austin, *Revisiting Microsecond Accurate NTP for Raspberry Pi with GPS PPS in 2025*, Austin's Nerdy Things, 14 February 2025.
   <https://austinsnerdythings.com/2025/02/14/revisiting-microsecond-accurate-ntp-for-raspberry-pi-with-gps-pps-in-2025/>
3. Austin, *Nanosecond accurate PTP server (grandmaster) and client tutorial for Raspberry Pi*, Austin's Nerdy Things, 18 February 2025.
   <https://austinsnerdythings.com/2025/02/18/nanosecond-accurate-ptp-server-grandmaster-and-client-tutorial-for-raspberry-pi/>

Further reading: RFC 8915 (Network Time Security for NTP), the chrony documentation (`chrony.conf(5)`: `refclock`,
`ntsserverkey`, `ntstrustedcerts`), and the linuxptp man pages (`ptp4l(8)`, `phc2sys(8)`, `pmc(8)`).
