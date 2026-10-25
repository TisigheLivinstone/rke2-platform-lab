#!/usr/bin/env bash
# Checks that the network and VMs behave as designed.
# Run from the repo root after terraform apply:  bash tests/01-foundation.sh
set -uo pipefail

TF="terraform -chdir=terraform"
SSH="ssh -F ssh_config -o BatchMode=yes -o ConnectTimeout=15"
pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "Reading Terraform outputs"
BASTION_IP=$($TF output -raw bastion_public_ip)
NAT_IP=$($TF output -raw nat_egress_ip)
CP=$($TF output -raw control_plane_name)
WORKERS=$($TF output -json worker_private_ips | tr -d '{}"' | tr ',' '\n' | cut -d: -f1)
RG=$($TF output -raw resource_group)
echo "  bastion=$BASTION_IP  nat=$NAT_IP  control plane=$CP"

echo
echo "The only way in: SSH through the bastion"
check "bastion answers SSH from this machine" "$SSH bastion true"
for host in $CP $WORKERS; do
  check "$host reachable through the bastion" "$SSH $host true"
done

echo
echo "The only way out: NAT Gateway"
for host in $CP $WORKERS; do
  egress=$($SSH "$host" "curl -s --max-time 10 https://api.ipify.org" 2>/dev/null)
  if [ "$egress" = "$NAT_IP" ]; then ok "$host goes out through the NAT IP"; else bad "$host egress is '$egress', expected $NAT_IP"; fi
done

echo
echo "No inbound path to the cluster"
if command -v az >/dev/null; then
  # Every public IP in the resource group must belong to the bastion or the NAT Gateway.
  others=$(az network public-ip list -g "$RG" --query "[?!(contains(name, 'bastion') || contains(name, 'nat'))].name" -o tsv)
  if [ -z "$others" ]; then ok "only the bastion and NAT have public IPs"; else bad "unexpected public IPs: $others"; fi
  # The API port must not be open in any NSG rule.
  open6443=$(az network nsg list -g "$RG" --query "[].securityRules[?contains(destinationPortRange || '', '6443') || contains(join(',', destinationPortRanges), '6443')].name" -o tsv)
  if [ -z "$open6443" ]; then ok "no NSG rule opens port 6443"; else bad "port 6443 opened by: $open6443"; fi
else
  echo "  SKIP  az CLI not found, skipping public IP and NSG checks"
fi

echo
echo "Data disks (workers only)"
for host in $WORKERS; do
  info=$($SSH "$host" 'd=$(readlink -f /dev/disk/azure/scsi1/lun0) && echo "$d $(lsblk -bdno SIZE "$d") [$(lsblk -no FSTYPE "$d" | tr -d "\n ")]"' 2>/dev/null)
  dev=$(echo "$info" | awk '{print $1}'); size=$(echo "$info" | awk '{print $2}'); fs=$(echo "$info" | awk '{print $3}')
  if [ -n "$dev" ] && [ "$size" = "34359738368" ] && [ "$fs" = "[]" ]; then
    ok "$host: lun0 -> $dev, 32 GiB, empty"
  else
    bad "$host: lun0 check failed ($info)"
  fi
done
check "$CP has no data disk at lun0" "! $SSH $CP test -e /dev/disk/azure/scsi1/lun0"

echo
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
