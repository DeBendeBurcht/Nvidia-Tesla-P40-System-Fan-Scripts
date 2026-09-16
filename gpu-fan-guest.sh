#!/bin/bash
# ============================================================
# gpu-fan-guest.sh
# Debian 12 Guest: Tesla P40 monitor -> PWM over serial0
#
# Matches host gpu-fan-controller.sh
#
# 1. Host side link requirements:
#      The VM (ID 126) must have a serial socket attached:
#      Run on Proxmox host: qm set 126 --serial0 socket
#
# 2. Guest side interface:
#      Serial0 maps natively to /dev/ttyS0 inside this Debian VM.
#      Note: Never attach `qm terminal` on host as it intercepts communication.
#
# 3. Prerequisites:
#      sudo apt update && sudo apt install -y nvidia-smi
#
# 4. Installation & permissions:
#      sudo nano /usr/local/bin/gpu-fan-guest.sh
#      sudo chmod +x /usr/local/bin/gpu-fan-guest.sh
#
# 5. Service configuration: /etc/systemd/system/gpu-fan-guest.service
#      [Unit]
#      Description=Tesla P40 Guest Fan Reporter
#      After=network.target
#
#      [Service]
#      Type=simple
#      ExecStart=/usr/local/bin/gpu-fan-guest.sh
#      Restart=always
#      RestartSec=2s
#
#      [Install]
#      WantedBy=multi-user.target
#
# 6. Service Management:
#      sudo systemctl daemon-reload
#      sudo systemctl enable --now gpu-fan-guest.service
# ============================================================
set -u

# --- Hardware / IPC ---
GPU_INDEX=0
SERIAL="/dev/ttyS0"
INTERVAL_SEC=2                    # Heartbeat interval (host timeout is 8s)

# --- PWM Boundaries ---
PWM_MIN=40                        # Host clamps here to protect fan bearing
PWM_MAX=254                       # Maximum normal speed
PWM_EMERGENCY=255                 # 255 triggers a hypervisor emergency stop
PWM_QUERY_FAIL=180                # Safe fallback if nvidia-smi fails
LAST_PWM=90                       # Initial startup value for smoothing

# --- Fan Curve (Die Temperature °C -> Base PWM) ---
# Tuned to ramp up blower early enough before copper shroud gets soaked
GPU_T=(40 50 55 60 65 70 75 80 84 87)
GPU_P=(40 44 55 78 110 145 180 215 240 254)

# --- Predictive Control & Smoothing ---
RISE_GAIN=12                      # Extra PWM boost per °C increase per sample
UTIL_LEAD=15                      # Proactive spin-up on sudden SM utilization
POWER_LEAD_W=130                  # Trigger extra cooling once power crosses this wattage
DOWN_STEP=6                       # Prevents annoying rapid deceleration pulses
UP_STEP=45                        # Max PWM rise per loop to prevent stepping noise

# --- Critical Safety ---
CRIT_GPU_C=87                     # Emergency threshold for sustained overheat
CRIT_HOLD_SEC=10                  # Hold duration before sending emergency 255
CRIT_SINCE=0
LAST_GPU_T=-1

log() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"
}

