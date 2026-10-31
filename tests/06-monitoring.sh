#!/usr/bin/env bash
# Checks the monitoring: every target scraped, alerts delivered, Ceph visible,
# history kept across a restart, and Grafana's dashboards. Run from the repo
# root after the monitoring playbook:
#   bash tests/06-monitoring.sh
set -uo pipefail

PORT=16443
GRAFANA_PORT=13000
K="kubectl --kubeconfig $HOME/.kube/rke2lab.yaml --server https://127.0.0.1:$PORT"
SSH="ssh -F ssh_config -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30"
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
CP=$(terraform -chdir=terraform output -raw control_plane_name)
PROM=/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy
AM=/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-alertmanager:9093/proxy

cleanup() {
  [ -n "${STOPPED_OSD:-}" ] && $K -n rook-ceph scale "$STOPPED_OSD" --replicas=1 >/dev/null 2>&1
  [ -n "${GRAFANA_PID:-}" ] && kill "$GRAFANA_PID" 2>/dev/null
  [ -n "${TUNNEL_PID:-}" ] && kill "$TUNNEL_PID" 2>/dev/null
}
trap cleanup EXIT

$SSH -N -o ExitOnForwardFailure=yes -L "$PORT:127.0.0.1:6443" "$CP" &
TUNNEL_PID=$!
sleep 5

# Runs a PromQL query (optionally at a past unix time) and prints the results,
# one "labels value" line per series.
query() {
  local url
  url="$PROM/api/v1/query?query=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1")"
  [ -n "${2:-}" ] && url="$url&time=$2"
  $K get --raw "$url" 2>/dev/null | python3 -c '
import json, sys
for r in json.load(sys.stdin)["data"]["result"]:
    print(json.dumps(r["metric"], sort_keys=True), r["value"][1])'
}
value() { query "$@" | awk 'NR==1 {print $NF}'; }

