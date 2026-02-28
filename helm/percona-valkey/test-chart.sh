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

    if helm lint "$CHART_DIR" --set acl.enabled=true --set auth.password=$PASS \
        --set 'acl.users.appuser.permissions=~* +@all' --set 'acl.users.appuser.password=apppass' > /dev/null 2>&1; then
        pass "lint standalone/acl"
    else
        fail "lint standalone/acl"
    fi

    if helm lint "$CHART_DIR" --set mode=cluster --set acl.enabled=true --set auth.password=$PASS \
        --set 'acl.users.appuser.permissions=~* +@all' --set 'acl.users.appuser.password=apppass' > /dev/null 2>&1; then
        pass "lint cluster/acl"
    else
        fail "lint cluster/acl"
    fi

    if helm lint "$CHART_DIR" --set env.TZ=UTC > /dev/null 2>&1; then
        pass "lint env map"
    else
        fail "lint env map"
    fi

    if helm lint "$CHART_DIR" --set auth.passwordRotation.enabled=true --set auth.password=$PASS > /dev/null 2>&1; then
        pass "lint password rotation"
    else
        fail "lint password rotation"
    fi

    if helm lint "$CHART_DIR" --set mode=cluster --set cluster.precheckBeforeScaleDown=true > /dev/null 2>&1; then
        pass "lint cluster precheck"
    else
        fail "lint cluster precheck"
    fi

    if helm lint "$CHART_DIR" --set backup.enabled=true > /dev/null 2>&1; then
        pass "lint backup enabled"
    else
        fail "lint backup enabled"
    fi

    if helm lint "$CHART_DIR" --set mode=sentinel > /dev/null 2>&1; then
        pass "lint sentinel/rpm"
    else
        fail "lint sentinel/rpm"
    fi

    if helm lint "$CHART_DIR" --set mode=sentinel,image.variant=hardened > /dev/null 2>&1; then
        pass "lint sentinel/hardened"
    else
        fail "lint sentinel/hardened"
    fi

    if helm lint "$CHART_DIR" --set global.imageRegistry=myregistry.io > /dev/null 2>&1; then
        pass "lint global.imageRegistry"
    else
        fail "lint global.imageRegistry"
    fi

    if helm lint "$CHART_DIR" --set commonLabels.team=platform > /dev/null 2>&1; then
        pass "lint commonLabels"
    else
        fail "lint commonLabels"
    fi

    if helm lint "$CHART_DIR" --set clusterDomain=custom.domain > /dev/null 2>&1; then
        pass "lint clusterDomain"
    else
        fail "lint clusterDomain"
    fi

    if helm lint "$CHART_DIR" --set config.logLevel=verbose --set config.disklessSync=true > /dev/null 2>&1; then
        pass "lint logLevel + disklessSync"
    else
        fail "lint logLevel + disklessSync"
    fi

    if helm lint "$CHART_DIR" --set standalone.useDeployment=true --set persistence.enabled=false > /dev/null 2>&1; then
        pass "lint deployment mode"
    else
        fail "lint deployment mode"
    fi

    if helm lint "$CHART_DIR" --set initResources.requests.cpu=50m --set initResources.requests.memory=64Mi \
        --set initResources.limits.cpu=100m --set initResources.limits.memory=128Mi > /dev/null 2>&1; then
        pass "lint initResources"
    else
        fail "lint initResources"
    fi

    # F4: hostPath
    if helm lint "$CHART_DIR" --set persistence.enabled=false --set persistence.hostPath=/mnt/data > /dev/null 2>&1; then
        pass "lint hostPath"
    else
        fail "lint hostPath"
    fi

    # F5: keepOnUninstall
    if helm lint "$CHART_DIR" --set persistence.keepOnUninstall=true > /dev/null 2>&1; then
        pass "lint keepOnUninstall"
    else
        fail "lint keepOnUninstall"
    fi

    # F6: subPath
    if helm lint "$CHART_DIR" --set persistence.subPath=mydata > /dev/null 2>&1; then
        pass "lint subPath"
    else
        fail "lint subPath"
    fi

    # F7: extraValkeySecrets
    if helm lint "$CHART_DIR" --set 'extraValkeySecrets[0].name=s' --set 'extraValkeySecrets[0].mountPath=/m' > /dev/null 2>&1; then
        pass "lint extraValkeySecrets"
    else
        fail "lint extraValkeySecrets"
    fi

    # F8: replicationUser
    if helm lint "$CHART_DIR" --set acl.enabled=true --set auth.password=$PASS \
        --set acl.replicationUser=repluser \
        --set 'acl.users.repluser.password=replpass' --set 'acl.users.repluser.permissions=+replconf +psync +ping' > /dev/null 2>&1; then
        pass "lint replicationUser"
    else
        fail "lint replicationUser"
    fi

    # F9: service fields
    if helm lint "$CHART_DIR" --set service.clusterIP=10.0.0.100 --set service.appProtocol=redis > /dev/null 2>&1; then
        pass "lint service clusterIP/appProtocol"
    else
        fail "lint service clusterIP/appProtocol"
    fi

    # F10: metrics command
    if helm lint "$CHART_DIR" --set metrics.enabled=true --set 'metrics.command[0]=/bin/exporter' > /dev/null 2>&1; then
        pass "lint metrics command"
    else
        fail "lint metrics command"
    fi

    # F11: serviceMonitor relabelings
    if helm lint "$CHART_DIR" --set metrics.enabled=true --set metrics.serviceMonitor.enabled=true \
        --set 'metrics.serviceMonitor.relabelings[0].sourceLabels[0]=__name__' > /dev/null 2>&1; then
        pass "lint F11 serviceMonitor relabelings"
    else
        fail "lint F11 serviceMonitor relabelings"
    fi

    # F12: serviceMonitor sampleLimit
    if helm lint "$CHART_DIR" --set metrics.enabled=true --set metrics.serviceMonitor.enabled=true \
        --set metrics.serviceMonitor.sampleLimit=5000 > /dev/null 2>&1; then
        pass "lint F12 serviceMonitor sampleLimit"
    else
        fail "lint F12 serviceMonitor sampleLimit"
    fi

    # F13: serviceMonitor honorLabels
    if helm lint "$CHART_DIR" --set metrics.enabled=true --set metrics.serviceMonitor.enabled=true \
        --set metrics.serviceMonitor.honorLabels=true > /dev/null 2>&1; then
        pass "lint F13 serviceMonitor honorLabels"
    else
        fail "lint F13 serviceMonitor honorLabels"
    fi

    # F14: metrics extraEnvs
    if helm lint "$CHART_DIR" --set metrics.enabled=true \
        --set 'metrics.extraEnvs[0].name=FOO' --set 'metrics.extraEnvs[0].value=bar' > /dev/null 2>&1; then
        pass "lint F14 metrics extraEnvs"
    else
        fail "lint F14 metrics extraEnvs"
    fi

    # F15: metrics securityContext
    if helm lint "$CHART_DIR" --set metrics.enabled=true \
        --set metrics.securityContext.runAsNonRoot=true > /dev/null 2>&1; then
        pass "lint F15 metrics securityContext"
    else
        fail "lint F15 metrics securityContext"
    fi

    # F16: readOnlyRootFilesystem default (emptyDir mounts added)
    if helm lint "$CHART_DIR" > /dev/null 2>&1; then
        pass "lint F16 readOnlyRootFilesystem default"
    else
        fail "lint F16 readOnlyRootFilesystem default"
    fi

    # F18: configurable TLS key names
    if helm lint "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=x \
        --set tls.certKey=cert.pem > /dev/null 2>&1; then
        pass "lint F18 configurable TLS key names"
    else
        fail "lint F18 configurable TLS key names"
    fi

    # F19: default user in acl.users must fail
    if (helm template test "$CHART_DIR" --set acl.enabled=true --set auth.password=p \
        --set 'acl.users.default.permissions=~* +@all' --set 'acl.users.default.password=p' 2>&1 || true) | grep -q "default user is auto-managed"; then
        pass "lint F19 default user protection"
    else
        fail "lint F19 default user protection"
    fi

    # F20: missing permissions must fail
    if (helm template test "$CHART_DIR" --set acl.enabled=true --set auth.password=p \
        --set 'acl.users.x.password=p' 2>&1 || true) | grep -q "permissions field is required"; then
        pass "lint F20 permissions required"
    else
        fail "lint F20 permissions required"
    fi

    # F21: per-mode persistence override
    if helm lint "$CHART_DIR" --set mode=cluster --set cluster.persistence.size=20Gi > /dev/null 2>&1; then
        pass "lint F21 cluster persistence override"
    else
        fail "lint F21 cluster persistence override"
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

    # --- TLS/SSL ---

    # TLS disabled by default (no tls-port in configmap)
    out=$(helm template test "$CHART_DIR" --show-only templates/configmap.yaml 2>&1)
    if ! echo "$out" | grep -q "tls-port"; then
        pass "template TLS disabled by default"
    else
        fail "template TLS disabled by default"
    fi

    # TLS enabled adds tls-port to configmap
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "tls-port 6380" && echo "$out" | grep -q "tls-cert-file" && echo "$out" | grep -q "tls-ca-cert-file"; then
        pass "template TLS configmap directives"
    else
        fail "template TLS configmap directives"
    fi

    # TLS custom port
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --set tls.port=6443 --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "tls-port 6443"; then
        pass "template TLS custom port"
    else
        fail "template TLS custom port"
    fi

    # TLS disablePlaintext sets port 0 in configmap
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --set tls.disablePlaintext=true --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "port 0"; then
        pass "template TLS disablePlaintext"
    else
        fail "template TLS disablePlaintext"
    fi

    # TLS replication directive
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --set tls.replication=true --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "tls-replication yes"; then
        pass "template TLS replication"
    else
        fail "template TLS replication"
    fi

    # TLS auth-clients directive
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --set tls.authClients=optional --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "tls-auth-clients optional"; then
        pass "template TLS authClients"
    else
        fail "template TLS authClients"
    fi

    # TLS ciphers
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --set tls.ciphers=HIGH --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "tls-ciphers HIGH"; then
        pass "template TLS ciphers"
    else
        fail "template TLS ciphers"
    fi

    # TLS ciphersuites
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --set tls.ciphersuites=TLS_AES_256_GCM_SHA384 --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "tls-ciphersuites TLS_AES_256_GCM_SHA384"; then
        pass "template TLS ciphersuites"
    else
        fail "template TLS ciphersuites"
    fi

    # TLS cluster mode adds tls-cluster yes
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --set mode=cluster --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "tls-cluster yes"; then
        pass "template TLS cluster mode adds tls-cluster"
    else
        fail "template TLS cluster mode adds tls-cluster"
    fi

    # TLS standalone does NOT add tls-cluster
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --show-only templates/configmap.yaml 2>&1)
    if ! echo "$out" | grep -q "tls-cluster"; then
        pass "template TLS standalone no tls-cluster"
    else
        fail "template TLS standalone no tls-cluster"
    fi

    # TLS adds port to statefulset
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "valkey-tls" && echo "$out" | grep -q "containerPort: 6380"; then
        pass "template TLS statefulset port"
    else
        fail "template TLS statefulset port"
    fi

    # TLS adds cert volume mount to statefulset
    if echo "$out" | grep -q "tls-certs" && echo "$out" | grep -q "/etc/valkey/tls"; then
        pass "template TLS statefulset cert volume mount"
    else
        fail "template TLS statefulset cert volume mount"
    fi

    # TLS cert volume references correct secret
    if echo "$out" | grep -q "secretName: my-tls"; then
        pass "template TLS existingSecret used in volume"
    else
        fail "template TLS existingSecret used in volume"
    fi

    # TLS adds port to service
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --show-only templates/service.yaml 2>&1)
    if echo "$out" | grep -q "valkey-tls" && echo "$out" | grep -q "port: 6380"; then
        pass "template TLS service port"
    else
        fail "template TLS service port"
    fi

    # TLS adds port to headless service
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --show-only templates/service-headless.yaml 2>&1)
    if echo "$out" | grep -q "valkey-tls" && echo "$out" | grep -q "port: 6380"; then
        pass "template TLS headless service port"
    else
        fail "template TLS headless service port"
    fi

    # TLS probes use plaintext when disablePlaintext=false
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "\-\-tls"; then
        pass "template TLS probes use plaintext by default"
    else
        fail "template TLS probes use plaintext by default"
    fi

    # TLS probes use TLS when disablePlaintext=true
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --set tls.disablePlaintext=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "\-\-tls" && echo "$out" | grep -q "\-\-cacert"; then
        pass "template TLS probes with disablePlaintext"
    else
        fail "template TLS probes with disablePlaintext"
    fi

    # TLS metrics sidecar uses rediss:// protocol
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --set metrics.enabled=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "rediss://localhost:6380" && echo "$out" | grep -q "REDIS_EXPORTER_TLS_CA_CERT_FILE"; then
        pass "template TLS metrics sidecar config"
    else
        fail "template TLS metrics sidecar config"
    fi

    # TLS metrics sidecar gets cert volume mount
    if echo "$out" | grep -A2 "name: metrics" | grep -q "" && echo "$out" | grep -B1 -A5 "REDIS_EXPORTER" | grep -q "ca.crt"; then
        pass "template TLS metrics sidecar cert volume"
    else
        fail "template TLS metrics sidecar cert volume"
    fi

    # TLS cluster-init-job has TLS flags
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --set mode=cluster --show-only templates/cluster-init-job.yaml 2>&1)
    if echo "$out" | grep -q 'TLS_FLAG="--tls' && echo "$out" | grep -q '$TLS_FLAG'; then
        pass "template TLS cluster-init-job flags"
    else
        fail "template TLS cluster-init-job flags"
    fi

    # TLS cluster-init-job mounts certs
    if echo "$out" | grep -q "tls-certs" && echo "$out" | grep -q "secretName: my-tls"; then
        pass "template TLS cluster-init-job cert mount"
    else
        fail "template TLS cluster-init-job cert mount"
    fi

    # TLS cluster-scale-job has TLS flags
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --set mode=cluster --show-only templates/cluster-scale-job.yaml 2>&1)
    if echo "$out" | grep -q 'TLS="--tls' && echo "$out" | grep -q '$TLS'; then
        pass "template TLS cluster-scale-job flags"
    else
        fail "template TLS cluster-scale-job flags"
    fi

    # TLS test-connection uses TLS flags and cert volume
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --show-only templates/tests/test-connection.yaml 2>&1)
    if echo "$out" | grep -q "\-\-tls" && echo "$out" | grep -q "tls-certs" && echo "$out" | grep -q "6380"; then
        pass "template TLS test-connection"
    else
        fail "template TLS test-connection"
    fi

    # TLS test-connection without TLS has no TLS flags
    out=$(helm template test "$CHART_DIR" --show-only templates/tests/test-connection.yaml 2>&1)
    if ! echo "$out" | grep -q "\-\-tls" && ! echo "$out" | grep -q "tls-certs"; then
        pass "template test-connection no TLS by default"
    else
        fail "template test-connection no TLS by default"
    fi

    # cert-manager Certificate template
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.certManager.enabled=true --set tls.certManager.issuerRef.name=my-issuer --show-only templates/certificate.yaml 2>&1)
    if echo "$out" | grep -q "kind: Certificate" && echo "$out" | grep -q "issuerRef" && echo "$out" | grep -q "my-issuer"; then
        pass "template cert-manager Certificate"
    else
        fail "template cert-manager Certificate"
    fi

    # cert-manager Certificate includes wildcard DNS
    if echo "$out" | grep -q '\*\..*-headless'; then
        pass "template cert-manager Certificate wildcard DNS"
    else
        fail "template cert-manager Certificate wildcard DNS"
    fi

    # cert-manager Certificate not rendered when certManager disabled
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls 2>&1)
    if ! echo "$out" | grep -q "kind: Certificate"; then
        pass "template no Certificate when certManager disabled"
    else
        fail "template no Certificate when certManager disabled"
    fi

    # TLS NOTES.txt shows TLS info (read raw template — NOTES.txt is not accessible via --show-only)
    local notes_raw=$(cat "$CHART_DIR/templates/NOTES.txt")
    if echo "$notes_raw" | grep -q "TLS is enabled" && echo "$notes_raw" | grep -q "tls.port"; then
        pass "template NOTES.txt TLS info"
    else
        fail "template NOTES.txt TLS info"
    fi

    # TLS NOTES.txt with disablePlaintext reference
    if echo "$notes_raw" | grep -q "plain-text port is disabled"; then
        pass "template NOTES.txt TLS disablePlaintext"
    else
        fail "template NOTES.txt TLS disablePlaintext"
    fi

    # TLS graceful failover includes TLS flags when plaintext disabled
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --set tls.disablePlaintext=true --set mode=cluster --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'TLS="-p.*--tls'; then
        pass "template TLS graceful failover uses TLS flags"
    else
        fail "template TLS graceful failover uses TLS flags"
    fi

    # TLS disabled in default still has no TLS in statefulset/services
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    ss_clean=$(! echo "$out" | grep -q "tls-certs" && echo "true" || echo "false")
    out=$(helm template test "$CHART_DIR" --show-only templates/service.yaml 2>&1)
    svc_clean=$(! echo "$out" | grep -q "valkey-tls" && echo "true" || echo "false")
    if [ "$ss_clean" = "true" ] && [ "$svc_clean" = "true" ]; then
        pass "template no TLS artifacts when disabled"
    else
        fail "template no TLS artifacts when disabled"
    fi

    # TLS custom certMountPath
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.existingSecret=my-tls --set tls.certMountPath=/custom/certs --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "/custom/certs"; then
        pass "template TLS custom certMountPath"
    else
        fail "template TLS custom certMountPath"
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

    # --- External Access Tests ---

    # externalAccess disabled by default: service is ClusterIP, no per-pod services
    out=$(helm template test "$CHART_DIR" --show-only templates/service.yaml 2>&1)
    if echo "$out" | grep -q "type: ClusterIP" && ! echo "$out" | grep -q "LoadBalancer"; then
        pass "template externalAccess disabled by default (ClusterIP)"
    else
        fail "template externalAccess disabled by default (ClusterIP)"
    fi

    # No per-pod services when disabled
    if ! helm template test "$CHART_DIR" --show-only templates/service-per-pod.yaml 2>&1 | grep -q "kind: Service"; then
        pass "template no per-pod services when externalAccess disabled"
    else
        fail "template no per-pod services when externalAccess disabled"
    fi

    # Standalone + externalAccess LoadBalancer
    out=$(helm template test "$CHART_DIR" --set externalAccess.enabled=true --show-only templates/service.yaml 2>&1)
    if echo "$out" | grep -q "type: LoadBalancer" && echo "$out" | grep -q "externalTrafficPolicy: Cluster"; then
        pass "template standalone externalAccess LoadBalancer"
    else
        fail "template standalone externalAccess LoadBalancer"
    fi

    # Standalone + externalAccess NodePort with explicit nodePort
    out=$(helm template test "$CHART_DIR" --set externalAccess.enabled=true --set externalAccess.service.type=NodePort --set externalAccess.standalone.nodePort=30379 --show-only templates/service.yaml 2>&1)
    if echo "$out" | grep -q "type: NodePort" && echo "$out" | grep -q "nodePort: 30379"; then
        pass "template standalone externalAccess NodePort"
    else
        fail "template standalone externalAccess NodePort"
    fi

    # Cluster + externalAccess: per-pod services count matches replicas
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set externalAccess.enabled=true --show-only templates/service-per-pod.yaml 2>&1)
    local svc_count
    svc_count=$(echo "$out" | grep -c "kind: Service" || true)
    if [ "$svc_count" -eq 6 ]; then
        pass "template cluster per-pod services count (6)"
    else
        fail "template cluster per-pod services count (expected 6, got $svc_count)"
    fi

    # Per-pod services include statefulset.kubernetes.io/pod-name selector
    if echo "$out" | grep -q "statefulset.kubernetes.io/pod-name"; then
        pass "template per-pod services have pod-name selector"
    else
        fail "template per-pod services have pod-name selector"
    fi

    # Cluster + externalAccess: RBAC Role for LoadBalancer
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set externalAccess.enabled=true --show-only templates/role.yaml 2>&1)
    if echo "$out" | grep -q "kind: Role" && ! echo "$out" | grep -q "kind: ClusterRole"; then
        pass "template RBAC Role for LoadBalancer"
    else
        fail "template RBAC Role for LoadBalancer"
    fi

    # Cluster + externalAccess NodePort: ClusterRole
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set externalAccess.enabled=true --set externalAccess.service.type=NodePort --show-only templates/role.yaml 2>&1)
    if echo "$out" | grep -q "kind: ClusterRole"; then
        pass "template RBAC ClusterRole for NodePort"
    else
        fail "template RBAC ClusterRole for NodePort"
    fi

    # ClusterRole includes nodes resource
    if echo "$out" | grep -q '"nodes"'; then
        pass "template ClusterRole includes nodes resource"
    else
        fail "template ClusterRole includes nodes resource"
    fi

    # Cluster + externalAccess: init container present
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set externalAccess.enabled=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "discover-external-ip"; then
        pass "template init container discover-external-ip present"
    else
        fail "template init container discover-external-ip present"
    fi

    # Cluster + externalAccess: cluster-announce flags in command
    if echo "$out" | grep -q "cluster-announce-ip" && echo "$out" | grep -q "cluster-announce-port" && echo "$out" | grep -q "cluster-announce-bus-port"; then
        pass "template cluster-announce flags in command"
    else
        fail "template cluster-announce flags in command"
    fi

    # Cluster + externalAccess: automountServiceAccountToken is true
    if echo "$out" | grep -q "automountServiceAccountToken: true"; then
        pass "template automountServiceAccountToken: true for externalAccess"
    else
        fail "template automountServiceAccountToken: true for externalAccess"
    fi

    # Cluster + externalAccess: external-config volume exists
    if echo "$out" | grep -q "external-config"; then
        pass "template external-config volume present"
    else
        fail "template external-config volume present"
    fi

    # TLS ports in per-pod services
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set externalAccess.enabled=true --set tls.enabled=true --set tls.existingSecret=mysecret --show-only templates/service-per-pod.yaml 2>&1)
    if echo "$out" | grep -q "valkey-tls" && echo "$out" | grep -q "6380"; then
        pass "template TLS port in per-pod services"
    else
        fail "template TLS port in per-pod services"
    fi

    # NetworkPolicy includes TLS port
    out=$(helm template test "$CHART_DIR" --set networkPolicy.enabled=true --set tls.enabled=true --set tls.existingSecret=mysecret --show-only templates/networkpolicy.yaml 2>&1)
    if echo "$out" | grep -q "6380"; then
        pass "template NetworkPolicy includes TLS port"
    else
        fail "template NetworkPolicy includes TLS port"
    fi

    # No RBAC when externalAccess disabled
    if ! helm template test "$CHART_DIR" --set mode=cluster --show-only templates/role.yaml 2>&1 | grep -q "kind:"; then
        pass "template no RBAC when externalAccess disabled"
    else
        fail "template no RBAC when externalAccess disabled"
    fi

    # --- Pod anti-affinity preset tests ---

    # Soft anti-affinity preset
    out=$(helm template test "$CHART_DIR" --set podAntiAffinityPreset.type=soft --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "preferredDuringSchedulingIgnoredDuringExecution"; then
        pass "template soft anti-affinity preset"
    else
        fail "template soft anti-affinity preset"
    fi

    # Hard anti-affinity preset
    out=$(helm template test "$CHART_DIR" --set podAntiAffinityPreset.type=hard --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "requiredDuringSchedulingIgnoredDuringExecution"; then
        pass "template hard anti-affinity preset"
    else
        fail "template hard anti-affinity preset"
    fi

    # Anti-affinity preset ignored when affinity is set explicitly
    out=$(helm template test "$CHART_DIR" --set podAntiAffinityPreset.type=hard --set 'affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=zone' --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "nodeAffinity" && ! echo "$out" | grep -q "podAntiAffinity"; then
        pass "template anti-affinity preset ignored with explicit affinity"
    else
        fail "template anti-affinity preset ignored with explicit affinity"
    fi

    # Custom topologyKey for anti-affinity
    out=$(helm template test "$CHART_DIR" --set podAntiAffinityPreset.type=soft --set podAntiAffinityPreset.topologyKey=topology.kubernetes.io/zone --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "topology.kubernetes.io/zone"; then
        pass "template anti-affinity custom topologyKey"
    else
        fail "template anti-affinity custom topologyKey"
    fi

    # No anti-affinity when preset type is empty (default)
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "podAntiAffinity"; then
        pass "template no anti-affinity by default"
    else
        fail "template no anti-affinity by default"
    fi

    # --- Topology spread constraints ---
    out=$(helm template test "$CHART_DIR" \
        --set 'topologySpreadConstraints[0].maxSkew=1' \
        --set 'topologySpreadConstraints[0].topologyKey=kubernetes.io/hostname' \
        --set 'topologySpreadConstraints[0].whenUnsatisfiable=DoNotSchedule' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "topologySpreadConstraints" && echo "$out" | grep -q "maxSkew"; then
        pass "template topologySpreadConstraints"
    else
        fail "template topologySpreadConstraints"
    fi

    # No topologySpreadConstraints by default
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "topologySpreadConstraints"; then
        pass "template no topologySpreadConstraints by default"
    else
        fail "template no topologySpreadConstraints by default"
    fi

    # --- Priority class ---
    out=$(helm template test "$CHART_DIR" --set priorityClassName=high-priority --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "priorityClassName: high-priority"; then
        pass "template priorityClassName"
    else
        fail "template priorityClassName"
    fi

    # No priorityClassName by default
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "priorityClassName"; then
        pass "template no priorityClassName by default"
    else
        fail "template no priorityClassName by default"
    fi

    # --- Termination grace period ---
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "terminationGracePeriodSeconds: 30"; then
        pass "template terminationGracePeriodSeconds default 30"
    else
        fail "template terminationGracePeriodSeconds default 30"
    fi

    out=$(helm template test "$CHART_DIR" --set terminationGracePeriodSeconds=120 --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "terminationGracePeriodSeconds: 120"; then
        pass "template terminationGracePeriodSeconds custom"
    else
        fail "template terminationGracePeriodSeconds custom"
    fi

    # --- Extra init containers ---
    out=$(helm template test "$CHART_DIR" \
        --set 'extraInitContainers[0].name=my-init' \
        --set 'extraInitContainers[0].image=busybox' \
        --set 'extraInitContainers[0].command[0]=echo' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "name: my-init" && echo "$out" | grep -q "image: busybox"; then
        pass "template extraInitContainers"
    else
        fail "template extraInitContainers"
    fi

    # --- Extra sidecar containers ---
    out=$(helm template test "$CHART_DIR" \
        --set 'extraContainers[0].name=my-sidecar' \
        --set 'extraContainers[0].image=busybox' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "name: my-sidecar" && echo "$out" | grep -q "image: busybox"; then
        pass "template extraContainers"
    else
        fail "template extraContainers"
    fi

    # --- HPA tests ---

    # HPA disabled by default
    if ! helm template test "$CHART_DIR" --show-only templates/hpa.yaml 2>&1 | grep -q "kind:"; then
        pass "template HPA disabled by default"
    else
        fail "template HPA disabled by default"
    fi

    # HPA enabled in standalone mode
    out=$(helm template test "$CHART_DIR" --set autoscaling.hpa.enabled=true --show-only templates/hpa.yaml 2>&1)
    if echo "$out" | grep -q "HorizontalPodAutoscaler" && echo "$out" | grep -q "maxReplicas"; then
        pass "template HPA enabled standalone"
    else
        fail "template HPA enabled standalone"
    fi

    # HPA not rendered in cluster mode
    if ! helm template test "$CHART_DIR" --set mode=cluster --set autoscaling.hpa.enabled=true --show-only templates/hpa.yaml 2>&1 | grep -q "kind:"; then
        pass "template HPA not rendered in cluster mode"
    else
        fail "template HPA not rendered in cluster mode"
    fi

    # --- VPA tests ---

    # VPA disabled by default
    if ! helm template test "$CHART_DIR" --show-only templates/vpa.yaml 2>&1 | grep -q "kind:"; then
        pass "template VPA disabled by default"
    else
        fail "template VPA disabled by default"
    fi

    # VPA enabled
    out=$(helm template test "$CHART_DIR" --set autoscaling.vpa.enabled=true --show-only templates/vpa.yaml 2>&1)
    if echo "$out" | grep -q "VerticalPodAutoscaler" && echo "$out" | grep -q "updateMode"; then
        pass "template VPA enabled"
    else
        fail "template VPA enabled"
    fi

    # --- Read service tests ---

    # No read service for standalone with 1 replica (default)
    if ! helm template test "$CHART_DIR" --show-only templates/service-read.yaml 2>&1 | grep -q "kind:"; then
        pass "template no read service with 1 replica"
    else
        fail "template no read service with 1 replica"
    fi

    # Read service created when standalone.replicas > 1
    out=$(helm template test "$CHART_DIR" --set standalone.replicas=3 --show-only templates/service-read.yaml 2>&1)
    if echo "$out" | grep -q "kind: Service" && echo "$out" | grep -q "\-read"; then
        pass "template read service with multiple replicas"
    else
        fail "template read service with multiple replicas"
    fi

    # No read service in cluster mode
    if ! helm template test "$CHART_DIR" --set mode=cluster --show-only templates/service-read.yaml 2>&1 | grep -q "kind:"; then
        pass "template no read service in cluster mode"
    else
        fail "template no read service in cluster mode"
    fi

    # --- Runtime class ---
    out=$(helm template test "$CHART_DIR" --set runtimeClassName=gvisor --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "runtimeClassName: gvisor"; then
        pass "template runtimeClassName"
    else
        fail "template runtimeClassName"
    fi

    # No runtimeClassName by default
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "runtimeClassName"; then
        pass "template no runtimeClassName by default"
    else
        fail "template no runtimeClassName by default"
    fi

    # --- DNS config/policy ---
    out=$(helm template test "$CHART_DIR" --set dnsPolicy=None \
        --set 'dnsConfig.nameservers[0]=8.8.8.8' \
        --set 'dnsConfig.options[0].name=ndots' \
        --set-string 'dnsConfig.options[0].value=5' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "dnsPolicy: None" && echo "$out" | grep -q "8.8.8.8" && echo "$out" | grep -q "ndots"; then
        pass "template dnsPolicy and dnsConfig"
    else
        fail "template dnsPolicy and dnsConfig"
    fi

    # No dnsPolicy/dnsConfig by default
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "dnsPolicy" && ! echo "$out" | grep -q "dnsConfig"; then
        pass "template no dnsPolicy/dnsConfig by default"
    else
        fail "template no dnsPolicy/dnsConfig by default"
    fi

    # --- ACL tests ---

    # ACL disabled: no aclfile in configmap
    out=$(helm template test "$CHART_DIR" --show-only templates/configmap.yaml 2>&1)
    if ! echo "$out" | grep -q "aclfile"; then
        pass "template ACL disabled: no aclfile in configmap"
    else
        fail "template ACL disabled: no aclfile in configmap"
    fi

    # ACL enabled: aclfile present in configmap
    out=$(helm template test "$CHART_DIR" --set acl.enabled=true --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "aclfile /etc/valkey/acl/users.acl"; then
        pass "template ACL enabled: aclfile present"
    else
        fail "template ACL enabled: aclfile present"
    fi

    # ACL inline user: users.acl key in Secret
    out=$(helm template test "$CHART_DIR" --set acl.enabled=true \
        --set 'acl.users.appuser.permissions=~* +@all' \
        --set 'acl.users.appuser.password=apppass' \
        --show-only templates/secret.yaml 2>&1)
    if echo "$out" | grep -q "users.acl"; then
        pass "template ACL inline user: users.acl in Secret"
    else
        fail "template ACL inline user: users.acl in Secret"
    fi

    # ACL inline user: direct secret mount, NO init container
    out=$(helm template test "$CHART_DIR" --set acl.enabled=true \
        --set 'acl.users.appuser.permissions=~* +@all' \
        --set 'acl.users.appuser.password=apppass' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "acl-config" && ! echo "$out" | grep -q "acl-init"; then
        pass "template ACL inline user: direct mount, no init container"
    else
        fail "template ACL inline user: direct mount, no init container"
    fi

    # ACL existingPasswordSecret: acl-init container present
    out=$(helm template test "$CHART_DIR" --set acl.enabled=true \
        --set 'acl.users.monitor.permissions=+info +ping' \
        --set 'acl.users.monitor.existingPasswordSecret=mon-creds' \
        --set 'acl.users.monitor.passwordKey=password' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "acl-init"; then
        pass "template ACL existingPasswordSecret: acl-init container present"
    else
        fail "template ACL existingPasswordSecret: acl-init container present"
    fi

    # ACL existingPasswordSecret: acl-assembled + acl-base volumes
    if echo "$out" | grep -q "acl-assembled" && echo "$out" | grep -q "acl-base"; then
        pass "template ACL existingPasswordSecret: acl-assembled + acl-base volumes"
    else
        fail "template ACL existingPasswordSecret: acl-assembled + acl-base volumes"
    fi

    # ACL existingPasswordSecret: external secret volume mounted
    if echo "$out" | grep -q "acl-secret-monitor"; then
        pass "template ACL existingPasswordSecret: external secret volume"
    else
        fail "template ACL existingPasswordSecret: external secret volume"
    fi

    # ACL existingSecret: uses external name, ignores users
    out=$(helm template test "$CHART_DIR" --set acl.enabled=true \
        --set acl.existingSecret=my-acl-secret \
        --set 'acl.users.appuser.permissions=~* +@all' \
        --set 'acl.users.appuser.password=x' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "my-acl-secret" && ! echo "$out" | grep -q "acl-init"; then
        pass "template ACL existingSecret: uses external name"
    else
        fail "template ACL existingSecret: uses external name"
    fi

    # ACL disabled: no acl resources
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "acl-config" && ! echo "$out" | grep -q "acl-init"; then
        pass "template ACL disabled: no acl resources"
    else
        fail "template ACL disabled: no acl resources"
    fi

    # ACL + cluster lint
    if helm lint "$CHART_DIR" --set mode=cluster --set acl.enabled=true \
        --set 'acl.users.app.permissions=~* +@all' --set 'acl.users.app.password=x' > /dev/null 2>&1; then
        pass "template ACL + cluster lint"
    else
        fail "template ACL + cluster lint"
    fi

    # ACL + external access: masterauth without requirepass
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set externalAccess.enabled=true --set acl.enabled=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "\-\-masterauth" && ! echo "$out" | grep -q "\-\-requirepass"; then
        pass "template ACL + external access: masterauth without requirepass"
    else
        fail "template ACL + external access: masterauth without requirepass"
    fi

    # Validation: missing passwordKey → error
    out=$(helm template test "$CHART_DIR" --set acl.enabled=true \
        --set 'acl.users.bad.existingPasswordSecret=some-secret' \
        --set 'acl.users.bad.permissions=+ping' 2>&1 || true)
    if echo "$out" | grep -q "existingPasswordSecret requires passwordKey"; then
        pass "validation: ACL missing passwordKey fails"
    else
        fail "validation: ACL missing passwordKey fails"
    fi

    # Validation: both password + existingPasswordSecret → error
    out=$(helm template test "$CHART_DIR" --set acl.enabled=true \
        --set 'acl.users.dup.password=x' \
        --set 'acl.users.dup.existingPasswordSecret=y' \
        --set 'acl.users.dup.passwordKey=pw' \
        --set 'acl.users.dup.permissions=+ping' 2>&1 || true)
    if echo "$out" | grep -q "cannot set both password and existingPasswordSecret"; then
        pass "validation: ACL both password + existingPasswordSecret fails"
    else
        fail "validation: ACL both password + existingPasswordSecret fails"
    fi

    # --- Feature #16: Scale-down precheck ---

    # Precheck renders only in cluster mode
    out=$(helm template test "$CHART_DIR" --set mode=cluster --show-only templates/cluster-precheck-job.yaml 2>&1)
    if echo "$out" | grep -q "cluster-precheck"; then
        pass "template precheck job present in cluster mode"
    else
        fail "template precheck job present in cluster mode"
    fi

    # Precheck not rendered in standalone
    if helm template test "$CHART_DIR" --set mode=standalone --show-only templates/cluster-precheck-job.yaml > /dev/null 2>&1; then
        out=$(helm template test "$CHART_DIR" --set mode=standalone --show-only templates/cluster-precheck-job.yaml 2>&1)
        if echo "$out" | grep -q "cluster-precheck"; then
            fail "template precheck job absent in standalone mode"
        else
            pass "template precheck job absent in standalone mode"
        fi
    else
        pass "template precheck job absent in standalone mode"
    fi

    # Precheck disabled when precheckBeforeScaleDown=false
    if helm template test "$CHART_DIR" --set mode=cluster --set cluster.precheckBeforeScaleDown=false --show-only templates/cluster-precheck-job.yaml > /dev/null 2>&1; then
        out=$(helm template test "$CHART_DIR" --set mode=cluster --set cluster.precheckBeforeScaleDown=false --show-only templates/cluster-precheck-job.yaml 2>&1)
        if echo "$out" | grep -q "cluster-precheck"; then
            fail "template precheck job absent when disabled"
        else
            pass "template precheck job absent when disabled"
        fi
    else
        pass "template precheck job absent when disabled"
    fi

    # Precheck is a pre-upgrade hook
    out=$(helm template test "$CHART_DIR" --set mode=cluster --show-only templates/cluster-precheck-job.yaml 2>&1)
    if echo "$out" | grep -q "pre-upgrade"; then
        pass "template precheck job is pre-upgrade hook"
    else
        fail "template precheck job is pre-upgrade hook"
    fi

    # --- Feature #17: Password rotation ---

    # Sidecar not present by default
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "password-watcher"; then
        pass "template password-watcher absent by default"
    else
        fail "template password-watcher absent by default"
    fi

    # Sidecar present when enabled
    out=$(helm template test "$CHART_DIR" --set auth.passwordRotation.enabled=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "password-watcher"; then
        pass "template password-watcher present when enabled"
    else
        fail "template password-watcher present when enabled"
    fi

    # Password file mount when rotation enabled
    out=$(helm template test "$CHART_DIR" --set auth.passwordRotation.enabled=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "valkey-password" && echo "$out" | grep -q "/opt/valkey/secrets"; then
        pass "template password file mount with rotation"
    else
        fail "template password file mount with rotation"
    fi

    # Probes use file-based password when rotation enabled
    out=$(helm template test "$CHART_DIR" --set auth.passwordRotation.enabled=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'cat /opt/valkey/secrets/valkey-password'; then
        pass "template probes use file-based password with rotation"
    else
        fail "template probes use file-based password with rotation"
    fi

    # --- Feature #18: Job image override ---

    # Default: Jobs use image.repository:appVersion
    out=$(helm template test "$CHART_DIR" --set mode=cluster --show-only templates/cluster-init-job.yaml 2>&1)
    if echo "$out" | grep -q "perconalab/valkey:9.0.3"; then
        pass "template job default image"
    else
        fail "template job default image"
    fi

    # Custom image.jobs.repository
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set image.jobs.repository=myregistry.io/valkey --show-only templates/cluster-init-job.yaml 2>&1)
    if echo "$out" | grep -q "myregistry.io/valkey:9.0.3"; then
        pass "template job custom repository"
    else
        fail "template job custom repository"
    fi

    # Custom image.jobs.tag
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set image.jobs.tag=custom-tag --show-only templates/cluster-init-job.yaml 2>&1)
    if echo "$out" | grep -q "perconalab/valkey:custom-tag"; then
        pass "template job custom tag"
    else
        fail "template job custom tag"
    fi

    # Custom both
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set image.jobs.repository=myregistry.io/valkey --set image.jobs.tag=v1.0 --show-only templates/cluster-init-job.yaml 2>&1)
    if echo "$out" | grep -q "myregistry.io/valkey:v1.0"; then
        pass "template job custom repository + tag"
    else
        fail "template job custom repository + tag"
    fi

    # --- Feature #26: Backup CronJob ---

    # CronJob not rendered by default (backup.enabled=false)
    out=$(helm template test "$CHART_DIR" 2>&1)
    if ! echo "$out" | grep -q "kind: CronJob"; then
        pass "template backup CronJob absent by default"
    else
        fail "template backup CronJob absent by default"
    fi

    # CronJob rendered when backup.enabled=true
    out=$(helm template test "$CHART_DIR" --set backup.enabled=true --show-only templates/backup-cronjob.yaml 2>&1)
    if echo "$out" | grep -q "kind: CronJob"; then
        pass "template backup CronJob present when enabled"
    else
        fail "template backup CronJob present when enabled"
    fi

    # Backup PVC rendered when enabled (no existingClaim)
    out=$(helm template test "$CHART_DIR" --set backup.enabled=true --show-only templates/backup-pvc.yaml 2>&1)
    if echo "$out" | grep -q "kind: PersistentVolumeClaim"; then
        pass "template backup PVC rendered"
    else
        fail "template backup PVC rendered"
    fi

    # Backup PVC NOT rendered when existingClaim is set
    if ! helm template test "$CHART_DIR" --set backup.enabled=true --set backup.storage.existingClaim=my-pvc --show-only templates/backup-pvc.yaml 2>&1 | grep -q "kind: PersistentVolumeClaim"; then
        pass "template backup PVC skipped with existingClaim"
    else
        fail "template backup PVC skipped with existingClaim"
    fi

    # CronJob uses existingClaim name in volume
    out=$(helm template test "$CHART_DIR" --set backup.enabled=true --set backup.storage.existingClaim=my-pvc --show-only templates/backup-cronjob.yaml 2>&1)
    if echo "$out" | grep -q "claimName: my-pvc"; then
        pass "template backup CronJob uses existingClaim"
    else
        fail "template backup CronJob uses existingClaim"
    fi

    # CronJob uses correct schedule
    out=$(helm template test "$CHART_DIR" --set backup.enabled=true --set 'backup.schedule=*/5 * * * *' --show-only templates/backup-cronjob.yaml 2>&1)
    if echo "$out" | grep -q '"\*/5 \* \* \* \*"'; then
        pass "template backup CronJob custom schedule"
    else
        fail "template backup CronJob custom schedule"
    fi

    # CronJob uses custom retention count
    out=$(helm template test "$CHART_DIR" --set backup.enabled=true --set backup.retention=3 --show-only templates/backup-cronjob.yaml 2>&1)
    if echo "$out" | grep -q "KEEP=3"; then
        pass "template backup CronJob custom retention"
    else
        fail "template backup CronJob custom retention"
    fi

    # CronJob has auth env var when auth enabled
    out=$(helm template test "$CHART_DIR" --set backup.enabled=true --show-only templates/backup-cronjob.yaml 2>&1)
    if echo "$out" | grep -q "VALKEY_PASSWORD"; then
        pass "template backup CronJob has auth env"
    else
        fail "template backup CronJob has auth env"
    fi

    # CronJob has no auth env when auth disabled
    out=$(helm template test "$CHART_DIR" --set backup.enabled=true --set auth.enabled=false --show-only templates/backup-cronjob.yaml 2>&1)
    if ! echo "$out" | grep -q "VALKEY_PASSWORD"; then
        pass "template backup CronJob no auth env when disabled"
    else
        fail "template backup CronJob no auth env when disabled"
    fi

    # CronJob has TLS volume mounts when TLS enabled
    out=$(helm template test "$CHART_DIR" --set backup.enabled=true --set tls.enabled=true --set tls.existingSecret=tls-secret --show-only templates/backup-cronjob.yaml 2>&1)
    if echo "$out" | grep -q "tls-certs" && echo "$out" | grep -q "PORT=6380" && echo "$out" | grep -q "\-\-tls"; then
        pass "template backup CronJob TLS support"
    else
        fail "template backup CronJob TLS support"
    fi

    # CronJob uses rpmImage (respects image.jobs.* overrides)
    out=$(helm template test "$CHART_DIR" --set backup.enabled=true --set image.jobs.repository=myregistry.io/valkey --show-only templates/backup-cronjob.yaml 2>&1)
    if echo "$out" | grep -q "myregistry.io/valkey:9.0.3"; then
        pass "template backup CronJob uses custom job image"
    else
        fail "template backup CronJob uses custom job image"
    fi

    # --- Sentinel template tests ---

    # Sentinel full render succeeds
    if helm template test "$CHART_DIR" --set mode=sentinel > /dev/null 2>&1; then
        pass "template sentinel full render"
    else
        fail "template sentinel full render"
    fi

    # Sentinel StatefulSet renders with correct replicas
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --show-only templates/sentinel-statefulset.yaml 2>&1)
    if echo "$out" | grep -q "replicas: 3"; then
        pass "template sentinel StatefulSet replicas"
    else
        fail "template sentinel StatefulSet replicas"
    fi

    # Sentinel ConfigMap has sentinel monitor and resolve-hostnames
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --show-only templates/sentinel-configmap.yaml 2>&1)
    if echo "$out" | grep -q "sentinel monitor mymaster" && echo "$out" | grep -q "resolve-hostnames yes"; then
        pass "template sentinel ConfigMap monitor + resolve-hostnames"
    else
        fail "template sentinel ConfigMap monitor + resolve-hostnames"
    fi

    # Sentinel service on port 26379
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --show-only templates/sentinel-service.yaml 2>&1)
    if echo "$out" | grep -q "port: 26379"; then
        pass "template sentinel service port 26379"
    else
        fail "template sentinel service port 26379"
    fi

    # Sentinel headless service with clusterIP: None
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --show-only templates/sentinel-headless-service.yaml 2>&1)
    if echo "$out" | grep -q "clusterIP: None"; then
        pass "template sentinel headless service clusterIP: None"
    else
        fail "template sentinel headless service clusterIP: None"
    fi

    # Sentinel NOT rendered in standalone mode
    out=$(helm template test "$CHART_DIR" --set mode=standalone 2>&1)
    if ! echo "$out" | grep -q "sentinel-statefulset\|sentinel-configmap\|sentinel-service"; then
        pass "template sentinel absent in standalone mode"
    else
        fail "template sentinel absent in standalone mode"
    fi

    # Sentinel NOT rendered in cluster mode
    out=$(helm template test "$CHART_DIR" --set mode=cluster 2>&1)
    if ! echo "$out" | grep -q "sentinel-statefulset\|sentinel-configmap\|sentinel-service"; then
        pass "template sentinel absent in cluster mode"
    else
        fail "template sentinel absent in cluster mode"
    fi

    # Valkey StatefulSet has replicaof in command (sentinel mode)
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "replicaof"; then
        pass "template sentinel valkey StatefulSet has replicaof"
    else
        fail "template sentinel valkey StatefulSet has replicaof"
    fi

    # No cluster-announce-ip in sentinel mode
    if ! echo "$out" | grep -q "cluster-announce-ip"; then
        pass "template sentinel no cluster-announce-ip"
    else
        fail "template sentinel no cluster-announce-ip"
    fi

    # No cluster_state in readiness probes (sentinel mode)
    if ! echo "$out" | grep -q "cluster_state"; then
        pass "template sentinel no cluster_state in probes"
    else
        fail "template sentinel no cluster_state in probes"
    fi

    # PDB renders in sentinel mode
    out=$(helm template test "$CHART_DIR" --set mode=sentinel 2>&1)
    if echo "$out" | grep -q "PodDisruptionBudget"; then
        pass "template PDB present in sentinel mode"
    else
        fail "template PDB present in sentinel mode"
    fi

    # Read service renders in sentinel mode
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --show-only templates/service-read.yaml 2>&1)
    if echo "$out" | grep -q "kind: Service"; then
        pass "template read service present in sentinel mode"
    else
        fail "template read service present in sentinel mode"
    fi

    # HPA doesn't render in sentinel mode
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --set autoscaling.hpa.enabled=true 2>&1)
    if ! echo "$out" | grep -q "HorizontalPodAutoscaler"; then
        pass "template HPA absent in sentinel mode"
    else
        fail "template HPA absent in sentinel mode"
    fi

    # Graceful failover preStop has SENTINEL FAILOVER
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "SENTINEL FAILOVER"; then
        pass "template sentinel graceful failover preStop"
    else
        fail "template sentinel graceful failover preStop"
    fi

    # Custom replicas, sentinelReplicas, quorum, masterSet
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --set sentinel.replicas=5 --set sentinel.sentinelReplicas=5 --set sentinel.quorum=3 --set sentinel.masterSet=mycluster 2>&1)
    sentinel_sts=$(echo "$out" | sed -n '/kind: StatefulSet/,/^---$/p' | grep -A999 "sentinel-statefulset\|name:.*-sentinel$")
    valkey_sts=$(helm template test "$CHART_DIR" --set mode=sentinel --set sentinel.replicas=5 --show-only templates/statefulset.yaml 2>&1)
    if echo "$valkey_sts" | grep -q "replicas: 5"; then
        pass "template sentinel custom data replicas"
    else
        fail "template sentinel custom data replicas"
    fi

    sentinel_cm=$(helm template test "$CHART_DIR" --set mode=sentinel --set sentinel.quorum=3 --set sentinel.masterSet=mycluster --show-only templates/sentinel-configmap.yaml 2>&1)
    if echo "$sentinel_cm" | grep -q "sentinel monitor mycluster" && echo "$sentinel_cm" | grep -q " 3$"; then
        pass "template sentinel custom masterSet + quorum"
    else
        fail "template sentinel custom masterSet + quorum"
    fi

    sentinel_sts_custom=$(helm template test "$CHART_DIR" --set mode=sentinel --set sentinel.sentinelReplicas=5 --show-only templates/sentinel-statefulset.yaml 2>&1)
    if echo "$sentinel_sts_custom" | grep -q "replicas: 5"; then
        pass "template sentinel custom sentinelReplicas"
    else
        fail "template sentinel custom sentinelReplicas"
    fi

    # TLS replication in configmap (sentinel mode)
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --set tls.enabled=true --set tls.existingSecret=my-tls --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "tls-replication yes"; then
        pass "template sentinel TLS replication in configmap"
    else
        fail "template sentinel TLS replication in configmap"
    fi

    # TLS in sentinel configmap
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --set tls.enabled=true --set tls.existingSecret=my-tls --show-only templates/sentinel-configmap.yaml 2>&1)
    if echo "$out" | grep -q "tls-port" && echo "$out" | grep -q "tls-replication yes"; then
        pass "template sentinel TLS in sentinel configmap"
    else
        fail "template sentinel TLS in sentinel configmap"
    fi

    # NetworkPolicy includes sentinel port
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --set networkPolicy.enabled=true --show-only templates/networkpolicy.yaml 2>&1)
    if echo "$out" | grep -q "26379"; then
        pass "template sentinel NetworkPolicy sentinel port"
    else
        fail "template sentinel NetworkPolicy sentinel port"
    fi

    # No cluster-init job in sentinel mode
    out=$(helm template test "$CHART_DIR" --set mode=sentinel 2>&1)
    if ! echo "$out" | grep -q "cluster-init"; then
        pass "template sentinel no cluster-init job"
    else
        fail "template sentinel no cluster-init job"
    fi

    # --- global.imageRegistry tests ---

    # Main image has registry prefix in statefulset
    out=$(helm template test "$CHART_DIR" --set global.imageRegistry=myregistry.io --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "image: myregistry.io/perconalab/valkey:"; then
        pass "template global.imageRegistry main image in statefulset"
    else
        fail "template global.imageRegistry main image in statefulset"
    fi

    # RPM image has registry prefix in cluster-init-job
    out=$(helm template test "$CHART_DIR" --set global.imageRegistry=myregistry.io --set mode=cluster --show-only templates/cluster-init-job.yaml 2>&1)
    if echo "$out" | grep -q "image: myregistry.io/perconalab/valkey:"; then
        pass "template global.imageRegistry rpm image in cluster-init-job"
    else
        fail "template global.imageRegistry rpm image in cluster-init-job"
    fi

    # Metrics image has registry prefix in statefulset
    out=$(helm template test "$CHART_DIR" --set global.imageRegistry=myregistry.io --set metrics.enabled=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "image: myregistry.io/oliver006/redis_exporter:"; then
        pass "template global.imageRegistry metrics image in statefulset"
    else
        fail "template global.imageRegistry metrics image in statefulset"
    fi

    # Registry prefix works in sentinel-statefulset
    out=$(helm template test "$CHART_DIR" --set global.imageRegistry=myregistry.io --set mode=sentinel --show-only templates/sentinel-statefulset.yaml 2>&1)
    if echo "$out" | grep -q "image: myregistry.io/perconalab/valkey:"; then
        pass "template global.imageRegistry in sentinel-statefulset"
    else
        fail "template global.imageRegistry in sentinel-statefulset"
    fi

    # Without registry, no leading / in image
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep "image:" | grep -q "image: /"; then
        fail "template no leading / without global.imageRegistry"
    else
        pass "template no leading / without global.imageRegistry"
    fi

    # Jobs image override + global registry combined
    out=$(helm template test "$CHART_DIR" --set global.imageRegistry=myregistry.io --set image.jobs.repository=custom/valkey --set mode=cluster --show-only templates/cluster-init-job.yaml 2>&1)
    if echo "$out" | grep -q "image: myregistry.io/custom/valkey:"; then
        pass "template global.imageRegistry + jobs override combined"
    else
        fail "template global.imageRegistry + jobs override combined"
    fi

    # Registry works in backup-cronjob
    out=$(helm template test "$CHART_DIR" --set global.imageRegistry=myregistry.io --set backup.enabled=true --show-only templates/backup-cronjob.yaml 2>&1)
    if echo "$out" | grep -q "image: myregistry.io/perconalab/valkey:"; then
        pass "template global.imageRegistry in backup-cronjob"
    else
        fail "template global.imageRegistry in backup-cronjob"
    fi

    # Registry works in cluster-scale-job
    out=$(helm template test "$CHART_DIR" --set global.imageRegistry=myregistry.io --set mode=cluster --show-only templates/cluster-scale-job.yaml 2>&1)
    if echo "$out" | grep -q "image: myregistry.io/perconalab/valkey:"; then
        pass "template global.imageRegistry in cluster-scale-job"
    else
        fail "template global.imageRegistry in cluster-scale-job"
    fi

    # --- commonLabels tests ---

    # StatefulSet labels include commonLabels
    out=$(helm template test "$CHART_DIR" --set commonLabels.team=platform --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "team: platform"; then
        pass "template commonLabels in StatefulSet"
    else
        fail "template commonLabels in StatefulSet"
    fi

    # Service labels include commonLabels
    out=$(helm template test "$CHART_DIR" --set commonLabels.team=platform --show-only templates/service.yaml 2>&1)
    if echo "$out" | grep -q "team: platform"; then
        pass "template commonLabels in Service"
    else
        fail "template commonLabels in Service"
    fi

    # ConfigMap labels include commonLabels
    out=$(helm template test "$CHART_DIR" --set commonLabels.team=platform --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "team: platform"; then
        pass "template commonLabels in ConfigMap"
    else
        fail "template commonLabels in ConfigMap"
    fi

    # Secret labels include commonLabels
    out=$(helm template test "$CHART_DIR" --set commonLabels.team=platform --show-only templates/secret.yaml 2>&1)
    if echo "$out" | grep -q "team: platform"; then
        pass "template commonLabels in Secret"
    else
        fail "template commonLabels in Secret"
    fi

    # commonLabels NOT in selector.matchLabels
    out=$(helm template test "$CHART_DIR" --set commonLabels.team=platform --show-only templates/statefulset.yaml 2>&1)
    MATCH_LABELS=$(echo "$out" | sed -n '/matchLabels:/,/template:/p')
    if echo "$MATCH_LABELS" | grep -q "team: platform"; then
        fail "template commonLabels NOT in matchLabels"
    else
        pass "template commonLabels NOT in matchLabels"
    fi

    # Multiple commonLabels values present
    out=$(helm template test "$CHART_DIR" --set commonLabels.team=platform --set commonLabels.env=prod --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "team: platform" && echo "$out" | grep -q "env: prod"; then
        pass "template multiple commonLabels present"
    else
        fail "template multiple commonLabels present"
    fi

    # --- clusterDomain tests ---

    # Default domain in replicaof (statefulset)
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "svc.cluster.local"; then
        pass "template default clusterDomain in statefulset replicaof"
    else
        fail "template default clusterDomain in statefulset replicaof"
    fi

    # Custom domain in replicaof (statefulset)
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --set clusterDomain=custom.domain --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "svc.custom.domain"; then
        pass "template custom clusterDomain in statefulset replicaof"
    else
        fail "template custom clusterDomain in statefulset replicaof"
    fi

    # Custom domain in cluster-init-job HEADLESS
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set clusterDomain=custom.domain --show-only templates/cluster-init-job.yaml 2>&1)
    if echo "$out" | grep -q "svc.custom.domain"; then
        pass "template custom clusterDomain in cluster-init-job"
    else
        fail "template custom clusterDomain in cluster-init-job"
    fi

    # Custom domain in sentinel-configmap monitor
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --set clusterDomain=custom.domain --show-only templates/sentinel-configmap.yaml 2>&1)
    if echo "$out" | grep -q "svc.custom.domain"; then
        pass "template custom clusterDomain in sentinel-configmap"
    else
        fail "template custom clusterDomain in sentinel-configmap"
    fi

    # Custom domain in certificate DNS SANs
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.certManager.enabled=true --set tls.certManager.issuerRef.name=my-issuer --set clusterDomain=custom.domain --show-only templates/certificate.yaml 2>&1)
    if echo "$out" | grep -q "svc.custom.domain"; then
        pass "template custom clusterDomain in certificate DNS SANs"
    else
        fail "template custom clusterDomain in certificate DNS SANs"
    fi

    # Custom domain in backup-cronjob HEADLESS
    out=$(helm template test "$CHART_DIR" --set backup.enabled=true --set clusterDomain=custom.domain --show-only templates/backup-cronjob.yaml 2>&1)
    if echo "$out" | grep -q "svc.custom.domain"; then
        pass "template custom clusterDomain in backup-cronjob"
    else
        fail "template custom clusterDomain in backup-cronjob"
    fi

    # --- Validation helpers ---

    # ACL without auth → fails
    out=$(helm template test "$CHART_DIR" --set acl.enabled=true --set auth.enabled=false 2>&1 || true)
    if echo "$out" | grep -q "acl.enabled requires auth"; then
        pass "validation: ACL without auth fails"
    else
        fail "validation: ACL without auth fails"
    fi

    # Sentinel + externalAccess → fails
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --set externalAccess.enabled=true 2>&1 || true)
    if echo "$out" | grep -q "externalAccess is not supported in sentinel mode"; then
        pass "validation: sentinel + externalAccess fails"
    else
        fail "validation: sentinel + externalAccess fails"
    fi

    # passwordRotation without auth → fails
    out=$(helm template test "$CHART_DIR" --set auth.passwordRotation.enabled=true --set auth.enabled=false 2>&1 || true)
    if echo "$out" | grep -q "auth.passwordRotation requires auth.enabled=true"; then
        pass "validation: passwordRotation without auth fails"
    else
        fail "validation: passwordRotation without auth fails"
    fi

    # Cluster without persistence → fails
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set persistence.enabled=false 2>&1 || true)
    if echo "$out" | grep -q "persistence.enabled=false with mode="; then
        pass "validation: cluster without persistence fails"
    else
        fail "validation: cluster without persistence fails"
    fi

    # Sentinel without persistence → fails
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --set persistence.enabled=false 2>&1 || true)
    if echo "$out" | grep -q "persistence.enabled=false with mode="; then
        pass "validation: sentinel without persistence fails"
    else
        fail "validation: sentinel without persistence fails"
    fi

    # Cluster replicas < 6 → fails
    out=$(helm template test "$CHART_DIR" --set mode=cluster --set cluster.replicas=3 2>&1 || true)
    if echo "$out" | grep -q "cluster.replicas must be >= 6"; then
        pass "validation: cluster replicas < 6 fails"
    else
        fail "validation: cluster replicas < 6 fails"
    fi

    # TLS disablePlaintext without TLS → fails
    out=$(helm template test "$CHART_DIR" --set tls.disablePlaintext=true --set tls.enabled=false 2>&1 || true)
    if echo "$out" | grep -q "tls.disablePlaintext requires tls.enabled=true"; then
        pass "validation: TLS disablePlaintext without TLS fails"
    else
        fail "validation: TLS disablePlaintext without TLS fails"
    fi

    # Valid cluster config → renders OK
    if helm template test "$CHART_DIR" --set mode=cluster --set cluster.replicas=6 > /dev/null 2>&1; then
        pass "validation: valid cluster config renders OK"
    else
        fail "validation: valid cluster config renders OK"
    fi

    # Standalone without persistence → allowed (does NOT fail)
    if helm template test "$CHART_DIR" --set mode=standalone --set persistence.enabled=false > /dev/null 2>&1; then
        pass "validation: standalone without persistence is allowed"
    else
        fail "validation: standalone without persistence is allowed"
    fi

    # --- env map tests ---

    # env map renders in statefulset
    out=$(helm template test "$CHART_DIR" --set env.TZ=UTC --set env.MY_VAR=hello --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "name: TZ" && echo "$out" | grep -q '"UTC"'; then
        pass "template env map renders in statefulset"
    else
        fail "template env map renders in statefulset"
    fi

    # env map empty by default
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "name: TZ"; then
        pass "template env map empty by default"
    else
        fail "template env map empty by default"
    fi

    # env map NOT in sentinel-statefulset
    out=$(helm template test "$CHART_DIR" --set mode=sentinel --set env.TZ=UTC --show-only templates/sentinel-statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "name: TZ"; then
        pass "template env map NOT in sentinel-statefulset"
    else
        fail "template env map NOT in sentinel-statefulset"
    fi

    # env map + extraEnvVars coexist
    out=$(helm template test "$CHART_DIR" --set env.TZ=UTC --set 'extraEnvVars[0].name=EXTRA' --set 'extraEnvVars[0].value=val' --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "name: TZ" && echo "$out" | grep -q "name: EXTRA"; then
        pass "template env map + extraEnvVars coexist"
    else
        fail "template env map + extraEnvVars coexist"
    fi

    # --- logLevel (Feature 8) ---

    # logLevel renders in configmap
    out=$(helm template test "$CHART_DIR" --set config.logLevel=verbose --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "loglevel verbose"; then
        pass "template logLevel renders in configmap"
    else
        fail "template logLevel renders in configmap"
    fi

    # logLevel absent by default
    out=$(helm template test "$CHART_DIR" --show-only templates/configmap.yaml 2>&1)
    if ! echo "$out" | grep -q "loglevel"; then
        pass "template logLevel absent by default"
    else
        fail "template logLevel absent by default"
    fi

    # --- DH parameters for TLS (Feature 9) ---

    # DH params config directive
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.dhParamsSecret=my-dh --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "tls-dh-params-file"; then
        pass "template DH params config directive"
    else
        fail "template DH params config directive"
    fi

    # DH params volume mount in statefulset
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --set tls.dhParamsSecret=my-dh --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "tls-dhparams" && echo "$out" | grep -q "dhparams.pem"; then
        pass "template DH params volume mount"
    else
        fail "template DH params volume mount"
    fi

    # DH params absent by default
    out=$(helm template test "$CHART_DIR" --set tls.enabled=true --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "dhparams"; then
        pass "template DH params absent by default"
    else
        fail "template DH params absent by default"
    fi

    # --- disklessSync (Feature 10) ---

    # disklessSync renders in configmap
    out=$(helm template test "$CHART_DIR" --set config.disklessSync=true --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "repl-diskless-sync yes"; then
        pass "template disklessSync renders in configmap"
    else
        fail "template disklessSync renders in configmap"
    fi

    # disklessSync absent by default
    out=$(helm template test "$CHART_DIR" --show-only templates/configmap.yaml 2>&1)
    if ! echo "$out" | grep -q "repl-diskless-sync"; then
        pass "template disklessSync absent by default"
    else
        fail "template disklessSync absent by default"
    fi

    # --- min-replicas-to-write / min-replicas-max-lag (Feature 11) ---

    # minReplicas renders in configmap
    out=$(helm template test "$CHART_DIR" --set config.minReplicasToWrite=2 --set config.minReplicasMaxLag=5 --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "min-replicas-to-write 2" && echo "$out" | grep -q "min-replicas-max-lag 5"; then
        pass "template minReplicas write quorum renders in configmap"
    else
        fail "template minReplicas write quorum renders in configmap"
    fi

    # minReplicas absent when 0
    out=$(helm template test "$CHART_DIR" --show-only templates/configmap.yaml 2>&1)
    if ! echo "$out" | grep -q "min-replicas-to-write"; then
        pass "template minReplicas absent by default (0)"
    else
        fail "template minReplicas absent by default (0)"
    fi

    # --- Standalone Deployment (Feature 12) ---

    # Deployment rendered when useDeployment=true
    out=$(helm template test "$CHART_DIR" --set standalone.useDeployment=true --set persistence.enabled=false --show-only templates/deployment.yaml 2>&1)
    if echo "$out" | grep -q "kind: Deployment"; then
        pass "template standalone Deployment rendered"
    else
        fail "template standalone Deployment rendered"
    fi

    # Deployment has strategy
    if echo "$out" | grep -q "strategy"; then
        pass "template Deployment has strategy"
    else
        fail "template Deployment has strategy"
    fi

    # StatefulSet NOT rendered in deployment mode
    out=$(helm template test "$CHART_DIR" --set standalone.useDeployment=true --set persistence.enabled=false --show-only templates/statefulset.yaml 2>&1 || true)
    if echo "$out" | grep -q "could not find template"; then
        pass "template StatefulSet skipped in deployment mode"
    else
        fail "template StatefulSet skipped in deployment mode"
    fi

    # Deployment NOT rendered by default
    out=$(helm template test "$CHART_DIR" 2>&1)
    if ! echo "$out" | grep -q "kind: Deployment"; then
        pass "template Deployment NOT rendered by default"
    else
        fail "template Deployment NOT rendered by default"
    fi

    # Validation: useDeployment + persistence → error
    out=$(helm template test "$CHART_DIR" --set standalone.useDeployment=true 2>&1 || true)
    if echo "$out" | grep -q "standalone.useDeployment requires persistence.enabled=false"; then
        pass "validation: useDeployment + persistence fails"
    else
        fail "validation: useDeployment + persistence fails"
    fi

    # Validation: useDeployment + non-standalone → error
    out=$(helm template test "$CHART_DIR" --set standalone.useDeployment=true --set persistence.enabled=false --set mode=cluster 2>&1 || true)
    if echo "$out" | grep -q "standalone.useDeployment requires mode=standalone"; then
        pass "validation: useDeployment + cluster mode fails"
    else
        fail "validation: useDeployment + cluster mode fails"
    fi

    # Deployment mode lint passes
    if helm lint "$CHART_DIR" --set standalone.useDeployment=true --set persistence.enabled=false > /dev/null 2>&1; then
        pass "lint deployment mode"
    else
        fail "lint deployment mode"
    fi

    # --- SHA256 password hashing ---

    # ACL inline user passwords are SHA256-hashed (# prefix, not > prefix)
    out=$(helm template test "$CHART_DIR" \
        --set acl.enabled=true --set auth.password=$PASS \
        --set 'acl.users.app.password=testpass' \
        --set 'acl.users.app.permissions=~* &* +@all' \
        --show-only templates/secret.yaml 2>&1)
    local acl_b64=$(echo "$out" | grep 'users.acl:' | awk '{print $2}' | tr -d '"')
    local acl_decoded=$(echo "$acl_b64" | base64 -d 2>/dev/null)
    if echo "$acl_decoded" | grep -q '#' && ! echo "$acl_decoded" | grep -q '>'; then
        pass "template ACL passwords are SHA256-hashed (# prefix, no > prefix)"
    else
        fail "template ACL passwords are SHA256-hashed (# prefix, no > prefix)"
    fi

    # ACL with existingPasswordSecret — acl-init script uses sha256sum
    out=$(helm template test "$CHART_DIR" \
        --set acl.enabled=true --set auth.password=$PASS \
        --set 'acl.users.svcuser.existingPasswordSecret=my-secret' \
        --set 'acl.users.svcuser.passwordKey=password' \
        --set 'acl.users.svcuser.permissions=~* +@all' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'sha256sum' && echo "$out" | grep -q '#$HASH'; then
        pass "template acl-init script uses sha256sum for existingPasswordSecret"
    else
        fail "template acl-init script uses sha256sum for existingPasswordSecret"
    fi

    # --- Seccomp profile ---

    # Default render includes seccompProfile RuntimeDefault
    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'seccompProfile' && echo "$out" | grep -q 'type: RuntimeDefault'; then
        pass "template seccompProfile RuntimeDefault in pod security context"
    else
        fail "template seccompProfile RuntimeDefault in pod security context"
    fi

    # --- initResources ---

    # initResources propagates to sysctl-init when sysctlInit.resources is not set
    out=$(helm template test "$CHART_DIR" \
        --set sysctlInit.enabled=true \
        --set initResources.requests.cpu=50m \
        --set initResources.requests.memory=64Mi \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -B20 'sysctl-init' | grep -q 'resources' || \
       echo "$out" | sed -n '/sysctl-init/,/- name:/p' | grep -q 'cpu: 50m'; then
        # More precise check: extract sysctl-init section and look for the resource
        local sysctl_section=$(echo "$out" | sed -n '/name: sysctl-init/,/^        - name:/p')
        if echo "$sysctl_section" | grep -q '50m'; then
            pass "template initResources propagates to sysctl-init"
        else
            fail "template initResources propagates to sysctl-init"
        fi
    else
        fail "template initResources propagates to sysctl-init"
    fi

    # sysctlInit.resources overrides initResources
    out=$(helm template test "$CHART_DIR" \
        --set sysctlInit.enabled=true \
        --set initResources.requests.cpu=50m \
        --set sysctlInit.resources.requests.cpu=200m \
        --show-only templates/statefulset.yaml 2>&1)
    local sysctl_section=$(echo "$out" | sed -n '/name: sysctl-init/,/^        - name:/p')
    if echo "$sysctl_section" | grep -q '200m' && ! echo "$sysctl_section" | grep -q '50m'; then
        pass "template sysctlInit.resources overrides initResources"
    else
        fail "template sysctlInit.resources overrides initResources"
    fi

    # initResources propagates to acl-init
    out=$(helm template test "$CHART_DIR" \
        --set acl.enabled=true --set auth.password=$PASS \
        --set 'acl.users.svcuser.existingPasswordSecret=my-secret' \
        --set 'acl.users.svcuser.passwordKey=password' \
        --set 'acl.users.svcuser.permissions=~* +@all' \
        --set initResources.requests.cpu=50m \
        --set initResources.limits.memory=128Mi \
        --show-only templates/statefulset.yaml 2>&1)
    local acl_section=$(echo "$out" | sed -n '/name: acl-init/,/^      containers:/p')
    if echo "$acl_section" | grep -q '50m' && echo "$acl_section" | grep -q '128Mi'; then
        pass "template initResources propagates to acl-init"
    else
        fail "template initResources propagates to acl-init"
    fi

    # --- Schema validation tests ---

    # Invalid mode value rejected
    out=$(helm template test "$CHART_DIR" --set mode=invalid 2>&1 || true)
    if echo "$out" | grep -qi "fail\|error\|invalid\|enum"; then
        pass "template schema rejects invalid mode"
    else
        fail "template schema rejects invalid mode"
    fi

    # Invalid image variant rejected
    out=$(helm template test "$CHART_DIR" --set image.variant=invalid 2>&1 || true)
    if echo "$out" | grep -qi "fail\|error\|invalid\|enum"; then
        pass "template schema rejects invalid image.variant"
    else
        fail "template schema rejects invalid image.variant"
    fi

    # Valid default values pass schema
    if helm template test "$CHART_DIR" > /dev/null 2>&1; then
        pass "template schema valid default values pass"
    else
        fail "template schema valid default values pass"
    fi

    # Invalid type rejected (string where object expected)
    out=$(helm template test "$CHART_DIR" --set auth=notanobject 2>&1 || true)
    if echo "$out" | grep -qi "fail\|error\|invalid\|expected"; then
        pass "template schema rejects invalid type"
    else
        fail "template schema rejects invalid type"
    fi

    # === F4: hostPath ===

    out=$(helm template test "$CHART_DIR" --set persistence.enabled=false --set persistence.hostPath=/mnt/data \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'path: /mnt/data'; then
        pass "template F4 hostPath in statefulset"
    else
        fail "template F4 hostPath in statefulset"
    fi

    out=$(helm template test "$CHART_DIR" --set standalone.useDeployment=true --set persistence.enabled=false \
        --set persistence.hostPath=/mnt/data --show-only templates/deployment.yaml 2>&1)
    if echo "$out" | grep -q 'path: /mnt/data'; then
        pass "template F4 hostPath in deployment"
    else
        fail "template F4 hostPath in deployment"
    fi

    out=$(helm template test "$CHART_DIR" --set persistence.enabled=false \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'emptyDir: {}'; then
        pass "template F4 emptyDir when no hostPath"
    else
        fail "template F4 emptyDir when no hostPath"
    fi

    out=$(helm template test "$CHART_DIR" --set persistence.enabled=true --set persistence.hostPath=/mnt 2>&1 || true)
    if echo "$out" | grep -q 'mutually exclusive'; then
        pass "template F4 validation hostPath+persistence.enabled"
    else
        fail "template F4 validation hostPath+persistence.enabled"
    fi

    # === F5: keepOnUninstall ===

    out=$(helm template test "$CHART_DIR" --set persistence.keepOnUninstall=true \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'helm.sh/resource-policy: keep'; then
        pass "template F5 keepOnUninstall annotation present"
    else
        fail "template F5 keepOnUninstall annotation present"
    fi

    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'resource-policy'; then
        fail "template F5 keepOnUninstall absent by default"
    else
        pass "template F5 keepOnUninstall absent by default"
    fi

    out=$(helm template test "$CHART_DIR" --set persistence.keepOnUninstall=true \
        --set 'persistence.annotations.backup\.velero\.io/backup-volumes=data' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'resource-policy: keep' && echo "$out" | grep -q 'backup.velero.io'; then
        pass "template F5 keepOnUninstall merges with annotations"
    else
        fail "template F5 keepOnUninstall merges with annotations"
    fi

    # === F6: subPath ===

    out=$(helm template test "$CHART_DIR" --set persistence.subPath=mydata \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'subPath: mydata'; then
        pass "template F6 subPath in statefulset"
    else
        fail "template F6 subPath in statefulset"
    fi

    out=$(helm template test "$CHART_DIR" --set standalone.useDeployment=true --set persistence.enabled=false \
        --set persistence.subPath=mydata --show-only templates/deployment.yaml 2>&1)
    if echo "$out" | grep -q 'subPath: mydata'; then
        pass "template F6 subPath in deployment"
    else
        fail "template F6 subPath in deployment"
    fi

    out=$(helm template test "$CHART_DIR" --set persistence.subPath=mydata \
        --set volumePermissions.enabled=true --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'subPath: mydata'; then
        pass "template F6 subPath in volume-permissions init"
    else
        fail "template F6 subPath in volume-permissions init"
    fi

    # === F7: extraValkeySecrets/Configs ===

    out=$(helm template test "$CHART_DIR" \
        --set 'extraValkeySecrets[0].name=mysecret' --set 'extraValkeySecrets[0].mountPath=/etc/valkey/extra' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'extra-secret-mysecret'; then
        pass "template F7 extraValkeySecrets in statefulset"
    else
        fail "template F7 extraValkeySecrets in statefulset"
    fi

    out=$(helm template test "$CHART_DIR" \
        --set 'extraValkeyConfigs[0].name=mycm' --set 'extraValkeyConfigs[0].mountPath=/etc/valkey/extra-cm' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'extra-config-mycm'; then
        pass "template F7 extraValkeyConfigs in statefulset"
    else
        fail "template F7 extraValkeyConfigs in statefulset"
    fi

    out=$(helm template test "$CHART_DIR" --set standalone.useDeployment=true --set persistence.enabled=false \
        --set 'extraValkeySecrets[0].name=mysecret' --set 'extraValkeySecrets[0].mountPath=/etc/valkey/extra' \
        --show-only templates/deployment.yaml 2>&1)
    if echo "$out" | grep -q 'extra-secret-mysecret'; then
        pass "template F7 extraValkeySecrets in deployment"
    else
        fail "template F7 extraValkeySecrets in deployment"
    fi

    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'extra-secret\|extra-config'; then
        fail "template F7 empty by default"
    else
        pass "template F7 empty by default"
    fi

    # === F8: replicationUser ===

    out=$(helm template test "$CHART_DIR" --set mode=cluster --set externalAccess.enabled=true \
        --set acl.enabled=true --set auth.password=$PASS \
        --set acl.replicationUser=repluser \
        --set 'acl.users.repluser.password=replpass' --set 'acl.users.repluser.permissions=+replconf +psync +ping' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'masteruser repluser'; then
        pass "template F8 masteruser in cluster"
    else
        fail "template F8 masteruser in cluster"
    fi

    out=$(helm template test "$CHART_DIR" --set mode=sentinel \
        --set acl.enabled=true --set auth.password=$PASS \
        --set acl.replicationUser=repluser \
        --set 'acl.users.repluser.password=replpass' --set 'acl.users.repluser.permissions=+replconf +psync +ping' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'masteruser repluser'; then
        pass "template F8 masteruser in sentinel"
    else
        fail "template F8 masteruser in sentinel"
    fi

    out=$(helm template test "$CHART_DIR" --set acl.enabled=true --set auth.password=$PASS \
        --set 'acl.users.appuser.password=apppass' --set 'acl.users.appuser.permissions=~* +@all' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q 'masteruser'; then
        fail "template F8 absent by default"
    else
        pass "template F8 absent by default"
    fi

    out=$(helm template test "$CHART_DIR" --set acl.enabled=true --set auth.password=$PASS \
        --set acl.replicationUser=baduser 2>&1 || true)
    if echo "$out" | grep -q "must be defined in acl.users"; then
        pass "template F8 validation missing user"
    else
        fail "template F8 validation missing user"
    fi

    # === F9: service fields ===

    out=$(helm template test "$CHART_DIR" --set service.clusterIP=10.0.0.100 \
        --show-only templates/service.yaml 2>&1)
    if echo "$out" | grep -q 'clusterIP: 10.0.0.100'; then
        pass "template F9 clusterIP renders"
    else
        fail "template F9 clusterIP renders"
    fi

    out=$(helm template test "$CHART_DIR" --set service.type=LoadBalancer --set service.loadBalancerClass=myclass \
        --show-only templates/service.yaml 2>&1)
    if echo "$out" | grep -q 'loadBalancerClass: myclass'; then
        pass "template F9 loadBalancerClass renders"
    else
        fail "template F9 loadBalancerClass renders"
    fi

    out=$(helm template test "$CHART_DIR" --set service.appProtocol=redis \
        --show-only templates/service.yaml 2>&1)
    if echo "$out" | grep -q 'appProtocol: redis'; then
        pass "template F9 appProtocol renders"
    else
        fail "template F9 appProtocol renders"
    fi

    out=$(helm template test "$CHART_DIR" --show-only templates/service.yaml 2>&1)
    if echo "$out" | grep -q 'clusterIP:\|loadBalancerClass:\|appProtocol:'; then
        fail "template F9 absent by default"
    else
        pass "template F9 absent by default"
    fi

    # === F10: metrics command/args ===

    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true \
        --set 'metrics.command[0]=/custom-exporter' --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q '/custom-exporter'; then
        pass "template F10 command in statefulset"
    else
        fail "template F10 command in statefulset"
    fi

    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true \
        --set 'metrics.args[0]=--debug' --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q '\-\-debug'; then
        pass "template F10 args in statefulset"
    else
        fail "template F10 args in statefulset"
    fi

    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -B1 'securityContext' | grep -q 'command:'; then
        fail "template F10 no command by default"
    else
        pass "template F10 no command by default"
    fi

    # === F11: relabelings & metricRelabelings ===

    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true --set metrics.serviceMonitor.enabled=true \
        --set 'metrics.serviceMonitor.relabelings[0].sourceLabels[0]=__name__' \
        --set 'metrics.serviceMonitor.relabelings[0].action=keep' \
        --show-only templates/servicemonitor.yaml 2>&1)
    if echo "$out" | grep -q "relabelings:" && echo "$out" | grep -q "action: keep"; then
        pass "template F11 relabelings in ServiceMonitor"
    else
        fail "template F11 relabelings in ServiceMonitor"
    fi

    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true --set metrics.podMonitor.enabled=true \
        --set 'metrics.podMonitor.metricRelabelings[0].sourceLabels[0]=__name__' \
        --set 'metrics.podMonitor.metricRelabelings[0].action=drop' \
        --show-only templates/podmonitor.yaml 2>&1)
    if echo "$out" | grep -q "metricRelabelings:" && echo "$out" | grep -q "action: drop"; then
        pass "template F11 metricRelabelings in PodMonitor"
    else
        fail "template F11 metricRelabelings in PodMonitor"
    fi

    # === F12: sampleLimit & targetLimit ===

    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true --set metrics.serviceMonitor.enabled=true \
        --set metrics.serviceMonitor.sampleLimit=5000 \
        --show-only templates/servicemonitor.yaml 2>&1)
    if echo "$out" | grep -q "sampleLimit: 5000"; then
        pass "template F12 sampleLimit in ServiceMonitor"
    else
        fail "template F12 sampleLimit in ServiceMonitor"
    fi

    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true --set metrics.podMonitor.enabled=true \
        --set metrics.podMonitor.targetLimit=100 \
        --show-only templates/podmonitor.yaml 2>&1)
    if echo "$out" | grep -q "targetLimit: 100"; then
        pass "template F12 targetLimit in PodMonitor"
    else
        fail "template F12 targetLimit in PodMonitor"
    fi

    # === F13: honorLabels & podTargetLabels ===

    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true --set metrics.serviceMonitor.enabled=true \
        --set metrics.serviceMonitor.honorLabels=true \
        --show-only templates/servicemonitor.yaml 2>&1)
    if echo "$out" | grep -q "honorLabels: true"; then
        pass "template F13 honorLabels in ServiceMonitor"
    else
        fail "template F13 honorLabels in ServiceMonitor"
    fi

    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true --set metrics.podMonitor.enabled=true \
        --set 'metrics.podMonitor.podTargetLabels[0]=app' \
        --show-only templates/podmonitor.yaml 2>&1)
    if echo "$out" | grep -q "podTargetLabels:" && echo "$out" | grep -q "app"; then
        pass "template F13 podTargetLabels in PodMonitor"
    else
        fail "template F13 podTargetLabels in PodMonitor"
    fi

    # === F14: metrics exporter extraEnvs, extraSecrets, extraVolumeMounts ===

    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true \
        --set 'metrics.extraEnvs[0].name=MY_EXPORTER_VAR' --set 'metrics.extraEnvs[0].value=test' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "MY_EXPORTER_VAR"; then
        pass "template F14 extraEnvs in metrics container"
    else
        fail "template F14 extraEnvs in metrics container"
    fi

    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true \
        --set 'metrics.extraSecrets[0].name=my-secret' --set 'metrics.extraSecrets[0].mountPath=/etc/secrets' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "metrics-secret-my-secret" && echo "$out" | grep -q "/etc/secrets"; then
        pass "template F14 extraSecrets volume+mount"
    else
        fail "template F14 extraSecrets volume+mount"
    fi

    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true \
        --set 'metrics.extraVolumeMounts[0].name=extra-vol' --set 'metrics.extraVolumeMounts[0].mountPath=/extra' \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "/extra"; then
        pass "template F14 extraVolumeMounts"
    else
        fail "template F14 extraVolumeMounts"
    fi

    # Verify absent by default
    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true \
        --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "metrics-secret-" && ! echo "$out" | grep -q "MY_EXPORTER_VAR"; then
        pass "template F14 absent by default"
    else
        fail "template F14 absent by default"
    fi

    # === F15: metrics configurable securityContext ===

    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true \
        --set metrics.securityContext.runAsUser=1000 \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "runAsUser: 1000"; then
        pass "template F15 custom securityContext renders"
    else
        fail "template F15 custom securityContext renders"
    fi

    out=$(helm template test "$CHART_DIR" --set metrics.enabled=true \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -A5 'name: metrics' | grep -q "readOnlyRootFilesystem: true"; then
        pass "template F15 default securityContext matches"
    else
        fail "template F15 default securityContext matches"
    fi

    # === F16: read-only root filesystem by default ===

    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "mountPath: /tmp" && echo "$out" | grep -q "mountPath: /run/valkey"; then
        pass "template F16 emptyDir mounts present by default"
    else
        fail "template F16 emptyDir mounts present by default"
    fi

    out=$(helm template test "$CHART_DIR" --set containerSecurityContext.readOnlyRootFilesystem=false \
        --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "mountPath: /tmp"; then
        pass "template F16 emptyDir mounts absent when readOnly=false"
    else
        fail "template F16 emptyDir mounts absent when readOnly=false"
    fi

    # === F17: seccompProfile ===

    out=$(helm template test "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "RuntimeDefault"; then
        pass "template F17 seccompProfile renders"
    else
        fail "template F17 seccompProfile renders"
    fi

    # === F18: configurable TLS key names ===

    out=$(helm template test "$CHART_DIR" \
        --set tls.enabled=true --set tls.existingSecret=my-tls \
        --set tls.certKey=server.crt --set tls.keyKey=server.key --set tls.caKey=root-ca.crt \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "key: server.crt" && echo "$out" | grep -q "key: server.key" && echo "$out" | grep -q "key: root-ca.crt"; then
        pass "template F18 custom key names in volumes"
    else
        fail "template F18 custom key names in volumes"
    fi

    out=$(helm template test "$CHART_DIR" \
        --set tls.enabled=true --set tls.existingSecret=my-tls \
        --set tls.certKey=server.crt --set tls.keyKey=server.key --set tls.caKey=root-ca.crt \
        --show-only templates/configmap.yaml 2>&1)
    if echo "$out" | grep -q "tls-cert-file .*/server.crt" && echo "$out" | grep -q "tls-ca-cert-file .*/root-ca.crt"; then
        pass "template F18 custom key names in configmap"
    else
        fail "template F18 custom key names in configmap"
    fi

    # === F19: default user protection ===

    out=$(helm template test "$CHART_DIR" --set acl.enabled=true --set auth.password=p \
        --set 'acl.users.default.permissions=~* +@all' --set 'acl.users.default.password=p' 2>&1 || true)
    if echo "$out" | grep -q "default user is auto-managed"; then
        pass "template F19 validation error for default user"
    else
        fail "template F19 validation error for default user"
    fi

    # === F20: permissions required ===

    out=$(helm template test "$CHART_DIR" --set acl.enabled=true --set auth.password=p \
        --set 'acl.users.x.password=p' 2>&1 || true)
    if echo "$out" | grep -q "permissions field is required"; then
        pass "template F20 validation error for missing permissions"
    else
        fail "template F20 validation error for missing permissions"
    fi

    # === F21: per-mode persistence overrides ===

    out=$(helm template test "$CHART_DIR" --set mode=cluster --set cluster.persistence.size=20Gi \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "storage: 20Gi"; then
        pass "template F21 cluster persistence size overrides global"
    else
        fail "template F21 cluster persistence size overrides global"
    fi

    out=$(helm template test "$CHART_DIR" --set mode=cluster \
        --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "storage: 8Gi"; then
        pass "template F21 fallback to global when not set"
    else
        fail "template F21 fallback to global when not set"
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

test_tls_standalone() {
    bold "=== TEST: TLS standalone ==="
    local rel="t-tls-sa"
    cleanup "$rel"

    # Generate self-signed CA and server certificate
    local TLS_DIR=$(mktemp -d)
    openssl genrsa -out "$TLS_DIR/ca.key" 2048 2>/dev/null
    openssl req -x509 -new -nodes -key "$TLS_DIR/ca.key" -sha256 -days 1 \
        -out "$TLS_DIR/ca.crt" -subj "/CN=valkey-test-ca" 2>/dev/null
    openssl genrsa -out "$TLS_DIR/tls.key" 2048 2>/dev/null
    openssl req -new -key "$TLS_DIR/tls.key" -out "$TLS_DIR/tls.csr" \
        -subj "/CN=valkey-tls-test" 2>/dev/null
    cat > "$TLS_DIR/ext.cnf" <<CERTEOF
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
DNS.2 = *.default.svc.cluster.local
DNS.3 = ${rel}-percona-valkey
DNS.4 = ${rel}-percona-valkey-headless
DNS.5 = ${rel}-percona-valkey.default.svc.cluster.local
DNS.6 = ${rel}-percona-valkey-headless.default.svc.cluster.local
DNS.7 = *.${rel}-percona-valkey-headless.default.svc.cluster.local
CERTEOF
    openssl x509 -req -in "$TLS_DIR/tls.csr" -CA "$TLS_DIR/ca.crt" -CAkey "$TLS_DIR/ca.key" \
        -CAcreateserial -out "$TLS_DIR/tls.crt" -days 1 -sha256 \
        -extensions v3_req -extfile "$TLS_DIR/ext.cnf" 2>/dev/null

    # Create Kubernetes secret
    kubectl create secret generic "${rel}-tls-secret" \
        --from-file=tls.crt="$TLS_DIR/tls.crt" \
        --from-file=tls.key="$TLS_DIR/tls.key" \
        --from-file=ca.crt="$TLS_DIR/ca.crt" \
        -n $NAMESPACE 2>/dev/null || true

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set tls.enabled=true \
        --set tls.existingSecret="${rel}-tls-secret" \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "TLS standalone install"; cleanup "$rel"; kubectl delete secret "${rel}-tls-secret" -n $NAMESPACE 2>/dev/null; rm -rf "$TLS_DIR"; return; }
    pass "TLS standalone install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "TLS standalone pod ready"
    else
        fail "TLS standalone pod ready"; cleanup "$rel"; kubectl delete secret "${rel}-tls-secret" -n $NAMESPACE 2>/dev/null; rm -rf "$TLS_DIR"; return
    fi

    # Verify TLS port is listening
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -p 6380 --tls --cacert /etc/valkey/tls/ca.crt --cert /etc/valkey/tls/tls.crt --key /etc/valkey/tls/tls.key -a $PASS ping 2>/dev/null | grep -q PONG; then
        pass "TLS standalone ping on TLS port"
    else
        fail "TLS standalone ping on TLS port"
    fi

    # Verify plaintext port still works (disablePlaintext is false)
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS ping 2>/dev/null | grep -q PONG; then
        pass "TLS standalone plaintext port still works"
    else
        fail "TLS standalone plaintext port still works"
    fi

    # Set/Get over TLS
    kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -p 6380 --tls --cacert /etc/valkey/tls/ca.crt --cert /etc/valkey/tls/tls.crt --key /etc/valkey/tls/tls.key -a $PASS set tls-key tls-value > /dev/null 2>&1
    local val=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -p 6380 --tls --cacert /etc/valkey/tls/ca.crt --cert /etc/valkey/tls/tls.crt --key /etc/valkey/tls/tls.key -a $PASS get tls-key 2>/dev/null)
    if [ "$val" = "tls-value" ]; then
        pass "TLS standalone set/get over TLS"
    else
        fail "TLS standalone set/get over TLS (got: $val)"
    fi

    # Verify tls-port in running config
    local tls_port=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS config get tls-port 2>/dev/null | tail -1)
    if [ "$tls_port" = "6380" ]; then
        pass "TLS standalone config tls-port=6380"
    else
        fail "TLS standalone config tls-port=6380 (got: $tls_port)"
    fi

    # Helm test should pass (test-connection uses TLS)
    if helm test "$rel" -n $NAMESPACE > /dev/null 2>&1; then
        pass "TLS standalone helm test"
    else
        fail "TLS standalone helm test"
    fi

    cleanup "$rel"
    kubectl delete secret "${rel}-tls-secret" -n $NAMESPACE 2>/dev/null || true
    rm -rf "$TLS_DIR"
}

test_tls_plaintext_disabled() {
    bold "=== TEST: TLS with plaintext disabled ==="
    local rel="t-tls-nopt"
    cleanup "$rel"

    # Generate self-signed CA and server certificate
    local TLS_DIR=$(mktemp -d)
    openssl genrsa -out "$TLS_DIR/ca.key" 2048 2>/dev/null
    openssl req -x509 -new -nodes -key "$TLS_DIR/ca.key" -sha256 -days 1 \
        -out "$TLS_DIR/ca.crt" -subj "/CN=valkey-test-ca" 2>/dev/null
    openssl genrsa -out "$TLS_DIR/tls.key" 2048 2>/dev/null
    openssl req -new -key "$TLS_DIR/tls.key" -out "$TLS_DIR/tls.csr" \
        -subj "/CN=valkey-tls-nopt" 2>/dev/null
    cat > "$TLS_DIR/ext.cnf" <<CERTEOF
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
DNS.2 = *.default.svc.cluster.local
DNS.3 = ${rel}-percona-valkey
DNS.4 = ${rel}-percona-valkey-headless
DNS.5 = ${rel}-percona-valkey.default.svc.cluster.local
DNS.6 = ${rel}-percona-valkey-headless.default.svc.cluster.local
DNS.7 = *.${rel}-percona-valkey-headless.default.svc.cluster.local
CERTEOF
    openssl x509 -req -in "$TLS_DIR/tls.csr" -CA "$TLS_DIR/ca.crt" -CAkey "$TLS_DIR/ca.key" \
        -CAcreateserial -out "$TLS_DIR/tls.crt" -days 1 -sha256 \
        -extensions v3_req -extfile "$TLS_DIR/ext.cnf" 2>/dev/null

    kubectl create secret generic "${rel}-tls-secret" \
        --from-file=tls.crt="$TLS_DIR/tls.crt" \
        --from-file=tls.key="$TLS_DIR/tls.key" \
        --from-file=ca.crt="$TLS_DIR/ca.crt" \
        -n $NAMESPACE 2>/dev/null || true

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set tls.enabled=true \
        --set tls.existingSecret="${rel}-tls-secret" \
        --set tls.disablePlaintext=true \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "TLS plaintext-disabled install"; cleanup "$rel"; kubectl delete secret "${rel}-tls-secret" -n $NAMESPACE 2>/dev/null; rm -rf "$TLS_DIR"; return; }
    pass "TLS plaintext-disabled install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "TLS plaintext-disabled pod ready"
    else
        fail "TLS plaintext-disabled pod ready"; cleanup "$rel"; kubectl delete secret "${rel}-tls-secret" -n $NAMESPACE 2>/dev/null; rm -rf "$TLS_DIR"; return
    fi

    # Verify TLS port works
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -p 6380 --tls --cacert /etc/valkey/tls/ca.crt --cert /etc/valkey/tls/tls.crt --key /etc/valkey/tls/tls.key -a $PASS ping 2>/dev/null | grep -q PONG; then
        pass "TLS plaintext-disabled ping on TLS port"
    else
        fail "TLS plaintext-disabled ping on TLS port"
    fi

    # Verify plaintext port is disabled (port 0 in config, connection should fail)
    local pt_response=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS ping 2>&1 || true)
    if echo "$pt_response" | grep -qi "refused\|error\|Could not connect"; then
        pass "TLS plaintext-disabled plaintext port rejected"
    else
        fail "TLS plaintext-disabled plaintext port rejected (got: $pt_response)"
    fi

    # Helm test should pass via TLS
    if helm test "$rel" -n $NAMESPACE > /dev/null 2>&1; then
        pass "TLS plaintext-disabled helm test"
    else
        fail "TLS plaintext-disabled helm test"
    fi

    cleanup "$rel"
    kubectl delete secret "${rel}-tls-secret" -n $NAMESPACE 2>/dev/null || true
    rm -rf "$TLS_DIR"
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

test_extra_init_containers() {
    bold "=== TEST: Extra init containers ==="
    local rel="t-extrainit"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set 'extraInitContainers[0].name=my-init' \
        --set 'extraInitContainers[0].image=busybox:latest' \
        --set 'extraInitContainers[0].command[0]=sh' \
        --set 'extraInitContainers[0].command[1]=-c' \
        --set 'extraInitContainers[0].command[2]=echo init-done > /data/init-marker' \
        --set 'extraInitContainers[0].volumeMounts[0].name=data' \
        --set 'extraInitContainers[0].volumeMounts[0].mountPath=/data' \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "extraInitContainers install"; cleanup "$rel"; return; }
    pass "extraInitContainers install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "extraInitContainers pod ready"
    else
        fail "extraInitContainers pod ready"; cleanup "$rel"; return
    fi

    # Verify init container ran and wrote the marker file
    local val=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- cat /data/init-marker 2>/dev/null)
    if [ "$val" = "init-done" ]; then
        pass "extraInitContainers marker file written"
    else
        fail "extraInitContainers marker file (got: '$val')"
    fi

    cleanup "$rel"
}

test_extra_containers() {
    bold "=== TEST: Extra sidecar containers ==="
    local rel="t-extrasidecar"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set 'extraContainers[0].name=log-tailer' \
        --set 'extraContainers[0].image=busybox:latest' \
        --set 'extraContainers[0].command[0]=sh' \
        --set 'extraContainers[0].command[1]=-c' \
        --set 'extraContainers[0].command[2]=while true; do sleep 3600; done' \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "extraContainers install"; cleanup "$rel"; return; }
    pass "extraContainers install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "extraContainers pod ready"
    else
        fail "extraContainers pod ready"; cleanup "$rel"; return
    fi

    # Verify sidecar container exists and is running
    local status=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.status.containerStatuses[?(@.name=="log-tailer")].ready}' 2>/dev/null)
    if [ "$status" = "true" ]; then
        pass "extraContainers sidecar running"
    else
        fail "extraContainers sidecar running (status: $status)"
    fi

    # Verify valkey still works alongside sidecar
    if kubectl exec ${rel}-percona-valkey-0 -c valkey -n $NAMESPACE -- valkey-cli -a $PASS ping 2>/dev/null | grep -q PONG; then
        pass "extraContainers valkey-cli ping"
    else
        fail "extraContainers valkey-cli ping"
    fi

    cleanup "$rel"
}

test_anti_affinity_preset() {
    bold "=== TEST: Pod anti-affinity preset ==="
    local rel="t-antiaffinity"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set podAntiAffinityPreset.type=soft \
        --set podAntiAffinityPreset.topologyKey=kubernetes.io/hostname \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "anti-affinity install"; cleanup "$rel"; return; }
    pass "anti-affinity install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "anti-affinity pod ready"
    else
        fail "anti-affinity pod ready"; cleanup "$rel"; return
    fi

    # Verify pod spec has the anti-affinity rule
    local affinity=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.topologyKey}' 2>/dev/null)
    if [ "$affinity" = "kubernetes.io/hostname" ]; then
        pass "anti-affinity soft preset applied"
    else
        fail "anti-affinity soft preset (got: '$affinity')"
    fi

    # Verify valkey works
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS ping 2>/dev/null | grep -q PONG; then
        pass "anti-affinity valkey-cli ping"
    else
        fail "anti-affinity valkey-cli ping"
    fi

    cleanup "$rel"
}

test_termination_grace_period() {
    bold "=== TEST: Termination grace period ==="
    local rel="t-termgrace"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set terminationGracePeriodSeconds=120 \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "termination-grace install"; cleanup "$rel"; return; }
    pass "termination-grace install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "termination-grace pod ready"
    else
        fail "termination-grace pod ready"; cleanup "$rel"; return
    fi

    # Verify terminationGracePeriodSeconds in pod spec
    local grace=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.terminationGracePeriodSeconds}' 2>/dev/null)
    if [ "$grace" = "120" ]; then
        pass "termination-grace period 120s in pod spec"
    else
        fail "termination-grace period (got: '$grace')"
    fi

    cleanup "$rel"
}

test_priority_class() {
    bold "=== TEST: Priority class ==="
    local rel="t-priority"
    cleanup "$rel"

    # Create a PriorityClass for testing
    kubectl apply -f - <<'PCEOF' 2>/dev/null || true
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: valkey-test-priority
value: 1000
globalDefault: false
description: "Test priority class for Valkey"
PCEOF

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set priorityClassName=valkey-test-priority \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "priority-class install"; cleanup "$rel"; kubectl delete priorityclass valkey-test-priority 2>/dev/null; return; }
    pass "priority-class install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "priority-class pod ready"
    else
        fail "priority-class pod ready"; cleanup "$rel"; kubectl delete priorityclass valkey-test-priority 2>/dev/null; return
    fi

    # Verify priorityClassName in pod spec
    local pc=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.priorityClassName}' 2>/dev/null)
    if [ "$pc" = "valkey-test-priority" ]; then
        pass "priority-class applied to pod"
    else
        fail "priority-class (got: '$pc')"
    fi

    cleanup "$rel"
    kubectl delete priorityclass valkey-test-priority 2>/dev/null || true
}

test_topology_spread() {
    bold "=== TEST: Topology spread constraints ==="
    local rel="t-topospr"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set 'topologySpreadConstraints[0].maxSkew=1' \
        --set 'topologySpreadConstraints[0].topologyKey=kubernetes.io/hostname' \
        --set 'topologySpreadConstraints[0].whenUnsatisfiable=ScheduleAnyway' \
        --set 'topologySpreadConstraints[0].labelSelector.matchLabels.app\.kubernetes\.io/name=percona-valkey' \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "topology-spread install"; cleanup "$rel"; return; }
    pass "topology-spread install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "topology-spread pod ready"
    else
        fail "topology-spread pod ready"; cleanup "$rel"; return
    fi

    # Verify topologySpreadConstraints in pod spec
    local topo=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.topologySpreadConstraints[0].topologyKey}' 2>/dev/null)
    if [ "$topo" = "kubernetes.io/hostname" ]; then
        pass "topology-spread constraint applied"
    else
        fail "topology-spread constraint (got: '$topo')"
    fi

    cleanup "$rel"
}

test_read_service() {
    bold "=== TEST: Read service (standalone replicas) ==="
    local rel="t-readsvc"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set standalone.replicas=2 \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "read-service install"; cleanup "$rel"; return; }
    pass "read-service install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 2; then
        pass "read-service 2 pods ready"
    else
        fail "read-service 2 pods ready"; cleanup "$rel"; return
    fi

    # Verify the read service exists
    if kubectl get svc ${rel}-percona-valkey-read -n $NAMESPACE > /dev/null 2>&1; then
        pass "read-service exists"
    else
        fail "read-service exists"; cleanup "$rel"; return
    fi

    # Verify read service has correct type
    local svc_type=$(kubectl get svc ${rel}-percona-valkey-read -n $NAMESPACE -o jsonpath='{.spec.type}' 2>/dev/null)
    if [ "$svc_type" = "ClusterIP" ]; then
        pass "read-service type ClusterIP"
    else
        fail "read-service type (got: '$svc_type')"
    fi

    # Verify read service has the valkey port
    local port=$(kubectl get svc ${rel}-percona-valkey-read -n $NAMESPACE -o jsonpath='{.spec.ports[?(@.name=="valkey")].port}' 2>/dev/null)
    if [ "$port" = "6379" ]; then
        pass "read-service port 6379"
    else
        fail "read-service port (got: '$port')"
    fi

    # Verify connectivity through read service
    local read_ip=$(kubectl get svc ${rel}-percona-valkey-read -n $NAMESPACE -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -h "$read_ip" -a $PASS ping 2>/dev/null | grep -q PONG; then
        pass "read-service ping via ClusterIP"
    else
        fail "read-service ping via ClusterIP"
    fi

    cleanup "$rel"
}

test_dns_config() {
    bold "=== TEST: DNS config and policy ==="
    local rel="t-dns"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set dnsPolicy=ClusterFirst \
        --set 'dnsConfig.options[0].name=ndots' \
        --set-string 'dnsConfig.options[0].value=3' \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "dns-config install"; cleanup "$rel"; return; }
    pass "dns-config install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "dns-config pod ready"
    else
        fail "dns-config pod ready"; cleanup "$rel"; return
    fi

    # Verify dnsPolicy in pod spec
    local policy=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.dnsPolicy}' 2>/dev/null)
    if [ "$policy" = "ClusterFirst" ]; then
        pass "dns-config policy ClusterFirst"
    else
        fail "dns-config policy (got: '$policy')"
    fi

    # Verify dnsConfig ndots
    local ndots=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.dnsConfig.options[0].name}' 2>/dev/null)
    if [ "$ndots" = "ndots" ]; then
        pass "dns-config ndots option present"
    else
        fail "dns-config ndots (got: '$ndots')"
    fi

    # Verify valkey works with custom DNS
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS ping 2>/dev/null | grep -q PONG; then
        pass "dns-config valkey-cli ping"
    else
        fail "dns-config valkey-cli ping"
    fi

    cleanup "$rel"
}

test_runtime_class() {
    bold "=== TEST: Runtime class ==="
    local rel="t-runtime"

    # Template-only test: runtimeClassName renders correctly
    # Deployment test skipped because it requires a specific RuntimeClass on the cluster
    local out=$(helm template "$rel" "$CHART_DIR" --set runtimeClassName=my-runtime --show-only templates/statefulset.yaml 2>&1)
    if echo "$out" | grep -q "runtimeClassName: my-runtime"; then
        pass "runtime-class renders in template"
    else
        fail "runtime-class renders in template"
    fi

    # Verify it doesn't appear by default
    out=$(helm template "$rel" "$CHART_DIR" --show-only templates/statefulset.yaml 2>&1)
    if ! echo "$out" | grep -q "runtimeClassName"; then
        pass "runtime-class absent by default"
    else
        fail "runtime-class absent by default"
    fi
}

test_acl_standalone() {
    bold "=== TEST: ACL standalone ==="
    local rel="t-acl"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set acl.enabled=true \
        --set 'acl.users.app.permissions=~* &* +@all' \
        --set 'acl.users.app.password=apppass123' \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "acl standalone install"; cleanup "$rel"; return; }
    pass "acl standalone install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1; then
        pass "acl standalone pod ready"
    else
        fail "acl standalone pod ready"; cleanup "$rel"; return
    fi

    # Verify default user can ping (uses auth.password)
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS ping 2>/dev/null | grep -q PONG; then
        pass "acl default user ping"
    else
        fail "acl default user ping"
    fi

    # Verify custom ACL user can authenticate
    if kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli --user app --pass apppass123 ping 2>/dev/null | grep -q PONG; then
        pass "acl custom user (app) ping"
    else
        fail "acl custom user (app) ping"
    fi

    # Verify ACL list shows the custom user
    local acl_list
    acl_list=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS acl list 2>/dev/null)
    if echo "$acl_list" | grep -q "user app"; then
        pass "acl list contains custom user"
    else
        fail "acl list contains custom user"
    fi

    cleanup "$rel"
}

# --- Feature #16: Cluster precheck deployment test ---

test_cluster_precheck() {
    bold "=== TEST: Cluster scale-down precheck ==="
    local rel="t-precheck"
    cleanup "$rel"

    # Deploy 6-node cluster
    helm install "$rel" "$CHART_DIR" \
        --set mode=cluster \
        --set auth.password=$PASS \
        -n $NAMESPACE --timeout $TIMEOUT 2>&1 || { fail "precheck install"; cleanup "$rel"; return; }
    pass "precheck install (6 nodes)"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 6 300s; then
        pass "precheck initial 6 pods ready"
    else
        fail "precheck initial 6 pods ready"; cleanup "$rel"; return
    fi

    # Wait for cluster init to finish
    sleep 15

    # Verify cluster is OK before testing
    local state=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -- valkey-cli -a $PASS cluster info 2>/dev/null | grep cluster_state | tr -d '\r')
    if [ "$state" != "cluster_state:ok" ]; then
        fail "precheck cluster not OK before test (got: $state)"; cleanup "$rel"; return
    fi
    pass "precheck cluster OK before test"

    # Scale to same size (no-op) — should succeed
    helm upgrade "$rel" "$CHART_DIR" \
        --set mode=cluster \
        --set cluster.replicas=6 \
        --set auth.password=$PASS \
        -n $NAMESPACE --timeout 300s 2>&1 || { fail "precheck no-op scale (6->6)"; cleanup "$rel"; return; }
    pass "precheck no-op scale (6->6) passed"

    # Scale up to 8 — should succeed (not a scale-down)
    helm upgrade "$rel" "$CHART_DIR" \
        --set mode=cluster \
        --set cluster.replicas=8 \
        --set auth.password=$PASS \
        -n $NAMESPACE --timeout 300s 2>&1 || { fail "precheck scale-up (6->8)"; cleanup "$rel"; return; }
    pass "precheck scale-up (6->8) passed"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 8 300s; then
        pass "precheck 8 pods ready"
    else
        fail "precheck 8 pods ready"; cleanup "$rel"; return
    fi

    # Wait for scale job
    sleep 15

    # Scale down 8->6 with replicasPerPrimary=1: 6/(1+1)=3 masters — should pass
    helm upgrade "$rel" "$CHART_DIR" \
        --set mode=cluster \
        --set cluster.replicas=6 \
        --set auth.password=$PASS \
        -n $NAMESPACE --timeout 300s 2>&1 || { fail "precheck safe scale-down (8->6)"; cleanup "$rel"; return; }
    pass "precheck safe scale-down (8->6) passed"

    cleanup "$rel"
}

# --- Feature #17: Password rotation deployment test ---

test_password_rotation() {
    bold "=== TEST: Password rotation without restart ==="
    local rel="t-passrot"
    cleanup "$rel"

    # Deploy standalone with password rotation enabled
    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set auth.passwordRotation.enabled=true \
        --set auth.passwordRotation.interval=5 \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "rotation install"; cleanup "$rel"; return; }
    pass "rotation install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1 120s; then
        pass "rotation pod ready"
    else
        fail "rotation pod ready"; cleanup "$rel"; return
    fi

    # Verify sidecar is running
    local containers=$(kubectl get pod ${rel}-percona-valkey-0 -n $NAMESPACE -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
    if echo "$containers" | grep -q "password-watcher"; then
        pass "rotation sidecar running"
    else
        fail "rotation sidecar running"; cleanup "$rel"; return
    fi

    # Verify ping works with current password
    local ping=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -c valkey -- sh -c "valkey-cli -a \$(cat /opt/valkey/secrets/valkey-password) ping" 2>/dev/null)
    if [ "$ping" = "PONG" ]; then
        pass "rotation initial ping works"
    else
        fail "rotation initial ping works (got: $ping)"; cleanup "$rel"; return
    fi

    # Rotate the password by updating the Secret
    local new_pass="rotated-pass-$(date +%s)"
    local new_pass_b64=$(echo -n "$new_pass" | base64)
    kubectl patch secret ${rel}-percona-valkey -n $NAMESPACE \
        -p "{\"data\":{\"valkey-password\":\"$new_pass_b64\"}}" 2>/dev/null || { fail "rotation patch secret"; cleanup "$rel"; return; }
    pass "rotation secret patched"

    # Wait for Kubernetes Secret file propagation (kubelet sync can take 60-90s) + sidecar detect
    sleep 90

    # Verify ping works with new password
    ping=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -c valkey -- sh -c "valkey-cli -a \$(cat /opt/valkey/secrets/valkey-password) ping" 2>/dev/null)
    if [ "$ping" = "PONG" ]; then
        pass "rotation ping works after rotation"
    else
        fail "rotation ping works after rotation (got: $ping)"
    fi

    # Verify old password no longer works
    local old_ping=$(kubectl exec ${rel}-percona-valkey-0 -n $NAMESPACE -c valkey -- sh -c "valkey-cli -a '$PASS' ping" 2>/dev/null)
    if echo "$old_ping" | grep -q "NOAUTH\|ERR\|WRONGPASS"; then
        pass "rotation old password rejected"
    else
        # If PONG, rotation failed
        if [ "$old_ping" = "PONG" ]; then
            fail "rotation old password rejected (still works)"
        else
            pass "rotation old password rejected"
        fi
    fi

    cleanup "$rel"
}

test_backup_cronjob() {
    bold "=== TEST: Backup CronJob ==="
    local rel="t-backup"
    cleanup "$rel"

    # Deploy standalone with backup enabled
    helm install "$rel" "$CHART_DIR" \
        --set auth.password=$PASS \
        --set backup.enabled=true \
        --set 'backup.schedule=*/2 * * * *' \
        --set backup.retention=3 \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "backup install"; cleanup "$rel"; return; }
    pass "backup install"

    if wait_for_pods "app.kubernetes.io/instance=$rel" 1 120s; then
        pass "backup pod ready"
    else
        fail "backup pod ready"; cleanup "$rel"; return
    fi

    # Verify CronJob exists
    if kubectl get cronjob ${rel}-percona-valkey-backup -n $NAMESPACE > /dev/null 2>&1; then
        pass "backup CronJob exists"
    else
        fail "backup CronJob exists"; cleanup "$rel"; return
    fi

    # Verify backup PVC exists
    if kubectl get pvc ${rel}-percona-valkey-backup -n $NAMESPACE > /dev/null 2>&1; then
        pass "backup PVC exists"
    else
        fail "backup PVC exists"; cleanup "$rel"; return
    fi

    # Manually trigger a Job from the CronJob
    kubectl create job ${rel}-backup-manual --from=cronjob/${rel}-percona-valkey-backup -n $NAMESPACE 2>&1 || { fail "backup manual trigger"; cleanup "$rel"; return; }
    pass "backup manual trigger"

    # Wait for Job completion
    local deadline=$(( $(date +%s) + 120 ))
    local job_done=false
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local status=$(kubectl get job ${rel}-backup-manual -n $NAMESPACE -o jsonpath='{.status.succeeded}' 2>/dev/null)
        if [ "$status" = "1" ]; then
            job_done=true
            break
        fi
        # Check for failure
        local failed=$(kubectl get job ${rel}-backup-manual -n $NAMESPACE -o jsonpath='{.status.failed}' 2>/dev/null)
        if [ "${failed:-0}" -ge 3 ]; then
            echo "    Backup job failed. Logs:"
            kubectl logs job/${rel}-backup-manual -n $NAMESPACE 2>/dev/null || true
            break
        fi
        sleep 5
    done

    if [ "$job_done" = "true" ]; then
        pass "backup job completed"
    else
        fail "backup job completed"
        kubectl logs job/${rel}-backup-manual -n $NAMESPACE 2>/dev/null || true
        cleanup "$rel"; return
    fi

    # Verify backup file exists on PVC by checking job logs
    local logs=$(kubectl logs job/${rel}-backup-manual -n $NAMESPACE 2>/dev/null)
    if echo "$logs" | grep -q "Backup successful"; then
        pass "backup file created"
    else
        fail "backup file created"
    fi

    cleanup "$rel"
    kubectl delete job ${rel}-backup-manual -n $NAMESPACE 2>/dev/null || true
}

