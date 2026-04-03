# Repository Structure

This document explains every file in this repo, what it does, and why it exists.

---

## Big Picture

```
Proxmox (192.168.1.10)
  └── Terraform ──────────────► creates VM (k8s-node-01, 192.168.1.20)
                                      │
                                 Ansible ──────────────► configures OS, installs k8s
                                      │
                                 kubectl / playbooks ──► deploys workloads (WireGuard, Jellyfin)
```

Three distinct layers with strict separation:
- **Terraform** talks to the Proxmox API — creates and destroys VMs, nothing else
- **Ansible** talks to the VM over SSH — installs software, configures the OS and k8s cluster
- **k8s manifests** (`k8s/`) define workloads — deployed separately via per-app playbooks

---

## Public Access Architecture

The cluster is not directly exposed to the internet. The only entry point is a WireGuard VPN pod.

```
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
                    ssh ubuntu@192.168.1.20            http://192.168.1.20:32018
                    (k8s node)                         (ingress-nginx → services)
```

**VPN subnet:** `10.13.13.0/24`
- Server: `10.13.13.1` (WireGuard pod, on host network of k8s-node-01)
- Peer 1: `10.13.13.2` (your device)

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

```bash
brew install ansible terraform gettext
ansible-galaxy collection install ansible.posix community.general kubernetes.core
```

`gettext` provides `envsubst`, used to generate secret-bearing config files from templates.

- `ansible.posix` — `authorized_key`, `sysctl` modules
- `community.general` — `modprobe`, `timezone` modules
- `kubernetes.core` — `k8s` module used by the app playbooks (jellyfin, wireguard)

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

### 4. Harden Proxmox SSH

```bash
cd ansible
ansible-playbook playbooks/harden-proxmox.yml
```

Disables password auth on pve1 — key only after this.

### 5. Create Proxmox API token for Terraform

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

### 6. Set up `.env.nu`

All secrets live in `.env.nu` (gitignored). Copy the template and fill in values:

```bash
cp .env.example.nu .env.nu
# edit .env.nu — fill in TF_VAR_proxmox_api_token, DUCKDNS_TOKEN, and WireGuard keys
```

---

## `terraform/`

Provisions the VM on Proxmox via the HTTP API. No SSH at this layer.

### `versions.tf`

Pins the `bpg/proxmox` provider (`~> 0.73`). We use `bpg/proxmox` rather than the older `Telmate/proxmox` — it's more actively maintained and has better cloud-init support.

### `variables.tf`

| Variable | Default | Purpose |
|---|---|---|
| `proxmox_endpoint` | `https://192.168.1.10:8006` | Proxmox API URL |
| `proxmox_api_token` | _(required)_ | API token — sensitive, goes in `terraform.tfvars` |
| `vm_ip` | `192.168.1.20` | Static IP for the k8s VM |
| `gateway` | `192.168.1.1` | Router/gateway IP |
| `ssh_public_key` | _(required)_ | Public key injected into the VM via cloud-init |

### `main.tf`

Two resources:

**`proxmox_virtual_environment_download_file`** — Downloads the Ubuntu 24.04 cloud image from Canonical and stores it on Proxmox local storage. Idempotent: no-ops if the file already exists.

**`proxmox_virtual_environment_vm`** — Creates the VM. Notable settings:

- **`cpu type = "x86-64-v2-AES"`** — Exposes modern CPU features including AES-NI. Better than `kvm64` for k8s, which does heavy TLS work.
- **`disk.discard = "on"` + `iothread = true`** — TRIM support for the LVM thin pool; dedicated IO thread for better disk performance.
- **`initialization` (cloud-init)** — Sets static IP, creates the `ubuntu` user with SSH key (no password), configures DNS.
- **`agent.enabled = true`** — Enables QEMU guest agent communication. Requires `qemu-guest-agent` installed by Ansible.
- **`on_boot = true`** — VM starts automatically when Proxmox boots.

### `outputs.tf`

