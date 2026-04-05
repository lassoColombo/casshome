# Repository Structure

This document explains every file in this repo, what it does, and why it exists.

---

## Big Picture

```text
Proxmox (192.168.1.10)
  └── Terraform ──────────────► creates VM (k8s-node-01, 192.168.1.20)
                                      │
                                 Ansible (site.yml) ─────► configures OS, installs k8s
                                                           deploys workloads (WireGuard, Media Stack)
```

Three distinct layers with strict separation:
* **Terraform** talks to the Proxmox API — creates and destroys VMs, nothing else.
* **Ansible** talks to the VM over SSH — installs software, configures the OS, bootstraps the k8s cluster, and acts as the deployment engine for workloads.
* **Kubernetes Manifests (Ansible Templates)** define workloads — embedded directly into Ansible roles and deployed dynamically.

---

## Public Access Architecture

The cluster is not directly exposed to the internet. The only entry point is a WireGuard VPN pod.

```text
Internet
  │
  │  UDP 51820
  ▼
kaloscasshome.duckdns.org  ◄── DuckDNS cron (every 5min) keeps this pointed at home public IP
  │
  │  DNS resolves to home public IP
  ▼
Router  ── port forward UDP 51820 ──►  192.168.1.20:51820
                                              │
                                        WireGuard pod
                                        (hostNetwork, wg0: 10.13.13.1)
                                              │
                                    VPN tunnel established
                                              │
                             ┌────────────────┴──────────────────┐
                             │                                   │
                   ssh ubuntu@192.168.1.20             [http://192.168.1.20:32018](http://192.168.1.20:32018)
                   (k8s node)                          (ingress-nginx → services)
```

**VPN subnet:** `10.13.13.0/24`
* Server: `10.13.13.1` (WireGuard pod, on host network of k8s-node-01)
* Peer 1: `10.13.13.2` (your device)

Once connected to the VPN, all traffic routes through the home network. You are effectively on the LAN.

**Router note:** ZTE routers have a dedicated "WireGuard" section that configures the router's own built-in VPN server — this is NOT a port forward. The actual UDP 51820 forward must be added under **Firewall → Port Forwarding**.

---

## Prerequisites

One-time setup steps before running Terraform or Ansible.

### 0. Enable Intel VT-x in BIOS (HP Z440)

The HP Z440 ships with VT-x disabled. Proxmox requires it for KVM.
1. Reboot pve1, press **F10** at the HP splash screen
2. Navigate to **Security → System Security**
3. Enable **Intel Virtualization Technology (VT-x)** and **VT-d**
4. F10 to save and exit

Verify: `grep -c vmx /proc/cpuinfo` should return > 0.

### 1. Install local tooling

This repository now uses `uv` for strict Python dependency management.

```bash
brew install uv terraform gettext
uv sync  # Installs Ansible and required Python dependencies from pyproject.toml / uv.lock
uv run ansible-galaxy collection install ansible.posix community.general kubernetes.core
```

`gettext` provides `envsubst`, used to generate secret-bearing config files from templates.
* `ansible.posix` — `authorized_key`, `sysctl` modules
* `community.general` — `modprobe`, `timezone` modules
* `kubernetes.core` — `k8s` module used by the app playbooks

### 2. SSH key

