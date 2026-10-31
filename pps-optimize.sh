#!/bin/bash
# PPS NTP server performance optimization
# Performance governor, PPS IRQ -> CPU0, chronyd SCHED_FIFO 50 on CPU0, ksoftirqd/0 boosted.
# The PPS IRQ is looked up by name: its number changes between kernels/boots
# (e.g. 173 on kernel 7.0; other kernels/boots differ).
set -e
sleep 5

echo "Setting CPU governor to performance..."
cpupower frequency-set -g performance >/dev/null

irq=$(awk -F: '/pps@/ {gsub(/ /,"",$1); print $1; exit}' /proc/interrupts)
if [ -n "$irq" ]; then
    echo 1 > /proc/irq/$irq/smp_affinity
    echo "PPS IRQ $irq pinned to CPU0"
else
    echo "Warning: PPS IRQ not found in /proc/interrupts"
fi

pids=""
for i in $(seq 30); do
    pids=$(pgrep chronyd || true)
    [ -n "$pids" ] && break
    sleep 1
done
if [ -z "$pids" ]; then
    echo "Warning: chronyd not found after 30 seconds"
else
    for p in $pids; do
        chrt -f -p 50 "$p"
        taskset -cp 0 "$p" >/dev/null
    done
fi

k=$(pgrep -x 'ksoftirqd/0' || true)
[ -n "$k" ] && renice -n -10 "$k" >/dev/null

echo "=== Current Status ==="
echo "CPU Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
[ -n "$irq" ] && echo "PPS IRQ $irq effective affinity: $(cat /proc/irq/$irq/effective_affinity_list 2>/dev/null)"
for p in $pids; do echo "chronyd $p: $(chrt -p $p | tr '\n' ' ') cpus=$(taskset -pc $p | cut -d: -f2)"; done
