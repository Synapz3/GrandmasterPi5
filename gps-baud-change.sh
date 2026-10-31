#!/bin/bash
# gps-baud-change.sh — change the u-blox LEA-M8T serial baud rate safely and
# re-calibrate chrony's NMEA offset to match (Raspberry Pi 5 + u-blox LEA-M8T).
#
# Why the offset matters: chrony numbers each PPS pulse using the NMEA time
# ("lock NMEA"). The receiver sends ~520 bytes of UBX per epoch (gpsd native mode);
# at 9600 baud that is ~0.55 s on the wire and latency ~0.64-0.71 s, varying with
# the number of satellites (NAV-SAT grows 12 bytes/sat). If the chrony NMEA offset doesn't match the real
# latency to well within 0.5 s, PPS pulses get the wrong second -> 1 s error.
#
# Usage (as root):
#   gps-baud-change.sh [BAUD]        change baud (default 115200), recalibrate chrony, verify
#   gps-baud-change.sh --boot        boot-time: put receiver at $GPS_BAUD before gpsd starts
#   gps-baud-change.sh --measure     only measure NMEA latency at the current baud
#
# Safety: gpsd is stopped while changing -> chrony's NMEA samples go stale and
# chrony drops PPS (maxlockage) and holds over on its disciplined frequency.
# After the change the result is checked against the noselect internet
# servers; on any failure the previous baud and chrony.conf are restored.
set -u
DEV=/dev/ttyAMA0
CHRONY_CONF=/etc/chrony/chrony.conf
DEFAULTS=/etc/default/gps-baud
PROTVER=22.00
LOG=/var/log/gps-baud-change.log
BAUDS="9600 38400 115200 19200 57600 230400"

[ -r "$DEFAULTS" ] && . "$DEFAULTS"
GPS_BAUD=${GPS_BAUD:-9600}

log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$LOG" >&2; }
die() { log "ERROR: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

# --- python helpers (stdlib only): detect baud / measure NMEA latency ---------
py() {
python3 -I - "$@" <<'PYEOF'
import os, sys, termios, time, select
mode, dev = sys.argv[1], sys.argv[2]
SPEEDS = {b: getattr(termios, f'B{b}') for b in (9600,19200,38400,57600,115200,230400)}

def open_at(baud):
    fd = os.open(dev, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = 0; a[1] = 0; a[3] = 0                       # raw iflag/oflag/lflag
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[4] = a[5] = SPEEDS[baud]
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIFLUSH)
    return fd

def frames(fd, secs):
    """Yield (arrival_time, kind, payload) for valid UBX frames and NMEA lines.
    The receiver normally speaks binary UBX (gpsd puts it in native mode)."""
    buf, end = b'', time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.02)
        if not r:
            continue
        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            continue
        t = time.time()
        buf += chunk
        while True:
            u, n = buf.find(b'\xb5\x62'), buf.find(b'$')
            if u < 0 and n < 0:
                buf = buf[-1:]
                break
            if u >= 0 and (n < 0 or u < n):          # UBX frame
                buf = buf[u:]
                if len(buf) < 6:
                    break
                ln = buf[4] | buf[5] << 8
                if ln > 2048:
                    buf = buf[2:]; continue
                if len(buf) < 8 + ln:
                    break
                fr, buf = buf[:8 + ln], buf[8 + ln:]
                a = b = 0
                for c in fr[2:6 + ln]:
                    a = (a + c) & 0xff; b = (b + a) & 0xff
                if fr[6 + ln] == a and fr[7 + ln] == b:
                    yield t, (fr[2], fr[3]), fr[6:6 + ln]
            else:                                     # NMEA line
                buf = buf[n:]
                e = buf.find(b'\n')
                if e < 0:
                    if len(buf) > 200: buf = buf[1:]
                    break
                ln, buf = buf[:e].strip(b'\r'), buf[e + 1:]
                if b'*' in ln:
                    body, ck = ln[1:].rsplit(b'*', 1)
                    x = 0
                    for c in body: x ^= c
                    try:
                        if int(ck[:2], 16) == x:
                            yield t, 'NMEA', ln
                    except ValueError:
                        pass

if mode == 'detect':
    for b in map(int, sys.argv[3:]):
        fd = open_at(b)
        ok = sum(1 for _ in frames(fd, 1.6))
        os.close(fd)
        if ok >= 3:
            print(b); sys.exit(0)
    sys.exit(1)

if mode == 'measure':
    # latency = arrival of the epoch's last message (UBX NAV-EOE, which is
    # what makes gpsd report the fix) minus the epoch time (iTOW). Only the
    # fractional second is used, so GPS-UTC leap seconds don't matter.
    baud, secs = int(sys.argv[3]), float(sys.argv[4])
    fd = open_at(baud)
    lat = []
    for t, kind, p in frames(fd, secs):
        if kind == (0x01, 0x61) and len(p) >= 4:      # NAV-EOE
            itow = int.from_bytes(p[0:4], 'little')
            lat.append(((t % 1.0) - (itow % 1000) / 1000.0) % 1.0)
        elif kind == 'NMEA':
            f = p.split(b',')
            if f[0][3:] in (b'ZDA', b'RMC', b'GGA') and len(f[1]) >= 6:
                lat.append(((t % 1.0) - float(f[1][4:]) % 1.0) % 1.0)
    os.close(fd)
    if len(lat) < 5:
        sys.exit(1)
    lat = lat[1:]                                     # first epoch may be partial
    lat.sort()
    print(f'{lat[len(lat)//2]:.4f} {lat[0]:.4f} {lat[-1]:.4f} {len(lat)}')
PYEOF
}

