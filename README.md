# 🌀 Nvidia Tesla P40 — System Fan Scripts

Control a **power-injected 9377 blower** (e.g. Delta BFB1012EH) from inside a Linux VM, through Proxmox, onto a motherboard `SYS_FAN` header.

Built for a **pasthrough NVIDIA Tesla P40 24GB** with a custom low-restriction shroud. Tuned and verified on **Proxmox VE** + **Debian 12**. The same ideas may work on other KVM setups with minor path tweaks.

---

> ⚠️ **Heads-up**  
> This repository was written with the help of AI. It is **not actively maintained**.  
> There is no support channel, no guaranteed compatibility matrix, and no promise that a future Proxmox / kernel / nvidia update will keep working without changes.  
>  
> That said — I'm proud of what this does on my box. Use it, fork it, break it, fix it. You own the risk on your own hardware.

---

## 🚨 Critical warnings (read before you touch hardware)

### 1. Set a **flat** BIOS fan curve first
If the host script is stopped, crashed, or not started yet, the motherboard reclaims the header. A normal BIOS “smart” curve will fight your last PWM write and can produce wild RPM swings.

**Do this in UEFI/BIOS before relying on the daemon:**

- Open the fan / hardware monitor page for the header you will use (`SYS_FAN2` in this project).
- Set a **flat fixed percentage** curve — not temperature-linked steps.  
  Example that works here: **20%** steady.
- Save and exit.

That way “script not running” = quiet, predictable airflow, not a roulette wheel.

### 2. Pick the **correct** fan header — wrong header can brick your calm
The host script writes directly to `pwmN` on the Super I/O chip (IT8689 via `it87`).

| Wrong move | What happens |
|---|---|
| `FAN_HEADER` points at CPU_FAN / a different SYS_FAN | You fight the BIOS or another controller on that channel |
| Two writers on the same `pwmN` (BIOS auto + script, or two scripts) | **Race condition** on the register — RPM hunting, odd ACPI behaviour, in the worst case a hard lock / crash loop |
| Power-injected blower on a header the board still tries to “sense” oddly | Noise, false tach, or surprise full speed |

**Checklist before `systemctl enable`:**

1. Physically plug the **BFB1012EH** (4-pin, molex +12V inject on the positive line — you already know that wiring is on you) into the intended header.
2. Confirm with `sensors` / sysfs which `hwmon*/pwmN` and `fanN_input` move when you twiddle that header.
3. Set `FAN_HEADER=N` in `gpu-fan-controller.sh` to **that** N only.
4. Do **not** leave the BIOS in “Smart” / “PWM auto” for that same header while the daemon owns it — use the flat % fallback from warning 1, and let the script switch `pwmN_enable` to manual while it runs.

### 3. Serial0 is exclusive
Guest talks to the host over QEMU `serial0` → guest `/dev/ttyS0`.

- Do **not** run `qm terminal <VMID>` on that serial while the fan bridge is up.
- Only **one** socket client at a time.

### 4. Guest “255” is a panic button
Host treats sustained **PWM 255** as “cooling failed → stop the VM”.  
Guest normal ceiling is **254**. Do not map a casual full-fan curve to 255.

---

## ✨ What this does

| Layer | Script | Job |
|---|---|---|
| **Proxmox host** | `gpu-fan-controller.sh` | Owns `SYS_FAN` via `it87`, reads PWM integers from the VM serial socket, applies hysteresis / heat-soak / fail-safes, writes sysfs |
| **Debian guest** | `gpu-fan-guest.sh` | Reads Tesla P40 die (and memory temp if the driver exposes it), util & power via `nvidia-smi`, runs a quiet fan curve + light prediction, heartbeats ASCII PWM lines to `/dev/ttyS0` |

### Goals on this machine
- Keep the **P40 stable and safe** under load  
- Keep the **server as silent as possible** at idle  
- Survive **VM crash / serial drop / script restart** without cooking the card or fighting the BIOS for minutes  

### Built-in safety (host)
| Event | Response |
|---|---|
| Guest silent ≥ **8s** (crash, hang, reboot) | Force **PWM 180** |
| VM offline | Idle **PWM 40**, then after **5 min** return header to **BIOS** |
| High duty then sudden drop | **Heat-soak** hold (~25s) so the heatsink can dump residual heat |
| Guest sends **255** for ~30s | `qm stop <VMID> --skiplock` |
| systemd restart while VM still up | Stay in **manual** at 180 — no 2s dive into the BIOS curve under a live P40 |

