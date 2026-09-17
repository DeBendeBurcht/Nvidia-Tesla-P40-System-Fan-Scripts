#!/bin/bash
# ============================================================
# gpu-fan-controller.sh
# Host-side SYS_FAN controller for a passthrough GPU VM on Proxmox VE
#
# Guest protocol (VM 126, serial0):
#   One ASCII integer 0-255 per line on /dev/ttyS0, e.g.:
#     echo 180 > /dev/ttyS0
#   Heartbeat at least once every TIMEOUT_SEC seconds.
#   255 held for EMERGENCY_HOLD_SEC = cooling failed (hypervisor stop).
#   Use 254 as the normal maximum if the guest maps a full fan curve.
#   Do not attach `qm terminal` to serial0 — QEMU allows one socket client.
#
# 1. Host packages:
#      apt update && apt install -y pve-headers-$(uname -r) build-essential git dkms lm-sensors netcat-openbsd
#
# 2. Frank Crawford it87 DKMS:
#      cd /usr/src && git clone https://github.com/frankcrawford/it87.git
#      cd it87 && ./dkms-install.sh
#
# 3. Persist the Gigabyte ACPI workaround (BOTH files):
#      echo it87 > /etc/modules-load.d/it87.conf
#      echo 'options it87 ignore_resource_conflict=1' > /etc/modprobe.d/it87.conf
#
# 4. Isolated Netcat Dependency:
#      Ensure NC_BIN="/bin/nc.openbsd" is set inside the script variables 
#      to avoid global update-alternatives conflicts with other system scripts.
# 5. Install:
#      install -m 755 gpu-fan-controller.sh /usr/local/bin/gpu-fan-controller.sh
#
# 6. /etc/systemd/system/gpu-fan-controller.service
#      [Unit]
#      Description=Proxmox Host SYS_FAN GPU Controller
#      After=pve-cluster.service qemu-server.service systemd-modules-load.service
#
#      [Service]
#      Type=simple
#      ExecStart=/usr/local/bin/gpu-fan-controller.sh
#      Restart=always
#      RestartSec=2s
#      TimeoutStopSec=8
#      StartLimitIntervalSec=60
#      StartLimitBurst=8
#
#      [Install]
#      WantedBy=multi-user.target
#
# 7. systemctl daemon-reload && systemctl enable --now gpu-fan-controller.service
# ============================================================

# Do not use `set -e`: a failed sysfs write or nc exit must not kill the daemon.
set -u

# --- Hardware ---
FAN_HEADER=2
CHIP_NAME="it8689"                 # preferred sysfs hwmon name; it87-family accepted as fallback

# --- VM & IPC ---
VM_ID=126
SOCKET="/var/run/qemu-server/${VM_ID}.serial0"
VM_PIDFILE="/var/run/qemu-server/${VM_ID}.pid"

# --- Safety & timing ---
TIMEOUT_SEC=8
MIN_INTERVAL=1
SLEEP_OFFLINE=5
BIOS_FALLBACK_TIMEOUT=300
EMERGENCY_HOLD_SEC=30

# --- PWM (0-255) ---
PWM_MIN=40
PWM_IDLE=40
PWM_SAFE_FALLBACK=180
HYSTERESIS_THRESHOLD=5
HEAT_SOAK_THRESHOLD=150
HEAT_SOAK_DURATION=25

# --- State ---
STATE_FILE="/dev/shm/sysfan-state"
LOCK_FILE="/var/run/gpu-fan-controller.lock"
MAX_WAIT=10

if [[ ! -d "$(dirname "$STATE_FILE")" ]]; then
    STATE_FILE="/tmp/sysfan-state"
fi

if (( PWM_IDLE < PWM_MIN )); then PWM_IDLE=$PWM_MIN; fi
if (( PWM_SAFE_FALLBACK < PWM_MIN )); then PWM_SAFE_FALLBACK=$PWM_MIN; fi
if (( PWM_SAFE_FALLBACK > 255 )); then PWM_SAFE_FALLBACK=255; fi

# -------------------- Internals --------------------
HWMON_PATH=""
PWM_ENABLE=""
PWM_VALUE=""
FAN_INPUT=""
LAST_WRITTEN_PWM=0
LAST_WRITE_TS=0
HEAT_SOAK_ACTIVE=0
HEAT_SOAK_START_TS=0
HEAT_SOAK_PEAK_PWM=0
OFFLINE_SINCE=0
CRIT_SINCE=0
PENDING_PWM=-1                     # latest target waiting on MIN_INTERVAL; -1 = none
LAST_GUEST_PWM=$PWM_IDLE           # last valid PWM from the guest (for heat-soak expiry)
MODE="INIT"
CURRENT_RPM=0
WRITE_FAILS=0
CLEANED=0
MONO=0
NC_BIN="/bin/nc.openbsd"

log() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

# Monotonic seconds (boot uptime). Immune to NTP / RTC jumps.
read_mono() {
    local up=0
    read -r up _ < /proc/uptime || up=0
    MONO=${up%%.*}
    [[ "$MONO" =~ ^[0-9]+$ ]] || MONO=0
}

vm_running() {
    local pid=""
    [[ -S "$SOCKET" && -f "$VM_PIDFILE" ]] || return 1
    read -r pid < "$VM_PIDFILE" 2>/dev/null || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

read_rpm() {
    CURRENT_RPM=0
    if [[ -n "$FAN_INPUT" && -f "$FAN_INPUT" ]]; then
        read -r CURRENT_RPM < "$FAN_INPUT" 2>/dev/null || CURRENT_RPM=0
    fi
    [[ "$CURRENT_RPM" =~ ^[0-9]+$ ]] || CURRENT_RPM=0
}

persist_state() {
    local wall
    printf -v wall '%(%s)T' -1
    printf '%d %d %d %s\n' "$wall" "$LAST_WRITTEN_PWM" "$CURRENT_RPM" "$MODE" > "${STATE_FILE}.tmp" 2>/dev/null \
        && mv -f "${STATE_FILE}.tmp" "$STATE_FILE" 2>/dev/null || true
}

find_hwmon() {
    local d chip exact="" fallback="" use="" want
    HWMON_PATH=""
    want="${CHIP_NAME,,}"
    want="${want//[[:space:]]/}"
    for d in /sys/class/hwmon/hwmon*; do
        [[ -d "$d" && -f "$d/name" && -f "$d/pwm${FAN_HEADER}" && -f "$d/fan${FAN_HEADER}_input" ]] || continue
        read -r chip < "$d/name" 2>/dev/null || continue
        chip="${chip//[[:space:]]/}"
        chip="${chip,,}"
        case "$chip" in
            "$want"|it8689*|it8689e*)
                exact=$d
                break
                ;;
            it87|it8688|it8728)
                # Frank Crawford DKMS sometimes exposes the generic or sibling name.
                fallback=$d
                ;;
        esac
    done
    use="${exact:-$fallback}"
    [[ -n "$use" ]] || return 1
    HWMON_PATH="$use"
    PWM_ENABLE="$use/pwm${FAN_HEADER}_enable"
    PWM_VALUE="$use/pwm${FAN_HEADER}"
    FAN_INPUT="$use/fan${FAN_HEADER}_input"
    return 0
}

recover_hardware() {
    if find_hwmon && [[ -f "$PWM_ENABLE" && -f "$PWM_VALUE" ]]; then
        printf '1\n' > "$PWM_ENABLE" 2>/dev/null || true
        log "hwmon refreshed at $HWMON_PATH"
        return 0
    fi
    return 1
}

