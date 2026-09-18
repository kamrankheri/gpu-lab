#!/usr/bin/env bash
# Collect a GPU allocation snapshot with kubectl and nothing else.
#
# Hand this to a client who will not give an outside consultant API access.
# It runs three read-only kubectl commands, writes one JSON file, and installs
# nothing. They can read every line of it in under a minute, which is the point.
# The grant it needs is rbac.yaml: list on nodes and pods, get on the
# kube-system namespace.
#
#   ./collect-cluster-snapshot.sh > cluster-snapshot.json
#
# Then: gpuaudit report ./cur-export --cluster-json cluster-snapshot.json ...
#
# The output is snapshot schema 1.1 and matches `gpuaudit cluster --json`
# field for field; tests/test_cluster_collection.py holds the two together.

set -euo pipefail

CONTEXT="${KUBE_CONTEXT:-}"
# ${ARGS[@]+"${ARGS[@]}"} below, not "${ARGS[@]}": bash 3.2, the stock macOS
# bash, treats an empty array as unbound under set -u.
ARGS=()
[ -n "$CONTEXT" ] && ARGS+=(--context "$CONTEXT")

command -v kubectl >/dev/null || { echo "kubectl not found on PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found on PATH" >&2; exit 1; }

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Which cluster this is: the kube-system namespace UID, fixed when the cluster
# was created. Not fatal: a grant without that rule still gets a snapshot, and
# the call records its exit code.
NS_START=$(now)
NS_RC=0
NS=$(kubectl ${ARGS[@]+"${ARGS[@]}"} get namespace kube-system -o json 2>/dev/null) || { NS_RC=$?; NS='{}'; }
NS_END=$(now)

NODES_START=$(now)
NODES=$(kubectl ${ARGS[@]+"${ARGS[@]}"} get nodes -o json)
NODES_END=$(now)

PODS_START=$(now)
PODS=$(kubectl ${ARGS[@]+"${ARGS[@]}"} get pods --all-namespaces -o json)
PODS_END=$(now)