### Guest curve behaviour (defaults)
| State | Approx PWM |
|---|---|
| Idle ~40–50°C | 40–44 (near silent) |
| Light work ~60°C | ~78 |
| Real load ~70–75°C | ~145–180 |
| Hot ~84°C | ~240 |
| Normal max | **254** |
| Die ≥88°C held critical | **255** (host stop path) |

Light **prediction**: extra PWM when temperature is rising, SM util is already high while the die is still cool, or power draw is already elevated — so the 9377 leads the copper instead of chasing it. Asymmetric slew (`UP_STEP` / `DOWN_STEP`) stops the blower from yoyoing audibly.

---

## 🏗️ Architecture

```text
┌────────────────────────────────────────────────────────────┐
│  Proxmox VE host                                           │
│                                                            │
│  it87  →  /sys/class/hwmon/hwmonX/pwmN   (SYS_FAN header)  │
│                    ▲                                       │
│         gpu-fan-controller.sh                              │
│                    ▲                                       │
│         UNIX socket  /var/run/qemu-server/<VMID>.serial0   │
└────────────────────┼───────────────────────────────────────┘
                     │  QEMU serial0 (socket)
                     ▼
┌────────────────────────────────────────────────────────────┐
│  Debian 12 guest  (e.g. VM 126)                            │
│                                                            │
│  nvidia-smi  →  die °C · (mem °C) · util · power           │
│                    │                                       │
│         gpu-fan-guest.sh                                   │
│                    │                                       │
│         /dev/ttyS0   ASCII integer + newline, ≤8s heartbeat│
└────────────────────────────────────────────────────────────┘
```

**Fan path (physical):** Tesla P40 → custom shroud → Delta **BFB1012EH** (4-pin) → molex **+12V power inject** on the positive rail → motherboard **SYS_FAN** header (tach + PWM from the board, power from the PSU inject).

---

## 📦 Prerequisites

### Host (Proxmox VE)
- Working Proxmox install (verified idea on kernel family `6.8.x-pve`; yours may differ)
- Motherboard Super I/O supported by Frank Crawford’s **it87** DKMS (here: **IT8689** on a Gigabyte A520M-class board)
- Packages: kernel headers for the **running** kernel, `dkms`, `git`, `build-essential`, `lm-sensors`, **`netcat-openbsd`**
- Flat BIOS % on the target header (see warnings)

### Guest (Debian 12 VM)
- GPU **PCI passthrough** of the Tesla P40 working
- NVIDIA proprietary driver **535+** (`nvidia-driver`, `nvidia-smi` OK)
- `serial0: socket` on the VM config → `/dev/ttyS0` inside the guest

### Hardware notes
- **9377-size blower**, model used here: **BFB1012EH**
- Header-driven PWM + separate **power inject** (board header alone usually cannot feed this blower’s current)
- You are responsible for inject polarity, wire gauge, and not back-feeding the motherboard rail

---

## 🚀 Installation

### Part 1 — Proxmox host

#### 1️⃣ Kernel headers & tools
Pin to the kernel you are **actually booted on** (avoids pulling a newer headers package than your running image):

```bash
apt update
apt install -y pve-headers-$(uname -r) build-essential git dkms lm-sensors netcat-openbsd
```

#### 2️⃣ Frank Crawford `it87` via DKMS
```bash
cd /usr/src
git clone https://github.com/frankcrawford/it87.git
cd it87

# Only if a broken half-install exists from an old kernel:
# dkms remove it87/<old-version> --all 2>/dev/null || true

./dkms-install.sh
# or: dkms add . && dkms install it87/<version-shown-by-dkms>
```

#### 3️⃣ Persist the Gigabyte ACPI workaround (**both** files)
`modules-load.d` only takes the **module name**. Parameters belong in `modprobe.d`.

```bash
echo "it87" > /etc/modules-load.d/it87.conf
echo "options it87 ignore_resource_conflict=1" > /etc/modprobe.d/it87.conf
modprobe it87 ignore_resource_conflict=1
```

Confirm after reboot:

```bash
cat /sys/module/it87/parameters/ignore_resource_conflict   # expect Y or 1
lsmod | grep it87
sensors
```

