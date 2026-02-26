# Percona Valkey Helm Chart

A production-ready Helm chart for deploying Percona Valkey on Kubernetes. Supports both **standalone** and **native Valkey Cluster** modes with two image variants: RPM-based (UBI9) and Hardened (DHI).

## Chart Structure

```
helm/percona-valkey/
├── Chart.yaml                         # Chart metadata (appVersion: 9.0.3)
├── values.yaml                        # All configurable parameters
├── .helmignore                        # Files excluded from chart packaging
└── templates/
    ├── _helpers.tpl                   # Template helpers (names, labels, image resolution)
    ├── NOTES.txt                      # Post-install connection instructions
    ├── secret.yaml                    # Valkey password (auto-generated or user-supplied)
    ├── serviceaccount.yaml            # Dedicated ServiceAccount
    ├── configmap.yaml                 # valkey.conf (base config + cluster directives)
    ├── service.yaml                   # Client-facing ClusterIP service
    ├── service-headless.yaml          # Headless service for StatefulSet DNS + cluster bus
    ├── statefulset.yaml               # Core workload (standalone or cluster)
    ├── pdb.yaml                       # PodDisruptionBudget (cluster mode only)
    ├── cluster-init-job.yaml          # Helm post-install hook: cluster formation
    └── tests/
        └── test-connection.yaml       # helm test: valkey-cli ping
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

### Install with hardened image

```bash
helm install my-valkey ./helm/percona-valkey --set image.variant=hardened
```

### Install with custom values file

```bash
helm install my-valkey ./helm/percona-valkey -f my-values.yaml
```

## Deployment Modes

### Standalone Mode (`mode: standalone`)

The default mode. Deploys a single Valkey instance as a 1-replica StatefulSet.

- Pod management policy: `OrderedReady`
- Readiness probe: `valkey-cli ping` (PONG check)
- Suitable for development, caching, and single-instance use cases

### Cluster Mode (`mode: cluster`)

Deploys a native Valkey Cluster using a multi-replica StatefulSet with automatic cluster formation.

- Default: 6 nodes (3 primaries + 3 replicas with `replicasPerPrimary: 1`)
- Pod management policy: `Parallel` (all pods start simultaneously)
- Readiness probe: `valkey-cli cluster info` (checks `cluster_state:ok`)
- PodDisruptionBudget enabled by default (`maxUnavailable: 1`)
- Cluster bus port 16379 exposed on headless service

#### How Cluster Formation Works

1. The StatefulSet creates N pods, each configured with `cluster-enabled yes` in the ConfigMap
2. Each pod receives its own IP via the Kubernetes Downward API (`status.podIP`)
3. The pod IP is passed as `--cluster-announce-ip $(POD_IP)` through the `VALKEY_EXTRA_FLAGS` environment variable
4. A headless service with `publishNotReadyAddresses: true` provides DNS resolution before pods pass readiness
5. A Helm **post-install** hook Job (`cluster-init-job.yaml`) runs after all pods are created:
   - Waits for every pod to respond to `valkey-cli ping`
   - Checks idempotency: if `cluster_state:ok`, skips initialization
   - Runs `valkey-cli --cluster create --cluster-yes` with all node addresses
6. Once the cluster is formed, readiness probes start passing (`cluster_state:ok`), and the pods become ready

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

## Configuration

### Parameters Reference

#### Global

| Parameter | Description | Default |
|-----------|-------------|---------|
| `nameOverride` | Override chart name | `""` |
| `fullnameOverride` | Override full release name | `""` |
| `mode` | Deployment mode: `standalone` or `cluster` | `standalone` |

#### Image

| Parameter | Description | Default |
|-----------|-------------|---------|
| `image.repository` | Image repository | `perconalab/valkey` |
| `image.variant` | Image variant: `rpm` or `hardened` | `rpm` |
| `image.tag` | Override image tag | `""` (auto-resolved from appVersion) |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `image.pullSecrets` | Image pull secrets | `[]` |

#### Authentication

| Parameter | Description | Default |
|-----------|-------------|---------|
| `auth.enabled` | Enable password authentication | `true` |
| `auth.password` | Valkey password (auto-generated 16-char if empty) | `""` |
| `auth.existingSecret` | Use existing Secret (must contain key `valkey-password`) | `""` |

#### Valkey Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `config.maxmemory` | Max memory limit (e.g., `256mb`, `1gb`) | `""` |
| `config.maxmemoryPolicy` | Eviction policy (e.g., `allkeys-lru`) | `""` |
| `config.bind` | Bind address | `0.0.0.0` |
| `config.extraFlags` | Additional flags passed via `VALKEY_EXTRA_FLAGS` env var | `""` |
| `config.customConfig` | Custom valkey.conf content appended to generated config | `""` |

#### Cluster Mode

| Parameter | Description | Default |
|-----------|-------------|---------|
| `cluster.replicas` | Total number of cluster nodes | `6` |
| `cluster.replicasPerPrimary` | Replicas per primary node | `1` |
| `cluster.nodeTimeout` | Cluster node timeout in milliseconds | `15000` |
| `cluster.busPort` | Cluster bus port | `16379` |

#### Standalone Mode

| Parameter | Description | Default |
|-----------|-------------|---------|
| `standalone.replicas` | Number of standalone replicas | `1` |

#### StatefulSet

| Parameter | Description | Default |
|-----------|-------------|---------|
| `statefulset.updateStrategy.type` | Update strategy | `RollingUpdate` |
| `statefulset.podManagementPolicy` | Override pod management policy | `""` (auto: Parallel for cluster, OrderedReady for standalone) |
| `statefulset.annotations` | StatefulSet annotations | `{}` |
| `statefulset.labels` | Additional StatefulSet labels | `{}` |

#### Pod

| Parameter | Description | Default |
|-----------|-------------|---------|
| `podAnnotations` | Pod annotations | `{}` |
| `podLabels` | Additional pod labels | `{}` |

#### Security Context

| Parameter | Description | Default |
|-----------|-------------|---------|
| `securityContext.runAsUser` | Pod-level UID | `999` |
| `securityContext.runAsGroup` | Pod-level GID | `999` |
| `securityContext.fsGroup` | Filesystem group | `999` |
| `securityContext.runAsNonRoot` | Enforce non-root | `true` |
| `containerSecurityContext.readOnlyRootFilesystem` | Read-only root filesystem | `false` |
| `containerSecurityContext.allowPrivilegeEscalation` | Allow privilege escalation | `false` |
| `containerSecurityContext.capabilities.drop` | Dropped capabilities | `[ALL]` |

#### Service

| Parameter | Description | Default |
|-----------|-------------|---------|
| `service.type` | Service type | `ClusterIP` |
| `service.port` | Service port | `6379` |
| `service.annotations` | Service annotations | `{}` |

#### Persistence

| Parameter | Description | Default |
|-----------|-------------|---------|
| `persistence.enabled` | Enable persistent storage | `true` |
| `persistence.storageClass` | Storage class name | `""` (default provisioner) |
| `persistence.accessModes` | PVC access modes | `[ReadWriteOnce]` |
| `persistence.size` | PVC size | `8Gi` |
| `persistence.annotations` | PVC annotations | `{}` |

#### Health Probes

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

#### Resources

| Parameter | Description | Default |
|-----------|-------------|---------|
| `resources.limits` | CPU/memory limits | `{}` |
| `resources.requests` | CPU/memory requests | `{}` |

#### ServiceAccount & RBAC

| Parameter | Description | Default |
|-----------|-------------|---------|
| `serviceAccount.create` | Create ServiceAccount | `true` |
| `serviceAccount.name` | ServiceAccount name override | `""` |
| `serviceAccount.annotations` | ServiceAccount annotations | `{}` |
| `rbac.create` | Create RBAC resources | `true` |

#### PodDisruptionBudget

| Parameter | Description | Default |
|-----------|-------------|---------|
| `pdb.enabled` | Enable PDB (cluster mode only) | `true` |
| `pdb.minAvailable` | Minimum available pods | `""` |
| `pdb.maxUnavailable` | Maximum unavailable pods | `1` |

#### Node Placement

| Parameter | Description | Default |
|-----------|-------------|---------|
| `nodeSelector` | Node selector labels | `{}` |
| `tolerations` | Pod tolerations | `[]` |
| `affinity` | Pod affinity rules | `{}` |

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

### Cluster with 9 nodes (3 primaries + 6 replicas)

```yaml
# values-cluster.yaml
mode: cluster
cluster:
  replicas: 9
  replicasPerPrimary: 2
  nodeTimeout: 5000
