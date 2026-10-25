locals {
  ssh_public_key = file(pathexpand(var.ssh_public_key_path))

  control_plane_ip = cidrhost(var.private_subnet_cidr, 10)

  workers = {
    for i in range(var.worker_count) :
    "${var.prefix}-worker-${i + 1}" => cidrhost(var.private_subnet_cidr, 21 + i)
  }

  ubuntu_image = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

# Bastion (jump host)

resource "azurerm_public_ip" "bastion" {
  name                = "${var.prefix}-bastion-pip"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "bastion" {
  name                = "${var.prefix}-bastion-nic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.public.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.bastion.id
  }
}

resource "azurerm_linux_virtual_machine" "bastion" {
  name                            = "${var.prefix}-bastion"
  location                        = azurerm_resource_group.lab.location
  resource_group_name             = azurerm_resource_group.lab.name
  size                            = var.bastion_vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.bastion.id]
  tags                            = merge(var.tags, { role = "bastion" })

  admin_ssh_key {
    username   = var.admin_username
    public_key = local.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = local.ubuntu_image.publisher
    offer     = local.ubuntu_image.offer
    sku       = local.ubuntu_image.sku
    version   = local.ubuntu_image.version
  }
}

# Control plane

resource "azurerm_network_interface" "control_plane" {
  name                = "${var.prefix}-cp-1-nic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.private.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.control_plane_ip
  }
}

resource "azurerm_linux_virtual_machine" "control_plane" {
  name                            = "${var.prefix}-cp-1"
  location                        = azurerm_resource_group.lab.location
  resource_group_name             = azurerm_resource_group.lab.name
  size                            = var.control_plane_vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.control_plane.id]
  tags                            = merge(var.tags, { role = "control-plane" })

  admin_ssh_key {
    username   = var.admin_username
    public_key = local.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = local.ubuntu_image.publisher
    offer     = local.ubuntu_image.offer
    sku       = local.ubuntu_image.sku
    version   = local.ubuntu_image.version
  }
}

# Workers

resource "azurerm_network_interface" "worker" {
  for_each            = local.workers
  name                = "${each.key}-nic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.private.id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value
  }
}

resource "azurerm_linux_virtual_machine" "worker" {
  for_each                        = local.workers
  name                            = each.key
  location                        = azurerm_resource_group.lab.location
  resource_group_name             = azurerm_resource_group.lab.name
  size                            = var.worker_vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.worker[each.key].id]
  tags                            = merge(var.tags, { role = "worker" })

  admin_ssh_key {
    username   = var.admin_username
    public_key = local.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = local.ubuntu_image.publisher
    offer     = local.ubuntu_image.offer
    sku       = local.ubuntu_image.sku
    version   = local.ubuntu_image.version
  }
}

# One empty data disk per worker, kept for cluster storage. Attached at LUN 0 so it
# always shows up as /dev/disk/azure/scsi1/lun0, whatever /dev/sdX name it gets.
resource "azurerm_managed_disk" "data" {
  for_each             = local.workers
  name                 = "${each.key}-data-disk"
  location             = azurerm_resource_group.lab.location
  resource_group_name  = azurerm_resource_group.lab.name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  tags                 = merge(var.tags, { purpose = "cluster-storage" })
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  for_each           = local.workers
  managed_disk_id    = azurerm_managed_disk.data[each.key].id
  virtual_machine_id = azurerm_linux_virtual_machine.worker[each.key].id
  lun                = 0
  caching            = "None"
}

# Every VM shuts down at night

resource "azurerm_dev_test_global_vm_shutdown_schedule" "all" {
  for_each = var.auto_shutdown_time == null ? {} : merge(
    { bastion = azurerm_linux_virtual_machine.bastion.id },
    { control_plane = azurerm_linux_virtual_machine.control_plane.id },
    { for k, vm in azurerm_linux_virtual_machine.worker : k => vm.id },
  )

  virtual_machine_id    = each.value
  location              = azurerm_resource_group.lab.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone
  tags                  = var.tags

  notification_settings {
    enabled = false
  }
}
