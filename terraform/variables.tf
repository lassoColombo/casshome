variable "proxmox_endpoint" {
  description = "Proxmox API endpoint URL"
  type        = string
  default     = "https://192.168.1.10:8006"
}

variable "proxmox_api_token" {
  description = "Proxmox API token (format: user@realm!token_name=token_value)"
  type        = string
  sensitive   = true
}

variable "vm_ip" {
  description = "Static IP for the k8s VM (without CIDR prefix)"
  type        = string
  default     = "192.168.1.20"
}

variable "gateway" {
  description = "Default gateway for the VM"
  type        = string
  default     = "192.168.1.1"
}

variable "ssh_public_key" {
  description = "SSH public key injected into the VM via cloud-init (for the ubuntu user)"
  type        = string
}

variable "proxmox_ssh_private_key" {
  description = "Path to the SSH private key used by the Terraform provider to connect to pve1"
  type        = string
  default     = "~/.ssh/casshome"
}