echo "Everything is scraped"
targets=$($K get --raw "$PROM/api/v1/targets?state=active" 2>/dev/null)
summary=$(python3 -c '
import json, sys
t = json.loads(sys.argv[1])["data"]["activeTargets"]
down = sorted({x["labels"].get("job", "") for x in t if x["health"] != "up"})
jobs = {x["labels"].get("job", "") for x in t}
need = ["apiserver", "kubelet", "coredns", "node-exporter", "kube-state-metrics", "cilium-agent", "hubble", "rook-ceph-mgr"]
missing = [n for n in need if not any(n in j for j in jobs)]
print(len(t), len(down), " ".join(down) or "-", " ".join(missing) or "-", sep="|")' "$targets")
IFS="|" read -r total ndown down missing <<< "$summary"
if [ "$ndown" -eq 0 ] && [ "$total" -gt 0 ]; then ok "all $total targets are up"; else bad "$ndown job(s) have targets down: $down"; fi
if [ "$missing" = "-" ]; then ok "the API server, kubelets, CoreDNS, Cilium, Hubble and Ceph are all scraped"; else bad "not scraped: $missing"; fi
nodes=$($K get nodes --no-headers | wc -l)
if [ "$(value 'count(up{job="node-exporter"} == 1)')" = "$nodes" ]; then ok "node-exporter reports from all $nodes nodes"; else bad "node-exporter is not up on every node"; fi

echo
echo "The alert path works"
if $K get --raw "$AM/api/v2/alerts" 2>/dev/null | grep -q '"alertname":"Watchdog"'; then
  ok "the always-firing Watchdog alert reached Alertmanager"
else
  bad "Watchdog is not in Alertmanager"
fi

echo
echo "Ceph is visible"
if [ "$(value 'ceph_health_status')" = "0" ] && [ "$(value 'count(ceph_osd_up == 1)')" = "3" ]; then
  ok "Prometheus sees Ceph healthy with 3 OSDs up"
else
  bad "Ceph metrics: health $(value 'ceph_health_status'), OSDs up $(value 'count(ceph_osd_up == 1)')"
fi
read -r _ W2 <<< "$($K get nodes -l node-role.kubernetes.io/worker=true -o jsonpath='{.items[*].metadata.name}')"
STOPPED_OSD=$($K -n rook-ceph get deployments -l app=rook-ceph-osd,topology-location-host="$W2" -o name)
osd="osd.${STOPPED_OSD##*-}"
$K -n rook-ceph scale "$STOPPED_OSD" --replicas=0 >/dev/null
seen=no
for _ in $(seq 1 24); do [ "$(value "ceph_osd_up{ceph_daemon=\"$osd\"}")" = "0" ] && { seen=yes; break; }; sleep 10; done
if [ "$seen" = yes ]; then ok "with the OSD on $W2 stopped, Prometheus shows $osd down"; else bad "Prometheus never showed $osd down"; fi
$K -n rook-ceph scale "$STOPPED_OSD" --replicas=1 >/dev/null
STOPPED_OSD=""
back=no
for _ in $(seq 1 30); do [ "$(value "ceph_osd_up{ceph_daemon=\"$osd\"}")" = "1" ] && [ "$(value 'ceph_health_status')" = "0" ] && { back=yes; break; }; sleep 10; done
if [ "$back" = yes ]; then ok "back up, and Ceph healthy again"; else bad "$osd did not come back healthy in Prometheus"; fi

echo
echo "History survives a restart"
past=$(( $(date +%s) - 300 ))
before=$(query 'up{job="node-exporter"}' "$past" | wc -l)
$K -n monitoring delete pod prometheus-kube-prometheus-stack-prometheus-0 >/dev/null
sleep 10
$K -n monitoring wait --for=condition=Ready pod/prometheus-kube-prometheus-stack-prometheus-0 --timeout=300s >/dev/null 2>&1
after=0
for _ in $(seq 1 12); do after=$(query 'up{job="node-exporter"}' "$past" | wc -l); [ "$after" -gt 0 ] && break; sleep 10; done
if [ "$before" -gt 0 ] && [ "$after" -eq "$before" ]; then
  ok "after the Prometheus pod was deleted, samples from 5 minutes ago are still there"
else
  bad "samples from 5 minutes ago: $before before the restart, $after after"
fi

echo
echo "Grafana works"
$K -n monitoring port-forward svc/kube-prometheus-stack-grafana "$GRAFANA_PORT:80" >/dev/null 2>&1 &
GRAFANA_PID=$!
sleep 5
user=$($K -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-user}' | base64 -d)
pw=$($K -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
G="curl -fsS -u $user:$pw http://127.0.0.1:$GRAFANA_PORT"
if $G/api/health 2>/dev/null | grep -q '"database": *"ok"' && $G/api/datasources 2>/dev/null | grep -q '"type":"prometheus"'; then
  ok "Grafana is up, with Prometheus as its data source"
else
  bad "Grafana or its Prometheus data source is not working"
fi
titles=$($G "/api/search?type=dash-db&limit=500" 2>/dev/null)
missing=""
for t in "Node Exporter" "Kubernetes / Compute Resources / Cluster" "Ceph Cluster" "Cilium"; do
  grep -q "\"title\":\"$t" <<< "$titles" || missing="$missing [$t]"
done
if [ -z "$missing" ]; then ok "the node, Kubernetes, Ceph and Cilium dashboards are there"; else bad "dashboards missing:$missing"; fi

echo
echo "Only node-exporter is privileged"
mon=$($K get namespace monitoring -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')
node=$($K get namespace monitoring-node -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')
if [ -z "$mon" ] && [ "$node" = "privileged" ]; then
  ok "monitoring stays restricted; monitoring-node is the privileged one"
else
  bad "Pod Security labels: monitoring='$mon', monitoring-node='$node'"
fi

echo
echo "Running the playbook again changes nothing"
LOG=$(mktemp)
(cd ansible && ansible-playbook playbooks/monitoring.yml > "$LOG" 2>&1)
changed=$(sed -n '/PLAY RECAP/,$p' "$LOG" | grep -Eo 'changed=[0-9]+' | cut -d= -f2 | awk '{s+=$1} END {print s+0}')
if grep -q 'failed=[1-9]' "$LOG"; then bad "monitoring.yml failed on a second run, see $LOG"
elif [ "$changed" -eq 0 ]; then ok "monitoring.yml reported changed=0"
else bad "monitoring.yml changed $changed task(s) on a second run, see $LOG"; fi

echo
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
