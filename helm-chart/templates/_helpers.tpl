{{/*
The labels that every object of this chart gets.
They do not include "app": the Service selects pods by "app", so only the Deployment pods get it.
*/}}
{{- define "hello.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
The name of the Secret that holds the session cookie key. The cookie Job creates it.
*/}}
{{- define "hello.cookieSecretName" -}}
{{ .Values.serviceAccounts.oauthClient.name }}-cookie
{{- end }}

{{/*
The ServiceAccount that the pod runs as.
Option A: the OAuth client ServiceAccount. Option B: the workload ServiceAccount.
*/}}
{{- define "hello.podServiceAccount" -}}
{{- if .Values.serviceAccounts.workload.enabled -}}
{{ .Values.serviceAccounts.workload.name }}
{{- else -}}
{{ .Values.serviceAccounts.oauthClient.name }}
{{- end -}}
{{- end }}
