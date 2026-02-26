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
