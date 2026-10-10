{{/*
============================================================================
_helpers.tpl — named templates reutilizables del chart sa-platform.
Estos bloques se comparten con TODOS los subcharts (Helm los compila en un
namespace global de plantillas), así evitamos duplicar labels/selectors en
cada microservicio. En las plantillas de Deployment (Fase 3) se usarán junto
con range, if/else, required, default y quote.
============================================================================
*/}}

{{/* Nombre base del chart (recortado a 63 chars, límite de un label de K8s). */}}
{{- define "sa-platform.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Nombre completo: <release>-<chart>, salvo que se fuerce con fullnameOverride. */}}
{{- define "sa-platform.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "sa-platform.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Etiqueta helm.sh/chart: nombre-version (se sanea el '+' de metadatos SemVer). */}}
{{- define "sa-platform.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Labels comunes: los mete todo recurso para trazabilidad y para que
'app.kubernetes.io/part-of' agrupe la plataforma completa.
*/}}
{{- define "sa-platform.labels" -}}
helm.sh/chart: {{ include "sa-platform.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: sa-platform
{{ include "sa-platform.selectorLabels" . }}
{{- end -}}

{{/* Selector labels: el subconjunto estable que casa Deployment <-> Service. */}}
{{- define "sa-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sa-platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Host interno de PostgreSQL dentro del clúster. El nombre del Service lo define
el chart de la dependencia (groundhog2k/postgres) como <release>-postgres.
Se centraliza aquí para que todos los servicios lo referencien igual.
*/}}
{{- define "sa-platform.postgresHost" -}}
{{- printf "%s-postgres" .Release.Name -}}
{{- end -}}

{{/*
Host interno de RabbitMQ (<release>-rabbitmq). Mismo motivo que el de Postgres.
*/}}
{{- define "sa-platform.rabbitmqHost" -}}
{{- printf "%s-rabbitmq" .Release.Name -}}
{{- end -}}

{{/* Nombre del ConfigMap compartido (creado por el chart padre en la Fase 3b). */}}
{{- define "sa-platform.configMapName" -}}
{{- printf "%s-config" .Release.Name -}}
{{- end -}}

{{/* Nombre del Secret compartido (creado por el chart padre en la Fase 3b). */}}
{{- define "sa-platform.secretName" -}}
{{- printf "%s-secret" .Release.Name -}}
{{- end -}}
