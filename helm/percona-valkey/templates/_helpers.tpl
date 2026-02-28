{{/*
Expand the name of the chart.
*/}}
{{- define "percona-valkey.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "percona-valkey.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "percona-valkey.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "percona-valkey.labels" -}}
helm.sh/chart: {{ include "percona-valkey.chart" . }}
{{ include "percona-valkey.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "percona-valkey.selectorLabels" -}}
app.kubernetes.io/name: {{ include "percona-valkey.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Resolve the image with tag based on variant.
RPM variant: perconalab/valkey:9.0.3
Hardened variant: perconalab/valkey:9.0.3-hardened
*/}}
{{- define "percona-valkey.image" -}}
{{- $tag := .Values.image.tag -}}
{{- if not $tag -}}
  {{- if eq .Values.image.variant "hardened" -}}
    {{- $tag = printf "%s-hardened" .Chart.AppVersion -}}
  {{- else -}}
    {{- $tag = .Chart.AppVersion -}}
  {{- end -}}
{{- end -}}
{{- $repo := .Values.image.repository -}}
{{- if and .Values.global .Values.global.imageRegistry -}}
  {{- $repo = printf "%s/%s" .Values.global.imageRegistry $repo -}}
{{- end -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end }}

{{/*
RPM image (always used for Jobs that need shell tools).
Supports image.jobs.repository and image.jobs.tag overrides for air-gapped environments.
*/}}
{{- define "percona-valkey.rpmImage" -}}
{{- $repo := .Values.image.repository -}}
{{- $tag := .Chart.AppVersion -}}
{{- if and .Values.image.jobs .Values.image.jobs.repository -}}
  {{- $repo = .Values.image.jobs.repository -}}
{{- end -}}
{{- if and .Values.image.jobs .Values.image.jobs.tag -}}
  {{- $tag = .Values.image.jobs.tag -}}
{{- end -}}
{{- if and .Values.global .Values.global.imageRegistry -}}
  {{- $repo = printf "%s/%s" .Values.global.imageRegistry $repo -}}
{{- end -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end }}

{{/*
Metrics exporter image with optional global registry prefix.
*/}}
{{- define "percona-valkey.metricsImage" -}}
{{- $repo := .Values.metrics.image.repository -}}
{{- if and .Values.global .Values.global.imageRegistry -}}
  {{- $repo = printf "%s/%s" .Values.global.imageRegistry $repo -}}
{{- end -}}
{{- printf "%s:%s" $repo .Values.metrics.image.tag -}}
{{- end }}

{{/*
Service account name.
*/}}
{{- define "percona-valkey.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "percona-valkey.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Secret name (existing or generated).
*/}}
{{- define "percona-valkey.secretName" -}}
{{- if .Values.auth.existingSecret }}
{{- .Values.auth.existingSecret }}
{{- else }}
{{- include "percona-valkey.fullname" . }}
{{- end }}
{{- end }}

{{/*
ACL secret name (existing or chart-managed).
*/}}
{{- define "percona-valkey.aclSecretName" -}}
{{- if .Values.acl.existingSecret }}
{{- .Values.acl.existingSecret }}
{{- else }}
{{- include "percona-valkey.fullname" . }}
{{- end }}
{{- end }}

{{/*
TLS secret name (existing or generated from cert-manager).
*/}}
{{- define "percona-valkey.tlsSecretName" -}}
{{- if .Values.tls.existingSecret }}
{{- .Values.tls.existingSecret }}
{{- else }}
{{- printf "%s-tls" (include "percona-valkey.fullname" .) }}
{{- end }}
{{- end }}

{{/*
TLS CLI flags for valkey-cli commands (probes, lifecycle hooks, jobs).
Includes --cert and --key for mutual TLS support (tls-auth-clients yes).
Returns empty string if TLS is disabled.
*/}}
{{- define "percona-valkey.tlsCliFlags" -}}
{{- if .Values.tls.enabled -}}
--tls --cacert {{ .Values.tls.certMountPath }}/ca.crt --cert {{ .Values.tls.certMountPath }}/tls.crt --key {{ .Values.tls.certMountPath }}/tls.key
{{- end -}}
{{- end }}

{{/*
Replica count based on mode.
*/}}
{{- define "percona-valkey.replicaCount" -}}
{{- if eq .Values.mode "cluster" }}
{{- .Values.cluster.replicas }}
{{- else if eq .Values.mode "sentinel" }}
{{- .Values.sentinel.replicas }}
{{- else }}
{{- .Values.standalone.replicas }}
{{- end }}
{{- end }}

{{/*
Resource presets. Returns resources dict based on preset name.
Explicit resources.limits/requests always override presets.
*/}}
{{- define "percona-valkey.resourcePreset" -}}
{{- if eq .Values.resourcePreset "nano" }}
requests:
  cpu: 100m
  memory: 128Mi
limits:
  cpu: 250m
  memory: 256Mi
{{- else if eq .Values.resourcePreset "micro" }}
requests:
  cpu: 250m
  memory: 256Mi
limits:
  cpu: 500m
  memory: 512Mi
{{- else if eq .Values.resourcePreset "small" }}
requests:
  cpu: 500m
  memory: 512Mi
limits:
  cpu: "1"
  memory: 1Gi
{{- else if eq .Values.resourcePreset "medium" }}
requests:
  cpu: "1"
  memory: 1Gi
limits:
  cpu: "2"
  memory: 2Gi
{{- else if eq .Values.resourcePreset "large" }}
requests:
  cpu: "2"
  memory: 2Gi
limits:
  cpu: "4"
  memory: 4Gi
{{- else if eq .Values.resourcePreset "xlarge" }}
requests:
  cpu: "4"
  memory: 4Gi
limits:
  cpu: "8"
  memory: 8Gi
{{- end }}
{{- end }}

{{/*
Resolve effective resources: explicit values override preset.
*/}}
{{- define "percona-valkey.resources" -}}
{{- if or .Values.resources.limits .Values.resources.requests }}
{{- toYaml .Values.resources }}
{{- else }}
{{- include "percona-valkey.resourcePreset" . }}
{{- end }}
{{- end }}

{{/*
Pod management policy based on mode.
*/}}
{{- define "percona-valkey.podManagementPolicy" -}}
{{- if .Values.statefulset.podManagementPolicy }}
{{- .Values.statefulset.podManagementPolicy }}
{{- else if eq .Values.mode "cluster" }}
{{- "Parallel" }}
{{- else }}
{{- "OrderedReady" }}
{{- end }}
{{- end }}

{{/*
Pod anti-affinity based on preset.
Returns empty string if preset type is empty or affinity is explicitly set.
*/}}
{{- define "percona-valkey.podAntiAffinity" -}}
{{- if and .Values.podAntiAffinityPreset.type (not .Values.affinity) -}}
{{- $labels := include "percona-valkey.selectorLabels" . -}}
{{- if eq .Values.podAntiAffinityPreset.type "hard" }}
podAntiAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          {{- $labels | nindent 10 }}
      topologyKey: {{ .Values.podAntiAffinityPreset.topologyKey }}
{{- else if eq .Values.podAntiAffinityPreset.type "soft" }}
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchLabels:
            {{- $labels | nindent 12 }}
        topologyKey: {{ .Values.podAntiAffinityPreset.topologyKey }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Nil-safe check for externalAccess.enabled.
Returns "true" (string) if enabled, empty string otherwise.
*/}}
{{- define "percona-valkey.externalAccessEnabled" -}}
{{- if .Values.externalAccess }}
{{- if .Values.externalAccess.enabled }}true{{- end }}
{{- end }}
{{- end }}

{{/*
Nil-safe check for externalAccess.enabled AND cluster mode.
Returns "true" (string) if both conditions met, empty string otherwise.
*/}}
{{- define "percona-valkey.externalAccessCluster" -}}
{{- if and (include "percona-valkey.externalAccessEnabled" .) (eq .Values.mode "cluster") }}true{{- end }}
{{- end }}

{{/*
Nil-safe check for externalAccess.enabled AND standalone mode.
Returns "true" (string) if both conditions met, empty string otherwise.
*/}}
{{- define "percona-valkey.externalAccessStandalone" -}}
{{- if and (include "percona-valkey.externalAccessEnabled" .) (eq .Values.mode "standalone") }}true{{- end }}
{{- end }}

{{/*
Returns "true" if any ACL user has existingPasswordSecret (needs init container).
*/}}
{{- define "percona-valkey.aclNeedsInitContainer" -}}
{{- if .Values.acl.enabled -}}
{{- range $user, $cfg := .Values.acl.users -}}
{{- if $cfg.existingPasswordSecret -}}true{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Returns "true" if standalone Deployment mode is active.
*/}}
{{- define "percona-valkey.useDeployment" -}}
{{- if and (eq .Values.mode "standalone") .Values.standalone.useDeployment -}}true{{- end -}}
{{- end }}

{{/*
Render ACL lines for users with inline password (skip users with existingPasswordSecret).
*/}}
{{- define "percona-valkey.aclInlineUsers" -}}
{{- range $user, $cfg := .Values.acl.users -}}
{{- if and (not $cfg.existingPasswordSecret) $cfg.password }}
user {{ $user }} on #{{ $cfg.password | sha256sum }} {{ $cfg.permissions | default "~* &* +@all" }}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Validate values and fail with collected errors.
*/}}
{{- define "percona-valkey.validateValues" -}}
{{- $errors := list -}}
{{- if and .Values.acl.enabled (not .Values.auth.enabled) -}}
  {{- $errors = append $errors "acl.enabled requires auth.enabled=true" -}}
{{- end -}}
{{- if and (eq .Values.mode "sentinel") (include "percona-valkey.externalAccessEnabled" .) -}}
  {{- $errors = append $errors "externalAccess is not supported in sentinel mode" -}}
{{- end -}}
{{- if and .Values.auth.passwordRotation.enabled (not .Values.auth.enabled) -}}
  {{- $errors = append $errors "auth.passwordRotation requires auth.enabled=true" -}}
{{- end -}}
{{- if and (ne .Values.mode "standalone") (not .Values.persistence.enabled) -}}
  {{- $errors = append $errors "persistence.enabled=false with mode=<cluster|sentinel> risks data loss" -}}
{{- end -}}
{{- if and (eq .Values.mode "cluster") (lt (int .Values.cluster.replicas) 6) -}}
  {{- $errors = append $errors "cluster.replicas must be >= 6 (3 primaries + 3 replicas minimum)" -}}
{{- end -}}
{{- if and .Values.tls.disablePlaintext (not .Values.tls.enabled) -}}
  {{- $errors = append $errors "tls.disablePlaintext requires tls.enabled=true" -}}
{{- end -}}
{{- if and .Values.standalone.useDeployment (ne .Values.mode "standalone") -}}
  {{- $errors = append $errors "standalone.useDeployment requires mode=standalone" -}}
{{- end -}}
{{- if and .Values.standalone.useDeployment .Values.persistence.enabled -}}
  {{- $errors = append $errors "standalone.useDeployment requires persistence.enabled=false" -}}
{{- end -}}
{{- /* ACL per-user validations */ -}}
{{- if .Values.acl.enabled -}}
{{- range $user, $cfg := .Values.acl.users -}}
{{- if and $cfg.existingPasswordSecret (not $cfg.passwordKey) -}}
  {{- $errors = append $errors (printf "acl.users.%s: existingPasswordSecret requires passwordKey" $user) -}}
{{- end -}}
{{- if and $cfg.password $cfg.existingPasswordSecret -}}
  {{- $errors = append $errors (printf "acl.users.%s: cannot set both password and existingPasswordSecret" $user) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $errors -}}
  {{- fail (printf "\n\npercona-valkey configuration errors:\n\n%s\n" (join "\n" $errors)) -}}
{{- end -}}
{{- end }}
