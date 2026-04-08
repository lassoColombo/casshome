# Network

## Public access flow

The cluster has no direct internet exposure. The only entry point is a WireGuard VPN pod running on the K8s node.

```
Internet
  │
  │  UDP 51820
  ▼
kaloscasshome.duckdns.org
  │
  │  DNS resolves to home public IP
  │  (kept current by DuckDNS cron every 5 min)
  ▼
Home router
  │
  │  Port forward: UDP 51820 → 192.168.1.20:51820
  ▼
k8s-node-01 (192.168.1.20)
  │
  │  WireGuard pod (hostNetwork: true, wg0: 10.13.13.1)
  ▼
VPN tunnel established
  │
  ├── ssh ubuntu@10.13.13.1         (K8s node SSH)
  ├── kubectl → https://10.13.13.1:6443  (K8s API server)
  └── http://10.13.13.1:32018       (NGINX Ingress → services)
```

Once connected to the VPN you are effectively on the home LAN. The `10.13.13.0/24` VPN subnet routes through the WireGuard pod with NAT (`MASQUERADE` via iptables), so you can reach all LAN addresses including `192.168.1.10` (Proxmox web UI).

---

## VPN subnet

| Address | Role |
|---|---|
| `10.13.13.0/24` | WireGuard subnet |
| `10.13.13.1` | Server (WireGuard pod on k8s-node-01) |
| `10.13.13.2` | Peer 1 (your laptop/phone) |

Add more peers in `.13.x` space; see [Adding a new peer](#adding-a-new-wireguard-peer) below.

---

## DuckDNS

A cron job runs every 5 minutes on `k8s-node-01` to keep `kaloscasshome.duckdns.org` pointed at the home public IP.

The script (`roles/duckdns/templates/duck.sh.j2`) calls the DuckDNS API with an empty `ip=` parameter, causing DuckDNS to auto-detect the outbound IP of the request. The `DUCKDNS_TOKEN` is sourced from the environment at cron execution time via the crontab entry.

No external dependency on the cluster being up — this is a plain host cron job.

---

## WireGuard host setup

The `roles/wireguard/tasks/host_up.yml` task configures the node to be capable of running WireGuard:

- Installs `wireguard-tools`
- Loads the `wireguard` kernel module and persists it via `/etc/modules-load.d/`
- Enables `net.ipv4.ip_forward = 1` via sysctl

The actual WireGuard interface (`wg0`) is managed by the K8s pod, not the host — `wireguard-tools` is needed only for the kernel module.

---

## WireGuard K8s pod

The VPN entry point is a Kubernetes Deployment in the `wireguard` namespace.

Key design choices:

**`hostNetwork: true`** — the pod shares the host's network namespace, binding `wg0` and UDP port 51820 directly on the physical NIC (`192.168.1.20`). This is why the router port forward targets the VM's LAN IP. Without `hostNetwork`, the pod would be behind KUBE-PROXY NAT with no way to receive UDP from the internet.

**`iptables` PostUp/PostDown** — the WireGuard config includes rules to `MASQUERADE` outbound traffic from VPN peers, making them appear to originate from `192.168.1.20` on the home LAN:

```
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o <default-iface> -j MASQUERADE
```

The default interface is resolved dynamically from the routing table at pod start time.

**Secret from Ansible** — the WireGuard config (containing the server private key and peer public keys) is stored as a Kubernetes Secret, rendered from `roles/wireguard/templates/config.yml.j2` with keys read from `.env.nu` environment variables via Ansible's `lookup('env', ...)`.

**`subPath` mount caveat** — the Secret is mounted via `subPath` into the pod's config directory. Kubernetes does **not** hot-reload `subPath` mounts when a Secret is updated. After any change to the WireGuard config (e.g. adding a peer), the pod must be manually restarted:

```bash
kubectl rollout restart deployment/wireguard -n wireguard
```

---

## Connecting to the VPN

1. Install the [WireGuard app](https://www.wireguard.com/install/) on your device
2. Create a peer config file:

```ini
[Interface]
PrivateKey = <your-peer-private-key>
Address = 10.13.13.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = <server-public-key>
PresharedKey = <preshared-key>
AllowedIPs = 10.13.13.0/24
Endpoint = kaloscasshome.duckdns.org:51820
PersistentKeepalive = 25
```

3. Import the config into the WireGuard app and activate the tunnel

### Verify the tunnel

```bash
ping 10.13.13.1                          # VPN gateway — must respond first
curl -s https://ifconfig.me              # should return your home public IP
ssh -i ~/.ssh/casshome ubuntu@10.13.13.1 # SSH to K8s node
kubectl --kubeconfig ~/.kube/casshome.conf get nodes
```

---

## Adding a new WireGuard peer

1. **Generate keys** for the new peer:

   ```bash
   priv=$(wg genkey)
   pub=$(echo "$priv" | wg pubkey)
   psk=$(wg genpsk)
   echo "private: $priv"
   echo "public:  $pub"
   echo "psk:     $psk"
   ```

2. **Add to `.env.nu`**:

   ```nu
   $env.WG_PEER2_PUBLIC_KEY    = "<pub>"
   $env.WG_PEER2_PRESHARED_KEY = "<psk>"
   ```

3. **Update `roles/wireguard/templates/config.yml.j2`** — add a new `[Peer]` block:

   ```ini
   [Peer]
   # peer2
   PublicKey = {{ lookup('env', 'WG_PEER2_PUBLIC_KEY') | mandatory }}
   PresharedKey = {{ lookup('env', 'WG_PEER2_PRESHARED_KEY') | mandatory }}
   AllowedIPs = 10.13.13.3/32
   ```

4. **Re-run Ansible and restart the pod**:

   ```bash
   source .env.nu
   cd ansible
   uv run ansible-playbook playbooks/site.yml --tags network
   kubectl --kubeconfig ~/.kube/casshome.conf rollout restart deployment/wireguard -n wireguard
   ```

5. **Configure the peer's client** using the peer's private key, the server's public key (`WG_SERVER_PRIVATE_KEY | wg pubkey`), and `Address = 10.13.13.3/32`.

---

## kubeconfig and the VPN IP

After `kubeadm init`, `admin.conf` on the node has the API server set to `https://127.0.0.1:6443` (loopback). Ansible rewrites this to `https://10.13.13.1:6443` when copying to `~/.kube/casshome.conf`. This makes `kubectl` work from your local machine over the VPN without any manual edits.

The kubeconfig is saved with mode `0600`. Keep it out of version control.

---

## Router note (ZTE routers)

ZTE routers have a dedicated "WireGuard" section in the UI that sets up the router's own built-in WireGuard server. **This is not what you want.** The port forward that sends UDP 51820 to the VM is a separate entry under **Firewall → Port Forwarding**.
