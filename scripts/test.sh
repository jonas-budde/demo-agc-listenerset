#!/usr/bin/env bash
# Runs the ListenerSet scenarios against the deployed demo. Needs KUBECONFIG set and infra applied.
set -uo pipefail
cd "$(dirname "$0")/../infra"

PUB=$(tofu output -raw public_frontend_fqdn)
PRIV=$(tofu output -json private_frontend | python3 -c 'import sys,json; print(json.load(sys.stdin)["fqdn"])')

pub() { curl -s -m 15 -o /dev/null -w '%{http_code}' -H "Host: $1" "http://$PUB/"; }
pubp() { curl -s -m 15 -o /dev/null -w '%{http_code}' -H "Host: $1" "http://$PUB$2"; }
priv() {
  kubectl run "curl-$RANDOM" --rm -i --restart=Never --image=curlimages/curl -n team-b --command -- \
    curl -s -m 15 -o /dev/null -w '%{http_code}' -H "Host: $1" "http://$PRIV/" 2>/dev/null | grep -oE '^[0-9]{3}'
}
wait_for() { # description, expected code, command
  for _ in $(seq 1 30); do
    [ "$(eval "$3")" = "$2" ] && { echo "PASS  $1"; return; }
    sleep 10
  done
  echo "FAIL  $1 (last: $(eval "$3"))"
}

echo "== status"
kubectl get gateway -n platform
kubectl get listenerset -A
echo "attachedListenerSets (public): $(kubectl get gateway shared-public -n platform -o jsonpath='{.status.attachedListenerSets}')"

echo "== 1. two teams on one frontend"
wait_for "team-a.example.com -> 200" 200 "pub team-a.example.com"
wait_for "team-b.example.com -> 200" 200 "pub team-b.example.com"

echo "== 2. unlabeled namespace is denied"
kubectl get listenerset team-c-listeners -n team-c -o jsonpath='{.status.conditions[?(@.type=="Accepted")]}{"\n"}'
wait_for "team-c.example.com -> not served (404)" 404 "pub team-c.example.com"

echo "== 3. hostname conflict is isolated"
kubectl patch listenerset team-b-listeners -n team-b --type=json \
  -p='[{"op":"replace","path":"/spec/listeners/0/hostname","value":"team-a.example.com"}]'
sleep 30
kubectl get listenerset team-b-listeners -n team-b -o jsonpath='{.status.listeners[*].conditions}{"\n"}'
wait_for "team-a still 200 during conflict" 200 "pub team-a.example.com"
kubectl patch listenerset team-b-listeners -n team-b --type=json \
  -p='[{"op":"replace","path":"/spec/listeners/0/hostname","value":"team-b.example.com"}]'
wait_for "team-b back to 200 after fix" 200 "pub team-b.example.com"

echo "== 4. private Gateway with a team ListenerSet (from inside the cluster)"
wait_for "team-b.internal.example.com -> 200" 200 "priv team-b.internal.example.com"

echo "== 5. removing the namespace label withdraws the listeners"
kubectl label ns team-b gateway-access-
wait_for "team-b.example.com -> 404 after label removal" 404 "pub team-b.example.com"
kubectl label ns team-b gateway-access=shared
wait_for "team-b.example.com -> 200 after label restored" 200 "pub team-b.example.com"

echo "== 6. WAF policy per team on the team's own HTTPRoute"
A=$(tofu output -json waf_policy_ids | python3 -c 'import sys,json; print(json.load(sys.stdin)["team-a"])')
B=$(tofu output -json waf_policy_ids | python3 -c 'import sys,json; print(json.load(sys.stdin)["team-b"])')
sed -e "s#WAF_TEAM_A_ID#$A#" -e "s#WAF_TEAM_B_ID#$B#" ../manifests/50-team-waf.yaml | kubectl apply -f -
wait_for "team-a /blocked-a -> 403" 403 "pubp team-a.example.com /blocked-a"
wait_for "team-a /blocked-b -> 200 (not team-b's rule)" 200 "pubp team-a.example.com /blocked-b"
wait_for "team-b /blocked-b -> 403" 403 "pubp team-b.example.com /blocked-b"
wait_for "team-b /blocked-a -> 200 (not team-a's rule)" 200 "pubp team-b.example.com /blocked-a"
kubectl get webapplicationfirewallpolicy -A
