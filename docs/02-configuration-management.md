# Part 2: Configuration management with Ansible

![Configuration management with Ansible](architecture/configuration-management.drawio.png)

## The problem

Part 1 left me with four fresh Ubuntu VMs and nothing on them. Before any
Kubernetes work, every one of them needs the same basics: current security
patches, a correct clock, SSH locked down, logs that can't fill the disk.

I could SSH into each VM and type the commands. That works once. It doesn't
work the second time, when I've forgotten a step, or on the fourth VM, when I
typo a setting, or after a rebuild, when I have to do it all again. Over time
the machines drift apart and nobody knows which one is "right".

So the problem for this part: **describe the OS baseline once, in code, and
apply it to every VM the same way, as often as needed, without breaking
anything that is already correct.**

## What gets built

Nothing new in Azure. This part changes what is inside the VMs.

| Piece | What it does |
|---|---|
| Inventory (`ansible/inventory/hosts.yml`) | Written by Terraform. Lists the VMs in groups: `bastion`, `cluster` (with `control_plane` and `workers`) and `storage_nodes`. |
| Group variables (`ansible/inventory/group_vars/`) | Settings per group, for example which hosts may forward SSH connections |
| Role `baseline` | Installs pending updates and reboots one VM at a time if needed, turns on daily security updates without automatic reboots, keeps chrony syncing the clock, sets UTC, caps the journal at 500 MB |
| Role `ssh_hardening` | Keys only, one allowed user, no root login, no agent or X11 forwarding, TCP forwarding only on the bastion and control plane |
| `site.yml` | The entry point. Each later part adds its playbook here. |

Ansible runs from WSL on my laptop. It connects to the bastion directly and to
the cluster VMs through the bastion, the same path I use by hand.

## Decisions

### Ansible instead of shell scripts, cloud-init, golden images or Puppet

- **A shell script over SSH** is where most people start. It runs top to
  bottom every time, so running it twice can install things twice or append
  the same line to a file twice. Making it safe to re-run means writing the
  checks yourself for every step.
- **cloud-init** runs once, on first boot. It is good for bootstrapping (Azure
  already uses it to create the user and install my SSH key), but it can't
  bring an existing VM back in line after a change.
- **A golden image built with Packer** bakes the baseline into the VM image.
  It boots fast and every VM starts identical, but every change means building
  and rolling out a new image. It's a good fit for large fleets. For four VMs
  that I rebuild often, it adds a pipeline without solving anything.
- **Puppet, Chef or Salt** keep an agent on every machine that pulls its
  config on a schedule. They are strong at keeping thousands of servers in
  line, but need a server and agents to run and secure.
