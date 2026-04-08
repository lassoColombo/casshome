# Installation

End-to-end first-deploy guide. Complete [Prerequisites](prerequisites.md) first.

---

## 1. Clone the repo

```bash
git clone <repo-url> casshome
cd casshome
```

---

## 2. Load secrets

```bash
source .env.nu
```

This must be done in every terminal session before running Terraform or Ansible. All secret values are read from environment variables at runtime — nothing is stored in the repo.

---

## 3. Provision the VM with Terraform

```bash
cd terraform
terraform init
terraform apply
```

This:
- Downloads the Ubuntu 24.04 cloud image to Proxmox local storage (idempotent)
- Creates the VM (`k8s-node-01`) with a static IP of `192.168.1.20`
- Injects the `~/.ssh/casshome.pub` key and creates the `ubuntu` user via cloud-init
- Enables the QEMU guest agent

After `terraform apply` succeeds, wait ~60 seconds for cloud-init to finish and the VM to come up before proceeding.

Verify:

```bash
ssh -i ~/.ssh/casshome ubuntu@192.168.1.20
```

---

## 4. Run Ansible

```bash
cd ../ansible
uv run ansible-playbook playbooks/site.yml
```

This runs the full stack in order:

1. **Proxmox layer** — SSH hardening + NIC configuration on `pve1`
2. **Kubernetes layer** — OS baseline, containerd, kubeadm cluster bootstrap, Flannel CNI, NGINX Ingress on `k8s-node-01`
3. **Network layer** — DuckDNS cron + WireGuard VPN (host prereqs + K8s pod)
4. **Apps layer** — Media stack (qBittorrent, Prowlarr, Lidarr, Beets, Jellyfin)
5. **Observability layer** — VictoriaMetrics, Grafana, Proxmox exporter, custom dashboards

The full run takes ~10–15 minutes on a fresh node. All plays are idempotent — re-running is always safe.

At the end, `~/.kube/casshome.conf` is written to your local machine with the cluster API server address set to `10.13.13.1` (the WireGuard VPN IP).

---

## 5. Connect via WireGuard

Before you can reach any service, you need to be on the VPN. See [Network](network.md#connecting-to-the-vpn) for full details.

Quick version:
1. Install the [WireGuard app](https://www.wireguard.com/install/)
2. Create a peer config file using your peer's private key, the server's public key, and `10.13.13.2/32` as your VPN IP
3. Set `Endpoint = kaloscasshome.duckdns.org:51820` and `AllowedIPs = 10.13.13.0/24`
4. Activate the tunnel

Verify:

```bash
ping 10.13.13.1                    # VPN gateway — must respond
ssh -i ~/.ssh/casshome ubuntu@10.13.13.1
kubectl --kubeconfig ~/.kube/casshome.conf get nodes
```

---

## 6. One-time UI wiring

After the first deploy, each service needs minimal manual configuration through its web UI. All UIs are reachable only over the VPN.

### qBittorrent — `http://10.13.13.1:32080`

1. Log in with `admin` / `adminadmin`
2. **Tools → Options → Web UI**: change the password
3. **Tools → Options → Downloads**: set "Default Save Path" to `/downloads`

### Prowlarr — `http://10.13.13.1:32696`

1. Complete the initial setup wizard (create admin account)
2. **Settings → Apps → Add Application → Lidarr**:
   - Prowlarr Server: `http://prowlarr:9696`
   - Lidarr Server: `http://lidarr:8686`
   - API Key: the value of `ARR_API_KEY` from `.env.nu`
3. Add indexers under **Indexers**

### Lidarr — `http://10.13.13.1:32686`

1. **Settings → Download Clients → Add → qBittorrent**:
   - Host: `qbittorrent`, Port: `8080`
   - Username/password: as configured above
2. **Settings → Media Management → Root Folders**: add `/music`

### Jellyfin — `http://10.13.13.1:32018/jellyfin`

1. Complete the initial setup wizard
2. **Dashboard → Libraries → Add Media Library**:
   - Content type: Music
   - Folder: `/media/music`

### Grafana — `http://10.13.13.1:32018/grafana`

1. Log in with `admin` / `admin` (you will be prompted to change the password)
2. Dashboards are pre-provisioned: navigate to **Dashboards** to find media stack, VM disk, and Proxmox dashboards

---

## Re-deploying individual layers

After the first install, use tags to target specific layers rather than running the full playbook. See [Running Ansible](running-ansible.md) for the full tag reference.