Prints VM IP, Proxmox VM ID, and the SSH command after `terraform apply`.

---

## `ansible/`

Configures the VM over SSH. Split into inventory, playbooks, and roles.

### `ansible.cfg`

- Points to the YAML inventory
- Default SSH user: `ubuntu` (overridden to `root` for the `proxmox` group)
- SSH key: `~/.ssh/casshome`
- Disables host key checking (new VMs don't prompt)
- `stdout_callback = yaml` for readable output

### `inventory/hosts.yml`

Three host groups, each with a distinct purpose:

```
proxmox:   pve1 (192.168.1.10, ansible_user: root)
k8s:       k8s-node-01 (192.168.1.20)   — all k8s nodes
gateway:   k8s-node-01 (192.168.1.20)   — nodes that serve as the public VPN entry point
```

A host can belong to multiple groups. Currently `k8s-node-01` is in both `k8s` and `gateway`, but they serve different playbooks:

- `k8s` → `site.yml` — installs k8s on every node in this group
- `gateway` → `duckdns.yml`, `wireguard.yml` — runs only on the node that is the public entry point

When adding a second k8s node, add it only to `k8s`. Only add it to `gateway` if it should also host WireGuard and DuckDNS.

### `inventory/group_vars/all.yml`

Variables available to all hosts:

| Variable | Value | Purpose |
|---|---|---|
| `timezone` | `UTC` | System timezone |
| `k8s_node_ip` | `192.168.1.20` | Node IP (used in kubeadm config and Jellyfin) |
| `k8s_ingress_http_nodeport` | `32018` | NodePort the ingress controller listens on |
| `duckdns_domain` | `kaloscasshome` | Subdomain only — no `.duckdns.org` suffix |
| `duckdns_token` | `{{ lookup('env', 'DUCKDNS_TOKEN') }}` | DuckDNS API token — read from `.env.nu` at playbook runtime |

---

## `ansible/playbooks/`

### `harden-proxmox.yml`

Targets `pve1`. Installs the SSH public key and drops a hardened `sshd_config` drop-in (`/etc/ssh/sshd_config.d/99-hardened.conf`) that disables password auth. A handler restarts sshd only if the file changed.

**Run before** disabling password auth — you need key access in place first.

### `site.yml`

Configures every node in the `k8s` group. Applies two roles:

```
common → k8s
```

Idempotent — safe to re-run on any or all k8s nodes. Each role uses `include_tasks` + tags for targeted runs. Does **not** include DuckDNS or WireGuard — those are gateway-specific and live in their own playbooks.

### `duckdns.yml`

Targets the `gateway` group. Applies the `duckdns` role to install the DuckDNS cron updater. Only runs on nodes in `gateway` — in a multi-node cluster this keeps the DNS updater off pure worker nodes.

### `wireguard.yml`

Two plays in one file:

1. **`hosts: gateway`** — applies the `wireguard` role (host prerequisites: kernel module, `wireguard-tools`, IP forwarding). Runs on the node that will host the VPN pod.
2. **`hosts: localhost`** — applies the k8s manifests from `k8s/wireguard/` via `kubernetes.core.k8s`. Runs on the Ansible controller against the cluster API.

Splitting into two plays keeps host-level config separate from k8s manifest deployment while keeping them in a single runnable file.

### `jellyfin.yml`

Targets `localhost` only — applies manifests from `k8s/jellyfin/` via `kubernetes.core.k8s`. No host-level changes needed for Jellyfin. Prerequisite: cluster up (`site.yml` first), `kubernetes.core` collection installed.

### `media-stack.yml`

Two plays, following the `wireguard.yml` pattern:

1. **`hosts: k8s`** — Creates `/mnt/downloads` and `/mnt/media/music` on every k8s node. Targeting `k8s` (not a specific host) means these directories are provisioned on any node in the group — extensible when adding worker nodes.
2. **`hosts: localhost`** — Deploys all three media stack apps to the `media` namespace in dependency order: namespace → storage → qBittorrent → Prowlarr → Lidarr → services.

All three services are tightly coupled (Lidarr configures against qBittorrent and Prowlarr), so they are deployed as a unit.

---

## `ansible/roles/`

### `roles/common/`

Baseline OS setup for any managed VM:

1. `apt update` + `upgrade dist` — full system upgrade, `cache_valid_time: 3600` skips re-fetch on reruns
2. Install base packages: `curl`, `git`, `vim`, `apt-transport-https`, `ca-certificates`, `gnupg`, `qemu-guest-agent`, `tree`
3. Enable `qemu-guest-agent` — required for Proxmox to communicate with the VM
4. Set timezone from `group_vars/all.yml`
5. Disable swap — required by Kubernetes (`swapoff -a` + comment out fstab entry)

---

### `roles/k8s/`

Installs a full kubeadm-based Kubernetes cluster. Structured as focused task files, each with a tag for targeted runs.

**`defaults/main.yml`:**

| Variable | Default | Purpose |
|---|---|---|
| `k8s_version` | `"1.32"` | Minor version — controls apt repo path |
| `k8s_pod_cidr` | `10.244.0.0/16` | Pod IP range — must match Calico IPPool |
| `k8s_service_cidr` | `10.96.0.0/12` | ClusterIP service range |
| `k8s_admin_user` | `ubuntu` | User that gets a kubeconfig on the node |
| `k8s_calico_chart_version` | `v3.29.0` | Calico Tigera operator Helm chart version |
| `k8s_flannel_version` | `v0.26.2` | Kept for the Flannel removal task during migration |
| `k8s_ingress_nginx_chart_version` | `4.12.0` | ingress-nginx Helm chart version |

**`handlers/main.yml`:**
- `Restart containerd` — fires when `config.toml` changes
- `Restart kubelet` — fires when CNI config is removed during migration

**`templates/kubeadm-config.j2`:** Multi-document YAML passed to `kubeadm init --config`. Using a config file rather than CLI flags makes init repeatable and reviewable. Three stanzas:
- `InitConfiguration` — advertise address, CRI socket
- `ClusterConfiguration` — pod and service CIDRs
- `KubeletConfiguration` — `cgroupDriver: systemd` (must match containerd)

**`tasks/main.yml`** — Dispatcher, calls task files in order:

```
prereqs → containerd → k8s_packages → kubeadm_init → helm → cni → ingress → kubectl_config
```

Helm is installed before CNI because Calico is deployed via Helm. WireGuard host prerequisites are intentionally absent — they belong to the `wireguard` role, run only on `gateway` nodes.

---

**`tasks/prereqs.yml`** — tag: `prereqs`

Kernel and network prerequisites:
- Loads `overlay` (containerd layered filesystem) and `br_netfilter` (iptables sees bridged traffic) kernel modules, persisted to `/etc/modules-load.d/`
- Sets sysctl params in `/etc/sysctl.d/99-k8s.conf`: `bridge-nf-call-iptables`, `bridge-nf-call-ip6tables`, `ip_forward`
- Installs `socat`, `conntrack`, `ebtables`

---

**`tasks/containerd.yml`** — tag: `containerd`

- Installs `containerd` from Ubuntu's apt repos
- Generates default config (`containerd config default`) on first run, guarded by a `stat` check
- Sets `SystemdCgroup = true` — mismatched cgroup drivers cause node instability; systemd must manage cgroups consistently
- Flushes the `Restart containerd` handler immediately so containerd is ready before kubelet install

---

**`tasks/k8s_packages.yml`** — tag: `k8s_packages`

- Adds the `pkgs.k8s.io` signing key (GPG dearmor into `/etc/apt/keyrings/`), guarded by `stat` — only runs once
- Adds the apt repo pinned to `k8s_version` minor version
- Installs `kubelet`, `kubeadm`, `kubectl`
- Holds all three via `dpkg_selections` — prevents `apt upgrade` from bumping k8s without a controlled drain-and-upgrade

---

**`tasks/kubeadm_init.yml`** — tag: `kubeadm`

Gated on whether `/etc/kubernetes/admin.conf` already exists — safe to re-run on an initialized cluster.

- Templates `kubeadm-config.j2` → `/tmp/kubeadm-config.yaml`, runs `kubeadm init --config`, cleans up the temp file in an `always` block
- Copies `admin.conf` to `/home/ubuntu/.kube/config`
- Removes the `node-role.kubernetes.io/control-plane` taint — required on single-node clusters so workloads can schedule on the control plane node
- Fetches kubeconfig to `~/.kube/casshome.conf` on the Ansible controller (your laptop)

---

**`tasks/helm.yml`** — tag: `helm`

Checks if `helm` is installed; runs the official `get-helm-3` script if not. Idempotent. Helm is installed at this stage (before CNI) because Calico is deployed via Helm.

---

**`tasks/cni.yml`** — tag: `cni`

Replaces Flannel with **Calico** as the CNI. Calico enforces `NetworkPolicy` objects — Flannel does not.

Migration path (safe on existing clusters):
1. Deletes the Flannel DaemonSet (`failed_when: false` — no-ops if already gone)
2. Removes `/etc/cni/net.d/10-flannel.conflist` from the node, triggers `Restart kubelet` handler
3. Adds the Calico Tigera operator Helm repo
4. Installs Calico via `helm upgrade --install` with `IPIP` encapsulation on the `k8s_pod_cidr`
5. Waits for `calico-node` DaemonSet to be ready
6. Waits for the node to reach `Ready`

---

**`tasks/ingress.yml`** — tag: `ingress`

Installs NGINX Ingress Controller via Helm with `type=NodePort`. HTTP is pinned to `k8s_ingress_http_nodeport` (32018). Waits for the controller deployment to reach `Available`.

---

**`tasks/kubectl_config.yml`** — tag: `kubectl_config`

Sets up kubectl shell aliases and autocompletion for the `ubuntu` user on the node.

---

### `roles/wireguard/`

Host-level prerequisites for running WireGuard on a gateway node. Applied by `wireguard.yml` against the `gateway` group — not part of the `k8s` role, so it doesn't run on every k8s node.

**`tasks/main.yml`:**
- Installs `wireguard-tools`
- Loads the `wireguard` kernel module via `modprobe`, persists it to `/etc/modules-load.d/wireguard.conf`
- Enables `net.ipv4.ip_forward` via sysctl — required for NAT/masquerade so VPN clients can route traffic through the tunnel

---

### `roles/duckdns/`

Keeps `kaloscasshome.duckdns.org` pointed at the home public IP. Runs a cron job on the k8s node every 5 minutes.

**`defaults/main.yml`:** `duckdns_dir: /opt/duckdns`

**`templates/duck.sh.j2`:** Single-line curl call to the DuckDNS API. Leaves the `ip=` parameter empty so DuckDNS auto-detects the public IP from the outbound request. Writes `OK` or `KO` to `duck.log`.

**`tasks/main.yml`:**
1. Creates `/opt/duckdns/` (mode 755)
2. Templates `duck.sh` (mode 700 — token is in the file, others shouldn't read it)
3. Adds a cron job under root: `*/5 * * * *`, identified by name `duckdns_update` so Ansible can find and update it without duplicating
4. Runs the script immediately so the DNS record is updated on first deploy

**Verify it's working:**
```bash
ssh k8s-node-01 "cat /opt/duckdns/duck.log"   # should print OK
dig kaloscasshome.duckdns.org +short           # should match your public IP
```

---

## `k8s/`

Kubernetes manifests for workloads. Each app is a subdirectory. Plain `.yml` files are applied directly; `.j2` files are Jinja2 templates rendered by Ansible at deploy time (they reference `group_vars`).

Deployed via `media-stack.yml` or `wireguard.yml` playbooks, not `site.yml`. Requires the cluster to be up first.

---

### The `media` namespace

All media services — Jellyfin, Lidarr, Prowlarr, and qBittorrent — share the `media` namespace. This is intentional:

- **Shared storage:** qBittorrent and Lidarr mount the same `media-downloads-pvc`. In k8s, a PVC can only be shared by pods on the same node, and `ReadWriteOnce` is enforced per-node (not per-pod), so both pods can mount it simultaneously on a single-node cluster.
- **Internal DNS:** Services within the same namespace are reachable by short name (`http://qbittorrent:8080`). Across namespaces you need the full DNS form (`http://qbittorrent.media.svc.cluster.local:8080`). Keeping everything in one namespace is simpler for UI wiring.
- **Unified deployment:** A single `media-stack.yml` playbook deploys and upgrades the whole stack atomically.

---

### How files are downloaded, moved, and served

This documents the full lifecycle of a piece of music from request to playback.

```
┌─────────────────────────────────────────────────────────────────────┐
│  You                                                                │
│    │  1. Search for artist in Lidarr UI                            │
│    │     → Lidarr queries Prowlarr                                 │
│    ▼                                                                │
│  Prowlarr (pod, port 9696)                                          │
│    │  2. Queries configured indexers (torrent trackers over HTTPS)  │
│    │     → Returns list of matching .torrent results               │
│    ▼                                                                │
│  Lidarr (pod, port 8686)                                            │
│    │  3. Picks best result, sends download request to qBittorrent  │
│    │     via HTTP API (http://qbittorrent:8080)                    │
│    ▼                                                                │
│  qBittorrent (pod, port 8080)                                       │
│    │  4. Downloads the torrent from peers (internet, via node IP)  │
│    │     Writes completed files to /downloads  (PVC mount)         │
│    │       = /mnt/downloads on the node                            │
│    ▼                                                                │
│  Lidarr (monitors /downloads via shared PVC)                        │
│    │  5. Detects completed download, matches to the expected album  │
│    │     Renames/organises: Artist/Album/Track.flac                │
│    │     Moves files from /downloads → /music  (PVC mount)         │
│    │       = /mnt/media/music on the node                          │
│    ▼                                                                │
│  Jellyfin (pod, port 8096)                                          │
│    │  6. Periodic library scan picks up new files in /media/music  │
│    │       = /mnt/media/music on the node (same hostPath)          │
│    │     Fetches metadata, artwork from MusicBrainz/MusicBrainz    │
│    ▼                                                                │
│  You                                                                │
│       7. Stream via http://192.168.1.20:32018/jellyfin             │
└─────────────────────────────────────────────────────────────────────┘
```

**Why the shared PVC works:**

Both qBittorrent and Lidarr mount `media-downloads-pvc` at `/downloads` inside their respective containers. This PVC maps to `/mnt/downloads` on the node via a hostPath PV. Because both pods run on the same node, they see the same directory. Lidarr does not need to copy files — when it "moves" a file from `/downloads` to `/music`, it is doing a rename across the same filesystem (hostPath directories on the same node), which is an atomic `rename(2)` syscall. No data is duplicated.

**Why Jellyfin can see the music Lidarr writes:**

Lidarr mounts `media-music-pvc` → `/mnt/media/music` on the node → appears as `/music` inside the Lidarr pod. Jellyfin mounts `jellyfin-media-pvc` → `/mnt/media` on the node → appears as `/media` inside the Jellyfin pod. `/mnt/media/music` is a subdirectory of `/mnt/media`, so Jellyfin sees it at `/media/music`. Both PVCs point to different directories but they overlap on the host filesystem — no data is duplicated.

**Who writes what, and where:**

| Writer | Writes to (in-pod) | Host path | Reader | Reads from (in-pod) |
|---|---|---|---|---|
| qBittorrent | `/downloads` | `/mnt/downloads` | Lidarr | `/downloads` |
| Lidarr | `/music` | `/mnt/media/music` | Jellyfin | `/media/music` |
| Lidarr | `/config` | `/opt/lidarr/config` | — | — |
| qBittorrent | `/config` | `/opt/qbittorrent/config` | — | — |
| Prowlarr | `/config` | `/opt/prowlarr/config` | — | — |
| Jellyfin | `/config` | `/opt/jellyfin/config` | — | — |

**All data directories use `Retain` policy.** Deleting a PVC or pod never deletes the data on disk. Re-creating the PVC and pod picks up exactly where it left off.

---

### `k8s/media/`

Storage and automation services (qBittorrent, Prowlarr, Lidarr) for the `media` namespace. Deployed by `media-stack.yml`.

| File | Purpose |
|---|---|
| `00-namespace.yml` | `media` namespace — shared by all media services including Jellyfin |
| `01-storage.yml` | PVs and PVCs for the automation stack: shared downloads (200Gi → `/mnt/downloads`), music library (500Gi → `/mnt/media/music`), and per-app config volumes for qBittorrent (1Gi), Prowlarr (1Gi), and Lidarr (2Gi) |
| `02-qbittorrent.yml.j2` | qBittorrent deployment. Image: `lscr.io/linuxserver/qbittorrent`. PUID/PGID=1000 (matches `ubuntu` user on node). Mounts config + shared downloads at `/downloads`. |
| `03-prowlarr.yml.j2` | Prowlarr deployment. Image: `lscr.io/linuxserver/prowlarr`. Mounts config only — Prowlarr talks to external indexers over HTTPS, needs no local media access. |
| `04-lidarr.yml.j2` | Lidarr deployment. Image: `lscr.io/linuxserver/lidarr`. Mounts config + shared downloads at `/downloads` + music library at `/music`. |
| `05-services.yml` | NodePort Services for the three automation apps. |

### `k8s/jellyfin/`

Jellyfin media server. Lives in the `media` namespace alongside the automation stack. Deployed by `media-stack.yml` (not `jellyfin.yml`, which is deprecated).

| File | Purpose |
|---|---|
| `00-namespace.yml` | Unused — `media` namespace is created by `k8s/media/00-namespace.yml`. Kept for reference. |
| `00-storage.yml` | Two hostPath PVs: `jellyfin-config-pv` (5Gi → `/opt/jellyfin/config`) and `jellyfin-media-pv` (500Gi → `/mnt/media`). Both bind to PVCs in the `media` namespace. |
| `01-deployment.yml.j2` | Jellyfin deployment. Templates `JELLYFIN_PublishedServerUrl` from `k8s_node_ip` and `k8s_ingress_http_nodeport`. Init container pre-seeds `network.xml` to set `BaseUrl=/jellyfin`. Mounts config (rw) and media (ro). |
| `02-service.yml` | ClusterIP service on port 8096 — accessed via NGINX Ingress, not directly. |
| `03-ingress.yml` | NGINX Ingress rule: path `/jellyfin` → jellyfin service:8096. Long proxy timeouts for streaming. |
| `04-networkconfig.yml` | ConfigMap: `network.xml` setting `BaseUrl=/jellyfin` and disabling HTTPS (TLS terminated at ingress). |

Access over VPN: `http://192.168.1.20:32018/jellyfin`

### `k8s/wireguard/`

WireGuard VPN server. Uses `hostNetwork: true` — the pod shares the node's network namespace, binding WireGuard directly to UDP 51820 on the node without involving the k8s CNI networking stack.

| File | Purpose |
|---|---|
| `00-namespace.yml` | `wireguard` namespace |
| `01-storage.yml` | hostPath PV at `/opt/wireguard/config` (100Mi, `Retain`) for the container's runtime state |
| `02-deployment.yml.j2` | WireGuard deployment. `hostNetwork: true`. Image: `lscr.io/linuxserver/wireguard`. Capabilities: `NET_ADMIN`, `SYS_MODULE`. Mounts the `wireguard-config` Secret at `/config/wg_confs/wg0.conf` via subPath (read-only). Note: subPath mounts do not hot-reload when the Secret changes — a rollout restart is always required. |
| `03-service.yml` | ClusterIP for internal cluster access (UDP 51820) |
| `04-networkpolicy.yml` | Egress policy: allows DNS (UDP/TCP 53) and egress to the `jellyfin` namespace. **No-op with Calico in its current default config** — requires a HostEndpoint policy to take effect on host-networked pods. Kept as-is for future hardening. |
| ~~`05-configmap.yml`~~ | Removed — WireGuard keys are never written to a file. The `wireguard.yml` playbook creates a k8s Secret inline using `lookup('env', ...)`, so keys exist only in `.env.nu` and in the cluster Secret. |

**Adding a new VPN peer:**

**1. Generate keys for the new peer** (run locally, never on the server):
```nu
let priv = (wg genkey)
let pub = ($priv | wg pubkey)
let psk = (wg genpsk)
echo $"private: ($priv)\npublic:  ($pub)\npsk:     ($psk)"
```

**2. Add peer vars to `.env.nu`** (use the next available peer number, e.g. `PEER2`):
```nu
$env.WG_PEER2_PUBLIC_KEY    = "<pub from step 1>"
$env.WG_PEER2_PRESHARED_KEY = "<psk from step 1>"
```
Add corresponding placeholder lines to `.env.example.nu`.

**3. Add a `[Peer]` block to the inline Secret in `ansible/playbooks/wireguard.yml`:**
```yaml
              [Peer]
              # peer2
              PublicKey = {{ lookup('env', 'WG_PEER2_PUBLIC_KEY') }}
              PresharedKey = {{ lookup('env', 'WG_PEER2_PRESHARED_KEY') }}
              AllowedIPs = 10.13.13.<N>/32
```

**4. Re-run the playbook and restart the pod:**
```bash
source ~/.env.nu
ansible-playbook playbooks/wireguard.yml -i inventory/hosts.yml
kubectl rollout restart deployment/wireguard -n wireguard
```

The subPath mount does not hot-reload — the rollout restart is mandatory.

**5. Get the server public key** (needed for the client config):
```nu
$env.WG_SERVER_PRIVATE_KEY | wg pubkey
```

**6. Distribute this client config to the new device:**
```ini
[Interface]
Address = 10.13.13.<N>/32
PrivateKey = <peer private key from step 1>
DNS = 1.1.1.1

[Peer]
PublicKey = <server public key from step 5>
PresharedKey = <psk from step 1>
Endpoint = kaloscasshome.duckdns.org:51820
AllowedIPs = 0.0.0.0/0
```

Delete the peer private key from local storage once it's on the device — it should only exist there.

**DNS note:** Use `1.1.1.1` (or any public resolver) — not `10.13.13.1`. CoreDNS is disabled in this setup; nothing is listening on port 53 at the WireGuard server IP.

---

## Running everything

Playbooks are grouped by concern and must be run in order. Each playbook is idempotent — safe to re-run.

```
Terraform          →  site.yml          →  duckdns.yml      →  wireguard.yml    →  media-stack.yml
(provision VM)        (k8s nodes)          (gateway only)      (gateway + k8s)     (all media workloads)
```

---

### 1. Provision the VM

```nu
source .env.nu   # sets TF_VAR_proxmox_api_token, picked up by Terraform automatically
```

```bash
cd terraform
terraform init      # first time only — downloads the bpg/proxmox provider
terraform plan
terraform apply
```

After apply: VM is at `192.168.1.20`, user `ubuntu`, SSH key injected.

---

### 2. Configure k8s nodes

Targets the `k8s` group. Installs the OS baseline, container runtime, and full Kubernetes stack.

```bash
cd ansible
ansible-playbook playbooks/site.yml -i inventory/hosts.yml
```

Run specific stages only:

```bash
ansible-playbook playbooks/site.yml -i inventory/hosts.yml --tags prereqs        # kernel modules, sysctl, packages
ansible-playbook playbooks/site.yml -i inventory/hosts.yml --tags containerd     # container runtime
ansible-playbook playbooks/site.yml -i inventory/hosts.yml --tags k8s_packages   # kubelet, kubeadm, kubectl
ansible-playbook playbooks/site.yml -i inventory/hosts.yml --tags kubeadm        # cluster init (skips if already done)
ansible-playbook playbooks/site.yml -i inventory/hosts.yml --tags helm           # Helm
ansible-playbook playbooks/site.yml -i inventory/hosts.yml --tags cni            # Calico CNI
ansible-playbook playbooks/site.yml -i inventory/hosts.yml --tags ingress        # NGINX Ingress Controller
```

---

### 3. Configure the gateway node

Targets the `gateway` group. Must run after `site.yml` — the k8s cluster must exist before WireGuard manifests are applied.

```bash
cd ansible

# DuckDNS: installs the cron updater that keeps kaloscasshome.duckdns.org → home public IP
ansible-playbook playbooks/duckdns.yml -i inventory/hosts.yml

# WireGuard: loads the kernel module on the gateway node, then deploys the VPN pod to k8s
ansible-playbook playbooks/wireguard.yml -i inventory/hosts.yml
```

`duckdns.yml` and `wireguard.yml` can be run in either order, but both require `site.yml` to have completed first.

After completion: VPN is reachable at `kaloscasshome.duckdns.org:51820`. Import a peer config into your WireGuard client and connect.

---

### 4. Deploy workloads

The media stack deploys all media services — Jellyfin, Lidarr, Prowlarr, and qBittorrent — as a single unit. It also creates the required host directories on the k8s nodes.

```bash
cd ansible
ansible-playbook playbooks/media-stack.yml -i inventory/hosts.yml
```

**One-time UI wiring after first deploy:**
1. **qBittorrent** (`http://192.168.1.20:32080`): change default password (`admin`/`adminadmin`); set save path to `/downloads`
2. **Prowlarr** (`http://192.168.1.20:32696`): add indexers; Settings → Apps → Add Lidarr (`http://lidarr:8686`, API key from Lidarr Settings → General)
3. **Lidarr** (`http://192.168.1.20:32686`): Settings → Download Clients → add qBittorrent (`http://qbittorrent:8080`); Settings → Media Management → Root Folder `/music`; search for an artist to start downloading
4. **Jellyfin** (`http://192.168.1.20:32018/jellyfin`): Dashboard → Libraries → Add Music library → folder `/media/music`

---

### 5. Full run from scratch

```bash
cd terraform && terraform apply

cd ../ansible
ansible-playbook playbooks/site.yml        -i inventory/hosts.yml
ansible-playbook playbooks/duckdns.yml     -i inventory/hosts.yml
ansible-playbook playbooks/wireguard.yml   -i inventory/hosts.yml
ansible-playbook playbooks/media-stack.yml -i inventory/hosts.yml
```

---

## Connecting to the cluster

All external access goes through WireGuard. There is no direct SSH or HTTP exposure to the internet.

### Connect via VPN

1. Install the WireGuard app (iOS, Android, macOS, Windows)
2. Import your peer `.conf` file
3. Activate the tunnel

### Verify the tunnel

```bash
ping 10.13.13.1                  # VPN server — must respond before anything else works
curl -s https://ifconfig.me      # should return your home public IP
ssh -i ~/.ssh/casshome ubuntu@192.168.1.20
```

### Access services over VPN

| Service | URL |
|---|---|
| k8s node SSH | `ssh -i ~/.ssh/casshome ubuntu@192.168.1.20` |
| Jellyfin | `http://192.168.1.20:32018/jellyfin` |
| qBittorrent | `http://192.168.1.20:32080` |
| Prowlarr | `http://192.168.1.20:32696` |
| Lidarr | `http://192.168.1.20:32686` |
