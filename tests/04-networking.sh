#!/usr/bin/env bash
# Checks pod networking: Cilium health, WireGuard encryption, network policies
# and Hubble. Run from the repo root after the networking playbook:
#   bash tests/04-networking.sh
set -uo pipefail

PORT=16443
K="kubectl --kubeconfig $HOME/.kube/rke2lab.yaml --server https://127.0.0.1:$PORT"
SSH="ssh -F ssh_config -o BatchMode=yes -o ConnectTimeout=15"
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
CP=$(terraform -chdir=terraform output -raw control_plane_name)

cleanup() {
  $K delete namespace netpol-demo netpol-outside --wait=false >/dev/null 2>&1
  [ -n "${TUNNEL_PID:-}" ] && kill "$TUNNEL_PID" 2>/dev/null
}
trap cleanup EXIT

$SSH -N -o ExitOnForwardFailure=yes -L "$PORT:127.0.0.1:6443" "$CP" &
TUNNEL_PID=$!
sleep 5
agents=$($K -n kube-system get pods -l k8s-app=cilium -o name)
nodes=$($K get nodes --no-headers | wc -l)

echo "Cilium"
healthy=0
for a in $agents; do
  $K -n kube-system exec "$a" -c cilium-agent -- cilium-dbg status --brief 2>/dev/null | grep -q '^OK$' && healthy=$((healthy + 1))
done
if [ "$healthy" -eq "$nodes" ]; then ok "Cilium agent healthy on $healthy of $nodes nodes"; else bad "Cilium agent healthy on $healthy of $nodes nodes"; fi
if $K -n kube-system rollout status deploy/hubble-relay --timeout=60s >/dev/null 2>&1; then ok "Hubble Relay is running"; else bad "Hubble Relay is not ready"; fi

echo
echo "Encryption between nodes"
encrypted=0
for a in $agents; do
  status=$($K -n kube-system exec "$a" -c cilium-agent -- cilium-dbg encrypt status 2>/dev/null)
  echo "$status" | grep -q 'Encryption: Wireguard' && echo "$status" | grep -q "Peers: $((nodes - 1))" && encrypted=$((encrypted + 1))
done
if [ "$encrypted" -eq "$nodes" ]; then ok "WireGuard on every node, each with $((nodes - 1)) peers"; else bad "WireGuard fully set up on $encrypted of $nodes nodes"; fi

echo
echo "Network policies"
$K apply -f tests/04-demo.yaml >/dev/null
$K apply -n netpol-demo -f kubernetes/network-policies/default-deny.yaml >/dev/null
$K -n netpol-demo rollout status deploy/backend --timeout=180s >/dev/null 2>&1
$K -n netpol-demo wait --for=condition=Ready pod/frontend pod/intruder --timeout=180s >/dev/null 2>&1
$K -n netpol-outside wait --for=condition=Ready pod/outsider --timeout=180s >/dev/null 2>&1
try() { $K -n "$1" exec "$2" -- wget -qO- -T 5 "$3" 2>/dev/null | grep -qi "$4"; }

if try netpol-demo frontend http://backend nginx; then ok "frontend reaches backend (the one allowed connection)"; else bad "frontend cannot reach backend"; fi
if $K -n netpol-demo exec intruder -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then ok "DNS still works under default deny"; else bad "DNS lookups are blocked"; fi
if try netpol-demo intruder http://backend nginx; then bad "intruder reached backend"; else ok "intruder in the same namespace cannot reach backend"; fi
if try netpol-outside outsider http://backend.netpol-demo nginx; then bad "a pod in another namespace reached backend"; else ok "a pod in another namespace cannot reach backend"; fi
if try netpol-outside outsider http://example.com 'example domain'; then
  if $K -n netpol-demo exec deploy/backend -- wget -qO- -T 5 http://example.com 2>/dev/null | grep -qi 'example domain'; then
    bad "backend reached the internet"
  else
    ok "backend cannot reach the internet (a pod without policies can)"
  fi
else
  bad "control check failed: a pod without policies could not reach the internet either"
fi

echo
echo "Hubble sees the blocked traffic"
sleep 5
drops=""
for a in $agents; do
  drops+=$($K -n kube-system exec "$a" -c cilium-agent -- hubble observe --namespace netpol-demo --verdict DROPPED --since 10m -o compact 2>/dev/null)
  drops+=$'\n'
done
if echo "$drops" | grep -q 'intruder' && echo "$drops" | grep -qi 'policy'; then
  ok "Hubble recorded the intruder's attempt as DROPPED by policy"
  echo "$drops" | grep -m1 'intruder' | sed 's/^/        /'
else
  bad "no DROPPED flow from the intruder in Hubble"
fi

echo
echo "Running the playbook again changes nothing"
LOG=$(mktemp)
(cd ansible && ansible-playbook playbooks/networking.yml > "$LOG" 2>&1)
changed=$(sed -n '/PLAY RECAP/,$p' "$LOG" | grep -Eo 'changed=[0-9]+' | cut -d= -f2 | awk '{s+=$1} END {print s+0}')
if grep -q 'failed=[1-9]' "$LOG"; then bad "networking.yml failed on a second run, see $LOG"
elif [ "$changed" -eq 0 ]; then ok "networking.yml reported changed=0"
else bad "networking.yml changed $changed task(s) on a second run, see $LOG"; fi

echo
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