auth:
  password: "cluster-password"
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: "2"
    memory: 2Gi
persistence:
  size: 20Gi
  storageClass: "fast-ssd"
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: percona-valkey
          topologyKey: kubernetes.io/hostname
```

```bash
helm install my-valkey ./helm/percona-valkey -f values-cluster.yaml
```

### Hardened image with existing secret

```bash
# Create the secret first
kubectl create secret generic my-valkey-secret \
  --from-literal=valkey-password="my-password"

# Install with existing secret
helm install my-valkey ./helm/percona-valkey \
  --set image.variant=hardened \
  --set auth.existingSecret=my-valkey-secret
```

### Custom Valkey configuration

```yaml
# values-custom.yaml
config:
  customConfig: |
    tcp-backlog 511
    timeout 300
    tcp-keepalive 60
    loglevel notice
    databases 16
    hz 10
    dynamic-hz yes
```

## Testing

### Lint the chart

```bash
# Lint all variants
helm lint ./helm/percona-valkey/
helm lint ./helm/percona-valkey/ --set mode=cluster
helm lint ./helm/percona-valkey/ --set image.variant=hardened
helm lint ./helm/percona-valkey/ --set mode=cluster,image.variant=hardened
```

### Render templates locally (dry run)

```bash
# Standalone mode
helm template test ./helm/percona-valkey/

