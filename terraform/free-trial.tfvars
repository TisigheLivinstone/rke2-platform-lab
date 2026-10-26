# For subscriptions capped at 4 vCPUs per region, such as an Azure Free Trial.
# Same layout as production, scaled down: bastion, control plane and 2 workers,
# 1 vCPU each. The control plane also gets a data disk so storage still has
# three machines. Use with: terraform apply -var-file=free-trial.tfvars

worker_count            = 2
control_plane_data_disk = true

bastion_vm_size       = "Standard_F1as_v7"  # 1 vCPU, 4 GiB
control_plane_vm_size = "Standard_F1ams_v7" # 1 vCPU, 8 GiB
worker_vm_size        = "Standard_F1ams_v7" # 1 vCPU, 8 GiB

# v7 sizes only support NVMe disk controllers.
disk_controller_type = "NVMe"
