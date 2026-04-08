# Prerequisites

One-time setup steps before running Terraform or Ansible. Follow these in order on a fresh machine.

---

## 0. Enable Intel VT-x in BIOS (HP Z440)

The HP Z440 ships with VT-x disabled. Proxmox requires it for KVM hardware virtualization.

1. Reboot `pve1`, press **F10** at the HP splash screen to enter BIOS Setup
2. Navigate to **Security → System Security**
3. Enable **Intel Virtualization Technology (VT-x)** and **VT-d**
4. Press **F10** to save and exit

Verify after boot: `grep -c vmx /proc/cpuinfo` should return `> 0`.

---

## 1. Install local tooling

```bash
brew install uv terraform gettext
```

- `uv` — Python dependency manager; runs Ansible in a strictly pinned isolated environment
- `terraform` — provisions the VM on Proxmox
- `gettext` — provides `envsubst` (used internally by some templates)

Then install Ansible and its Python dependencies:

```bash
cd ansible
uv sync
```

Then install the required Ansible collections (one-time):

```bash
uv run ansible-galaxy collection install ansible.posix community.general kubernetes.core
```

| Collection | Provides |
|---|---|
| `ansible.posix` | `authorized_key`, `sysctl` modules |
| `community.general` | `modprobe`, `timezone`, `cron` modules |
| `kubernetes.core` | `k8s` module used by all workload deployment tasks |

---

## 2. Generate the homelab SSH key pair

```bash
ssh-keygen -t ed25519 -f ~/.ssh/casshome
```

This key pair is used for:
- SSH access to `pve1` (Proxmox host) during initial bootstrap
- SSH access to `k8s-node-01` (injected via Terraform cloud-init)
- Ansible connections to all managed hosts

---

## 3. Bootstrap the SSH key onto Proxmox

Before Ansible can manage `pve1`, the key must be copied there manually:

```bash
ssh-copy-id -i ~/.ssh/casshome.pub root@192.168.1.10
```

Verify: `ssh -i ~/.ssh/casshome root@192.168.1.10`

---

## 4. Create Proxmox API token for Terraform

SSH into `pve1` and run:

```bash
pveum user add terraform@pve
pveum aclmod / -user terraform@pve -role Administrator
pveum user token add terraform@pve terraform --privsep=0
```

The token value is shown **once** in the output. Save it immediately — you cannot retrieve it again. It goes into `.env.nu` as shown below.

---

## 5. Create Proxmox API token for the PVE exporter

The observability stack scrapes Proxmox metrics via a dedicated read-only token:

```bash
pveum user add prom-exporter@pve
pveum aclmod / -user prom-exporter@pve -role PVEAuditor
pveum user token add prom-exporter@pve pve-exporter --privsep=0
```

Save the token value for `.env.nu`.

---

## 6. Set up `.env.nu`

All secrets live in `.env.nu` at the repo root (gitignored). Copy the template and fill in values:

```bash
cp .env.example.nu .env.nu
```

Then edit `.env.nu` with the values you collected above:

| Variable | Purpose | Where to get it |
|---|---|---|
| `TF_VAR_proxmox_api_token` | Proxmox API token for Terraform | Step 4 above |
| `DUCKDNS_TOKEN` | DuckDNS update token | [duckdns.org](https://www.duckdns.org) dashboard |
| `WG_SERVER_PRIVATE_KEY` | WireGuard server private key | `wg genkey` |
| `WG_PEER1_PUBLIC_KEY` | WireGuard peer 1 public key | `echo $priv \| wg pubkey` |
| `WG_PEER1_PRESHARED_KEY` | WireGuard peer 1 preshared key | `wg genpsk` |
| `ARR_API_KEY` | Shared API key for Prowlarr + Lidarr | Any random 32-char hex string |
| `PVE_EXPORTER_TOKEN` | Proxmox API token for observability exporter | Step 5 above |

Generating WireGuard keys (run locally, requires `wireguard-tools`):

```bash
# macOS
brew install wireguard-tools

priv=$(wg genkey)
pub=$(echo "$priv" | wg pubkey)
psk=$(wg genpsk)
echo "private: $priv"
echo "public:  $pub"
echo "psk:     $psk"
```

The server private key goes in `WG_SERVER_PRIVATE_KEY`. The peer public and preshared keys go in `WG_PEER1_PUBLIC_KEY` / `WG_PEER1_PRESHARED_KEY`. The peer's private key is used only in the peer's WireGuard client config — it never enters the repo.

---

## 7. Configure router port forwarding

The WireGuard VPN pod needs UDP port 51820 forwarded from the internet to the VM:

- **Router**: navigate to **Firewall → Port Forwarding** (not the "WireGuard" section, which configures the router's own built-in VPN — that is a different thing)
- **Protocol**: UDP
- **External port**: 51820
- **Internal IP**: `192.168.1.20` (the VM's LAN IP)
- **Internal port**: 51820

---

## Next step

[Installation](installation.md) — provision the VM and deploy the full stack.
