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
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end }}

{{/*
RPM image (always used for Jobs that need shell tools).
*/}}
{{- define "percona-valkey.rpmImage" -}}
{{- printf "%s:%s" .Values.image.repository .Chart.AppVersion -}}
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
