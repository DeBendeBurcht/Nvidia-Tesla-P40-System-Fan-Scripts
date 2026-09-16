# Nvidia-Tesla-P40-System-Fan-Scripts
Scripts to allow a (power injected) 9377 fan to be controlled from inside a linux vm through proxmox into the motherboards header


# Proxmox / KVM GPU Fan Controller for NVIDIA Tesla P40

An enterprise-grade, automated cooling bridge designed to control host-managed motherboard chassis fans (`SYS_FAN`) based on real-time GPU metrics inside a KVM/QEMU Guest Virtual Machine (VM). 

This architecture explicitly solves the cooling challenges of the **NVIDIA Tesla P40** (and similar passive enterprise accelerators) when equipped with custom blower shrouds (e.g., Delta BFB1012EH) connected to a motherboard fan header rather than a native GPU fan controller.

---

## ⚡ Key Features

* **Proactive Load Anti-Lag (Predictive Control):** Spins up the high-static pressure blower the moment GPU execution starts or high wattage draw occurs, instead of waiting for the copper heatsink block to become thermally saturated.
* **Smart Hysteresis & Decay Dampening:** Prevents the blower from generating annoying rapid auditory "pulsing" by caching target RPM jumps and applying strict acceleration/deceleration rate-limiting (`UP_STEP` / `DOWN_STEP`).
* **Kernel & Infrastructure Safety Failsafes:**
  * **Host Fallback:** If the guest VM crashes, reboots, or drops communication for $>8$ seconds, the host daemon instantly locks the fan to a safe high-throughput velocity (`PWM 180`).
  * **Thermal Emergency:** If the guest registers a critical thermal runaway condition ($\ge 87^\circ\text{C}$), it transmits an emergency burst (`PWM 255`) prompting host notification workflows.
* **Isolated Environment Footprint:** Runs independently of system-wide networking infrastructure using isolated UNIX domain sockets over QEMU serial pipelines. It avoids tampering with system-wide configuration layers (`update-alternatives`).

---

## 🏗️ System Architecture

```text
┌────────────────────────────────────────────────────────┐
│  Proxmox VE (Host Layer)                               │
│                                                        │
│  [it87 Driver] ──> /sys/class/hwmon/hwmon3/pwm2        │
│                           ▲                            │
│               (gpu-fan-controller.sh)                  │
│                           ▲                            │
│              Reads from UNIX Domain Socket             │
└───────────────────────────┼────────────────────────────┘
                            │
                            │ QEMU VirtIO Serial0
                            ▼
┌────────────────────────────────────────────────────────┐
│  Debian 12 Guest (VM 126)                              │
│                                                        │
│  [nvidia-smi] ──> Queries Die Temp, Util & Power       │
│                           │                            │
│                  (gpu-fan-guest.sh)                    │
│                           │                            │
│              Writes to Pipeline /dev/ttyS0             │
└────────────────────────────────────────────────────────┘
```

---

## 📦 Prerequisites

### Host Environment (Proxmox VE)
* **Kernel Compatibility:** Fully verified on kernel `6.8.4-2-pve`.
* **Required Packages:** Linux header files for the current booted kernel must be present to build the hardware monitoring driver.

### Guest Environment (VM)
* **OS:** Debian 12 (or similar modern Linux distribution).
* **GPU Configuration:** NVIDIA Proprietary Datacenter Drivers (v535+) installed with active PCI-passthrough topology successfully configured.

---

## 🚀 Step-by-Step Installation

### Part 1: Proxmox Host Configuration

#### 1. Install Kernel Headers and Building Tools
To ensure compliance with pinned or rolled-back kernels without forcing unwanted system upgrades, target your running kernel layout:
```bash
apt update
apt install -y pve-headers-$(uname -r) build-essential git dkms lm-sensors netcat-openbsd
```

#### 2. Deploy Frank Crawford's `it87` Driver via DKMS
```bash
cd /usr/src
git clone https://github.com
cd it87

# If recovery from a prior interrupted kernel migration is required, clear records:
dkms remove it87/v2.0-4-gbc06d34.20260913 --all 2>/dev/null || true

# Register, build, and deploy the driver
dkms add .
dkms install it87/v2.0-4-gbc06d34.20260913
```

#### 3. Establish the Gigabyte ACPI Workaround
Create persistent runtime module arguments to resolve common hardware resource ownership contentions between the Linux driver and UEFI ACPI instructions:
```bash
echo "it87" > /etc/modules-load.d/it87.conf
echo "options it87 ignore_resource_conflict=1" > /etc/modprobe.d/it87.conf

# Commit changes and force immediate insertion
modprobe it87
```

#### 4. Configure the QEMU Serial Interface
Bind a virtual UNIX stream server instance to VM 126. Run this command on your Proxmox terminal:
```bash
qm set 126 --serial0 socket
```