# try the configured baud first, then the others
detect_baud() { py detect "$DEV" $GPS_BAUD $(echo $BAUDS | tr ' ' '\n' | grep -vx "$GPS_BAUD"); }

set_baud() {   # $1 = current, $2 = new
    [ "$1" = "$2" ] && return 0
    log "setting receiver $1 -> $2 baud (CFG-PRT)"
    ubxtool -f "$DEV" -s "$1" -P "$PROTVER" -S "$2" >/dev/null 2>&1 || true
    sleep 2
    local now; now=$(detect_baud) || die "no NMEA after baud change"
    [ "$now" = "$2" ] || die "receiver at $now, expected $2"
    log "saving receiver config (CFG-CFG save: BBR/flash)"
    ubxtool -f "$DEV" -s "$2" -P "$PROTVER" -p SAVE >/dev/null 2>&1 || log "warning: SAVE failed"
}

stop_gpsd()  { systemctl stop gpsd.socket gpsd.service; sleep 1; }
start_gpsd() { systemctl start gpsd.socket gpsd.service; }

chrony_nmea_offset() { sed -nE 's/^refclock SHM 0 refid NMEA offset ([-0-9.]+).*/\1/p' "$CHRONY_CONF"; }
set_chrony_nmea_offset() {
    sed -i -E "s/^(refclock SHM 0 refid NMEA offset )[-0-9.]+/\1$1/" "$CHRONY_CONF"
    [ "$(chrony_nmea_offset)" = "$1" ] || die "could not update NMEA offset in $CHRONY_CONF"
}

wait_pps_lock() {  # up to $1 s for PPS to be the selected source with small offset
    local i
    for i in $(seq "$1"); do
        chronyc -n sources 2>/dev/null | grep -qE '^#\* PPS' && return 0
        sleep 1
    done
    return 1
}

monitor_check() {  # median |offset| of reachable noselect NTP servers must be < 20 ms
    chronyc -c -n sources 2>/dev/null | awk -F, '$1=="^" && $6!="0" {o=$8; if(o<0)o=-o; print o}' |
      sort -g | awk '{a[NR]=$1} END{ if(NR==0){print "none"; exit 2} m=a[int((NR+1)/2)]; print m; exit (m<0.020?0:1)}'
}

# ------------------------------------------------------------------------------
case "${1:-}" in
--boot)
    # never probe the port underneath a running gpsd (it would lose sync)
    if systemctl -q is-active gpsd.service; then
        log "boot: gpsd already running, skipping (use '$0 $GPS_BAUD' to change baud)"
        exit 0
    fi
    cur=$(detect_baud) || { log "boot: no NMEA detected on $DEV"; exit 0; }
    [ "$cur" = "$GPS_BAUD" ] && { log "boot: receiver already at $cur"; exit 0; }
    set_baud "$cur" "$GPS_BAUD"
    exit 0 ;;
