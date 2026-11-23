{{/*
The half of an agent's ingress HTTPRoute that does not depend on whether OIDC is configured.

40-agent-rgd.yaml renders TWO HTTPRoute resources -- one carrying the ExtensionRef filter that
attaches the OIDC ListenerRuleConfiguration, one without -- selected by mutually exclusive
`includeWhen` conditions on the same field that decides whether the ListenerRuleConfiguration
exists. This is the part they share, so the two cannot drift.

It lives here rather than in 40-agent-rgd.yaml because that whole file is wrapped in
`{{ "{{- if .Values.agentResource.enabled }}" }}`, and Go templates do not allow a `define` inside
another action's body: "parse error: unexpected <define> in command".
*/}}
{{- define "agent.httpRouteSpec" }}
          # Attaches to the Gateway the platform team owns, in the namespace the base chart put it
          # in. An agent brings a route and a hostname; it does not bring a load balancer, a scheme
          # or a certificate -- those are on the Gateway and the GatewayClass, where an agent author
          # cannot reach them. That is the property the Ingress shape did not have, because there
          # every one of those was an annotation on the same object the agent owned.
          parentRefs:
            - group: gateway.networking.k8s.io
              kind: Gateway
              name: {{ .Values.ingress.gatewayName }}
              namespace: {{ .Values.ingress.namespace }}
              sectionName: https

          hostnames:
            # `<agent>.<ingress.domainName>` unless the agent names its own. Derived rather than
            # required, because the suffix is the platform's and the agent's own name is already in
            # the resource -- asking an author to retype both is how a hostname the certificate does
            # not cover gets in, which reports Accepted and then fails the TLS handshake.
            # QUOTED, and it has to be. A CEL ternary contains `: `, which YAML reads as a mapping
            # key -- unquoted, this line parses as an object and kro refuses the WHOLE graph with
            # "expected string type for path spec.hostnames[0], got object", which stops every agent
            # on the cluster reconciling rather than just this resource.
            - '${schema.spec.routeHostname != "" ? schema.spec.routeHostname : schema.metadata.name + ".{{ .Values.ingress.domainName }}"}'

{{- end }}
