#!/usr/bin/env bash
# Checks the Ceph storage: health, where the copies go, that data follows a pod
# to another node, and that losing a node loses nothing. Run from the repo root
# after the storage playbook:
#   bash tests/05-storage.sh
set -uo pipefail

PORT=16443
K="kubectl --kubeconfig $HOME/.kube/rke2lab.yaml --server https://127.0.0.1:$PORT"
SSH="ssh -F ssh_config -o BatchMode=yes -o ConnectTimeout=15"
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
CP=$(terraform -chdir=terraform output -raw control_plane_name)

# Runs a ceph command in the toolbox pod.
ceph() { $K -n rook-ceph exec deploy/rook-ceph-tools -- ceph "$@" 2>/dev/null; }

cleanup() {
  [ -n "${STOPPED_OSD:-}" ] && $K -n rook-ceph scale "$STOPPED_OSD" --replicas=1 >/dev/null 2>&1
  $K delete namespace storage-demo --wait=false >/dev/null 2>&1
  [ -n "${TUNNEL_PID:-}" ] && kill "$TUNNEL_PID" 2>/dev/null
}
trap cleanup EXIT

$SSH -N -o ExitOnForwardFailure=yes -L "$PORT:127.0.0.1:6443" "$CP" &
TUNNEL_PID=$!
sleep 5
read -r W1 W2 <<< "$($K get nodes -l node-role.kubernetes.io/worker=true -o jsonpath='{.items[*].metadata.name}')"
storage_nodes=$($K get nodes --no-headers | wc -l)

# Starts a pod on a given worker with the demo volume at /data, runs a command, waits for it to finish.
run_on() {
  local name=$1 node=$2 cmd=$3
  $K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: { name: $name, namespace: storage-demo }
spec:
  nodeName: $node
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: c
      image: busybox:1.36
      command: [sh, -c, "$cmd"]
      resources:
        requests: { cpu: 10m, memory: 8Mi }
        limits: { memory: 32Mi }
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
      volumeMounts: [{ name: data, mountPath: /data }]
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: data }
EOF
  $K -n storage-demo wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$name" --timeout=180s >/dev/null 2>&1
}

echo "Ceph"
health=$(ceph health)
if [ "$health" = "HEALTH_OK" ]; then ok "Ceph reports HEALTH_OK"; else bad "Ceph reports: $health"; fi
monstat=$(ceph mon stat)
if grep -q "$storage_nodes mons" <<< "$monstat" && grep -Eq 'quorum ([0-9]+,){2}[0-9]+ ' <<< "$monstat"; then
  ok "$storage_nodes mons, all in quorum"
else
  bad "mons not all in quorum: $monstat"
fi
osdstat=$(ceph osd stat)
if grep -Eq "^$storage_nodes osds: $storage_nodes up .*$storage_nodes in" <<< "$osdstat"; then ok "$storage_nodes OSDs up and in"; else bad "OSDs: $osdstat"; fi
hosts_with_osd=$(ceph osd tree | awk '/ host /{h=$4} / osd\.[0-9]+ /{print h}' | sort -u | wc -l)
if [ "$hosts_with_osd" -eq "$storage_nodes" ]; then ok "one OSD on each of the $storage_nodes nodes"; else bad "OSDs on $hosts_with_osd of $storage_nodes nodes"; fi

echo
echo "Where the copies go"
size=$(ceph osd pool get ceph-blockpool size)
rule=$(ceph osd pool get ceph-blockpool crush_rule | awk '{print $2}')
if [ "$size" = "size: 3" ] && ceph osd crush rule dump "$rule" | grep -q '"type": "host"'; then
  ok "ceph-blockpool keeps 3 copies, each on a different host"
else
  bad "ceph-blockpool: $size, rule $rule"
fi
default_sc=$($K get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}')
if [ "$default_sc" = "ceph-block " ]; then ok "ceph-block is the only default StorageClass"; else bad "default StorageClass: '$default_sc'"; fi

echo
echo "Data follows the pod"
$K apply -f tests/05-demo.yaml >/dev/null
if $K -n storage-demo wait --for=jsonpath='{.status.phase}'=Bound pvc/data --timeout=120s >/dev/null 2>&1; then
  ok "a 1 GiB PVC is bound to a Ceph volume"
else
  bad "the PVC was not bound"
fi
token=$(date +%s%N)
run_on writer "$W1" "echo $token > /data/proof && sync"
$K -n storage-demo delete pod writer --wait=true >/dev/null 2>&1
run_on reader "$W2" "cat /data/proof"
if [ "$($K -n storage-demo logs reader 2>/dev/null)" = "$token" ]; then
  ok "written on $W1, read back on $W2 after the first pod was deleted"
else
  bad "the file written on $W1 was not there on $W2"
fi
$K -n storage-demo delete pod reader --wait=true >/dev/null 2>&1

echo
echo "Losing a node loses nothing"
STOPPED_OSD=$($K -n rook-ceph get deployments -l app=rook-ceph-osd,topology-location-host="$W2" -o name)
$K -n rook-ceph scale "$STOPPED_OSD" --replicas=0 >/dev/null
for _ in $(seq 1 30); do grep -q "$((storage_nodes - 1)) up" <<< "$(ceph osd stat)" && break; sleep 5; done
if grep -q 'OSD_DOWN' <<< "$(ceph health detail)"; then ok "Ceph noticed the OSD on $W2 is down"; else bad "Ceph did not report the stopped OSD"; fi
run_on survivor "$W1" "cat /data/proof && echo second > /data/during-outage && cat /data/during-outage"
if [ "$($K -n storage-demo logs survivor 2>/dev/null | tr '\n' ' ')" = "$token second " ]; then
  ok "with one node's copy gone, the volume can still be read and written"
else
  bad "the volume did not work with one OSD down"
fi
$K -n storage-demo delete pod survivor --wait=false >/dev/null 2>&1
$K -n rook-ceph scale "$STOPPED_OSD" --replicas=1 >/dev/null
STOPPED_OSD=""
for _ in $(seq 1 60); do [ "$(ceph health)" = "HEALTH_OK" ] && break; sleep 10; done
if [ "$(ceph health)" = "HEALTH_OK" ]; then ok "back to HEALTH_OK once the OSD returned"; else bad "not healthy after the OSD returned: $(ceph health)"; fi

echo
echo "Only Ceph is privileged"
if [ "$($K get namespace rook-ceph -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" = "privileged" ]; then
  ok "rook-ceph is the privileged namespace"
else
  bad "rook-ceph is not labelled privileged"
fi
if sed 's/namespace: smoke/namespace: storage-demo/' tests/03-privileged-pod.yaml | $K apply --dry-run=server -f - >/dev/null 2>&1; then
  bad "a privileged pod was accepted in storage-demo"
else
  ok "a privileged pod is still rejected in other namespaces"
fi

echo
echo "Running the playbook again changes nothing"
LOG=$(mktemp)
(cd ansible && ansible-playbook playbooks/storage.yml > "$LOG" 2>&1)
changed=$(sed -n '/PLAY RECAP/,$p' "$LOG" | grep -Eo 'changed=[0-9]+' | cut -d= -f2 | awk '{s+=$1} END {print s+0}')
if grep -q 'failed=[1-9]' "$LOG"; then bad "storage.yml failed on a second run, see $LOG"
elif [ "$changed" -eq 0 ]; then ok "storage.yml reported changed=0"
else bad "storage.yml changed $changed task(s) on a second run, see $LOG"; fi

echo
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
