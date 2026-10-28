# Runbook

How to rebuild the lab by hand, from a blank Windows machine to a deployed and
tested platform. Each command is followed by what it does. Each part of the
series adds its steps here.

## 1. One-time setup

### Install WSL

In an Administrator PowerShell:

```powershell
wsl --install -d Ubuntu
```

Installs WSL and an Ubuntu Linux inside Windows. Restart Windows when it asks,
then open Ubuntu from the Start menu and create a Linux user and password.

### Let Linux file permissions work on the C: drive

Inside Ubuntu:

```bash
sudo nano /etc/wsl.conf
```

Opens WSL's settings file. Add these lines and save:

```ini
[automount]
options = "metadata,umask=22,fmask=11"
```

By default the C: drive is mounted with every file open to everyone. SSH then
refuses private keys stored there, and Ansible ignores `ansible.cfg` in a folder
anyone can write to. This setting makes Linux permissions stick on C:.

Back in PowerShell:

```powershell
wsl --shutdown
```

Stops WSL so the new setting applies the next time Ubuntu opens.

### Install Ansible, unzip and git

```bash
sudo apt update && sudo apt install -y ansible unzip git
```

Refreshes Ubuntu's package list, then installs Ansible (which already includes
the `community.general` collection the lab uses), `unzip` for the Terraform
download, and `git`.

### Install Terraform

```bash
VERSION=1.15.8
cd /tmp
curl -fsSLO https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_linux_amd64.zip
curl -fsSLO https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_SHA256SUMS
```

Downloads Terraform and HashiCorp's list of official checksums.

```bash
grep linux_amd64.zip terraform_${VERSION}_SHA256SUMS | sha256sum -c -
```

Checks the download matches HashiCorp's checksum. It must print `OK`;
anything else means the file is damaged or not the real one, so stop.

```bash
mkdir -p ~/.local/bin && unzip -o terraform_${VERSION}_linux_amd64.zip terraform -d ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile && source ~/.profile
terraform version
```

Puts the `terraform` program in a folder in your home directory, adds that folder
to your PATH so the shell finds it, and prints the version to confirm.

### Log in to Azure

```bash
az account show
```

If the Azure CLI is installed on Windows, WSL can use it and its login as is,
and this prints your subscription. If it prints an error, install the Azure CLI
and log in:

```bash
az login
az account set --subscription "<subscription id>"
```

`az login` opens a browser to sign in. `az account set` picks which subscription
Terraform will deploy into, in case your account has more than one.

