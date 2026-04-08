# Ansible Structure

## Playbook layout

```
site.yml                        # master orchestrator — five sequential plays
inventory/
  hosts.yml                     # host groups and IPs
  group_vars/all.yml            # shared variables (local_kubeconfig, wireguard_ip, ...)
roles/
  proxmox/                      # SSH hardening + NIC configuration for pve1
  common/                       # base packages, swap, timezone for k8s nodes
  k8s/                          # kubeadm cluster bootstrap
  duckdns/                      # DuckDNS cron update script
  wireguard/                    # WireGuard host prereqs + k8s pod deployment
  media_stack/                  # host dirs + full media stack k8s deployment
  observability/                # VictoriaMetrics operator + k8s stack, Grafana, exporters
```

## Plays in site.yml

| Play | `hosts` group | Roles / tasks | Tags |
|------|---------------|---------------|------|
| Proxmox | `proxmox` | proxmox | `proxmox` |
| K8s | `k8s` | common, k8s | `k8s` |
| Gateway | `gateway` | label node, duckdns, wireguard | `gateway` |
| Apps | `media` | label node, media_stack | `media` |
| Core | `k8s` | observability | `observability` |

All host groups currently resolve to the same single node (`k8s-node-01`).

## Delegation rule

Every play targets the remote node via SSH (`become: true`). Tasks divide into two classes:

**Node tasks** — run on the remote host (no `delegate_to`):
- OS/package management (`apt`, `service`, `sysctl`, `modprobe`, ...)
- kubeadm init, kubelet, containerd
- Writing files on the node (`/etc/...`, `/opt/...`, `/mnt/...`)

**Control-plane tasks** — MUST use `delegate_to: localhost` + `become: false`:
- Any `kubernetes.core.*` module call
- Any `helm` or `kubectl` command that targets the cluster
- Any write to `local_kubeconfig` or other local paths

Breaking this rule causes the chicken-and-egg hang: without `delegate_to: localhost`, the
Python kubernetes client falls back to `localhost:8080`, which hangs forever.

## Kubeconfig lifecycle

```
kubeadm init (node)
  └─> /etc/kubernetes/admin.conf  server: https://192.168.1.20:6443

copy_kubeconfig_up.yml (delegate_to: localhost)
  └─> ~/.kube/casshome.conf       server: https://192.168.1.20:6443
      (LAN IP — reachable from control machine during the Ansible run)

[all subsequent kubernetes.core.* and helm/kubectl tasks use this file]

wireguard k8s_up.yml — after WireGuard pod is Available (delegate_to: localhost)
  └─> ~/.kube/casshome.conf       server: https://10.13.13.1:6443
      (WireGuard IP — reachable for manual kubectl after VPN is connected)
```

**Ordering invariant**: no `kubernetes.core.*`, `helm`, or `kubectl` task may run before
`copy_kubeconfig_up.yml` completes. This is why the taint removal was moved out of
`kubeadm_init_up.yml` and into `k8s/tasks/main.yml` after the kubeconfig copy.

**Tunnel bootstrap problem**: the gateway play rewrites the kubeconfig server to `10.13.13.1`
after WireGuard is deployed. If the WireGuard pod is down (e.g. fresh cluster), the label
tasks in the gateway and media plays hang because `delegate_to: localhost` tries to reach
`10.13.13.1:6443`. Temporary workaround for a full re-bootstrap:

```bash
# Before running the playbook — point kubeconfig at LAN IP
cp ~/.kube/casshome.conf ~/.kube/casshome.conf.bak
sed -i '' 's|https://10.13.13.1:6443|https://192.168.1.20:6443|' ~/.kube/casshome.conf

uv run ansible-playbook playbooks/site.yml

# After WireGuard is up — restore tunnel-based kubeconfig
cp ~/.kube/casshome.conf.bak ~/.kube/casshome.conf
```

## Helm usage

`kubernetes.core.helm` requires Helm `<4.0.0` and is not used. All Helm installs use raw
`ansible.builtin.command: helm upgrade --install ...` with `KUBECONFIG` set via the task's
`environment:` key. All `kubectl` commands also pass `--kubeconfig {{ local_kubeconfig }}`
explicitly. Both run inside `delegate_to: localhost` blocks.

## Observability stack

VictoriaMetrics is deployed as two separate Helm releases to avoid a CRD ownership conflict:

1. `vm-operator` — installs the VictoriaMetrics operator and owns all `operator.victoriametrics.com` CRDs
2. `vm-stack` — deploys the full k8s monitoring stack with `victoria-metrics-operator.enabled=false`
   (uses the operator from release 1, does not re-install it)

If CRDs exist without Helm ownership annotations (e.g. from a failed prior install), delete them
before re-running: `kubectl delete crds -l app.kubernetes.io/name=victoria-metrics-operator`
or delete by name, then re-run `--tags observability`.

## Media Stack Workflow & Manual Operations

The media stack relies on an **"In-Place Groomer"** workflow. Ansible deploys the infrastructure and constraints, but the following manual steps are required to configure the applications' internal databases correctly.

### 1. Lidarr: Folder Structure & Renaming
Ansible cannot configure Lidarr's internal database (`lidarr.db`). You must explicitly configure Lidarr to use subfolders so Beets can accurately parse albums without flattening the directory.
1. Open Lidarr UI (`http://192.168.1.20:32018/media/lidarr`).
2. Go to **Settings > Media Management** (Check "Show Advanced" at the top).
3. Check **Rename Tracks**.
4. Set **Standard Album Folder Format** to `{Album Title} ({Release Year})` (or your preferred subfolder format).
5. Save changes.
6. Go to **Artists** > **Mass Update** > Select all artists > Click **Rename Files** to trigger a reorganization of your `/music` directory.

### 2. Beets: In-Place Metadata Enrichment
Beets acts as a strict metadata enricher. It runs against the `/music` directory in-place. Ansible provisions it to never move or copy files (`move: false`, `copy: false`) to avoid unlinking Lidarr's database. It is also configured to `quiet_fallback: asis` so it automatically accepts its own ID3 tags if MusicBrainz fails to find a match, preventing terminal hangs.
* **To trigger a bulk import:**
  ```bash
  kubectl exec -it -n media deploy/beets -- beet import -q /music/
  ```

### 3. Jellyfin: Library Refresh
Jellyfin monitors the `/media` mount passively. After Lidarr performs a mass structural rename, or after Beets updates ID3 tags and cover art, you must trigger a manual scan.
1. Open Jellyfin UI (`http://192.168.1.20:32018/media/jellyfin`).
2. Go to **Dashboard > Libraries**.
3. Click the `...` next to your Music library and select **Scan Library** to pull in the new directory paths and enriched metadata.

## k8s role task order

```
prereqs_up.yml          kernel modules, sysctl, socat/conntrack
containerd_up.yml       containerd install + config
k8s_packages_up.yml     kubernetes apt repo + kubelet/kubeadm/kubectl
kubeadm_init_up.yml     kubeadm init (idempotent), on-node .kube/config
copy_kubeconfig_up.yml  ← kubeconfig written here (delegate_to: localhost)
[taint removal]         delegate_to: localhost — first local k8s API call
helm_up.yml             Helm install on node (used by node-side tooling)
cni_up.yml              Flannel manifest + host-gw backend config (delegate_to: localhost)
ingress_up.yml          NGINX Ingress via helm + kubectl wait (delegate_to: localhost)
kubectl_config_up.yml   bash completion + alias on node
```

## Tags reference

```
# By layer
--tags proxmox       Proxmox SSH hardening + NIC configuration (e1000e)
--tags k8s           Full cluster bootstrap (common + k8s role)
--tags gateway       Node labeling + DuckDNS + WireGuard
--tags media         Media stack host dirs + k8s deployment
--tags observability VictoriaMetrics operator + k8s stack, Grafana, PVE exporter

# By app (within media_stack)
--tags jellyfin
--tags qbittorrent
--tags prowlarr
--tags lidarr
--tags beets
--tags media_infra   Namespace + shared PVs only
```

## Exposed Services

| App | Internal Port | NodePort | Ingress URL |
|-----|---------------|----------|-------------|
| Jellyfin | 8096 | 32018 | http://192.168.1.20:32018/media/jellyfin |
| qBittorrent | 8080 | 32018 | http://192.168.1.20:32018/media/qbittorrent |
| Prowlarr | 9696 | 32018 | http://192.168.1.20:32018/media/prowlarr |
| Lidarr | 8686 | 32018 | http://192.168.1.20:32018/media/lidarr |
| Beets | 8337 | 32018 | http://192.168.1.20:32018/media/beets |
| Grafana | 3000 | 32018 | http://192.168.1.20:32018/grafana |