# --- Sentinel Deployment Tests ---

test_sentinel_rpm() {
    bold "=== TEST: Sentinel RPM ==="
    local rel="sentinel-rpm"
    local fullname="${rel}-percona-valkey"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set mode=sentinel \
        --set auth.password=$PASS \
        --set sentinel.replicas=3 \
        --set sentinel.sentinelReplicas=3 \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "sentinel rpm install"; cleanup "$rel"; return; }
    pass "sentinel rpm install"

    # Verify 3 data pods running
    if wait_for_pods "app.kubernetes.io/instance=$rel,app.kubernetes.io/name=percona-valkey" 3; then
        pass "sentinel 3 data pods running"
    else
        fail "sentinel 3 data pods running"
    fi

    # Verify 3 sentinel pods running
    if wait_for_pods "app.kubernetes.io/instance=$rel,app.kubernetes.io/component=sentinel" 3; then
        pass "sentinel 3 sentinel pods running"
    else
        fail "sentinel 3 sentinel pods running"
    fi

    # Wait for sentinel topology to stabilize and replication to establish
    sleep 10

    # Query sentinel for master
    local master_info
    master_info=$(kubectl exec -n $NAMESPACE ${fullname}-sentinel-0 -- valkey-cli -p 26379 -a $PASS SENTINEL get-master-addr-by-name mymaster 2>/dev/null)
    if echo "$master_info" | grep -q "6379"; then
        pass "sentinel reports master on port 6379"
    else
        fail "sentinel reports master on port 6379"
    fi

    # Find the actual master pod via role check
    local master_pod=""
    local replica_pod=""
    for i in 0 1 2; do
        local r
        r=$(kubectl exec -n $NAMESPACE ${fullname}-$i -- valkey-cli -a $PASS role 2>/dev/null | head -1)
        if echo "$r" | grep -qi "^master"; then
            master_pod="${fullname}-$i"
        elif [ -z "$replica_pod" ]; then
            replica_pod="${fullname}-$i"
        fi
    done
    if [ -z "$master_pod" ]; then
        master_pod="${fullname}-0"
    fi
    if [ -z "$replica_pod" ]; then
        replica_pod="${fullname}-1"
    fi

    # Wait for replicas to connect to master
    local repl_ok=false
    for attempt in $(seq 1 15); do
        local connected
        connected=$(kubectl exec -n $NAMESPACE $master_pod -- valkey-cli -a $PASS info replication 2>/dev/null | grep "connected_slaves:" | tr -d '\r' | cut -d: -f2)
        if [ "${connected:-0}" -ge 2 ]; then
            repl_ok=true
            break
        fi
        sleep 2
    done
    if [ "$repl_ok" = "true" ]; then
        pass "sentinel 2 replicas connected"
    else
        fail "sentinel 2 replicas connected (got: ${connected:-0})"
    fi

    # Ping test
    if kubectl exec -n $NAMESPACE $master_pod -- valkey-cli -a $PASS ping 2>/dev/null | grep -q "PONG"; then
        pass "sentinel valkey-cli ping"
    else
        fail "sentinel valkey-cli ping"
    fi

    # Set/get test (write to actual master)
    local set_result
    set_result=$(kubectl exec -n $NAMESPACE $master_pod -- valkey-cli -a $PASS set sentinel-test "hello" 2>/dev/null)
    if echo "$set_result" | grep -q "OK"; then
        local val
        val=$(kubectl exec -n $NAMESPACE $master_pod -- valkey-cli -a $PASS get sentinel-test 2>/dev/null)
        if echo "$val" | grep -q "hello"; then
            pass "sentinel set/get data"
        else
            fail "sentinel set/get data (set OK but get returned: $val)"
        fi
    else
        fail "sentinel set/get data (set on $master_pod returned: $set_result)"
    fi

    # Verify at least one replica exists
    local role
    role=$(kubectl exec -n $NAMESPACE $replica_pod -- valkey-cli -a $PASS role 2>/dev/null | head -1)
    if echo "$role" | grep -qi "slave\|replica"; then
        pass "sentinel replica found"
    else
        fail "sentinel replica found"
    fi

    # Sentinel service exists
    if kubectl get svc ${fullname}-sentinel -n $NAMESPACE > /dev/null 2>&1; then
        pass "sentinel service exists"
    else
        fail "sentinel service exists"
    fi

    # Helm test
    if helm test "$rel" -n $NAMESPACE --timeout 60s > /dev/null 2>&1; then
        pass "sentinel helm test"
    else
        fail "sentinel helm test"
    fi

    cleanup "$rel"
}