The homelab key pair is `~/.ssh/casshome` (ed25519). The public key is injected into VMs via Terraform cloud-init.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/casshome
```

### 3. Bootstrap SSH key onto Proxmox

```bash
ssh-copy-id -i ~/.ssh/casshome.pub root@192.168.1.10
```

After this: `ssh -i ~/.ssh/casshome root@192.168.1.10`

### 4. Create Proxmox API token for Terraform

SSH into pve1 and run:

```bash
pveum user add terraform@pve
pveum aclmod / -user terraform@pve -role Administrator
pveum user token add terraform@pve terraform --privsep=0
```

Save the output token — shown once only. Add it to `.env.nu`:

```nu
$env.TF_VAR_proxmox_api_token = "terraform@pve!terraform=<token>"
```

### 5. Set up `.env.nu`

All secrets live in `.env.nu` (gitignored). Copy the template and fill in values:

```bash
cp .env.example.nu .env.nu
# edit .env.nu — fill in TF_VAR_proxmox_api_token, DUCKDNS_TOKEN, and WireGuard keys
```

---

## `terraform/`

Provisions the VM on Proxmox via the HTTP API. No SSH at this layer.

### `versions.tf`
Pins the `bpg/proxmox` provider. We use `bpg/proxmox` because it is actively maintained and has robust cloud-init support.

### `variables.tf`
| Variable | Default | Purpose |
|---|---|---|
| `proxmox_endpoint` | `https://192.168.1.10:8006` | Proxmox API URL |
| `proxmox_api_token` | _(required)_ | API token — sensitive, sourced from `.env.nu` |
| `vm_ip` | `192.168.1.20` | Static IP for the k8s VM |
| `gateway` | `192.168.1.1` | Router/gateway IP |
| `ssh_public_key` | _(required)_ | Public key injected into the VM via cloud-init |

### `main.tf`
Two resources:
* **`proxmox_virtual_environment_download_file`** — Downloads the Ubuntu 24.04 cloud image from Canonical and stores it on Proxmox local storage. Idempotent.
* **`proxmox_virtual_environment_vm`** — Creates the VM. Notable settings:
    * **`cpu type = "x86-64-v2-AES"`** — Exposes modern CPU features including AES-NI.
    * **`disk.discard = "on"` + `iothread = true`** — TRIM support for the LVM thin pool; dedicated IO thread.
    * **`initialization`** — Sets static IP, creates the `ubuntu` user with SSH key, configures DNS.
    * **`agent.enabled = true`** — Enables QEMU guest agent communication.

### `outputs.tf`
Prints VM IP, Proxmox VM ID, and the SSH command after `terraform apply`.

---

## `ansible/`

Configures the VM over SSH and deploys workloads to the Kubernetes cluster.

### `ansible.cfg`
* Points to the YAML inventory.
* Default SSH user: `ubuntu` (overridden to `root` for the `proxmox` group).
* SSH key: `~/.ssh/casshome`.
* Disables host key checking.
* `stdout_callback = yaml` for readable output.

### `pyproject.toml` / `uv.lock`
Defines the strictly pinned Python dependencies required to run Ansible and interact with the Kubernetes API (`ansible==13.5.0`, `kubernetes==35.0.0`, etc.).

### `inventory/hosts.yml`
Hosts are divided into functional groups:
```yaml
proxmox:   pve1 (192.168.1.10, ansible_user: root)
k8s:       k8s-node-01 (10.13.13.1)  — all k8s nodes
gateway:   k8s-node-01 (10.13.13.1)  — nodes that serve as the public VPN entry point
media:     k8s-node-01 (10.13.13.1)  — nodes chosen to host the media stack
```

### `inventory/group_vars/all.yml`
Variables available to all hosts:
| Variable | Value | Purpose |
|---|---|---|
| `timezone` | `UTC` | System timezone |
| `k8s_ingress_http_nodeport` | `32018` | NodePort the ingress controller listens on |
| `wireguard_ip` | `10.13.13.1` | The local IP of the WireGuard tunnel endpoint |

---

## `ansible/playbooks/`

### `site.yml`
This is now the **master orchestrator playbook**. It has completely replaced standalone playbooks (like `harden-proxmox.yml`, `duckdns.yml`, etc.) by dividing execution into distinct layers based on host groups:

1.  **Infrastructure - Proxmox:** Connects to the `proxmox` host group to apply SSH hardening and NIC performance workarounds.
2.  **Kubernetes - Host & Cluster Layer:** Connects to the `k8s` host group to install prerequisites, containerd, and bootstrap the kubeadm cluster.
3.  **Network - Gateway Layer:** Connects to the `gateway` host group. It dynamically labels the node (`network-role: gateway`) via the local kubeconfig, then applies the `duckdns` and `wireguard` roles.
4.  **Apps - Media Stack Layer:** Connects to the `media` host group. It dynamically labels the node (`stack-role: media`) and deploys the `media_stack` role.

