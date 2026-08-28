{{- define "togglemaster-base.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- if .Values.serviceAccount.name -}}
{{ .Values.serviceAccount.name }}
{{- else -}}
{{ .Release.Name }}
{{- end -}}
{{- else -}}
{{ .Values.serviceAccount.name | default "default" }}
{{- end -}}
{{- end -}}

{{- define "togglemaster-base.secretName" -}}
{{- if .Values.externalSecret.enabled -}}
{{- $externalSecretName := .Values.externalSecret.name | default .Release.Name -}}
{{ printf "%s-secret" $externalSecretName }}
{{- else -}}
{{- required "secret.name is required when secret is enabled" .Values.secret.name -}}
{{- end -}}
{{- end -}}