test_sentinel_failover() {
    bold "=== TEST: Sentinel failover ==="
    local rel="sentinel-fo"
    local fullname="${rel}-percona-valkey"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set mode=sentinel \
        --set auth.password=$PASS \
        --set sentinel.replicas=3 \
        --set sentinel.sentinelReplicas=3 \
        --set sentinel.downAfterMilliseconds=5000 \
        --set sentinel.failoverTimeout=10000 \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "sentinel failover install"; cleanup "$rel"; return; }
    pass "sentinel failover install"

    if wait_for_pods "app.kubernetes.io/instance=$rel,app.kubernetes.io/component=sentinel" 3; then
        pass "sentinel failover 3 sentinel pods running"
    else
        fail "sentinel failover 3 sentinel pods running"
        cleanup "$rel"
        return
    fi

    if wait_for_pods "app.kubernetes.io/instance=$rel,app.kubernetes.io/name=percona-valkey" 3; then
        pass "sentinel failover 3 data pods running"
    else
        fail "sentinel failover 3 data pods running"
        cleanup "$rel"
        return
    fi

    # Wait for sentinel topology to stabilize
    sleep 10

    # Find the actual master pod and wait for replicas to connect
    local master_pod=""
    for i in 0 1 2; do
        local r
        r=$(kubectl exec -n $NAMESPACE ${fullname}-$i -- valkey-cli -a $PASS role 2>/dev/null | head -1)
        if echo "$r" | grep -qi "^master"; then
            master_pod="${fullname}-$i"
            break
        fi
    done
    if [ -z "$master_pod" ]; then
        master_pod="${fullname}-0"
    fi

    # Wait for replication to be fully established
    for attempt in $(seq 1 15); do
        local connected
        connected=$(kubectl exec -n $NAMESPACE $master_pod -- valkey-cli -a $PASS info replication 2>/dev/null | grep "connected_slaves:" | tr -d '\r' | cut -d: -f2)
        [ "${connected:-0}" -ge 2 ] && break
        sleep 2
    done

    # Write data to master and verify SET succeeded
    local set_result
    set_result=$(kubectl exec -n $NAMESPACE $master_pod -- valkey-cli -a $PASS set failover-test "survived" 2>/dev/null)
    if echo "$set_result" | grep -q "OK"; then
        pass "sentinel failover write data to $master_pod"
    else
        fail "sentinel failover write data to $master_pod (set returned: $set_result)"
        cleanup "$rel"
        return
    fi

    # Wait for the write to replicate
    sleep 3

    # Delete the master pod
    kubectl delete pod $master_pod -n $NAMESPACE --grace-period=0 --force > /dev/null 2>&1 || true
    pass "sentinel failover deleted $master_pod"

    # Wait for all 3 data pods to recover
    sleep 15
    if wait_for_pods "app.kubernetes.io/instance=$rel,app.kubernetes.io/name=percona-valkey" 3 300s; then
        pass "sentinel failover pods recovered"
    else
        fail "sentinel failover pods recovered"
        cleanup "$rel"
        return
    fi

    # Wait for sentinel to complete failover
    sleep 15

    # Verify data survived — try all pods since master changed
    local data_found=false
    for i in 0 1 2; do
        local val
        val=$(kubectl exec -n $NAMESPACE ${fullname}-$i -- valkey-cli -a $PASS get failover-test 2>/dev/null || true)
        if echo "$val" | grep -q "survived"; then
            data_found=true
            break
        fi
    done
    if [ "$data_found" = "true" ]; then
        pass "sentinel failover data survived"
    else
        fail "sentinel failover data survived"
    fi

    cleanup "$rel"
}