# Cluster mode
helm template test ./helm/percona-valkey/ --set mode=cluster

# Hardened variant
helm template test ./helm/percona-valkey/ --set image.variant=hardened

# Validate against Kubernetes API
helm template test ./helm/percona-valkey/ | kubectl apply --dry-run=client -f -
```

### Run the connection test after install

```bash
helm test my-valkey -n <namespace>
```

This runs a pod that executes `valkey-cli ping` against the service and checks for a `PONG` response.

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

### Uninstall

```bash
helm uninstall my-valkey
```

**Note:** PVCs created by the StatefulSet are not deleted automatically. To remove them:

```bash
kubectl delete pvc -l app.kubernetes.io/instance=my-valkey
```

## Architecture Details

### Entrypoint Integration

The chart passes configuration to Valkey through environment variables that the `docker-entrypoint.sh` script processes:

| Env Variable | Source | Purpose |
|-------------|--------|---------|
| `VALKEY_PASSWORD` | Secret | Appended as `--requirepass` by entrypoint |
| `VALKEY_MAXMEMORY` | ConfigMap / values | Appended as `--maxmemory` by entrypoint |
| `VALKEY_BIND` | ConfigMap / values | Appended as `--bind` by entrypoint |
| `VALKEY_EXTRA_FLAGS` | Values + Downward API | Additional flags (includes `--cluster-announce-ip` in cluster mode) |

The container args are `["/etc/valkey/valkey.conf"]` — the entrypoint script detects the `.conf` suffix and prepends `valkey-server`.

### Networking

- **Client service** (`service.yaml`): ClusterIP service on port 6379 for application connections
- **Headless service** (`service-headless.yaml`): Provides stable DNS names for each pod (`<release>-percona-valkey-{0..N}.<release>-percona-valkey-headless.<namespace>.svc.cluster.local`)
  - `publishNotReadyAddresses: true` ensures DNS resolution works before pods pass readiness (required for cluster formation)
  - In cluster mode, exposes the cluster bus port (16379) for inter-node communication

### Persistence

Each pod gets its own PVC via the StatefulSet's `volumeClaimTemplates`. Data is stored at `/data` inside the container, which contains:
- `dump.rdb` — RDB snapshots
- `appendonly.aof` — AOF persistence log
- `nodes.conf` — Cluster node configuration (cluster mode only)

### Config Rollout

Pod annotations include `checksum/config` computed from the ConfigMap content. When `valkey.conf` changes (via `helm upgrade`), the checksum changes and triggers a rolling restart of all pods.

## Known Limitations

1. **Cluster scaling requires manual intervention**: Adding or removing nodes from an existing Valkey Cluster is not automated. You must manually run `valkey-cli --cluster add-node` or `valkey-cli --cluster del-node` and then rebalance slots with `valkey-cli --cluster rebalance`.

2. **Cluster-init Job runs only on initial install**: The `cluster-init-job.yaml` is a Helm `post-install` hook, not `post-upgrade`. Scaling the cluster up after the initial install requires manual node addition.

3. **Hardened image uses RPM image for Jobs**: The cluster-init Job and helm test pod always use the RPM image variant (`percona-valkey.rpmImage`), because they need shell utilities (`sh`, `grep`, `valkey-cli`) that are not available in the distroless hardened image.

4. **Password rotation requires pod restart**: Changing `auth.password` or the referenced Secret updates the Secret object, but running pods must be restarted to pick up the new password (the entrypoint reads it at startup). Use `kubectl rollout restart statefulset/<release>-percona-valkey`.

5. **No built-in Sentinel support**: This chart supports standalone and native Valkey Cluster modes only. Sentinel-based HA is not included.

6. **No TLS support**: TLS termination is not configured in this chart version. Use a service mesh (Istio, Linkerd) or add TLS configuration via `config.customConfig` and volume-mounted certificates.

7. **Auto-generated passwords change on upgrade**: If `auth.password` is left empty, Helm generates a random password on each `helm template` / `helm upgrade`. To avoid this, either set an explicit password or use `auth.existingSecret` to manage the Secret outside of Helm.

8. **Single-namespace deployment**: All resources are deployed into the release namespace. Cross-namespace cluster topologies are not supported.

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
