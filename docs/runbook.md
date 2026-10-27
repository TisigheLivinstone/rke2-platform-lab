# Runbook

How to rebuild everything from a blank Windows machine, by hand, in order.
Each part of the series adds its steps here.

Everything after the one-time setup runs inside WSL (Ubuntu), from the repo
folder.

## 1. One-time setup

### WSL

In an Administrator PowerShell:

```powershell
wsl --install -d Ubuntu
```

Restart Windows when asked, open Ubuntu from the Start menu and create a Linux
user.

By default WSL mounts the C: drive with every file open to everyone. SSH then
refuses private keys stored there, and Ansible ignores `ansible.cfg` in a folder
anyone can write to. Turn on Linux permissions for C: by adding this to
`/etc/wsl.conf` inside Ubuntu (`sudo nano /etc/wsl.conf`):

```ini
[automount]
options = "metadata,umask=22,fmask=11"
```

Then restart WSL from PowerShell:

```powershell
wsl --shutdown
```

### Tools

Inside Ubuntu:

```bash
sudo apt update && sudo apt install -y ansible unzip git
```

Terraform, checked against HashiCorp's published checksum before use:

```bash
VERSION=1.15.8
cd /tmp
curl -fsSLO https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_linux_amd64.zip
curl -fsSLO https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_SHA256SUMS
grep linux_amd64.zip terraform_${VERSION}_SHA256SUMS | sha256sum -c -
mkdir -p ~/.local/bin && unzip -o terraform_${VERSION}_linux_amd64.zip terraform -d ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile && source ~/.profile
terraform version
```

Azure CLI: if it's installed on Windows, WSL can use it and its login as is
(`az account show` inside Ubuntu should print the subscription). Otherwise
install the Linux version and sign in:

```bash
az login
az account set --subscription "<subscription id>"
```

### SSH key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/rke2lab
```

The private key stays in `~/.ssh` inside Ubuntu, readable only by you.

### The repo

```bash
cd /mnt/c/Users/<you>/Documents
git clone https://github.com/TisigheLivinstone/rke2-platform-lab.git
cd rke2-platform-lab
```

Keeping it on C: means Windows editors can open the same files.

## 2. Configure

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
curl -s https://ifconfig.me        # your public IP, for admin_cidr
```

Fill in `terraform/terraform.tfvars`:

```hcl
subscription_id     = "<subscription id>"
admin_cidr          = "<your public IP>/32"
ssh_public_key_path = "~/.ssh/rke2lab.pub"
```

On an Azure Free Trial, check the region has 4 free vCPUs before deploying:

```bash
az vm list-usage -l southafricanorth --query "[?name.value=='cores']" -o table
```

## 3. Part 1: Azure foundation

```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan -var-file=free-trial.tfvars -out=tfplan
terraform -chdir=terraform apply tfplan
bash tests/01-foundation.sh        # expect 12 passed
```

Leave out `-var-file=free-trial.tfvars` on a subscription without the 4 vCPU
cap to get the production layout (dedicated control plane, 3 workers).

## 4. Part 2: OS baseline with Ansible

```bash
cd ansible
ansible all -m ping                # all 4 VMs answer pong
ansible-playbook site.yml
cd ..
bash tests/02-automation.sh        # expect 8 passed
```

## Day to day

| Task | Command |
|---|---|
| Start the VMs after the 22:00 shutdown | `az vm start --ids $(az vm list -g rke2lab-rg --query "[].id" -o tsv)` |
| Stop them and stop paying for compute | `az vm deallocate --ids $(az vm list -g rke2lab-rg --query "[].id" -o tsv)` |
| SSH to a VM | `ssh -F ssh_config rke2lab-worker-1` |
| Delete everything | `terraform -chdir=terraform destroy -var-file=free-trial.tfvars` |
| Rebuild from scratch | Sections 3 and 4 again, about 15 minutes |

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
| Test reports a problem but lists nothing after it | The Windows `az` prints blank Windows lines when called from WSL | Already handled in the tests; if you write a new check, strip whitespace from `az` output |
