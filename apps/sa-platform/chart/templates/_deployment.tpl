{{/*
============================================================================
sa-platform.podTemplate - el "template:" (metadata + spec) del Pod, molde
compartido por TODOS los microservicios. Lo consumen tanto
"sa-platform.deployment" (Deployment normal) como el Rollout de api-gateway
(P8: entrega progresiva con Argo Rollouts) — ambos objetos usan exactamente
el mismo Pod, solo cambia el controlador que lo gestiona.

Cada subchart expresa sus diferencias mediante el bloque 'features' de su
values.yaml:

  features:
    database: catalogo_db     # "" (vacio) => el servicio NO tiene base de datos
    prismaMigrate: true       # true => agrega el initContainer de prisma db push
    healthCheck: http         # http => probes httpGet /health ; tcp => probes tcpSocket
    healthPath: /health       # ruta del health (solo si healthCheck: http)

Usa el motor de plantillas de verdad: if, if/else, range, required, default, quote.
============================================================================
*/}}
{{- define "sa-platform.podTemplate" -}}
metadata:
  annotations:
    # Cambio en la config compartida => cambia el hash => rollout (bloque B)
    checksum/config: {{ .Values.global.config | toYaml | sha256sum | quote }}
  labels:
    {{- include "sa-platform.selectorLabels" . | nindent 4 }}
