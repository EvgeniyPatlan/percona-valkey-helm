# Percona Valkey Helm Chart — Comprehensive Documentation

## Table of Contents

1. [Introduction](#1-introduction)
2. [Architecture Overview](#2-architecture-overview)
3. [Deployment Modes](#3-deployment-modes)
4. [Features Reference](#4-features-reference)
5. [Configuration Reference](#5-configuration-reference)
6. [Helper Templates Reference](#6-helper-templates-reference)
7. [Installation & Usage Guide](#7-installation--usage-guide)
8. [Operations Guide](#8-operations-guide)
9. [Test Suite Documentation](#9-test-suite-documentation)
10. [Troubleshooting](#10-troubleshooting)
11. [Known Limitations](#11-known-limitations)

---

## 1. Introduction

### What is Percona Valkey?

[Valkey](https://github.com/valkey-io/valkey) is a high-performance, open-source key-value store that is fully compatible with the Redis protocol. It was forked from Redis after the Redis license change and is maintained by the Linux Foundation. Valkey supports data structures such as strings, hashes, lists, sets, sorted sets, bitmaps, HyperLogLogs, geospatial indexes, and streams.

**Percona Valkey** is Percona's enterprise-grade distribution of Valkey, providing production-ready container images built on Red Hat UBI 9, along with hardened (distroless) image variants for security-sensitive environments.

### What This Helm Chart Provides

This Helm chart deploys Percona Valkey on Kubernetes with full production readiness:

- **Three deployment modes:** Standalone, Cluster (hash-slot sharding), and Sentinel (automatic failover)
- **Enterprise security:** Authentication, ACL (multi-user access control), TLS/SSL with cert-manager integration, password rotation
- **High availability:** Automatic failover, pod disruption budgets, graceful failover hooks
- **Observability:** Prometheus metrics exporter, ServiceMonitor, PodMonitor, PrometheusRule
- **Operations:** Scheduled backups, rolling restarts on config change, horizontal and vertical autoscaling
- **Hardened images:** Read-only root filesystem, dropped capabilities, minimal attack surface

### Chart Metadata

| Field | Value |
|-------|-------|
| **Chart Name** | `percona-valkey` |
| **Chart Version** | `0.1.0` |
| **App Version** | `9.0.3` |
| **API Version** | `v2` |
| **Type** | `application` |
| **Home** | https://www.percona.com/software/percona-valkey |
| **Maintainer** | Percona (info@percona.com) |
| **Sources** | [valkey-packaging](https://github.com/EvgeniyPatlan/valkey-packaging), [valkey](https://github.com/valkey-io/valkey) |
| **Keywords** | valkey, cache, key-value, percona, database |

---

## 2. Architecture Overview

### Chart File Structure

```
percona-valkey-helm/
  helm/percona-valkey/
    Chart.yaml                          # Chart metadata
    values.yaml                         # Default configuration values
    .helmignore                         # Files to ignore during packaging
    test-chart.sh                       # Comprehensive test suite (5000+ lines)
    templates/
      _helpers.tpl                      # 20 named template helpers
      NOTES.txt                         # Post-install instructions
      # --- Core Resources ---
      statefulset.yaml                  # Main Valkey StatefulSet (standalone/cluster/sentinel data)
      configmap.yaml                    # Valkey configuration (valkey.conf)
      secret.yaml                       # Password and ACL secrets
      service.yaml                      # Main ClusterIP/LoadBalancer/NodePort service
      service-headless.yaml             # Headless service for pod DNS discovery
      service-read.yaml                 # Read-only load-balanced service
      service-metrics.yaml              # Metrics exporter service
      service-per-pod.yaml              # Per-pod services for cluster external access
      # --- Sentinel Resources ---
      sentinel-statefulset.yaml         # Sentinel monitor StatefulSet
      sentinel-configmap.yaml           # Sentinel configuration (sentinel.conf)
      sentinel-service.yaml             # Sentinel ClusterIP service
      sentinel-headless-service.yaml    # Sentinel headless service
      # --- Cluster Jobs ---
      cluster-init-job.yaml             # Post-install: cluster creation
      cluster-precheck-job.yaml         # Pre-upgrade: scale-down safety validation
      cluster-scale-job.yaml            # Post-upgrade: add/remove nodes
      # --- Security & RBAC ---
      serviceaccount.yaml               # ServiceAccount for Valkey pods
      role.yaml                         # Role/ClusterRole for external access
      rolebinding.yaml                  # RoleBinding/ClusterRoleBinding
      networkpolicy.yaml                # Network isolation rules
      certificate.yaml                  # cert-manager Certificate resource
      # --- Scaling ---
      hpa.yaml                          # Horizontal Pod Autoscaler
      vpa.yaml                          # Vertical Pod Autoscaler
      pdb.yaml                          # Pod Disruption Budget
      # --- Monitoring ---
      servicemonitor.yaml               # Prometheus ServiceMonitor
      podmonitor.yaml                   # Prometheus PodMonitor
      prometheusrule.yaml               # Prometheus alerting rules
      # --- Backup ---
      backup-cronjob.yaml               # Scheduled RDB backup CronJob
      backup-pvc.yaml                   # Backup storage PVC
      # --- Testing ---
      tests/
        test-connection.yaml            # Helm test hook pod
```

**Total: 31 template files** (including `_helpers.tpl`, `NOTES.txt`, and `serviceaccount.yaml`)

### Image Variants

| Variant | Base Image | Tag Format | Description |
|---------|-----------|------------|-------------|
| **RPM** (default) | Red Hat UBI 9 | `9.0.3` | Full OS with shell tools (`sh`, `grep`, `awk`). Used for all modes and all Jobs. |
| **Hardened** | Distroless (DHI) | `9.0.3-hardened` | Minimal image with no shell, no package manager. Read-only root filesystem enforced. |

### Image Resolution Logic

The chart resolves the container image tag based on the `image.variant` setting:

- **RPM variant** (`image.variant: rpm`): `perconalab/valkey:9.0.3`
- **Hardened variant** (`image.variant: hardened`): `perconalab/valkey:9.0.3-hardened`
- **Jobs** (cluster-init, cluster-scale, cluster-precheck, backup, test-connection): Always use the RPM image regardless of variant, because they require shell tools. Customizable via `image.jobs.repository` and `image.jobs.tag` for air-gapped environments.

---

## 3. Deployment Modes

The chart supports three deployment modes, selected via the `mode` parameter.

### 3.1 Standalone Mode (`mode: standalone`)

**Default mode.** Deploys a single Valkey instance or a primary with read replicas.

#### Architecture

```
                    ┌─────────────────┐
                    │   Service (CIP)  │
                    │   port: 6379     │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  StatefulSet     │
                    │  (OrderedReady)  │
                    │                  │
                    │  ┌────────────┐  │
                    │  │   pod-0    │  │
                    │  │  (primary) │  │
                    │  └────────────┘  │
                    │                  │
                    │  When replicas>1:│
                    │  ┌────────────┐  │
                    │  │   pod-1    │  │
                    │  │  (replica) │  │
                    │  └────────────┘  │
                    └─────────────────┘
```

#### Key Characteristics

| Property | Value |
|----------|-------|
| **Default replicas** | 1 |
| **Pod management** | OrderedReady (sequential rollout) |
| **Startup command** | `valkey-server /etc/valkey/valkey.conf` (args-based) |
| **Read service** | Created when `standalone.replicas > 1` (also created in sentinel mode when `sentinel.replicas > 1`) |
| **HPA support** | Yes (standalone-only feature) |
| **PDB** | Not created (standalone has no HA topology) |

#### How It Works

1. The StatefulSet creates pods sequentially (OrderedReady).
2. Pod-0 starts as a standalone Valkey server using the ConfigMap-based `valkey.conf`.
3. If `standalone.replicas > 1`, additional pods start but do NOT automatically replicate — they are independent instances suitable for read scaling behind a read service.
4. Authentication is handled via `VALKEY_PASSWORD` environment variable (from Secret) or password files.
5. A separate read service (`<fullname>-read`) is created when multiple replicas exist to distribute read traffic.

### 3.2 Cluster Mode (`mode: cluster`)

Native Valkey Cluster with hash-slot sharding across multiple primary nodes.

#### Architecture

```
                ┌─────────────────────┐
                │  Headless Service    │
                │  (pod discovery)     │
                └──────────┬──────────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
   ┌────▼────┐       ┌────▼────┐       ┌────▼────┐
   │  pod-0  │       │  pod-1  │       │  pod-2  │
   │ Primary │       │ Primary │       │ Primary │
   │ 0-5460  │       │ 5461-   │       │ 10923-  │
   │         │       │ 10922   │       │ 16383   │
   └────┬────┘       └────┬────┘       └────┬────┘
        │                  │                  │
   ┌────▼────┐       ┌────▼────┐       ┌────▼────┐
   │  pod-3  │       │  pod-4  │       │  pod-5  │
   │ Replica │       │ Replica │       │ Replica │
   │ of 0    │       │ of 1    │       │ of 2    │
   └─────────┘       └─────────┘       └─────────┘

   ←── cluster-bus port (16379) interconnect ──→
```

#### Key Characteristics

| Property | Value |
|----------|-------|
| **Default replicas** | 6 (3 primaries + 3 replicas) |
| **Replicas per primary** | 1 |
| **Pod management** | Parallel (all pods start simultaneously) |
| **Bus port** | 16379 (cluster gossip protocol) |
| **Node timeout** | 15000ms |
| **Hash slots** | 16384 (automatically distributed) |

#### Cluster Lifecycle — Helm Hook Jobs

The cluster lifecycle is managed by three Helm hook Jobs:

**1. cluster-init (post-install, weight 5)**
- Runs after initial `helm install`
- Waits for all pods to respond to PING
- Checks idempotency: skips if cluster already formed (`cluster_state:ok`)
- Executes `valkey-cli --cluster create` with `--cluster-replicas` flag
- `backoffLimit: 6`, `restartPolicy: OnFailure`

**2. cluster-precheck (pre-upgrade, weight 0)**
- Runs before `helm upgrade` (only when `cluster.precheckBeforeScaleDown: true`)
- **Check 1:** Cluster must be healthy (`cluster_state:ok`)
- **Check 2:** Minimum 3 masters after scale-down: `DESIRED / (1 + REPLICAS_PER_PRIMARY) >= 3`
- **Check 3:** No data loss — each master being removed must have a healthy replica
- Passes through (exits 0, allowing upgrade to proceed) on fresh install (no reachable nodes), cluster not yet formed, or scale-up operations (desired >= current)
- `backoffLimit: 0`, `restartPolicy: Never` — fails immediately on unsafe scale-down

**3. cluster-scale (post-upgrade, weight 5)**
- Runs after `helm upgrade`
- **Scale-up:** Adds new pods to cluster, converts excess masters to replicas (targets masters with fewest replicas), rebalances hash slots
- **Scale-down:** Waits for automatic failover (NODE_TIMEOUT + 15s), forgets dead nodes from all live nodes, uses `--cluster fix` as fallback, rebalances
- **Idempotency:** If cluster is not formed (initial cluster-init failed), performs full cluster creation
- `backoffLimit: 3`, `restartPolicy: OnFailure`

#### Readiness Probe (Cluster-Specific)

In cluster mode, the readiness probe checks `cluster_state:ok` instead of a simple PING:

```sh
response=$(valkey-cli cluster info)
case "$response" in *cluster_state:ok*) exit 0;; *) exit 1;; esac
```

This ensures pods are not marked Ready until the cluster is fully formed.

#### Cluster Announce IP

For internal cluster communication, each pod announces its IP via the Kubernetes Downward API:

```yaml
env:
  - name: POD_IP
    valueFrom:
      fieldRef:
        fieldPath: status.podIP
  - name: VALKEY_EXTRA_FLAGS
    value: "--cluster-announce-ip $(POD_IP)"
```

For external access, the `discover-external-ip` init container discovers the LoadBalancer IP or NodePort and writes it to shared volume files.

#### Graceful Failover (Cluster preStop Hook)

When a cluster pod is terminated, the preStop hook performs graceful failover:

1. Check if the pod is a primary (`valkey-cli role`)
2. If primary: execute `valkey-cli cluster failover`
3. Wait up to 10 seconds for role change to replica
4. Execute `valkey-cli shutdown nosave`

This ensures zero-downtime rolling updates by demoting the primary before shutdown.

### 3.3 Sentinel Mode (`mode: sentinel`)

Sentinel provides automatic failover monitoring with a master-replica topology.

#### Architecture

```
        ┌──────────────────────────────────────────┐
        │          Sentinel StatefulSet             │
        │          (Parallel, 3 pods)               │
        │                                          │
        │  ┌──────────┐ ┌──────────┐ ┌──────────┐ │
        │  │sentinel-0│ │sentinel-1│ │sentinel-2│ │
        │  │ :26379   │ │ :26379   │ │ :26379   │ │
        │  └────┬─────┘ └────┬─────┘ └────┬─────┘ │
        └───────┼────────────┼────────────┼────────┘
                │   monitor  │            │
                └──────┬─────┘────────────┘
                       │
        ┌──────────────▼───────────────────────────┐
        │          Data StatefulSet                 │
        │          (OrderedReady, 3 pods)           │
        │                                          │
        │  ┌──────────┐ ┌──────────┐ ┌──────────┐ │
        │  │  pod-0   │ │  pod-1   │ │  pod-2   │ │
        │  │ (master) │ │(replica) │ │(replica) │ │
        │  │          │ │replicaof │ │replicaof │ │
        │  │          │ │  pod-0   │ │  pod-0   │ │
        │  └──────────┘ └──────────┘ └──────────┘ │
        └──────────────────────────────────────────┘
```

#### Key Characteristics

| Property | Value |
|----------|-------|
| **Data replicas** | 3 (1 master + 2 replicas) |
| **Sentinel replicas** | 3 (must be odd, minimum 3) |
| **Sentinel port** | 26379 |
| **Master set name** | `mymaster` |
| **Quorum** | 2 |
| **Down-after** | 30000ms |
| **Failover timeout** | 180000ms |
| **Parallel syncs** | 1 |

#### Two StatefulSets

**Data StatefulSet** (`<fullname>`)
- Pod management: OrderedReady
- Pod-0 always starts as master
- Pods 1..N start with `--replicaof <pod-0-fqdn> 6379` (ordinal-based)
- Uses the main ConfigMap for valkey.conf
- Supports graceful failover via preStop hook

**Sentinel StatefulSet** (`<fullname>-sentinel`)
- Pod management: Parallel
- Two init containers:
  1. **wait-for-master:** Polls pod-0 until it responds to PING (or NOAUTH)
  2. **sentinel-init:** Copies base sentinel.conf from ConfigMap to `/data/sentinel.conf`, then appends `sentinel auth-pass <masterSet> <password>` and `requirepass <password>` directives when authentication is enabled. This happens automatically — no manual auth configuration is needed for Sentinel.
- Main container runs `valkey-server /data/sentinel.conf --sentinel`
- Fixed liveness/readiness probes (10s/5s intervals)
- Supports password files: reads from `VALKEY_PASSWORD_FILE` when `auth.usePasswordFiles` or `auth.passwordRotation` is enabled

#### Sentinel Configuration

The sentinel ConfigMap includes:

```
sentinel monitor mymaster <pod-0-fqdn> 6379 2
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel down-after-milliseconds mymaster 30000
sentinel failover-timeout mymaster 180000
sentinel parallel-syncs mymaster 1
```

Key features:
- `resolve-hostnames yes` and `announce-hostnames yes` enable DNS-based hostname resolution within Kubernetes
- Auth credentials are injected at runtime by the sentinel-init init container

#### Sentinel Services

| Service | Type | Purpose |
|---------|------|---------|
| `<fullname>-sentinel` | ClusterIP | Client queries for current master |
| `<fullname>-sentinel-headless` | Headless | Pod DNS discovery |

#### Graceful Failover (Sentinel preStop Hook)

When a data pod in sentinel mode is terminated:

1. Check if the pod is the master (`valkey-cli role`)
2. If master: request failover via `valkey-cli -h <sentinel-svc> SENTINEL FAILOVER mymaster`
3. Wait up to 10 seconds for role change
4. Execute `valkey-cli shutdown nosave`

---

## 4. Features Reference

### 4.1 Authentication

The chart provides flexible password authentication for Valkey.

#### Password Sources (priority order)

1. **Explicit password** (`auth.password`): Provided directly in values; base64-encoded into the Secret
2. **Existing Secret** (`auth.existingSecret`): References a pre-created Secret with key `valkey-password`; no chart-managed Secret is created
3. **Preserved on upgrade**: Uses Helm's `lookup` function to check for an existing Secret and preserves its password across `helm upgrade`
4. **Auto-generated**: If none of the above, generates a random 16-character alphanumeric password

#### Password File Mode

When `auth.usePasswordFiles: true`:
- Password is mounted as a file at `<passwordFilePath>/valkey-password` (default: `/opt/valkey/secrets/valkey-password`)
- `VALKEY_PASSWORD_FILE` environment variable is set instead of `VALKEY_PASSWORD`
- More secure than environment variables (not visible in `kubectl describe pod`)

#### Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `auth.enabled` | `true` | Enable password authentication |
| `auth.password` | `""` | Explicit password (auto-generated if empty) |
| `auth.existingSecret` | `""` | Name of existing Secret (key: `valkey-password`) |
| `auth.usePasswordFiles` | `false` | Mount password as file |
| `auth.passwordFilePath` | `/opt/valkey/secrets` | Directory for password file |

### 4.2 ACL (Access Control List)

Multi-user authentication with per-user command and key restrictions. **Requires `auth.enabled: true`.** The default user password is still managed by the `auth.password` parameter.

#### How It Works

1. When `acl.enabled: true`, the chart adds `aclfile /etc/valkey/acl/users.acl` to valkey.conf
2. The ACL file is mounted from a Secret — either an existing Secret (`acl.existingSecret`) or the **same chart-managed Secret** that holds the password (key: `users.acl`)
3. The **default user** line is auto-generated: `user default on ><password> ~* &* +@all`
4. Custom user rules from `acl.users` are appended after the default user

#### Example

```yaml
auth:
  enabled: true
  password: "mypass"
acl:
  enabled: true
  users: |
    user app on >apppass ~cache:* +@read +@write -@dangerous
    user monitor on >monpass +client +info +slowlog +latency +ping
```

This creates three users:
- `default`: Full access with password `mypass`
- `app`: Read/write access only to keys matching `cache:*`, no dangerous commands
- `monitor`: Read-only monitoring commands

#### Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `acl.enabled` | `false` | Enable ACL |
| `acl.existingSecret` | `""` | Existing Secret with `users.acl` key |
| `acl.users` | `""` | Inline ACL rules (appended after auto-generated default user) |

### 4.3 TLS/SSL

Full TLS/SSL encryption for client connections, replication, and cluster communication.

#### Dual-Port Mode (Default)

By default, TLS runs alongside plaintext:
- Plaintext port: 6379
- TLS port: 6380 (configurable)

#### Plaintext Disabled Mode

When `tls.disablePlaintext: true`, the plaintext port is set to 0 in valkey.conf, forcing all connections through TLS.

#### TLS in valkey.conf

```
tls-port 6380
tls-cert-file /etc/valkey/tls/tls.crt
tls-key-file /etc/valkey/tls/tls.key
tls-ca-cert-file /etc/valkey/tls/ca.crt
tls-auth-clients no
```

Additional directives are added based on mode:
- **Cluster mode:** `tls-cluster yes` (encrypts cluster bus traffic)
- **Sentinel mode:** `tls-replication yes` (encrypts replication traffic)
- **Replication enabled:** `tls-replication yes`

#### TLS-Aware Components

All chart components support TLS when enabled:
- Health probes (liveness, readiness, startup)
- Graceful failover preStop hooks
- Cluster Jobs (init, precheck, scale)
- Backup CronJob
- Test connection pod
- Metrics exporter (uses `rediss://` protocol)
- Sentinel init containers and probes

#### Certificate Sources

1. **Existing Secret** (`tls.existingSecret`): Must contain keys `tls.crt`, `tls.key`, `ca.crt`
2. **cert-manager** (`tls.certManager.enabled`): Automatically creates a Certificate resource

#### Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `tls.enabled` | `false` | Enable TLS |
| `tls.port` | `6380` | TLS port |
| `tls.existingSecret` | `""` | Existing TLS Secret |
| `tls.certMountPath` | `/etc/valkey/tls` | Certificate mount path |
| `tls.replication` | `false` | TLS for replication |
| `tls.authClients` | `"no"` | Client cert requirement: `yes`, `no`, `optional` |
| `tls.disablePlaintext` | `false` | Disable plaintext port |
| `tls.ciphers` | `""` | TLS 1.2 cipher suites |
| `tls.ciphersuites` | `""` | TLS 1.3 cipher suites |

### 4.4 cert-manager Integration

Automatic TLS certificate lifecycle management via cert-manager.

#### Certificate Resource

When enabled, the chart creates a `Certificate` custom resource:
- **Secret name:** `<fullname>-tls`
- **Private key:** RSA 2048-bit
- **Usages:** server auth, client auth
- **Duration:** 2160h (90 days)
- **Renew before:** 360h (15 days)

#### DNS SANs (Subject Alternative Names)

The certificate includes comprehensive DNS names:

```
<fullname>
<fullname>.<namespace>
<fullname>.<namespace>.svc
<fullname>.<namespace>.svc.cluster.local
<fullname>-headless
<fullname>-headless.<namespace>
<fullname>-headless.<namespace>.svc
<fullname>-headless.<namespace>.svc.cluster.local
*.<fullname>-headless.<namespace>.svc.cluster.local
localhost
```

In sentinel mode, additional SANs are added for sentinel services:
```
<fullname>-sentinel
<fullname>-sentinel-headless
*.<fullname>-sentinel-headless.<namespace>.svc.cluster.local
```

#### Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `tls.certManager.enabled` | `false` | Enable cert-manager integration |
| `tls.certManager.issuerRef.name` | `""` | Issuer name |
| `tls.certManager.issuerRef.kind` | `Issuer` | Issuer or ClusterIssuer |
| `tls.certManager.issuerRef.group` | `cert-manager.io` | API group |
| `tls.certManager.duration` | `2160h` | Certificate duration |
| `tls.certManager.renewBefore` | `360h` | Renew before expiry |
| `tls.certManager.additionalDnsNames` | `[]` | Extra DNS names |

### 4.5 Password Rotation

Hot-reload password changes without restarting Valkey pods.

#### How It Works

1. A `password-watcher` sidecar container is added to each Valkey pod
2. The sidecar polls the password file at a configurable interval
3. When a change is detected:
   - Authenticates with the **old** password
   - Executes `CONFIG SET requirepass <new-password>`
   - Executes `CONFIG SET masterauth <new-password>`
   - If ACL is enabled: `ACL SETUSER default on resetpass ><new-password> ~* &* +@all`
   - Verifies the new password works with PING
4. Falls back to authenticating with the new password if the old one already expired

#### Prerequisites

- `auth.enabled: true`
- `auth.passwordRotation.enabled: true`
- Password rotation implicitly enables `auth.usePasswordFiles: true`

#### Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `auth.passwordRotation.enabled` | `false` | Enable password rotation sidecar |
| `auth.passwordRotation.interval` | `10` | Poll interval in seconds |
| `auth.passwordRotation.resources` | `{}` | Sidecar CPU/memory resources |

### 4.6 Backup & Restore

Scheduled RDB backups via Kubernetes CronJob.

#### Backup Process

1. CronJob creates a pod on schedule (default: 2 AM daily)
2. Pod connects to a specific Valkey pod (by ordinal) via headless service
3. When TLS is enabled, the backup automatically uses the TLS port and TLS CLI flags instead of the plaintext port
4. Executes `valkey-cli -h <host> -p <port> [TLS flags] --rdb /backup/dump-<timestamp>.rdb`
5. Verifies backup file is non-empty
6. Applies retention: keeps last N backups, deletes older ones
7. Backup files are stored on a dedicated PVC

#### Backup Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `backup.enabled` | `false` | Enable backup CronJob |
| `backup.schedule` | `"0 2 * * *"` | Cron schedule |
| `backup.retention` | `7` | Number of backups to retain |
| `backup.concurrencyPolicy` | `Forbid` | Skip if previous still running |
| `backup.sourceOrdinal` | `0` | Pod ordinal to backup from |
| `backup.storage.storageClass` | `""` | Storage class for backup PVC |
| `backup.storage.size` | `10Gi` | Backup PVC size |
| `backup.storage.accessModes` | `[ReadWriteOnce]` | PVC access modes |
| `backup.storage.existingClaim` | `""` | Use existing PVC |
| `backup.resources` | `{}` | Backup container resources |
| `backup.successfulJobsHistoryLimit` | `3` | Successful job history |
| `backup.failedJobsHistoryLimit` | `1` | Failed job history |

#### Restore Procedure

See [Operations Guide — Backup & Restore](#84-backup--restore-step-by-step) for detailed instructions.

### 4.7 External Access

Expose Valkey to clients outside the Kubernetes cluster. External access is supported in **standalone** and **cluster** modes. Sentinel mode does not support external access or per-pod services.

#### Standalone External Access

Changes the main service type to LoadBalancer or NodePort:

```yaml
externalAccess:
  enabled: true
  service:
    type: LoadBalancer  # or NodePort
```

Supports `loadBalancerIP`, `nodePort`, `loadBalancerSourceRanges`, and `externalTrafficPolicy`.

#### Cluster External Access

Creates per-pod services for each cluster node, plus an init container for IP discovery:

1. **Per-pod services:** One Service per pod (`<fullname>-0`, `<fullname>-1`, etc.) with type LoadBalancer or NodePort
2. **discover-external-ip init container:** Queries the Kubernetes API to discover the assigned external IP/NodePort
3. **cluster-announce flags:** The main container reads the discovered IP/port and passes `--cluster-announce-ip`, `--cluster-announce-port`, `--cluster-announce-bus-port`
4. **RBAC:** A Role (LoadBalancer) or ClusterRole (NodePort) is created for API access

#### Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `externalAccess.enabled` | `false` | Enable external access |
| `externalAccess.service.type` | `LoadBalancer` | Service type |
| `externalAccess.service.port` | `6379` | External port |
| `externalAccess.service.annotations` | `{}` | Service annotations |
| `externalAccess.service.loadBalancerSourceRanges` | `[]` | Source IP restrictions |
| `externalAccess.service.externalTrafficPolicy` | `Cluster` | Traffic policy |
| `externalAccess.standalone.nodePort` | `0` | Fixed NodePort (standalone) |
| `externalAccess.standalone.loadBalancerIP` | `""` | Fixed LB IP (standalone) |
| `externalAccess.cluster.nodePorts` | `[]` | Per-pod NodePorts (by ordinal) |
| `externalAccess.cluster.loadBalancerIPs` | `[]` | Per-pod LB IPs (by ordinal) |

### 4.8 Graceful Failover

Zero-downtime pod termination via preStop lifecycle hooks.

#### Cluster Mode

```sh
# 1. Check role
ROLE=$(valkey-cli $AUTH role)
case "$ROLE" in
  master*)
    # 2. Trigger failover
    valkey-cli $AUTH cluster failover
    # 3. Wait for demotion (up to 10s)
    while [ $i -lt 20 ]; do
      NEWROLE=$(valkey-cli $AUTH role)
      case "$NEWROLE" in slave*|replica*) break;; esac
      sleep 0.5
    done
    ;;
esac
# 4. Shutdown
valkey-cli $AUTH shutdown nosave || true
```

#### Sentinel Mode

```sh
# 1. Check role
ROLE=$(valkey-cli $AUTH role)
case "$ROLE" in
  master*)
    # 2. Request failover via Sentinel
    valkey-cli -h <sentinel-svc> SENTINEL FAILOVER mymaster || true
    # 3. Wait for demotion (up to 10s)
    ...
    ;;
esac
# 4. Shutdown
valkey-cli $AUTH shutdown nosave || true
```

Both hooks:
- Poll every 0.5 seconds for up to 20 iterations (10-second timeout) waiting for demotion
- Support TLS flags (`-p <tls-port> --tls --cacert ... --cert ... --key ...`) when `tls.disablePlaintext` is enabled
- Support password rotation (`cat <password-file>`) or standard `$VALKEY_PASSWORD` env var
- Use only shell builtins (`case`/`esac`) for pattern matching, making them compatible with hardened images
- End with `shutdown nosave` to prevent unnecessary disk writes during planned termination

User-defined `lifecycle` hooks override the built-in graceful failover.

### 4.9 Hardened Images

Security-hardened container configuration for the distroless image variant.

#### Security Measures

When `image.variant: hardened`:

| Feature | Setting |
|---------|---------|
| `readOnlyRootFilesystem` | `true` |
| `allowPrivilegeEscalation` | `false` |
| `capabilities.drop` | `[ALL]` |
| `/tmp` | tmpfs (memory-backed emptyDir) |
| `/run/valkey` | tmpfs (memory-backed emptyDir) |

These settings are **hardcoded** for the hardened variant and override any `containerSecurityContext` values.

#### Job Images

Jobs (cluster-init, cluster-scale, cluster-precheck, backup, test-connection) **always use the RPM image** regardless of `image.variant`, because they require shell tools (`sh`, `grep`, `awk`, `valkey-cli`).

### 4.10 Monitoring

Prometheus-compatible metrics via the Redis exporter sidecar.

#### Metrics Exporter

When `metrics.enabled: true`, an `oliver006/redis_exporter` sidecar container is added to each pod:
- Default image: `oliver006/redis_exporter:v1.67.0`
- Metrics port: 9121
- Connects to Valkey via `redis://localhost:{service.port}` (default 6379) or `rediss://localhost:{tls.port}` (default 6380) with TLS
- Authenticates via `REDIS_PASSWORD` environment variable
- TLS: Mounts CA certificate via `REDIS_EXPORTER_TLS_CA_CERT_FILE` for verification

#### ServiceMonitor

Creates a Prometheus Operator ServiceMonitor for automatic scrape configuration:

```yaml
metrics:
  serviceMonitor:
    enabled: true
    namespace: ""          # Target namespace (default: release namespace)
    interval: 30s          # Scrape interval
    scrapeTimeout: ""      # Scrape timeout
    labels: {}             # Additional labels
```

#### PodMonitor

Alternative to ServiceMonitor for pod-level metrics:

```yaml
metrics:
  podMonitor:
    enabled: true
    namespace: ""
    interval: 30s
    labels: {}
```

#### PrometheusRule

Defines alerting rules:

```yaml
metrics:
  prometheusRule:
    enabled: true
    rules:
      - alert: ValkeyDown
        expr: redis_up == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Valkey instance {{ $labels.instance }} is down"
```

### 4.11 Autoscaling

#### Horizontal Pod Autoscaler (Standalone Only)

```yaml
autoscaling:
  hpa:
    enabled: true
    minReplicas: 1
    maxReplicas: 5
    targetCPU: 80
    targetMemory: ""
```

HPA is only supported in standalone mode because cluster and sentinel modes have topology constraints. For advanced use cases, `customMetrics` can be provided to override the default CPU/memory targets with custom Prometheus-based metrics.

#### Vertical Pod Autoscaler

```yaml
autoscaling:
  vpa:
    enabled: true
    updateMode: "Auto"      # Off, Initial, Auto
    controlledResources:
      - cpu
      - memory
    minAllowed: {}
    maxAllowed: {}
```

VPA is supported in all modes.

### 4.12 PodDisruptionBudget

Created only for cluster and sentinel modes:

```yaml
pdb:
  enabled: true
  minAvailable: ""       # Takes precedence over maxUnavailable
  maxUnavailable: 1      # Default
```

Not created for standalone mode (no HA topology to protect).

### 4.13 Network Policy

Restricts ingress and egress traffic:

```yaml
networkPolicy:
  enabled: true
  allowExternal: true      # Allow traffic from outside the namespace
  extraIngress: []         # Additional ingress rules
  extraEgress: []          # Additional egress rules
```

#### Ports opened by mode:
- **All modes:** 6379 (valkey), TLS port (if enabled), 9121 (if metrics enabled)
- **Cluster:** 16379 (cluster bus)
- **Sentinel:** 26379 (sentinel)

### 4.14 Disabled Commands

Dangerous commands are renamed to empty string (disabled) in valkey.conf:

```yaml
disableCommands:
  - FLUSHDB
  - FLUSHALL
```

Per-mode overrides replace the default list entirely:

```yaml
disableCommandsStandalone: []       # No commands disabled in standalone
disableCommandsCluster:
  - FLUSHDB
  - FLUSHALL
  - CLUSTER RESET
disableCommandsSentinel:
  - FLUSHDB
```

### 4.15 Sysctl Tuning & Volume Permissions

#### Sysctl Init Container

Privileged init container for kernel tuning:

```yaml
sysctlInit:
  enabled: true
  somaxconn: 512           # net.core.somaxconn
  disableTHP: true         # Disable Transparent Huge Pages
  resources: {}
```

Runs as root with `privileged: true`.

#### Volume Permissions

Fixes PVC ownership:

```yaml
volumePermissions:
  enabled: true
  resources: {}
```

Runs `chown -R 999:999 /data` as root.

### 4.16 Diagnostic Mode

Overrides the container entrypoint for debugging:

```yaml
diagnosticMode:
  enabled: true
  command:
    - sleep
  args:
    - infinity
```

When enabled:
- All health probes are effectively bypassed (container runs sleep, not valkey)
- Pod starts but Valkey server does not run
- Useful for debugging container issues without CrashLoopBackOff

### 4.17 Extensibility

#### Extra Init Containers

```yaml
extraInitContainers:
  - name: my-init
    image: busybox
    command: ["sh", "-c", "echo init"]
```

#### Extra Sidecar Containers

```yaml
extraContainers:
  - name: log-tailer
    image: busybox
    command: ["sh", "-c", "tail -f /data/appendonly.aof"]
    volumeMounts:
      - name: data
        mountPath: /data
```

#### Extra Volumes and Mounts

```yaml
extraVolumes:
  - name: scratch
    emptyDir:
      medium: Memory
extraVolumeMounts:
  - name: scratch
    mountPath: /scratch
```

#### Extra Environment Variables

```yaml
extraEnvVars:
  - name: MY_CUSTOM_VAR
    value: "hello-world"
```

### 4.18 Pod Scheduling

```yaml
nodeSelector:
  disktype: ssd

tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "valkey"
    effect: "NoSchedule"

affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: topology.kubernetes.io/zone
              operator: In
              values: ["us-east-1a"]
```

#### Anti-Affinity Presets

```yaml
podAntiAffinityPreset:
  type: "soft"    # "soft" or "hard"
  topologyKey: "kubernetes.io/hostname"
```

- **soft:** `preferredDuringSchedulingIgnoredDuringExecution` (weight 100)
- **hard:** `requiredDuringSchedulingIgnoredDuringExecution`
- Ignored when `affinity` is set explicitly

Sentinel pods have their own anti-affinity preset:

```yaml
sentinel:
  podAntiAffinityPreset:
    type: "soft"
    topologyKey: "kubernetes.io/hostname"
```

#### Topology Spread Constraints

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: "topology.kubernetes.io/zone"
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: percona-valkey
```

#### Priority Class

```yaml
priorityClassName: "high-priority"
```

### 4.19 PVC Retention Policy

Controls what happens to PVCs when the StatefulSet is deleted or scaled down (requires Kubernetes 1.27+):

```yaml
persistentVolumeClaimRetentionPolicy:
  whenDeleted: Retain    # Retain or Delete
  whenScaled: Retain     # Retain or Delete
```

---

## 5. Configuration Reference

### Global Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `nameOverride` | string | `""` | Override chart name |
| `fullnameOverride` | string | `""` | Override full resource name |
| `mode` | string | `"standalone"` | Deployment mode: `standalone`, `cluster`, `sentinel` |

### Image Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `image.repository` | string | `"perconalab/valkey"` | Container image repository |
| `image.variant` | string | `"rpm"` | Image variant: `rpm` (UBI9) or `hardened` (distroless) |
| `image.tag` | string | `""` | Image tag (default: appVersion or appVersion-hardened) |
| `image.pullPolicy` | string | `"IfNotPresent"` | Image pull policy |
| `image.pullSecrets` | list | `[]` | Image pull secrets |
| `image.jobs.repository` | string | `""` | Job image repository override |
| `image.jobs.tag` | string | `""` | Job image tag override |

### Authentication

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `auth.enabled` | bool | `true` | Enable password authentication |
| `auth.password` | string | `""` | Valkey password (auto-generated if empty) |
| `auth.existingSecret` | string | `""` | Existing Secret name (key: `valkey-password`) |
| `auth.usePasswordFiles` | bool | `false` | Mount password as file |
| `auth.passwordFilePath` | string | `"/opt/valkey/secrets"` | Password file directory |
| `auth.passwordRotation.enabled` | bool | `false` | Enable password rotation sidecar |
| `auth.passwordRotation.interval` | int | `10` | Poll interval in seconds |
| `auth.passwordRotation.resources` | object | `{}` | Sidecar resources |

### ACL (Access Control List)

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `acl.enabled` | bool | `false` | Enable ACL |
| `acl.existingSecret` | string | `""` | Existing Secret with `users.acl` key |
| `acl.users` | string | `""` | Inline ACL rules |

### TLS/SSL Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `tls.enabled` | bool | `false` | Enable TLS |
| `tls.port` | int | `6380` | TLS port |
| `tls.existingSecret` | string | `""` | Existing TLS Secret |
| `tls.certMountPath` | string | `"/etc/valkey/tls"` | Certificate mount path |
| `tls.replication` | bool | `false` | TLS for replication traffic |
| `tls.authClients` | string | `"no"` | Client cert requirement |
| `tls.disablePlaintext` | bool | `false` | Disable non-TLS port |
| `tls.ciphers` | string | `""` | TLS 1.2 cipher suites |
| `tls.ciphersuites` | string | `""` | TLS 1.3 cipher suites |
| `tls.certManager.enabled` | bool | `false` | Enable cert-manager |
| `tls.certManager.issuerRef.name` | string | `""` | Issuer name |
| `tls.certManager.issuerRef.kind` | string | `"Issuer"` | Issuer kind |
| `tls.certManager.issuerRef.group` | string | `"cert-manager.io"` | API group |
| `tls.certManager.duration` | string | `"2160h"` | Certificate duration |
| `tls.certManager.renewBefore` | string | `"360h"` | Renew before expiry |
| `tls.certManager.additionalDnsNames` | list | `[]` | Extra DNS SANs |

### Valkey Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `config.maxmemory` | string | `""` | Max memory limit |
| `config.maxmemoryPolicy` | string | `""` | Eviction policy |
| `config.bind` | string | `"0.0.0.0"` | Bind address |
| `config.extraFlags` | string | `""` | Extra CLI flags via VALKEY_EXTRA_FLAGS |
| `config.customConfig` | string | `""` | Custom valkey.conf content |

### Cluster Mode Settings

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `cluster.replicas` | int | `6` | Total cluster nodes |
| `cluster.replicasPerPrimary` | int | `1` | Replicas per primary |
| `cluster.nodeTimeout` | int | `15000` | Node timeout in ms |
| `cluster.busPort` | int | `16379` | Cluster bus port |
| `cluster.precheckBeforeScaleDown` | bool | `true` | Enable pre-upgrade safety check |

### Standalone Mode Settings

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `standalone.replicas` | int | `1` | Number of Valkey instances |

### Sentinel Mode Settings

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `sentinel.replicas` | int | `3` | Data pods (1 master + N-1 replicas) |
| `sentinel.sentinelReplicas` | int | `3` | Sentinel monitor pods |
| `sentinel.port` | int | `26379` | Sentinel port |
| `sentinel.masterSet` | string | `"mymaster"` | Master set name |
| `sentinel.quorum` | int | `2` | Quorum for failover |
| `sentinel.downAfterMilliseconds` | int | `30000` | Master unreachable timeout |
| `sentinel.failoverTimeout` | int | `180000` | Failover timeout |
| `sentinel.parallelSyncs` | int | `1` | Parallel sync count |
| `sentinel.resources` | object | `{}` | Sentinel pod resources |
| `sentinel.persistence.enabled` | bool | `false` | Sentinel persistence |
| `sentinel.persistence.size` | string | `"1Gi"` | Sentinel PVC size |
| `sentinel.podAntiAffinityPreset.type` | string | `""` | Anti-affinity type |
| `sentinel.podAntiAffinityPreset.topologyKey` | string | `"kubernetes.io/hostname"` | Topology key |
| `sentinel.podAnnotations` | object | `{}` | Sentinel pod annotations |
| `sentinel.podLabels` | object | `{}` | Sentinel pod labels |
| `sentinel.nodeSelector` | object | `{}` | Sentinel node selector |
| `sentinel.tolerations` | list | `[]` | Sentinel tolerations |
| `sentinel.affinity` | object | `{}` | Sentinel affinity |

### StatefulSet Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `statefulset.updateStrategy.type` | string | `"RollingUpdate"` | Update strategy |
| `statefulset.podManagementPolicy` | string | `""` | Override pod management (auto: Parallel for cluster, OrderedReady for others) |
| `statefulset.annotations` | object | `{}` | StatefulSet annotations |
| `statefulset.labels` | object | `{}` | StatefulSet labels |

### Pod Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `podAnnotations` | object | `{}` | Pod annotations |
| `podLabels` | object | `{}` | Pod labels |

### Security Context

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `securityContext.runAsUser` | int | `999` | Pod-level UID |
| `securityContext.runAsGroup` | int | `999` | Pod-level GID |
| `securityContext.fsGroup` | int | `999` | Pod-level fsGroup |
| `securityContext.runAsNonRoot` | bool | `true` | Enforce non-root |
| `containerSecurityContext.readOnlyRootFilesystem` | bool | `false` | Read-only root FS |
| `containerSecurityContext.allowPrivilegeEscalation` | bool | `false` | Prevent privilege escalation |
| `containerSecurityContext.capabilities.drop` | list | `["ALL"]` | Drop Linux capabilities |

### Service Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `service.type` | string | `"ClusterIP"` | Service type |
| `service.port` | int | `6379` | Service port |
| `service.annotations` | object | `{}` | Service annotations |

### Persistence

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `persistence.enabled` | bool | `true` | Enable persistent storage |
| `persistence.storageClass` | string | `""` | Storage class |
| `persistence.accessModes` | list | `["ReadWriteOnce"]` | Access modes |
| `persistence.size` | string | `"8Gi"` | PVC size |
| `persistence.annotations` | object | `{}` | PVC annotations |

### Health Probes

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `livenessProbe.enabled` | bool | `true` | Enable liveness probe |
| `livenessProbe.initialDelaySeconds` | int | `20` | Initial delay |
| `livenessProbe.periodSeconds` | int | `10` | Check interval |
| `livenessProbe.timeoutSeconds` | int | `5` | Timeout |
| `livenessProbe.failureThreshold` | int | `6` | Failures before restart |
| `livenessProbe.successThreshold` | int | `1` | Successes to pass |
| `readinessProbe.enabled` | bool | `true` | Enable readiness probe |
| `readinessProbe.initialDelaySeconds` | int | `10` | Initial delay |
| `readinessProbe.periodSeconds` | int | `10` | Check interval |
| `readinessProbe.timeoutSeconds` | int | `3` | Timeout |
| `readinessProbe.failureThreshold` | int | `3` | Failures before unready |
| `readinessProbe.successThreshold` | int | `1` | Successes to pass |
| `startupProbe.enabled` | bool | `true` | Enable startup probe |
| `startupProbe.initialDelaySeconds` | int | `5` | Initial delay |
| `startupProbe.periodSeconds` | int | `5` | Check interval |
| `startupProbe.timeoutSeconds` | int | `3` | Timeout |
| `startupProbe.failureThreshold` | int | `30` | Max failures (30 * 5s = 150s startup budget) |

### Resources

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `resources.limits` | object | `{}` | CPU/memory limits |
| `resources.requests` | object | `{}` | CPU/memory requests |
| `resourcePreset` | string | `"none"` | Preset: `none`, `nano`, `micro`, `small`, `medium`, `large`, `xlarge` |

#### Resource Presets

| Preset | CPU Request | Memory Request | CPU Limit | Memory Limit |
|--------|------------|----------------|-----------|-------------|
| `nano` | 100m | 128Mi | 250m | 256Mi |
| `micro` | 250m | 256Mi | 500m | 512Mi |
| `small` | 500m | 512Mi | 1 | 1Gi |
| `medium` | 1 | 1Gi | 2 | 2Gi |
| `large` | 2 | 2Gi | 4 | 4Gi |
| `xlarge` | 4 | 4Gi | 8 | 8Gi |

Explicit `resources.limits`/`resources.requests` always override presets.

### ServiceAccount

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `serviceAccount.create` | bool | `true` | Create ServiceAccount |
| `serviceAccount.name` | string | `""` | ServiceAccount name (default: fullname) |
| `serviceAccount.annotations` | object | `{}` | ServiceAccount annotations |
| `serviceAccount.automountServiceAccountToken` | bool | `false` | Auto-mount token (forced `true` for external access) |

### Pod Disruption Budget

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `pdb.enabled` | bool | `true` | Enable PDB (cluster/sentinel only) |
| `pdb.minAvailable` | string | `""` | Minimum available pods |
| `pdb.maxUnavailable` | int | `1` | Maximum unavailable pods |

### External Access

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `externalAccess.enabled` | bool | `false` | Enable external access |
| `externalAccess.service.type` | string | `"LoadBalancer"` | Service type |
| `externalAccess.service.port` | int | `6379` | External port |
| `externalAccess.service.annotations` | object | `{}` | Service annotations |
| `externalAccess.service.loadBalancerSourceRanges` | list | `[]` | Source IP restrictions |
| `externalAccess.service.externalTrafficPolicy` | string | `"Cluster"` | Traffic policy |
| `externalAccess.standalone.nodePort` | int | `0` | Standalone NodePort |
| `externalAccess.standalone.tlsNodePort` | int | `0` | Standalone TLS NodePort |
| `externalAccess.standalone.loadBalancerIP` | string | `""` | Standalone LoadBalancer IP |
| `externalAccess.cluster.annotations` | object | `{}` | Per-pod service annotations |
| `externalAccess.cluster.nodePorts` | list | `[]` | Per-pod NodePorts |
| `externalAccess.cluster.tlsNodePorts` | list | `[]` | Per-pod TLS NodePorts |
| `externalAccess.cluster.busNodePorts` | list | `[]` | Per-pod bus NodePorts |
| `externalAccess.cluster.loadBalancerIPs` | list | `[]` | Per-pod LoadBalancer IPs |

### Network Policy

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `networkPolicy.enabled` | bool | `false` | Enable NetworkPolicy |
| `networkPolicy.allowExternal` | bool | `true` | Allow external traffic |
| `networkPolicy.extraIngress` | list | `[]` | Additional ingress rules |
| `networkPolicy.extraEgress` | list | `[]` | Additional egress rules |

### Init Containers

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `sysctlInit.enabled` | bool | `false` | Enable sysctl init container |
| `sysctlInit.somaxconn` | int | `512` | net.core.somaxconn value |
| `sysctlInit.disableTHP` | bool | `true` | Disable Transparent Huge Pages |
| `sysctlInit.resources` | object | `{}` | Init container resources |
| `volumePermissions.enabled` | bool | `false` | Enable volume-permissions init |
| `volumePermissions.resources` | object | `{}` | Init container resources |

### Metrics (Prometheus Exporter)

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `metrics.enabled` | bool | `false` | Enable metrics exporter |
| `metrics.image.repository` | string | `"oliver006/redis_exporter"` | Exporter image |
| `metrics.image.tag` | string | `"v1.67.0"` | Exporter version |
| `metrics.image.pullPolicy` | string | `"IfNotPresent"` | Pull policy |
| `metrics.port` | int | `9121` | Metrics port |
| `metrics.resources` | object | `{}` | Exporter resources |
| `metrics.serviceMonitor.enabled` | bool | `false` | Enable ServiceMonitor |
| `metrics.serviceMonitor.namespace` | string | `""` | ServiceMonitor namespace |
| `metrics.serviceMonitor.interval` | string | `"30s"` | Scrape interval |
| `metrics.serviceMonitor.scrapeTimeout` | string | `""` | Scrape timeout |
| `metrics.serviceMonitor.labels` | object | `{}` | ServiceMonitor labels |
| `metrics.podMonitor.enabled` | bool | `false` | Enable PodMonitor |
| `metrics.podMonitor.namespace` | string | `""` | PodMonitor namespace |
| `metrics.podMonitor.interval` | string | `"30s"` | Scrape interval |
| `metrics.podMonitor.labels` | object | `{}` | PodMonitor labels |
| `metrics.prometheusRule.enabled` | bool | `false` | Enable PrometheusRule |
| `metrics.prometheusRule.namespace` | string | `""` | PrometheusRule namespace |
| `metrics.prometheusRule.labels` | object | `{}` | PrometheusRule labels |
| `metrics.prometheusRule.rules` | list | `[]` | Alerting rules |

### Graceful Failover

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `gracefulFailover.enabled` | bool | `true` | Enable preStop failover hooks |

### Lifecycle Hooks

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `lifecycle` | object | `{}` | Custom lifecycle hooks (overrides graceful failover) |

### Diagnostic Mode

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `diagnosticMode.enabled` | bool | `false` | Enable diagnostic mode |
| `diagnosticMode.command` | list | `["sleep"]` | Override command |
| `diagnosticMode.args` | list | `["infinity"]` | Override args |

### Disabled Commands

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `disableCommands` | list | `["FLUSHDB", "FLUSHALL"]` | Commands to disable |
| `disableCommandsStandalone` | list | (undefined) | Override for standalone mode |
| `disableCommandsCluster` | list | (undefined) | Override for cluster mode |
| `disableCommandsSentinel` | list | (undefined) | Override for sentinel mode |

### Extensibility

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `extraInitContainers` | list | `[]` | Additional init containers |
| `extraContainers` | list | `[]` | Additional sidecar containers |
| `extraVolumes` | list | `[]` | Additional volumes |
| `extraVolumeMounts` | list | `[]` | Additional volume mounts |
| `extraEnvVars` | list | `[]` | Additional environment variables |

### Pod Scheduling

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `nodeSelector` | object | `{}` | Node selector |
| `tolerations` | list | `[]` | Tolerations |
| `affinity` | object | `{}` | Affinity rules |
| `podAntiAffinityPreset.type` | string | `""` | Anti-affinity type: `soft` or `hard` |
| `podAntiAffinityPreset.topologyKey` | string | `"kubernetes.io/hostname"` | Topology key |
| `topologySpreadConstraints` | list | `[]` | Topology spread constraints |
| `priorityClassName` | string | `""` | Priority class name |
| `runtimeClassName` | string | `""` | Runtime class name |

### Termination & DNS

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `terminationGracePeriodSeconds` | int | `30` | Graceful shutdown timeout |
| `dnsPolicy` | string | `""` | DNS policy override |
| `dnsConfig` | object | `{}` | Custom DNS configuration |

### Autoscaling

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `autoscaling.hpa.enabled` | bool | `false` | Enable HPA (standalone only) |
| `autoscaling.hpa.minReplicas` | int | `1` | Min replicas |
| `autoscaling.hpa.maxReplicas` | int | `5` | Max replicas |
| `autoscaling.hpa.targetCPU` | int | `80` | Target CPU % |
| `autoscaling.hpa.targetMemory` | string | `""` | Target memory % |
| `autoscaling.hpa.customMetrics` | list | (undefined) | Custom metrics (overrides targetCPU/targetMemory when set) |
| `autoscaling.vpa.enabled` | bool | `false` | Enable VPA |
| `autoscaling.vpa.updateMode` | string | `"Auto"` | Update mode |
| `autoscaling.vpa.controlledResources` | list | `["cpu", "memory"]` | Controlled resources |
| `autoscaling.vpa.minAllowed` | object | `{}` | Min resource bounds |
| `autoscaling.vpa.maxAllowed` | object | `{}` | Max resource bounds |

### PVC Retention Policy

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `persistentVolumeClaimRetentionPolicy.whenDeleted` | string | `"Retain"` | Policy on delete |
| `persistentVolumeClaimRetentionPolicy.whenScaled` | string | `"Retain"` | Policy on scale-down |

### Backup

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `backup.enabled` | bool | `false` | Enable backup CronJob |
| `backup.schedule` | string | `"0 2 * * *"` | Cron schedule |
| `backup.retention` | int | `7` | Backups to retain |
| `backup.concurrencyPolicy` | string | `"Forbid"` | CronJob concurrency |
| `backup.sourceOrdinal` | int | `0` | Pod to backup from |
| `backup.storage.storageClass` | string | `""` | Backup storage class |
| `backup.storage.size` | string | `"10Gi"` | Backup PVC size |
| `backup.storage.accessModes` | list | `["ReadWriteOnce"]` | Access modes |
| `backup.storage.existingClaim` | string | `""` | Existing PVC name |
| `backup.resources` | object | `{}` | Backup container resources |
| `backup.successfulJobsHistoryLimit` | int | `3` | Successful job history |
| `backup.failedJobsHistoryLimit` | int | `1` | Failed job history |

---

## 6. Helper Templates Reference

The chart defines 20 named templates in `_helpers.tpl`:

| Template | Description | Usage |
|----------|-------------|-------|
| `percona-valkey.name` | Chart name (truncated to 63 chars). Uses `nameOverride` if set. | Labels, selectors |
| `percona-valkey.fullname` | Fully qualified app name (truncated to 63 chars). Uses `fullnameOverride`, or combines release name + chart name. | Resource names |
| `percona-valkey.chart` | Chart name + version string (e.g., `percona-valkey-0.1.0`). | `helm.sh/chart` label |
| `percona-valkey.labels` | Common labels: chart, selector labels, version, managed-by. | All resource metadata |
| `percona-valkey.selectorLabels` | Selector labels: `app.kubernetes.io/name` + `app.kubernetes.io/instance`. | StatefulSet selectors, services |
| `percona-valkey.image` | Resolves container image with tag based on variant. RPM: `repo:appVersion`, hardened: `repo:appVersion-hardened`. | StatefulSet, sentinel StatefulSet |
| `percona-valkey.rpmImage` | Always returns RPM variant image. Supports `image.jobs.repository` and `image.jobs.tag` overrides. | Jobs, init containers, test pod |
| `percona-valkey.serviceAccountName` | ServiceAccount name: fullname if created, `default` otherwise. | All pods |
| `percona-valkey.secretName` | Secret name: `auth.existingSecret` or fullname. | Password references |
| `percona-valkey.aclSecretName` | ACL Secret name: `acl.existingSecret` if provided, otherwise fullname (shares the main password Secret). | ACL volume mount |
| `percona-valkey.tlsSecretName` | TLS Secret name: `tls.existingSecret` or `<fullname>-tls`. | TLS volume mount, cert-manager |
| `percona-valkey.tlsCliFlags` | TLS CLI flags for valkey-cli: `--tls --cacert ... --cert ... --key ...`. Returns empty string if TLS disabled. | Probes, Jobs, lifecycle hooks |
| `percona-valkey.replicaCount` | Replica count based on mode: `cluster.replicas`, `sentinel.replicas`, or `standalone.replicas`. | StatefulSet spec |
| `percona-valkey.resourcePreset` | Returns resources dict for preset name (nano, micro, small, medium, large, xlarge). | Resource resolution |
| `percona-valkey.resources` | Resolves effective resources: explicit values override preset. | StatefulSet containers |
| `percona-valkey.podManagementPolicy` | Pod management: explicit override, or `Parallel` for cluster, `OrderedReady` for others. | StatefulSet spec |
| `percona-valkey.podAntiAffinity` | Generates anti-affinity rules from preset. Returns empty if type is empty or affinity is explicitly set. | StatefulSet pod spec |
| `percona-valkey.externalAccessEnabled` | Nil-safe check: returns `"true"` if `externalAccess.enabled`. | Conditional rendering |
| `percona-valkey.externalAccessCluster` | Returns `"true"` if external access enabled AND cluster mode. | Per-pod services, RBAC, init container |
| `percona-valkey.externalAccessStandalone` | Returns `"true"` if external access enabled AND standalone mode. | Main service type changes |

---

## 7. Installation & Usage Guide

### Prerequisites

- Kubernetes 1.23+ cluster
- Helm 3.x
- PersistentVolume provisioner (for persistence)
- cert-manager (optional, for TLS certificate automation)
- Prometheus Operator (optional, for ServiceMonitor/PodMonitor/PrometheusRule)
- metrics-server (optional, for HPA)
- VPA controller (optional, for VPA)

### Quick Start

#### Standalone Mode (Default)

```bash
helm install my-valkey ./helm/percona-valkey \
  --set auth.password="my-secure-password"
```

#### Cluster Mode

```bash
helm install my-valkey ./helm/percona-valkey \
  --set mode=cluster \
  --set auth.password="my-secure-password"
```

This creates a 6-node cluster (3 primaries + 3 replicas). The cluster-init Job automatically forms the cluster.

#### Sentinel Mode

```bash
helm install my-valkey ./helm/percona-valkey \
  --set mode=sentinel \
  --set auth.password="my-secure-password"
```

This creates 3 data pods (1 master + 2 replicas) and 3 sentinel monitors.

### Customization Examples

#### Enable TLS with cert-manager

```bash
helm install my-valkey ./helm/percona-valkey \
  --set auth.password="my-secure-password" \
  --set tls.enabled=true \
  --set tls.certManager.enabled=true \
  --set tls.certManager.issuerRef.name=my-issuer \
  --set tls.certManager.issuerRef.kind=ClusterIssuer
```

#### Enable TLS with Existing Secret

```bash
# Create the TLS secret first
kubectl create secret generic my-valkey-tls \
  --from-file=tls.crt=server.crt \
  --from-file=tls.key=server.key \
  --from-file=ca.crt=ca.crt

helm install my-valkey ./helm/percona-valkey \
  --set auth.password="my-secure-password" \
  --set tls.enabled=true \
  --set tls.existingSecret=my-valkey-tls
```

#### Enable ACL

```bash
helm install my-valkey ./helm/percona-valkey \
  --set auth.password="adminpass" \
  --set acl.enabled=true \
  --set 'acl.users=user app on >apppass ~cache:* +@read +@write -@dangerous'
```

#### Enable Backups

```bash
helm install my-valkey ./helm/percona-valkey \
  --set auth.password="my-secure-password" \
  --set backup.enabled=true \
  --set backup.schedule="0 */6 * * *" \
  --set backup.retention=14
```

#### Enable Metrics and Monitoring

```bash
helm install my-valkey ./helm/percona-valkey \
  --set auth.password="my-secure-password" \
  --set metrics.enabled=true \
  --set metrics.serviceMonitor.enabled=true
```

#### External Access (Standalone)

```bash
helm install my-valkey ./helm/percona-valkey \
  --set auth.password="my-secure-password" \
  --set externalAccess.enabled=true \
  --set externalAccess.service.type=LoadBalancer
```

#### External Access (Cluster)

```bash
helm install my-valkey ./helm/percona-valkey \
  --set mode=cluster \
  --set auth.password="my-secure-password" \
  --set externalAccess.enabled=true \
  --set externalAccess.service.type=LoadBalancer
```

#### Hardened Image

```bash
helm install my-valkey ./helm/percona-valkey \
  --set image.variant=hardened \
  --set auth.password="my-secure-password"
```

### Upgrade Operations

#### Upgrade with Config Change

```bash
helm upgrade my-valkey ./helm/percona-valkey \
  --set auth.password="my-secure-password" \
  --set config.maxmemory=256mb \
  --set config.maxmemoryPolicy=allkeys-lru
```

Config changes trigger a rolling restart via the `checksum/config` annotation.

#### Scale Cluster

```bash
# Scale up from 6 to 8 nodes
helm upgrade my-valkey ./helm/percona-valkey \
  --set mode=cluster \
  --set cluster.replicas=8

# Scale down from 8 to 6 nodes (precheck validates safety)
helm upgrade my-valkey ./helm/percona-valkey \
  --set mode=cluster \
  --set cluster.replicas=6
```

### How to Connect

#### From Inside the Cluster

```bash
# Get the password
export VALKEY_PASSWORD=$(kubectl get secret my-valkey -o jsonpath="{.data.valkey-password}" | base64 -d)

# Connect
kubectl exec -it my-valkey-0 -- valkey-cli -a "$VALKEY_PASSWORD" ping
```

#### From Outside the Cluster (External Access)

```bash
# LoadBalancer
export SERVICE_IP=$(kubectl get svc my-valkey -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
valkey-cli -h $SERVICE_IP -p 6379 -a "$VALKEY_PASSWORD"

# NodePort
export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
export NODE_PORT=$(kubectl get svc my-valkey -o jsonpath='{.spec.ports[?(@.name=="valkey")].nodePort}')
valkey-cli -h $NODE_IP -p $NODE_PORT -a "$VALKEY_PASSWORD"
```

---

## 8. Operations Guide

### 8.1 Get Password from Secret

```bash
# Chart-managed password
kubectl get secret <release-name> -o jsonpath="{.data.valkey-password}" | base64 -d

# Existing secret
kubectl get secret <secret-name> -o jsonpath="{.data.valkey-password}" | base64 -d
```

### 8.2 Check Cluster Status

```bash
# Cluster info
kubectl exec <release>-0 -- valkey-cli -a "$PASS" cluster info

# Cluster nodes
kubectl exec <release>-0 -- valkey-cli -a "$PASS" cluster nodes

# Key metrics to check:
# cluster_state:ok
# cluster_slots_ok:16384
# cluster_known_nodes:6
# cluster_size:3
```

### 8.3 Check Sentinel Status

```bash
# Query current master
kubectl exec <release>-sentinel-0 -- valkey-cli -p 26379 -a "$PASS" \
  SENTINEL get-master-addr-by-name mymaster

# Sentinel info
kubectl exec <release>-sentinel-0 -- valkey-cli -p 26379 -a "$PASS" \
  INFO sentinel

# Check replicas
kubectl exec <release>-sentinel-0 -- valkey-cli -p 26379 -a "$PASS" \
  SENTINEL replicas mymaster
```

### 8.4 Scale Up/Down Procedures

#### Cluster Scale-Up

```bash
# 1. Increase replicas (e.g., 6 -> 8)
helm upgrade my-valkey ./helm/percona-valkey \
  --set mode=cluster \
  --set cluster.replicas=8

# 2. The cluster-scale Job (post-upgrade hook) automatically:
#    - Waits for new pods
#    - Adds them to cluster
#    - Converts excess masters to replicas
#    - Rebalances hash slots
```

#### Cluster Scale-Down

```bash
# 1. The precheck Job validates safety:
#    - Minimum 3 masters after scale-down
#    - No data loss (masters have replicas for failover)
# 2. If precheck passes, the upgrade proceeds
helm upgrade my-valkey ./helm/percona-valkey \
  --set mode=cluster \
  --set cluster.replicas=6

# 3. The cluster-scale Job (post-upgrade hook) automatically:
#    - Waits for automatic failover
#    - Forgets dead nodes
#    - Rebalances remaining nodes
```

### 8.5 Password Rotation Step-by-Step

```bash
# 1. Deploy with password rotation enabled
helm install my-valkey ./helm/percona-valkey \
  --set auth.password="initial-password" \
  --set auth.passwordRotation.enabled=true

# 2. Rotate the password by patching the Secret
kubectl patch secret my-valkey -p \
  '{"data":{"valkey-password":"'"$(echo -n 'new-password' | base64)"'"}}'

# 3. Wait for propagation (default: 10 seconds poll interval)
# The password-watcher sidecar will:
#   - Detect the file change
#   - CONFIG SET requirepass <new>
#   - CONFIG SET masterauth <new>
#   - ACL SETUSER default (if ACL enabled)

# 4. Verify
kubectl exec my-valkey-0 -- valkey-cli -a "new-password" ping
```

### 8.6 Backup & Restore Step-by-Step

#### Manual Backup

```bash
# Trigger a backup manually
kubectl create job --from=cronjob/<release>-backup <release>-backup-manual

# Check backup status
kubectl logs -l job-name=<release>-backup-manual

# List existing backups
kubectl exec <backup-pod> -- ls -lh /backup/
```

#### Restore from Backup

```bash
# 1. Scale down the StatefulSet
kubectl scale statefulset <release> --replicas=0

# 2. Copy the RDB file to the data PVC
kubectl run restore-helper --image=perconalab/valkey:9.0.3 --restart=Never \
  --overrides='{
    "spec": {
      "volumes": [
        {"name": "data", "persistentVolumeClaim": {"claimName": "data-<release>-0"}},
        {"name": "backup", "persistentVolumeClaim": {"claimName": "<release>-backup"}}
      ],
      "containers": [{
        "name": "restore",
        "image": "perconalab/valkey:9.0.3",
        "command": ["sh", "-c", "cp /backup/<backup-file>.rdb /data/dump.rdb && chown 999:999 /data/dump.rdb"],
        "volumeMounts": [
          {"name": "data", "mountPath": "/data"},
          {"name": "backup", "mountPath": "/backup"}
        ]
      }]
    }
  }'

# 3. Wait for the restore helper to complete
kubectl wait --for=condition=Ready pod/restore-helper --timeout=60s
kubectl delete pod restore-helper

# 4. Scale back up
kubectl scale statefulset <release> --replicas=1
```

### 8.7 TLS Certificate Management

#### With cert-manager

Certificates are automatically renewed before expiry. Check certificate status:

```bash
kubectl get certificate <release>-tls
kubectl describe certificate <release>-tls
```

#### Manual Certificate Rotation

```bash
# Update the TLS secret
kubectl create secret generic <release>-tls \
  --from-file=tls.crt=new-server.crt \
  --from-file=tls.key=new-server.key \
  --from-file=ca.crt=new-ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -

# Trigger rolling restart
kubectl rollout restart statefulset <release>
```

### 8.8 NOTES.txt Output Explained

After `helm install`, the NOTES.txt output provides:

1. **Deployment summary:** Mode, node count, topology
2. **Connection instructions:** Mode-specific commands to connect via `valkey-cli`
3. **Password retrieval:** Command to get the password from the Secret
4. **External access info:** LoadBalancer IP or NodePort discovery commands
5. **Feature-specific notes:**
   - Password rotation: How to patch the Secret
   - ACL: How to connect as custom users
   - Backup: Schedule, retention, manual trigger, restore procedure
   - TLS: Port info, plaintext status, certificate source
6. **Helm test command:** `helm test <release>`

### 8.9 Running the Helm Test

```bash
helm test my-valkey
```

The test pod:
- Connects to the main service
- Executes `valkey-cli ping`
- Supports TLS: automatically uses TLS port and flags (`--tls --cacert ... --cert ... --key ...`) when `tls.enabled=true`
- Supports authentication: injects `VALKEY_PASSWORD` from the chart Secret
- Validates `PONG` response
- Uses the RPM image (respects `image.jobs.*` overrides)
- Auto-cleans up on success (`hook-delete-policy: before-hook-creation,hook-succeeded`)

---

## 9. Test Suite Documentation

The chart includes a comprehensive test suite in `test-chart.sh` (5000+ lines) covering lint tests, template rendering tests, and live deployment tests.

### 9.1 Test Framework Overview

#### Structure

```
test-chart.sh
  ├── Helper Functions
  │   ├── green(), red(), yellow(), bold()  — colored output
  │   ├── pass(), fail(), skip()            — test result tracking
  │   ├── wait_for_pods()                   — pod readiness polling
  │   └── cleanup()                         — release + PVC cleanup
  ├── Phase 1: Static Tests
  │   ├── test_lint()                       — helm lint validation
  │   └── test_template_render()            — helm template assertions
  └── Phase 2: Deployment Tests
      ├── Standalone tests
      ├── Cluster tests
      ├── Sentinel tests
      └── Feature-specific tests
```

#### Test Counters

- `TOTAL` — total tests executed
- `PASSED` — tests that passed
- `FAILED` — tests that failed (tracked in `FAILURES` string)
- `SKIPPED` — tests skipped (e.g., hardened tests when `SKIP_HARDENED=true`)

#### Key Helper Functions

**`wait_for_pods(label, count, timeout)`**
- Polls `kubectl get pods` with the given label selector
- Waits for `count` pods to show Ready status (1/1 or 2/2)
- Default timeout: 180 seconds
- Returns 0 on success, 1 on timeout

**`cleanup(release)`**
- `helm uninstall <release>` (ignores errors)
- Deletes PVCs matching the release label
- Waits up to 60 seconds for pods to terminate

#### Configuration

```bash
CHART_DIR="./helm/percona-valkey"
PASS="testpass123"
TIMEOUT="180s"
NAMESPACE="default"
SKIP_HARDENED="${SKIP_HARDENED:-false}"
```

### 9.2 Lint Tests (11 Tests)

Lint tests validate that `helm lint` passes for all supported configurations.

| # | Test Name | Configuration | Purpose |
|---|-----------|--------------|---------|
| 1 | lint standalone/rpm | Default values | Validates standalone RPM configuration |
| 2 | lint cluster/rpm | `mode=cluster` | Validates cluster configuration |
| 3 | lint standalone/hardened | `image.variant=hardened` | Validates hardened image settings |
| 4 | lint cluster/hardened | `mode=cluster, image.variant=hardened` | Validates cluster + hardened combination |
| 5 | lint standalone/acl | `acl.enabled=true` + inline users | Validates ACL configuration |
| 6 | lint cluster/acl | `mode=cluster, acl.enabled=true` | Validates cluster + ACL combination |
| 7 | lint password rotation | `auth.passwordRotation.enabled=true` | Validates password rotation configuration |
| 8 | lint cluster precheck | `mode=cluster, cluster.precheckBeforeScaleDown=true` | Validates precheck Job configuration |
| 9 | lint backup enabled | `backup.enabled=true` | Validates backup CronJob configuration |
| 10 | lint sentinel/rpm | `mode=sentinel` | Validates sentinel configuration |
| 11 | lint sentinel/hardened | `mode=sentinel, image.variant=hardened` | Validates sentinel + hardened combination |

### 9.3 Template Render Tests (~270 Assertions)

Template tests use `helm template` to render manifests and verify their contents with `grep`, `jq`, or string matching. They are organized by feature area.

#### Basic Rendering (3 tests)
- **template standalone default** — Basic rendering succeeds without errors
- **template cluster** — Cluster mode rendering succeeds
- **template metrics sidecar present** — redis_exporter container appears in StatefulSet when metrics enabled

#### Metrics & Monitoring (17 tests)
- Metrics service exists on port 9121
- ServiceMonitor, PodMonitor, PrometheusRule resources render correctly
- Custom image, pullPolicy, resources, port for exporter
- Custom namespace, interval, scrapeTimeout, labels for ServiceMonitor
- Custom namespace, interval, labels for PodMonitor
- Custom namespace, labels for PrometheusRule

#### Network Policy (6 tests)
- NetworkPolicy renders when enabled
- Cluster bus port (16379) included in cluster mode
- `allowExternal=false` restricts ingress to pod selector
- Extra ingress/egress rules rendered
- Metrics port (9121) included when metrics enabled

#### Init Containers (7 tests)
- sysctl-init container renders when enabled
- volume-permissions container renders when enabled
- Custom somaxconn value, THP disabling
- Custom resources for each init container
- Both init containers present simultaneously

#### Configuration & Commands (18 tests)
- Disabled commands (FLUSHDB, FLUSHALL) in ConfigMap
- Per-mode disabled command overrides
- Password file mounting (VALKEY_PASSWORD_FILE env)
- `automountServiceAccountToken: false`
- Resource presets (small, nano, micro, medium, large, xlarge, none)
- Explicit resources override preset
- Diagnostic mode (sleep infinity)
- Lifecycle hooks
- Extra env vars
- PVC retention policy
- Hardened image tag format
- Hardened security (readOnlyRootFilesystem + tmpfs)
- ConfigMap maxmemory, maxmemoryPolicy, bind
- Extra flags in VALKEY_EXTRA_FLAGS
- Custom config content

#### StatefulSet Metadata (4 tests)
- Pod annotations, pod labels
- StatefulSet annotations, StatefulSet labels

#### Node Placement (3 tests)
- nodeSelector, tolerations, affinity

#### StatefulSet Strategy (4 tests)
- Update strategy OnDelete
- Pod management policy defaults (OrderedReady for standalone, Parallel for cluster)
- Explicit pod management policy override

#### Service Configuration (3 tests)
- Service type NodePort
- Service annotations
- Headless service cluster-bus port in cluster mode

#### Persistence (3 tests)
- Persistence disabled (emptyDir fallback)
- Custom storageClass
- Custom PVC size

#### Security Context (5 tests)
- Custom runAsUser, runAsGroup, fsGroup
- runAsNonRoot default true
- Hardened allowPrivilegeEscalation + caps drop
- Custom containerSecurityContext.readOnlyRootFilesystem

#### Image Configuration (3 tests)
- Custom image tag, custom repository, imagePullSecrets

#### Naming (2 tests)
- nameOverride, fullnameOverride

#### Cluster-Specific (4 tests)
- Custom nodeTimeout in ConfigMap
- Cluster replicas count
- Standalone replicas default (1)
- Custom `replicasPerPrimary=2` renders correctly in cluster-init-job

#### Extra Volumes (1 test)
- extraVolumes + extraVolumeMounts rendered in StatefulSet

#### ServiceAccount (2 tests)
- ServiceAccount disabled produces no output
- Custom ServiceAccount name

#### Config Change Checksum (1 test)
- Different config produces different `checksum/config` annotation (triggers rolling restart)

#### Health Probes (11 tests)
- Liveness probe: defaults present, custom values, disabled
- Readiness probe: defaults present, custom values, disabled, cluster mode checks `cluster_state`
- Startup probe: defaults present, custom values, disabled
- All three probes disabled simultaneously

#### PDB Configuration (4 tests)
- maxUnavailable default (1), custom (2)
- minAvailable overrides maxUnavailable
- PDB disabled in cluster mode when `pdb.enabled=false`
- PDB absent in standalone mode, present in cluster and sentinel

#### External Access (15 tests)
- Disabled by default (ClusterIP)
- No per-pod services when disabled
- Standalone LoadBalancer, NodePort
- Cluster per-pod services count (6 for 6 replicas)
- Per-pod services have pod-name selector
- RBAC Role for LoadBalancer, ClusterRole for NodePort
- ClusterRole includes nodes resource
- discover-external-ip init container present
- cluster-announce flags in command
- automountServiceAccountToken: true for external access
- external-config volume present
- TLS port in per-pod services
- No RBAC when disabled

#### Pod Anti-Affinity Presets (5 tests)
- Soft anti-affinity preset
- Hard anti-affinity preset
- Ignored with explicit affinity
- Custom topologyKey
- No anti-affinity by default

#### Topology & Advanced (4 tests)
- topologySpreadConstraints rendered, absent by default
- priorityClassName rendered, absent by default

#### Termination & Lifecycle (4 tests)
- terminationGracePeriodSeconds default 30, custom
- extraInitContainers, extraContainers

#### HPA & VPA (4 tests)
- HPA disabled by default, enabled in standalone, not rendered in cluster
- VPA disabled by default, enabled

#### Read Service (3 tests)
- No read service with 1 replica
- Read service with multiple replicas
- No read service in cluster mode

#### Runtime & DNS (4 tests)
- runtimeClassName rendered, absent by default
- dnsPolicy and dnsConfig rendered, absent by default

#### ACL (10 tests)
- ACL disabled by default (no aclfile)
- ACL enabled: aclfile in ConfigMap, users.acl in Secret
- ACL volume mount and acl-config volume in StatefulSet
- ACL existingSecret references, no chart-managed users.acl
- ACL disabled: no acl-config in StatefulSet
- ACL + cluster mode lint
- ACL + external access masterauth handling

#### Cluster Precheck (4 tests)
- Precheck job present in cluster mode
- Absent in standalone mode
- Absent when disabled
- Has pre-upgrade hook annotation

#### Password Rotation (4 tests)
- password-watcher absent by default
- password-watcher present when enabled
- Password file mount with rotation
- Probes use file-based password with rotation

#### Job Image Override (4 tests)
- Default job image
- Custom repository, custom tag
- Custom repository + tag combined

#### Backup CronJob (11 tests)
- Absent by default, present when enabled
- Backup PVC rendered, skipped with existingClaim
- CronJob uses existingClaim
- Custom schedule, custom retention
- Auth env present/absent
- TLS support
- Custom job image

#### Sentinel (21 tests)
- Full render validation
- Sentinel StatefulSet replicas
- Sentinel ConfigMap with monitor + resolve-hostnames
- Sentinel service port 26379
- Sentinel headless service clusterIP: None
- Absent in standalone/cluster modes
- Data StatefulSet has replicaof
- No cluster-announce-ip
- No cluster_state in probes
- PDB present in sentinel mode
- Read service present in sentinel mode
- HPA absent in sentinel mode
- Graceful failover preStop (SENTINEL FAILOVER)
- Custom data replicas, masterSet + quorum, sentinelReplicas
- TLS in data and sentinel ConfigMaps
- NetworkPolicy sentinel port
- No cluster-init job

#### TLS/SSL (32 tests)
- TLS disabled by default
- ConfigMap directives (tls-port, certs, authClients, ciphers, ciphersuites)
- Custom TLS port
- disablePlaintext (port 0)
- TLS replication
- tls-cluster in cluster mode, absent in standalone
- StatefulSet TLS port and cert volume mount
- existingSecret in volume
- TLS service and headless service ports
- Probes: plaintext by default, TLS when plaintext disabled
- Metrics sidecar: rediss:// protocol, cert volume
- Cluster-init-job and cluster-scale-job TLS flags and cert mounts
- Test-connection with/without TLS
- cert-manager Certificate: CRD creation, wildcard DNS, absent when disabled
- NOTES.txt TLS info and disablePlaintext message
- Graceful failover TLS flags
- No TLS artifacts when disabled
- Custom certMountPath

#### Graceful Failover (6 tests)
- preStop hook in cluster mode
- No lifecycle hook in standalone mode
- Disabled when `gracefulFailover.enabled=false`
- User lifecycle overrides graceful failover
- Uses shell builtins only (hardened compatible)
- No-auth mode (AUTH="")

#### Edge Cases (7 tests)
- test-connection.yaml renders, uses auth, no auth when disabled
- auth.disabled ignores existingSecret
- Hardened overrides containerSecurityContext
- All monitoring components together
- Cluster + metrics + networkPolicy combined

### 9.4 Deployment Tests (40+ Tests)

Deployment tests install the chart on a live Kubernetes cluster and verify actual behavior. Each test uses `cleanup()` to ensure a clean environment.

#### Standalone Mode Tests

**test_standalone_rpm** — Basic standalone deployment
- Deploys: Single-node Valkey with RPM image, auth enabled
- Verifies: Pod ready, PING returns PONG, SET/GET works, FLUSHDB/FLUSHALL disabled, Helm test passes

**test_standalone_hardened** — Hardened image variant
- Deploys: Single-node with `image.variant=hardened`
- Verifies: Pod ready, PING works, SET/GET works, Helm test passes
- Conditional: Skipped when `SKIP_HARDENED=true`

**test_hardened_security_verify** — Security properties verification
- Verifies: `readOnlyRootFilesystem=true`, `/tmp` writable (tmpfs), `/data` writable (PVC), `allowPrivilegeEscalation=false`, capabilities drop ALL

**test_persistence** — Data survives pod restart
- Deploys: Standalone with persistence enabled
- Process: Write data, delete pod, wait for restart, verify data persists
- Verifies: PVC-backed storage preserves data across restarts

**test_no_auth** — Authentication disabled
- Deploys: `auth.enabled=false`
- Verifies: PING without password works, Helm test passes

**test_secret_lookup** — Password preservation across upgrades
- Process: Install (auto-generated password), get password, upgrade with `--reuse-values`, verify password unchanged
- Verifies: `lookup` function preserves existing Secret password

**test_existing_secret** — External Secret reference
- Process: Create external Secret, deploy with `auth.existingSecret`, verify password
- Verifies: External Secret is used, no chart-managed Secret

**test_password_file_mount** — Password file mode
- Deploys: `auth.usePasswordFiles=true`
- Verifies: Password file exists at correct path, contains correct value

**test_resource_preset** — Resource presets
- Deploys: `resourcePreset=micro`
- Verifies: Memory request = 256Mi in running pod

**test_custom_config** — Custom Valkey configuration
- Deploys: `config.maxmemory=64mb, config.maxmemoryPolicy=allkeys-lru, config.customConfig="hz 20"`
- Verifies: All settings applied via `CONFIG GET`

**test_config_rolling_restart** — Config changes trigger restart
- Process: Install, get pod UID, upgrade with config change, verify new UID
- Verifies: `checksum/config` annotation triggers pod recreation

**test_persistence_disabled** — EmptyDir storage
- Deploys: `persistence.enabled=false`
- Verifies: No PVCs created, Valkey works with emptyDir

**test_probes_deploy** — Custom probe values
- Deploys: Custom liveness, readiness, startup probe settings
- Verifies: Pod becomes ready, all probe values match in pod spec

**test_probes_disabled_deploy** — All probes disabled
- Deploys: All probes disabled
- Verifies: Pod runs, no probes in container spec, Valkey works

**test_tls_standalone** — TLS encryption
- Deploys: Self-signed TLS certificates, `tls.enabled=true`
- Verifies: TLS port works, plaintext port works, SET/GET over TLS, config shows tls-port

**test_tls_plaintext_disabled** — TLS-only mode
- Deploys: `tls.disablePlaintext=true`
- Verifies: TLS works, plaintext connection refused

**test_metrics_sidecar** — Metrics exporter
- Deploys: `metrics.enabled=true`
- Verifies: 2 containers (valkey + metrics), redis_up metric available, metrics service exists

**test_metrics_with_auth** — Authenticated metrics
- Verifies: REDIS_PASSWORD env set in metrics container, redis_up=1 (authenticated)

**test_init_containers_deploy** — Sysctl-init and volume-permissions init containers
- Deploys: Both `sysctlInit.enabled=true` and `volumePermissions.enabled=true` with graceful fallback
- Fallback: If privileged containers are blocked by PodSecurity, falls back to volumePermissions only, then skips
- Verifies: Both init containers ran and completed, Valkey works after initialization

**test_extra_env_vars** — Custom environment variables
- Verifies: Custom env var accessible in pod

**test_extra_volumes** — Custom volumes
- Verifies: Memory-backed volume writable at mount path

**test_extra_init_containers** — Custom init containers
- Verifies: Marker file created by init container exists

**test_extra_containers** — Custom sidecar containers
- Verifies: Sidecar running alongside Valkey

**test_diagnostic_mode** — Debug override
- Deploys: `diagnosticMode.enabled=true`
- Verifies: Pod running but Valkey NOT running (sleep instead)

**test_naming_overrides** — Custom resource names
- Deploys: `fullnameOverride=my-valkey-custom`
- Verifies: Pod and service use custom name

**test_anti_affinity_preset** — Pod anti-affinity
- Verifies: Soft anti-affinity rule in pod spec

**test_termination_grace_period** — Custom grace period
- Verifies: `terminationGracePeriodSeconds: 120` in pod spec

**test_priority_class** — Priority class
- Process: Create PriorityClass, deploy with reference
- Verifies: priorityClassName in pod spec

**test_topology_spread** — Topology spread constraints
- Verifies: Constraint applied to pod spec

**test_read_service** — Read-only service
- Deploys: `standalone.replicas=2`
- Verifies: Read service exists, ClusterIP type, port 6379, PING works

**test_dns_config** — DNS configuration
- Verifies: dnsPolicy and dnsConfig options in pod spec

**test_helm_test_hook** — Helm test validation
- Verifies: `helm test` passes with and without auth

**test_acl_standalone** — ACL multi-user
- Deploys: ACL enabled with custom user
- Verifies: Default user PING works, custom user PING works, ACL list includes custom user

**test_runtime_class** — Template-only: runtimeClassName renders when set, absent by default

#### Cluster Mode Tests

**test_cluster_rpm** — Basic cluster deployment
- Deploys: 6-node cluster (3 primary + 3 replica), 300s timeout
- Verifies: All 6 pods ready, `cluster_state:ok`, `cluster_size:3`, `cluster_known_nodes:6`, `cluster_slots_ok:16384`, SET/GET with `-c`, FLUSHDB disabled, Helm test passes

**test_cluster_hardened** — Cluster with hardened image
- Verifies: Cluster health + hardened image compatibility

**test_cluster_multi_slot** — Multi-slot distribution
- Process: Set 10 keys across different hash slots
- Verifies: All keys retrievable, distributed across multiple nodes

**test_cluster_custom_node_timeout** — Custom node timeout
- Verifies: `cluster-node-timeout 5000` in config

**test_cluster_scale_up** — Scale from 6 to 8 nodes
- Process: Install 6-node cluster, write data, upgrade to 8 nodes
- Verifies: `cluster_known_nodes:8`, `cluster_state:ok`, data preserved

**test_cluster_scale_down** — Scale from 8 to 6 nodes
- Verifies: Cluster adjusts, data preserved

**test_graceful_failover** — Primary failover during pod deletion
- Process: Find primary, write data, delete primary pod
- Verifies: All pods recover, `cluster_state:ok`, slots intact, data survived

**test_cluster_precheck** — Scale-down safety validation
- Process: Install 6-node, no-op scale (6->6), scale up (6->8), scale down (8->6)
- Verifies: All operations succeed with precheck enabled

#### Sentinel Mode Tests

**test_sentinel_rpm** — Basic sentinel deployment
- Deploys: 3 data pods + 3 sentinel pods
- Verifies: All pods ready, sentinel reports master, 2 replicas connected, SET/GET works, replica role detected, sentinel service exists, Helm test passes

**test_sentinel_failover** — Sentinel-managed failover
- Process: Write data to master, delete master pod, wait for recovery
- Verifies: Data survived failover

**test_sentinel_hardened** — Sentinel with hardened image
- Verifies: Both sentinel and data pods running with hardened image, readOnlyRootFilesystem, replication works

#### Feature-Specific Tests

**test_password_rotation** — Live password rotation
- Deploys: `auth.passwordRotation.enabled=true`
- Process: Verify sidecar, PING with current password, patch Secret with new password, wait 90s for propagation
- Verifies: New password works, old password fails

**test_backup_cronjob** — Backup creation
- Deploys: `backup.enabled=true`
- Verifies: CronJob exists, backup PVC exists, manual trigger succeeds, "Backup successful" in logs

### 9.5 Test Execution

#### Running the Full Suite

```bash
cd percona-valkey-helm
bash test-chart.sh
```

#### Skipping Hardened Tests

```bash
SKIP_HARDENED=true bash test-chart.sh
```

#### Phases

1. **Phase 1 — Static Tests (no cluster required)**
   - `test_lint()` — All 11 lint tests
   - `test_template_render()` — All ~250 template assertions

2. **Phase 2 — Deployment Tests (requires running cluster)**
   - All 40+ deployment tests run sequentially
   - Each test cleans up before/after via `cleanup()`

#### Summary Output

```
============================================
  Percona Valkey Helm Chart — Full Test Suite
============================================

Passed:  [count]
Failed:  [count]
Skipped: [count]
Total:   [count]
```

Exit code: 0 if all passed, 1 if any failed.

---

## 10. Troubleshooting

### CrashLoopBackOff

**Common causes:**

1. **Wrong password** — The pod starts, connects to a replica/master with the wrong password. Check the Secret matches across all pods.
2. **Insufficient resources** — Valkey cannot allocate memory. Set `config.maxmemory` or increase `resources.limits.memory`.
3. **PVC permissions** — Enable `volumePermissions.enabled=true` to fix ownership on the `/data` volume.
4. **Invalid config** — Check `config.customConfig` for syntax errors. Use `kubectl logs <pod>` to see Valkey startup errors.
5. **Missing TLS certificates** — If `tls.enabled=true`, ensure the TLS Secret exists with keys `tls.crt`, `tls.key`, `ca.crt`.

### Readiness Probe Failures

**Standalone/Sentinel:**
```
Readiness probe failed: PONG
```
- The probe checks `response = "PONG"`. If Valkey responds with `NOAUTH` or an error, it fails.
- Verify the password in the probe matches the running config.

**Cluster:**
```
Readiness probe failed: cluster_state:ok not found
```
- The cluster is not yet formed. Check if the cluster-init Job completed.
- Run `kubectl get jobs` to see if `*-cluster-init` succeeded.
- Check Job logs: `kubectl logs job/<release>-cluster-init`

### Cluster-Init Job Stuck

**Symptoms:** Job keeps retrying, pods are ready but cluster not formed.

**Diagnosis:**
```bash
kubectl logs job/<release>-cluster-init
```

**Common causes:**
1. **DNS resolution failure** — Headless service not resolving pod hostnames. Wait for all pods to register.
2. **Authentication mismatch** — Job uses a different password than the pods.
3. **Network policy blocking** — Ensure NetworkPolicy allows port 6379 and 16379 between pods.
4. **Existing cluster state** — If pods have stale `nodes.conf` from a previous installation, delete the PVCs and retry.

### Permission Denied (Hardened Image)

**Symptoms:** `Read-only file system` errors in pod logs.

**Resolution:**
- The hardened variant sets `readOnlyRootFilesystem: true`
- Writable paths: `/data` (PVC), `/tmp` (tmpfs), `/run/valkey` (tmpfs)
- If Valkey needs to write elsewhere, switch to the RPM variant or add custom volume mounts

### Sentinel No Master

**Symptoms:** Sentinel reports no master, or `SENTINEL get-master-addr-by-name` returns nil.

**Diagnosis:**
```bash
kubectl logs <release>-sentinel-0
kubectl exec <release>-sentinel-0 -- valkey-cli -p 26379 INFO sentinel
```

**Common causes:**
1. **Master pod-0 not ready** — The `wait-for-master` init container should handle this, but check if pod-0 is starting correctly.
2. **Password mismatch** — The sentinel-init container injects auth credentials. Verify the Secret.
3. **Network partition** — Sentinels cannot reach data pods. Check services and DNS.

### Password Issues

**Auto-generated password lost:**
```bash
# Retrieve from Secret
kubectl get secret <release> -o jsonpath="{.data.valkey-password}" | base64 -d
```

**Password not preserved on upgrade:**
- The `lookup` function requires `helm upgrade` (not `helm template`)
- `helm template` does not have access to the cluster and cannot look up existing Secrets
- Always pass `--reuse-values` or explicitly set `auth.password` during upgrades

**Password rotation not working:**
- Ensure `auth.passwordRotation.enabled=true`
- Check password-watcher logs: `kubectl logs <pod> -c password-watcher`
- Verify the Secret file is mounted: `kubectl exec <pod> -- cat /opt/valkey/secrets/valkey-password`
- Allow up to `interval` seconds (default 10) for detection

---

## 11. Known Limitations

### Scale-Down Requires Care

Scaling down a Valkey Cluster requires that:
- At least 3 masters remain after scale-down
- Each master being removed has a healthy replica for failover
- The precheck Job validates these conditions, but manual intervention may be needed if the cluster is in a degraded state

### Jobs Always Use RPM Image

All Helm hook Jobs (cluster-init, cluster-scale, cluster-precheck) and the backup CronJob always use the RPM variant image, even when `image.variant: hardened` is set. This is because Jobs require shell tools (`sh`, `grep`, `awk`, `valkey-cli`) that are not available in the distroless hardened image.

### Auto-Generated Passwords with `helm template`

The `lookup` function used for password preservation requires cluster access. When using `helm template` (offline rendering):
- A new random password is generated every time
- The password will not match any existing Secret
- Use `auth.password` explicitly when rendering templates offline

### Sentinel Mode Limitations

- Pod-0 is initially hardcoded as the master via ordinal-based `--replicaof`. After Sentinel failover, any pod can become master.
- Sentinel persistence is disabled by default because Sentinel state is ephemeral and reconstructed on startup.
- There is no automated scale-up/down for sentinel mode — changing `sentinel.replicas` requires manual attention to replication topology.

### HPA Only for Standalone

Horizontal Pod Autoscaler is only supported in standalone mode. Cluster and sentinel modes have fixed topologies that cannot be dynamically scaled via HPA metrics.

### Network Policy Coverage

The chart's NetworkPolicy covers ingress rules but does not restrict egress by default. Add `networkPolicy.extraEgress` rules for full network isolation.

### PVC Retention Policy

The `persistentVolumeClaimRetentionPolicy` feature requires Kubernetes 1.27+ and the `StatefulSetAutoDeletePVC` feature gate to be enabled.

### External Access RBAC Scope

- **LoadBalancer mode:** Creates a namespace-scoped Role (minimal permissions)
- **NodePort mode:** Creates a cluster-scoped ClusterRole (requires node read access)

The ClusterRole is more permissive because the init container needs to read node ExternalIP addresses.