#### 4️⃣ Find **your** fan header (do not skip)
```bash
# List chips / fans
sensors

# See which hwmon node is the IT8689 and which pwm/fan indices exist
grep -H . /sys/class/hwmon/hwmon*/name
ls /sys/class/hwmon/hwmon*/pwm* /sys/class/hwmon/hwmon*/fan*_input 2>/dev/null
```

Spin or stop the physical blower briefly (or watch RPM while changing BIOS % on one header only) until you know:

- `hwmon` path  
- `pwmN` / `fanN_input` index  

Set that index as `FAN_HEADER` in the host script. **Wrong N = race with something else on the board.**

#### 5️⃣ Attach QEMU serial0 to the GPU VM
```bash
qm set <VMID> --serial0 socket
# example: qm set 126 --serial0 socket
qm config <VMID> | grep serial0
```

#### 6️⃣ Install the host daemon
Copy `gpu-fan-controller.sh` to the host and adjust at least:

| Variable | Meaning | Example |
|---|---|---|
| `FAN_HEADER` | Motherboard header index (`pwmN`) | `2` |
| `VM_ID` | Proxmox VM id with the P40 | `126` |
| `PWM_IDLE` / `PWM_MIN` | Quiet floor while script owns the fan | `40` |
| `PWM_SAFE_FALLBACK` | Serial silence / takeover | `180` |

```bash
install -m 755 gpu-fan-controller.sh /usr/local/bin/gpu-fan-controller.sh
```

#### 7️⃣ systemd unit (host)
`/etc/systemd/system/gpu-fan-controller.service`:

```ini
[Unit]
Description=Proxmox Host SYS_FAN GPU Controller
After=pve-cluster.service qemu-server.service systemd-modules-load.service

[Service]
Type=simple
ExecStart=/usr/local/bin/gpu-fan-controller.sh
Restart=always
RestartSec=2s
TimeoutStopSec=8
StartLimitIntervalSec=60
StartLimitBurst=8

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now gpu-fan-controller.service
journalctl -u gpu-fan-controller.service -f
```

Useful one-shot:

```bash
gpu-fan-controller.sh --status
```

---

### Part 2 — Debian guest (P40 VM)

#### 1️⃣ Serial node
```bash
ls -l /dev/ttyS0
```

#### 2️⃣ NVIDIA stack
```bash
sudo apt install -y nvidia-driver nvidia-kernel-dkms
nvidia-smi
nvidia-smi --query-gpu=temperature.gpu,temperature.memory,utilization.gpu,power.draw --format=csv,noheader
```

Die temperature should be a number. **Memory temp on P40 + 535 is often `[N/A]`** — the guest script treats that as optional and ignores it when missing.

#### 3️⃣ Install the guest reporter
Copy `gpu-fan-guest.sh`, then:

```bash
sudo install -m 755 gpu-fan-guest.sh /usr/local/bin/gpu-fan-guest.sh
```

Tune `GPU_T` / `GPU_P` (and optional `MEM_*`) if your shroud/ambient needs a quieter or colder curve. Leave **254** as the normal max unless you intend to trip the host emergency path.

#### 4️⃣ systemd unit (guest)
`/etc/systemd/system/gpu-fan-guest.service`:

```ini
[Unit]
Description=Tesla P40 Guest Fan Reporter
After=multi-user.target
# Optional if you use it:
# Wants=nvidia-persistenced.service

[Service]
Type=simple
ExecStart=/usr/local/bin/gpu-fan-guest.sh
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gpu-fan-guest.service
sudo systemctl status gpu-fan-guest.service
sudo journalctl -u gpu-fan-guest.service -f
```

Guest status file (when running):

```bash
gpu-fan-guest.sh --status
# or: cat /dev/shm/gpu-fan-guest-state
```

---

## ✅ Validation checklist

### 1. Host driver & header
```bash
lsmod | grep it87
cat /sys/module/it87/parameters/ignore_resource_conflict
# Write a test value ONLY to the header you identified:
# echo 80 > /sys/class/hwmon/hwmonX/pwmN_enable   # 1 = manual
# echo 100 > /sys/class/hwmon/hwmonX/pwmN
# cat /sys/class/hwmon/hwmonX/fanN_input
```
Expect RPM to move on **that** blower only.

### 2. Guest is transmitting
```bash
sudo journalctl -u gpu-fan-guest.service -n 30 --no-pager
```
Expect lines with GPU °C, util, power, and outbound PWM. Heartbeat about every **2s**.