- **Ansible** needs nothing on the VMs except SSH and Python, which Ubuntu
  already has. Each task describes the state I want ("chrony is installed and
  running") rather than a command to run, and only acts if the VM isn't
  already in that state. That property, idempotence, is what makes it safe to
  run again and again. The test for this part checks it directly.

### Running Ansible from WSL

Ansible doesn't run on Windows, so it runs in WSL (Ubuntu inside Windows).
Terraform and the tests run there too from this part on, so the whole toolchain
is Linux, which is also what a CI runner will use in Part 8.

In a team I wouldn't run this from a laptop at all. Ansible would run from a
CI pipeline or a management host inside the network. I considered running it
from the bastion, but that would mean keeping a key that opens every node on the
one machine that faces the internet.

### An inventory written by Terraform, not a dynamic inventory

Ansible has a plugin that asks Azure for the list of VMs every time it runs.
That is the right choice when VMs come and go on their own, like in a scale
set. Here, Terraform already knows every VM, so it writes the inventory once
per `apply`. Ansible then needs no Azure credentials at all, and the inventory
is a plain file I can read.

### Updates: install now, patch daily, never reboot on their own

The first run installs every pending update and reboots any VM that needs it,
**one VM at a time** (`throttle: 1`). After that, Ubuntu's unattended-upgrades
installs security fixes every day but never reboots by itself.

The reason is what comes next. A Kubernetes control plane rebooting at a random
time takes the API down. Two storage nodes rebooting together could take
storage below its safety margin. Reboots should happen when I decide, in order,
one node at a time. Later parts can hand that job to a tool built for it
(kured), which drains each node before rebooting it.

### chrony for time

Ubuntu on Azure already ships chrony set up to follow the Azure host's clock,
which is more accurate than reaching out to internet time servers. The role
only makes sure it stays installed and running, and the test checks that it is
actually in sync.

Correct time matters more than it sounds. TLS certificates are only valid
between two dates, etcd uses time-based leases, and storage systems like Ceph
raise warnings when nodes disagree on the time by even a fraction of a second.

### UTC everywhere

When something breaks across three machines, I want their logs to line up
without converting time zones in my head.

### A cap on the journal

The OS disks are 64 GiB. Without a limit, the systemd journal can grow until it
fills the disk, and a full disk stops a Kubernetes node. 500 MB is plenty of
history for a lab.

### SSH hardening

Azure already turns off password logins. The role makes the rest explicit:

| Setting | Why |
|---|---|
| `PermitRootLogin no` | Nobody logs in as root; I use my user and `sudo`, which leaves a trail |
| `AuthenticationMethods publickey` | Keys only, no passwords or keyboard prompts |
| `AllowUsers azureuser` | Any other account on the VM can't log in over SSH, even with a key |
| `MaxAuthTries 3`, `LoginGraceTime 30` | Guessing gets slow and dead connections get dropped |
| `AllowAgentForwarding no` | A compromised VM can't use my SSH agent to hop elsewhere |
| `AllowTcpForwarding` per group | `local` on the bastion (it forwards my connections to the private subnet) and the control plane (the Kubernetes API tunnel in Part 3). `no` on the workers. |

Settings go in `/etc/ssh/sshd_config.d/10-hardening.conf`. Ubuntu reads that
folder before the main config and the first value wins, so a low number keeps
these ahead of the file cloud-init writes. Before reloading SSH, the role runs
`sshd -t` to check the config, so a typo fails the run instead of locking me
out.

I left out fail2ban. It bans IPs that keep failing to log in, but the NSG
already drops SSH from every address except mine, so it would have nothing to do.

### Azure DNS instead of /etc/hosts

Many guides put every node in `/etc/hosts` so they can find each other by name.
Azure's built-in DNS already resolves VM names inside a VNet, so that would be
a second list to keep in sync. The test checks that every cluster VM resolves
every other one by name.

### What is not here yet

Kubernetes needs a few more OS changes (kernel modules, network settings, swap
off). Those belong to Part 3, where it's clear why they are needed. This part
stays generic: the same baseline would suit any Linux server.

## What the next part needs from this one

Three identical, patched cluster VMs with a correct clock and locked-down SSH,
and a tool that can change all of them at once from code.

The next problem is the one the platform exists for: running containers across
these machines, restarting them when they crash and moving them when a machine
fails. Part 3 installs Kubernetes (RKE2) with an Ansible role on top of this
baseline.

## Code

| File | Contents |
|---|---|
| `ansible/ansible.cfg` | Points Ansible at the inventory and roles |
| `ansible/requirements.yml` | The one extra collection used (`community.general`, for the timezone module) |
| `ansible/inventory/group_vars/` | Shared settings and the per-group forwarding rule |
| `ansible/roles/baseline/` | Updates, reboots, unattended upgrades, chrony, timezone, journal limit |
| `ansible/roles/ssh_hardening/` | The sshd drop-in, checked with `sshd -t` before reload |
| `ansible/playbooks/baseline.yml` | Applies both roles, cluster VMs first and the bastion last |
| `ansible/site.yml` | Runs everything in order |
| `terraform/templates/hosts.yml.tftpl` | Now also lists the bastion and the new group names |

## Run it

From WSL, in the repo folder:

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml -p collections
ansible-playbook site.yml
```

## Test

```bash
bash tests/02-automation.sh
```

| What should be true | How the script checks it |
|---|---|
| Ansible can reach every VM | `ansible all -m ping` succeeds on all four |
| The baseline applies cleanly | `site.yml` completes without errors |
| Running it again changes nothing | A second run reports `changed=0` on every VM |
| The baseline is really there | `tests/02-verify.yml` reads each VM: chrony in sync, UTC, daily security updates without auto-reboot, no pending updates or reboots, journal capped, every SSH setting as sshd actually sees it (`sshd -T`), and cluster names resolving through Azure DNS |
| Passwords are refused | An SSH login that only offers a password is rejected with `Permission denied (publickey)` on every VM |

### Results

Added after the first run.
