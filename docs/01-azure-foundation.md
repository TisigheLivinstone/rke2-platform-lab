# Part 1: Azure foundation

![Azure foundation: network and compute](architecture/azure-foundation.drawio.png)

## The problem

Before there is any Kubernetes, storage or app, the platform needs somewhere to
live. I wanted that place to meet five conditions:

1. Nothing in the cluster is reachable from the internet.
2. I still have one controlled way in to build and operate it.
3. The machines can download packages, container images and Helm charts.
4. I can destroy all of it tonight and get the exact same thing back tomorrow.
5. If I forget it running, it does not quietly run up a bill.

This part covers those five points and nothing else.

## What gets built

| Resource | Name | Purpose |
|---|---|---|
| Resource group | `rke2lab-rg` | Holds everything. Deleting it deletes the lab. |
| Virtual network | `rke2lab-vnet` (`10.10.0.0/16`) | The private network |
| Public subnet | `snet-public` (`10.10.0.0/27`) | The bastion, the only VM with a public IP |
| Private subnet | `snet-private` (`10.10.1.0/24`) | The cluster VMs. No public IPs, no default internet access. |
| Bastion | `rke2lab-bastion` | The only way in, over SSH |
| NAT Gateway | `rke2lab-natgw` + `rke2lab-nat-pip` | The only way out, for the private subnet |
| NSGs | `rke2lab-public-nsg`, `rke2lab-private-nsg` | One firewall per subnet |
| Cluster VMs | `rke2lab-cp-1`, `rke2lab-worker-1` to `3` | Future control plane and workers |
| Data disks | `rke2lab-worker-N-data-disk` | One empty 32 GiB disk per worker, at LUN 0 |
| Shutdown schedules | | Every VM stops at 22:00 |

Traffic is simple to follow. I connect from my laptop to the bastion's public IP
on port 22, which the public NSG only accepts from my home IP. From the bastion
I can SSH to any cluster VM. Going out, the cluster VMs reach the internet
through the NAT Gateway, and replies come back on the same connections. Nothing
from the internet can start a connection to the private subnet: there is no
public IP there and no rule that would allow it. The Kubernetes API port (6443)
is not opened anywhere.

## Decisions

### RKE2 on VMs instead of AKS

AKS is what most teams on Azure should use. Microsoft runs the control plane,
etcd, upgrades and certificates. I am doing the harder thing on purpose. A lot
of companies (banks, public sector, manufacturing, telecoms) run Kubernetes on
their own hardware, often with no internet access, and there is no managed
service there. RKE2 is built for that situation. Azure VMs are just cheap
hardware I can throw away after each session.

The trade-off is that everything AKS would handle is now my job, and that is
exactly what I want to practise.

### Terraform instead of the portal, Bicep or Pulumi

Clicking through the portal can't be repeated or reviewed. Bicep and ARM
templates are solid but only work on Azure. Pulumi is nice but has a smaller
community. Terraform works the same way on Azure, AWS and GCP, `plan` shows
what will change before anything does, and it is what most job adverts ask for.

Terraform also writes the two files the next part needs (the Ansible inventory
and an SSH config), so I never copy IP addresses by hand.

For anyone coming from AWS: a VNet is a VPC, an NSG is close to a security
group, and a resource group has no direct equivalent (the closest is a
CloudFormation stack).

### A bastion VM instead of Azure Bastion

| Option | Rough cost | Verdict |
|---|---|---|
| Public IP on every VM | low | Every node gets scanned from the internet. No. |
| VPN gateway | ~$140/month | Good for a team, too much for one person |
| Azure Bastion | ~$140/month (Basic), more for Standard | The production choice, nothing to patch |
| B1s VM as a jump host | ~$8/month | Same idea, but I have to keep it patched |

The bastion VM gives the same shape as Azure Bastion, one locked-down way in,
for a fraction of the price. In production I would use Azure Bastion or a VPN.

### Two subnets instead of one

If the bastion and the cluster shared a subnet, anyone who broke into the
bastion would already be next to the nodes. With separate subnets, the bastion
sits outside the cluster's firewall and can only reach it on port 22.

### NAT Gateway for outbound traffic

The private VMs need to download things. I looked at four other ways to do that:

- **Azure default outbound access.** It works without any setup, but the IP is
  not fixed and Microsoft is retiring it for new networks. I turn it off
  explicitly with `default_outbound_access_enabled = false`.
- **A public IP on each VM.** That makes every VM reachable from the internet
  and defeats the point of a private subnet.
- **Load balancer outbound rules.** It works but needs more setup for the same result.
- **Azure Firewall.** It can control which sites the VMs are allowed to reach,
  which is great, but it costs roughly $900 a month.

The NAT Gateway is outbound only, has one fixed public IP and costs about $33 a
month plus data. A side benefit of the fixed IP: if a service ever needs to
allow-list the cluster, there is one address to give them.

One thing that differs from AWS: there, a NAT Gateway sits inside a public
subnet. In Azure it is not inside any subnet. It is its own resource with its
own public IP, attached to the subnets it serves. That is why the diagram shows
it outside both subnets, with an arrow from the private subnet.

### NSGs on the subnets

