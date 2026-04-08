# Observability

The observability stack runs in the `observability` namespace and provides metrics collection, storage, and dashboards for the entire homelab — both the Kubernetes workloads and the Proxmox hypervisor.

---

## Stack components

| Component | Role | How deployed |
|---|---|---|
| **VictoriaMetrics Single** (`vmsingle`) | Metrics database, 30-day retention | `victoria-metrics-k8s-stack` Helm chart |
| **VMAgent** | Metrics scraper (replaces Prometheus) | Same Helm chart |
| **Grafana** | Dashboards and visualization | Same Helm chart |
| **prometheus-pve-exporter** | Scrapes Proxmox VE API → Prometheus metrics | Custom Deployment (Ansible template) |

The `victoria-metrics-k8s-stack` Helm chart installs the VictoriaMetrics operator and pre-configures scraping of all standard Kubernetes metrics (node, kubelet, kube-state-metrics, etc.) out of the box.

---

## Deployment

Managed by `roles/observability/tasks/k8s_up.yml`. Run:

```bash
uv run ansible-playbook playbooks/site.yml --tags observability
```

Deploy order:
1. Namespace (`observability`)
2. Shared storage (PersistentVolumes for VictoriaMetrics and Grafana)
3. VictoriaMetrics stack via Helm
4. Proxmox exporter (Secret, Deployment, Service, VMServiceScrape)
5. Custom Grafana dashboards (ConfigMaps)

---

## Storage

All data is persisted to `hostPath` volumes on `k8s-node-01`:

| Component | Host path | PV size |
|---|---|---|
| VictoriaMetrics (vmsingle) | `/opt/victoriametrics/data` | 20 Gi |
| Grafana | `/opt/grafana/data` | 2 Gi |

Retention is set to **30 days** in `vm-stack-values.yml.j2` (`retentionPeriod: 30d`). VictoriaMetrics enforces this automatically.

---

## Grafana

Grafana is served at **`http://10.13.13.1:32018/grafana`** via NGINX Ingress. The sub-path routing is configured in `vm-stack-values.yml.j2`:

```yaml
grafana:
  grafana.ini:
    server:
      root_url: "%(protocol)s://%(domain)s:%(http_port)s/grafana"
      serve_from_sub_path: true
  ingress:
    enabled: true
    ingressClassName: nginx
    path: /grafana
```

**Default credentials**: `admin` / `admin`

---

## VMServiceScrape — how scrape targets are discovered

VictoriaMetrics uses a Kubernetes operator model. Instead of configuring scrape targets in a static file, you create `VMServiceScrape` custom resources that the operator translates into scrape jobs.

The Proxmox exporter's scrape config lives in `roles/observability/templates/pve-exporter/vmservicescrape.yml.j2`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: pve-exporter
  namespace: observability
spec:
  selector:
    matchLabels:
      app: pve-exporter
  endpoints:
    - port: http
      path: /pve
      params:
        target: ["192.168.1.10"]   # Proxmox host IP
      interval: 30s
      scrapeTimeout: 15s
```

VMAgent finds this resource, calls the exporter at `/pve?target=192.168.1.10` every 30 seconds, and stores the result in VictoriaMetrics.

---

## Proxmox exporter

[`prometheus-pve-exporter`](https://github.com/prometheus-pve/prometheus-pve-exporter) translates the Proxmox VE HTTP API into Prometheus-format metrics.

**Version**: `3.4.2` (set in `roles/observability/defaults/main.yml`)

### Authentication

The exporter uses a dedicated read-only Proxmox API token (`prom-exporter@pve!pve-exporter`). The token value is stored as a Kubernetes Secret rendered from `.env.nu`:

```yaml
# pve-exporter/secret.yml.j2
default:
  user: "prom-exporter@pve"
  token_name: "pve-exporter"
  token_value: "{{ lookup('env', 'PVE_EXPORTER_TOKEN') | mandatory }}"
  verify_ssl: false
```

`verify_ssl: false` is needed because Proxmox uses a self-signed certificate.

### What it exposes

The exporter provides per-node and per-VM metrics from the Proxmox API:

- **CPU**: usage per node and VM, CPU type, core count
- **Memory**: total, used, free per node and VM
- **Storage**: size, used, available per storage pool
- **Network**: in/out bytes per interface
- **VM status**: running/stopped/paused per VMID
- **Node status**: online/offline

These feed the Proxmox Cluster dashboard in Grafana.

### `PVE_EXPORTER_TOKEN` prerequisite

The token must exist in `.env.nu` before running the observability play. See [Prerequisites](prerequisites.md#5-create-proxmox-api-token-for-the-pve-exporter) for how to create the Proxmox token.

---

## Custom dashboards

Dashboards are auto-provisioned via Grafana's sidecar mechanism. Any ConfigMap in the `observability` namespace with the label `grafana_dashboard: "1"` is automatically loaded by Grafana — no manual import required.

### Media Stack dashboard

**ConfigMap**: `roles/observability/templates/dashboards/media-stack-dashboard.yml`

Panels:
- **Volume usage**: gauge (disk free %), disk used (bytes), disk free (bytes), time series of usage over time — for `/mnt/downloads` and `/mnt/media/music`
- **App resource usage**: CPU usage (millicores) per pod, memory usage (bytes) per pod — for all `media` namespace pods
- **Reliability**: container restart count (last 24h), pod status (running/pending/failed)

### VM Disk dashboard

**ConfigMap**: `roles/observability/templates/dashboards/vm-disk-dashboard.yml`

Panels:
- **Filesystem space**: used % gauge, free space, used vs total time series — parameterized by instance and mountpoint
- **Disk I/O**: read throughput (bytes/s), write throughput (bytes/s), read/write IOPS, disk utilization %

### Proxmox dashboard

**ConfigMap**: `roles/observability/templates/pve-exporter/dashboard.yml`

Based on Grafana.net dashboard ID `10347`. Provides cluster-level hypervisor metrics from the PVE exporter.

---

## Accessing metrics directly

VictoriaMetrics exposes a query API compatible with Prometheus. To query metrics directly (e.g. for debugging):

```bash
# Port-forward VictoriaMetrics locally
kubectl --kubeconfig ~/.kube/casshome.conf -n observability port-forward svc/victoria-metrics-k8s-stack-victoria-metrics-single-server 8428:8428

# Query (MetricsQL / PromQL)
curl 'http://localhost:8428/api/v1/query?query=up'
```

Or use the Grafana Explore view at `/grafana/explore`.
