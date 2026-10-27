# Runbook

How to rebuild the lab by hand, from a blank Windows machine to a deployed and
tested platform. Each command is followed by what it does. Each part of the
series adds its steps here.

## Prerequisites

| What | Why it's needed |
|---|---|
| An Azure subscription | Where everything runs. A Free Trial works, with the trial sizes. |
| Windows 10 or 11 with WSL | Ansible doesn't run on Windows, so the tools run in Ubuntu inside WSL |
| About 8 GB of RAM on the laptop | WSL, Terraform and Ansible are light, but the laptop also runs Windows |
| Internet access from home | Terraform and the Azure CLI talk to Azure; you SSH to the bastion |
| A GitHub account (optional) | Only to fork the repo instead of cloning it |

Tools, all installed in the steps below:

| Tool | Version used | Used for |
|---|---|---|
| Ubuntu (WSL) | 26.04 | The Linux machine everything runs from |
| Terraform | 1.15.8 | Creates the Azure resources (Part 1) |
| Ansible | core 2.20 | Configures the VMs (Part 2 onwards) |
| Azure CLI | 2.x | Logs Terraform in to Azure; starts and stops the VMs |
| OpenSSH | from Ubuntu | Connects to the VMs through the bastion |
| git | from Ubuntu | Gets the code |

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
ansible-playbook site.yml
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

Deletes everything this lab created in Azure. Costs drop to zero. Sections 3 and
4 rebuild it in about 15 minutes.

## Troubleshooting

Problems I actually hit, and the fix for each.

| Symptom | Cause | Fix |
|---|---|---|
| SSH to the bastion times out after working before | Your home IP changed, and the NSG only allows the old one | Update `admin_cidr` in `terraform.tfvars`, run `terraform apply` again |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` after a rebuild | New VMs, same private IPs | `terraform apply` resets the lab's `known_hosts` file; or delete `known_hosts` in the repo root |
| `UNPROTECTED PRIVATE KEY FILE`, or Ansible ignores `ansible.cfg` | C: drive mounted without Linux permissions | The `/etc/wsl.conf` change in section 1, then `wsl --shutdown` |
| Your password is shown as you type it | `sudo` started through `wsl -e` from PowerShell | Run `sudo` commands in the Ubuntu window instead |
| `OperationNotAllowed ... exceeding approved Total Regional Cores quota` | Free Trial allows 4 vCPUs per region | Use `free-trial.tfvars`, and a region with nothing else running in it |
| `SkuNotAvailable` for a VM size | That size isn't offered to your subscription in that region | `az vm list-skus -l <region> --size <size> -o table`, then pick another size or region |
| A test reports a problem but lists nothing after it | The Windows `az` prints blank Windows lines when called from WSL | Already handled in the tests; if you write a new check, strip whitespace from `az` output |