jq -n \
  --argjson ns "$NS" \
  --argjson ns_rc "$NS_RC" \
  --argjson nodes "$NODES" \
  --argjson pods "$PODS" \
  --arg ctx_flag "$CONTEXT" \
  --arg ns_start "$NS_START" --arg ns_end "$NS_END" \
  --arg nodes_start "$NODES_START" --arg nodes_end "$NODES_END" \
  --arg pods_start "$PODS_START" --arg pods_end "$PODS_END" \
  --arg collected_at "$(now)" \
  '
  def gpu_res: to_entries
    | map(select(.key | test("^(nvidia\\.com/gpu|amd\\.com/gpu|habana\\.ai/gaudi|aws\\.amazon\\.com/neuron(core)?|intel\\.com/gpu|gpu\\.intel\\.com/i915|nvidia\\.com/mig-.*)$")))
    | map(select((.value | tonumber) > 0))
    | map({key: .key, value: (.value | tonumber)}) | from_entries;

  # In jq, `add` merges objects instead of summing them, which drops all but the
  # GPUs of the last container. These two helpers do it numerically.
  def sum_res: reduce (.[] | to_entries[]) as $e ({}; .[$e.key] = ((.[$e.key] // 0) + $e.value));
  def max_res: reduce (.[] | to_entries[]) as $e ({}; .[$e.key] = ([(.[$e.key] // 0), $e.value] | max));

  # Limits first, requests as fallback. Matches the Python path.
  def res_of:
    ((.resources.limits // {}) | gpu_res) as $l
    | if ($l | length) > 0 then $l else ((.resources.requests // {}) | gpu_res) end;

  # One row per container, init containers first, matching the Python path.
  # A container state has exactly one key: running, waiting or terminated.
  def container_row($kind; $st):
    ($st[.name] // {}) as $s
    | (($s.state // {}) | keys_unsorted | first) as $state
    | ((($s.state // {})[$state // ""]) // {}) as $d
    | {
        name: .name,
        type: (if $kind == "init" and .restartPolicy == "Always" then "sidecar" else $kind end),
        gpus: ([res_of[]] | add // 0),
        state: $state,
        reason: ($d.reason // null),
        started_at: ($d.startedAt // null),
        restart_count: ($s.restartCount // 0),
        ready: ($s.ready // false)
      };

  # The argv exactly as run above.
  def kubectl($rest):
    ["kubectl"] + (if $ctx_flag != "" then ["--context", $ctx_flag] else [] end) + $rest;

  (if $ctx_flag != "" then $ctx_flag else null end) as $ctxname
  | {
    schema_version: "1.1",
    cluster: {context: $ctxname, kube_system_uid: ($ns.metadata.uid // null)},
    calls: [
      {section: "cluster", command: kubectl(["get", "namespace", "kube-system", "-o", "json"]),
       started_at: $ns_start, finished_at: $ns_end, exit_code: $ns_rc,
       items: (if ($ns.metadata // null) != null then 1 else 0 end)},
      {section: "nodes", command: kubectl(["get", "nodes", "-o", "json"]),
       started_at: $nodes_start, finished_at: $nodes_end, exit_code: 0,
       items: ($nodes.items | length)},
      {section: "pods", command: kubectl(["get", "pods", "--all-namespaces", "-o", "json"]),
       started_at: $pods_start, finished_at: $pods_end, exit_code: 0,
       items: ($pods.items | length)}
    ],
    context: $ctxname,
    collected_at: $collected_at,
    source: "kubectl-script",
    observed_hours: 0,
    samples: 1,
    nodes: [ $nodes.items[] | {
      name: .metadata.name,
      provider_id: .spec.providerID,
      instance_type: (.metadata.labels["node.kubernetes.io/instance-type"]
                      // .metadata.labels["beta.kubernetes.io/instance-type"]),
      zone: (.metadata.labels["topology.kubernetes.io/zone"]
             // .metadata.labels["failure-domain.beta.kubernetes.io/zone"]),
      region: (.metadata.labels["topology.kubernetes.io/region"]
               // .metadata.labels["failure-domain.beta.kubernetes.io/region"]),
      labels: (.metadata.labels // {}),
      gpu_capacity: ((.status.capacity // {}) | gpu_res),
      gpu_allocatable: ((.status.allocatable // {}) | gpu_res),
      unschedulable: (.spec.unschedulable // false),
      taints: [ (.spec.taints // [])[] | {key: .key, effect: .effect} ]
    } ],
    pods: [ $pods.items[]
      | . as $p
      # Init containers in order: a sidecar keeps running, so each plain init
      # container after it runs alongside every sidecar started before it.
      | (reduce (($p.spec.initContainers // [])[]) as $c ({side: {}, peak: {}};
           ($c | res_of) as $r
           | if $c.restartPolicy == "Always"
             then .side = ([.side, $r] | sum_res)
             else .peak = ([.peak, ([.side, $r] | sum_res)] | max_res) end)) as $init
      | (((($p.spec.containers // []) | map(res_of)) + [$init.side]) | sum_res) as $concurrent
      | $init.peak as $init_peak
      | ((($p.status.initContainerStatuses // []) + ($p.status.containerStatuses // []))
         | map({key: .name, value: .}) | from_entries) as $st
      | ([($p.spec.initContainers // [])[] | container_row("init"; $st)]
         + [($p.spec.containers // [])[] | container_row("container"; $st)]) as $containers
      | ([$concurrent, $init_peak] | max_res)
      | to_entries[]
      | {
          namespace: $p.metadata.namespace,
          name: $p.metadata.name,
          node: $p.spec.nodeName,
          phase: ($p.status.phase // "Unknown"),
          gpus: .value,
          resource_name: .key,
          labels: ($p.metadata.labels // {}),
          owner_references: [ ($p.metadata.ownerReferences // [])[]
                              | {kind: .kind, name: .name, controller: (.controller // false)} ],
          created_at: ($p.metadata.creationTimestamp // null),
          containers: $containers,
          conditions: [ ($p.status.conditions // [])[]
                        | {type: .type, status: .status, reason: (.reason // null),
                           message: (.message // null),
                           last_transition: (.lastTransitionTime // null)} ]
        }
    ]
  }'
