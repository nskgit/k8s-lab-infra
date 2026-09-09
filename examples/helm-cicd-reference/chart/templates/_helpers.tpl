{{- define "helm-demo.labels" -}}
app.kubernetes.io/name: helm-demo
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
