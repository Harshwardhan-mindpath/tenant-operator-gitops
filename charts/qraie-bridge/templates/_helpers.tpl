{{/*
Expand the name of the chart.
*/}}
{{- define "qraie-bridge.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified release name.
*/}}
{{- define "qraie-bridge.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "qraie-bridge.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/part-of: {{ include "qraie-bridge.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels for one service entry -- $ is the root context, .svc is the
current service map from .Values.services.
*/}}
{{- define "qraie-bridge.serviceSelectorLabels" -}}
app.kubernetes.io/part-of: {{ include "qraie-bridge.name" .root }}
app.kubernetes.io/name: {{ .svc.name }}
{{- end }}

{{/*
Merged env for one service: TENANT_ID (from global.tenantId -- the one
real per-tenant override point, see templates/qraie_bridge_values.yaml.j2
in the parent repo), then global.commonEnv, then the service's own `env`
map -- same precedence as the compose file's `<<: *common-env-variables`
anchor merge, with TENANT_ID always coming from global.tenantId regardless
of what any of those layers also set (every service in values.yaml that
still hardcodes TENANT_ID literally does so only for parity with the
source compose file's own PROTOTYPE-only setup; this override keeps it
from winning over the real per-tenant value). Pass a dict {root: $, svc: <entry>}.
Services with `useCommonEnv: false` skip the common block entirely (they
didn't use the anchor in the source compose file).
*/}}
{{- define "qraie-bridge.env" -}}
{{- $global := .root.Values.global }}
{{- $svc := .svc }}
{{- $base := dict "TENANT_ID" $global.tenantId }}
{{- if not (eq $svc.useCommonEnv false) }}
{{- $base = mergeOverwrite $base (deepCopy $global.commonEnv) }}
{{- end }}
{{- $merged := mergeOverwrite $base (default (dict) $svc.env) }}
{{- range $key, $value := $merged }}
- name: {{ $key }}
  value: {{ $value | toString | quote }}
{{- end }}
{{- end }}
