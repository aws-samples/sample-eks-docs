{{/*
The prompt guard block, shared by every model backend so a change lands on all of them at once.

bedrockGuardrails is a typed processor in the CRD rather than something to wire by hand, so the same
guardrail an agent's IAM policy requires can also be enforced here. Two independent layers on one
guardrail definition: the IAM condition stops an agent calling the model without the guardrail, and
this applies it to traffic the gateway sees whatever the agent asked for.

Reject rather than Audit, and FailClosed rather than FailOpen. An audit-only guard records the prompt
it was there to refuse, and a guard that fails open lets the request through ungoverned at exactly
the moment the guardrail service is unreachable.
*/}}
{{- define "agentgateway-config.promptGuard" -}}
{{- if not .Values.promptGuard.guardrailIdentifier }}
{{ fail "promptGuard.enabled is true but promptGuard.guardrailIdentifier is empty. An enabled guard with no guardrail named checks nothing; either name the guardrail or turn the guard off." }}
{{- end }}
request:
  - bedrockGuardrails:
      identifier: {{ .Values.promptGuard.guardrailIdentifier | quote }}
      version: {{ .Values.promptGuard.guardrailVersion | quote }}
      region: {{ .Values.region | quote }}
      action: Reject
      failureMode: FailClosed
response:
  - bedrockGuardrails:
      identifier: {{ .Values.promptGuard.guardrailIdentifier | quote }}
      version: {{ .Values.promptGuard.guardrailVersion | quote }}
      region: {{ .Values.region | quote }}
      action: Reject
      failureMode: FailClosed
{{- end -}}

{{/*
The MCP servers the gateway aggregates, shared by mcp-servers and mcp-servers-person so both reach
the same targets.
*/}}
{{- define "agentgateway-config.mcpTargets" }}
  mcp:
    targets:
      {{- range $name, $server := .Values.mcpServers }}
      - name: {{ $name }}
        {{- if $server.serviceSelector }}
        selector:
          {{/*
          THE NAMESPACE IS NOT OPTIONAL, and omitting it matches nothing. This backend lives in the
          gateway's namespace and the MCP servers live in another (mcp-servers for the reference
          server), so a label selector with no namespace resolves to zero Services. The gateway then answers every MCP request
          with 503 and `error="mcp: no backends configured"`, even with the Service present,
          correctly labelled and carrying healthy endpoints.
          */}}
          namespaces:
            matchLabels:
              kubernetes.io/metadata.name: {{ $server.namespace | default $.Values.namespaces.reasoning | quote }}
          services:
            matchLabels:
              {{- toYaml $server.serviceSelector | nindent 14 }}
        {{- else }}
        static:
          host: {{ $server.host | quote }}
          port: {{ $server.port | default 443 }}
          {{- if $server.path }}
          path: {{ $server.path | quote }}
          {{- end }}
        {{- end }}
      {{- end }}

{{- end }}
