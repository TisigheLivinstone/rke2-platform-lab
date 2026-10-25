variable "subscription_id" {
  description = "Azure subscription to deploy into."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "westus2"
}

variable "prefix" {
  description = "Short name used in every resource name."
  type        = string
  default     = "rke2lab"
}

variable "admin_username" {
  description = "Linux user created on every VM."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key allowed on every VM."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "admin_cidr" {
  description = "Your public IP in CIDR form (for example 203.0.113.10/32). Only this address can SSH to the bastion."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid CIDR and must not be 0.0.0.0/0."
  }
}

variable "vnet_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.10.0.0/27"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.10.1.0/24"
}

variable "bastion_vm_size" {
  type    = string
  default = "Standard_B1s"
}

variable "control_plane_vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "worker_vm_size" {
  description = "Worker size. 16 GiB leaves room for storage and monitoring added later."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "worker_count" {
  description = "Number of workers. At least 3, so storage can keep 3 copies on 3 different machines."
  type        = number
  default     = 3

  validation {
    condition     = var.worker_count >= 3
    error_message = "worker_count must be at least 3."
  }
}

variable "data_disk_size_gb" {
  description = "Size of the empty data disk attached to each worker at LUN 0."
  type        = number
  default     = 32
}

variable "auto_shutdown_time" {
  description = "Daily VM shutdown time (HHmm). Set to null to turn it off."
  type        = string
  default     = "2200"
}

variable "auto_shutdown_timezone" {
  type    = string
  default = "W. Central Africa Standard Time"
}

variable "tags" {
  type = map(string)
  default = {
    project = "rke2-platform-lab"
    env     = "lab"
  }
}