### 3. Host is applying
```bash
journalctl -u gpu-fan-controller.service -f
gpu-fan-controller.sh --status
```
Expect `ACTIVE`, PWM matching the guest (subject to hysteresis / heat-soak), non-zero RPM.

### 4. Forced ramp (acoustic test)
On the **guest**, temporarily raise the floor, then put it back:

```bash
sudo sed -i 's/^PWM_MIN=40/PWM_MIN=160/' /usr/local/bin/gpu-fan-guest.sh
sudo systemctl restart gpu-fan-guest.service
# blower should climb; host journal shows higher PWM / RPM
sudo sed -i 's/^PWM_MIN=160/PWM_MIN=40/' /usr/local/bin/gpu-fan-guest.sh
sudo systemctl restart gpu-fan-guest.service
```
After the drop, host **heat-soak** may hold an elevated duty ~25s — that is intentional.

### 5. Fail-safe smoke tests (careful)
| Test | Expect |
|---|---|
| `systemctl stop gpu-fan-guest` for >8s | Host → PWM **180** |
| Clean VM shutdown | Host → idle **40**, later BIOS after timeout |
| Stop host daemon with VM still up | Cleanup holds **180 manual** (not a surprise BIOS dip) |

---

## 🔧 Configuration map

### Host (`gpu-fan-controller.sh`)
| Knob | Role |
|---|---|
| `FAN_HEADER` | Sysfs `pwmN` / `fanN` index — **must match the physical header** |
| `VM_ID` | Proxmox VM id → `…/qemu-server/${VM_ID}.serial0` |
| `TIMEOUT_SEC` | Serial silence before safe fallback (default 8) |
| `PWM_IDLE` / `PWM_MIN` | Offline / clamp floor |
| `PWM_SAFE_FALLBACK` | Crash / silence / takeover |
| `HEAT_SOAK_*` | Post-load residual cooling |
| `BIOS_FALLBACK_TIMEOUT` | Seconds offline before `pwm_enable=2` |
| `HYSTERESIS_THRESHOLD` / `MIN_INTERVAL` | Anti-chatter + 1 Hz hardware write floor |

### Guest (`gpu-fan-guest.sh`)
| Knob | Role |
|---|---|
| `SERIAL` | Usually `/dev/ttyS0` |
| `INTERVAL_SEC` | Heartbeat (keep well under host `TIMEOUT_SEC`) |
| `GPU_T` / `GPU_P` | Die temperature curve |
| `MEM_T` / `MEM_P` | Used only if memory °C exists |
| `RISE_GAIN` / `UTIL_LEAD` / `POWER_LEAD_*` | Predictive boost |
| `UP_STEP` / `DOWN_STEP` | Audible smoothness |
| `CRIT_GPU_C` / `PWM_EMERGENCY` | Path to host VM stop |

---

## 🐛 Common pitfalls

| Symptom | Likely cause |
|---|---|
| `IT8689` / pwm not found | `it87` not loaded, or missing `ignore_resource_conflict=1` in **modprobe.d** |
| Fan flaps between two speeds | BIOS still on a smart curve for the **same** header, or wrong `FAN_HEADER` |
| Host stuck at 180 | Guest not heartbeating, bad `ttyS0`, or `qm terminal` stole serial0 |
| Guest write fails | VM has no `serial0: socket`, or wrong device node |
| `nc: invalid option -U` | Install **`netcat-openbsd`** (not traditional netcat only) |
| Memory temp always `-` | Normal on many P40 + 535 setups — die curve alone is enough |
| Server crashed after enable | **Wrong header** / dual control race — fix `FAN_HEADER`, set flat BIOS %, one writer only |

---

## 📁 Repo layout (suggested)

```text
.
├── README.md
├── host/
│   └── gpu-fan-controller.sh
└── guest/
    └── gpu-fan-guest.sh
```

Copy each script to `/usr/local/bin/` on the matching machine as shown above.

---

## 📄 License

GPL-2.0-style usage is fine for this tooling (same family as much of the kernel/DKMS stack you load beside it).  
No warranty. Full responsibility for hardware, wiring, power inject, and thermal outcome is yours.

---

## 🙏 Notes

- Written for **my** Ryzen + Gigabyte + Proxmox + Debian 12 + Tesla P40 + BFB1012EH path.  
- “Works on my machine” was earned the hard way (host IPC, heat-soak, BIOS fallback, guest curve).  
- If you publish a fork that survives another board or GPU, you are doing future strangers a favour — this repo itself may never track those variants.
