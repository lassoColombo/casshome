# Architecture

## Three-layer separation

The infrastructure is divided into three strictly separated layers. Each layer has exactly one responsibility and talks to exactly one interface.

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: Terraform                                         │
│  Proxmox HTTP API only                                      │
│  → provisions VM, injects cloud-init, nothing else          │
└─────────────────────────┬───────────────────────────────────┘
                          │ creates
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 2: Ansible                                           │
│  SSH to VM + local kubectl (via WireGuard kubeconfig)       │
│  → OS config, K8s bootstrap, workload deployment            │
└─────────────────────────┬───────────────────────────────────┘
                          │ applies
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: Kubernetes Manifests                              │
│  Jinja2 templates inside Ansible role templates/ dirs       │
│  → define and run all workloads                             │
└─────────────────────────────────────────────────────────────┘
```

Terraform never touches the OS. Ansible never touches the Proxmox API. K8s manifests never contain secrets — those are injected by Ansible at render time via Jinja2.

---

## Physical topology

| Host | IP (LAN) | IP (VPN) | Role |
|---|---|---|---|
| `pve1` | `192.168.1.10` | — | Proxmox hypervisor |
| `k8s-node-01` | `192.168.1.20` | `10.13.13.1` | VM: K8s node, gateway, media host |

Everything runs on a single Proxmox host (HP Z440 workstation, Xeon E5-1620 v3, 16 GB RAM, 794 GB LVM thin pool).

---

## Ansible host groups

`inventory/hosts.yml` divides hosts into functional groups. Multiple groups can target the same host:

| Group | Host | Purpose |
|---|---|---|
| `proxmox` | `pve1` @ `192.168.1.10` as `root` | Proxmox OS hardening and NIC config |
| `k8s` | `k8s-node-01` @ `192.168.1.20` as `ubuntu` | Kubernetes cluster install |
| `gateway` | `k8s-node-01` | Nodes that serve as the public VPN entry point |
| `media` | `k8s-node-01` | Node chosen to host the media stack |

In a multi-node cluster you would add nodes to `k8s` but keep only one in `gateway` and `media`.

---

## `site.yml` — master orchestrator

The single playbook that runs everything. Five plays, each targeting a specific host group:

| Play | Tag | Hosts | What it does |
|---|---|---|---|
| Infrastructure | `proxmox` | `proxmox` | SSH hardening, Intel NIC workaround |
| Kubernetes | `k8s` | `k8s` | OS baseline, containerd, kubeadm init, Flannel, NGINX Ingress, fetch kubeconfig |
| Network | `network` | `gateway` | Labels node `network-role: gateway`, runs DuckDNS + WireGuard roles |
| Apps | `apps` | `media` | Labels node `stack-role: media`, runs media_stack role |
| Observability | `observability` | `k8s` | VictoriaMetrics stack + Proxmox exporter + dashboards |

The `network` and `apps` plays dynamically label the K8s node using `kubernetes.core.k8s` delegated to `localhost` with the locally-fetched kubeconfig, then deploy workloads using node selectors.

---

## Kubernetes cluster

- **Distribution**: kubeadm (full upstream, not k3s)
- **Version**: `1.32` (pinned in `roles/k8s/defaults/main.yml`)
- **Node**: single control-plane node with the `node-role.kubernetes.io/control-plane` taint removed so workloads can schedule on it
- **CRI**: containerd with `SystemdCgroup = true`
- **CNI**: Flannel with the `host-gw` backend — pods communicate via direct kernel routing, no overlay tunneling. Works because all nodes are on the same L2 segment (single node: always true)
- **Ingress**: NGINX Ingress Controller via Helm, listening on static NodePort `32018`
- **Pod CIDR**: `10.244.0.0/16`
- **Service CIDR**: `10.96.0.0/12`

### kubeconfig

After `kubeadm init`, Ansible fetches `admin.conf` from the node and saves it locally as `~/.kube/casshome.conf` with the API server address rewritten from `127.0.0.1` to `10.13.13.1` (the WireGuard VPN IP). This means `kubectl` works from your local machine when the VPN is connected.

```bash
export KUBECONFIG=~/.kube/casshome.conf
kubectl get nodes
```

---

## Template and manifest pattern

Raw Kubernetes YAML never lives in the repo as static files. Instead:

1. Templates live in `roles/<role>/templates/` as `.yml` (static) or `.yml.j2` (Jinja2)
2. Ansible renders each template and applies it to the cluster via `kubernetes.core.k8s` with `delegate_to: localhost`
3. Variables like ports, versions, and API keys are injected at render time

This means the cluster state is always driven by Ansible — there is no separate `kubectl apply` step and no out-of-band changes.

---

## Storage model

All persistent storage uses `hostPath` PersistentVolumes pointing to directories on `k8s-node-01`. This is appropriate for a single-node homelab: no network storage overhead, and renames across directories on the same filesystem are atomic `rename()` syscalls (zero copy).

### Media stack storage

| Writer | In-pod path | Host path | Reader | In-pod path |
|---|---|---|---|---|
| qBittorrent | `/downloads` | `/mnt/downloads` | Lidarr | `/downloads` |
| Lidarr | `/music` | `/mnt/media/music` | Jellyfin | `/media/music` |
| Lidarr | `/config` | `/opt/lidarr/config` | — | — |
| qBittorrent | `/config` | `/opt/qbittorrent/config` | — | — |
| Prowlarr | `/config` | `/opt/prowlarr/config` | — | — |
| Jellyfin | `/config` | `/opt/jellyfin/config` | — | — |

`/mnt/downloads` is mounted by both qBittorrent and Lidarr simultaneously via the same `hostPath` PVC. When Lidarr "moves" a file from `/downloads` to `/music`, the underlying host paths resolve to different mount points, so Ansible provisions both the host directories on the node and separate PVs for each path.

### Observability storage

| Component | Host path | Size |
|---|---|---|
| VictoriaMetrics (vmsingle) | `/opt/victoriametrics/data` | 20 Gi |
| Grafana | `/opt/grafana/data` | 2 Gi |
