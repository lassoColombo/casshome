# Running Ansible

## Why `uv run`

All Ansible commands are prefixed with `uv run`. This ensures Ansible runs inside the isolated Python virtual environment defined by `pyproject.toml` and `uv.lock`, with exact dependency versions pinned (`ansible==13.5.0`, `kubernetes==35.0.0`, etc.). Running bare `ansible-playbook` would use whatever version happens to be on your system PATH.

Always run Ansible from the `ansible/` directory:

```bash
cd ansible
source ../.env.nu   # load secrets into environment
uv run ansible-playbook playbooks/site.yml
```

---

## Full stack run

```bash
uv run ansible-playbook playbooks/site.yml
```

Runs all five layers in order. Safe to re-run at any time — every task is idempotent.

---

## Tag-targeted runs

Use `--tags` to run a specific layer or service instead of the full stack. This is the normal workflow after the initial install.

### Layer tags

| Tag | What it does | Hosts | Roles |
|---|---|---|---|
| `proxmox` | SSH hardening + NIC configuration | `proxmox` (pve1) | `proxmox` |
| `k8s` | Kubernetes cluster bootstrap | `k8s` (k8s-node-01) | `common`, `k8s` |
| `network` | WireGuard VPN + DuckDNS | `gateway` (k8s-node-01) | `duckdns`, `wireguard` |
| `apps` | Full media stack | `media` (k8s-node-01) | `media_stack` |
| `observability` | VictoriaMetrics + Grafana + Proxmox exporter | `k8s` (k8s-node-01) | `observability` |

### App-level tags

These target individual services within the media stack:

| Tag | What it deploys |
|---|---|
| `media_infra` | `media` namespace + shared PersistentVolumes only |
| `qbittorrent` | qBittorrent (ConfigMap, Deployment, Service, Ingress) |
| `prowlarr` | Prowlarr (ConfigMap, Deployment, Service, Ingress) |
| `lidarr` | Lidarr (ConfigMap, Deployment, Service, Ingress) |
| `jellyfin` | Jellyfin (ConfigMap, Deployment, Service, Ingress) |

### Examples

```bash
# Update only the Jellyfin deployment
uv run ansible-playbook playbooks/site.yml --tags jellyfin

# Re-apply WireGuard config (e.g. after adding a peer)
uv run ansible-playbook playbooks/site.yml --tags network

# Refresh observability stack (e.g. after updating a dashboard ConfigMap)
uv run ansible-playbook playbooks/site.yml --tags observability

# Rebuild the Kubernetes cluster from scratch (after wiping the node)
uv run ansible-playbook playbooks/site.yml --tags k8s
```

---

## Idempotency

Every task in every role is written to be idempotent — running the same playbook multiple times produces the same result and will not break a running cluster. Kubernetes resources are applied with `state: present`, Helm releases are installed-or-upgraded, and file tasks use `creates:` guards or Ansible's built-in change detection.

Re-running the full playbook against a healthy cluster is always safe.

---

## Linting

```bash
uv run ansible-lint
```

Runs `ansible-lint` against all roles and playbooks. Fix any warnings before committing.

---

## Ansible collections

If you get `ModuleNotFoundError` or `collection not found` errors, reinstall the collections:

```bash
uv run ansible-galaxy collection install ansible.posix community.general kubernetes.core
```