# Piecewise-linear interpolation for smooth fan speed transitions
lerp_curve() {
    local t=$1; local -n _xt=$2; local -n _xp=$3
    local i; local n=${#_xt[@]}
    if (( t <= _xt )); then echo "${_xp}"; return; fi
    if (( t >= _xt[n-1] )); then echo "${_xp[n-1]}"; return; fi
    for (( i=1; i<n; i++ )); do
        if (( t <= _xt[i] )); then
            local t0=${_xt[i-1]}; local t1=${_xt[i]}
            local p0=${_xp[i-1]}; local p1=${_xp[i]}
            echo $(( p0 + (t - t0) * (p1 - p0) / (t1 - t0) ))
            return
        fi
    done
}

log "Starting Tesla P40 Guest Fan Controller..."

# Guard: Ensure the serial device link exists
if [[ ! -c "$SERIAL" ]]; then
    log "ERROR: Serial device $SERIAL not found in VM!"
    exit 1
fi

while true; do
    # Query nvidia-smi (safely handles missing memory sensors on 535 drivers)
    CSV=$(nvidia-smi -i "$GPU_INDEX" --query-gpu=temperature.gpu,utilization.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
    
    if [[ -z "$CSV" ]]; then
        log "WARNING: nvidia-smi query failed, passing safe fallback..."
        echo "$PWM_QUERY_FAIL" > "$SERIAL"
        sleep "$INTERVAL_SEC"
        continue
    fi

    IFS=',' read -r GPU_TEMP UTIL_PCT POWER_W <<< "$CSV"
    GPU_TEMP=${GPU_TEMP%%.*}
    UTIL_PCT=${UTIL_PCT%%.*}
    POWER_W=${POWER_W%%.*}

    # 1. Evaluate baseline PWM from curve lookup
    TARGET_PWM=$(lerp_curve "$GPU_TEMP" GPU_T GPU_P)

    # 2. Predictive Thermal Rise Delta (Leads the blower if temperature climbs fast)
    if (( LAST_GPU_T != -1 )); then
        DIFF_T=$(( GPU_TEMP - LAST_GPU_T ))
        if (( DIFF_T > 0 )); then
            TARGET_PWM=$(( TARGET_PWM + (DIFF_T * RISE_GAIN) ))
        fi
    fi

    # 3. Direct Core Utilization Injection
    if (( UTIL_PCT > 40 && GPU_TEMP < 65 )); then
        TARGET_PWM=$(( TARGET_PWM + UTIL_LEAD ))
    fi

    # 4. Power Draw Lead Overrides
    if (( POWER_W > POWER_LEAD_W )); then
        TARGET_PWM=$(( TARGET_PWM + 15 ))
    fi

    # Enforce safe protocol bounds (0 - 254)
    if (( TARGET_PWM < PWM_MIN )); then TARGET_PWM=$PWM_MIN; fi
    if (( TARGET_PWM > PWM_MAX )); then TARGET_PWM=$PWM_MAX; fi

    # 5. Apply Hysteresis Smoothing Rate-Limits
    if (( TARGET_PWM > LAST_PWM + UP_STEP )); then
        TARGET_PWM=$(( LAST_PWM + UP_STEP ))
    elif (( TARGET_PWM < LAST_PWM - DOWN_STEP )); then
        TARGET_PWM=$(( LAST_PWM - DOWN_STEP ))
    fi

    # 6. Critical Hardware Failsafe Tracking
    if (( GPU_TEMP >= CRIT_GPU_C )); then
        if (( CRIT_SINCE == 0 )); then
            read up _ < /proc/uptime; CRIT_SINCE=${up%%.*}
        else
            read up _ < /proc/uptime; NOW=${up%%.*}
            if (( NOW - CRIT_SINCE >= CRIT_HOLD_SEC )); then
                log "CRITICAL OVERHEAT DETECTED: GPU at ${GPU_TEMP}°C! Sending host shutdown instruction..."
                TARGET_PWM=$PWM_EMERGENCY
            fi
        fi
    else
        CRIT_SINCE=0
    fi

    # Ship payload data across serial line to Proxmox hardware layer
    if ! echo "$TARGET_PWM" > "$SERIAL"; then
        log "WARNING: Transmission block on channel $SERIAL"
    else
        log "GPU: ${GPU_TEMP}°C | Core Util: ${UTIL_PCT}% | Power Draw: ${POWER_W}W | Outbound PWM: $TARGET_PWM"
    fi

    LAST_PWM=$TARGET_PWM
    LAST_GPU_T=$GPU_TEMP
    sleep "$INTERVAL_SEC"
done