--measure)
    stop_gpsd
    cur=$(detect_baud) || { start_gpsd; die "no NMEA detected"; }
    r=$(py measure "$DEV" "$cur" 12) || { start_gpsd; die "latency measurement failed"; }
    start_gpsd
    echo "baud=$cur latency median/min/max/n: $r"
    exit 0 ;;
esac

NEW=${1:-115200}
case " $BAUDS " in *" $NEW "*) ;; *) die "unsupported baud $NEW";; esac

TS=$(date +%Y%m%d-%H%M%S)
cp -a "$CHRONY_CONF" "$CHRONY_CONF.pre-baud-$TS"
OLD_OFFSET=$(chrony_nmea_offset)
[ -n "$OLD_OFFSET" ] || die "NMEA refclock line not found in $CHRONY_CONF"

log "stopping gpsd (chrony holds over; PPS unused while NMEA is stale)"
stop_gpsd
OLD=$(detect_baud) || { start_gpsd; die "no NMEA detected on $DEV"; }
log "receiver at $OLD baud, chrony NMEA offset $OLD_OFFSET"

rollback() {
    log "ROLLBACK: $*"
    stop_gpsd
    cur=$(detect_baud) && { ( set_baud "$cur" "$OLD" ) || log "could not restore $OLD baud"; }
    cp -a "$CHRONY_CONF.pre-baud-$TS" "$CHRONY_CONF"
    echo "GPS_BAUD=$OLD" > "$DEFAULTS"
    systemctl restart chrony; start_gpsd
    exit 1
}

( set_baud "$OLD" "$NEW" ) || rollback "baud change failed"

r=$(py measure "$DEV" "$NEW" 12) || rollback "latency measurement failed"
read -r LAT LMIN LMAX N <<<"$r"
log "NMEA latency at $NEW baud: median $LAT s (min $LMIN, max $LMAX, n=$N)"
awk -v l="$LAT" -v a="$LMIN" -v b="$LMAX" 'BEGIN{exit !(l>0 && l<0.45 && b-a<0.1)}' ||
    rollback "implausible latency $LAT ($LMIN..$LMAX)"

OFF=$(printf '%.3f' "$LAT")
set_chrony_nmea_offset "$OFF"
echo "GPS_BAUD=$NEW" > "$DEFAULTS"
log "chrony NMEA offset $OLD_OFFSET -> $OFF; restarting chrony, starting gpsd"
systemctl restart chrony
start_gpsd
wait_pps_lock 90 || rollback "PPS did not lock within 90 s"

# refine against PPS-disciplined clock: chronyc +x means NMEA is x s behind
sleep 30
RES=$(chronyc -c -n sourcestats | awk -F, '$1=="NMEA"{print $7}')
log "NMEA residual vs PPS: ${RES:-n/a} s"
if [ -n "$RES" ] && awk -v r="$RES" 'BEGIN{exit !(r>0.01 || r<-0.01)}'; then
    OFF2=$(awk -v o="$OFF" -v r="$RES" 'BEGIN{printf "%.3f", o+r}')
    log "refining NMEA offset $OFF -> $OFF2"
    set_chrony_nmea_offset "$OFF2"
    systemctl restart chrony
    wait_pps_lock 90 || rollback "PPS did not re-lock after refinement"
fi

log "waiting for internet monitor servers"
for i in $(seq 12); do
    m=$(monitor_check); rc=$?
    [ $rc -eq 0 ] && break
    [ $rc -eq 1 ] && rollback "system clock disagrees with internet monitors (median |offset| $m s)"
    sleep 5
done
[ "${rc:-2}" -eq 0 ] || log "warning: no internet monitors reachable, could not cross-check"
log "done: receiver at $NEW baud, chrony NMEA offset $(chrony_nmea_offset), monitors median |offset| ${m:-n/a} s"
chronyc -n sources
