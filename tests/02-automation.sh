#!/usr/bin/env bash
# Checks that Ansible can configure every VM, that running it twice changes
# nothing the second time, and that the baseline is really in place.
# Run from the repo root after terraform apply:  bash tests/02-automation.sh
set -uo pipefail
cd "$(dirname "$0")/../ansible" || exit 1

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
LOG=$(mktemp -d)

echo "Ansible reaches every VM"
hosts=$(ansible all --list-hosts | tail -n +2 | wc -l)
reached=$(ansible all -m ping -o 2>/dev/null | grep -c 'SUCCESS')
if [ "$reached" -eq "$hosts" ]; then ok "ping succeeded on $reached of $hosts VMs"; else bad "ping succeeded on $reached of $hosts VMs"; fi

echo
echo "First run applies the baseline"
if ansible-playbook site.yml > "$LOG/run1.log" 2>&1; then
  ok "site.yml completed"
else
  bad "site.yml failed, see $LOG/run1.log"
fi
sed -n '/PLAY RECAP/,$p' "$LOG/run1.log"

echo
echo "Second run changes nothing"
ansible-playbook site.yml > "$LOG/run2.log" 2>&1
changed=$(sed -n '/PLAY RECAP/,$p' "$LOG/run2.log" | grep -Eo 'changed=[0-9]+' | cut -d= -f2 | awk '{s+=$1} END {print s+0}')
if [ "${changed:-1}" -eq 0 ]; then ok "second run reported changed=0 on every VM"; else bad "second run changed $changed task(s), see $LOG/run2.log"; fi

echo
echo "The baseline is in place"
if ansible-playbook ../tests/02-verify.yml > "$LOG/verify.log" 2>&1; then
  ok "chrony, timezone, updates, journal limit, SSH settings and DNS all verified"
else
  bad "verification failed:"
  grep -E '^(TASK|fatal|failed)' "$LOG/verify.log" | grep -B1 -E '^(fatal|failed)'
fi

echo
echo "Password logins are refused"
for host in $(ansible all --list-hosts | tail -n +2); do
  out=$(ssh -F ../ssh_config -o BatchMode=yes -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive "$host" true 2>&1)
  if echo "$out" | grep -q 'Permission denied (publickey)'; then
    ok "$host only offers publickey"
  else
    bad "$host: unexpected answer: $out"
  fi
done

echo
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
