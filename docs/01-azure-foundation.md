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
| Cluster VMs | `rke2lab-cp-1`, `rke2lab-worker-1`, `rke2lab-worker-2` | Future control plane and workers |
| Data disks | `rke2lab-<vm>-data-disk` | One empty 32 GiB disk at LUN 0 on each storage node (cp-1 and both workers here) |
| Shutdown schedules | | Every VM stops at 22:00 |

Everything runs in South Africa North, the closest Azure region to me, and the
only one where every VM size below was available to my subscription.

The layout above is scaled to fit an Azure Free Trial, which caps every region
at 4 vCPUs. The production version of the same design has a dedicated control
plane and at least three workers. That is the Terraform default; the trial
sizes live in `terraform/free-trial.tfvars`. The section on worker count below
explains the difference.

Traffic is simple to follow. I connect from my laptop to the bastion's public IP
on port 22, which the public NSG only accepts from my home IP. From the bastion
I can SSH to any cluster VM. Going out, the cluster VMs reach the internet
through the NAT Gateway, and replies come back on the same connections. Nothing
from the internet can start a connection to the private subnet: there is no
public IP there and no rule that would allow it. The Kubernetes API port (6443)
is not opened anywhere.

<!-- SCREENSHOT
Everything above sits in one resource group, which is also what makes cleanup a single command.
Capture: Azure portal > Resource groups > rke2lab-rg > Overview, with the full resource list visible.
Blur: subscription ID.
-->

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
| 1 vCPU VM as a jump host | ~$10 to $30/month | Same idea, but I have to keep it patched |

The bastion VM gives the same shape as Azure Bastion, one locked-down way in,
for a fraction of the price. In production I would use Azure Bastion or a VPN.

### Two subnets instead of one

If the bastion and the cluster shared a subnet, anyone who broke into the
bastion would already be next to the nodes. With separate subnets, the bastion
sits outside the cluster's firewall and can only reach it on port 22.

<!-- SCREENSHOT
In the portal the two subnets show up side by side, each with its own NSG, and only the private one has the NAT Gateway attached.
Capture: Virtual networks > rke2lab-vnet > Subnets (columns: name, address range, NSG, NAT gateway).
Blur: subscription ID.
-->

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

<!-- SCREENSHOT
The NAT Gateway lists the private subnet as the only subnet it serves, and one outbound public IP.
Capture: NAT gateways > rke2lab-natgw > Subnets, then Outbound IP (two screenshots, or one if both fit).
Blur: subscription ID.
-->

### NSGs on the subnets

NSGs are free and enough to say "port 22 only, and only from here". I put them
on the subnets rather than on each VM's network card, so the whole policy is in
one place. The last rule in the private NSG denies everything else from the
VNet, which overrides Azure's default of allowing all traffic inside a VNet.

<!-- SCREENSHOT
These are the inbound rules on the private subnet: SSH from the public subnet, everything between cluster VMs, and a deny for the rest of the VNet ahead of the Azure defaults.
Capture: Network security groups > rke2lab-private-nsg > Inbound security rules.
Blur: subscription ID.
-->

### Ubuntu 24.04

RKE2 supports it, it is free, it gets updates until 2029, and it is the Linux
most people have used. SLE Micro or RHEL would work just as well in a company
that already runs them.

### Two workers here, at least three in production

The Free Trial allows 4 vCPUs per region and the smallest VM has 1 vCPU, so a
bastion plus a control plane plus three workers (5 VMs) cannot fit. I kept the
bastion, because removing it would put a cluster node on the internet, and
dropped to two workers. The control plane gets a data disk as well, so the
storage layer still has three machines to work with.

For production I would use at least three dedicated workers, and keep the
control plane free of storage and application work:

- **Three copies of data need three machines.** The storage layer in Part 5
  keeps every piece of data on three different nodes. With fewer nodes it
  either cannot place the third copy or keeps two copies on one machine, which
  defeats the point.
