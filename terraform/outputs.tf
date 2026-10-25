output "bastion_public_ip" {
  value = azurerm_public_ip.bastion.ip_address
}

output "control_plane_name" {
  value = azurerm_linux_virtual_machine.control_plane.name
}

output "control_plane_private_ip" {
  value = local.control_plane_ip
}

output "worker_private_ips" {
  value = local.workers
}

output "nat_egress_ip" {
  description = "All outbound traffic from the cluster leaves from this IP."
  value       = azurerm_public_ip.nat.ip_address
}

output "resource_group" {
  value = azurerm_resource_group.lab.name
}

# Inventory and SSH config for the next steps

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/hosts.yml.tftpl", {
    admin_username   = var.admin_username
    bastion_ip       = azurerm_public_ip.bastion.ip_address
    control_plane    = azurerm_linux_virtual_machine.control_plane.name
    control_plane_ip = local.control_plane_ip
    workers          = local.workers
  })
}

resource "local_file" "ssh_config" {
  filename        = "${path.module}/../ssh_config"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/ssh_config.tftpl", {
    admin_username   = var.admin_username
    bastion_ip       = azurerm_public_ip.bastion.ip_address
    control_plane    = azurerm_linux_virtual_machine.control_plane.name
    control_plane_ip = local.control_plane_ip
    workers          = local.workers
  })
}
