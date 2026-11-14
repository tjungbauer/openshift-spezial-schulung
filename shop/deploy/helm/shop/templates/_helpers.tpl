{{/*
Helpers of the shop chart. Files starting with "_" are never rendered as manifests.
*/}}

{{/* Labels on every object. app.kubernetes.io/name is added per component. */}}
{{- define "shop.labels" -}}
app.kubernetes.io/part-of: shop
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Image of a shop component:  include "shop.image" (list . "catalog") */}}
{{- define "shop.image" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- with $root.Values.image -}}
{{ .registry }}/shop-{{ $name }}{{ .suffix }}:{{ required "image.tag is required" .tag }}
{{- end -}}
{{- end }}

{{/* Pod settings shared by all shop Deployments */}}
{{- define "shop.podSecurity" -}}
terminationGracePeriodSeconds: 30
securityContext:            # no runAsUser: OpenShift picks one from the project range
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
{{- end }}

{{/* Container security context for restricted-v2 */}}
{{- define "shop.containerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
    - ALL
{{- end }}

{{/* The three probes of every shop component (same endpoints in all five) */}}
{{- define "shop.probes" -}}
startupProbe:             # up to 60 s to start
  httpGet:
    path: /health/started
    port: http
  periodSeconds: 2
  failureThreshold: 30
readinessProbe:           # out of the Service while not ready
  httpGet:
    path: /health/ready
    port: http
  periodSeconds: 5
  timeoutSeconds: 2
  failureThreshold: 2
livenessProbe:            # restart only if the process is stuck
  httpGet:
    path: /health/live
    port: http
  periodSeconds: 10
  timeoutSeconds: 2
  failureThreshold: 3
{{- end }}

{{/* DB_* and DATABASE_URL from the Secret "postgres" – for orders and the migration Job */}}
{{- define "shop.databaseEnv" -}}
- name: DB_USER
  valueFrom: { secretKeyRef: { name: postgres, key: POSTGRESQL_USER } }
- name: DB_PASSWORD
  valueFrom: { secretKeyRef: { name: postgres, key: POSTGRESQL_PASSWORD } }
- name: DB_NAME
  valueFrom: { secretKeyRef: { name: postgres, key: POSTGRESQL_DATABASE } }
- name: DATABASE_URL
  value: postgresql://$(DB_USER):$(DB_PASSWORD)@postgres:5432/$(DB_NAME)
{{- end }}

{{/* Combinations that do not work – stop early with a clear message */}}
{{- define "shop.validate" -}}
{{- if and .Values.orders.persistence.enabled .Values.postgresql.enabled -}}
{{- fail "orders.persistence.enabled and postgresql.enabled are alternatives – enable only one" -}}
{{- end -}}
{{- if and .Values.backup.enabled (not .Values.postgresql.enabled) -}}
{{- fail "backup.enabled needs postgresql.enabled" -}}
{{- end -}}
{{- end }}