- **Voting needs an odd number.** Storage monitors, like etcd, only work while
  a majority agrees. Three can lose one and still have a majority (2 of 3). Two
  cannot: losing one leaves 1 of 2, and storage stops.
- **Somewhere to move work to.** When a node fails or is drained for patching,
  its pods move to the others. With two workers, every drain puts the whole
  cluster on one machine. With three, there is still room to spread out.
- **A quiet control plane.** etcd needs fast, predictable disk writes. A
  control plane that also serves storage shares its disk and CPU with that
  work, so a busy storage node can slow down the whole cluster. In production
  it runs Kubernetes and nothing else.

Moving to the production layout is a variable change, not a redesign:
`worker_count = 3` and `control_plane_data_disk = false` (both defaults).

### VM sizes

**Production defaults:** a D2s_v5 (2 vCPU, 8 GiB) for the control plane, enough
for one Kubernetes server with etcd, and D4s_v5 (4 vCPU, 16 GiB) workers, with
room for storage and monitoring later.

**This deployment:** F1ams_v7 (1 vCPU, 8 GiB) for the three cluster VMs and
F1as_v7 (1 vCPU, 4 GiB) for the bastion, which together use exactly the 4 vCPUs
the trial allows. That is below the 2 vCPUs RKE2 recommends for a server node.
It is enough for the first parts; storage and monitoring will be tight, and the
write-ups for those parts will say where.

I avoided burstable B-series VMs for the cluster. They run on CPU credits and
get throttled when the credits run out, and etcd does not handle that kind of
pause well. A stalled etcd can lose its leader and freeze the cluster. The
F-series v7 sizes give a full, unthrottled vCPU.

The v7 sizes only support NVMe disk controllers, so this deployment sets
`disk_controller_type = "NVMe"`. The production v5 sizes use SCSI.

### Premium SSD

etcd writes to disk on every change and waits for the write to finish. A slow
disk means a slow and unstable cluster. Premium SSD keeps that latency low and
predictable. The cluster storage added later has the same need.

### The data disk at LUN 0

Each storage node gets a second, empty disk that will later become cluster
storage. Linux names disks in the order it finds them (`/dev/sdb`, or
`/dev/nvme0n2` on NVMe), and that order can change after a reboot. The storage
software wipes whatever disk it is pointed at, so pointing it at a kernel name
is a real risk: one day that name could be the OS disk.

Azure attaches data disks to numbered slots called LUNs, and Ubuntu on Azure
creates a fixed link for each slot. `/dev/disk/azure/data/by-lun/0` always means
the disk in slot 0, on SCSI and NVMe VMs alike, so that is the only path I use.

<!-- SCREENSHOT
On each storage node the data disk sits at LUN 0, next to the OS disk.
Capture: Virtual machines > rke2lab-worker-1 > Disks (OS disk and data disk with LUN 0 visible).
Blur: subscription ID.
-->

### Fixed private IPs

Later parts put IP addresses into config files (the Kubernetes server address,
certificate names). Static IPs (`.10` for the control plane, `.21` upwards for
the workers) mean those files never go stale.

### Auto-shutdown instead of budget alerts

Every VM shuts down at 22:00, so a lab I forget about costs me one evening, not a
weekend.

<!-- SCREENSHOT
Each VM carries its own shutdown schedule.
Capture: Virtual machines > rke2lab-cp-1 > Auto-shutdown (enabled, 22:00, time zone).
Blur: subscription ID.
--> I thought about budget alerts too and left them out. They only send an
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

At the end of this part there are three blank Ubuntu cluster VMs that can only
be reached through the bastion. Nothing is installed on them.

Terraform writes two files from the real IPs:

- `ansible/inventory/hosts.yml` lists the control plane, the workers, and which
  VMs carry a data disk (`storage_nodes`).
- `ssh_config` tells SSH how to reach every VM through the bastion.

