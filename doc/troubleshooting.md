# Troubleshooting

---

## WireGuard: tunnel not connecting

**Symptoms**: `ping 10.13.13.1` times out after activating the WireGuard client.

**Check in order**:

1. **Router port forward**: confirm UDP 51820 is forwarded to `192.168.1.20`. On ZTE routers, this is under **Firewall → Port Forwarding**, not the "WireGuard" section (which configures the router's own VPN).

2. **WireGuard pod running**:
   ```bash
   kubectl --kubeconfig ~/.kube/casshome.conf get pods -n wireguard
   ```
   Should show `Running`. If `Pending`, the node may not be labeled — re-run `--tags network`.

3. **Pod is using host network**:
   ```bash
   kubectl --kubeconfig ~/.kube/casshome.conf get pod -n wireguard -o wide
   ```
   The pod IP should be `192.168.1.20` (same as the node), confirming `hostNetwork: true`.

4. **DuckDNS resolving correctly**:
   ```bash
   dig kaloscasshome.duckdns.org
   ```
   Should return your home public IP. If not, the DuckDNS cron may have stopped — check with `crontab -l` on the node.

---

## WireGuard: config change not taking effect

**Cause**: Secrets mounted via `subPath` are not hot-reloaded by Kubernetes.

**Fix**: After any change to the WireGuard Secret (e.g. adding a peer), restart the pod:

```bash
kubectl --kubeconfig ~/.kube/casshome.conf rollout restart deployment/wireguard -n wireguard
```

---

## Pods not scheduling

**Symptoms**: Pods stuck in `Pending`; `kubectl describe pod` shows `0/1 nodes are available: 1 node(s) had untolerated taint`.

**Cause**: The control-plane taint (`node-role.kubernetes.io/control-plane:NoSchedule`) was not removed. This is done by `kubeadm_init_up.yml` during cluster init. It may not have run if you used `--tags` that skipped the `k8s` play.

**Fix**:
```bash
kubectl --kubeconfig ~/.kube/casshome.conf taint nodes --all node-role.kubernetes.io/control-plane-
```

Or re-run the k8s play:
```bash
uv run ansible-playbook playbooks/site.yml --tags k8s
```

---

## Flannel pods not ready

**Symptoms**: `kubectl get pods -n kube-flannel` shows pods not `Running`; nodes stuck in `NotReady`.

**Check**: Flannel uses the `host-gw` backend, which requires L2 adjacency between nodes. On a single-node cluster this is always satisfied. The most common cause is a failed manifest download.

```bash
kubectl --kubeconfig ~/.kube/casshome.conf describe daemonset kube-flannel-ds -n kube-flannel
kubectl --kubeconfig ~/.kube/casshome.conf logs -n kube-flannel daemonset/kube-flannel-ds
```

**Fix**: Re-run the CNI task:
```bash
uv run ansible-playbook playbooks/site.yml --tags k8s
```

---

## qBittorrent UI inaccessible / login loop

**Cause**: `HostHeaderValidation=false` is missing from the ConfigMap, or the pod hasn't been restarted after a ConfigMap change.

**Note**: ConfigMap changes do **not** automatically restart pods. After any change to the qBittorrent ConfigMap:
```bash
kubectl --kubeconfig ~/.kube/casshome.conf rollout restart deployment/qbittorrent -n media
```

**Cause 2**: IP was banned due to failed logins (`MaxAuthFails`). Delete the pod to get a fresh instance:
```bash
kubectl --kubeconfig ~/.kube/casshome.conf delete pod -n media -l app=qbittorrent
```

---

## Prowlarr or Lidarr: stale config after ConfigMap update

**Cause**: The busybox init-container copies `config.xml` from the ConfigMap to the PVC only if the file doesn't already exist. If you update the ConfigMap but the file already exists on the PVC, the new config is ignored.

**Fix**: Delete the PVC (data loss — only config, not media) and redeploy:
```bash
kubectl --kubeconfig ~/.kube/casshome.conf delete pvc prowlarr-config-pvc -n media
uv run ansible-playbook playbooks/site.yml --tags prowlarr
```

---

## Ansible: `kubernetes.core.k8s` fails — kubeconfig not found

**Symptoms**: Ansible tasks targeting the cluster fail with `kubeconfig not found` or connection refused.

**Cause**: `~/.kube/casshome.conf` doesn't exist yet. It's created by the `copy_kubeconfig_up.yml` task in the `k8s` play.

**Fix**: Run the k8s play first:
```bash
uv run ansible-playbook playbooks/site.yml --tags k8s
```

Then re-run the failing play.

---

## Ansible: `uv run` not found

**Fix**:
```bash
brew install uv
cd ansible
uv sync
```

---

## Ansible: collection not found

**Fix**:
```bash
cd ansible
uv run ansible-galaxy collection install ansible.posix community.general kubernetes.core
```

---

## Observability: Proxmox exporter returning no data

**Symptoms**: Proxmox dashboard in Grafana shows no data or "No data" panels.

**Check**:
1. `PVE_EXPORTER_TOKEN` is set in `.env.nu` and the Ansible play was re-run after setting it
2. The Proxmox user `prom-exporter@pve` exists and has `PVEAuditor` role
3. The exporter pod is running:
   ```bash
   kubectl --kubeconfig ~/.kube/casshome.conf get pods -n observability -l app=pve-exporter
   ```
4. Test the exporter directly:
   ```bash
   kubectl --kubeconfig ~/.kube/casshome.conf -n observability port-forward svc/pve-exporter 9221:9221
   curl 'http://localhost:9221/pve?target=192.168.1.10'
   ```
   Should return Prometheus-format metrics. If it returns an error, check the token value in the Secret:
   ```bash
   kubectl --kubeconfig ~/.kube/casshome.conf get secret pve-exporter-auth -n observability -o jsonpath='{.data.pve\.yml}' | base64 -d
   ```

---

## Terraform: VM already exists / state drift

If the VM was manually deleted from Proxmox but Terraform state still references it:

```bash
cd terraform
terraform state rm proxmox_virtual_environment_vm.k8s_node
terraform apply
```

Or import the existing VM:
```bash
terraform import proxmox_virtual_environment_vm.k8s_node pve1/qemu/<vmid>
```