### Create an SSH key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/rke2lab
```

Creates a key pair: `~/.ssh/rke2lab` (private, stays on your machine) and
`~/.ssh/rke2lab.pub` (public, Terraform copies it onto every VM). The VMs have
password logins turned off, so this key is the only way in.

### Get the code

```bash
cd /mnt/c/Users/<you>/Documents
git clone https://github.com/TisigheLivinstone/rke2-platform-lab.git
cd rke2-platform-lab
```

Downloads the repo onto the C: drive, so Windows editors can open the same
files Ubuntu works on. Every command from here on runs from this folder.

## 2. Configure

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Creates your own settings file from the example. It's listed in `.gitignore`,
so your subscription ID and IP never end up in git.

```bash
curl -s https://ifconfig.me
```

Prints your public IP. The bastion will only accept SSH from this address.

Then edit `terraform/terraform.tfvars`:

```hcl
subscription_id     = "<subscription id>"
admin_cidr          = "<your public IP>/32"
ssh_public_key_path = "~/.ssh/rke2lab.pub"
```

`/32` means exactly that one IP address.

```bash
az vm list-usage -l southafricanorth --query "[?name.value=='cores']" -o table
```

On a Free Trial, shows how many of the region's 4 vCPUs are already used. The
trial layout needs all 4, so this should show 0 in use.

## 3. Part 1: Azure foundation

```bash
terraform -chdir=terraform init
```

Downloads the Azure provider Terraform needs. Only needed the first time, or
after the provider version changes.

```bash
terraform -chdir=terraform plan -var-file=free-trial.tfvars -out=tfplan
```

Compares the code with what exists in Azure and lists everything it would
create, change or delete, without doing anything. `-var-file` applies the
smaller trial sizes; `-out` saves the plan so the next step does exactly this
and nothing else. Read it before going on.

```bash
terraform -chdir=terraform apply tfplan
```

Creates the network, bastion, NAT Gateway, VMs and disks from the saved plan,
then writes the Ansible inventory and `ssh_config` with the real IPs. Takes
about four minutes.

```bash
bash tests/01-foundation.sh
```

Checks the result against the design: SSH works only through the bastion, the
VMs go out only through the NAT Gateway, nothing else has a public IP, and each
storage node has its empty data disk. Expect `12 passed, 0 failed`.

On a subscription without the 4 vCPU cap, leave out `-var-file=free-trial.tfvars`
to get the production layout (dedicated control plane, 3 workers).

## 4. Part 2: OS baseline with Ansible

```bash
cd ansible
ansible all -m ping
```

Logs in to all four VMs (the bastion directly, the others through it) and runs
a small test. Every VM should answer `pong`. Changes nothing.

```bash
ansible-playbook playbooks/baseline.yml
```

Applies the baseline to every VM: installs updates, turns on daily security
updates without automatic reboots, syncs the clock, sets UTC, caps the journal,
pins each VM's own name to its IP, and hardens SSH. Reboots a VM only if an
update needs it, one at a time. About 10 minutes.

```bash
cd ..
bash tests/02-automation.sh
```

Runs the playbook again (it must change nothing), reads every setting back from
each VM, and checks that password logins are refused. Expect `8 passed, 0 failed`.

## 5. Part 3: Kubernetes with RKE2

### Install kubectl

```bash
VERSION=v1.36.5
cd /tmp
curl -fsSLO https://dl.k8s.io/release/${VERSION}/bin/linux/amd64/kubectl
curl -fsSLO https://dl.k8s.io/release/${VERSION}/bin/linux/amd64/kubectl.sha256
echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -
install -m 0755 kubectl ~/.local/bin/kubectl
```

Downloads kubectl, the command line tool for Kubernetes, at the same version as
the cluster, checks it against the official checksum (it must print `OK`) and
installs it next to Terraform. Then go back to the repo folder.

### Build the cluster

```bash
cd ansible
ansible-playbook playbooks/kubernetes.yml
cd ..
```

Installs RKE2 on cp-1 and starts the control plane, then installs it on the
workers and joins them to cp-1. Waits until all three nodes are Ready, labels
the workers, and copies the admin kubeconfig to `~/.kube/rke2lab.yaml`. The
join token is created in `~/.rke2lab/` on the first run. Neither file goes in
the repo. About 15 minutes.

### Reach the API

```bash
ssh -F ssh_config -N -L 6443:127.0.0.1:6443 rke2lab-cp-1 &
```

Opens an SSH tunnel through the bastion: anything sent to port 6443 on your
machine arrives at the API server on cp-1. `-N` means no shell, and `&` keeps it
running in the background. Port 6443 is never opened in Azure.

```bash
export KUBECONFIG=~/.kube/rke2lab.yaml
kubectl get nodes
```

Tells kubectl which cluster to use, then lists the nodes. All three should
show `Ready`. Stop the tunnel with `kill %1` when you're done.

### Test

```bash
bash tests/03-kubernetes.sh
```

Opens its own tunnel, then checks the API is private, the nodes and system
components are healthy, a test app runs only on the workers, pods reach each
other across VMs, a privileged pod is rejected, an etcd snapshot works, and a
second run of the playbook changes nothing. Removes its test app at the end.
Expect `16 passed, 0 failed`.

## 6. Part 4: Pod networking with Cilium

### Configure Cilium

```bash
cd ansible
ansible-playbook playbooks/networking.yml
cd ..
```

Writes the Cilium settings (WireGuard, Hubble, Relay and UI) into the folder
RKE2 watches on cp-1. RKE2 re-applies its Cilium chart with them, and the
Cilium agent restarts one node at a time. The playbook waits until Hubble Relay
is running and every node reports WireGuard. About 5 minutes.

### Test

```bash
bash tests/04-networking.sh
```

Opens its own tunnel, then checks Cilium is healthy on every node, WireGuard is
on with the other two nodes as peers, and the policies in a demo namespace
allow only frontend to backend. Checks Hubble recorded the intruder's blocked
attempt, and that a second run of the playbook changes nothing. Removes the
demo namespaces at the end. Expect `10 passed, 0 failed`.

```bash
bash tests/03-kubernetes.sh
```

The Part 3 tests again, to make sure the new network settings broke nothing.
Expect `16 passed, 0 failed`.

### Open the Hubble UI

```bash
kubectl -n kube-system port-forward svc/hubble-ui 12000:80
```

With the tunnel from Part 3 running, forwards port 12000 on your machine to the
Hubble UI. Browse to http://localhost:12000 and pick a namespace to see its
flows. Stop it with Ctrl+C.

## 7. Part 5: Storage with Rook-Ceph

### Install Rook and Ceph

```bash
cd ansible
ansible-playbook playbooks/storage.yml
cd ..
```

Writes three charts to the folder RKE2 watches on cp-1: the Rook operator, the
Ceph CSI drivers, and the Ceph cluster. RKE2 installs them, Rook prepares the
empty data disk on each node, and starts the Ceph mons, mgr and OSDs. The
playbook waits until Ceph reports `HEALTH_OK`, an OSD runs on every node, the
CSI driver is up and `ceph-block` is the default StorageClass. About 15 minutes
on a first run, mostly image downloads.

### Test

```bash
bash tests/05-storage.sh
```

Opens its own tunnel, then checks Ceph's health, mons and OSDs, that the pool
keeps 3 copies on 3 different hosts, and that a file written to a volume on one
worker can be read on the other. Stops the OSD on one worker for a while to
show the volume still works and Ceph reports the missing copy, then brings it
back and waits for `HEALTH_OK`. Removes its demo namespace at the end. Expect
`14 passed, 0 failed`.

```bash
bash tests/04-networking.sh
bash tests/03-kubernetes.sh
```

The Part 4 and Part 3 tests again. Expect `10 passed` and `16 passed`.

### Check Ceph by hand

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
```