Setting up several machines by hand is slow, easy to get wrong and impossible to
repeat exactly. Part 2 uses those two files to do it with Ansible instead.

## Code

| File | Contents |
|---|---|
| `terraform/versions.tf` | Terraform and provider versions |
| `terraform/variables.tf` | Settings, with production defaults. Rejects `0.0.0.0/0` as the admin IP. |
| `terraform/free-trial.tfvars` | Smaller sizes and 2 workers for a 4-vCPU subscription |
| `terraform/network.tf` | Resource group, VNet, subnets, NAT Gateway, NSGs |
| `terraform/compute.tf` | Bastion, control plane, workers, data disks, shutdown schedules |
| `terraform/outputs.tf`, `terraform/templates/` | Outputs, the Ansible inventory and `ssh_config` |

## Deploy

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
terraform -chdir=terraform init
terraform -chdir=terraform plan -var-file=free-trial.tfvars -out=tfplan
terraform -chdir=terraform apply tfplan
```

On a subscription without the 4-vCPU cap, leave out `-var-file=free-trial.tfvars`
to get the production layout.

## Test

```bash
bash tests/01-foundation.sh
```

| What should be true | How the script checks it |
|---|---|
| The only way in is SSH through the bastion | SSH to the bastion, then through it to every VM |
| The only way out is the NAT Gateway | Each VM asks a public IP echo service for its address; it must match the NAT IP |
| Nothing can reach the private subnet from outside | Only the bastion and the NAT Gateway own public IPs, and no NSG rule opens 6443 |
| Each storage node has an empty 32 GiB disk at LUN 0 | The LUN 0 link points to a 32 GiB disk with no filesystem that is not the OS disk |
| VMs that are not storage nodes have no data disk | The LUN 0 link does not exist on them (only applies to the production layout) |

### Results

First deployment on 26 October 2026, South Africa North, with `free-trial.tfvars`.
`terraform apply` created 34 resources in about four minutes, and every check passed:

```
The only way in: SSH through the bastion
  PASS  bastion answers SSH from this machine
  PASS  rke2lab-cp-1 reachable through the bastion
  PASS  rke2lab-worker-1 reachable through the bastion
  PASS  rke2lab-worker-2 reachable through the bastion

The only way out: NAT Gateway
  PASS  rke2lab-cp-1 goes out through the NAT IP
  PASS  rke2lab-worker-1 goes out through the NAT IP
  PASS  rke2lab-worker-2 goes out through the NAT IP

No inbound path to the cluster
  PASS  only the bastion and NAT have public IPs
  PASS  no NSG rule opens port 6443

Data disks
  PASS  rke2lab-cp-1: LUN 0 is /dev/nvme0n2, 32 GiB, empty, separate from the OS disk (/dev/nvme0n1)
  PASS  rke2lab-worker-1: LUN 0 is /dev/nvme0n2, 32 GiB, empty, separate from the OS disk (/dev/nvme0n1)
  PASS  rke2lab-worker-2: LUN 0 is /dev/nvme0n2, 32 GiB, empty, separate from the OS disk (/dev/nvme0n1)

Result: 12 passed, 0 failed
```

The data disk shows up as `/dev/nvme0n2` on every VM, which is exactly the kind
of kernel name I don't want to rely on. The test reaches it through the stable
`/dev/disk/azure/data/by-lun/0` link instead and confirms it is not the OS disk.

## Cost

Rough figures for South Africa North, pay-as-you-go rates. On the Free Trial
this comes out of the trial credit. Prices change, so check the Azure pricing
calculator.

| | VMs running | VMs stopped |
|---|---|---|
| 3 × F1ams_v7, 1 × F1as_v7 (4 vCPUs in total) | ~$0.30/hour | $0 |
| NAT Gateway | ~$0.05/hour | ~$0.05/hour |
| Disks and public IPs | ~$2/day | ~$2/day |

`terraform destroy` takes it to zero, and rebuilding takes about five minutes.
