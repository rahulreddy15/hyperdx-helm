{{- define "hyperdx.name" -}}{{ default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}{{- end }}
{{- define "hyperdx.fullname" -}}{{ default (printf "%s-%s" .Release.Name (include "hyperdx.name" .)) .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}{{- end }}
{{- define "hyperdx.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
app.kubernetes.io/name: {{ include "hyperdx.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{ with .Values.commonLabels }}{{ toYaml . }}{{ end }}
{{- end }}
{{- define "hyperdx.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hyperdx.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- define "hyperdx.selectorLabelsApp" -}}{{ include "hyperdx.selectorLabels" . }}
app.kubernetes.io/component: app
{{- end }}
{{- define "hyperdx.selectorLabelsCollector" -}}{{ include "hyperdx.selectorLabels" . }}
app.kubernetes.io/component: otel-collector
{{- end }}
{{- define "hyperdx.otelCollectorName" -}}{{ printf "%s-otel-collector" (include "hyperdx.fullname" .) | trunc 63 | trimSuffix "-" }}{{- end }}
{{- define "hyperdx.keeperName" -}}{{ printf "%s-keeper" (include "hyperdx.fullname" .) | trunc 63 | trimSuffix "-" }}{{- end }}
{{- define "hyperdx.mongodbName" -}}{{ printf "%s-mongodb" (include "hyperdx.fullname" .) | trunc 63 | trimSuffix "-" }}{{- end }}
{{- define "hyperdx.mongoConnectionName" -}}{{ printf "%s-mongo-connection" (include "hyperdx.fullname" .) | trunc 63 | trimSuffix "-" }}{{- end }}
{{- define "hyperdx.mongoScramName" -}}{{ printf "%s-mongo-scram" (include "hyperdx.fullname" .) | trunc 63 | trimSuffix "-" }}{{- end }}
{{- define "hyperdx.serviceAccountName" -}}{{ default (include "hyperdx.fullname" .) .Values.serviceAccount.name }}{{- end }}
{{- define "hyperdx.secretName" -}}{{ if .Values.auth.existingSecret }}{{ .Values.auth.existingSecret }}{{ else }}{{ include "hyperdx.fullname" . }}{{ end }}{{- end }}
{{- define "hyperdx.clickhouseSecretName" -}}{{ default (include "hyperdx.fullname" .) .Values.clickhouse.auth.existingSecret }}{{- end }}
{{- define "hyperdx.mongodbSecretName" -}}{{ default (include "hyperdx.fullname" .) .Values.mongodb.existingSecret }}{{- end }}
{{- define "hyperdx.clickhouse.host" -}}{{ if .Values.clickhouse.enabled }}{{ include "hyperdx.fullname" . }}-clickhouse-headless{{ else }}{{ required "clickhouse.external.host is required when clickhouse.enabled=false" .Values.clickhouse.external.host }}{{ end }}{{- end }}
{{/*
Ports for the ClickHouse endpoint. The in-cluster operator always exposes the standard
8123/9000; the external.* ports apply only when bringing your own ClickHouse.
*/}}
{{- define "hyperdx.clickhouse.httpPort" -}}{{ ternary 8123 .Values.clickhouse.external.httpPort .Values.clickhouse.enabled }}{{- end }}
{{- define "hyperdx.clickhouse.nativePort" -}}{{ ternary 9000 .Values.clickhouse.external.nativePort .Values.clickhouse.enabled }}{{- end }}
{{- define "hyperdx.mongo.host" -}}{{ printf "%s-svc" (include "hyperdx.mongodbName" .) | trunc 63 | trimSuffix "-" }}{{- end }}
{{- define "hyperdx.image" -}}{{ printf "%s%s" .repository (ternary (printf "@%s" .digest) (printf ":%s" .tag) (ne .digest "")) }}{{- end }}
{{- define "hyperdx.persisted" -}}
{{- $root := index . 0 -}}{{- $key := index . 1 -}}{{- $given := index . 2 -}}
{{- if $given }}{{ $given }}{{ else }}{{- $old := lookup "v1" "Secret" $root.Release.Namespace (include "hyperdx.fullname" $root) -}}{{- if and $old (hasKey $old.data $key) }}{{ index $old.data $key | b64dec }}{{ else }}{{ randAlphaNum 32 }}{{ end }}{{ end -}}
{{- end }}
{{- define "hyperdx.clickhousePassword" -}}
{{- $root := index . 0 -}}{{- $which := index . 1 -}}{{- $given := index . 2 -}}{{- $key := index . 3 -}}
{{- if $root.Values.clickhouse.auth.existingSecret -}}
  {{- $secret := lookup "v1" "Secret" $root.Release.Namespace $root.Values.clickhouse.auth.existingSecret -}}
  {{- if not $secret }}{{ fail (printf "clickhouse.auth.existingSecret %q was not found in namespace %q" $root.Values.clickhouse.auth.existingSecret $root.Release.Namespace) }}{{ end -}}
  {{- if not (hasKey $secret.data $key) }}{{ fail (printf "clickhouse.auth.existingSecret %q is missing required key %q" $root.Values.clickhouse.auth.existingSecret $key) }}{{ end -}}
  {{- index $secret.data $key | b64dec -}}
{{- else if $given -}}{{ $given }}
{{- else if not $root.Values.clickhouse.enabled -}}
  {{- fail "clickhouse.external.collectorPassword and clickhouse.external.appPassword must be set when clickhouse.enabled=false (or use clickhouse.auth.existingSecret); external credentials are never generated" -}}
{{- else -}}
  {{- $old := lookup "v1" "Secret" $root.Release.Namespace (include "hyperdx.fullname" $root) -}}
  {{- if and $old (hasKey $old.data $which) }}{{ index $old.data $which | b64dec }}{{ else -}}
    {{- if eq $root.Release.Name "release-name" -}}REQUIRED_FOR_FIRST_INSTALL
    {{- else }}{{ fail "clickhouse.auth.collectorPassword and clickhouse.auth.appPassword must be set on first install (or use clickhouse.auth.existingSecret). Helm cannot generate them consistently across templates. Generate with: --set clickhouse.auth.collectorPassword=$(openssl rand -base64 24) --set clickhouse.auth.appPassword=$(openssl rand -base64 24)" }}{{ end -}}
  {{- end -}}
{{- end -}}
{{- end }}
{{- define "hyperdx.clickhouseCollectorUser" -}}{{ if .Values.clickhouse.enabled }}{{ required "clickhouse.auth.collectorUser is required" .Values.clickhouse.auth.collectorUser }}{{ else }}{{ required "clickhouse.external.collectorUser is required when clickhouse.enabled=false" .Values.clickhouse.external.collectorUser }}{{ end }}{{- end }}
{{- define "hyperdx.clickhouseAppUser" -}}{{ if .Values.clickhouse.enabled }}{{ required "clickhouse.auth.appUser is required" .Values.clickhouse.auth.appUser }}{{ else }}{{ required "clickhouse.external.appUser is required when clickhouse.enabled=false" .Values.clickhouse.external.appUser }}{{ end }}{{- end }}