test_sentinel_hardened() {
    bold "=== TEST: Sentinel Hardened ==="
    if [ "$SKIP_HARDENED" = "true" ]; then
        skip "sentinel hardened (SKIP_HARDENED=true)"
        return
    fi
    local rel="sentinel-hrd"
    local fullname="${rel}-percona-valkey"
    cleanup "$rel"

    helm install "$rel" "$CHART_DIR" \
        --set mode=sentinel \
        --set image.variant=hardened \
        --set auth.password=$PASS \
        --set sentinel.replicas=3 \
        --set sentinel.sentinelReplicas=3 \
        -n $NAMESPACE --wait --timeout $TIMEOUT 2>&1 || { fail "sentinel hardened install"; cleanup "$rel"; return; }
    pass "sentinel hardened install"

    # Verify 3 sentinel pods running
    if wait_for_pods "app.kubernetes.io/instance=$rel,app.kubernetes.io/component=sentinel" 3; then
        pass "sentinel hardened 3 sentinel pods running"
    else
        fail "sentinel hardened 3 sentinel pods running"
    fi

    # Verify 3 data pods running
    if wait_for_pods "app.kubernetes.io/instance=$rel,app.kubernetes.io/name=percona-valkey" 3; then
        pass "sentinel hardened 3 data pods running"
    else
        fail "sentinel hardened 3 data pods running"; cleanup "$rel"; return
    fi

    # Find the actual master pod
    local master_pod=""
    for i in 0 1 2; do
        local r
        r=$(kubectl exec -n $NAMESPACE ${fullname}-$i -- valkey-cli -a $PASS role 2>/dev/null | head -1)
        if echo "$r" | grep -qi "^master"; then
            master_pod="${fullname}-$i"
            break
        fi
    done
    if [ -z "$master_pod" ]; then
        master_pod="${fullname}-0"
    fi

    # Ping
    if kubectl exec -n $NAMESPACE $master_pod -- valkey-cli -a $PASS ping 2>/dev/null | grep -q PONG; then
        pass "sentinel hardened valkey-cli ping"
    else
        fail "sentinel hardened valkey-cli ping"
    fi

    # Set/Get
    kubectl exec -n $NAMESPACE $master_pod -- valkey-cli -a $PASS set shrd-key shrd-value > /dev/null 2>&1
    local val=$(kubectl exec -n $NAMESPACE $master_pod -- valkey-cli -a $PASS get shrd-key 2>/dev/null)
    if echo "$val" | grep -q "shrd-value"; then
        pass "sentinel hardened set/get"
    else
        fail "sentinel hardened set/get (got: $val)"
    fi

    # Verify hardened security context on data pod
    local ro=$(kubectl get pod ${fullname}-0 -n $NAMESPACE -o jsonpath='{.spec.containers[?(@.name=="valkey")].securityContext.readOnlyRootFilesystem}' 2>/dev/null)
    if [ "$ro" = "true" ]; then
        pass "sentinel hardened data pod readOnlyRootFilesystem"
    else
        fail "sentinel hardened data pod readOnlyRootFilesystem (got: $ro)"
    fi

    # Verify hardened security context on sentinel pod
    local sro=$(kubectl get pod ${fullname}-sentinel-0 -n $NAMESPACE -o jsonpath='{.spec.containers[?(@.name=="sentinel")].securityContext.readOnlyRootFilesystem}' 2>/dev/null)
    if [ "$sro" = "true" ]; then
        pass "sentinel hardened sentinel pod readOnlyRootFilesystem"
    else
        fail "sentinel hardened sentinel pod readOnlyRootFilesystem (got: $sro)"
    fi

    # Helm test
    if helm test "$rel" -n $NAMESPACE --timeout 60s > /dev/null 2>&1; then
        pass "sentinel hardened helm test"
    else
        fail "sentinel hardened helm test"
    fi

    cleanup "$rel"
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
    test_tls_standalone
    echo ""
    test_tls_plaintext_disabled
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
    test_extra_init_containers
    echo ""
    test_extra_containers
    echo ""
    test_anti_affinity_preset
    echo ""
    test_termination_grace_period
    echo ""
    test_priority_class
    echo ""
    test_topology_spread
    echo ""
    test_read_service
    echo ""
    test_dns_config
    echo ""
    test_runtime_class
    echo ""
    test_acl_standalone
    echo ""
    test_cluster_precheck
    echo ""
    test_password_rotation
    echo ""
    test_backup_cronjob
    echo ""
    test_sentinel_rpm
    echo ""
    test_sentinel_failover
    echo ""
    test_sentinel_hardened
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
