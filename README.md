# Percona Valkey Helm Chart

A production-ready Helm chart for deploying Percona Valkey on Kubernetes. Supports **standalone**, **native Valkey Cluster**, and **Sentinel** modes with two image variants: RPM-based (UBI9) and Hardened (DHI).

---

## Table of Contents

- [Chart Structure](#chart-structure)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Deployment Modes](#deployment-modes)
- [Image Variants](#image-variants)
- [Configuration Reference](#configuration-reference)
- [Security](#security)
- [TLS/SSL](#tlsssl)
- [Access Control Lists (ACL)](#access-control-lists-acl)
- [Monitoring & Metrics](#monitoring--metrics)
- [Persistence](#persistence)
- [Networking](#networking)
- [Backup & Restore](#backup--restore)
- [Autoscaling](#autoscaling)
- [Usage Examples](#usage-examples)
- [Operations](#operations)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Known Limitations](#known-limitations)

---

## Chart Structure

```
helm/percona-valkey/
├── Chart.yaml                            # Chart metadata (appVersion: 9.0.3)
├── values.yaml                           # All configurable parameters
├── values.schema.json                    # JSON Schema for values validation
├── .helmignore                           # Files excluded from chart packaging
├── test-chart.sh                         # Comprehensive lint/render/deploy test suite
└── templates/
    ├── _helpers.tpl                      # Template helpers, validators, resource presets
    ├── NOTES.txt                         # Post-install connection instructions
    ├── secret.yaml                       # Valkey password (auto-generated or user-supplied)
    ├── serviceaccount.yaml               # Dedicated ServiceAccount (automount disabled)
    ├── role.yaml                         # RBAC Role
    ├── rolebinding.yaml                  # RBAC RoleBinding
    ├── configmap.yaml                    # valkey.conf (base config + TLS + cluster)
    ├── sentinel-configmap.yaml           # sentinel.conf (sentinel mode only)
    ├── service.yaml                      # Client-facing ClusterIP service
    ├── service-headless.yaml             # Headless service for StatefulSet DNS + cluster bus
    ├── service-read.yaml                 # Read-only service (replica targeting)
    ├── service-metrics.yaml              # Metrics exporter service
    ├── service-per-pod.yaml              # Per-pod external services (cluster external access)
    ├── sentinel-service.yaml             # Sentinel service
    ├── sentinel-headless-service.yaml    # Sentinel headless service
    ├── statefulset.yaml                  # Core workload (standalone/cluster/sentinel data)
    ├── deployment.yaml                   # Standalone Deployment mode (cache-only)
    ├── sentinel-statefulset.yaml         # Sentinel monitor pods
    ├── pdb.yaml                          # PodDisruptionBudget (cluster/sentinel)
    ├── networkpolicy.yaml                # Network Policy
    ├── hpa.yaml                          # Horizontal Pod Autoscaler
    ├── vpa.yaml                          # Vertical Pod Autoscaler
    ├── certificate.yaml                  # cert-manager Certificate
    ├── servicemonitor.yaml               # Prometheus ServiceMonitor
    ├── podmonitor.yaml                   # Prometheus PodMonitor
    ├── prometheusrule.yaml               # Prometheus alerting rules
    ├── cluster-init-job.yaml             # Helm post-install hook: cluster formation
    ├── cluster-scale-job.yaml            # Helm post-upgrade hook: scale up/down
    ├── cluster-precheck-job.yaml         # Helm pre-upgrade hook: safety validation
    ├── backup-cronjob.yaml               # Scheduled RDB backup CronJob
    ├── backup-pvc.yaml                   # Backup PVC
    └── tests/
        └── test-connection.yaml          # helm test: valkey-cli ping
```

## Prerequisites

- Kubernetes 1.23+
- Helm 3.x
- PV provisioner support in the underlying infrastructure (if persistence is enabled)
- `perconalab/valkey` image available (DockerHub or private registry)

## Quick Start

### Install in standalone mode (default)

```bash
helm install my-valkey ./helm/percona-valkey
```

### Install in cluster mode

```bash
helm install my-valkey ./helm/percona-valkey --set mode=cluster
```

### Install in sentinel mode

```bash
helm install my-valkey ./helm/percona-valkey --set mode=sentinel
```

### Install with hardened image

```bash
helm install my-valkey ./helm/percona-valkey --set image.variant=hardened
```

### Install with custom values file

```bash
helm install my-valkey ./helm/percona-valkey -f my-values.yaml
```

---

## Architecture

### High-Level Overview

```
                    ┌─────────────────────────────────────────────────┐
                    │              Percona Valkey Helm Chart           │
                    │                                                 │
                    │   values.yaml ──► _helpers.tpl ──► templates/   │
                    │                                                 │
                    │   Modes: standalone | cluster | sentinel        │
                    │   Variants: rpm (UBI9) | hardened (DHI)         │
                    └─────────────────────────────────────────────────┘
                                          │
                    ┌─────────────────────┼──────────────────────┐
                    ▼                     ▼                      ▼
           ┌──────────────┐     ┌──────────────┐      ┌──────────────────┐
           │  Standalone   │     │   Cluster    │      │    Sentinel      │
           │              │     │              │      │                  │
           │ StatefulSet  │     │ StatefulSet  │      │ StatefulSet (data)│
           │  or Deploy.  │     │  (N pods)    │      │ StatefulSet (sent)│
           │  (1 pod)     │     │              │      │                  │
           └──────────────┘     └──────────────┘      └──────────────────┘
```

### Standalone Mode Architecture

```
┌──────────────────────────────────────────────┐
│                  Kubernetes                   │
│                                              │
│  ┌────────────────────────────────────┐      │
│  │ StatefulSet: my-valkey             │      │
│  │ (or Deployment if useDeployment)   │      │
│  │                                    │      │
│  │  ┌─────────────────────────────┐   │      │
│  │  │ Pod: my-valkey-0            │   │      │
│  │  │                             │   │      │
│  │  │ ┌─────────┐ ┌───────────┐  │   │      │
│  │  │ │ valkey   │ │ metrics   │  │   │      │
│  │  │ │ server   │ │ exporter  │  │   │      │
│  │  │ │ :6379    │ │ :9121     │  │   │      │
│  │  │ └─────────┘ └───────────┘  │   │      │
│  │  │      │                      │   │      │
│  │  │ ┌────▼────┐                 │   │      │
│  │  │ │ PVC     │                 │   │      │
│  │  │ │ /data   │                 │   │      │
│  │  │ └─────────┘                 │   │      │
│  │  └─────────────────────────────┘   │      │
│  └────────────────────────────────────┘      │
│                                              │
│  ┌────────────┐  ┌──────────────────┐        │
│  │ Service    │  │ Headless Service │        │
│  │ ClusterIP  │  │ (DNS per pod)    │        │
│  │ :6379      │  │                  │        │
│  └────────────┘  └──────────────────┘        │
└──────────────────────────────────────────────┘
```

### Cluster Mode Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Kubernetes Cluster                            │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ StatefulSet: my-valkey (6 pods default: 3 primaries + 3 replicas)│  │
│  │                                                                   │  │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐                          │  │
│  │  │ Pod 0    │ │ Pod 1    │ │ Pod 2    │  ◄─── Primaries          │  │
│  │  │ Primary  │ │ Primary  │ │ Primary  │       (hash slots)       │  │
│  │  │ 0-5460   │ │ 5461-10922│ │10923-16383│                        │  │
│  │  │ :6379    │ │ :6379    │ │ :6379    │                          │  │
│  │  │ :16379   │ │ :16379   │ │ :16379   │  ◄─── Cluster bus       │  │
│  │  └────┬─────┘ └────┬─────┘ └────┬─────┘                          │  │
│  │       │             │             │                                │  │
│  │  ┌────▼─────┐ ┌────▼─────┐ ┌────▼─────┐                          │  │
│  │  │ Pod 3    │ │ Pod 4    │ │ Pod 5    │  ◄─── Replicas           │  │
│  │  │ Replica  │ │ Replica  │ │ Replica  │                          │  │
│  │  │ of Pod 0 │ │ of Pod 1 │ │ of Pod 2 │                          │  │
│  │  └──────────┘ └──────────┘ └──────────┘                          │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌───────────┐  ┌──────────────────────┐  ┌──────────────────────────┐ │
│  │ Service   │  │ Headless Service     │  │ Jobs (Helm hooks)        │ │
│  │ ClusterIP │  │ publishNotReady: true│  │ post-install: init       │ │
│  │ :6379     │  │ :6379 + :16379       │  │ post-upgrade: scale      │ │
│  └───────────┘  └──────────────────────┘  │ pre-upgrade:  precheck   │ │
│                                            └──────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

### Sentinel Mode Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                            Kubernetes Cluster                             │
│                                                                           │
│  ┌─────────────────────────────────────────────┐                         │
│  │ StatefulSet: my-valkey (data pods)          │                         │
│  │                                             │                         │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐    │                         │
│  │  │ Pod 0    │ │ Pod 1    │ │ Pod 2    │    │                         │
│  │  │ PRIMARY  │ │ Replica  │ │ Replica  │    │                         │
│  │  │ :6379    │ │ :6379    │ │ :6379    │    │                         │
│  │  │ ┌──────┐ │ │ ┌──────┐ │ │ ┌──────┐ │    │                         │
│  │  │ │ PVC  │ │ │ │ PVC  │ │ │ │ PVC  │ │    │                         │
│  │  │ └──────┘ │ │ └──────┘ │ │ └──────┘ │    │                         │
│  │  └──────────┘ └──────────┘ └──────────┘    │                         │
│  └──────────────────────┬──────────────────────┘                         │
│                         │  monitors                                       │
│  ┌──────────────────────▼──────────────────────┐                         │
│  │ StatefulSet: my-valkey-sentinel             │                         │
│  │                                             │                         │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐    │                         │
│  │  │Sentinel 0│ │Sentinel 1│ │Sentinel 2│    │                         │
│  │  │ :26379   │ │ :26379   │ │ :26379   │    │  quorum: 2              │
│  │  └──────────┘ └──────────┘ └──────────┘    │                         │
│  └─────────────────────────────────────────────┘                         │
│                                                                           │
│  ┌────────────┐ ┌──────────────┐ ┌──────────────────┐                    │
│  │ Service    │ │ Sentinel Svc │ │ Headless Services │                    │
│  │ :6379      │ │ :26379       │ │ data + sentinel   │                    │
│  └────────────┘ └──────────────┘ └──────────────────┘                    │
└──────────────────────────────────────────────────────────────────────────┘
```

### Entrypoint Integration

The chart passes configuration to Valkey through environment variables that the `docker-entrypoint.sh` script processes:

| Env Variable | Source | Purpose |
|-------------|--------|---------|
| `VALKEY_PASSWORD` | Secret | Appended as `--requirepass` by entrypoint |
| `VALKEY_MAXMEMORY` | ConfigMap / values | Appended as `--maxmemory` by entrypoint |
| `VALKEY_BIND` | ConfigMap / values | Appended as `--bind` by entrypoint |
| `VALKEY_EXTRA_FLAGS` | Values + Downward API | Additional flags (includes `--cluster-announce-ip` in cluster mode) |

The container args are `["/etc/valkey/valkey.conf"]` — the entrypoint script detects the `.conf` suffix and prepends `valkey-server`.

---

## Deployment Modes

### Standalone Mode (`mode: standalone`)

The default mode. Deploys a single Valkey instance as a 1-replica StatefulSet.

- Pod management policy: `OrderedReady`
- Readiness probe: `valkey-cli ping` (PONG check)
- Suitable for development, caching, and single-instance use cases
- Optional: set `standalone.useDeployment=true` + `persistence.enabled=false` for a cache-only Deployment (no PVC)

### Cluster Mode (`mode: cluster`)

Deploys a native Valkey Cluster using a multi-replica StatefulSet with automatic cluster formation.

- Default: 6 nodes (3 primaries + 3 replicas with `replicasPerPrimary: 1`)
- Pod management policy: `Parallel` (all pods start simultaneously)
- Readiness probe: `valkey-cli cluster info` (checks `cluster_state:ok`)
- PodDisruptionBudget enabled by default (`maxUnavailable: 1`)
- Cluster bus port 16379 exposed on headless service
- Pre-upgrade safety checks block unsafe scale-downs

#### How Cluster Formation Works

```
  helm install
       │
       ▼
  StatefulSet creates N pods
       │
       ▼
  Each pod gets IP via Downward API (status.podIP)
       │
       ▼
  Pod IP passed as --cluster-announce-ip $(POD_IP)
       │
       ▼
  Headless service provides DNS (publishNotReadyAddresses: true)
       │
       ▼
  post-install Job: cluster-init-job.yaml
       │
       ├─► Wait for all pods to PONG
       ├─► Check idempotency (cluster_state:ok → skip)
       └─► valkey-cli --cluster create --cluster-yes
              │
              ▼
         Readiness probes pass (cluster_state:ok)
              │
              ▼
         Pods become Ready
```

### Sentinel Mode (`mode: sentinel`)

Master-replica topology monitored by Sentinel processes for automatic failover.

- Data StatefulSet: 1 master + N-1 replicas (default: 3 pods)
- Sentinel StatefulSet: odd number of monitor pods (default: 3)
- Automatic failover when master is unreachable
- Clients query Sentinel to discover current master

---

## Image Variants

| Variant | Base Image | Default Tag | Description |
|---------|-----------|-------------|-------------|
| `rpm` (default) | UBI9 (Red Hat Universal Base Image) | `9.0.3` | Full-featured image with shell, package manager, and standard tooling |
| `hardened` | DHI (Distroless Hardened Image) | `9.0.3-hardened` | Minimal attack surface, no shell in production container |

### RPM Variant

```yaml
image:
  variant: rpm  # default
```

Standard UBI9-based image. Contains shell utilities, making it suitable for debugging and operational tasks.

### Hardened Variant

```yaml
image:
  variant: hardened
```

When the hardened variant is selected, the chart automatically:
- Sets `readOnlyRootFilesystem: true` on the Valkey container
- Mounts tmpfs emptyDir volumes at `/tmp` and `/run/valkey` (required for read-only root filesystem)
- Uses the RPM image for the cluster-init Job and test pods (they need shell/grep)

---

## Configuration Reference

### Global

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global.imageRegistry` | Global image registry prepended to all repositories | `""` |
| `nameOverride` | Override chart name | `""` |
| `fullnameOverride` | Override full release name | `""` |
| `commonLabels` | Additional labels applied to all resources | `{}` |
| `clusterDomain` | Kubernetes cluster domain | `cluster.local` |
| `mode` | Deployment mode: `standalone`, `cluster`, or `sentinel` | `standalone` |

### Image

| Parameter | Description | Default |
|-----------|-------------|---------|
| `image.repository` | Image repository | `perconalab/valkey` |
| `image.variant` | Image variant: `rpm` or `hardened` | `rpm` |
| `image.tag` | Override image tag | `""` (auto-resolved from appVersion) |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `image.pullSecrets` | Image pull secrets | `[]` |
| `image.jobs.repository` | Override image for Jobs (cluster-init, test, etc.) | `""` |
| `image.jobs.tag` | Override tag for Jobs | `""` |

### Authentication

| Parameter | Description | Default |
|-----------|-------------|---------|
| `auth.enabled` | Enable password authentication | `true` |
| `auth.password` | Valkey password (auto-generated 16-char if empty) | `""` |
| `auth.existingSecret` | Use existing Secret (must contain key `valkey-password`) | `""` |
| `auth.usePasswordFiles` | Mount password as file instead of env var | `false` |
| `auth.passwordFilePath` | Directory where password file is mounted | `/opt/valkey/secrets` |
| `auth.passwordRotation.enabled` | Enable hot-reload password rotation sidecar | `false` |
| `auth.passwordRotation.interval` | Poll interval in seconds | `10` |
| `auth.passwordRotation.resources` | Resources for the password-watcher sidecar | `{}` |

### Valkey Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `config.maxmemory` | Max memory limit (e.g., `256mb`, `1gb`) | `""` |
| `config.maxmemoryPolicy` | Eviction policy (e.g., `allkeys-lru`) | `""` |
| `config.bind` | Bind address | `0.0.0.0` |
| `config.logLevel` | Log level: `debug`, `verbose`, `notice`, `warning` | `""` |
| `config.disklessSync` | Enable diskless replication sync | `false` |
| `config.minReplicasToWrite` | Minimum replicas for write quorum (0 = disabled) | `0` |
| `config.minReplicasMaxLag` | Max replication lag (seconds) for write quorum | `10` |
| `config.extraFlags` | Additional flags passed via `VALKEY_EXTRA_FLAGS` env var | `""` |
| `config.customConfig` | Custom valkey.conf content appended to generated config | `""` |

### Cluster Mode

| Parameter | Description | Default |
|-----------|-------------|---------|
| `cluster.replicas` | Total number of cluster nodes (min 6) | `6` |
| `cluster.replicasPerPrimary` | Replicas per primary node | `1` |
| `cluster.nodeTimeout` | Cluster node timeout in milliseconds | `15000` |
| `cluster.busPort` | Cluster bus port | `16379` |
| `cluster.precheckBeforeScaleDown` | Enable pre-upgrade safety validation | `true` |
| `cluster.persistence.size` | Override persistence size for cluster mode | `""` |
| `cluster.persistence.storageClass` | Override storage class for cluster mode | `""` |

### Standalone Mode

| Parameter | Description | Default |
|-----------|-------------|---------|
| `standalone.replicas` | Number of standalone replicas | `1` |
| `standalone.useDeployment` | Use Deployment instead of StatefulSet (cache-only) | `false` |
| `standalone.strategy.type` | Deployment strategy (when useDeployment=true) | `RollingUpdate` |

### Sentinel Mode

| Parameter | Description | Default |
|-----------|-------------|---------|
| `sentinel.replicas` | Total Valkey data pods (1 master + N-1 replicas) | `3` |
| `sentinel.sentinelReplicas` | Sentinel monitor pods (must be odd, min 3) | `3` |
| `sentinel.port` | Sentinel port | `26379` |
| `sentinel.masterSet` | Master set name | `mymaster` |
| `sentinel.quorum` | Sentinels that must agree master is down | `2` |
| `sentinel.downAfterMilliseconds` | Milliseconds before master unreachable | `30000` |
| `sentinel.failoverTimeout` | Failover timeout in milliseconds | `180000` |
| `sentinel.parallelSyncs` | Replicas syncing with new master simultaneously | `1` |
| `sentinel.resources` | Resources for Sentinel pods | `{}` |
| `sentinel.persistence.enabled` | Enable persistence for Sentinel pods | `false` |
| `sentinel.persistence.size` | Sentinel PVC size | `1Gi` |
| `sentinel.dataPersistence.size` | Override persistence size for data pods | `""` |
| `sentinel.dataPersistence.storageClass` | Override storage class for data pods | `""` |
| `sentinel.podAntiAffinityPreset.type` | Anti-affinity preset: `soft` or `hard` | `""` |
| `sentinel.podAntiAffinityPreset.topologyKey` | Topology key for anti-affinity | `kubernetes.io/hostname` |
| `sentinel.podAnnotations` | Sentinel pod annotations | `{}` |
| `sentinel.podLabels` | Sentinel pod labels | `{}` |
| `sentinel.nodeSelector` | Sentinel node selector | `{}` |
| `sentinel.tolerations` | Sentinel tolerations | `[]` |
| `sentinel.affinity` | Sentinel affinity | `{}` |

### StatefulSet

| Parameter | Description | Default |
|-----------|-------------|---------|
| `statefulset.updateStrategy.type` | Update strategy | `RollingUpdate` |
| `statefulset.podManagementPolicy` | Override pod management policy | `""` (auto) |
| `statefulset.annotations` | StatefulSet annotations | `{}` |
| `statefulset.labels` | Additional StatefulSet labels | `{}` |

### Pod

| Parameter | Description | Default |
|-----------|-------------|---------|
| `podAnnotations` | Pod annotations | `{}` |
| `podLabels` | Additional pod labels | `{}` |

### Security Context

| Parameter | Description | Default |
|-----------|-------------|---------|
| `securityContext.runAsUser` | Pod-level UID | `999` |
| `securityContext.runAsGroup` | Pod-level GID | `999` |
| `securityContext.fsGroup` | Filesystem group | `999` |
| `securityContext.runAsNonRoot` | Enforce non-root | `true` |
| `securityContext.seccompProfile.type` | Seccomp profile type | `RuntimeDefault` |
| `containerSecurityContext.readOnlyRootFilesystem` | Read-only root filesystem | `true` |
| `containerSecurityContext.allowPrivilegeEscalation` | Allow privilege escalation | `false` |
| `containerSecurityContext.capabilities.drop` | Dropped capabilities | `[ALL]` |

### Service

| Parameter | Description | Default |
|-----------|-------------|---------|
| `service.type` | Service type | `ClusterIP` |
| `service.port` | Service port | `6379` |
| `service.annotations` | Service annotations | `{}` |
| `service.clusterIP` | Specific cluster IP (empty = auto-assign) | `""` |
| `service.loadBalancerClass` | LoadBalancer class (K8s 1.24+) | `""` |
| `service.appProtocol` | Application protocol for service ports | `""` |

### Persistence

| Parameter | Description | Default |
|-----------|-------------|---------|
| `persistence.enabled` | Enable persistent storage | `true` |
| `persistence.storageClass` | Storage class name | `""` (default provisioner) |
| `persistence.accessModes` | PVC access modes | `[ReadWriteOnce]` |
| `persistence.size` | PVC size | `8Gi` |
| `persistence.annotations` | PVC annotations | `{}` |
| `persistence.keepOnUninstall` | Keep PVCs when Helm release is uninstalled | `false` |
| `persistence.subPath` | Mount a sub-directory within the PVC | `""` |
| `persistence.hostPath` | Use hostPath volume (requires persistence.enabled=false) | `""` |
| `persistentVolumeClaimRetentionPolicy.whenDeleted` | PVC retention on delete | `Retain` |
| `persistentVolumeClaimRetentionPolicy.whenScaled` | PVC retention on scale-down | `Retain` |

### Health Probes

| Parameter | Description | Default |
|-----------|-------------|---------|
| `livenessProbe.enabled` | Enable liveness probe | `true` |
| `livenessProbe.initialDelaySeconds` | Initial delay | `20` |
| `livenessProbe.periodSeconds` | Check interval | `10` |
| `livenessProbe.timeoutSeconds` | Timeout | `5` |
| `livenessProbe.failureThreshold` | Failure threshold | `6` |
| `readinessProbe.enabled` | Enable readiness probe | `true` |
| `readinessProbe.initialDelaySeconds` | Initial delay | `10` |
| `readinessProbe.periodSeconds` | Check interval | `10` |
| `readinessProbe.timeoutSeconds` | Timeout | `3` |
| `readinessProbe.failureThreshold` | Failure threshold | `3` |
| `startupProbe.enabled` | Enable startup probe | `true` |
| `startupProbe.initialDelaySeconds` | Initial delay | `5` |
| `startupProbe.periodSeconds` | Check interval | `5` |
| `startupProbe.timeoutSeconds` | Timeout | `3` |
| `startupProbe.failureThreshold` | Failure threshold | `30` |

### Resources

| Parameter | Description | Default |
|-----------|-------------|---------|
| `resources.limits` | CPU/memory limits | `{}` |
| `resources.requests` | CPU/memory requests | `{}` |
| `resourcePreset` | Predefined resource preset: `none`, `nano`, `micro`, `small`, `medium`, `large`, `xlarge` | `none` |
| `initResources` | Resources for init containers (global default) | `{}` |

#### Resource Presets

| Preset | CPU Request | Memory Request | CPU Limit | Memory Limit |
|--------|-----------|--------------|---------|------------|
| `nano` | 100m | 128Mi | 250m | 256Mi |
| `micro` | 250m | 256Mi | 500m | 512Mi |
| `small` | 500m | 512Mi | 1 | 1Gi |
| `medium` | 1 | 1Gi | 2 | 2Gi |
| `large` | 2 | 2Gi | 4 | 4Gi |
| `xlarge` | 4 | 4Gi | 8 | 8Gi |

Explicit `resources.limits`/`resources.requests` always override presets.

### ServiceAccount & RBAC

| Parameter | Description | Default |
|-----------|-------------|---------|
| `serviceAccount.create` | Create ServiceAccount | `true` |
| `serviceAccount.name` | ServiceAccount name override | `""` |
| `serviceAccount.annotations` | ServiceAccount annotations | `{}` |
| `serviceAccount.automountServiceAccountToken` | Automount token | `false` |
| `rbac.create` | Create RBAC resources | `true` |

### PodDisruptionBudget

| Parameter | Description | Default |
|-----------|-------------|---------|
| `pdb.enabled` | Enable PDB (cluster/sentinel mode) | `true` |
| `pdb.minAvailable` | Minimum available pods | `""` |
| `pdb.maxUnavailable` | Maximum unavailable pods | `1` |

### Disabled Commands

| Parameter | Description | Default |
|-----------|-------------|---------|
| `disableCommands` | Commands renamed to "" (disabled) | `[FLUSHDB, FLUSHALL]` |
| `disableCommandsStandalone` | Override for standalone mode | `nil` |
| `disableCommandsCluster` | Override for cluster mode | `nil` |
| `disableCommandsSentinel` | Override for sentinel mode | `nil` |

### Pod Scheduling

| Parameter | Description | Default |
|-----------|-------------|---------|
| `nodeSelector` | Node selector labels | `{}` |
| `tolerations` | Pod tolerations | `[]` |
| `affinity` | Pod affinity rules | `{}` |
| `podAntiAffinityPreset.type` | Preset: `soft` or `hard` (ignored if affinity set) | `""` |
| `podAntiAffinityPreset.topologyKey` | Topology key | `kubernetes.io/hostname` |
| `topologySpreadConstraints` | Topology spread constraints | `[]` |
| `priorityClassName` | Priority class name | `""` |
| `runtimeClassName` | Runtime class name (e.g., gVisor) | `""` |
| `terminationGracePeriodSeconds` | Graceful shutdown timeout | `30` |

### DNS Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `dnsPolicy` | Override pod DNS policy | `""` |
| `dnsConfig` | Custom DNS configuration | `{}` |

### Lifecycle & Diagnostics

| Parameter | Description | Default |
|-----------|-------------|---------|
| `gracefulFailover.enabled` | Cluster preStop hook: CLUSTER FAILOVER | `true` |
| `lifecycle` | Custom lifecycle hooks (overrides gracefulFailover) | `{}` |
| `diagnosticMode.enabled` | Override entrypoint with sleep infinity | `false` |

### Extra Resources

| Parameter | Description | Default |
|-----------|-------------|---------|
| `extraInitContainers` | Additional init containers | `[]` |
| `extraContainers` | Additional sidecar containers | `[]` |
| `extraVolumes` | Additional volumes | `[]` |
| `extraVolumeMounts` | Additional volume mounts for valkey container | `[]` |
| `extraValkeySecrets` | Convenience: mount Secrets into valkey container | `[]` |
| `extraValkeyConfigs` | Convenience: mount ConfigMaps into valkey container | `[]` |
| `env` | Simple key-value env vars for valkey container | `{}` |
| `extraEnvVars` | Additional env vars (full spec with valueFrom) | `[]` |

---

## Security

### Security Context Defaults

The chart ships with hardened security defaults:

```
┌─────────────────────────────────────────────────────┐
│ Pod-Level Security Context                          │
│                                                     │
│  runAsUser: 999                                     │
│  runAsGroup: 999                                    │
│  fsGroup: 999                                       │
│  runAsNonRoot: true                                 │
│  seccompProfile:                                    │
│    type: RuntimeDefault                             │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│ Container-Level Security Context                    │
│                                                     │
│  readOnlyRootFilesystem: true    ◄── NEW default    │
│  allowPrivilegeEscalation: false                    │
│  capabilities:                                      │
│    drop: [ALL]                                      │
└─────────────────────────────────────────────────────┘
```

With `readOnlyRootFilesystem: true` (the default), the chart automatically mounts writable emptyDir volumes at `/tmp` and `/run/valkey`. Set `containerSecurityContext.readOnlyRootFilesystem=false` to disable this.

### Metrics Exporter Security Context

The metrics sidecar has its own configurable security context:

```yaml
metrics:
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop: [ALL]
    readOnlyRootFilesystem: true
    runAsNonRoot: true
```

Override per-field or replace entirely:

```yaml
metrics:
  securityContext:
    runAsUser: 65534
    runAsNonRoot: true
```

---

## TLS/SSL

### Basic TLS Setup

```yaml
tls:
  enabled: true
  existingSecret: my-tls-secret   # Must exist with cert/key/CA
  disablePlaintext: true           # Disable port 6379, TLS-only on 6380
```

### TLS Configuration Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `tls.enabled` | Enable TLS | `false` |
| `tls.port` | TLS port | `6380` |
| `tls.existingSecret` | Existing Secret with certificates | `""` |
| `tls.certMountPath` | Mount path for certificates | `/etc/valkey/tls` |
| `tls.replication` | Enable TLS for replication traffic | `false` |
| `tls.authClients` | Client auth: `yes`, `no`, `optional` | `no` |
| `tls.disablePlaintext` | Disable non-TLS port entirely | `false` |
| `tls.certKey` | Key name for certificate in Secret | `tls.crt` |
| `tls.keyKey` | Key name for private key in Secret | `tls.key` |
| `tls.caKey` | Key name for CA certificate in Secret | `ca.crt` |
| `tls.dhParamsSecret` | Secret with DH parameters | `""` |
| `tls.ciphers` | Cipher suites (TLS 1.2) | `""` |
| `tls.ciphersuites` | Cipher suites (TLS 1.3) | `""` |

### Custom Certificate Key Names

If your TLS Secret uses non-standard key names:

```yaml
tls:
  enabled: true
  existingSecret: my-custom-certs
  certKey: server.crt
  keyKey: server.key
  caKey: root-ca.crt
```

This propagates consistently to all templates: volumes, configmaps, probes, CLI flags, and lifecycle hooks.

### cert-manager Integration

```yaml
tls:
  enabled: true
  certManager:
    enabled: true
    issuerRef:
      name: my-issuer
      kind: ClusterIssuer
    duration: 2160h      # 90 days
    renewBefore: 360h    # 15 days
```

### TLS Flow

```
┌──────────────┐     ┌────────────────────────┐
│ TLS Secret   │     │ cert-manager (optional) │
│              │     │                          │
│ tls.certKey  │◄────│ Certificate resource     │
│ tls.keyKey   │     │ auto-renewal             │
│ tls.caKey    │     └────────────────────────┘
└──────┬───────┘
       │  mounted as volume
       ▼
┌──────────────────────────────────────────────┐
│ All Pods                                     │
│                                              │
│  /etc/valkey/tls/                            │
│    ├── <certKey>    ──► valkey.conf          │
│    ├── <keyKey>         tls-cert-file        │
│    └── <caKey>          tls-key-file         │
│                         tls-ca-cert-file     │
│                                              │
│  Probes & CLI: --tls --cacert --cert --key   │
└──────────────────────────────────────────────┘
```

---

## Access Control Lists (ACL)

### Overview

```
┌────────────────────────────────────────────────────────┐
│ ACL System                                             │
│                                                        │
│  Default user ──► auto-managed (auth.password)         │
│                   DO NOT define in acl.users            │
│                                                        │
│  Custom users ──► defined in acl.users map             │
│                   each requires: permissions + password │
│                                                        │
│  Replication  ──► optional dedicated user               │
│    user           (acl.replicationUser)                 │
└────────────────────────────────────────────────────────┘
```

### ACL Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `acl.enabled` | Enable ACL (requires auth.enabled) | `false` |
| `acl.existingSecret` | Existing Secret with `users.acl` key | `""` |
| `acl.replicationUser` | Dedicated replication user | `""` |
| `acl.users` | Structured ACL user definitions | `{}` |

### ACL User Definition

```yaml
acl:
  enabled: true
  users:
    appuser:
      permissions: "~app:* +get +set +del"
      password: "secretpass"
    monitor:
      permissions: "+client +info +slowlog +latency +ping"
      existingPasswordSecret: "monitor-creds"
      passwordKey: "password"
```

### Validation Rules

The chart validates ACL configuration and fails with clear errors:

- `acl.enabled` requires `auth.enabled=true`
- The `default` user must NOT be defined in `acl.users` (it is auto-managed)
- Each user must have a `permissions` field
- `existingPasswordSecret` requires `passwordKey`
- Cannot set both `password` and `existingPasswordSecret` on the same user
- `acl.replicationUser` must be defined in `acl.users` with a password

---

## Monitoring & Metrics

### Metrics Exporter

The chart deploys an `oliver006/redis_exporter` sidecar when enabled:

```
┌─────────────────────────────────────────────┐
│ Pod                                         │
│                                             │
│ ┌──────────┐        ┌───────────────────┐   │
│ │ valkey   │◄──────►│ redis_exporter    │   │
│ │ :6379    │ scrape │ :9121             │   │
│ └──────────┘        │                   │   │
│                     │ /metrics endpoint │   │
│                     └──────────┬────────┘   │
│                                │             │
└────────────────────────────────┼─────────────┘
                                 │
                    ┌────────────▼─────────────┐
                    │ Prometheus               │
                    │                          │
                    │ ServiceMonitor or        │
                    │ PodMonitor               │
                    │                          │
                    │ ┌──────────────────────┐ │
                    │ │ PrometheusRule       │ │
                    │ │ alerting rules       │ │
                    │ └──────────────────────┘ │
                    └──────────────────────────┘
```

### Metrics Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `metrics.enabled` | Enable metrics sidecar | `false` |
| `metrics.image.repository` | Exporter image | `oliver006/redis_exporter` |
| `metrics.image.tag` | Exporter image tag | `v1.67.0` |
| `metrics.port` | Metrics port | `9121` |
| `metrics.resources` | Exporter resources | `{}` |
| `metrics.command` | Override exporter command | `[]` |
| `metrics.args` | Override exporter args | `[]` |
| `metrics.extraEnvs` | Extra env vars for exporter container | `[]` |
| `metrics.extraVolumeMounts` | Extra volume mounts for exporter | `[]` |
| `metrics.extraSecrets` | Extra secrets mounted into exporter | `[]` |
| `metrics.securityContext` | Exporter container security context | *(see below)* |

### ServiceMonitor

| Parameter | Description | Default |
|-----------|-------------|---------|
| `metrics.serviceMonitor.enabled` | Create ServiceMonitor | `false` |
| `metrics.serviceMonitor.namespace` | ServiceMonitor namespace | `""` (release namespace) |
| `metrics.serviceMonitor.interval` | Scrape interval | `30s` |
| `metrics.serviceMonitor.scrapeTimeout` | Scrape timeout | `""` |
| `metrics.serviceMonitor.labels` | Additional labels | `{}` |
| `metrics.serviceMonitor.relabelings` | Endpoint relabelings | `[]` |
| `metrics.serviceMonitor.metricRelabelings` | Metric relabelings | `[]` |
| `metrics.serviceMonitor.sampleLimit` | Per-scrape sample limit | `""` |
| `metrics.serviceMonitor.targetLimit` | Target limit | `""` |
| `metrics.serviceMonitor.honorLabels` | Honor target labels | `false` |
| `metrics.serviceMonitor.podTargetLabels` | Labels copied from pod to target | `[]` |

### PodMonitor

| Parameter | Description | Default |
|-----------|-------------|---------|
| `metrics.podMonitor.enabled` | Create PodMonitor | `false` |
| `metrics.podMonitor.namespace` | PodMonitor namespace | `""` (release namespace) |
| `metrics.podMonitor.interval` | Scrape interval | `30s` |
| `metrics.podMonitor.labels` | Additional labels | `{}` |
| `metrics.podMonitor.relabelings` | Endpoint relabelings | `[]` |
| `metrics.podMonitor.metricRelabelings` | Metric relabelings | `[]` |
| `metrics.podMonitor.sampleLimit` | Per-scrape sample limit | `""` |
| `metrics.podMonitor.targetLimit` | Target limit | `""` |
| `metrics.podMonitor.honorLabels` | Honor target labels | `false` |
| `metrics.podMonitor.podTargetLabels` | Labels copied from pod to target | `[]` |

### PrometheusRule

| Parameter | Description | Default |
|-----------|-------------|---------|
| `metrics.prometheusRule.enabled` | Create PrometheusRule | `false` |
| `metrics.prometheusRule.namespace` | Namespace | `""` |
| `metrics.prometheusRule.labels` | Additional labels | `{}` |
| `metrics.prometheusRule.rules` | Alerting rules | `[]` |

### Exporter Extras Example

```yaml
metrics:
  enabled: true
  extraEnvs:
    - name: REDIS_EXPORTER_LOG_FORMAT
      value: json
  extraSecrets:
    - name: exporter-tls
      mountPath: /etc/exporter/tls
  extraVolumeMounts:
    - name: custom-scripts
      mountPath: /scripts
```

---

## Persistence

### Per-Mode Persistence Overrides

```
┌──────────────────────────────────────────────────┐
│ Persistence Resolution                           │
│                                                  │
│  cluster mode:                                   │
│    cluster.persistence.size ──► if set, use it   │
│    cluster.persistence.storageClass              │
│                   │                              │
│                   ▼ fallback                     │
│    persistence.size ──► global default (8Gi)     │
│    persistence.storageClass                      │
│                                                  │
│  sentinel mode:                                  │
│    sentinel.dataPersistence.size ──► if set       │
│    sentinel.dataPersistence.storageClass          │
│                   │                              │
│                   ▼ fallback                     │
│    persistence.size ──► global default (8Gi)     │
│    persistence.storageClass                      │
│                                                  │
│  standalone mode:                                │
│    persistence.size ──► always uses global        │
│    persistence.storageClass                      │
└──────────────────────────────────────────────────┘
```

Example: larger storage for cluster, smaller for dev standalone:

```yaml
persistence:
  size: 8Gi          # default for standalone

cluster:
  persistence:
    size: 50Gi        # override for cluster mode
    storageClass: fast-ssd
```

### Data Layout

Each pod gets its own PVC via the StatefulSet's `volumeClaimTemplates`. Data is stored at `/data` inside the container, which contains:
- `dump.rdb` — RDB snapshots
- `appendonly.aof` — AOF persistence log
- `nodes.conf` — Cluster node configuration (cluster mode only)

---

## Networking

### External Access

| Parameter | Description | Default |
|-----------|-------------|---------|
| `externalAccess.enabled` | Expose Valkey outside the cluster | `false` |
| `externalAccess.service.type` | External service type | `LoadBalancer` |
| `externalAccess.service.port` | External service port | `6379` |
| `externalAccess.service.annotations` | Service annotations | `{}` |
| `externalAccess.service.loadBalancerSourceRanges` | Source IP ranges | `[]` |
| `externalAccess.service.externalTrafficPolicy` | Traffic policy | `Cluster` |

```
┌──────────────────────────────────────────────────────────┐
│ External Access (cluster mode)                           │
│                                                          │
│  External ──► LoadBalancer/NodePort per pod              │
│  Client       (service-per-pod.yaml)                     │
│                                                          │
│    ┌────────────┐  ┌────────────┐  ┌────────────┐       │
│    │ LB :6379   │  │ LB :6379   │  │ LB :6379   │  ...  │
│    │ Pod 0      │  │ Pod 1      │  │ Pod 2      │       │
│    └──────┬─────┘  └──────┬─────┘  └──────┬─────┘       │
│           │               │               │              │
│    ┌──────▼─────┐  ┌──────▼─────┐  ┌──────▼─────┐       │
│    │ valkey-0   │  │ valkey-1   │  │ valkey-2   │       │
│    └────────────┘  └────────────┘  └────────────┘       │
│                                                          │
│  External IP discovered via init container               │
│  and passed as --cluster-announce-ip                     │
└──────────────────────────────────────────────────────────┘
```

### Network Policy

| Parameter | Description | Default |
|-----------|-------------|---------|
| `networkPolicy.enabled` | Enable NetworkPolicy | `false` |
| `networkPolicy.allowExternal` | Allow connections from outside cluster | `true` |
| `networkPolicy.extraIngress` | Additional ingress rules | `[]` |
| `networkPolicy.extraEgress` | Additional egress rules | `[]` |

---

## Backup & Restore

### Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `backup.enabled` | Enable scheduled backup CronJob | `false` |
| `backup.schedule` | Cron schedule | `0 2 * * *` |
| `backup.retention` | Number of RDB backups to retain | `7` |
| `backup.concurrencyPolicy` | Concurrency policy | `Forbid` |
| `backup.sourceOrdinal` | Pod ordinal to backup from | `0` |
| `backup.storage.storageClass` | Backup PVC storage class | `""` |
| `backup.storage.size` | Backup PVC size | `10Gi` |
| `backup.storage.accessModes` | Backup PVC access modes | `[ReadWriteOnce]` |
| `backup.storage.existingClaim` | Use existing PVC | `""` |
| `backup.resources` | Backup container resources | `{}` |
| `backup.successfulJobsHistoryLimit` | Successful job history | `3` |
| `backup.failedJobsHistoryLimit` | Failed job history | `1` |

### Backup Flow

```
  CronJob (schedule: "0 2 * * *")
       │
       ▼
  Job Pod
       │
       ├─► valkey-cli --rdb /backup/dump-TIMESTAMP.rdb
       │   (connects to sourceOrdinal pod)
       │
       ├─► Verify backup file is non-empty
       │
       └─► Retention: keep last N, delete older
              │
              ▼
         Backup PVC (/backup/dump-*.rdb)
```

---

## Autoscaling

### Horizontal Pod Autoscaler

| Parameter | Description | Default |
|-----------|-------------|---------|
| `autoscaling.hpa.enabled` | Enable HPA (standalone only) | `false` |
| `autoscaling.hpa.minReplicas` | Minimum replicas | `1` |
| `autoscaling.hpa.maxReplicas` | Maximum replicas | `5` |
| `autoscaling.hpa.targetCPU` | Target CPU utilization % | `80` |
| `autoscaling.hpa.targetMemory` | Target memory utilization % | `""` |

### Vertical Pod Autoscaler

| Parameter | Description | Default |
|-----------|-------------|---------|
| `autoscaling.vpa.enabled` | Enable VPA | `false` |
| `autoscaling.vpa.updateMode` | Update mode: `Off`, `Initial`, `Auto` | `Auto` |
| `autoscaling.vpa.controlledResources` | Controlled resources | `[cpu, memory]` |
| `autoscaling.vpa.minAllowed` | Minimum allowed resources | `{}` |
| `autoscaling.vpa.maxAllowed` | Maximum allowed resources | `{}` |

---

## Usage Examples

### Standalone with custom password and memory limit

```yaml
# values-standalone.yaml
mode: standalone
auth:
  password: "my-secure-password"
config:
  maxmemory: "512mb"
  maxmemoryPolicy: "allkeys-lru"
resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: "1"
    memory: 1Gi
persistence:
  size: 10Gi
```

```bash
helm install my-valkey ./helm/percona-valkey -f values-standalone.yaml
```

### Cluster with 9 nodes and per-mode persistence

```yaml
# values-cluster.yaml
mode: cluster
cluster:
  replicas: 9
  replicasPerPrimary: 2
  nodeTimeout: 5000
  persistence:
    size: 50Gi
    storageClass: fast-ssd
auth:
  password: "cluster-password"
resourcePreset: medium
podAntiAffinityPreset:
  type: soft
  topologyKey: kubernetes.io/hostname
```

```bash
helm install my-valkey ./helm/percona-valkey -f values-cluster.yaml
```

### Sentinel with monitoring

```yaml
# values-sentinel.yaml
mode: sentinel
sentinel:
  replicas: 3
  sentinelReplicas: 3
  dataPersistence:
    size: 20Gi
auth:
  password: "sentinel-password"
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
    interval: 15s
    relabelings:
      - sourceLabels: [__name__]
        action: keep
        regex: "redis_(up|connected_clients|memory_used_bytes)"
    sampleLimit: 5000
  prometheusRule:
    enabled: true
    rules:
      - alert: ValkeyDown
        expr: redis_up == 0
        for: 5m
        labels:
          severity: critical
```

### Hardened image with TLS and custom cert keys

```yaml
# values-hardened-tls.yaml
image:
  variant: hardened
tls:
  enabled: true
  existingSecret: my-custom-certs
  certKey: server.crt
  keyKey: server.key
  caKey: root-ca.crt
  disablePlaintext: true
  authClients: "yes"
auth:
  password: "tls-password"
```

### ACL with multiple users

```yaml
# values-acl.yaml
auth:
  password: "admin-password"
acl:
  enabled: true
  replicationUser: repluser
  users:
    appuser:
      permissions: "~app:* +get +set +del +exists +expire"
      password: "app-secret"
    readonly:
      permissions: "~* +get +mget +scan +keys +info"
      password: "readonly-secret"
    repluser:
      permissions: "+replconf +psync +ping"
      password: "repl-secret"
```

### Cache-only Deployment (no persistence)

```yaml
# values-cache.yaml
mode: standalone
standalone:
  useDeployment: true
  strategy:
    type: RollingUpdate
persistence:
  enabled: false
config:
  maxmemory: "1gb"
  maxmemoryPolicy: "allkeys-lru"
resourcePreset: small
```

### Custom Valkey configuration

```yaml
# values-custom.yaml
config:
  logLevel: verbose
  disklessSync: true
  minReplicasToWrite: 1
  minReplicasMaxLag: 10
  customConfig: |
    tcp-backlog 511
    timeout 300
    tcp-keepalive 60
    databases 16
    hz 10
    dynamic-hz yes
```

---

## Operations

### Get the password

```bash
kubectl get secret <release-name>-percona-valkey -o jsonpath="{.data.valkey-password}" | base64 -d
```

### Connect to Valkey

```bash
# Port-forward to local machine
kubectl port-forward svc/<release-name>-percona-valkey 6379:6379

# Connect
valkey-cli -a $(kubectl get secret <release-name>-percona-valkey -o jsonpath="{.data.valkey-password}" | base64 -d)
```

### Check cluster status (cluster mode)

```bash
kubectl exec <release-name>-percona-valkey-0 -- \
  valkey-cli -a $(kubectl get secret <release-name>-percona-valkey -o jsonpath="{.data.valkey-password}" | base64 -d) \
  cluster info

kubectl exec <release-name>-percona-valkey-0 -- \
  valkey-cli -a $(kubectl get secret <release-name>-percona-valkey -o jsonpath="{.data.valkey-password}" | base64 -d) \
  cluster nodes
```

### Upgrade

```bash
helm upgrade my-valkey ./helm/percona-valkey -f my-values.yaml
```

The StatefulSet includes a `checksum/config` annotation on pods, so ConfigMap changes trigger a rolling restart automatically.

### Scale cluster up

Increase the replica count and run `helm upgrade`. The `post-upgrade` hook Job automatically:
1. Detects new pods that are not yet part of the cluster
2. Adds them with `valkey-cli --cluster add-node`
3. Converts excess masters to replicas (maintains the `replicasPerPrimary` ratio)
4. Rebalances hash slots across all masters

```
  helm upgrade --set cluster.replicas=8
       │
       ▼
  New pods created (pods 6, 7)
       │
       ▼
  post-upgrade Job: cluster-scale-job
       │
       ├─► Wait for new pods to PONG
       ├─► Add to cluster (--cluster add-node)
       ├─► Convert excess masters to replicas
       └─► Rebalance hash slots
              │
              ▼
         Cluster: 4 primaries + 4 replicas
```

```bash
# Scale from 6 to 8 nodes
helm upgrade my-valkey ./helm/percona-valkey \
  --set mode=cluster \
  --set cluster.replicas=8 \
  --set auth.password=<your-password>

# Monitor the scale job
kubectl logs -f job/my-valkey-percona-valkey-cluster-scale

# Verify cluster health
kubectl exec my-valkey-percona-valkey-0 -- valkey-cli -a <password> cluster info
kubectl exec my-valkey-percona-valkey-0 -- valkey-cli -a <password> cluster nodes
```

**Important:** Always scale in multiples of `(1 + replicasPerPrimary)` for balanced distribution. For example, with `replicasPerPrimary: 1`, scale in steps of 2 (6 -> 8 -> 10).

### Scale cluster down

Reduce the replica count and run `helm upgrade`. The `post-upgrade` hook Job automatically:
1. Waits for Valkey's automatic failover (replicas of terminated primaries get promoted)
2. Runs `--cluster fix` if any slots remain on dead nodes
3. Removes dead nodes from the cluster via `cluster forget`
4. Rebalances remaining slots

The pre-upgrade precheck Job (enabled by default) blocks unsafe scale-downs before they happen.

```bash
# Scale from 8 to 6 nodes
helm upgrade my-valkey ./helm/percona-valkey \
  --set mode=cluster \
  --set cluster.replicas=6 \
  --set auth.password=<your-password>

# Monitor the scale job
kubectl logs -f job/my-valkey-percona-valkey-cluster-scale

# Verify cluster health
kubectl exec my-valkey-percona-valkey-0 -- valkey-cli -a <password> cluster info

# Clean up orphaned PVCs from removed pods
kubectl delete pvc data-my-valkey-percona-valkey-6 data-my-valkey-percona-valkey-7
```

**Warning:** When scaling down, ensure that every primary being removed has at least one replica that will survive. Losing both a primary and all its replicas causes data loss for that shard's hash slots.

### Uninstall

```bash
helm uninstall my-valkey
```

**Note:** PVCs created by the StatefulSet are not deleted automatically. To remove them:

```bash
kubectl delete pvc -l app.kubernetes.io/instance=my-valkey
```

---

## Testing

### Lint the chart

```bash
# Lint all variants
helm lint ./helm/percona-valkey/
helm lint ./helm/percona-valkey/ --set mode=cluster
helm lint ./helm/percona-valkey/ --set mode=sentinel
helm lint ./helm/percona-valkey/ --set image.variant=hardened
helm lint ./helm/percona-valkey/ --set mode=cluster,image.variant=hardened
```

### Render templates locally (dry run)

```bash
# Standalone mode
helm template test ./helm/percona-valkey/

# Cluster mode
helm template test ./helm/percona-valkey/ --set mode=cluster

# Sentinel mode
helm template test ./helm/percona-valkey/ --set mode=sentinel

# With TLS
helm template test ./helm/percona-valkey/ --set tls.enabled=true --set tls.existingSecret=x

# Validate against Kubernetes API
helm template test ./helm/percona-valkey/ | kubectl apply --dry-run=client -f -
```

### Run the comprehensive test suite

```bash
# From the repository root (requires kubectl connected to a cluster)
bash ./helm/percona-valkey/test-chart.sh
```

The test suite includes:
- **Lint tests**: All modes, variants, and feature combinations
- **Template render tests**: Validates rendered YAML for every feature
- **Deployment tests**: Full install/upgrade/test/uninstall cycles
- **Validation tests**: Ensures invalid configurations fail with clear errors

### Run the connection test after install

```bash
helm test my-valkey -n <namespace>
```

This runs a pod that executes `valkey-cli ping` against the service and checks for a `PONG` response.

---

## Troubleshooting

### Pods stuck in CrashLoopBackOff

Check the startup probe configuration. The default allows up to 150 seconds (30 failures * 5s period) for Valkey to start. Increase `startupProbe.failureThreshold` for slow storage backends.

### Cluster readiness probe failing

In cluster mode, the readiness probe checks `cluster_state:ok`. Until the cluster-init Job completes, all pods will report `cluster_state:fail`. This is expected behavior — the pods will become ready after cluster formation.

Check the cluster-init Job logs:

```bash
kubectl logs job/<release-name>-percona-valkey-cluster-init
```

### Cluster-init Job stuck waiting

The Job waits for all pods to respond to `valkey-cli ping`. If a pod never starts:

```bash
# Check pod status
kubectl get pods -l app.kubernetes.io/instance=<release-name>

# Check pod events
kubectl describe pod <release-name>-percona-valkey-0

# Check PVC binding
kubectl get pvc -l app.kubernetes.io/instance=<release-name>
```

### Permission denied errors with hardened image

The hardened variant runs with `readOnlyRootFilesystem: true`. Ensure that all writable paths (`/data`, `/tmp`, `/run/valkey`) have proper volume mounts. If Valkey tries to write to an unexpected path, check `config.customConfig` for directives that reference non-mounted directories.

### Permission denied with default security context

Since `readOnlyRootFilesystem` defaults to `true`, all modes automatically get emptyDir mounts at `/tmp` and `/run/valkey`. If you encounter write errors at other paths, either:
- Add the path via `extraVolumeMounts` + `extraVolumes`
- Set `containerSecurityContext.readOnlyRootFilesystem=false` to disable

### ACL validation errors

The chart validates ACL configuration during template rendering. Common errors:

```
acl.users.default: the default user is auto-managed by the chart — do not define it in acl.users
acl.users.myuser: permissions field is required
acl.users.myuser: existingPasswordSecret requires passwordKey
```

Fix by ensuring each user has `permissions` set, and do not include `default` in `acl.users`.

### TLS connection issues

Verify the Secret exists and contains the expected keys:

```bash
kubectl get secret <tls-secret> -o jsonpath='{.data}' | jq 'keys'
```

If using custom key names (`tls.certKey`, `tls.keyKey`, `tls.caKey`), ensure they match the actual keys in the Secret.

---

## Known Limitations

1. **Scale-down requires care**: The `cluster.precheckBeforeScaleDown` pre-upgrade hook now blocks unsafe scale-downs by default. If the pre-check is disabled, aggressive scale-down can still cause data loss when both a primary and all its replicas are removed simultaneously. Always scale in steps of `(1 + replicasPerPrimary)` and verify `cluster nodes` between steps.

2. **Jobs default to RPM image**: The cluster-init Job, cluster-scale Job, backup CronJob, and helm test pod use the RPM image variant by default because they need shell utilities (`sh`, `grep`, `valkey-cli`). Use `image.jobs.repository` and `image.jobs.tag` to override with a custom image in air-gapped environments.

3. **Auto-generated passwords and `helm template`**: Auto-generated passwords are preserved across `helm upgrade` (the chart looks up the existing Secret). However, `helm template` always generates a new random password since it cannot access the cluster. Use `auth.password` or `auth.existingSecret` if you need deterministic output.

4. **External access not supported in Sentinel mode**: The chart validates and rejects `externalAccess.enabled=true` when `mode=sentinel`.

5. **Deployment mode requires no persistence**: `standalone.useDeployment=true` requires `persistence.enabled=false`. The chart validates this constraint.