---

## `ansible/roles/`

### `roles/proxmox/`
Targets `pve1` directly.
* **`harden_ssh_up.yml`:** Installs the SSH public key for `root` and drops a hardened `sshd_config` drop-in that disables password auth.
* **`nic_workaround_up.yml`:** Mitigates an Intel I218-LM deadlocking issue by dropping `e1000e` options and disabling TSO/GSO/GRO on boot in `/etc/network/interfaces`.

### `roles/common/`
Baseline OS setup for any managed VM:
* Updates apt cache and upgrades packages.
* Installs base packages (`curl`, `git`, `vim`, `yq`, `jq`, `qemu-guest-agent`, etc.).
* Disables swap — required by Kubernetes.

### `roles/k8s/`
Installs a full kubeadm-based Kubernetes cluster.
* **`prereqs_up.yml`:** Loads `overlay` and `br_netfilter` kernel modules; configures sysctl (`ip_forward`, `bridge-nf-call-iptables`).
* **`containerd_up.yml`:** Installs containerd and templates `config.toml` (enforcing `SystemdCgroup = true`).
* **`k8s_packages_up.yml`:** Adds the K8s apt repository and installs pinned versions of `kubelet`, `kubeadm`, and `kubectl`, holding them via `dpkg_selections`.
* **`kubeadm_init_up.yml`:** Initializes the cluster, sets up the `ubuntu` user's `.kube/config`, and removes the control-plane taint so workloads can schedule on a single node.
* **`cni_up.yml`:** Installs Calico via the Tigera operator Helm chart.
* **`ingress_up.yml`:** Installs the NGINX Ingress Controller via Helm on a static NodePort.
* **`copy_kubeconfig_up.yml`:** Dynamically downloads `admin.conf` from the node to your local machine (`~/.kube/casshome.conf`), automatically substituting the server address with the `wireguard_ip`.

### `roles/wireguard/`
Deploys the VPN entry point.
* **`host_up.yml`:** Installs `wireguard-tools`, loads the kernel module, and enables `ip_forward`.
* **`k8s_up.yml`:** Deploys the WireGuard Kubernetes manifests. Applies namespace, dynamic Secret (reading from local `.env.nu`), storage, deployment (`hostNetwork: true`), and service.

### `roles/duckdns/`
Runs a cron job every 5 minutes to keep `kaloscasshome.duckdns.org` pointing at the home public IP. Leaves the `ip=` parameter empty so DuckDNS auto-detects the outbound IP.

### `roles/media_stack/`
Orchestrates the entire Jellyfin + *arr automation stack inside Kubernetes.
* **`host_up.yml`:** Creates the physical host paths (`/mnt/downloads` and `/mnt/media/music`) on the target node.
* **`k8s_up.yml`:** Connects to the cluster API to deploy the stack in dependency order: Namespace & Shared Storage -> qBittorrent -> Prowlarr -> Lidarr -> Jellyfin.

---

## Kubernetes Manifests (Inside Roles)

Raw Kubernetes YAML files have been migrated into Ansible role templates (`roles/media_stack/templates/` and `roles/wireguard/templates/`). This allows Ansible to dynamically inject configurations (like `k8s_ingress_http_nodeport` and API keys) at runtime via Jinja2 (`.j2`).

### The `media` namespace

All media services share the `media` namespace to allow for seamless internal DNS resolution and shared PVCs.

