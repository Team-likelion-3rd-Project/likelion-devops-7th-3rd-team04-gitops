{{/* root 가 렌더링하는 gitops 커밋. 비어 있으면(로컬 helm template) main */}}
{{- define "prod-apps.revision" -}}
{{- .Values.gitopsRevision | default "main" -}}
{{- end -}}

{{/*
배포 대상 앱 목록(JSON) — chart.yaml 이 있는 폴더 중 enabled: false 가 아닌 것, order(기본 50) · 폴더 이름 순.
{"apps": [{"name": 폴더, "order": 정수, "def": chart.yaml 내용}, ...]}
*/}}
{{- define "prod-apps.apps" -}}
{{- $keyed := dict -}}
{{- range $path, $_ := .Files.Glob "*/chart.yaml" -}}
{{- $def := $.Files.Get $path | fromYaml -}}
{{- if ne (toString $def.enabled) "false" -}}
{{- $order := int ($def.order | default 50) -}}
{{- $_ := set $keyed (printf "%05d %s" $order (dir $path)) (dict "name" (dir $path) "order" $order "def" $def) -}}
{{- end -}}
{{- end -}}
{{- $apps := list -}}
{{- range $key := keys $keyed | sortAlpha -}}
{{- $apps = append $apps (get $keyed $key) -}}
{{- end -}}
{{- dict "apps" $apps | toJson -}}
{{- end -}}

{{- define "prod-apps.notifyEnabled" -}}
{{- if dig "global" "awsAccountId" "" .Values.clusterValues -}}true{{- end -}}
{{- end -}}
