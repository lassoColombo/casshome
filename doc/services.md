# Services

All services are reachable only over the WireGuard VPN. See [Network](network.md) for connection instructions.

---

## Service directory

| Service | Namespace | URL | Access method |
|---|---|---|---|
| qBittorrent | `media` | `http://10.13.13.1:32080` | NodePort |
| Prowlarr | `media` | `http://10.13.13.1:32696` | NodePort |
| Lidarr | `media` | `http://10.13.13.1:32686` | NodePort |
| Jellyfin | `media` | `http://10.13.13.1:32018/jellyfin` | NGINX Ingress |
| Grafana | `observability` | `http://10.13.13.1:32018/grafana` | NGINX Ingress |
| Proxmox UI | — | `https://192.168.1.10:8006` | Direct (LAN via VPN) |

NodePort services are exposed directly on the node. Ingress-routed services go through NGINX Ingress Controller on port `32018`.

---

## qBittorrent

The download client. Receives torrent files/magnet links from Lidarr (via Prowlarr indexers) and saves completed downloads to `/downloads`.

**Default credentials**: `admin` / `adminadmin`

### First-time setup

1. **Change the password**: Tools → Options → Web UI → change password
2. **Set download path**: Tools → Options → Downloads → set "Default Save Path" to `/downloads`

### Config notes

The `qBittorrent.conf` is managed as a Kubernetes ConfigMap (`subPath`-mounted read-only). Two settings are mandatory for the pod to function:

- `WebUI\HostHeaderValidation=false` — without this, qBittorrent rejects requests coming from outside (e.g. from your browser via the NodePort) because the `Host` header doesn't match `localhost`
- `WebUI\MaxAuthFails=0` — without this, qBittorrent bans IPs after failed login attempts, which can lock you out inside Kubernetes where source IPs are unpredictable

These are already set in the ConfigMap. Do not override them via the UI — they will be reset on the next Ansible run.

---

## Prowlarr

The indexer aggregator. Talks to torrent indexers and feeds search results to Lidarr.

### First-time setup

1. Complete the setup wizard (create admin account, note or set the API key)
2. **Settings → Apps → Add Application → Lidarr**:
   - Prowlarr Server: `http://prowlarr:9696`
   - Lidarr Server: `http://lidarr:8686`
   - API Key: value of `ARR_API_KEY` from `.env.nu`
3. Add indexers under **Indexers → Add Indexer**

The connection between Prowlarr and Lidarr uses internal Kubernetes DNS (`<service>.<namespace>.svc.cluster.local`, shortened to `<service>` within the same namespace). No NodePorts are used for service-to-service communication.

### Config

Prowlarr's `config.xml` is managed as a ConfigMap. A busybox init-container copies it to the PVC on first run (the app requires the config to be on a writable PVC, not a read-only mount). The init-container only copies if the file doesn't already exist, so manual changes made via the UI are preserved across pod restarts.

---

## Lidarr

The music library manager. Searches Prowlarr for albums, sends download requests to qBittorrent, monitors completion, and moves finished files to `/music`.

### First-time setup

1. **Settings → Download Clients → Add → qBittorrent**:
   - Host: `qbittorrent`, Port: `8080`
   - Username/password: as set in qBittorrent
2. **Settings → Media Management → Root Folders**: add `/music`
3. **Settings → Profiles**: configure quality profiles as desired

Lidarr's API key is pre-set in its ConfigMap to the value of `ARR_API_KEY` from `.env.nu`, matching the key configured in Prowlarr.

### File flow

1. Lidarr sends a download request to qBittorrent
2. qBittorrent downloads to `/downloads` (host: `/mnt/downloads`)
3. Lidarr monitors the download; on completion, moves files to `/music` (host: `/mnt/media/music`)
4. The "move" is a `rename()` syscall — both paths are on the same host filesystem, so it is instant and zero-copy

### Config

Same init-container pattern as Prowlarr.

---

## Jellyfin

The media server. Serves the music library to clients.

**URL**: `http://10.13.13.1:32018/jellyfin` (routed through NGINX Ingress)

### First-time setup

1. Complete the setup wizard (create admin account)
2. **Dashboard → Libraries → Add Media Library**:
   - Content type: Music
   - Folder: `/media/music`
3. Let the initial library scan complete

### Config notes

Jellyfin's `BaseUrl` is set to `/jellyfin` via a `network.xml` ConfigMap so that the Ingress sub-path routing works correctly. This is applied automatically by Ansible — do not change it in the UI.

Same init-container pattern as Prowlarr/Lidarr.

---

## Beets

An automatic music library tagger. Runs as a sidecar that can be triggered manually or on a schedule to tag and normalize the music collection in `/music`.

Beets does not have a web UI. Configuration is managed via its ConfigMap (`config.yml.j2`). To run a tag pass manually:

```bash
kubectl --kubeconfig ~/.kube/casshome.conf exec -n media deployment/beets -- beet import /music
```

---

## Grafana

The monitoring dashboard. Served at `/grafana` via NGINX Ingress.

**Default credentials**: `admin` / `admin` (you will be prompted to change on first login)

### Pre-provisioned dashboards

Dashboards are automatically provisioned by the observability role — they appear in Grafana without any manual import:

| Dashboard | What it shows |
|---|---|
| Media Stack | Volume usage, CPU/memory per service, pod restart counts, pod status |
| VM Disk | Filesystem used %, free space, read/write throughput, IOPS |
| Proxmox Cluster | Hypervisor CPU, memory, storage, network per node/VM |

See [Observability](observability.md) for a full breakdown of the monitoring stack.
