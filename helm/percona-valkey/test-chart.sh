#!/bin/bash
#
# Comprehensive test script for percona-valkey Helm chart.
# Requires: kubectl (connected to a cluster), helm 3.x
# Run from the valkey-packaging root directory.
#
set -euo pipefail

CHART_DIR="./helm/percona-valkey"
PASS=testpass123
TIMEOUT=180s
NAMESPACE=default
# Set to "true" to skip tests that require the hardened image variant
SKIP_HARDENED="${SKIP_HARDENED:-false}"

# Counters
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
FAILURES=""

# --- Helpers ---

green()  { printf "\033[32m%s\033[0m\n" "$*"; }
red()    { printf "\033[31m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }

pass() {
    TOTAL=$((TOTAL + 1))
    PASSED=$((PASSED + 1))
    green "  PASS: $1"
}

fail() {
    TOTAL=$((TOTAL + 1))
    FAILED=$((FAILED + 1))
    FAILURES="${FAILURES}\n  - $1"
    red "  FAIL: $1"
}

skip() {
    TOTAL=$((TOTAL + 1))
    SKIPPED=$((SKIPPED + 1))
    yellow "  SKIP: $1"
}

wait_for_pods() {
    local label="$1"
    local expected="$2"
    local timeout="${3:-$TIMEOUT}"
    local start=$(date +%s)
    local deadline=$((start + ${timeout%s}))

    while true; do
        local ready=$(kubectl get pods -l "$label" -n $NAMESPACE --no-headers 2>/dev/null | grep "Running" | awk '{print $2}' | grep -c "1/1" || true)
        # Also count 2/2 for metrics sidecar
        local ready2=$(kubectl get pods -l "$label" -n $NAMESPACE --no-headers 2>/dev/null | grep "Running" | awk '{print $2}' | grep -c "2/2" || true)
        ready=$((ready + ready2))
        if [ "$ready" -ge "$expected" ]; then
            return 0
        fi
        if [ "$(date +%s)" -gt "$deadline" ]; then
            echo "    Timeout waiting for $expected pods (got $ready)"
            kubectl get pods -l "$label" -n $NAMESPACE --no-headers 2>/dev/null || true
            return 1
        fi
        sleep 3
    done
}

cleanup() {
    local release="$1"
    helm uninstall "$release" -n $NAMESPACE --wait 2>/dev/null || true
    kubectl delete pvc -l "app.kubernetes.io/instance=$release" -n $NAMESPACE --wait=false 2>/dev/null || true
    # Wait for pods to terminate
    local deadline=$(( $(date +%s) + 60 ))
    while kubectl get pods -l "app.kubernetes.io/instance=$release" -n $NAMESPACE --no-headers 2>/dev/null | grep -q .; do
        if [ "$(date +%s)" -gt "$deadline" ]; then break; fi
        sleep 2
    done
}

# --- Lint Tests ---

test_lint() {
    bold "=== TEST: Helm lint (all variants) ==="

    if helm lint "$CHART_DIR" > /dev/null 2>&1; then
        pass "lint standalone/rpm"
    else
        fail "lint standalone/rpm"
    fi

    if helm lint "$CHART_DIR" --set mode=cluster > /dev/null 2>&1; then
        pass "lint cluster/rpm"
    else
        fail "lint cluster/rpm"
    fi

    if helm lint "$CHART_DIR" --set image.variant=hardened > /dev/null 2>&1; then
        pass "lint standalone/hardened"
    else
        fail "lint standalone/hardened"
    fi

    if helm lint "$CHART_DIR" --set mode=cluster,image.variant=hardened > /dev/null 2>&1; then
        pass "lint cluster/hardened"
    else
        fail "lint cluster/hardened"
    fi
}

# --- Template Render Tests ---

test_template_render() {
    bold "=== TEST: Template render validation ==="
    local out

    # Standalone default
    if helm template test "$CHART_DIR" > /dev/null 2>&1; then
        pass "template standalone default"
    else
        fail "template standalone default"
    fi

    # Cluster
    if helm template test "$CHART_DIR" --set mode=cluster > /dev/null 2>&1; then
        pass "template cluster"
    else
        fail "template cluster"
    fi

    # Metrics sidecar
    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "redis_exporter"; then
        pass "template metrics sidecar present"
    else
        fail "template metrics sidecar present"
    fi

    # Metrics service
    if helm template test "$CHART_DIR" --set metrics.enabled=true --show-only templates/service-metrics.yaml > /dev/null 2>&1; then
        pass "template metrics service"
    else
        fail "template metrics service"
    fi

    # ServiceMonitor
    if helm template test "$CHART_DIR" --set metrics.enabled=true,metrics.serviceMonitor.enabled=true --show-only templates/servicemonitor.yaml > /dev/null 2>&1; then
        pass "template ServiceMonitor"
    else
        fail "template ServiceMonitor"
    fi

    # PodMonitor
    if helm template test "$CHART_DIR" --set metrics.enabled=true,metrics.podMonitor.enabled=true --show-only templates/podmonitor.yaml > /dev/null 2>&1; then
        pass "template PodMonitor"
    else
        fail "template PodMonitor"
    fi

    # PrometheusRule
    out=$(helm template test "$CHART_DIR" \
        --set metrics.enabled=true \
        --set metrics.prometheusRule.enabled=true \
        --set 'metrics.prometheusRule.rules[0].alert=ValkeyDown' \
        --set 'metrics.prometheusRule.rules[0].expr=redis_up == 0' \
        --show-only templates/prometheusrule.yaml 2>&1)
    if echo "$out" | grep -q "ValkeyDown"; then
        pass "template PrometheusRule"
    else
        fail "template PrometheusRule"
    fi

    # Network Policy
    out=$(helm template test "$CHART_DIR" --set networkPolicy.enabled=true --show-only templates/networkpolicy.yaml 2>&1)
    if echo "$out" | grep -q "NetworkPolicy"; then
        pass "template NetworkPolicy"
    else
        fail "template NetworkPolicy"
    fi

    # Network Policy in cluster mode (should include bus port)
    out=$(helm template test "$CHART_DIR" --set networkPolicy.enabled=true,mode=cluster --show-only templates/networkpolicy.yaml 2>&1)
    if echo "$out" | grep -q "16379"; then
        pass "template NetworkPolicy cluster bus port"
    else
        fail "template NetworkPolicy cluster bus port"
    fi

    # sysctl init container
    out=$(helm template test "$CHART_DIR" --set sysctlInit.enabled=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "sysctl-init"; then
        pass "template sysctl init container"
    else
        fail "template sysctl init container"
    fi

    # Volume permissions init container
    out=$(helm template test "$CHART_DIR" --set volumePermissions.enabled=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "volume-permissions"; then
        pass "template volume-permissions init container"
    else
        fail "template volume-permissions init container"
    fi

    # Disabled commands in configmap
    out=$(helm template test "$CHART_DIR" --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q 'rename-command FLUSHDB ""'; then
        pass "template disabled commands (FLUSHDB)"
    else
        fail "template disabled commands (FLUSHDB)"
    fi
    if echo "$out" | grep -q 'rename-command FLUSHALL ""'; then
        pass "template disabled commands (FLUSHALL)"
    else
        fail "template disabled commands (FLUSHALL)"
    fi

    # Per-mode disabled commands
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set 'disableCommandsCluster={DEBUG}' --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q 'rename-command DEBUG ""' && ! echo "$out" | grep -q 'rename-command FLUSHDB'; then
        pass "template per-mode disabled commands (cluster override)"
    else
        fail "template per-mode disabled commands (cluster override)"
    fi

    # Password file mounting
    out=$(helm template test "$CHART_DIR" --set auth.usePasswordFiles=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "VALKEY_PASSWORD_FILE" && echo "$out" | grep -q "/opt/valkey/secrets"; then
        pass "template password file mounting"
    else
        fail "template password file mounting"
    fi

    # automountServiceAccountToken
    out=$(helm template test "$CHART_DIR" --show-only templates/serviceaccount.yaml 2>&1)
    if echo "$out" | grep -q "automountServiceAccountToken: false"; then
        pass "template automountServiceAccountToken: false"
    else
        fail "template automountServiceAccountToken: false"
    fi

    # Resource preset
    out=$(helm template test "$CHART_DIR" --set resourcePreset=small --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "memory: 512Mi"; then
        pass "template resource preset (small)"
    else
        fail "template resource preset (small)"
    fi

    # Explicit resources override preset
    out=$(helm template test "$CHART_DIR" --set resourcePreset=small --set resources.requests.memory=999Mi --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "999Mi"; then
        pass "template explicit resources override preset"
    else
        fail "template explicit resources override preset"
    fi

    # Diagnostic mode
    out=$(helm template test "$CHART_DIR" --set diagnosticMode.enabled=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "sleep" && echo "$out" | grep -q "infinity"; then
        pass "template diagnostic mode"
    else
        fail "template diagnostic mode"
    fi

    # Lifecycle hooks
    out=$(helm template test "$CHART_DIR" --set 'lifecycle.preStop.exec.command[0]=/bin/sh' --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "lifecycle:" && echo "$out" | grep -q "preStop"; then
        pass "template lifecycle hooks"
    else
        fail "template lifecycle hooks"
    fi

    # Extra env vars
    out=$(helm template test "$CHART_DIR" --set 'extraEnvVars[0].name=MY_VAR' --set 'extraEnvVars[0].value=hello' --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "MY_VAR"; then
        pass "template extra env vars"
    else
        fail "template extra env vars"
    fi

    # PVC retention policy
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "persistentVolumeClaimRetentionPolicy" && echo "$out" | grep -q "whenDeleted: Retain"; then
        pass "template PVC retention policy"
    else
        fail "template PVC retention policy"
    fi

    # Hardened image tag
    out=$(helm template test "$CHART_DIR" --set image.variant=hardened --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "9.0.3-hardened"; then
        pass "template hardened image tag"
    else
        fail "template hardened image tag"
    fi

    # Hardened readOnlyRootFilesystem + tmpfs
    if echo "$out" | grep -q "readOnlyRootFilesystem: true" && echo "$out" | grep -q "mountPath: /tmp"; then
        pass "template hardened security (readOnlyRootFilesystem + tmpfs)"
    else
        fail "template hardened security (readOnlyRootFilesystem + tmpfs)"
    fi

    # PDB only in cluster mode
    out=$(helm template test "$CHART_DIR" --set mode=standalone 2>&1)
    if ! echo "$out" | grep -q "PodDisruptionBudget"; then
        pass "template PDB absent in standalone mode"
    else
        fail "template PDB absent in standalone mode"
    fi

    out=$(helm template test "$CHART_DIR" --set mode=cluster 2>&1)
    if echo "$out" | grep -q "PodDisruptionBudget"; then
        pass "template PDB present in cluster mode"
    else
        fail "template PDB present in cluster mode"
    fi

    # Cluster-init job only in cluster mode
    out=$(helm template test "$CHART_DIR" --set mode=standalone 2>&1)
    if ! echo "$out" | grep -q "cluster-init"; then
        pass "template cluster-init absent in standalone mode"
    else
        fail "template cluster-init absent in standalone mode"
    fi

    # Cluster mode: announce-ip via VALKEY_EXTRA_FLAGS
    out=$(helm template test "$CHART_DIR" --set mode=cluster --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "cluster-announce-ip" && echo "$out" | grep -q "POD_IP"; then
        pass "template cluster announce-ip via VALKEY_EXTRA_FLAGS"
    else
        fail "template cluster announce-ip via VALKEY_EXTRA_FLAGS"
    fi

    # Cluster configmap: cluster-enabled yes
    out=$(helm template test "$CHART_DIR" --set mode=cluster --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "cluster-enabled yes"; then
        pass "template cluster-enabled in configmap"
    else
        fail "template cluster-enabled in configmap"
    fi

    # Auth disabled: no secret, no VALKEY_PASSWORD
    out=$(helm template test "$CHART_DIR" --set auth.enabled=false 2>&1)
    if ! echo "$out" | grep -q "kind: Secret"; then
        pass "template no Secret when auth disabled"
    else
        fail "template no Secret when auth disabled"
    fi

    # Existing secret
    out=$(helm template test "$CHART_DIR" --set auth.existingSecret=my-secret --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "my-secret" && ! helm template test "$CHART_DIR" --set auth.existingSecret=my-secret 2>&1 | grep -q "kind: Secret"; then
        pass "template existing secret used, no Secret generated"
    else
        fail "template existing secret used, no Secret generated"
    fi

    # Headless service publishNotReadyAddresses
    out=$(helm template test "$CHART_DIR" --show-only templates/service-headless.yaml 2>&1)
    if echo "$out" | grep -q "publishNotReadyAddresses: true"; then
        pass "template headless service publishNotReadyAddresses"
    else
        fail "template headless service publishNotReadyAddresses"
    fi

    # --- Config values in configmap ---

    # maxmemory
    out=$(helm template test "$CHART_DIR" --set config.maxmemory=256mb --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "maxmemory 256mb"; then
        pass "template configmap maxmemory"
    else
        fail "template configmap maxmemory"
    fi

    # maxmemoryPolicy
    out=$(helm template test "$CHART_DIR" --set config.maxmemoryPolicy=allkeys-lru --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "maxmemory-policy allkeys-lru"; then
        pass "template configmap maxmemoryPolicy"
    else
        fail "template configmap maxmemoryPolicy"
    fi

    # bind
    out=$(helm template test "$CHART_DIR" --set config.bind=127.0.0.1 --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "bind 127.0.0.1"; then
        pass "template configmap bind"
    else
        fail "template configmap bind"
    fi

    # extraFlags in standalone
    out=$(helm template test "$CHART_DIR" --set config.extraFlags="--loglevel verbose" --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "VALKEY_EXTRA_FLAGS" && echo "$out" | grep -q "\-\-loglevel verbose"; then
        pass "template extraFlags standalone"
    else
        fail "template extraFlags standalone"
    fi

    # customConfig
    out=$(helm template test "$CHART_DIR" --set config.customConfig="tcp-keepalive 300" --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "tcp-keepalive 300"; then
        pass "template configmap customConfig"
    else
        fail "template configmap customConfig"
    fi

    # --- StatefulSet metadata ---

    # podAnnotations
    out=$(helm template test "$CHART_DIR" --set podAnnotations.test/anno=myval --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "test/anno: myval"; then
        pass "template podAnnotations"
    else
        fail "template podAnnotations"
    fi

    # podLabels
    out=$(helm template test "$CHART_DIR" --set podLabels.custom-label=mylab --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "custom-label: mylab"; then
        pass "template podLabels"
    else
        fail "template podLabels"
    fi

    # statefulset annotations
    out=$(helm template test "$CHART_DIR" --set statefulset.annotations.sts-anno=stsval --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "sts-anno: stsval"; then
        pass "template statefulset annotations"
    else
        fail "template statefulset annotations"
    fi

    # statefulset labels
    out=$(helm template test "$CHART_DIR" --set statefulset.labels.sts-label=stslab --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "sts-label: stslab"; then
        pass "template statefulset labels"
    else
        fail "template statefulset labels"
    fi

    # --- Node placement ---

    # nodeSelector
    out=$(helm template test "$CHART_DIR" --set nodeSelector.disktype=ssd --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "disktype: ssd"; then
        pass "template nodeSelector"
    else
        fail "template nodeSelector"
    fi

    # tolerations
    out=$(helm template test "$CHART_DIR" \
        --set 'tolerations[0].key=dedicated' \
        --set 'tolerations[0].operator=Equal' \
        --set 'tolerations[0].value=valkey' \
        --set 'tolerations[0].effect=NoSchedule' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "dedicated" && echo "$out" | grep -q "NoSchedule"; then
        pass "template tolerations"
    else
        fail "template tolerations"
    fi

    # affinity
    out=$(helm template test "$CHART_DIR" \
        --set 'affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight=100' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "podAntiAffinity"; then
        pass "template affinity"
    else
        fail "template affinity"
    fi

    # --- StatefulSet strategy ---

    # updateStrategy
    out=$(helm template test "$CHART_DIR" --set statefulset.updateStrategy.type=OnDelete --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "type: OnDelete"; then
        pass "template updateStrategy OnDelete"
    else
        fail "template updateStrategy OnDelete"
    fi

    # podManagementPolicy override (standalone should default to OrderedReady)
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "podManagementPolicy: OrderedReady"; then
        pass "template podManagementPolicy standalone default (OrderedReady)"
    else
        fail "template podManagementPolicy standalone default (OrderedReady)"
    fi

    # podManagementPolicy cluster default (Parallel)
    out=$(helm template test "$CHART_DIR" --set mode=cluster --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "podManagementPolicy: Parallel"; then
        pass "template podManagementPolicy cluster default (Parallel)"
    else
        fail "template podManagementPolicy cluster default (Parallel)"
    fi

    # podManagementPolicy explicit override
    out=$(helm template test "$CHART_DIR" --set statefulset.podManagementPolicy=Parallel --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "podManagementPolicy: Parallel"; then
        pass "template podManagementPolicy explicit override"
    else
        fail "template podManagementPolicy explicit override"
    fi

    # --- Service overrides ---

    # service type override
    out=$(helm template test "$CHART_DIR" --set service.type=NodePort --show-only templates/service.yaml 2>&1)
    if echo "$out" | grep -q "type: NodePort"; then
        pass "template service type NodePort"
    else
        fail "template service type NodePort"
    fi

    # service annotations
    out=$(helm template test "$CHART_DIR" --set service.annotations.svc-key=svc-val --show-only templates/service.yaml 2>&1)
    if echo "$out" | grep -q "svc-key: svc-val"; then
        pass "template service annotations"
    else
        fail "template service annotations"
    fi

    # headless service cluster-bus port in cluster mode
    out=$(helm template test "$CHART_DIR" --set mode=cluster --show-only templates/service-headless.yaml 2>&1)
    if echo "$out" | grep -q "cluster-bus" && echo "$out" | grep -q "16379"; then
        pass "template headless service cluster-bus port"
    else
        fail "template headless service cluster-bus port"
    fi

    # --- Persistence ---

    # persistence disabled (emptyDir)
    out=$(helm template test "$CHART_DIR" --set persistence.enabled=false --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "emptyDir" && ! echo "$out" | grep -q "volumeClaimTemplates"; then
        pass "template persistence disabled (emptyDir)"
    else
        fail "template persistence disabled (emptyDir)"
    fi

    # custom storageClass
    out=$(helm template test "$CHART_DIR" --set persistence.storageClass=fast-ssd --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "fast-ssd"; then
        pass "template custom storageClass"
    else
        fail "template custom storageClass"
    fi

    # custom persistence size
    out=$(helm template test "$CHART_DIR" --set persistence.size=50Gi --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "50Gi"; then
        pass "template custom persistence size"
    else
        fail "template custom persistence size"
    fi

    # --- Security ---

    # custom securityContext
    out=$(helm template test "$CHART_DIR" --set securityContext.runAsUser=1000 --set securityContext.runAsGroup=1000 --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "runAsUser: 1000"; then
        pass "template custom securityContext runAsUser"
    else
        fail "template custom securityContext runAsUser"
    fi

    # hardened caps drop and allowPrivilegeEscalation
    out=$(helm template test "$CHART_DIR" --set image.variant=hardened --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "allowPrivilegeEscalation: false" && echo "$out" | grep -A2 "capabilities:" | grep -q "ALL"; then
        pass "template hardened allowPrivilegeEscalation + caps drop"
    else
        fail "template hardened allowPrivilegeEscalation + caps drop"
    fi

    # --- Image ---

    # custom image tag
    out=$(helm template test "$CHART_DIR" --set image.tag=custom-tag-1.2.3 --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "perconalab/valkey:custom-tag-1.2.3"; then
        pass "template custom image tag"
    else
        fail "template custom image tag"
    fi

    # custom image repository
    out=$(helm template test "$CHART_DIR" --set image.repository=myregistry.io/valkey --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "myregistry.io/valkey"; then
        pass "template custom image repository"
    else
        fail "template custom image repository"
    fi

    # pullSecrets
    out=$(helm template test "$CHART_DIR" --set 'image.pullSecrets[0].name=my-registry-secret' --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "my-registry-secret"; then
        pass "template imagePullSecrets"
    else
        fail "template imagePullSecrets"
    fi

    # --- Naming ---

    # nameOverride
    out=$(helm template test "$CHART_DIR" --set nameOverride=myvalkey 2>&1)
    if echo "$out" | grep -q "myvalkey"; then
        pass "template nameOverride"
    else
        fail "template nameOverride"
    fi

    # fullnameOverride
    out=$(helm template test "$CHART_DIR" --set fullnameOverride=my-custom-valkey 2>&1)
    if echo "$out" | grep -q "my-custom-valkey" && ! echo "$out" | grep -q "test-percona-valkey"; then
        pass "template fullnameOverride"
    else
        fail "template fullnameOverride"
    fi

    # --- Cluster-specific template tests ---

    # custom nodeTimeout in configmap
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set cluster.nodeTimeout=5000 --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "cluster-node-timeout 5000"; then
        pass "template cluster custom nodeTimeout"
    else
        fail "template cluster custom nodeTimeout"
    fi

    # cluster replicas count in statefulset
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set cluster.replicas=9 --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "replicas: 9"; then
        pass "template cluster replicas count"
    else
        fail "template cluster replicas count"
    fi

    # standalone replicas count
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "replicas: 1"; then
        pass "template standalone replicas default (1)"
    else
        fail "template standalone replicas default (1)"
    fi

    # --- Extra volumes ---

    # extraVolumes + extraVolumeMounts
    out=$(helm template test "$CHART_DIR" \
        --set 'extraVolumes[0].name=my-vol' \
        --set 'extraVolumes[0].emptyDir.medium=Memory' \
        --set 'extraVolumeMounts[0].name=my-vol' \
        --set 'extraVolumeMounts[0].mountPath=/my-data' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "name: my-vol" && echo "$out" | grep -q "mountPath: /my-data"; then
        pass "template extraVolumes + extraVolumeMounts"
    else
        fail "template extraVolumes + extraVolumeMounts"
    fi

    # --- ServiceAccount ---

    # serviceAccount disabled
    out=$(helm template test "$CHART_DIR" --set serviceAccount.create=false --show-only templates/serviceaccount.yaml 2>&1 || true)
    if [ -z "$out" ] || echo "$out" | grep -q "could not find template"; then
        pass "template serviceAccount disabled produces no output"
    else
        fail "template serviceAccount disabled produces no output"
    fi

    # serviceAccount custom name
    out=$(helm template test "$CHART_DIR" --set serviceAccount.name=my-sa --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "serviceAccountName: my-sa"; then
        pass "template serviceAccount custom name"
    else
        fail "template serviceAccount custom name"
    fi

    # --- Checksum annotation for rolling restart ---

    # Config change triggers different checksum
    local out1 out2
    out1=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1 | grep "checksum/config")
    out2=$(helm template test "$CHART_DIR" --set config.customConfig="new-setting 1" --show-only templates/statefulset.yaml 2>&1 | grep "checksum/config")
    if [ "$out1" != "$out2" ]; then
        pass "template config change produces different checksum (rolling restart)"
    else
        fail "template config change produces different checksum (rolling restart)"
    fi

    # --- Health probes ---

    # livenessProbe defaults present
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "livenessProbe:" && echo "$out" | grep -q "initialDelaySeconds: 20"; then
        pass "template livenessProbe defaults present"
    else
        fail "template livenessProbe defaults present"
    fi

    # livenessProbe custom values
    out=$(helm template test "$CHART_DIR" \
        --set livenessProbe.initialDelaySeconds=30 \
        --set livenessProbe.periodSeconds=15 \
        --set livenessProbe.timeoutSeconds=10 \
        --set livenessProbe.failureThreshold=8 \
        --set livenessProbe.successThreshold=2 \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "initialDelaySeconds: 30" && echo "$out" | grep -q "periodSeconds: 15" && \
       echo "$out" | grep -q "timeoutSeconds: 10" && echo "$out" | grep -q "failureThreshold: 8"; then
        pass "template livenessProbe custom values"
    else
        fail "template livenessProbe custom values"
    fi

    # livenessProbe disabled
    out=$(helm template test "$CHART_DIR" --set livenessProbe.enabled=false --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "livenessProbe:"; then
        pass "template livenessProbe disabled"
    else
        fail "template livenessProbe disabled"
    fi

    # readinessProbe defaults present
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "readinessProbe:" && echo "$out" | grep -q "initialDelaySeconds: 10"; then
        pass "template readinessProbe defaults present"
    else
        fail "template readinessProbe defaults present"
    fi

    # readinessProbe custom values
    out=$(helm template test "$CHART_DIR" \
        --set readinessProbe.initialDelaySeconds=25 \
        --set readinessProbe.periodSeconds=20 \
        --set readinessProbe.timeoutSeconds=8 \
        --set readinessProbe.failureThreshold=5 \
        --set readinessProbe.successThreshold=3 \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "initialDelaySeconds: 25" && echo "$out" | grep -q "failureThreshold: 5"; then
        pass "template readinessProbe custom values"
    else
        fail "template readinessProbe custom values"
    fi

    # readinessProbe disabled
    out=$(helm template test "$CHART_DIR" --set readinessProbe.enabled=false --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "readinessProbe:"; then
        pass "template readinessProbe disabled"
    else
        fail "template readinessProbe disabled"
    fi

    # readinessProbe cluster mode uses cluster info
    out=$(helm template test "$CHART_DIR" --set mode=cluster --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "cluster_state:ok"; then
        pass "template readinessProbe cluster mode checks cluster_state"
    else
        fail "template readinessProbe cluster mode checks cluster_state"
    fi

    # startupProbe defaults present
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "startupProbe:" && echo "$out" | grep -q "failureThreshold: 30"; then
        pass "template startupProbe defaults present"
    else
        fail "template startupProbe defaults present"
    fi

    # startupProbe custom values
    out=$(helm template test "$CHART_DIR" \
        --set startupProbe.initialDelaySeconds=10 \
        --set startupProbe.periodSeconds=3 \
        --set startupProbe.timeoutSeconds=2 \
        --set startupProbe.failureThreshold=60 \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "failureThreshold: 60" && echo "$out" | grep -q "periodSeconds: 3"; then
        pass "template startupProbe custom values"
    else
        fail "template startupProbe custom values"
    fi

    # startupProbe disabled
    out=$(helm template test "$CHART_DIR" --set startupProbe.enabled=false --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "startupProbe:"; then
        pass "template startupProbe disabled"
    else
        fail "template startupProbe disabled"
    fi

    # All probes disabled together
    out=$(helm template test "$CHART_DIR" \
        --set livenessProbe.enabled=false \
        --set readinessProbe.enabled=false \
        --set startupProbe.enabled=false \
        --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "livenessProbe:" && ! echo "$out" | grep -q "readinessProbe:" && ! echo "$out" | grep -q "startupProbe:"; then
        pass "template all probes disabled"
    else
        fail "template all probes disabled"
    fi

    # --- Security context subfields ---

    # runAsGroup
    out=$(helm template test "$CHART_DIR" --set securityContext.runAsGroup=1001 --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "runAsGroup: 1001"; then
        pass "template securityContext runAsGroup"
    else
        fail "template securityContext runAsGroup"
    fi

    # fsGroup
    out=$(helm template test "$CHART_DIR" --set securityContext.fsGroup=2000 --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "fsGroup: 2000"; then
        pass "template securityContext fsGroup"
    else
        fail "template securityContext fsGroup"
    fi

    # runAsNonRoot
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "runAsNonRoot: true"; then
        pass "template securityContext runAsNonRoot default true"
    else
        fail "template securityContext runAsNonRoot default true"
    fi

    # containerSecurityContext in non-hardened mode
    out=$(helm template test "$CHART_DIR" --set containerSecurityContext.readOnlyRootFilesystem=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "readOnlyRootFilesystem: true"; then
        pass "template containerSecurityContext readOnlyRootFilesystem custom"
    else
        fail "template containerSecurityContext readOnlyRootFilesystem custom"
    fi

    # --- PDB field values ---

    # PDB maxUnavailable default
    out=$(helm template test "$CHART_DIR" --set mode=cluster --show-only templates/pdb.yaml 2>&1)
    if echo "$out" | grep -q "maxUnavailable: 1"; then
        pass "template PDB maxUnavailable default (1)"
    else
        fail "template PDB maxUnavailable default (1)"
    fi

    # PDB maxUnavailable custom
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set pdb.maxUnavailable=2 --show-only templates/pdb.yaml 2>&1)
    if echo "$out" | grep -q "maxUnavailable: 2"; then
        pass "template PDB maxUnavailable custom (2)"
    else
        fail "template PDB maxUnavailable custom (2)"
    fi

    # PDB minAvailable overrides maxUnavailable
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set pdb.minAvailable=3 --show-only templates/pdb.yaml 2>&1)
    if echo "$out" | grep -q "minAvailable: 3" && ! echo "$out" | grep -q "maxUnavailable"; then
        pass "template PDB minAvailable overrides maxUnavailable"
    else
        fail "template PDB minAvailable overrides maxUnavailable"
    fi

    # PDB disabled in cluster mode
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set pdb.enabled=false 2>&1)
    if ! echo "$out" | grep -q "PodDisruptionBudget"; then
        pass "template PDB disabled in cluster mode"
    else
        fail "template PDB disabled in cluster mode"
    fi

    # --- NetworkPolicy advanced ---

    # allowExternal=false adds podSelector from
    out=$(helm template test "$CHART_DIR" --set networkPolicy.enabled=true --set networkPolicy.allowExternal=false --show-only templates/networkpolicy.yaml 2>&1)
    if echo "$out" | grep -q "podSelector:" && echo "$out" | grep -q "from:"; then
        pass "template NetworkPolicy allowExternal=false restricts ingress"
    else
        fail "template NetworkPolicy allowExternal=false restricts ingress"
    fi

    # extraIngress
    out=$(helm template test "$CHART_DIR" \
        --set networkPolicy.enabled=true \
        --set 'networkPolicy.extraIngress[0].from[0].namespaceSelector.matchLabels.env=prod' \
        --show-only templates/networkpolicy.yaml 2>&1)
    if echo "$out" | grep -q "env: prod"; then
        pass "template NetworkPolicy extraIngress"
    else
        fail "template NetworkPolicy extraIngress"
    fi

    # extraEgress
    out=$(helm template test "$CHART_DIR" \
        --set networkPolicy.enabled=true \
        --set 'networkPolicy.extraEgress[0].to[0].ipBlock.cidr=10.0.0.0/8' \
        --show-only templates/networkpolicy.yaml 2>&1)
    if echo "$out" | grep -q "10.0.0.0/8" && echo "$out" | grep -q "Egress"; then
        pass "template NetworkPolicy extraEgress"
    else
        fail "template NetworkPolicy extraEgress"
    fi

    # NetworkPolicy with metrics port
    out=$(helm template test "$CHART_DIR" --set networkPolicy.enabled=true --set metrics.enabled=true --show-only templates/networkpolicy.yaml 2>&1)
    if echo "$out" | grep -q "9121"; then
        pass "template NetworkPolicy includes metrics port"
    else
        fail "template NetworkPolicy includes metrics port"
    fi

    # --- Init container configs ---

    # sysctl somaxconn value
    out=$(helm template test "$CHART_DIR" --set sysctlInit.enabled=true --set sysctlInit.somaxconn=1024 --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "net.core.somaxconn=1024"; then
        pass "template sysctl somaxconn=1024"
    else
        fail "template sysctl somaxconn=1024"
    fi

    # sysctl disableTHP
    out=$(helm template test "$CHART_DIR" --set sysctlInit.enabled=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "transparent_hugepage"; then
        pass "template sysctl disableTHP"
    else
        fail "template sysctl disableTHP"
    fi

    # sysctl resources
    out=$(helm template test "$CHART_DIR" \
        --set sysctlInit.enabled=true \
        --set sysctlInit.resources.requests.cpu=50m \
        --set sysctlInit.resources.requests.memory=32Mi \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "32Mi"; then
        pass "template sysctl init container resources"
    else
        fail "template sysctl init container resources"
    fi

    # volumePermissions resources
    out=$(helm template test "$CHART_DIR" \
        --set volumePermissions.enabled=true \
        --set volumePermissions.resources.requests.cpu=50m \
        --set volumePermissions.resources.requests.memory=64Mi \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "64Mi"; then
        pass "template volume-permissions resources"
    else
        fail "template volume-permissions resources"
    fi

    # Both init containers together
    out=$(helm template test "$CHART_DIR" \
        --set sysctlInit.enabled=true \
        --set volumePermissions.enabled=true \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "sysctl-init" && echo "$out" | grep -q "volume-permissions"; then
        pass "template both init containers present"
    else
        fail "template both init containers present"
    fi

    # --- Metrics configuration ---

    # metrics custom image
    out=$(helm template test "$CHART_DIR" \
        --set metrics.enabled=true \
        --set metrics.image.repository=myrepo/redis_exporter \
        --set metrics.image.tag=v1.99.0 \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "myrepo/redis_exporter:v1.99.0"; then
        pass "template metrics custom image"
    else
        fail "template metrics custom image"
    fi

    # metrics pullPolicy
    out=$(helm template test "$CHART_DIR" \
        --set metrics.enabled=true \
        --set metrics.image.pullPolicy=Always \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "imagePullPolicy: Always"; then
        pass "template metrics pullPolicy=Always"
    else
        fail "template metrics pullPolicy=Always"
    fi

    # metrics resources
    out=$(helm template test "$CHART_DIR" \
        --set metrics.enabled=true \
        --set metrics.resources.requests.cpu=100m \
        --set metrics.resources.requests.memory=128Mi \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "128Mi"; then
        pass "template metrics resources"
    else
        fail "template metrics resources"
    fi

    # metrics custom port
    out=$(helm template test "$CHART_DIR" \
        --set metrics.enabled=true \
        --set metrics.port=9200 \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "containerPort: 9200"; then
        pass "template metrics custom port"
    else
        fail "template metrics custom port"
    fi

    # ServiceMonitor custom namespace
    out=$(helm template test "$CHART_DIR" \
        --set metrics.enabled=true \
        --set metrics.serviceMonitor.enabled=true \
        --set metrics.serviceMonitor.namespace=monitoring \
        --show-only templates/servicemonitor.yaml 2>&1)
    if echo "$out" | grep -q "namespace: monitoring"; then
        pass "template ServiceMonitor custom namespace"
    else
        fail "template ServiceMonitor custom namespace"
    fi

    # ServiceMonitor custom interval
    out=$(helm template test "$CHART_DIR" \
        --set metrics.enabled=true \
        --set metrics.serviceMonitor.enabled=true \
        --set metrics.serviceMonitor.interval=15s \
        --show-only templates/servicemonitor.yaml 2>&1)
    if echo "$out" | grep -q "interval: 15s"; then
        pass "template ServiceMonitor custom interval"
    else
        fail "template ServiceMonitor custom interval"
    fi

    # ServiceMonitor scrapeTimeout
    out=$(helm template test "$CHART_DIR" \
        --set metrics.enabled=true \
        --set metrics.serviceMonitor.enabled=true \
        --set metrics.serviceMonitor.scrapeTimeout=10s \
        --show-only templates/servicemonitor.yaml 2>&1)
    if echo "$out" | grep -q "scrapeTimeout: 10s"; then
        pass "template ServiceMonitor scrapeTimeout"
    else
        fail "template ServiceMonitor scrapeTimeout"
    fi

    # ServiceMonitor custom labels
    out=$(helm template test "$CHART_DIR" \
        --set metrics.enabled=true \
        --set metrics.serviceMonitor.enabled=true \
        --set metrics.serviceMonitor.labels.release=prometheus \
        --show-only templates/servicemonitor.yaml 2>&1)
    if echo "$out" | grep -q "release: prometheus"; then
        pass "template ServiceMonitor custom labels"
    else
        fail "template ServiceMonitor custom labels"
    fi

    # PodMonitor custom namespace
    out=$(helm template test "$CHART_DIR" \
        --set metrics.enabled=true \
        --set metrics.podMonitor.enabled=true \
        --set metrics.podMonitor.namespace=monitoring \
        --show-only templates/podmonitor.yaml 2>&1)
    if echo "$out" | grep -q "namespace: monitoring"; then
        pass "template PodMonitor custom namespace"
    else
        fail "template PodMonitor custom namespace"
    fi

    # PodMonitor custom interval
    out=$(helm template test "$CHART_DIR" \
        --set metrics.enabled=true \
        --set metrics.podMonitor.enabled=true \
        --set metrics.podMonitor.interval=20s \
        --show-only templates/podmonitor.yaml 2>&1)
    if echo "$out" | grep -q "interval: 20s"; then
        pass "template PodMonitor custom interval"
    else
        fail "template PodMonitor custom interval"
    fi

    # PodMonitor custom labels
    out=$(helm template test "$CHART_DIR" \
        --set metrics.enabled=true \
        --set metrics.podMonitor.enabled=true \
        --set metrics.podMonitor.labels.team=backend \
        --show-only templates/podmonitor.yaml 2>&1)
    if echo "$out" | grep -q "team: backend"; then
        pass "template PodMonitor custom labels"
    else
        fail "template PodMonitor custom labels"
    fi

    # PrometheusRule custom namespace
    out=$(helm template test "$CHART_DIR" \
        --set metrics.enabled=true \
        --set metrics.prometheusRule.enabled=true \
        --set metrics.prometheusRule.namespace=monitoring \
        --set 'metrics.prometheusRule.rules[0].alert=Test' \
        --set 'metrics.prometheusRule.rules[0].expr=up==0' \
        --show-only templates/prometheusrule.yaml 2>&1)
    if echo "$out" | grep -q "namespace: monitoring"; then
        pass "template PrometheusRule custom namespace"
    else
        fail "template PrometheusRule custom namespace"
    fi

    # PrometheusRule custom labels
    out=$(helm template test "$CHART_DIR" \
        --set metrics.enabled=true \
        --set metrics.prometheusRule.enabled=true \
        --set metrics.prometheusRule.labels.role=alerting \
        --set 'metrics.prometheusRule.rules[0].alert=Test' \
        --set 'metrics.prometheusRule.rules[0].expr=up==0' \
        --show-only templates/prometheusrule.yaml 2>&1)
    if echo "$out" | grep -q "role: alerting"; then
        pass "template PrometheusRule custom labels"
    else
        fail "template PrometheusRule custom labels"
    fi

    # --- Persistence extras ---

    # PVC accessModes
    out=$(helm template test "$CHART_DIR" \
        --set 'persistence.accessModes[0]=ReadWriteMany' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "ReadWriteMany"; then
        pass "template persistence accessModes"
    else
        fail "template persistence accessModes"
    fi

    # PVC annotations
    out=$(helm template test "$CHART_DIR" \
        --set persistence.annotations.backup=enabled \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "backup: enabled"; then
        pass "template persistence annotations"
    else
        fail "template persistence annotations"
    fi

    # PVC retention whenScaled
    out=$(helm template test "$CHART_DIR" \
        --set persistentVolumeClaimRetentionPolicy.whenScaled=Delete \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "whenScaled: Delete"; then
        pass "template PVC retention whenScaled=Delete"
    else
        fail "template PVC retention whenScaled=Delete"
    fi

    # --- ServiceAccount extras ---

    # serviceAccount annotations
    out=$(helm template test "$CHART_DIR" \
        --set serviceAccount.annotations.iam\\.amazonaws\\.com/role=my-role \
        --show-only templates/serviceaccount.yaml 2>&1)
    if echo "$out" | grep -q "iam.amazonaws.com/role: my-role"; then
        pass "template serviceAccount annotations"
    else
        fail "template serviceAccount annotations"
    fi

    # --- Image pullPolicy ---

    # pullPolicy Always
    out=$(helm template test "$CHART_DIR" --set image.pullPolicy=Always --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "imagePullPolicy: Always"; then
        pass "template image pullPolicy=Always"
    else
        fail "template image pullPolicy=Always"
    fi

    # Multiple pullSecrets
    out=$(helm template test "$CHART_DIR" \
        --set 'image.pullSecrets[0].name=secret-one' \
        --set 'image.pullSecrets[1].name=secret-two' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "secret-one" && echo "$out" | grep -q "secret-two"; then
        pass "template multiple pullSecrets"
    else
        fail "template multiple pullSecrets"
    fi

    # --- Resource presets (all variants) ---

    # nano
    out=$(helm template test "$CHART_DIR" --set resourcePreset=nano --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "memory: 128Mi" && echo "$out" | grep -q "cpu: 100m"; then
        pass "template resource preset nano"
    else
        fail "template resource preset nano"
    fi

    # micro
    out=$(helm template test "$CHART_DIR" --set resourcePreset=micro --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "memory: 256Mi" && echo "$out" | grep -q "cpu: 250m"; then
        pass "template resource preset micro"
    else
        fail "template resource preset micro"
    fi

    # medium
    out=$(helm template test "$CHART_DIR" --set resourcePreset=medium --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "memory: 1Gi" && echo "$out" | grep -q 'cpu: "1"'; then
        pass "template resource preset medium"
    else
        fail "template resource preset medium"
    fi

    # large
    out=$(helm template test "$CHART_DIR" --set resourcePreset=large --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "memory: 2Gi" && echo "$out" | grep -q 'cpu: "2"'; then
        pass "template resource preset large"
    else
        fail "template resource preset large"
    fi

    # xlarge
    out=$(helm template test "$CHART_DIR" --set resourcePreset=xlarge --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "memory: 4Gi" && echo "$out" | grep -q 'cpu: "4"'; then
        pass "template resource preset xlarge"
    else
        fail "template resource preset xlarge"
    fi

    # none (no container resources section — VCT resources: for storage is expected)
    out=$(helm template test "$CHART_DIR" --set resourcePreset=none --show-only templates/statefulset.yaml 2>&1)
    # Check that no cpu/memory resources appear (the only "resources:" should be in volumeClaimTemplates for storage)
    if ! echo "$out" | grep -q "cpu:" && ! echo "$out" | grep -q "memory:"; then
        pass "template resource preset none (no resources)"
    else
        fail "template resource preset none (no resources)"
    fi

    # --- NOTES.txt (source file validation — cannot render via helm template) ---

    # NOTES.txt exists and contains expected content
    if [ -f "$CHART_DIR/templates/NOTES.txt" ]; then
        local notes_content
        notes_content=$(cat "$CHART_DIR/templates/NOTES.txt")
        if echo "$notes_content" | grep -q "standalone" || echo "$notes_content" | grep -q "cluster"; then
            pass "template NOTES.txt contains mode references"
        else
            fail "template NOTES.txt contains mode references"
        fi

        if echo "$notes_content" | grep -q "helm test"; then
            pass "template NOTES.txt contains helm test instructions"
        else
            fail "template NOTES.txt contains helm test instructions"
        fi

        if echo "$notes_content" | grep -q "cluster-init"; then
            pass "template NOTES.txt references cluster-init job"
        else
            fail "template NOTES.txt references cluster-init job"
        fi

        if echo "$notes_content" | grep -q "replicasPerPrimary"; then
            pass "template NOTES.txt references replicasPerPrimary"
        else
            fail "template NOTES.txt references replicasPerPrimary"
        fi
    else
        fail "template NOTES.txt file exists"
    fi

    # --- Graceful failover ---

    # Graceful failover preStop present in cluster mode
    out=$(helm template test "$CHART_DIR" --set mode=cluster --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "lifecycle:" && echo "$out" | grep -q "preStop:" && echo "$out" | grep -q "cluster failover"; then
        pass "template graceful failover preStop in cluster mode"
    else
        fail "template graceful failover preStop in cluster mode"
    fi

    # Graceful failover absent in standalone mode
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "lifecycle:"; then
        pass "template no lifecycle hook in standalone mode"
    else
        fail "template no lifecycle hook in standalone mode"
    fi

    # Graceful failover disabled
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set gracefulFailover.enabled=false --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "lifecycle:"; then
        pass "template graceful failover disabled"
    else
        fail "template graceful failover disabled"
    fi

    # User lifecycle overrides graceful failover
    out=$(helm template test "$CHART_DIR" --set mode=cluster \
        --set 'lifecycle.preStop.exec.command[0]=custom-shutdown' --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "custom-shutdown" && ! echo "$out" | grep -q "cluster failover"; then
        pass "template user lifecycle overrides graceful failover"
    else
        fail "template user lifecycle overrides graceful failover"
    fi

    # Graceful failover uses valkey-cli role (no grep/awk for hardened compat)
    out=$(helm template test "$CHART_DIR" --set mode=cluster --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "valkey-cli.*role" && ! echo "$out" | grep -q "grep\|awk"; then
        pass "template graceful failover uses shell builtins only (hardened compatible)"
    else
        fail "template graceful failover uses shell builtins only"
    fi

    # Graceful failover without auth
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set auth.enabled=false --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'AUTH=""'; then
        pass "template graceful failover no-auth mode"
    else
        fail "template graceful failover no-auth mode"
    fi

    # --- Cluster replicasPerPrimary ---

    # replicasPerPrimary used in cluster-init-job
    out=$(helm template test "$CHART_DIR" \
        --set mode=cluster \
        --set cluster.replicasPerPrimary=2 \
        --show-only templates/cluster-init-job.yaml 2>&1)
    if echo "$out" | grep -q "REPLICAS_PER_PRIMARY=2"; then
        pass "template cluster replicasPerPrimary=2 in cluster-init-job"
    else
        fail "template cluster replicasPerPrimary=2 in cluster-init-job"
    fi

    # --- Edge case: test-connection.yaml ---

    # test-connection pod renders
    out=$(helm template test "$CHART_DIR" --show-only templates/tests/test-connection.yaml 2>&1)
    if echo "$out" | grep -q "helm.sh/hook.*test" && echo "$out" | grep -q "valkey-cli"; then
        pass "template test-connection.yaml renders"
    else
        fail "template test-connection.yaml renders"
    fi

    # test-connection uses auth
    if echo "$out" | grep -q "VALKEY_PASSWORD"; then
        pass "template test-connection uses auth"
    else
        fail "template test-connection uses auth"
    fi

    # test-connection without auth
    out=$(helm template test "$CHART_DIR" --set auth.enabled=false --show-only templates/tests/test-connection.yaml 2>&1)
    if ! echo "$out" | grep -q "VALKEY_PASSWORD"; then
        pass "template test-connection no auth"
    else
        fail "template test-connection no auth"
    fi

    # --- Edge case: auth disabled + existingSecret (should ignore existingSecret) ---

    out=$(helm template test "$CHART_DIR" --set auth.enabled=false --set auth.existingSecret=my-secret 2>&1)
    if ! echo "$out" | grep -q "kind: Secret" && ! echo "$out" | grep -q "VALKEY_PASSWORD"; then
        pass "template auth.disabled ignores existingSecret"
    else
        fail "template auth.disabled ignores existingSecret"
    fi

    # --- Edge case: hardened variant with custom containerSecurityContext ---
    # hardened should override containerSecurityContext (uses its own block)
    out=$(helm template test "$CHART_DIR" \
        --set image.variant=hardened \
        --set containerSecurityContext.readOnlyRootFilesystem=false \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "readOnlyRootFilesystem: true"; then
        pass "template hardened overrides containerSecurityContext"
    else
        fail "template hardened overrides containerSecurityContext"
    fi

    # --- Edge case: all monitoring components enabled simultaneously ---
    local sm_ok=false pm_ok=false pr_ok=false
    local _mon_args="--set metrics.enabled=true --set metrics.serviceMonitor.enabled=true --set metrics.podMonitor.enabled=true --set metrics.prometheusRule.enabled=true"
    helm template test "$CHART_DIR" $_mon_args \
        --set 'metrics.prometheusRule.rules[0].alert=Test' --set 'metrics.prometheusRule.rules[0].expr=up==0' \
        --show-only templates/servicemonitor.yaml 2>&1 | grep -q "ServiceMonitor" && sm_ok=true
    helm template test "$CHART_DIR" $_mon_args \
        --set 'metrics.prometheusRule.rules[0].alert=Test' --set 'metrics.prometheusRule.rules[0].expr=up==0' \
        --show-only templates/podmonitor.yaml 2>&1 | grep -q "PodMonitor" && pm_ok=true
    helm template test "$CHART_DIR" $_mon_args \
        --set 'metrics.prometheusRule.rules[0].alert=Test' --set 'metrics.prometheusRule.rules[0].expr=up==0' \
        --show-only templates/prometheusrule.yaml 2>&1 | grep -q "PrometheusRule" && pr_ok=true
    if $sm_ok && $pm_ok && $pr_ok; then
        pass "template all monitoring components together"
    else
        fail "template all monitoring components together (sm=$sm_ok pm=$pm_ok pr=$pr_ok)"
    fi

    # --- Edge case: cluster mode with metrics + networkPolicy ---
    local np_ok=false ss_ok=false cm_ok=false
    helm template test "$CHART_DIR" --set mode=cluster --set metrics.enabled=true --set networkPolicy.enabled=true \
        --show-only templates/networkpolicy.yaml 2>&1 | grep -q "NetworkPolicy" && np_ok=true
    helm template test "$CHART_DIR" --set mode=cluster --set metrics.enabled=true --set networkPolicy.enabled=true \
        --show-only templates/statefulset.yaml 2>&1 | grep -q "redis_exporter" && ss_ok=true
    helm template test "$CHART_DIR" --set mode=cluster --set metrics.enabled=true --set networkPolicy.enabled=true \
        --show-only templates/configmap.yaml 2>&1 | grep -q "cluster-enabled" && cm_ok=true
    if $np_ok && $ss_ok && $cm_ok; then
        pass "template cluster + metrics + networkPolicy combined"
    else
        fail "template cluster + metrics + networkPolicy combined (np=$np_ok ss=$ss_ok cm=$cm_ok)"
    fi
}

# --- Deployment Tests ---

test_standalone_rpm() {
    bold "=== TEST: Standalone RPM ==="
    local rel="t-standalone"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "standalone rpm install"; cleanup "$rel"; return; }
    pass "standalone rpm install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "standalone rpm pod ready"
    else
        fail "standalone rpm pod ready"; cleanup "$rel"; return
    fi

    # Ping
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS ping 2>/dev/null | grep -q PONG; then
        pass "standalone rpm valkey-cli ping"
    else
        fail "standalone rpm valkey-cli ping"
    fi

    # Set/Get
    kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS set test-key test-value > /dev/null 2>&1
    local val=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS get test-key 2>/dev/null)
    if [ "$val" = "test-value" ]; then
        pass "standalone rpm set/get"
    else
        fail "standalone rpm set/get (got: $val)"
    fi

    # Disabled commands
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS FLUSHDB 2>&1 | grep -qi "error\|ERR"; then
        pass "standalone rpm FLUSHDB disabled"
    else
        fail "standalone rpm FLUSHDB disabled"
    fi

    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS FLUSHALL 2>&1 | grep -qi "error\|ERR"; then
        pass "standalone rpm FLUSHALL disabled"
    else
        fail "standalone rpm FLUSHALL disabled"
    fi

    # Helm test
    if helm test "$rel" -n $NAMESPACE > /dev/null 2>&1; then
        pass "standalone rpm helm test"
    else
        fail "standalone rpm helm test"
    fi

    cleanup "$rel"
}

test_standalone_hardened() {
    bold "=== TEST: Standalone Hardened ==="
    if [ "$SKIP_HARDENED" = "true" ]; then
        skip "standalone hardened (SKIP_HARDENED=true)"
        return
    fi
    local rel="t-hardened"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set image.variant=hardened \
        --set auth.password=$PASS \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "standalone hardened install"; cleanup "$rel"; return; }
    pass "standalone hardened install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "standalone hardened pod ready"
    else
        fail "standalone hardened pod ready"; cleanup "$rel"; return
    fi

    # Ping
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS ping 2>/dev/null | grep -q PONG; then
        pass "standalone hardened valkey-cli ping"
    else
        fail "standalone hardened valkey-cli ping"
    fi

    # Set/Get
    kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS set hrd-key hrd-value > /dev/null 2>&1
    local val=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS get hrd-key 2>/dev/null)
    if [ "$val" = "hrd-value" ]; then
        pass "standalone hardened set/get"
    else
        fail "standalone hardened set/get (got: $val)"
    fi

    # Helm test
    if helm test "$rel" -n $NAMESPACE > /dev/null 2>&1; then
        pass "standalone hardened helm test"
    else
        fail "standalone hardened helm test"
    fi

    cleanup "$rel"
}

test_persistence() {
    bold "=== TEST: Persistence (data survives pod restart) ==="
    local rel="t-persist"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "persistence install"; cleanup "$rel"; return; }
    pass "persistence install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "persistence pod ready"
    else
        fail "persistence pod ready"; cleanup "$rel"; return
    fi

    # Write data
    kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS set persist-key "survived-restart" > /dev/null 2>&1

    # Delete pod (StatefulSet recreates it)
    kubectl delete pod ${rel}-percona-valkey-0 -n $NAMESPACE --wait=true > /dev/null 2>&1

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "persistence pod restarted"
    else
        fail "persistence pod restarted"; cleanup "$rel"; return
    fi

    # Verify data
    sleep 3
    local val=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS get persist-key 2>/dev/null)
    if [ "$val" = "survived-restart" ]; then
        pass "persistence data survived pod restart"
    else
        fail "persistence data survived pod restart (got: $val)"
    fi

    cleanup "$rel"
}

test_no_auth() {
    bold "=== TEST: Auth disabled ==="
    local rel="t-noauth"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.enabled=false \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "no-auth install"; cleanup "$rel"; return; }
    pass "no-auth install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "no-auth pod ready"
    else
        fail "no-auth pod ready"; cleanup "$rel"; return
    fi

    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli ping 2>/dev/null | grep -q PONG; then
        pass "no-auth valkey-cli ping (no password)"
    else
        fail "no-auth valkey-cli ping (no password)"
    fi

    if helm test "$rel" -n $NAMESPACE > /dev/null 2>&1; then
        pass "no-auth helm test"
    else
        fail "no-auth helm test"
    fi

    cleanup "$rel"
}

test_secret_lookup() {
    bold "=== TEST: Secret lookup (password preserved on upgrade) ==="
    local rel="t-secretlookup"
    cleanup "$rel"

    # Install with auto-generated password
    helm install "$rel" "$CHART_DIR" \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "secret-lookup install"; cleanup "$rel"; return; }
    pass "secret-lookup install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "secret-lookup pod ready"
    else
        fail "secret-lookup pod ready"; cleanup "$rel"; return
    fi

    # Get the generated password
    local pw1=$(kubectl get secret ${rel}-percona-valkey -n $NAMESPACE -o jsonpath="{.data.valkey-password}" 2>/dev/null | base64 -d)
    if [ -n "$pw1" ]; then
        pass "secret-lookup password auto-generated (${#pw1} chars)"
    else
        fail "secret-lookup password auto-generated"; cleanup "$rel"; return
    fi

    # Upgrade (should preserve password). Use --reuse-values to keep all defaults unchanged.
    helm upgrade "$rel" "$CHART_DIR" \
        --reuse-values \
        --set-string podAnnotations.upgraded=true \
        -n $NAMESPACE --wait --timeout 300s 2>&1 || { fail "secret-lookup upgrade"; cleanup "$rel"; return; }
    pass "secret-lookup upgrade"

    # Get password after upgrade
    local pw2=$(kubectl get secret ${rel}-percona-valkey -n $NAMESPACE -o jsonpath="{.data.valkey-password}" 2>/dev/null | base64 -d)
    if [ "$pw1" = "$pw2" ]; then
        pass "secret-lookup password preserved after upgrade ($pw1)"
    else
        fail "secret-lookup password changed ($pw1 -> $pw2)"
    fi

    # Verify the old password still works
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a "$pw1" ping 2>/dev/null | grep -q PONG; then
        pass "secret-lookup old password still works after upgrade"
    else
        fail "secret-lookup old password still works after upgrade"
    fi

    cleanup "$rel"
}

test_existing_secret() {
    bold "=== TEST: Existing secret ==="
    local rel="t-existsecret"
    cleanup "$rel"

    # Create external secret
    kubectl create secret generic my-ext-secret \
        --from-literal=valkey-password=external-pass-123 \
        -n $NAMESPACE 2>/dev/null || true

    helm install "$rel" "$CHART_DIR" \
        --set auth.existingSecret=my-ext-secret \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "existing-secret install"; cleanup "$rel"; kubectl delete secret my-ext-secret -n $NAMESPACE 2>/dev/null; return; }
    pass "existing-secret install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "existing-secret pod ready"
    else
        fail "existing-secret pod ready"; cleanup "$rel"; kubectl delete secret my-ext-secret -n $NAMESPACE 2>/dev/null; return
    fi

    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a external-pass-123 ping 2>/dev/null | grep -q PONG; then
        pass "existing-secret password works"
    else
        fail "existing-secret password works"
    fi

    cleanup "$rel"
    kubectl delete secret my-ext-secret -n $NAMESPACE 2>/dev/null || true
}

test_resource_preset() {
    bold "=== TEST: Resource preset ==="
    local rel="t-preset"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set resourcePreset=micro \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "resource-preset install"; cleanup "$rel"; return; }
    pass "resource-preset install (micro)"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "resource-preset pod ready"
    else
        fail "resource-preset pod ready"; cleanup "$rel"; return
    fi

    # Verify resources are set
    local mem=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.containers[0].resources.requests.memory}' 2>/dev/null)
    if [ "$mem" = "256Mi" ]; then
        pass "resource-preset memory request = 256Mi"
    else
        fail "resource-preset memory request (got: $mem, expected: 256Mi)"
    fi

    cleanup "$rel"
}

test_cluster_rpm() {
    bold "=== TEST: Cluster RPM (6 nodes) ==="
    local rel="t-cluster"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set mode=cluster \
        --set auth.password=$PASS \
        -n $NAMESPACE --timeout $TIMEOUT 2>&1 || { fail "cluster rpm install"; cleanup "$rel"; return; }
    pass "cluster rpm install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 6 300s; then
        pass "cluster rpm all 6 pods ready"
    else
        fail "cluster rpm all 6 pods ready"; cleanup "$rel"; return
    fi

    # Cluster state
    local state=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS cluster info 2>/dev/null | grep cluster_state | tr -d '\r')
    if [ "$state" = "cluster_state:ok" ]; then
        pass "cluster rpm cluster_state:ok"
    else
        fail "cluster rpm cluster_state:ok (got: $state)"
    fi

    # Cluster size
    local size=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS cluster info 2>/dev/null | grep cluster_size | tr -d '\r')
    if [ "$size" = "cluster_size:3" ]; then
        pass "cluster rpm cluster_size:3 (3 primaries)"
    else
        fail "cluster rpm cluster_size (got: $size)"
    fi

    # Known nodes
    local known=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS cluster info 2>/dev/null | grep cluster_known_nodes | tr -d '\r')
    if [ "$known" = "cluster_known_nodes:6" ]; then
        pass "cluster rpm cluster_known_nodes:6"
    else
        fail "cluster rpm cluster_known_nodes (got: $known)"
    fi

    # Slots assigned
    local slots=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS cluster info 2>/dev/null | grep cluster_slots_ok | tr -d '\r')
    if [ "$slots" = "cluster_slots_ok:16384" ]; then
        pass "cluster rpm all 16384 slots assigned"
    else
        fail "cluster rpm slots (got: $slots)"
    fi

    # Cluster set/get with -c
    kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS -c set cluster-key cluster-value > /dev/null 2>&1
    local val=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS -c get cluster-key 2>/dev/null)
    if [ "$val" = "cluster-value" ]; then
        pass "cluster rpm set/get with -c"
    else
        fail "cluster rpm set/get (got: $val)"
    fi

    # Helm test
    if helm test "$rel" -n $NAMESPACE > /dev/null 2>&1; then
        pass "cluster rpm helm test"
    else
        fail "cluster rpm helm test"
    fi

    # Disabled commands in cluster
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS FLUSHDB 2>&1 | grep -qi "error\|ERR"; then
        pass "cluster rpm FLUSHDB disabled"
    else
        fail "cluster rpm FLUSHDB disabled"
    fi

    cleanup "$rel"
}

test_cluster_hardened() {
    bold "=== TEST: Cluster Hardened ==="
    if [ "$SKIP_HARDENED" = "true" ]; then
        skip "cluster hardened (SKIP_HARDENED=true)"
        return
    fi
    local rel="t-cluster-hrd"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set mode=cluster \
        --set image.variant=hardened \
        --set auth.password=$PASS \
        -n $NAMESPACE --timeout $TIMEOUT 2>&1 || { fail "cluster hardened install"; cleanup "$rel"; return; }
    pass "cluster hardened install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 6 300s; then
        pass "cluster hardened all 6 pods ready"
    else
        fail "cluster hardened all 6 pods ready"; cleanup "$rel"; return
    fi

    local state=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS cluster info 2>/dev/null | grep cluster_state | tr -d '\r')
    if [ "$state" = "cluster_state:ok" ]; then
        pass "cluster hardened cluster_state:ok"
    else
        fail "cluster hardened cluster_state:ok (got: $state)"
    fi

    if helm test "$rel" -n $NAMESPACE > /dev/null 2>&1; then
        pass "cluster hardened helm test"
    else
        fail "cluster hardened helm test"
    fi

    cleanup "$rel"
}

test_graceful_failover() {
    bold "=== TEST: Graceful failover on pod termination ==="
    local rel="t-failover"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set mode=cluster \
        --set auth.password=$PASS \
        -n $NAMESPACE --timeout 300s 2>&1 || { fail "graceful-failover install"; cleanup "$rel"; return; }
    pass "graceful-failover install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 6 300s; then
        pass "graceful-failover 6 pods ready"
    else
        fail "graceful-failover 6 pods ready"; cleanup "$rel"; return
    fi

    local state=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS cluster info 2>/dev/null | grep cluster_state | tr -d '\r')
    if [ "$state" != "cluster_state:ok" ]; then
        fail "graceful-failover cluster_state:ok (got: $state)"; cleanup "$rel"; return
    fi
    pass "graceful-failover cluster_state:ok"

    # Verify preStop hook is set on the pod
    local prestop=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.containers[0].lifecycle.preStop.exec.command}' 2>/dev/null)
    if echo "$prestop" | grep -q "failover"; then
        pass "graceful-failover preStop hook present"
    else
        fail "graceful-failover preStop hook present (got: $prestop)"
    fi

    # Find a primary node
    local primary_pod=""
    for i in $(seq 0 5); do
        local role=$(kubectl exec ${rel}-percona-valkey-$i -n $NAMESPACE -- valkey-cli -a $PASS role 2>/dev/null | head -1 | tr -d '\r')
        if [ "$role" = "master" ]; then
            primary_pod="${rel}-percona-valkey-$i"
            break
        fi
    done

    if [ -z "$primary_pod" ]; then
        fail "graceful-failover could not find primary"; cleanup "$rel"; return
    fi
    pass "graceful-failover found primary: $primary_pod"

    # Write data before failover
    kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS -c set failover-key "must-survive" > /dev/null 2>&1

    # Delete the primary pod (triggers preStop -> CLUSTER FAILOVER)
    kubectl delete pod "$primary_pod" -n $NAMESPACE --wait=true > /dev/null 2>&1

    # Wait for pod to come back
    if wait_for_pods "app.kubernetes.io/instance=$rel" 6 300s; then
        pass "graceful-failover all 6 pods recovered"
    else
        fail "graceful-failover pods recovered"; cleanup "$rel"; return
    fi

    # Cluster should still be healthy
    sleep 5
    local state2=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS cluster info 2>/dev/null | grep cluster_state | tr -d '\r')
    if [ "$state2" = "cluster_state:ok" ]; then
        pass "graceful-failover cluster_state:ok after failover"
    else
        fail "graceful-failover cluster_state:ok after failover (got: $state2)"
    fi

    # All 16384 slots still assigned
    local slots=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS cluster info 2>/dev/null | grep cluster_slots_ok | tr -d '\r')
    if [ "$slots" = "cluster_slots_ok:16384" ]; then
        pass "graceful-failover all 16384 slots intact"
    else
        fail "graceful-failover slots (got: $slots)"
    fi

    # Data survived
    local val=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS -c get failover-key 2>/dev/null)
    if [ "$val" = "must-survive" ]; then
        pass "graceful-failover data survived"
    else
        fail "graceful-failover data survived (got: $val)"
    fi

    cleanup "$rel"
}

test_cluster_scale_up() {
    bold "=== TEST: Cluster scale up (6 -> 8) ==="
    local rel="t-scaleup"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set mode=cluster \
        --set auth.password=$PASS \
        -n $NAMESPACE --timeout $TIMEOUT 2>&1 || { fail "scale-up install"; cleanup "$rel"; return; }
    pass "scale-up install (6 nodes)"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 6 300s; then
        pass "scale-up initial 6 pods ready"
    else
        fail "scale-up initial 6 pods ready"; cleanup "$rel"; return
    fi

    # Write test data before scaling
    kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS -c set before-scale "preserved" > /dev/null 2>&1

    # Scale up
    helm upgrade "$rel" "$CHART_DIR" \
        --set mode=cluster \
        --set cluster.replicas=8 \
        --set auth.password=$PASS \
        -n $NAMESPACE --timeout 300s 2>&1 || { fail "scale-up upgrade to 8"; cleanup "$rel"; return; }
    pass "scale-up upgrade to 8 nodes"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 8 300s; then
        pass "scale-up all 8 pods ready"
    else
        fail "scale-up all 8 pods ready"; cleanup "$rel"; return
    fi

    # Wait for scale job to complete
    sleep 10

    local known=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS cluster info 2>/dev/null | grep cluster_known_nodes | tr -d '\r')
    if [ "$known" = "cluster_known_nodes:8" ]; then
        pass "scale-up cluster knows 8 nodes"
    else
        fail "scale-up cluster nodes (got: $known)"
    fi

    local state=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS cluster info 2>/dev/null | grep cluster_state | tr -d '\r')
    if [ "$state" = "cluster_state:ok" ]; then
        pass "scale-up cluster_state:ok"
    else
        fail "scale-up cluster_state:ok (got: $state)"
    fi

    # Verify old data survived
    local val=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS -c get before-scale 2>/dev/null)
    if [ "$val" = "preserved" ]; then
        pass "scale-up data preserved"
    else
        fail "scale-up data preserved (got: $val)"
    fi

    cleanup "$rel"
}

test_cluster_scale_down() {
    bold "=== TEST: Cluster scale down (8 -> 6) ==="
    local rel="t-scaledn"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set mode=cluster \
        --set cluster.replicas=8 \
        --set auth.password=$PASS \
        -n $NAMESPACE --timeout $TIMEOUT 2>&1 || { fail "scale-down install (8)"; cleanup "$rel"; return; }
    pass "scale-down install (8 nodes)"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 8 300s; then
        pass "scale-down initial 8 pods ready"
    else
        fail "scale-down initial 8 pods ready"; cleanup "$rel"; return
    fi

    # Write data
    kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS -c set scaledown-key "must-survive" > /dev/null 2>&1

    # Scale down
    helm upgrade "$rel" "$CHART_DIR" \
        --set mode=cluster \
        --set cluster.replicas=6 \
        --set auth.password=$PASS \
        -n $NAMESPACE --timeout 300s 2>&1 || { fail "scale-down upgrade to 6"; cleanup "$rel"; return; }
    pass "scale-down upgrade to 6 nodes"

    # Wait for pods to terminate and scale job to finish
    sleep 30

    if wait_for_pods "app.kubernetes.io/instance=$rel" 6 300s; then
        pass "scale-down 6 pods ready"
    else
        fail "scale-down 6 pods ready"; cleanup "$rel"; return
    fi

    # Wait for scale job cleanup
    sleep 20

    local state=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS cluster info 2>/dev/null | grep cluster_state | tr -d '\r')
    if [ "$state" = "cluster_state:ok" ]; then
        pass "scale-down cluster_state:ok"
    else
        fail "scale-down cluster_state:ok (got: $state)"
    fi

    local slots=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS cluster info 2>/dev/null | grep cluster_slots_ok | tr -d '\r')
    if [ "$slots" = "cluster_slots_ok:16384" ]; then
        pass "scale-down all 16384 slots intact"
    else
        fail "scale-down slots (got: $slots)"
    fi

    # Verify data survived
    local val=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS -c get scaledown-key 2>/dev/null)
    if [ "$val" = "must-survive" ]; then
        pass "scale-down data survived"
    else
        fail "scale-down data survived (got: $val)"
    fi

    cleanup "$rel"
}

test_metrics_sidecar() {
    bold "=== TEST: Metrics exporter sidecar ==="
    local rel="t-metrics"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set metrics.enabled=true \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "metrics install"; cleanup "$rel"; return; }
    pass "metrics install"

    # Pod should have 2 containers (valkey + metrics)
    local containers=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
    if echo "$containers" | grep -q "metrics"; then
        pass "metrics sidecar container present"
    else
        fail "metrics sidecar container present (containers: $containers)"
    fi

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "metrics pod ready (2/2)"
    else
        fail "metrics pod ready"; cleanup "$rel"; return
    fi

    # Check metrics endpoint (query from valkey container — exporter image has no wget/curl)
    local metrics_output=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -c valkey -- \
        sh -c 'exec 3<>/dev/tcp/127.0.0.1/9121; printf "GET /metrics HTTP/1.0\r\nHost: localhost\r\n\r\n" >&3; cat <&3' 2>/dev/null)
    if echo "$metrics_output" | grep -q "redis_up"; then
        pass "metrics endpoint returns redis_up"
    else
        fail "metrics endpoint returns redis_up"
    fi

    # Check metrics service exists
    if kubectl get svc ${rel}-percona-valkey-metrics -n $NAMESPACE > /dev/null 2>&1; then
        pass "metrics service exists"
    else
        fail "metrics service exists"
    fi

    cleanup "$rel"
}

test_password_file_mount() {
    bold "=== TEST: Password file mounting ==="
    local rel="t-pwfile"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set auth.usePasswordFiles=true \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "password-file install"; cleanup "$rel"; return; }
    pass "password-file install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "password-file pod ready"
    else
        fail "password-file pod ready"; cleanup "$rel"; return
    fi

    # Verify the password file exists in the pod
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- cat /opt/valkey/secrets/valkey-password 2>/dev/null | grep -q "$PASS"; then
        pass "password-file mounted and contains correct password"
    else
        fail "password-file mounted and contains correct password"
    fi

    # Verify valkey-cli works (entrypoint reads VALKEY_PASSWORD_FILE)
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS ping 2>/dev/null | grep -q PONG; then
        pass "password-file valkey-cli ping"
    else
        fail "password-file valkey-cli ping"
    fi

    cleanup "$rel"
}

test_extra_env_vars() {
    bold "=== TEST: Extra environment variables ==="
    local rel="t-extraenv"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set 'extraEnvVars[0].name=MY_CUSTOM_VAR' \
        --set 'extraEnvVars[0].value=hello-world' \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "extraEnvVars install"; cleanup "$rel"; return; }
    pass "extraEnvVars install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "extraEnvVars pod ready"
    else
        fail "extraEnvVars pod ready"; cleanup "$rel"; return
    fi

    # Verify env var is set inside the container
    local val=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- sh -c 'echo $MY_CUSTOM_VAR' 2>/dev/null)
    if [ "$val" = "hello-world" ]; then
        pass "extraEnvVars MY_CUSTOM_VAR=hello-world"
    else
        fail "extraEnvVars MY_CUSTOM_VAR (got: '$val')"
    fi

    cleanup "$rel"
}

test_extra_volumes() {
    bold "=== TEST: Extra volumes + mounts ==="
    local rel="t-extravol"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set 'extraVolumes[0].name=scratch' \
        --set 'extraVolumes[0].emptyDir.medium=Memory' \
        --set 'extraVolumeMounts[0].name=scratch' \
        --set 'extraVolumeMounts[0].mountPath=/scratch' \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "extraVolumes install"; cleanup "$rel"; return; }
    pass "extraVolumes install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "extraVolumes pod ready"
    else
        fail "extraVolumes pod ready"; cleanup "$rel"; return
    fi

    # Verify the mount exists and is writable
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- sh -c 'echo test > /scratch/testfile && cat /scratch/testfile' 2>/dev/null | grep -q "test"; then
        pass "extraVolumes /scratch is mounted and writable"
    else
        fail "extraVolumes /scratch is mounted and writable"
    fi

    cleanup "$rel"
}

test_diagnostic_mode() {
    bold "=== TEST: Diagnostic mode ==="
    local rel="t-diag"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set diagnosticMode.enabled=true \
        -n $NAMESPACE --timeout $TIMEOUT 2>&1 || { fail "diagnostic-mode install"; cleanup "$rel"; return; }
    pass "diagnostic-mode install"

    # Wait for pod to be running (it won't pass readiness since valkey isn't running)
    local deadline=$(( $(date +%s) + 120 ))
    local running=false
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local phase=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$phase" = "Running" ]; then
            running=true
            break
        fi
        sleep 3
    done

    if $running; then
        pass "diagnostic-mode pod running"
    else
        fail "diagnostic-mode pod running"; cleanup "$rel"; return
    fi

    # Verify valkey-server is NOT running (sleep infinity instead)
    local procs=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- ps aux 2>/dev/null || kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- sh -c 'ls /proc/*/cmdline 2>/dev/null | head -20' 2>/dev/null)
    if ! kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- sh -c 'pgrep valkey-server' > /dev/null 2>&1; then
        pass "diagnostic-mode valkey-server NOT running"
    else
        fail "diagnostic-mode valkey-server NOT running (should be sleeping)"
    fi

    # Verify we can exec into it
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- echo "alive" 2>/dev/null | grep -q "alive"; then
        pass "diagnostic-mode can exec into pod"
    else
        fail "diagnostic-mode can exec into pod"
    fi

    cleanup "$rel"
}

test_persistence_disabled() {
    bold "=== TEST: Persistence disabled (emptyDir) ==="
    local rel="t-nopvc"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set persistence.enabled=false \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "no-persistence install"; cleanup "$rel"; return; }
    pass "no-persistence install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "no-persistence pod ready"
    else
        fail "no-persistence pod ready"; cleanup "$rel"; return
    fi

    # Verify no PVC was created
    local pvcs=$(kubectl get pvc -l "app.kubernetes.io/instance=$rel" -n $NAMESPACE --no-headers 2>/dev/null | wc -l)
    if [ "$pvcs" -eq 0 ]; then
        pass "no-persistence no PVCs created"
    else
        fail "no-persistence PVCs found ($pvcs)"
    fi

    # Valkey still works
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS ping 2>/dev/null | grep -q PONG; then
        pass "no-persistence valkey-cli ping"
    else
        fail "no-persistence valkey-cli ping"
    fi

    cleanup "$rel"
}

test_custom_config() {
    bold "=== TEST: Custom configuration values ==="
    local rel="t-config"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set config.maxmemory=64mb \
        --set config.maxmemoryPolicy=allkeys-lru \
        --set config.customConfig="hz 20" \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "custom-config install"; cleanup "$rel"; return; }
    pass "custom-config install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "custom-config pod ready"
    else
        fail "custom-config pod ready"; cleanup "$rel"; return
    fi

    # Verify maxmemory is set
    local maxmem=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS config get maxmemory 2>/dev/null | tail -1)
    if [ "$maxmem" = "67108864" ]; then
        pass "custom-config maxmemory=64mb (67108864 bytes)"
    else
        fail "custom-config maxmemory (got: $maxmem, expected: 67108864)"
    fi

    # Verify maxmemory-policy
    local policy=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS config get maxmemory-policy 2>/dev/null | tail -1)
    if [ "$policy" = "allkeys-lru" ]; then
        pass "custom-config maxmemory-policy=allkeys-lru"
    else
        fail "custom-config maxmemory-policy (got: $policy)"
    fi

    # Verify custom hz setting
    local hz=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS config get hz 2>/dev/null | tail -1)
    if [ "$hz" = "20" ]; then
        pass "custom-config customConfig hz=20"
    else
        fail "custom-config customConfig hz (got: $hz)"
    fi

    cleanup "$rel"
}

test_config_rolling_restart() {
    bold "=== TEST: Config change triggers rolling restart ==="
    local rel="t-rollrestart"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "rolling-restart install"; cleanup "$rel"; return; }
    pass "rolling-restart install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "rolling-restart pod ready"
    else
        fail "rolling-restart pod ready"; cleanup "$rel"; return
    fi

    # Get initial pod UID
    local uid1=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.metadata.uid}' 2>/dev/null)

    # Upgrade with config change (this changes configmap checksum -> triggers restart)
    helm upgrade "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set config.customConfig="hz 50" \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "rolling-restart upgrade"; cleanup "$rel"; return; }
    pass "rolling-restart upgrade"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "rolling-restart pod ready after upgrade"
    else
        fail "rolling-restart pod ready after upgrade"; cleanup "$rel"; return
    fi

    # Get new pod UID — should differ (pod was recreated)
    local uid2=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.metadata.uid}' 2>/dev/null)
    if [ "$uid1" != "$uid2" ]; then
        pass "rolling-restart pod UID changed (config change triggered restart)"
    else
        fail "rolling-restart pod UID unchanged (expected restart)"
    fi

    # Verify new config is applied
    local hz=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS config get hz 2>/dev/null | tail -1)
    if [ "$hz" = "50" ]; then
        pass "rolling-restart new config applied (hz=50)"
    else
        fail "rolling-restart new config applied (got hz=$hz)"
    fi

    cleanup "$rel"
}

test_cluster_multi_slot() {
    bold "=== TEST: Cluster multi-slot operations ==="
    local rel="t-multislot"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set mode=cluster \
        --set auth.password=$PASS \
        -n $NAMESPACE --timeout $TIMEOUT 2>&1 || { fail "multi-slot install"; cleanup "$rel"; return; }
    pass "multi-slot install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 6 300s; then
        pass "multi-slot 6 pods ready"
    else
        fail "multi-slot 6 pods ready"; cleanup "$rel"; return
    fi

    local state=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS cluster info 2>/dev/null | grep cluster_state | tr -d '\r')
    if [ "$state" != "cluster_state:ok" ]; then
        fail "multi-slot cluster_state:ok (got: $state)"; cleanup "$rel"; return
    fi
    pass "multi-slot cluster_state:ok"

    # Write keys that hash to different slots
    # "foo" -> slot 12182, "bar" -> slot 5061, "hello" -> slot 866, "baz" -> slot 4813
    local keys=("foo" "bar" "hello" "baz" "key1" "key2" "key3" "key4" "key5" "key6")
    local all_set=true
    for k in "${keys[@]}"; do
        kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS -c set "$k" "value-$k" > /dev/null 2>&1 || all_set=false
    done
    if $all_set; then
        pass "multi-slot set 10 keys across hash slots"
    else
        fail "multi-slot set 10 keys across hash slots"
    fi

    # Read them all back
    local all_get=true
    for k in "${keys[@]}"; do
        local v=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS -c get "$k" 2>/dev/null)
        if [ "$v" != "value-$k" ]; then
            all_get=false
            echo "    Key $k: expected value-$k, got $v"
        fi
    done
    if $all_get; then
        pass "multi-slot get all 10 keys correct"
    else
        fail "multi-slot get some keys incorrect"
    fi

    # Verify keys are distributed across multiple nodes
    local nodes_with_keys=0
    for i in $(seq 0 5); do
        local dbsize=$(kubectl exec ${rel}-percona-valkey-$i -n $NAMESPACE -- valkey-cli -a $PASS dbsize 2>/dev/null | grep -o '[0-9]*' || echo "0")
        if [ "${dbsize:-0}" -gt 0 ]; then
            nodes_with_keys=$((nodes_with_keys + 1))
        fi
    done
    if [ "$nodes_with_keys" -ge 2 ]; then
        pass "multi-slot keys distributed across $nodes_with_keys nodes"
    else
        fail "multi-slot keys only on $nodes_with_keys node(s)"
    fi

    cleanup "$rel"
}

test_cluster_custom_node_timeout() {
    bold "=== TEST: Cluster with custom nodeTimeout ==="
    local rel="t-timeout"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set mode=cluster \
        --set auth.password=$PASS \
        --set cluster.nodeTimeout=5000 \
        -n $NAMESPACE --timeout $TIMEOUT 2>&1 || { fail "custom-nodeTimeout install"; cleanup "$rel"; return; }
    pass "custom-nodeTimeout install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 6 300s; then
        pass "custom-nodeTimeout 6 pods ready"
    else
        fail "custom-nodeTimeout 6 pods ready"; cleanup "$rel"; return
    fi

    local state=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS cluster info 2>/dev/null | grep cluster_state | tr -d '\r')
    if [ "$state" = "cluster_state:ok" ]; then
        pass "custom-nodeTimeout cluster_state:ok"
    else
        fail "custom-nodeTimeout cluster_state:ok (got: $state)"
    fi

    # Verify node-timeout is actually set to 5000
    local timeout=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS config get cluster-node-timeout 2>/dev/null | tail -1)
    if [ "$timeout" = "5000" ]; then
        pass "custom-nodeTimeout cluster-node-timeout=5000"
    else
        fail "custom-nodeTimeout cluster-node-timeout (got: $timeout)"
    fi

    cleanup "$rel"
}

test_hardened_security_verify() {
    bold "=== TEST: Hardened security verification ==="
    if [ "$SKIP_HARDENED" = "true" ]; then
        skip "hardened security verification (SKIP_HARDENED=true)"
        return
    fi
    local rel="t-hrdsec"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set image.variant=hardened \
        --set auth.password=$PASS \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "hardened-security install"; cleanup "$rel"; return; }
    pass "hardened-security install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "hardened-security pod ready"
    else
        fail "hardened-security pod ready"; cleanup "$rel"; return
    fi

    # Verify readOnlyRootFilesystem is set in the pod spec
    local rofs=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.containers[0].securityContext.readOnlyRootFilesystem}' 2>/dev/null)
    if [ "$rofs" = "true" ]; then
        pass "hardened-security readOnlyRootFilesystem=true in pod spec"
    else
        fail "hardened-security readOnlyRootFilesystem (got: $rofs)"
    fi

    # Verify /tmp is writable (tmpfs mount)
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- sh -c 'touch /tmp/testfile && rm /tmp/testfile' 2>/dev/null; then
        pass "hardened-security /tmp tmpfs writable"
    else
        fail "hardened-security /tmp tmpfs writable"
    fi

    # Verify /data is writable (PVC)
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- sh -c 'touch /data/testfile && rm /data/testfile' 2>/dev/null; then
        pass "hardened-security /data PVC writable"
    else
        fail "hardened-security /data PVC writable"
    fi

    # Verify capabilities dropped (no privilege escalation)
    local sec=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.containers[0].securityContext.allowPrivilegeEscalation}' 2>/dev/null)
    if [ "$sec" = "false" ]; then
        pass "hardened-security allowPrivilegeEscalation=false"
    else
        fail "hardened-security allowPrivilegeEscalation (got: $sec)"
    fi

    local caps=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.containers[0].securityContext.capabilities.drop[0]}' 2>/dev/null)
    if [ "$caps" = "ALL" ]; then
        pass "hardened-security capabilities drop ALL"
    else
        fail "hardened-security capabilities drop (got: $caps)"
    fi

    cleanup "$rel"
}

test_init_containers_deploy() {
    bold "=== TEST: Init containers deployment ==="
    local rel="t-initc"
    cleanup "$rel"

    # Init containers require elevated privileges:
    #   sysctl init: privileged=true
    #   volume-permissions: runAsUser=0 (root)
    # Both may be blocked by PodSecurity policies.
    # Try: both → volumePermissions only → skip entirely.
    local mode="both"
    if ! helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set sysctlInit.enabled=true \
        --set volumePermissions.enabled=true \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1; then
        yellow "    sysctl+volumePermissions failed, retrying volumePermissions only"
        cleanup "$rel"
        mode="volperms"
        if ! helm install "$rel" "$CHART_DIR" \
            --set auth.password=$PASS \
            --set volumePermissions.enabled=true \
            -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1; then
            yellow "    volumePermissions also failed (runAsUser:0 blocked), skipping init containers test"
            cleanup "$rel"
            skip "init-containers (root/privileged not allowed by PodSecurity)"
            return
        fi
    fi
    pass "init-containers install ($mode)"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "init-containers pod ready"
    else
        fail "init-containers pod ready"; cleanup "$rel"; return
    fi

    if [ "$mode" = "both" ]; then
        # Verify both init containers ran
        local init_count=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.status.initContainerStatuses[*].name}' 2>/dev/null | wc -w)
        if [ "$init_count" -ge 2 ]; then
            pass "init-containers both init containers ran ($init_count)"
        else
            fail "init-containers expected 2 init containers (got: $init_count)"
        fi

        # Verify sysctl-init completed
        local sysctl_state=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.status.initContainerStatuses[?(@.name=="sysctl-init")].state.terminated.reason}' 2>/dev/null)
        if [ "$sysctl_state" = "Completed" ]; then
            pass "init-containers sysctl-init completed"
        else
            fail "init-containers sysctl-init state (got: $sysctl_state)"
        fi
    else
        skip "init-containers sysctl-init (privileged not allowed)"
    fi

    if [ "$mode" != "skip" ]; then
        # Verify volume-permissions completed
        local vp_state=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.status.initContainerStatuses[?(@.name=="volume-permissions")].state.terminated.reason}' 2>/dev/null)
        if [ "$vp_state" = "Completed" ]; then
            pass "init-containers volume-permissions completed"
        else
            fail "init-containers volume-permissions state (got: $vp_state)"
        fi

        # Valkey still works
        if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS ping 2>/dev/null | grep -q PONG; then
            pass "init-containers valkey works after init"
        else
            fail "init-containers valkey works after init"
        fi
    fi

    cleanup "$rel"
}

test_metrics_with_auth() {
    bold "=== TEST: Metrics sidecar with auth ==="
    local rel="t-metricsauth"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set metrics.enabled=true \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "metrics-auth install"; cleanup "$rel"; return; }
    pass "metrics-auth install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "metrics-auth pod ready (2/2)"
    else
        fail "metrics-auth pod ready"; cleanup "$rel"; return
    fi

    # Verify REDIS_PASSWORD env is set in metrics container
    local pw_env=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.containers[?(@.name=="metrics")].env[?(@.name=="REDIS_PASSWORD")].valueFrom.secretKeyRef.name}' 2>/dev/null)
    if [ -n "$pw_env" ]; then
        pass "metrics-auth REDIS_PASSWORD env set from secret"
    else
        fail "metrics-auth REDIS_PASSWORD env not found"
    fi

    # Verify redis_up=1 (exporter can auth successfully — query from valkey container)
    local metrics_out=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -c valkey -- \
        sh -c 'exec 3<>/dev/tcp/127.0.0.1/9121; printf "GET /metrics HTTP/1.0\r\nHost: localhost\r\n\r\n" >&3; cat <&3' 2>/dev/null)
    local up=$(echo "$metrics_out" | grep "^redis_up " | awk '{print $2}')
    if [ "$up" = "1" ]; then
        pass "metrics-auth redis_up=1 (exporter authenticated)"
    else
        fail "metrics-auth redis_up (got: $up)"
    fi

    cleanup "$rel"
}

test_probes_deploy() {
    bold "=== TEST: Health probes in deployment ==="
    local rel="t-probes"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set livenessProbe.initialDelaySeconds=10 \
        --set livenessProbe.periodSeconds=5 \
        --set readinessProbe.initialDelaySeconds=5 \
        --set readinessProbe.periodSeconds=5 \
        --set startupProbe.initialDelaySeconds=3 \
        --set startupProbe.periodSeconds=3 \
        --set startupProbe.failureThreshold=20 \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "probes install"; cleanup "$rel"; return; }
    pass "probes install with custom values"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "probes pod ready (all probes passing)"
    else
        fail "probes pod ready"; cleanup "$rel"; return
    fi

    # Verify probes are set on the pod
    local lp=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.containers[0].livenessProbe.initialDelaySeconds}' 2>/dev/null)
    if [ "$lp" = "10" ]; then
        pass "probes livenessProbe.initialDelaySeconds=10"
    else
        fail "probes livenessProbe.initialDelaySeconds (got: $lp)"
    fi

    local rp=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.containers[0].readinessProbe.periodSeconds}' 2>/dev/null)
    if [ "$rp" = "5" ]; then
        pass "probes readinessProbe.periodSeconds=5"
    else
        fail "probes readinessProbe.periodSeconds (got: $rp)"
    fi

    local sp=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.containers[0].startupProbe.failureThreshold}' 2>/dev/null)
    if [ "$sp" = "20" ]; then
        pass "probes startupProbe.failureThreshold=20"
    else
        fail "probes startupProbe.failureThreshold (got: $sp)"
    fi

    cleanup "$rel"
}

test_probes_disabled_deploy() {
    bold "=== TEST: All probes disabled ==="
    local rel="t-noprobes"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set livenessProbe.enabled=false \
        --set readinessProbe.enabled=false \
        --set startupProbe.enabled=false \
        -n $NAMESPACE --timeout $TIMEOUT 2>&1 || { fail "probes-disabled install"; cleanup "$rel"; return; }
    pass "probes-disabled install"

    # Pod will be Running but never Ready (no readiness probe means always ready)
    local deadline=$(( $(date +%s) + 120 ))
    local running=false
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local phase=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$phase" = "Running" ]; then
            running=true
            break
        fi
        sleep 3
    done

    if $running; then
        pass "probes-disabled pod running"
    else
        fail "probes-disabled pod running"; cleanup "$rel"; return
    fi

    # Verify no probes on the container
    local has_lp=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.containers[0].livenessProbe}' 2>/dev/null)
    local has_rp=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.containers[0].readinessProbe}' 2>/dev/null)
    local has_sp=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.containers[0].startupProbe}' 2>/dev/null)
    if [ -z "$has_lp" ] && [ -z "$has_rp" ] && [ -z "$has_sp" ]; then
        pass "probes-disabled no probes on container"
    else
        fail "probes-disabled probes still present"
    fi

    # Valkey still works
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS ping 2>/dev/null | grep -q PONG; then
        pass "probes-disabled valkey-cli ping"
    else
        fail "probes-disabled valkey-cli ping"
    fi

    cleanup "$rel"
}

test_helm_test_hook() {
    bold "=== TEST: Helm test hook execution ==="
    local rel="t-helmtest"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "helm-test install"; cleanup "$rel"; return; }
    pass "helm-test install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "helm-test pod ready"
    else
        fail "helm-test pod ready"; cleanup "$rel"; return
    fi

    # Run helm test and capture output
    local test_out
    test_out=$(helm test "$rel" -n $NAMESPACE 2>&1)
    if echo "$test_out" | grep -qi "succeeded\|passed"; then
        pass "helm-test hook succeeded"
    else
        fail "helm-test hook (output: $test_out)"
    fi

    # Test with auth disabled
    cleanup "$rel"
    helm install "$rel" "$CHART_DIR" \
        --set auth.enabled=false \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "helm-test no-auth install"; cleanup "$rel"; return; }

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "helm-test no-auth pod ready"
    else
        fail "helm-test no-auth pod ready"; cleanup "$rel"; return
    fi

    test_out=$(helm test "$rel" -n $NAMESPACE 2>&1)
    if echo "$test_out" | grep -qi "succeeded\|passed"; then
        pass "helm-test no-auth hook succeeded"
    else
        fail "helm-test no-auth hook (output: $test_out)"
    fi

    cleanup "$rel"
}

test_naming_overrides() {
    bold "=== TEST: Naming overrides (deploy) ==="
    local rel="t-naming"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set fullnameOverride=my-valkey-custom \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "naming-override install"; cleanup "$rel"; return; }
    pass "naming-override install"

    # Verify pod uses the custom name
    if kubectl get pod my-valkey-custom-0 -n $NAMESPACE > /dev/null 2>&1; then
        pass "naming-override pod named my-valkey-custom-0"
    else
        fail "naming-override pod named my-valkey-custom-0"
    fi

    # Verify service uses the custom name
    if kubectl get svc my-valkey-custom -n $NAMESPACE > /dev/null 2>&1; then
        pass "naming-override service named my-valkey-custom"
    else
        fail "naming-override service named my-valkey-custom"
    fi

    if kubectl exec my-valkey-custom-0 -n $NAMESPACE -- valkey-cli -a $PASS ping 2>/dev/null | grep -q PONG; then
        pass "naming-override valkey-cli ping"
    else
        fail "naming-override valkey-cli ping"
    fi

    # Cleanup - need to use fullnameOverride for PVC label matching too
    helm uninstall "$rel" -n $NAMESPACE --wait 2>/dev/null || true
    kubectl delete pvc -l "app.kubernetes.io/instance=$rel" -n $NAMESPACE --wait=false 2>/dev/null || true
    local deadline=$(( $(date +%s) + 60 ))
    while kubectl get pods my-valkey-custom-0 -n $NAMESPACE --no-headers 2>/dev/null | grep -q .; do
        if [ "$(date +%s)" -gt "$deadline" ]; then break; fi
        sleep 2
    done
}

# --- Main ---

main() {
    bold ""
    bold "=============================================="
    bold "  Percona Valkey Helm Chart — Full Test Suite"
    bold "=============================================="
    bold ""

    # Verify prerequisites
    if ! command -v helm > /dev/null 2>&1; then
        red "ERROR: helm not found in PATH"
        exit 1
    fi
    if ! command -v kubectl > /dev/null 2>&1; then
        red "ERROR: kubectl not found in PATH"
        exit 1
    fi
    if ! kubectl cluster-info > /dev/null 2>&1; then
        red "ERROR: kubectl cannot connect to cluster"
        exit 1
    fi
    if [ ! -d "$CHART_DIR" ]; then
        red "ERROR: Chart directory $CHART_DIR not found. Run from valkey-packaging root."
        exit 1
    fi

    green "Prerequisites OK (helm, kubectl, cluster connected)"
    echo ""

    # Phase 1: Static tests (no cluster needed, fast)
    test_lint
    echo ""
    test_template_render
    echo ""

    # Phase 2: Deployment tests (require running cluster)
    bold "--- Deployment tests (require running Kubernetes cluster) ---"
    echo ""

    test_standalone_rpm
    echo ""
    test_standalone_hardened
    echo ""
    test_hardened_security_verify
    echo ""
    test_persistence
    echo ""
    test_persistence_disabled
    echo ""
    test_no_auth
    echo ""
    test_secret_lookup
    echo ""
    test_existing_secret
    echo ""
    test_password_file_mount
    echo ""
    test_resource_preset
    echo ""
    test_custom_config
    echo ""
    test_config_rolling_restart
    echo ""
    test_probes_deploy
    echo ""
    test_probes_disabled_deploy
    echo ""
    test_init_containers_deploy
    echo ""
    test_extra_env_vars
    echo ""
    test_extra_volumes
    echo ""
    test_diagnostic_mode
    echo ""
    test_naming_overrides
    echo ""
    test_helm_test_hook
    echo ""
    test_metrics_sidecar
    echo ""
    test_metrics_with_auth
    echo ""
    test_cluster_rpm
    echo ""
    test_cluster_hardened
    echo ""
    test_cluster_multi_slot
    echo ""
    test_cluster_custom_node_timeout
    echo ""
    test_graceful_failover
    echo ""
    test_cluster_scale_up
    echo ""
    test_cluster_scale_down
    echo ""

    # Summary
    bold "=============================================="
    bold "  TEST SUMMARY"
    bold "=============================================="
    green "  Passed:  $PASSED"
    if [ "$FAILED" -gt 0 ]; then
        red   "  Failed:  $FAILED"
    else
        echo  "  Failed:  0"
    fi
    if [ "$SKIPPED" -gt 0 ]; then
        yellow "  Skipped: $SKIPPED"
    fi
    bold   "  Total:   $TOTAL"
    echo ""

    if [ "$FAILED" -gt 0 ]; then
        red "Failed tests:$FAILURES"
        echo ""
        exit 1
    else
        green "All tests passed!"
        echo ""
        exit 0
    fi
}

main "$@"
