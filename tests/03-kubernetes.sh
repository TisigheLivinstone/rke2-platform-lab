#!/usr/bin/env bash
# Checks that the Kubernetes cluster works and stays locked down.
# Run from the repo root after the kubernetes playbook:  bash tests/03-kubernetes.sh
set -uo pipefail

KUBECONFIG_FILE="$HOME/.kube/rke2lab.yaml"
PORT=16443   # local end of the test's own tunnel, so it doesn't clash with yours
K="kubectl --kubeconfig $KUBECONFIG_FILE --server https://127.0.0.1:$PORT"
SSH="ssh -F ssh_config -o BatchMode=yes -o ConnectTimeout=15"
VERSION=$(grep '^rke2_version:' ansible/inventory/group_vars/all.yml | awk '{print $2}')
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

CP=$(terraform -chdir=terraform output -raw control_plane_name)
CP_IP=$(terraform -chdir=terraform output -raw control_plane_private_ip)

cleanup() {
  $K delete namespace smoke --wait=false >/dev/null 2>&1
  [ -n "${TUNNEL_PID:-}" ] && kill "$TUNNEL_PID" 2>/dev/null
}
trap cleanup EXIT

echo "The API is only reachable through the SSH tunnel"
if $SSH bastion "timeout 5 bash -c '</dev/tcp/$CP_IP/6443'" 2>/dev/null; then
  bad "the bastion can open port 6443 on the control plane directly"
else
  ok "port 6443 is closed even from the bastion"
fi
$SSH -N -o ExitOnForwardFailure=yes -L "$PORT:127.0.0.1:6443" "$CP" &
TUNNEL_PID=$!
sleep 5
server=$($K version -o json 2>/dev/null | grep -o '"gitVersion": *"[^"]*"' | tail -1 | cut -d'"' -f4)
if [ "$server" = "$VERSION" ]; then ok "kubectl reaches the API through the tunnel, version $server"; else bad "API version '$server', expected $VERSION"; fi

echo
echo "Nodes"
nodes=$($K get nodes --no-headers)
total=$(echo "$nodes" | wc -l); ready=$(echo "$nodes" | awk '$2 == "Ready"' | wc -l)
if [ "$ready" -eq 3 ] && [ "$total" -eq 3 ]; then ok "3 of 3 nodes Ready"; else bad "$ready of $total nodes Ready"; fi
if $K get node "$CP" -o jsonpath='{.spec.taints[*].key}' | grep -q CriticalAddonsOnly; then
  ok "$CP is tainted: no application pods on the control plane"
else
  bad "$CP has no CriticalAddonsOnly taint"
fi

echo
echo "System components"
# Look at what each component should be doing, not at raw pod status: a job
# that needed a retry leaves its failed attempt behind even when it succeeded.
cp_running=$($K -n kube-system get pods --no-headers | grep -E '^(etcd|kube-apiserver|kube-scheduler|kube-controller-manager)-' | awk '$3 == "Running"' | wc -l)
if [ "$cp_running" -eq 4 ]; then ok "etcd, API server, scheduler and controller manager are Running"; else bad "only $cp_running of 4 control plane components Running"; fi
for i in $(seq 1 30); do
  short=$( { $K -n kube-system get deploy -o jsonpath='{range .items[*]}{.metadata.name} {.status.readyReplicas} {.spec.replicas}{"\n"}{end}';
             $K -n kube-system get ds -o jsonpath='{range .items[*]}{.metadata.name} {.status.numberReady} {.status.desiredNumberScheduled}{"\n"}{end}'; } \
           | awk '$2 != $3 {print $1}')
  [ -z "$short" ] && break
  sleep 10
done
if [ -z "$short" ]; then ok "every Deployment and DaemonSet in kube-system has all replicas ready"; else bad "not fully ready: $(echo $short)"; fi
unfinished=$($K -n kube-system get jobs -o jsonpath='{range .items[*]}{.metadata.name} {.status.succeeded}{"\n"}{end}' | awk '$2 < 1 {print $1}')
if [ -z "$unfinished" ]; then ok "every RKE2 install job has completed"; else bad "jobs not completed: $(echo $unfinished)"; fi

echo
echo "An application runs, on the workers only"
$K apply -f tests/03-smoke.yaml >/dev/null
$K -n smoke rollout status deploy/web --timeout=300s >/dev/null 2>&1 \
  && $K -n smoke wait --for=condition=Ready pod/client --timeout=180s >/dev/null 2>&1 \
  && ok "test app is running" || bad "test app did not become ready"
web_nodes=$($K -n smoke get pods -l app=web -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u)
if echo "$web_nodes" | grep -q "$CP"; then bad "an app pod landed on the control plane"; else ok "no app pod on the control plane"; fi
if [ "$(echo "$web_nodes" | wc -l)" -eq 2 ]; then ok "the two app pods are on two different workers"; else bad "app pods on: $(echo $web_nodes)"; fi

echo
echo "Networking between nodes"
client_node=$($K -n smoke get pod client -o jsonpath='{.spec.nodeName}')
for ip in $($K -n smoke get pods -l app=web -o jsonpath='{.items[*].status.podIP}'); do
  node=$($K -n smoke get pods -l app=web -o jsonpath="{.items[?(@.status.podIP=='$ip')].spec.nodeName}")
  if $K -n smoke exec client -- wget -qO- -T 5 "http://$ip:8080" 2>/dev/null | grep -qi nginx; then
    ok "client on $client_node reaches the app pod on $node"
  else
    bad "client on $client_node cannot reach $ip on $node"
  fi
done
if $K -n smoke exec client -- wget -qO- -T 5 http://web.smoke.svc.cluster.local 2>/dev/null | grep -qi nginx; then
  ok "cluster DNS resolves the service name and the service answers"
else
  bad "web.smoke.svc.cluster.local did not answer"
fi

echo
echo "Security"
out=$($K apply --dry-run=server -f tests/03-privileged-pod.yaml 2>&1)
if echo "$out" | grep -q 'violates PodSecurity'; then ok "a privileged pod is rejected (CIS profile)"; else bad "privileged pod was not rejected: $out"; fi
if $SSH "$CP" "sudo rke2 etcd-snapshot save --name test >/dev/null 2>&1 && sudo rke2 etcd-snapshot list 2>/dev/null | grep -q test"; then
  ok "etcd snapshots can be taken and listed"
else
  bad "etcd snapshot failed"
fi

echo
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