spec:
  serviceAccountName: {{ include "sa-platform.fullname" . }}
  automountServiceAccountToken: false
  imagePullSecrets:
    - name: ghcr-pull-secret
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  {{- if and .Values.podAntiAffinity .Values.podAntiAffinity.enabled }}
  # P9 (continuidad operativa): repartir las réplicas entre nodos para que la
  # pérdida de UN nodo no se lleve todas. Es "preferred" y no "required" a
  # propósito: durante un canary de Argo Rollouts conviven pods estables y
  # canarios del mismo servicio (3 pods con 2 workers) y una regla dura dejaría
  # al canario en Pending; tampoco bloquea el reprogramado tras perder un nodo
  # (con "required" y 2 workers, la réplica desalojada no encontraría dónde caer).
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            topologyKey: kubernetes.io/hostname
            labelSelector:
              matchLabels:
                {{- include "sa-platform.selectorLabels" . | nindent 16 }}
  {{- end }}
  {{- if or .Values.features.prismaMigrate .Values.features.database }}
  initContainers:
    {{- if .Values.features.prismaMigrate }}
    # Solo servicios Node con Prisma: aplica el esquema antes de arrancar.
    - name: prisma-migrate
      image: "{{ required "Falta image.repository" .Values.image.repository }}:{{ .Values.image.tag | default "dev" }}"
      imagePullPolicy: {{ .Values.image.pullPolicy | default "IfNotPresent" }}
      command:
        - sh
        - -c
        - |
          until npx prisma db push --skip-generate; do
            echo "esperando que la base exista..."; sleep 3;
          done
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      env:
        - name: TMPDIR
          value: /tmp
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: {{ include "sa-platform.secretName" . }}
              key: POSTGRES_USER
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: {{ include "sa-platform.secretName" . }}
              key: POSTGRES_PASSWORD
        - name: DATABASE_URL
          value: "postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@{{ include "sa-platform.postgresHost" . }}:5432/{{ .Values.features.database }}"
      volumeMounts:
        - name: tmp
          mountPath: /tmp
    {{- else }}
    # Servicios sin Prisma (FastAPI) que SI tienen base de datos: el
    # contenedor principal crea sus tablas al arrancar (create_all) sin
    # reintentos propios. NO alcanza con "esperar" a que el Job db-init
    # (hook post-install) la haya creado: con --wait, Helm no dispara los
    # hooks post-install hasta que los recursos normales (Deployments)
    # ya esten Ready - y estos Deployments nunca quedarian Ready si
    # dependen de ese mismo hook (interbloqueo circular, confirmado
    # reproduciendo el despliegue en un kind local). Por eso este
    # initContainer CREA su propia base si no existe (igual que ya hace
    # Prisma automaticamente para los servicios Node), sin depender del
    # hook para nada.
    - name: wait-for-db
      image: postgres:16-alpine
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      env:
        - name: HOME
          value: /tmp
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: {{ include "sa-platform.secretName" . }}
              key: POSTGRES_USER
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: {{ include "sa-platform.secretName" . }}
              key: POSTGRES_PASSWORD
      command:
        - sh
        - -c
        - |
          set -e
          HOST={{ include "sa-platform.postgresHost" . }}
          DB={{ .Values.features.database }}
          until pg_isready -h "$HOST" -U "$POSTGRES_USER"; do
            echo "esperando a que postgres acepte conexiones..."; sleep 2;
          done
          if psql -h "$HOST" -U "$POSTGRES_USER" -d postgres -tAc \
               "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1; then
            echo "$DB ya existe"
          else
            echo "creando $DB"
            psql -h "$HOST" -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE \"$DB\""
          fi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
    {{- end }}
  {{- end }}
  containers:
    - name: {{ .Chart.Name }}
      image: "{{ required "Falta image.repository" .Values.image.repository }}:{{ .Values.image.tag | default "dev" }}"
      imagePullPolicy: {{ .Values.image.pullPolicy | default "IfNotPresent" }}
      ports:
        - name: http
          containerPort: {{ .Values.service.port }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      env:
        - name: PORT
          value: {{ .Values.service.port | quote }}
        - name: TMPDIR
          value: /tmp
        {{- if .Values.features.database }}
        # Solo servicios con base de datos: arma DATABASE_URL con las credenciales del Secret.
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: {{ include "sa-platform.secretName" . }}
              key: POSTGRES_USER
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: {{ include "sa-platform.secretName" . }}
              key: POSTGRES_PASSWORD
        - name: DATABASE_URL
          value: "postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@{{ include "sa-platform.postgresHost" . }}:5432/{{ .Values.features.database }}"
        {{- end }}
        {{- if .Values.faultMode }}
        # Solo api-gateway (P8): modo de fallo inducido para demostrar la
        # reversión automática del canary. Vacío/ausente en producción normal.
        - name: FAULT_MODE
          value: {{ .Values.faultMode | quote }}
        {{- end }}
        # Variables extra literales propias del servicio (si las hubiera)
        {{- range $key, $val := .Values.env }}
        - name: {{ $key }}
          value: {{ $val | quote }}
        {{- end }}
      # Config no sensible (ConfigMap) + credenciales (Secret), compartidas.
      envFrom:
        - configMapRef:
            name: {{ include "sa-platform.configMapName" . }}
        - secretRef:
            name: {{ include "sa-platform.secretName" . }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      {{- if .Values.preStopSleepSeconds }}
      # P9: al desalojar el pod (drenaje de nodo), el endpoint tarda unos
      # segundos en salir del balanceador; sin esta pausa ingress-nginx sigue
      # enviando peticiones a un contenedor que ya se cerró (connection refused,
      # medido en la prueba de la Fase 4). El sleep mantiene el pod sirviendo
      # mientras se propaga la baja del endpoint. Debe ser menor que
      # terminationGracePeriodSeconds (30 s por defecto).
      lifecycle:
        preStop:
          exec:
            command: ["sleep", {{ .Values.preStopSleepSeconds | quote }}]
      {{- end }}
      {{- if eq (.Values.features.healthCheck | default "http") "http" }}
      # Probes HTTP contra el endpoint de salud
      startupProbe:
        httpGet:
          path: {{ .Values.features.healthPath | default "/health" }}
          port: http
        failureThreshold: 30
        periodSeconds: 2
      readinessProbe:
        httpGet:
          path: {{ .Values.features.healthPath | default "/health" }}
          port: http
        periodSeconds: 5
        timeoutSeconds: 2
      livenessProbe:
        httpGet:
          path: {{ .Values.features.healthPath | default "/health" }}
          port: http
        periodSeconds: 10
        timeoutSeconds: 2
      {{- else }}
      # Probes TCP (para servicios sin endpoint de salud propio, ej. el gateway)
      startupProbe:
        tcpSocket:
          port: http
        failureThreshold: 30
        periodSeconds: 2
      readinessProbe:
        tcpSocket:
          port: http
        periodSeconds: 5
        timeoutSeconds: 2
      livenessProbe:
        tcpSocket:
          port: http
        periodSeconds: 10
        timeoutSeconds: 2
      {{- end }}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
{{- end -}}

{{/*
============================================================================
sa-platform.deployment - Deployment estándar, para todos los microservicios
salvo api-gateway (que usa Rollout, ver charts/api-gateway/templates/rollout.yaml).
============================================================================
*/}}
{{- define "sa-platform.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "sa-platform.fullname" . }}
  labels:
    {{- include "sa-platform.labels" . | nindent 4 }}
spec:
  # Si el servicio tiene HPA, no fijamos replicas (lo maneja el autoscaler).
  {{- if not (default dict .Values.autoscaling).enabled }}
  replicas: {{ .Values.replicas | default 1 }}
  {{- end }}
  # RollingUpdate sin caída de servicio (bloque F): crea el nuevo antes de
  # retirar el viejo (maxUnavailable: 0).
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      {{- include "sa-platform.selectorLabels" . | nindent 6 }}
  template:
    {{- include "sa-platform.podTemplate" . | nindent 4 }}
{{- end -}}
