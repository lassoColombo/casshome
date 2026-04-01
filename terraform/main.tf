provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true # self-signed certificate

  ssh {
    agent       = true
    username    = "root"
    private_key = file(pathexpand(var.proxmox_ssh_private_key))
  }
}

# Download Ubuntu 24.04 LTS cloud image to Proxmox local storage
resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "pve1"

  url       = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  file_name = "noble-server-cloudimg-amd64.img"
}

# Single-node Kubernetes VM
resource "proxmox_virtual_environment_vm" "k8s_node" {
  name      = "k8s-node-01"
  node_name = "pve1"
  vm_id     = 100

  cpu {
    cores = 5
    type  = "x86-64-v2-AES"
  }

  memory { # Mib
    dedicated = 12288
    floating  = 2048 # enables ballooning; host can reclaim down to this minimum
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    file_format  = "raw"
    interface    = "virtio0"
    size         = 100
    discard      = "on"
    iothread     = true
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  # Cloud-init configuration
  initialization {
    ip_config {
      ipv4 {
        address = "${var.vm_ip}/24"
        gateway = var.gateway
      }
    }

    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }

    dns {
      servers = ["1.1.1.1", "8.8.8.8"]
    }
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true # re-enable after Ansible installs qemu-guest-agent
  }

  on_boot = true
}
