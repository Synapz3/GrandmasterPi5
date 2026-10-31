#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Marcus Lund. See LICENSE.
"""CPU thermal stabiliser for a Raspberry Pi GNSS/PPS NTP + PTP time server.

Goal: keep the board (and the Pi's 54 MHz crystal next to the SoC) at a constant
temperature so the system-clock frequency is as stable as possible, without
ever overheating.

Design (v2, 2026-10-31):
  * Workers produce heat as finely-grained PWM (default 50 ms period) with their
    phases staggered, so total power is close to a smooth DC level instead of
    synchronized 200 ms bursts -> much less die-temperature ripple.
  * Workers run SCHED_IDLE on CPUs 1-3 only: chrony/PPS IRQ own CPU0 and any
    real work (ptp4l, phc2sys, gpsd) always preempts the heater.
  * PI controller on a 1 s interval using the average of ~10 sensor reads
    (the sensor has 0.55 C steps), clamped integral (real anti-windup),
    bumpless start from --initial-duty to avoid overshoot after boot.
  * time.monotonic() everywhere -> unaffected by chrony clock steps.
  * Safety: duty forced to 0 above --max-temp, or if the sensor can't be read;
    the kernel fan curve (config.txt) still ramps the fan above 70 C.
  * One flushed summary line per --log-interval seconds (default 300).
"""
import argparse
import hashlib
import multiprocessing as mp
import os
import signal
import sys
import time

TEMP_PATH = '/sys/class/thermal/thermal_zone0/temp'


def read_temp():
    with open(TEMP_PATH) as f:
        return int(f.read()) / 1000.0


class PI:
    def __init__(self, kp, ki, setpoint, initial_duty):
        self.kp, self.ki, self.setpoint = kp, ki, setpoint
        self.i_max = 1.0 / ki
        self.integral = min(max(initial_duty / ki, 0.0), self.i_max)

    def update(self, temp, dt):
        error = self.setpoint - temp
        p = self.kp * error
        # conditional integration: don't integrate further into saturation
        new_i = min(max(self.integral + error * dt, 0.0), self.i_max)
        out = p + self.ki * new_i
        if 0.0 <= out <= 1.0 or (out > 1.0 and error < 0) or (out < 0.0 and error > 0):
            self.integral = new_i
        return min(max(p + self.ki * self.integral, 0.0), 1.0)


def worker(cpu, phase, duty, period):
    os.sched_setaffinity(0, {cpu})
    try:
        os.sched_setscheduler(0, os.SCHED_IDLE, os.sched_param(0))
    except (AttributeError, PermissionError, OSError):
        os.nice(19)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    h = hashlib.md5()
    t = time.monotonic() + phase * period
    while True:
        now = time.monotonic()
        if t > now:
            time.sleep(t - now)
        burn_until = t + duty.value * period
        while time.monotonic() < burn_until:
            h.update(b'burning-cpu')
        t += period
        if time.monotonic() > t + period:  # fell behind (e.g. preempted) -> resync
            t = time.monotonic()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('-t', '--target', type=float, default=60.0, help='setpoint, degC (default 60)')
    ap.add_argument('-m', '--max-temp', type=float, default=70.0, help='heater off above this, degC')
    ap.add_argument('-n', '--workers', type=int, default=3)
    ap.add_argument('-c', '--cpus', default='1,2,3', help='CPUs for heater workers (keep CPU0 free)')
    ap.add_argument('-p', '--period', type=float, default=0.05, help='heater PWM period, s')
    ap.add_argument('-u', '--update', type=float, default=1.0, help='control interval, s')
    ap.add_argument('--kp', type=float, default=0.05, help='duty per degC')
    ap.add_argument('--ki', type=float, default=0.02, help='duty per degC*s')
    ap.add_argument('--initial-duty', type=float, default=0.25)
    ap.add_argument('-i', '--log-interval', type=float, default=300.0)
    a = ap.parse_args()

    cpus = [int(c) for c in a.cpus.split(',')]
    os.sched_setaffinity(0, set(cpus))  # keep the controller off CPU0 too
    duty = mp.Value('d', 0.0, lock=False)
    procs = [mp.Process(target=worker, daemon=True,
                        args=(cpus[i % len(cpus)], i / a.workers, duty, a.period))
             for i in range(a.workers)]
    for p in procs:
        p.start()

    def stop(*_):
        duty.value = 0.0
        for p in procs:
            p.terminate()
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    pi = PI(a.kp, a.ki, a.target, a.initial_duty)
    print(f'time_burner v2: target={a.target}C max={a.max_temp}C workers={a.workers} '
          f'cpus={cpus} period={a.period}s update={a.update}s kp={a.kp} ki={a.ki}', flush=True)

    last = time.monotonic()
    stats = None
    while True:
        samples, end = [], last + a.update
        while time.monotonic() < end:
            try:
                samples.append(read_temp())
            except (OSError, ValueError):
                pass
            time.sleep(a.update / 10)
        now = time.monotonic()
        dt, last = now - last, now

        if not samples:
            duty.value = 0.0
            print('sensor read failed -> heater off', flush=True)
            continue
        temp = sum(samples) / len(samples)
        if temp >= a.max_temp:
            duty.value = 0.0
            print(f'OVERTEMP {temp:.2f}C >= {a.max_temp}C -> heater off', flush=True)
        else:
            duty.value = pi.update(temp, dt)

        if stats is None:
            stats = [now, 0, 0.0, 0.0, 1e9, -1e9, 0.0]
        stats[1] += 1; stats[2] += temp; stats[3] += temp * temp
        stats[4] = min(stats[4], temp); stats[5] = max(stats[5], temp); stats[6] += duty.value
        if now - stats[0] >= a.log_interval:
            n = stats[1]; mean = stats[2] / n
            sd = max(stats[3] / n - mean * mean, 0.0) ** 0.5
            print(f'temp mean={mean:.2f}C sd={sd:.2f} min={stats[4]:.2f} max={stats[5]:.2f} '
                  f'duty={stats[6]/n:.3f}', flush=True)
            stats = None

        if not all(p.is_alive() for p in procs):
            duty.value = 0.0
            sys.exit('worker died')


if __name__ == '__main__':
    main()
