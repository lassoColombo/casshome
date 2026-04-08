# CassHome

Single-node homelab running on a Proxmox-hosted VM. Terraform provisions the VM; Ansible bootstraps a kubeadm Kubernetes cluster and deploys a full media automation stack with VPN-only access and built-in observability.

```
Proxmox (192.168.1.10, HP Z440)
  └── Terraform ──────────────► k8s-node-01 (192.168.1.20)
                                      │
                                 Ansible (site.yml)
                                      │
                          ┌───────────┼────────────────────┐
                          │           │                    │
                     WireGuard    Media Stack        Observability
                     (VPN entry)  (qBit · Prowlarr   (VictoriaMetrics
                     DuckDNS      · Lidarr · Beets    · Grafana
                                  · Jellyfin)         · PVE exporter)
```

**All external access goes through WireGuard.** There is no direct internet exposure — the only open port is UDP 51820 for the VPN.

---

## Documentation

| Document | Contents |
|---|---|
| [Prerequisites](doc/prerequisites.md) | BIOS, local tooling, SSH key, Proxmox API tokens, `.env.nu` secrets |
| [Installation](doc/installation.md) | End-to-end first-deploy walkthrough |
| [Running Ansible](doc/running-ansible.md) | `uv run`, tag reference, idempotency |
| [Architecture](doc/architecture.md) | Three-layer design, K8s cluster setup, storage model |
| [Network](doc/network.md) | WireGuard deep dive, DuckDNS, VPN subnet, adding peers |
| [Services](doc/services.md) | Service URLs, NodePorts, first-time UI setup per service |
| [Observability](doc/observability.md) | VictoriaMetrics, Grafana, Proxmox exporter, dashboards |
| [Troubleshooting](doc/troubleshooting.md) | Common failures and fixes |

---

## Quick reference

### Services (requires VPN)

| Service | URL |
|---|---|
| qBittorrent | `http://10.13.13.1:32080/media/qbittorrent` |
| Prowlarr | `http://10.13.13.1:32696/media/prowlarr` |
| Lidarr | `http://10.13.13.1:32686/media/lidarr` |
| Jellyfin | `http://10.13.13.1:32018/media/jellyfin` |
| Grafana | `http://10.13.13.1:32018/grafana` |
| Proxmox UI | `https://192.168.1.10:8006` |

### Common commands

```bash
# Load secrets (required before every Terraform or Ansible session)
source .env.nu

# Provision VM
cd terraform && terraform apply

# Deploy full stack
cd ansible && uv run ansible-playbook playbooks/site.yml

# Target a specific layer
uv run ansible-playbook playbooks/site.yml --tags jellyfin
uv run ansible-playbook playbooks/site.yml --tags observability
uv run ansible-playbook playbooks/site.yml --tags network

# Verify cluster (after connecting VPN)
kubectl --kubeconfig ~/.kube/casshome.conf get nodes
kubectl --kubeconfig ~/.kube/casshome.conf get pods -A
```

---

## New here?

Start with [Prerequisites](doc/prerequisites.md), then follow [Installation](doc/installation.md).
