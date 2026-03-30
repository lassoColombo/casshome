output "vm_ip" {
  description = "IP address of the k8s VM"
  value       = var.vm_ip
}

output "vm_id" {
  description = "Proxmox VM ID"
  value       = proxmox_virtual_environment_vm.k8s_node.vm_id
}

output "ssh_command" {
  description = "SSH command to connect to the VM"
  value       = "ssh ubuntu@${var.vm_ip}"
}
