# Ansible Structure

## Playbook layout

```
site.yml                        # master orchestrator — four sequential plays
inventory/
  hosts.yml                     # host groups and IPs
  group_vars/all.yml            # shared variables (local_kubeconfig, wireguard_ip, ...)
roles/
  proxmox/                      # SSH hardening + NIC workaround for pve1
  common/                       # base packages, swap, timezone for k8s nodes
  k8s/                          # kubeadm cluster bootstrap
  duckdns/                      # DuckDNS cron update script
  wireguard/                    # WireGuard host prereqs + k8s pod deployment
  media_stack/                  # host dirs + full media stack k8s deployment
```

## Plays in site.yml

| Play | `hosts` group | Roles / tasks | Tags |
|------|---------------|---------------|------|
| Proxmox | `proxmox` | proxmox | `proxmox` |
| K8s | `k8s` | common, k8s | `k8s` |
| Gateway | `gateway` | label node, duckdns, wireguard | `gateway` |
| Apps | `media` | label node, media_stack | `apps` |

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

## Helm usage

`kubernetes.core.helm` requires Helm `<4.0.0` and is not used. All Helm installs use raw
`ansible.builtin.command: helm upgrade --install ...` with `KUBECONFIG` set via the task's
`environment:` key. All `kubectl` commands also pass `--kubeconfig {{ local_kubeconfig }}`
explicitly. Both run inside `delegate_to: localhost` blocks.

## k8s role task order

```
prereqs_up.yml          kernel modules, sysctl, socat/conntrack
containerd_up.yml       containerd install + config
k8s_packages_up.yml     kubernetes apt repo + kubelet/kubeadm/kubectl
kubeadm_init_up.yml     kubeadm init (idempotent), on-node .kube/config
copy_kubeconfig_up.yml  ← kubeconfig written here (delegate_to: localhost)
[taint removal]         delegate_to: localhost — first local k8s API call
helm_up.yml             Helm install on node (used by node-side tooling)
cni_up.yml              Calico via helm + kubectl wait (delegate_to: localhost)
ingress_up.yml          NGINX Ingress via helm + kubectl wait (delegate_to: localhost)
kubectl_config_up.yml   bash completion + alias on node
```

## Tags reference

```
# By layer
--tags proxmox       Proxmox SSH hardening + NIC workaround
--tags k8s           Full cluster bootstrap (common + k8s role)
--tags gateway       Node labeling + DuckDNS + WireGuard
--tags apps          Media stack host dirs + k8s deployment

# By app (within media_stack)
--tags jellyfin
--tags qbittorrent
--tags prowlarr
--tags lidarr
--tags media_infra   Namespace + shared PVs only
```