Runs `ceph -s` in the toolbox pod: health, mons in quorum, OSDs up, and how
full the disks are.

### Open the Ceph dashboard

```bash
kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' | base64 -d; echo
```

Prints the dashboard's `admin` password, which Rook generated at install.

```bash
kubectl -n rook-ceph port-forward svc/rook-ceph-mgr-dashboard 8443:8443
```

With the tunnel from Part 3 running, forwards port 8443 to the dashboard.
Browse to https://localhost:8443 (self-signed certificate, so the browser warns
once) and log in as `admin`. Stop it with Ctrl+C.

## Day to day

```bash
az vm start --ids $(az vm list -g rke2lab-rg --query "[].id" -o tsv)
```

Starts all the lab VMs. They shut themselves down at 22:00 every night.

```bash
az vm deallocate --ids $(az vm list -g rke2lab-rg --query "[].id" -o tsv)
```

Stops all the VMs and releases their hardware, so compute stops costing money.
Disks and public IPs keep a small daily cost.

```bash
ssh -F ssh_config rke2lab-worker-1
```

Opens a shell on a VM through the bastion, using the SSH config Terraform wrote.

```bash
terraform -chdir=terraform destroy -var-file=free-trial.tfvars
```

Deletes everything this lab created in Azure. Costs drop to zero. Sections 3 to
7 rebuild it in about 50 minutes.

## Troubleshooting

Problems I actually hit, and the fix for each.

| Symptom | Cause | Fix |
|---|---|---|
| SSH to the bastion times out after working before | Your home IP changed, and the NSG only allows the old one | Update `admin_cidr` in `terraform.tfvars`, run `terraform apply` again |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` after a rebuild | New VMs, same private IPs | `terraform apply` resets the lab's `known_hosts` file; or delete `known_hosts` in the repo root |
| `UNPROTECTED PRIVATE KEY FILE`, or Ansible ignores `ansible.cfg` | C: drive mounted without Linux permissions | The `/etc/wsl.conf` change in section 1, then `wsl --shutdown` |
| `OperationNotAllowed ... exceeding approved Total Regional Cores quota` | Free Trial allows 4 vCPUs per region | Use `free-trial.tfvars`, and a region with nothing else running in it |
| Nodes stay `NotReady`; `helm-install-rke2-cilium` shows `UnexpectedAdmissionError` | The control plane's default CPU reservations fill the 1 vCPU cp-1, so the Cilium install job can't be placed | `control-plane-resource-requests` in the server config (already set) |
| `Wait for WireGuard to be active` retries and fails, yet `cilium-dbg encrypt status` shows WireGuard on every node | The check piped kubectl into `grep -q` under `set -o pipefail`. grep exits at the first match, kubectl gets a broken pipe (exit 141), and pipefail reports a failure | Capture the output first, then grep it (already fixed in the role and the test) |
| Ceph is `HEALTH_OK` or close, but PVCs stay `Pending` and there are no `rook-ceph.rbd.csi.ceph.com` pods | Since Rook v1.20 the CSI drivers are a separate chart (`ceph-csi-drivers`), and only the operator and cluster charts were installed | Install the drivers chart with Rook's values (already in the role: `ceph-csi-drivers.yaml.j2`) |
| `HEALTH_WARN ... auth client entities with insecure key types` | The cluster chart gives the CSI keys the old `aes` type, meant for kernels before 7.0 | On kernel 7.0+, set the CSI `keyType` to `aes256k` and rotate with `keyGeneration: 2` (already set) |
| `HEALTH_WARN Monitors are configured to allow auth using insecure key types` | Ceph still accepts `aes` keys | Check every key is `aes256k` first, then `allowedCiphers: [aes256k]` (already set) |