#### 5. Install the Host-Side Daemon
Place the script text into `/usr/local/bin/gpu-fan-controller.sh`. Give it executable permissions:
```bash
chmod +x /usr/local/bin/gpu-fan-controller.sh
```

#### 6. Register and Activate the Host Service
Create a dedicated background management system definition:
```bash
nano /etc/systemd/system/gpu-fan-controller.service
```
Paste the following definition:
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
Initialize and start the service:
```bash
systemctl daemon-reload
systemctl enable --now gpu-fan-controller.service
```

---

### Part 2: Guest VM Configuration

SSH into the Guest VM (with ID 126) and execute commands utilizing administrative permissions (`sudo`):

#### 1. Verify Serial Link Device Node
Confirm that your virtual serial interface mapping is exposed by KVM:
```bash
ls -l /dev/ttyS0
```

#### 2. Install the Guest Script
Deploy the script text into `/usr/local/bin/gpu-fan-guest.sh` and make it executable:
```bash
sudo chmod +x /usr/local/bin/gpu-fan-guest.sh
```

#### 3. Register the Guest Service Container
```bash
sudo nano /etc/systemd/system/gpu-fan-guest.service
```
Paste the configuration:
```ini
[Unit]
Description=Tesla P40 Guest Fan Reporter
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gpu-fan-guest.sh
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
```
Commit changes to systemd and spin up the daemon pipeline:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gpu-fan-guest.service
```

---

## 🔍 Validation and Verification

Follow these verification pipelines to confirm that communication, logic, and physical fan control are functioning perfectly.

### Phase 1: Verify Hardware Module Tracking
On the Proxmox Host, execute an introspection call to confirm the kernel driver has locked target device registries:
```bash
lsmod | grep it87
```
*Expected Output:* An active pointer structure listing references showing `it87`.

### Phase 2: Interrogate Guest VM Datastream Transmission
Inspect the system logs inside the VM to track live telemetry acquisition and serialization routines:
```bash
sudo systemctl status gpu-fan-guest.service
```
*Expected Output:*
```text
● gpu-fan-guest.service - Tesla P40 Guest Fan Reporter
   Active: active (running) since Wed 2026-09-16 20:42:40 CEST; 5s ago
...
[2026-09-16 20:59:32] GPU: 32°C | Core Util: 0% | Power Draw: 9W | Outbound PWM: 40
```

### Phase 3: Monitor Real-Time Host Execution Logs
Track how the Proxmox hypervisor layer captures incoming IPC frames and handles hardware changes:
```bash
journalctl -u gpu-fan-controller.service -f
```
*Expected Output during normal execution:*
```text
integro systemd: Started Proxmox Host SYS_FAN GPU Controller.
integro gpu-fan-controller.sh: === SYS_FAN init (header 2) ===
integro gpu-fan-controller.sh: Hardware at /sys/class/hwmon/hwmon3
integro gpu-fan-controller.sh: VM 126 up -> manual control
integro gpu-fan-controller.sh: PWM 40 | 1180 RPM | ACTIVE
```

### Phase 4: Dynamic Hardware Control Verification Loop (Forced Ramping)
To check if the blower fan physically scales up and down, force a high PWM signal through the VM:

1. Inside the Guest VM, modify the script variables to temporarily simulate a heavy minimum state:
   ```bash
   sudo sed -i 's/PWM_MIN=40/PWM_MIN=160/g' /usr/local/bin/gpu-fan-guest.sh
   sudo systemctl restart gpu-fan-guest.service
   ```
2. **Acoustic and Visual Validation:** The physical Delta blower fan will instantly ramp up, registering $\approx 3600\text{ RPM}$ inside your active Proxmox `journalctl -f` shell.
3. Revert your configuration profile once verification concludes:
   ```bash
   sudo sed -i 's/PWM_MIN=160/PWM_MIN=40/g' /usr/local/bin/gpu-fan-guest.sh
   sudo systemctl restart gpu-fan-guest.service
   ```
4. Heat-Soak Verification: Notice that the fan continues to run high for precisely 25 seconds after reverting. This confirms that the host-side HEAT_SOAK protective layer is working exactly as intended to shed residual core heat.


📄 LicenseThis system tool assembly is distributed under open-source protocols matching standard GPL-2.0 conditions matching parent module drivers.
***
<FollowUp>
Nu de **README.md** helemaal strak op GitHub kan worden geplaatst, laat maar weten:
* Of je de **volledige broncode** van beide definitieve bestanden nog in één overzicht wilt zien om ze makkelijk te kunnen uploaden naar je repository.
* Of je hulp nodig hebt bij het initialiseren van de **Git repository** vanaf de commandline.
</FollowUp>