**Who writes what, and where:**
| Writer | Writes to (in-pod) | Host path | Reader | Reads from (in-pod) |
|---|---|---|---|---|
| qBittorrent | `/downloads` | `/mnt/downloads` | Lidarr | `/downloads` |
| Lidarr | `/music` | `/mnt/media/music` | Jellyfin | `/media/music` |
| Lidarr | `/config` | `/opt/lidarr/config` | — | — |
| qBittorrent | `/config` | `/opt/qbittorrent/config` | — | — |
| Prowlarr | `/config` | `/opt/prowlarr/config` | — | — |
| Jellyfin | `/config` | `/opt/jellyfin/config` | — | — |

Because `media-downloads-pvc` is mapped to a hostPath, both qBittorrent and Lidarr can mount it simultaneously. Lidarr "moving" files from `/downloads` to `/music` resolves to a fast, atomic `rename()` syscall across the host filesystem.

### WireGuard Peer Management

Keys are passed seamlessly from `.env.nu` into the cluster Secret via Ansible lookups (`lookup('env', ...)`).

**Adding a new VPN peer:**
1.  **Generate keys for the new peer** (run locally):
    ```nu
    let priv = (wg genkey)
    let pub = ($priv | wg pubkey)
    let psk = (wg genpsk)
    echo $"private: ($priv)\npublic:  ($pub)\npsk:     ($psk)"
    ```
2.  **Add peer vars to `.env.nu`**:
    ```nu
    $env.WG_PEER2_PUBLIC_KEY    = "<pub>"
    $env.WG_PEER2_PRESHARED_KEY = "<psk>"
    ```
3.  **Update `roles/wireguard/templates/config.yml.j2`** to include the new Peer block.
4.  **Re-run Ansible and rollout restart the deployment:**
    ```bash
    source ~/.env.nu
    uv run ansible-playbook playbooks/site.yml --tags wireguard_k8s_install
    kubectl rollout restart deployment/wireguard -n wireguard
    ```
    *(Note: subPath volume mounts in Kubernetes do not hot-reload Secrets; a pod restart is mandatory).*

---

## Running Everything

The transition to `site.yml` as the master playbook makes running the stack highly streamlined. Playbooks are completely idempotent.

### 1. Provision the VM
```bash
source .env.nu
cd terraform
terraform init
terraform apply
```

### 2. Configure Node & Deploy Workloads
Run the entire stack top-to-bottom via `uv run` (which ensures Ansible runs inside the isolated environment with the correct Python dependencies):
```bash
cd ansible
uv run ansible-playbook playbooks/site.yml
```

If you only want to update a specific layer, you can use tags:
```bash
uv run ansible-playbook playbooks/site.yml --tags proxmox        # Only Proxmox host tweaks
uv run ansible-playbook playbooks/site.yml --tags k8s            # Only Kubernetes cluster configs
uv run ansible-playbook playbooks/site.yml --tags network        # Only WireGuard and DuckDNS
uv run ansible-playbook playbooks/site.yml --tags apps           # Only the Media Stack
```

### 3. One-time UI wiring after first deploy:
1.  **qBittorrent** (`http://10.13.13.1:32080`): change default password (`admin`/`adminadmin`); set save path to `/downloads`
2.  **Prowlarr** (`http://10.13.13.1:32696`): add indexers; Add Lidarr (`http://lidarr:8686`, API key from Lidarr Settings)
3.  **Lidarr** (`http://10.13.13.1:32686`): add qBittorrent (`http://qbittorrent:8080`); set Root Folder to `/music`
4.  **Jellyfin** (`http://10.13.13.1:32018/jellyfin`): Add Music library mapping to `/media/music`

---

## Connecting to the cluster

All external access goes through WireGuard. There is no direct SSH or HTTP exposure to the internet.

### Connect via VPN
1.  Install the WireGuard app.
2.  Import your peer `.conf` file.
3.  Activate the tunnel.

### Verify the tunnel
```bash
ping 10.13.13.1                  # VPN server — must respond before anything else works
curl -s [https://ifconfig.me](https://ifconfig.me)      # should return your home public IP
ssh -i ~/.ssh/casshome ubuntu@10.13.13.1
```
