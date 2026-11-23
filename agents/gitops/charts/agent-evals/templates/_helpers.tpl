{{/* The runner image. registry["agents/evals"] unless image.repository overrides it. */}}
{{- define "agent-evals.image" -}}
{{- $repo := .Values.image.repository | default (index (.Values.registry | default dict) "agents/evals") -}}
{{- if not $repo -}}
{{ fail "No image for the evaluation runner: registry[\"agents/evals\"] is empty and image.repository is unset. Build apps/evals/Dockerfile into the agents/evals ECR repository Terraform creates (see apps/README.md), or set image.repository." }}
{{- end -}}
{{ $repo }}:{{ .Values.image.tag }}
{{- end -}}

{{/* Fail early on a configuration that would render a runner that cannot grade anything. */}}
{{- define "agent-evals.guards" -}}
{{- if not (has .Values.evals.backend (list "langfuse" "agentcore")) -}}
{{ fail (printf "evals.backend must be langfuse or agentcore, got %q. Terraform renders it into terraform-values.yaml: langfuse on the open source path, agentcore on the AWS services path." .Values.evals.backend) }}
{{- end -}}
{{- if not .Values.evals.judge.baseUrl -}}
{{ fail "evals.judge.baseUrl is empty. It is the gateway endpoint the judge calls, rendered by Terraform; without it the runner has no model to grade with." }}
{{- end -}}
{{- if and (eq .Values.evals.backend "agentcore") (not .Values.evals.agentcore.logGroup) -}}
{{ fail "evals.agentcore.logGroup is empty. It is the log group the agents' OTLP logs land in, which the runner reads a session's trajectory from." }}
{{- end -}}
{{- end -}}

{{/*
The pod both CronJobs run. `mode` is online or experiment.

Two kinds of projected token, and neither is the default service account token, which is off:

  gateway   audience = the gateway's. What the judge presents on every model call.
  agents/X  audience = agent X's own name. What the experiment presents to agent X's /chat, which
            refuses a token naming any other relying party -- so the gateway's token cannot open an
            agent, and one agent's token cannot open another.
*/}}
{{- define "agent-evals.pod" -}}
{{- $root := .root -}}
{{- $v := $root.Values -}}
metadata:
  labels:
    app.kubernetes.io/part-of: eks-agents-paved-paths
    eks-agents-ai-docs: "true"
    app.kubernetes.io/name: agent-evals
    eks-agents/evals-mode: {{ .mode }}
spec:
  serviceAccountName: {{ $v.evals.serviceAccount }}
  automountServiceAccountToken: false
  restartPolicy: Never
  # No Service links: a Service in this namespace would otherwise inject *_PORT variables.
  enableServiceLinks: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    # The group a mounted Secret's files are given, so the non-root runner can read the Langfuse keys
    # at mode 0440; a Secret volume's files are owned by root, so 0400 would be unreadable to it.
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: runner
      image: {{ include "agent-evals.image" $root }}
      imagePullPolicy: {{ $v.image.pullPolicy }}
      args: [{{ .mode | quote }}]
      env:
        - name: EVALS_CONFIG
          value: /etc/agent-evals/config.yaml
        {{- if eq $v.evals.backend "langfuse" }}
        - name: LANGFUSE_HOST
          value: {{ $v.langfuse.host | quote }}
        # The keys as files, not environment variables: a variable is readable by every process in
        # the pod and travels with any crash dump or debug print. The runner reads them from here.
        - name: LANGFUSE_KEYS_DIR
          value: /var/run/secrets/langfuse
        {{- else }}
        # The AWS SDK's region, for the CloudWatch reads and the result writes. Credentials come
        # from EKS Pod Identity on this service account (terraform/modules/evaluations-aws).
        - name: AWS_REGION
          value: {{ $v.evals.agentcore.region | default $v.region | quote }}
        {{- end }}
      resources:
        {{- toYaml $v.resources | nindent 8 }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      volumeMounts:
        - name: config
          mountPath: /etc/agent-evals
          readOnly: true
        - name: tmp
          mountPath: /tmp
        - name: gateway-identity
          mountPath: /var/run/secrets/eks-agents/gateway
          readOnly: true
        {{- if eq $v.evals.backend "langfuse" }}
        - name: langfuse-keys
          mountPath: /var/run/secrets/langfuse
          readOnly: true
        {{- end }}
        {{- if eq .mode "experiment" }}
        {{- range $name, $_ := $v.experiment.agents }}
        - name: agent-{{ $name }}
          mountPath: /var/run/secrets/eks-agents/agents/{{ $name }}
          readOnly: true
        {{- end }}
        {{- end }}
  volumes:
    - name: config
      configMap:
        name: agent-evals
    - name: tmp
      emptyDir: {}
    {{- if eq $v.evals.backend "langfuse" }}
    - name: langfuse-keys
      secret:
        secretName: {{ $v.langfuse.existingSecret | quote }}
        defaultMode: 0440
        items:
          - { key: {{ $v.langfuse.publicKeyRef | quote }}, path: public-key }
          - { key: {{ $v.langfuse.secretKeyRef | quote }}, path: secret-key }
    {{- end }}
    - name: gateway-identity
      projected:
        defaultMode: 0400
        sources:
          - serviceAccountToken:
              path: token
              audience: {{ $v.evals.judge.audience | quote }}
              expirationSeconds: {{ $v.tokenExpirationSeconds }}
    {{- if eq .mode "experiment" }}
    {{- range $name, $_ := $v.experiment.agents }}
    - name: agent-{{ $name }}
      projected:
        defaultMode: 0400
        sources:
          - serviceAccountToken:
              path: token
              audience: {{ $name | quote }}
              expirationSeconds: {{ $v.tokenExpirationSeconds }}
    {{- end }}
    {{- end }}
{{- end -}}