# force=1 skips hysteresis AND the 1s write floor (takeover / fallback / emergency).
# Rate-limit never drops a newer target: it is latched in PENDING_PWM and flushed on the 1s tick.
write_pwm() {
    local target="${1:-}"
    local force="${2:-0}"
    local diff=0

    [[ "$target" =~ ^[0-9]+$ ]] || return 1
    target=$((10#$target))
    if (( target < PWM_MIN )); then target=$PWM_MIN; fi
    if (( target > 255 )); then target=255; fi

    read_mono

    if (( force == 0 )); then
        if (( MONO - LAST_WRITE_TS < MIN_INTERVAL )); then
            PENDING_PWM=$target
            return 1
        fi

        diff=$(( target > LAST_WRITTEN_PWM ? target - LAST_WRITTEN_PWM : LAST_WRITTEN_PWM - target ))
        if (( target >= LAST_WRITTEN_PWM + 15 )); then
            :
        elif (( target > LAST_WRITTEN_PWM && target >= HEAT_SOAK_THRESHOLD )); then
            :
        elif (( diff < HYSTERESIS_THRESHOLD )); then
            if (( diff == 0 || MONO - LAST_WRITE_TS < 10 )); then
                PENDING_PWM=-1
                return 1
            fi
        fi
    fi

    if [[ -z "$PWM_VALUE" || ! -f "$PWM_VALUE" ]] || ! printf '%s\n' "$target" > "$PWM_VALUE" 2>/dev/null; then
        log "WARNING: Sysfs write failed to ${PWM_VALUE:-unset}"
        WRITE_FAILS=$((WRITE_FAILS + 1))
        if (( WRITE_FAILS >= 3 )); then
            log "WARNING: rediscovering IT8689 hwmon"
            recover_hardware || true
            WRITE_FAILS=0
        fi
        return 1
    fi

    WRITE_FAILS=0
    PENDING_PWM=-1
    LAST_WRITTEN_PWM=$target
    LAST_WRITE_TS=$MONO
    read_rpm
    persist_state
    log "PWM $target | ${CURRENT_RPM} RPM | $MODE"
    return 0
}

flush_pending() {
    if (( PENDING_PWM >= 0 )); then
        write_pwm "$PENDING_PWM" || true
    fi
}

# Heat-soak must be able to expire even if the guest is silent until nc -w fires.
expire_heat_soak() {
    if (( HEAT_SOAK_ACTIVE != 1 )); then
        return 0
    fi
    read_mono
    if (( MONO - HEAT_SOAK_START_TS >= HEAT_SOAK_DURATION )); then
        HEAT_SOAK_ACTIVE=0
        MODE="ACTIVE"
        log "Heat-soak done -> guest PWM $LAST_GUEST_PWM"
        write_pwm "$LAST_GUEST_PWM" || true
    fi
}

verify_manual_control() {
    local current_mode=""
    [[ "$MODE" == "BIOS_FALLBACK" ]] && return 0
    [[ -n "$PWM_ENABLE" && -f "$PWM_ENABLE" ]] || return 0
    read -r current_mode < "$PWM_ENABLE" 2>/dev/null || current_mode="0"
    if [[ "$current_mode" != "1" ]]; then
        log "WARNING: Manual PWM mode dropped ($current_mode) — re-asserting"
        printf '1\n' > "$PWM_ENABLE" 2>/dev/null || true
    fi
}

cleanup() {
    [[ "$CLEANED" == 1 ]] && return 0
    CLEANED=1
    log "Shutting down daemon"
    if [[ -n "${PWM_ENABLE:-}" && -f "$PWM_ENABLE" ]]; then
        if vm_running && [[ -n "${PWM_VALUE:-}" && -f "$PWM_VALUE" ]]; then
            # VM still up: hold safe speed in manual so a systemd restart
            # does not dip into the BIOS curve under a live P40.
            printf '1\n' > "$PWM_ENABLE" 2>/dev/null || true
            printf '%s\n' "$PWM_SAFE_FALLBACK" > "$PWM_VALUE" 2>/dev/null || true
            log "VM still running — held PWM $PWM_SAFE_FALLBACK"
        else
            printf '2\n' > "$PWM_ENABLE" 2>/dev/null || true
            log "SYS_FAN returned to BIOS"
        fi
    fi
    rm -f "$STATE_FILE" "${STATE_FILE}.tmp" 2>/dev/null || true
    flock -u 200 2>/dev/null || true
}

# -------------------- CLI status --------------------
if [[ "${1:-}" == "--status" || "${1:-}" == "-s" ]]; then
    if [[ -f "$STATE_FILE" ]]; then
        read -r ts pwm rpm mode < "$STATE_FILE" 2>/dev/null || true
        printf "=== GPU Fan Controller Status ===\n"
        printf "  Last Update : %s\n" "$(date -d "@${ts:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'Unknown')"
        printf "  Current Mode: %s\n" "${mode:-Unknown}"
        printf "  Current PWM : %s / 255\n" "${pwm:-0}"
        printf "  Fan Speed   : %s RPM\n" "${rpm:-0}"
        if vm_running; then
            printf "  VM %s        : Running (%s)\n" "$VM_ID" "$SOCKET"
        elif [[ -S "$SOCKET" ]]; then
            printf "  VM %s        : Stale socket (QEMU not running)\n" "$VM_ID"
        else
            printf "  VM %s        : Offline\n" "$VM_ID"
        fi
    else
        echo "No active state file found at $STATE_FILE (Daemon not running)."
    fi
    exit 0
fi

# -------------------- Lock --------------------
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    printf '[%(%Y-%m-%d %H:%M:%S)T] ERROR: Another instance is already running.\n' -1 >&2
    exit 1
fi

trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 131' QUIT

# -------------------- Phase 1: hardware --------------------
bootstrap_hardware() {
    local elapsed=0 chip irc=""

    log "=== SYS_FAN init (header $FAN_HEADER) ==="

    if ! grep -q '^it87 ' /proc/modules 2>/dev/null; then
        log "Loading it87 (ignore_resource_conflict=1)"
        modprobe it87 ignore_resource_conflict=1 2>/dev/null || true
        sleep 0.5
    elif [[ -f /sys/module/it87/parameters/ignore_resource_conflict ]]; then
        read -r irc < /sys/module/it87/parameters/ignore_resource_conflict 2>/dev/null || irc=""
        if [[ "$irc" != "Y" && "$irc" != "1" ]]; then
            log "WARNING: it87 loaded without ignore_resource_conflict=1 (see /etc/modprobe.d/it87.conf)"
        fi
    fi

    while (( elapsed < MAX_WAIT )); do
        find_hwmon && break
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [[ -z "$HWMON_PATH" ]]; then
        log "hwmon devices present:"
        for d in /sys/class/hwmon/hwmon*; do
            [[ -f "$d/name" ]] || continue
            read -r chip < "$d/name" 2>/dev/null || chip="?"
            log "  $d  name=$chip"
        done
        die "IT8689E / pwm${FAN_HEADER} not found after ${MAX_WAIT}s"
    fi

    log "Hardware at $HWMON_PATH"
    [[ -f "$PWM_ENABLE" ]] || die "Missing $PWM_ENABLE"
    printf '1\n' > "$PWM_ENABLE" || die "Cannot enable manual PWM"
    log "Manual control on (pwm${FAN_HEADER}_enable=1)"
}

# Handle one validated guest PWM. Always returns 0 (never abort the stream).
apply_guest_pwm() {
    local guest_pwm=$1
    local target_pwm

    LAST_GUEST_PWM=$guest_pwm
    read_mono

    if (( guest_pwm >= 255 )); then
        if (( CRIT_SINCE == 0 )); then
            CRIT_SINCE=$MONO
        fi
        if (( MONO - CRIT_SINCE >= EMERGENCY_HOLD_SEC )); then
            log "CRITICAL: guest PWM 255 for ${EMERGENCY_HOLD_SEC}s — stopping VM $VM_ID"
            MODE="EMERGENCY"
            write_pwm 255 1 || true
            if command -v qm >/dev/null 2>&1; then
                qm stop "$VM_ID" --skiplock || true
            else
                log "WARNING: qm not found, cannot stop VM"
            fi
            CRIT_SINCE=0
            return 0
        fi
    else
        CRIT_SINCE=0
    fi

    if (( HEAT_SOAK_ACTIVE == 0 && LAST_WRITTEN_PWM >= HEAT_SOAK_THRESHOLD && guest_pwm < HEAT_SOAK_THRESHOLD )); then
        HEAT_SOAK_ACTIVE=1
        HEAT_SOAK_START_TS=$MONO
        HEAT_SOAK_PEAK_PWM=$LAST_WRITTEN_PWM
        log "Heat-soak: holding $HEAT_SOAK_PEAK_PWM for ${HEAT_SOAK_DURATION}s"
    elif (( guest_pwm >= HEAT_SOAK_THRESHOLD )); then
        HEAT_SOAK_ACTIVE=0
    fi

    if (( HEAT_SOAK_ACTIVE == 1 )); then
        if (( MONO - HEAT_SOAK_START_TS < HEAT_SOAK_DURATION )); then
            target_pwm=$HEAT_SOAK_PEAK_PWM
            MODE="HEAT_SOAK"
        else
            HEAT_SOAK_ACTIVE=0
            target_pwm=$guest_pwm
            MODE="ACTIVE"
            log "Heat-soak done -> guest PWM $guest_pwm"
        fi
    else
        target_pwm=$guest_pwm
        MODE="ACTIVE"
    fi

    if ! write_pwm "$target_pwm"; then
        persist_state
    fi
}

handle_offline() {
    local target_pwm

    read_mono
    CRIT_SINCE=0
    PENDING_PWM=-1

    if [[ "$MODE" == "BIOS_FALLBACK" ]]; then
        return 0
    fi

    if [[ "$MODE" != "OFFLINE" && "$MODE" != "HEAT_SOAK" ]]; then
        log "VM $VM_ID offline"
        MODE="OFFLINE"
        OFFLINE_SINCE=$MONO
    fi
    if (( OFFLINE_SINCE == 0 )); then
        OFFLINE_SINCE=$MONO
    fi

    if (( HEAT_SOAK_ACTIVE == 1 || LAST_WRITTEN_PWM >= HEAT_SOAK_THRESHOLD )); then
        if (( HEAT_SOAK_ACTIVE == 0 )); then
            HEAT_SOAK_ACTIVE=1
            HEAT_SOAK_START_TS=$MONO
            HEAT_SOAK_PEAK_PWM=$LAST_WRITTEN_PWM
            log "Heat-soak on shutdown: PWM $HEAT_SOAK_PEAK_PWM for ${HEAT_SOAK_DURATION}s"
        fi
        if (( MONO - HEAT_SOAK_START_TS < HEAT_SOAK_DURATION )); then
            target_pwm=$HEAT_SOAK_PEAK_PWM
            MODE="HEAT_SOAK"
        else
            HEAT_SOAK_ACTIVE=0
            target_pwm=$PWM_IDLE
            MODE="OFFLINE"
            log "Heat-soak done -> PWM_IDLE $PWM_IDLE"
        fi
    else
        target_pwm=$PWM_IDLE
        MODE="OFFLINE"
    fi

    write_pwm "$target_pwm" || true

    if (( MONO - OFFLINE_SINCE >= BIOS_FALLBACK_TIMEOUT )); then
        log "Offline ${BIOS_FALLBACK_TIMEOUT}s -> BIOS auto curve"
        printf '2\n' > "$PWM_ENABLE" 2>/dev/null || true
        MODE="BIOS_FALLBACK"
        HEAT_SOAK_ACTIVE=0
        persist_state
    fi
}

# nc -w TIMEOUT_SEC: idle timeout on the QEMU unix socket (same pattern as the
# proven host script). Process substitution keeps heat-soak state in THIS shell.
# read -t 1 ticks once a second so pending PWM / heat-soak are not stuck on a blocking read.
run_serial_stream() {
    local raw_line="" latest="" rc=0

    while true; do
        verify_manual_control
        raw_line=""
        if read -t 1 -r raw_line; then
            raw_line="${raw_line//[[:space:]]/}"
            if [[ "$raw_line" =~ ^[0-9]{1,3}$ ]]; then
                latest=$((10#$raw_line))
                if (( latest > 255 )); then latest=255; fi
                apply_guest_pwm "$latest"
            fi
        else
            rc=$?
            # timeout is >128; EOF/error is 1 — nc went away, let main_loop decide.
            if (( rc <= 128 )); then
                break
            fi
            flush_pending
            expire_heat_soak
        fi
        vm_running || break
    done < <("$NC_BIN" -w "$TIMEOUT_SEC" -U "$SOCKET" 2>/dev/null)
}

main_loop() {
    log "=== Host SYS_FAN daemon active ==="

    while true; do
        read_mono
        verify_manual_control

        if ! vm_running; then
            handle_offline
            sleep "$SLEEP_OFFLINE"
            continue
        fi

        if [[ "$MODE" == "BIOS_FALLBACK" || "$MODE" == "OFFLINE" || "$MODE" == "INIT" || "$MODE" == "EMERGENCY" ]]; then
            log "VM $VM_ID up -> manual control"
            printf '1\n' > "$PWM_ENABLE" 2>/dev/null || true
            MODE="ACTIVE"
            write_pwm "$PWM_SAFE_FALLBACK" 1 || true
        fi
        OFFLINE_SINCE=0

        run_serial_stream

        # nc idle-timeout, hangup, or VM vanished mid-stream.
        if vm_running; then
            if [[ "$MODE" != "SAFE_FALLBACK" ]]; then
                log "WARNING: serial silent ${TIMEOUT_SEC}s -> PWM_SAFE_FALLBACK $PWM_SAFE_FALLBACK"
                MODE="SAFE_FALLBACK"
            fi
            write_pwm "$PWM_SAFE_FALLBACK" 1 || true
            persist_state
            # nc can return in 0ms (socket not ready / already taken). Do not spin a host core.
            sleep 1
        fi
    done
}

# -------------------- Entry --------------------
# Robust binary resolution: Prioritize explicit absolute paths to bypass systemd minimal PATH restrictions
if [[ -f "/bin/nc.openbsd" ]]; then
    NC_BIN="/bin/nc.openbsd"
elif [[ -f "/usr/bin/nc.openbsd" ]]; then
    NC_BIN="/usr/bin/nc.openbsd"
elif command -v nc.openbsd >/dev/null 2>&1; then
    NC_BIN=$(command -v nc.openbsd)
elif command -v nc >/dev/null 2>&1; then
    NC_BIN=$(command -v nc)
    if ! "$NC_BIN" -h 2>&1 | grep -q -- '-U'; then
        die "nc ($NC_BIN) has no -U — apt install netcat-openbsd"
    fi
else
    die "nc not found — apt install netcat-openbsd"
fi


bootstrap_hardware
read_mono
write_pwm "$PWM_SAFE_FALLBACK" 1 || true
main_loop