NSGs are free and enough to say "port 22 only, and only from here". I put them
on the subnets rather than on each VM's network card, so the whole policy is in
one place. The last rule in the private NSG denies everything else from the
VNet, which overrides Azure's default of allowing all traffic inside a VNet.

### Ubuntu 24.04

RKE2 supports it, it is free, it gets updates until 2029, and it is the Linux
most people have used. SLE Micro or RHEL would work just as well in a company
that already runs them.

### VM sizes

The bastion is a B1s, a burstable VM that runs on CPU credits. That is fine for
something that only forwards SSH. It is not fine for cluster nodes: when the
credits run out the VM is throttled, and etcd is very sensitive to that kind of
pause. A stalled etcd can lose its leader and freeze the cluster.

So the control plane is a D2s_v5 (2 vCPU, 8 GiB), enough for one Kubernetes
server with etcd. The workers are D4s_v5 (4 vCPU, 16 GiB) to leave room for
storage and monitoring later.

### Premium SSD

etcd writes to disk on every change and waits for the write to finish. A slow
disk means a slow and unstable cluster. Premium SSD keeps that latency low and
predictable. The cluster storage added later has the same need.

### The data disk at LUN 0

Each worker gets a second, empty disk that will later become cluster storage.
Linux names disks `/dev/sda`, `/dev/sdb` and so on in the order it finds them,
and that order can change after a reboot. The storage software wipes whatever
disk it is pointed at, so pointing it at `/dev/sdb` is a real risk: one day that
could be the OS disk.

Azure attaches data disks to numbered slots called LUNs, and Ubuntu on Azure
creates a fixed path for each slot. `/dev/disk/azure/scsi1/lun0` always means
the disk in slot 0, so that is the only path I use.

There are three workers because the storage layer will keep three copies of
everything, each on a different machine. Terraform refuses `worker_count`
below 3.

### Fixed private IPs

Later parts put IP addresses into config files (the Kubernetes server address,
certificate names). Static IPs (`.10` for the control plane, `.21` to `.23` for
the workers) mean those files never go stale.

### Auto-shutdown instead of budget alerts

Every VM shuts down at 22:00, so a lab I forget about costs me one evening, not a
weekend. I thought about budget alerts too and left them out. They only send an
email, they don't stop anything. My real cost control is destroying the lab
after each session. Some subscription types (free trial, sponsorship, some
student offers) don't support budgets at all, which would break `terraform
apply`. In a shared environment that runs for months, budgets with alerts to a
team channel make sense. Here they would not add anything.

### What is not here yet

I only add a resource in the part where it solves a problem. Backup storage is
the obvious example: until there is a cluster there is nothing to back up, and
an empty storage account is just one more thing to pay for and secure. The same
goes for DNS, load balancers and monitoring.

## What the next part needs from this one

At the end of this part there are four blank Ubuntu machines that can only be
reached through the bastion. Nothing is installed on them.

Terraform writes two files from the real IPs:

- `ansible/inventory/hosts.yml` lists the control plane, the workers, and which
  workers carry a data disk (`storage_nodes`).
- `ssh_config` tells SSH how to reach every VM through the bastion.

Setting up four machines by hand is slow, easy to get wrong and impossible to
repeat exactly. Part 2 uses those two files to do it with Ansible instead.

## Code

| File | Contents |
|---|---|
| `terraform/versions.tf` | Terraform and provider versions |
| `terraform/variables.tf` | Settings. Rejects `0.0.0.0/0` as the admin IP and fewer than 3 workers. |
| `terraform/network.tf` | Resource group, VNet, subnets, NAT Gateway, NSGs |
| `terraform/compute.tf` | Bastion, control plane, workers, data disks, shutdown schedules |
| `terraform/outputs.tf`, `terraform/templates/` | Outputs, the Ansible inventory and `ssh_config` |

## Deploy

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
terraform -chdir=terraform init
terraform -chdir=terraform plan -out=tfplan
terraform -chdir=terraform apply tfplan
```

## Test

```bash
bash tests/01-foundation.sh
```

| What should be true | How the script checks it |
|---|---|
| The only way in is SSH through the bastion | SSH to the bastion, then through it to every VM |
| The only way out is the NAT Gateway | Each VM asks a public IP echo service for its address; it must match the NAT IP |
| Nothing can reach the private subnet from outside | Only the bastion and the NAT Gateway own public IPs, and no NSG rule opens 6443 |
| Each worker has an empty 32 GiB disk at LUN 0 | `lun0` points to a 32 GiB disk with no filesystem |
| The control plane has no data disk | `lun0` does not exist on cp-1 |

### Results

Added after the first deployment.

## Cost

Rough figures for West US 2, pay-as-you-go. Prices change, so check the Azure
pricing calculator.

| | VMs running | VMs stopped |
|---|---|---|
| 3 × D4s_v5, 1 × D2s_v5, 1 × B1s | ~$0.70/hour | $0 |
| NAT Gateway | ~$0.045/hour | ~$0.045/hour |
| Disks and public IPs | ~$2/day | ~$2/day |

`terraform destroy` takes it to zero, and rebuilding takes about five minutes.
