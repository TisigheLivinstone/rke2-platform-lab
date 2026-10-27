# RKE2 Platform Lab

A self-managed Kubernetes platform on Azure VMs: RKE2, Cilium and Rook-Ceph,
with monitoring, backups and GitOps on top. I build it one layer at a time.
Each layer is deployed and tested before the next one starts, and each write-up
explains what problem the layer solves and why I chose it over the alternatives.

![Azure foundation: network and compute](docs/architecture/azure-foundation.drawio.png)

## Parts

| Part | Layer | Status |
|---|---|---|
| 1 | [Azure foundation](docs/01-azure-foundation.md): private network, bastion, NAT Gateway, VMs | Deployed and tested |
| 2 | [Configuration management](docs/02-configuration-management.md): Ansible OS baseline for every VM | Deployed and tested |
| 3 | [Kubernetes with RKE2](docs/03-kubernetes.md): CIS-hardened cluster, API through an SSH tunnel | In progress |
| 4 | Pod networking with Cilium | |
| 5 | Storage with Rook-Ceph | |
| 6 | Monitoring | |
| 7 | Backups and recovery | |
| 8 | GitOps and CI | |

## Running it

[docs/runbook.md](docs/runbook.md) has every step, from a blank Windows machine
to a deployed and tested lab, plus the problems I hit along the way and their
fixes. In short, from WSL:

```bash
terraform -chdir=terraform apply -var-file=free-trial.tfvars   # Part 1
bash tests/01-foundation.sh
cd ansible && ansible-playbook playbooks/baseline.yml && cd ..     # Part 2
bash tests/02-automation.sh
cd ansible && ansible-playbook playbooks/kubernetes.yml && cd ..   # Part 3
bash tests/03-kubernetes.sh
```

`ansible-playbook site.yml` runs every Ansible part in order.

`free-trial.tfvars` fits the layout into the 4 vCPUs an Azure Free Trial allows
per region (2 workers, 1 vCPU VMs). Without it you get the production layout:
a dedicated control plane and 3 workers.
