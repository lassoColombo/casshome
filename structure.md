# Repository Structure

This document explains every file in this repo, what it does, and why it exists.

---

## Big Picture

The repo is split into two tools with distinct responsibilities:

```
Terraform  →  talks to Proxmox API  →  creates the VM
Ansible    →  talks to the VM via SSH  →  installs software inside it
```

Terraform doesn't touch software. Ansible doesn't touch infrastructure. Each does one job.

---

## Prerequisites

These are one-time setup steps that must be completed before running Terraform or Ansible.

### 0. Enable Intel VT-x in BIOS (HP Z440)

The HP Z440's BIOS ships with Intel VT-x disabled. Proxmox requires it to run KVM virtual machines.

1. Reboot pve1
2. Press **F10** at the HP splash screen to enter BIOS Setup
3. Navigate to **Security → System Security**
4. Set **Intel Virtualization Technology (VT-x)** → Enabled
5. Set **Intel VT for Directed I/O (VT-d)** → Enabled (while you're there)
6. F10 to save and exit

Verify after reboot: `grep -c vmx /proc/cpuinfo` should return > 0.

### 1. Install local tooling

```bash
brew install ansible terraform
ansible-galaxy collection install ansible.posix community.general
```

`ansible.posix` provides the `authorized_key` and `sysctl` modules. `community.general` provides `modprobe` and `timezone`.

### 2. SSH key

The key pair used for this homelab is `~/.ssh/casshome` (ed25519). The public key `~/.ssh/casshome.pub` is injected into VMs via Terraform cloud-init and into the Proxmox root account via Ansible.

If you need to regenerate it:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/casshome -C "lasso.colombo@gmail.com"
```

### 3. Bootstrap SSH key onto Proxmox

While password auth is still enabled on pve1, copy the key:
```bash
ssh-copy-id -i ~/.ssh/casshome.pub root@192.168.1.10
```

After this you can SSH without a password: `ssh -i ~/.ssh/casshome root@192.168.1.10`

### 4. Harden Proxmox SSH

Once the key is in place, run the hardening playbook to disable password auth:
```bash
cd ansible
ansible-playbook playbooks/harden_proxmox.yml
```

This writes `/etc/ssh/sshd_config.d/99-hardened.conf` on pve1 and restarts sshd. After this, password login is disabled — key only.

### 5. Create Proxmox API token for Terraform

SSH into pve1 and run:
```bash
pveum user add terraform@pve --comment "Terraform automation"
pveum aclmod / -user terraform@pve -role Administrator
pveum user token add terraform@pve terraform --privsep=0
```

The last command outputs a token secret (UUID). Save it — it's only shown once.

Token format used in `terraform.tfvars`: `terraform@pve!terraform=<uuid>`

### 6. Create `terraform.tfvars`

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Fill in `proxmox_api_token` with the value from step 5. The `ssh_public_key` is already set to the `casshome` key value in the example. Adjust `vm_ip` and `gateway` if your network differs from `192.168.1.x`.

---

## Top-level files

### `.gitignore`
Prevents secrets and generated files from being committed:
- `terraform/terraform.tfvars` — your actual secrets (API token, SSH key)
- `terraform/.terraform/` — downloaded provider binaries (100MB+, not yours)
- `terraform/*.tfstate*` — Terraform's live record of what it created (contains sensitive data)
- `ansible/vault_pass` — Ansible Vault password file (if used later)

### `CLAUDE.md`
Instructions for Claude Code when working in this repo. Contains commands, architecture notes, and context about the infrastructure.

---

## `terraform/`

Terraform provisions the VM on Proxmox. It talks to the Proxmox HTTP API — no SSH involved at this stage.

### `versions.tf`
Declares which version of Terraform and which providers are required.

```hcl
required_providers {
  proxmox = {
    source  = "bpg/proxmox"
    version = "~> 0.73"
  }
}
```

We use the `bpg/proxmox` provider (not the older `Telmate/proxmox`). It's more actively maintained, supports cloud-init natively, and has better resource coverage. The `~> 0.73` constraint allows patch updates but not breaking minor version bumps.

### `variables.tf`
Defines all inputs to the Terraform configuration. None of the actual values live here — just the declarations, types, descriptions, and safe defaults.

| Variable | Default | Purpose |
|---|---|---|
| `proxmox_endpoint` | `https://192.168.1.10:8006` | Proxmox API URL |
| `proxmox_api_token` | _(none, required)_ | Proxmox API token — sensitive |
| `vm_ip` | `192.168.1.20` | Static IP for the k8s VM |
| `gateway` | `192.168.1.1` | Router/gateway IP |
| `ssh_public_key` | _(none, required)_ | Your public key, injected into the VM |

### `terraform.tfvars.example`
A template showing what `terraform.tfvars` should look like. Copy it:
```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# then fill in your real values
```
`terraform.tfvars` is gitignored. Never commit it.

### `main.tf`
The heart of Terraform. Contains two resources:

**Resource 1 — `proxmox_virtual_environment_download_file`**

Downloads the Ubuntu 24.04 LTS cloud image from Canonical's servers and stores it on the Proxmox node in the `local` datastore (the `/var/lib/vz/template/iso/` directory on pve1). This is a raw disk image (`.img`), not an ISO — Proxmox treats it as an "ISO" for storage purposes, but it's actually a pre-installed Ubuntu system image designed for cloud/VM use.

This resource is idempotent: if the file already exists on Proxmox, Terraform won't re-download it.

**Resource 2 — `proxmox_virtual_environment_vm`**

Creates the actual VM. Key decisions explained:

- **`vm_id = 100`** — Proxmox VM ID. Must be unique across the node. 100 is the conventional starting point.
- **`cpu type = "x86-64-v2-AES"`** — Exposes modern CPU features to the guest. Better than `kvm64` (generic) because the Xeon E5-1620 v3 supports it, and it gives better performance for crypto operations (which k8s uses heavily for TLS).
- **`disk.discard = "on"` + `iothread = true`** — `discard` enables TRIM so deleted blocks are freed on the LVM thin pool. `iothread` gives the disk its own IO thread for better performance.
- **`initialization` block (cloud-init)** — This is how the VM gets configured on first boot without any manual interaction. It sets:
  - Static IP and gateway on the network interface
  - A user named `ubuntu` with your SSH public key (no password)
  - DNS servers (Cloudflare + Google)
- **`agent.enabled = true`** — Tells Proxmox to communicate with the QEMU guest agent running inside the VM. This is why `qemu-guest-agent` is installed by the `common` Ansible role — without it, Proxmox can't query the VM's IP or do clean shutdowns.
- **`on_boot = true`** — VM automatically starts when the Proxmox host boots.

### `outputs.tf`
Prints useful information after `terraform apply` completes:
- The VM's IP address
- The Proxmox VM ID
- The exact SSH command to connect

---

## `ansible/`

Ansible runs commands inside the VM over SSH. It's split into inventory (who to connect to), playbooks (what to run), and roles (reusable groups of tasks).

### `ansible.cfg`
Configuration that applies to all Ansible commands run from the `ansible/` directory:
- Points to the YAML inventory file
- Sets `ubuntu` as the default SSH user for all VMs (overridden per host for pve1)
- Uses `~/.ssh/casshome` as the key — make sure this matches what you put in `terraform.tfvars`
- Disables host key checking so the first connection to a new VM doesn't prompt
- Sets `stdout_callback = yaml` for cleaner output

### `inventory/hosts.yml`
Defines two host groups:

```yaml
proxmox:       # the Proxmox node itself
  pve1: 192.168.1.10  (ansible_user: root)

k8s:           # VMs managed as k8s nodes
  k8s-node-01: 192.168.1.20
```

The `proxmox` group uses `root` because that's the only user on a fresh Proxmox install. The `k8s` group uses the default `ubuntu` user (from `ansible.cfg`).

### `group_vars/all.yml`
Variables that apply to every host in every group. Currently just:
```yaml
timezone: UTC
```
Add shared variables here as the homelab grows.

---

## `ansible/playbooks/`

### `harden_proxmox.yml`
Targets the `proxmox` group (pve1 at 192.168.1.10). Two tasks:

1. **Install SSH public key** — writes `~/.ssh/casshome.pub` into `/root/.ssh/authorized_keys` on pve1. After this, you can SSH without a password.
2. **Drop hardened sshd config** — writes `/etc/ssh/sshd_config.d/99-hardened.conf` with:
   - `PasswordAuthentication no` — no more logging in with the root password
   - `PermitRootLogin prohibit-password` — root can still log in, but only with a key
   - `PubkeyAuthentication yes` — explicitly ensures key auth is on

The config goes in `sshd_config.d/` (a drop-in directory) rather than editing the main `sshd_config` directly — this avoids conflicts with Proxmox's own SSH config and survives upgrades.

A handler restarts sshd only if the config file actually changed.

**Important**: run `ssh-copy-id root@192.168.1.10` manually before running this playbook. Once the playbook disables password auth, you can only get in via key.

### `site.yml`
The main playbook for the k8s VM. Runs the `common` role then the `k8s` role against all hosts in the `k8s` group.

---

## `ansible/roles/`

Roles are reusable units. Each role is a directory with a standard structure. Playbooks call roles by name.

### `roles/common/`

**`tasks/main.yml`** — Runs on any managed VM. Handles baseline OS setup:

1. **`apt update` + `upgrade dist`** — Full system upgrade on first run. `cache_valid_time: 3600` means it won't re-fetch the apt cache if it was updated less than an hour ago (makes reruns faster).
2. **Install base packages** — `curl`, `git`, `vim`, `apt-transport-https`, `ca-certificates`, `gnupg` (needed to add the k8s apt repo), `qemu-guest-agent` (needed for Proxmox to communicate with the VM).
3. **Enable qemu-guest-agent** — Starts the service so Proxmox can see the VM is alive.
4. **Set timezone** — Uses the `timezone` variable from `group_vars/all.yml` (UTC).
5. **Disable swap** — Kubernetes requires swap to be off. `swapoff -a` disables it immediately; the `fstab` edit makes it permanent across reboots by commenting out the swap line.

### `roles/k8s/`

**`defaults/main.yml`** — Default values for the role, easily overridden:
```yaml
k8s_version: "1.32"       # Kubernetes minor version (controls which apt repo to use)
k8s_pod_cidr: "10.244.0.0/16"  # Pod IP range (must match Flannel's default)
k8s_node_ip: "192.168.1.20"    # The VM's IP (used in kubeadm init)
```

**`tasks/main.yml`** — Installs and initializes Kubernetes. Walk-through:

**Section 1: Kernel modules**
- `overlay` — required by containerd for the overlay filesystem (how container layers work)
- `br_netfilter` — required for iptables to see bridged traffic (how k8s networking works)
- `persistent: present` — adds them to `/etc/modules-load.d/` so they load on reboot

**Section 2: Sysctl**
Three networking parameters required by Kubernetes:
- `net.bridge.bridge-nf-call-iptables` / `ip6tables` — makes iptables rules apply to bridged packets
- `net.ipv4.ip_forward` — allows the kernel to forward packets between interfaces (essential for pod-to-pod routing)

Written to `/etc/sysctl.d/99-k8s.conf` so they persist across reboots.

**Section 3: containerd**
containerd is the container runtime — the component that actually runs containers. Kubernetes talks to it via the CRI (Container Runtime Interface).

- Installs `containerd` from Ubuntu's apt repos
- Generates the default config (`containerd config default > /etc/containerd/config.toml`)
- **Critical fix**: sets `SystemdCgroup = true`. By default, containerd uses its own cgroup driver. Kubernetes uses systemd's. If they disagree on cgroup management, the node will become unstable. This line makes them consistent.

**Section 4: Kubernetes apt repo**
Kubernetes isn't in Ubuntu's default apt repos. This section:
1. Downloads the official Kubernetes signing key and stores it as a GPG keyring
2. Adds the `pkgs.k8s.io` apt repository pinned to `v1.32`
3. Installs `kubelet` (the per-node agent), `kubeadm` (the init tool), `kubectl` (the CLI)
4. **Holds** all three packages — prevents `apt upgrade` from accidentally upgrading k8s out from under you. k8s upgrades require a controlled drain/upgrade process.

**Section 5: kubeadm init**
- Checks if `/etc/kubernetes/admin.conf` already exists to avoid re-initializing on rerun
- Runs `kubeadm init` with:
  - `--pod-network-cidr=10.244.0.0/16` — the IP range for pods; must match Flannel's config
  - `--apiserver-advertise-address=192.168.1.20` — tells the API server which IP to listen on

**Section 6: kubeconfig**
After init, only `root` can use kubectl. This section copies `/etc/kubernetes/admin.conf` to `/home/ubuntu/.kube/config` so the `ubuntu` user can run `kubectl` without sudo.

**Section 7: Flannel CNI**
Kubernetes creates pods but doesn't handle pod-to-pod networking itself — that's the CNI plugin's job. Flannel is a simple overlay network that works well for single-node setups. Applied via `kubectl apply`.

**Section 8: Untaint control-plane**
By default, k8s marks the control-plane node with a taint that prevents regular workloads from scheduling on it (designed for multi-node clusters where you don't want your app pods on the same node as etcd and the API server). On a single-node setup, we remove this taint so we can actually run workloads.

**Section 9: Fetch kubeconfig**
Copies the kubeconfig from the VM to `~/.kube/casshome-k8s.yaml` on your local machine. After this you can run `kubectl --kubeconfig ~/.kube/casshome-k8s.yaml get nodes` from your laptop.
