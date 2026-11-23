{{/*
The agent's pod, shared by the two runtimes an Agent can take (40-agent-rgd.yaml): the Deployment's
spec.template and the Sandbox's spec.podTemplate. One definition, so the two cannot drift -- every
control below (the sandbox runtime class, the projected tokens, the egress-dependent environment)
holds whichever runtime the Agent asks for.

Indented for both callers: each puts this directly under a key at ten spaces, `template:` or
`podTemplate:`. Called with (dict "root" $ "probed" <bool> ["worker" <bool>]): `with .root` below
puts the chart root back, so .Values works as it does in the caller, `probed` picks whether the
container carries health probes (see HEALTH PROBES), and `worker` makes it a task pod for
`runtime: tasks` (a KEDA ScaledJob's job template: restartPolicy Never, the queue in its environment).
*/}}
{{/*
The platform's gateway endpoints, for an Agent that names none (gatewayBaseUrl and mcpUrl empty, the
schema default). Rendered from the chart's values, so they follow the platform when the gateway is
turned on or its address changes; see gatewayBaseUrl in 40-agent-rgd.yaml for why the schema
default cannot carry them. Empty with no gateway.
*/}}
{{- define "agentRgd.gatewayUrl" -}}
{{- if not .Values.gateway.enabled }}{{ else if eq .Values.path "open-source" }}http://{{ .Values.gateway.serviceName }}.{{ .Values.gateway.namespace }}.svc.cluster.local:{{ .Values.gateway.port }}{{ else }}{{ required "gateway.modelEndpoint is required on the aws-services path with the gateway on: it is the OpenAI-compatible endpoint an agent posts a model call to, and the gateway is the only model destination the egress policy permits. Take it from the model_endpoint Terraform output." .Values.gateway.modelEndpoint }}{{ end }}
{{- end -}}
{{- define "agentRgd.mcpUrl" -}}
{{- if not .Values.gateway.enabled }}{{ else if eq .Values.path "open-source" }}http://{{ .Values.gateway.serviceName }}.{{ .Values.gateway.namespace }}.svc.cluster.local:{{ .Values.gateway.port }}/mcp{{ else }}{{ .Values.gateway.mcpEndpoint }}{{ end }}
{{- end -}}
{{ define "agentRgd.podTemplate" }}
{{- $probed := .probed }}
{{- $worker := .worker | default false }}
{{- with .root }}
            metadata:
              labels:
                app.kubernetes.io/part-of: eks-agents-paved-paths
                eks-agents-ai-docs: "true"
                eks-agents/agent: ${schema.metadata.name}
                # Whether the shared ingress may reach this agent's port.
                #
                # The mesh rule that admits the load balancer has no principal to name -- an ALB is
                # not a mesh workload -- so it is scoped by destination port, and a rule scoped by
                # port and nothing else admits ANY source to that port on EVERY pod in the
                # namespace, including a caller with no identity at all. This label narrows it to
                # the agents that actually have a route, so an agent with expose: none or
                # expose: cluster is not reachable through a rule written for ingress.
                # See gitops/base/templates/50-mesh-authz.yaml.
                eks-agents/ingress: '${schema.spec.expose == "route" ? "true" : "false"}'
                # Whether the Admin tier's Kubernetes API rule applies to this pod
                # (30-cluster-egress-policy.yaml, eks-agents-cluster-api), only read when
                # networkPolicy.adminTierDefaultDeny is on.
                eks-agents/cluster-api: '${schema.spec.needsClusterApi ? "true" : "false"}'
                # Whether the Admin tier's MCP server rule applies (30-cluster-egress-policy.yaml,
                # eks-agents-mcp-servers): an Agent that sets mcpAudience calls the MCP server directly.
                eks-agents/mcp-client: '${schema.spec.mcpAudience != "" ? "true" : "false"}'

              # THE WORKLOAD HAS TO WAIT FOR THE POD IDENTITY ASSOCIATION, and this annotation is
              # how that is expressed. It is read by nothing; referencing the association's id is
              # what makes kro order this resource after it.
              #
              # Pod Identity injects AWS_CONTAINER_CREDENTIALS_FULL_URI at pod ADMISSION, from the
              # association that exists at that moment. Without this reference kro creates the
              # workload and the association concurrently, and a pod admitted first runs with NO AWS
              # identity for its whole life -- while the Agent reports AllResourcesReady, the
              # association reports SYNCED and the pod is Running. Ordering narrows that window
              # without closing it, which is why the pod also sets the two variables itself (POD
              # IDENTITY, below).
              #
              # It also means a change of association rolls the pods, which is correct: the
              # credentials endpoint they were admitted with is not the current one.
              annotations:
                eks-agents/pod-identity-association: ${podIdentity.status.associationID}
                # The Nitro sandbox's network meters, from the Agent's sandbox limit fields
                # (templates/40-agent-rgd.yaml). Read once at pod creation; strings, as the
                # service reads them.
                sandbox.amazonaws.com/ingress-bandwidth: ${schema.spec.networkBandwidth}
                sandbox.amazonaws.com/egress-bandwidth: ${schema.spec.networkBandwidth}
                sandbox.amazonaws.com/ingress-packets-per-second: ${schema.spec.networkPacketsPerSecond}
                sandbox.amazonaws.com/egress-packets-per-second: ${schema.spec.networkPacketsPerSecond}
                sandbox.amazonaws.com/dns-packets-per-second: ${schema.spec.dnsQueriesPerSecond}
                sandbox.amazonaws.com/conntrack-limit: ${string(schema.spec.connectionLimit)}
                # A Sandbox's pod is the agent's one instance, so Karpenter -- and EKS Auto Mode, which runs
                # it -- must not consolidate its node out from under it: the pod would be evicted and
                # recreated, losing what it held in memory and in /workspace. Set only on the Sandbox
                # runtime; Karpenter acts on "true" alone. A Deployment's replicas are interchangeable
                # and stay disruptable, so node consolidation and upgrades proceed normally there.
                # THE COST: it also holds back voluntary node replacement for that node -- an AMI
                # update waits until the node reaches its maximum lifetime, when Karpenter evicts it
                # anyway. Delayed patching, not skipped. Suspend the Sandbox to move it sooner. The
                # same annotation the upstream sample's sandboxes carry
                # (aws-samples/sample-eks-nitro-sandbox, examples/agent-sandbox).
                karpenter.sh/do-not-disrupt: '${schema.spec.runtime != "deployment" ? "true" : "false"}'
            spec:
              serviceAccountName: ${serviceAccount.metadata.name}
{{- if $worker }}

              # A task pod runs one task and exits. KEDA's ScaledJob starts the next one; a failed
              # task is not retried in place, so its message returns to the queue and, after the
              # queue's maxReceiveCount, goes to the dead-letter queue.
              restartPolicy: Never
{{- end }}

              # The one line that puts the pod in a Nitro sandbox, and not a field on the Agent
              # resource. The RuntimeClass carries its own scheduling constraints and EKS Auto Mode
              # brings up a sandbox-capable node.
              runtimeClassName: isolated-sandbox
{{- if and (.Values.nodeClass | default dict).enabled (.Values.nodeClass | default dict).roleName }}

              # ONTO THE AGENTS' OWN POOL, which is what makes the strict network policy enforcement
              # mode in templates/11-agents-nodeclass.yaml apply to this pod. Without these two the
              # NodeClass exists, the cluster reads as hardened, and every agent still lands on the
              # cluster's default pool in standard mode -- a control that is present and inert,
              # which is the failure this repository is most exposed to.
              #
              # An `Agent` sets neither: the pool and its taint are platform concerns.
              nodeSelector:
                karpenter.sh/nodepool: {{ (.Values.nodeClass | default dict).name }}

              tolerations:
                - key: {{ (.Values.nodeClass | default dict).taintKey }}
                  operator: Equal
                  value: "true"
                  effect: NoSchedule
{{- end }}

              # No <SERVICE>_HOST or <SERVICE>_PORT variables for the other Services in this
              # namespace, so generated code the agent runs finds nothing in its environment that
              # names one. The KUBERNETES_* variables are injected whatever this says; they name an
              # address the service account has no token for.
              enableServiceLinks: false

              securityContext:
                runAsNonRoot: true
                runAsUser: 10001
                runAsGroup: 10001
                fsGroup: 10001
                seccompProfile:
                  type: RuntimeDefault

              containers:
                - name: agent
                  image: ${schema.spec.image}
                  imagePullPolicy: IfNotPresent

                  # THE PLATFORM TEAM'S CONFIGURATION FOR THIS AGENT, by convention rather than by a
                  # field: a ConfigMap named <agent>-config in the agent's namespace, loaded as
                  # environment variables. Optional, so an agent without one starts unchanged.
                  #
                  # It cannot override anything below. Kubernetes gives `env` precedence over
                  # `envFrom`, so a key in the ConfigMap that names a variable the platform sets
                  # here -- the gateway URL, the model, the token files, the AWS credential
                  # endpoint -- is ignored for that variable. What reaches the agent from it is
                  # only what this template does not already decide.
                  envFrom:
                    - configMapRef:
                        name: ${schema.metadata.name}-config
                        optional: true

                  env:
                    # The model endpoint, under this stack's name and the OpenAI SDK's.
                    #
                    # AGENT_GATEWAY_URL is this stack's name. OPENAI_BASE_URL is what an agent
                    # written against the OpenAI SDK reads, so such an agent finds the endpoint
                    # without a rebuild. Both name an OpenAI-compatible endpoint that holds the model
                    # credential so the agent does not.
                    #
                    # An agent that ignores both still reaches nothing else: the network policy is
                    # what makes the gateway unavoidable, not the variable.
{{- if not .Values.gateway.enabled }}
                    # NO GATEWAY, so no endpoint is injected under either name.
                    #
                    # This is deliberate and it is the whole of what the templates can do here. An
                    # agent that reads OPENAI_BASE_URL and finds it unset either falls back to the
                    # provider's own SDK -- which is what you want, Bedrock reached directly with
                    # this agent's Pod Identity credential -- or it fails at its first model call.
                    # Which of the two happens is a property of the image, not of this chart.
                    #
                    # The default reference image (agents/reasoning) does NOT fall back: it has no
                    # code path to Bedrock and refuses to start. agents/reasoning-direct does, using
                    # AWS_BEDROCK_REGION and AGENT_MODEL below on this agent's own role. The cluster policy
                    # permits exactly that host and nothing else, so the boundary still holds; what
                    # changes is that the agent holds the credential it spends.
                    - name: AWS_BEDROCK_REGION
                      value: {{ .Values.region | quote }}
{{- else if eq .Values.path "open-source" }}
                    # The per-agent model route. One model backend per agent, selected by this
                    # path, because the gateway's assumeRole.roleArn cannot be derived per request.
                    - name: AGENT_GATEWAY_URL
                      value: '${schema.spec.gatewayBaseUrl != "" ? schema.spec.gatewayBaseUrl : "{{ include "agentRgd.gatewayUrl" . }}"}/llm/${schema.metadata.name}'
                    - name: OPENAI_BASE_URL
                      value: '${schema.spec.gatewayBaseUrl != "" ? schema.spec.gatewayBaseUrl : "{{ include "agentRgd.gatewayUrl" . }}"}/llm/${schema.metadata.name}'
{{- else }}
                    # One OpenAI-compatible endpoint for every model. The gateway routes on the
                    # `model` field in the request body, so an agent selects a model by name and
                    # the base URL never changes. Prefix with a target name (bedrock/<model>) to
                    # pin a provider.
                    - name: AGENT_GATEWAY_URL
                      value: '${schema.spec.gatewayBaseUrl != "" ? schema.spec.gatewayBaseUrl : "{{ include "agentRgd.gatewayUrl" . }}"}'
                    - name: OPENAI_BASE_URL
                      value: '${schema.spec.gatewayBaseUrl != "" ? schema.spec.gatewayBaseUrl : "{{ include "agentRgd.gatewayUrl" . }}"}'
{{- end }}

                    # WHICH MODEL TO ASK FOR, and the two paths name models differently.
                    #
                    # The gateway routes on the `model` field in the request body, so an agent that
                    # does not set this falls back to whatever its image defaults to. The reference
                    # agent defaults to "bedrock-claude-sonnet", which is the BACKEND NAME
                    # agentgateway-config renders on the open source path -- so the default is
                    # correct there and wrong everywhere else.
                    #
                    # On the aws-services path the AgentCore connector advertises its own catalogue
                    # with its own ids, of the form bedrock/<provider>.<model>. A Bedrock model id
                    # or inference profile id is not one of them. The default produces a clean
                    # 404 from a correctly authenticated call:
                    #
                    #   {"error":{"message":"Model 'bedrock-claude-sonnet' not found on any
                    #   target.","type":"not_found_error","code":"404"}}
                    #
                    # which reads as a routing or target problem rather than the agent asking for a
                    # model that does not exist. List what a gateway serves with
                    # GET {{ "{{" }} gateway {{ "}}" }}/inference/v1/models.
                    #
                    # NOT EVERY MODEL SERVES THE OPENAI DIALECT either: some Bedrock models refuse
                    # /v1/chat/completions and require /v1/messages with an anthropic_version field,
                    # which an OpenAI-SDK agent does not send. Pick one that does.
                    #
                    # WITH NO GATEWAY there is no gateway model id to require: the agent calls
                    # Bedrock itself, so the value is a BEDROCK model id rather than a gateway route
                    # name, and the default is a real one. Requiring the gateway's id here would
                    # fail the render for a configuration that has no gateway to name.
                    - name: AGENT_MODEL
                      value: {{ if not .Values.gateway.enabled }}{{ .Values.model.directModelId | default "us.anthropic.claude-sonnet-5-5" | quote }}{{ else if eq .Values.path "open-source" }}{{ .Values.model.gatewayModelId | default "bedrock-claude-sonnet" | quote }}{{ else }}{{ required "model.gatewayModelId is required on the aws-services path: the gateway routes on the model name in the request body and the AgentCore connector advertises its own ids (bedrock/<provider>.<model>), so there is no default that resolves. List what your gateway serves with GET <gateway>/inference/v1/models and set one that speaks the OpenAI dialect." .Values.model.gatewayModelId | quote }}{{ end }}

                    # The tool endpoint. An agent's tools come from the gateway's aggregated MCP
                    # surface rather than a list in application code, so the catalogue is a
                    # reviewable object rather than a deployment artifact.
                    - name: AGENT_MCP_URL
                      value: '${schema.spec.mcpUrl != "" ? schema.spec.mcpUrl : "{{ include "agentRgd.mcpUrl" . }}"}'

                    # Only set when mcpAudience is, so the default path is unchanged. kro renders
                    # the empty string when it is unset, and the serving code treats that as absent.
                    - name: AGENT_MCP_TOKEN_FILE
                      value: '${schema.spec.mcpAudience != "" ? "/var/run/secrets/eks-agents/mcp/token" : ""}'

                    # --- serving, and who may call this agent -------------------
                    # Whether this agent listens at all. The CLI is the default, so an agent serves
                    # traffic only where expose asked for a Service or a route in front of it.
                    - name: AGENT_SERVE
                      # Quoted: the CEL ternary contains ": ", which an unquoted YAML scalar reads
                      # as a mapping and rejects.
                      value: '${schema.spec.expose != "none" ? "1" : "0"}'
{{- if $worker }}
                    # --- a task pod (runtime: tasks) -------------------------------
                    # Takes one message from this agent's task queue, runs the turn, sends the
                    # answer to its result queue, and deletes the message. Both queues are the
                    # platform's (terraform/modules/agent-tasks), named for the cluster and agent;
                    # the permission set tasks-<agent> is what lets this agent's role use them.
                    - name: AGENT_WORKER
                      value: "1"
                    - name: AGENT_TASK_QUEUE_URL
                      value: "https://sqs.{{ .Values.region }}.amazonaws.com/{{ .Values.accountId }}/{{ .Values.cluster }}-${schema.metadata.name}-tasks"
                    - name: AGENT_RESULT_QUEUE_URL
                      value: "https://sqs.{{ .Values.region }}.amazonaws.com/{{ .Values.accountId }}/{{ .Values.cluster }}-${schema.metadata.name}-results"
                    # The queue's visibility timeout. The worker extends it while a task runs, so a
                    # task longer than this is not handed to a second pod.
                    - name: AGENT_TASK_VISIBILITY_SECONDS
                      value: {{ (.Values.tasks | default dict).visibilityTimeoutSeconds | default 300 | toString | quote }}
{{- end }}
                    # The port it listens on: the one the Service targets and the probe checks.
                    # Without it an Agent with any port but 8080 serves where nothing points.
                    - name: AGENT_PORT
                      value: ${string(schema.spec.port)}

                    # What a caller's token must name to reach this agent, and the issuer that
                    # signs it. The agent verifies both before answering, which is the gate that
                    # holds when mesh_mode is none -- the mesh is the stronger control where it is
                    # on, and it is off by default on the AWS services path, so an agent whose only
                    # gate was the mesh would be ungated on the default configuration.
                    - name: AGENT_INBOUND_AUDIENCE
                      value: ${schema.metadata.name}
                    - name: CLUSTER_OIDC_ISSUER
                      value: {{ .Values.oidcIssuerUrl | quote }}
                    # Turns a minute for each person a turn is for (agent_turns_per_person_per_minute),
                    # so one person cannot exhaust an agent many people share. 0 is off.
                    - name: AGENT_TURNS_PER_PERSON_PER_MINUTE
                      value: {{ (.Values.agentResource.turnsPerPersonPerMinute | default 0) | toString | quote }}
                    # And who may call it. Any service account can mint a token for any audience, so
                    # the audience above names this agent and not its caller. The chat UI
                    # and the route's workload gate (which pins sub to this namespace) run in the
                    # agent's own namespace; the evaluation runner is the one composed caller that
                    # does not.
                    - name: AGENT_ALLOWED_CALLER_NAMESPACES
                      # Plus the evaluation runner's namespace when evaluations are on: the release gate
                      # calls each agent directly with a token for that agent's audience, and is
                      # refused 401 without it.
                      value: '${schema.spec.callerNamespaces != "" ? schema.metadata.namespace + "," + schema.spec.callerNamespaces : schema.metadata.namespace}{{ if (.Values.evals | default dict).enabled }},{{ .Values.namespaces.evals }}{{ end }}'

                    # Where the gateway credential is, so an agent reads the file rather than
                    # carrying a token of its own. Re-read it per request: the kubelet rewrites
                    # this file in place when it refreshes the token.
                    - name: AGENT_IDENTITY_TOKEN_FILE
                      value: /var/run/secrets/eks-agents/gateway/token
                    # AgentCore Gateway temporal policies (written in the Dogwood policy language)
                    # need a policy session on every gateway request; the agent sends its
                    # conversation session as one when this is on.
                    - name: AGENT_POLICY_SESSIONS
                      value: {{ (.Values.gateway.policySessions | default false) | toString | quote }}

                    - name: AGENT_NAME
                      value: ${schema.metadata.name}
                    - name: AGENT_SYSTEM_PROMPT
                      value: ${schema.spec.systemPrompt}
                    - name: AWS_REGION
                      value: {{ .Values.region }}
                    # S3'S REGIONAL NAME, IN EVERY REGION. In us-east-1 the SDKs default to the legacy
                    # global endpoint (<bucket>.s3.amazonaws.com), which no egress rule names, so a
                    # call to the agent's own checkpoint bucket hangs on a dropped connection. The
                    # network policy names <bucket>.s3.<region>.amazonaws.com.
                    - name: AWS_S3_US_EAST_1_REGIONAL_ENDPOINT
                      value: regional

                    # POD IDENTITY, SET HERE RATHER THAN WAITING TO BE INJECTED.
                    #
                    # EKS injects these two variables and the token volume below at pod ADMISSION,
                    # from the Pod Identity association that the control plane can see at that
                    # moment -- and the association this graph creates is not visible to it
                    # immediately. The association reports SYNCED with an associationID, kro orders
                    # the Deployment after it, and the first pod is STILL admitted before the
                    # webhook will act on it. That pod then runs for its whole life with no AWS
                    # identity, while the Agent reports AllResourcesReady, the pod is 1/1 Running
                    # and nothing anywhere reports a problem.
                    #
                    # A container restart does not fix it, because env is fixed at admission rather
                    # than at container start -- only a NEW pod gets another chance, which is why
                    # `kubectl rollout restart` appears to fix it and a CrashLoop would not.
                    #
                    # Ordering alone is not enough: the annotation above makes the association exist
                    # first, and the first pod of a freshly applied Agent can still miss it.
                    #
                    # So this stack sets them itself. The endpoint is the fixed Pod Identity
                    # link-local address, which the egress policy already permits, and the token is
                    # projected below for the `pods.eks.amazonaws.com` audience the credential
                    # endpoint requires. Credentials then start working as soon as the association
                    # propagates, which the AWS SDKs retry into naturally, rather than never.
                    - name: AWS_CONTAINER_CREDENTIALS_FULL_URI
                      value: http://169.254.170.23/v1/credentials
                    - name: AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
                      value: /var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token
{{- if .Values.storage.checkpointBucket }}
                    # Durable state (enable_checkpoints): the reference agent saves each session's
                    # conversation here with Strands' S3SessionManager, under its own prefix.
                    - name: CHECKPOINT_BUCKET
                      value: {{ .Values.storage.checkpointBucket | quote }}

                    # Configuration, never a tool argument. An agent that chose its own prefix would
                    # get AccessDenied from its role, but passing it as configuration means the
                    # model never sees it as something it can set.
                    - name: CHECKPOINT_PREFIX
                      value: agents/${schema.metadata.name}/
{{- end }}
{{- if (.Values.personAccess | default dict).enabled }}
                    # Acting with a person's own authority. The agent exchanges a person's ID token
                    # for ITS OWN person role, whose permissions IAM scopes to that person's prefix
                    # and this agent's part of it; the agent's own role is not involved. Empty for
                    # an agent not in person_access_agents, which then has no person role.
                    # Configuration, never a tool argument, so the model cannot point it elsewhere.
                    - name: AGENT_PERSON_ROLE_ARN
                      value: '${schema.metadata.name in {{ toJson .Values.personAccess.agents }} ? "{{ .Values.personAccess.roleArnPrefix }}" + schema.metadata.name + "-person-data" : ""}'
                    - name: AGENT_PERSON_BUCKET
                      value: {{ .Values.personAccess.bucket | quote }}
                    - name: PERSON_TOKEN_ISSUER
                      value: {{ .Values.personAccess.issuer | quote }}
{{- if (.Values.personAccess.viaGateway | default dict).enabled }}
                    # S3 with the person's authority THROUGH THE GATEWAY (person_access_via_gateway):
                    # the agent sends its own token and the person's, unsigned, and the gateway
                    # signs as this agent's person role tagged with the verified person. Empty for an
                    # agent not in person_access_agents, which has no such route.
                    - name: AGENT_PERSON_S3_URL
                      value: '${schema.metadata.name in {{ toJson .Values.personAccess.agents }} ? (schema.spec.gatewayBaseUrl != "" ? schema.spec.gatewayBaseUrl : "{{ include "agentRgd.gatewayUrl" . }}") + "/aws/" + schema.metadata.name + "/s3" : ""}'
                    # Every person_access_gateway_services service is under the same base:
                    # <AGENT_PERSON_AWS_URL>/<signing name>, for example .../aws/research/dynamodb.
                    - name: AGENT_PERSON_AWS_URL
                      value: '${schema.metadata.name in {{ toJson .Values.personAccess.agents }} ? (schema.spec.gatewayBaseUrl != "" ? schema.spec.gatewayBaseUrl : "{{ include "agentRgd.gatewayUrl" . }}") + "/aws/" + schema.metadata.name : ""}'
{{- end }}
{{- if (.Values.personAccess.tokenExchange | default dict).enabled }}
                    # The gateway exchanges a person's ACCESS token with this agent's own for one
                    # delegated token (person_access_delegated_token), so only an access token goes
                    # to the MCP endpoint. An ID token, which the agent still exchanges with STS for
                    # its person role, is not sent there: the exchange would refuse it.
                    - name: AGENT_MCP_PERSON_TOKEN
                      value: access
{{- if eq (.Values.personAccess.tokenExchange.mode | default "") "agentcore" }}
                    # The AWS services path makes the exchange in the agent, with AgentCore Identity:
                    # its own workload identity and credential provider, for the tools' audience.
                    # The tool gets the delegated token in x-delegated-token and never the person's
                    # own. Empty for an agent not in person_access_agents, which has neither.
                    - name: AGENT_PERSON_WORKLOAD
                      value: '${schema.metadata.name in {{ toJson .Values.personAccess.agents }} ? "{{ .Values.personAccess.tokenExchange.resourcePrefix }}" + schema.metadata.name : ""}'
                    - name: AGENT_PERSON_DELEGATION_PROVIDER
                      value: '${schema.metadata.name in {{ toJson .Values.personAccess.agents }} ? "{{ .Values.personAccess.tokenExchange.resourcePrefix }}" + schema.metadata.name + "-on-behalf-of" : ""}'
                    - name: AGENT_PERSON_DELEGATED_AUDIENCE
                      value: {{ .Values.personAccess.tokenExchange.audience | quote }}
{{- end }}
{{- end }}
{{- end }}
                    # Whether /workspace outlives the pod (a Sandbox with workspaceSize). With no
                    # bucket, the reference agent keeps its sessions there, so they survive suspend.
                    - name: AGENT_WORKSPACE_PERSISTENT
                      value: '${schema.spec.workspaceSize != "" ? "true" : "false"}'

                    - name: GUARDRAIL_ARN
                      value: ${schema.spec.guardrailArn}
                    - name: GUARDRAIL_VERSION
                      value: ${schema.spec.guardrailVersion}

                    # OpenTelemetry with the GenAI semantic conventions, which is the
                    # instrumentation both paths share. What differs is the backend it lands in, so
                    # this is identical on either path and the choice stays reversible.
                    - name: OTEL_SERVICE_NAME
                      value: ${schema.metadata.name}
                    # aws.service.type=gen_ai_agent IS WHAT AGENTCORE ONLINE EVALUATION SELECTS
                    # SESSIONS BY. The AWS OpenTelemetry distro sets it and the plain SDK this image
                    # uses does not, so without it every session is skipped while the configuration
                    # reads ACTIVE.
                    - name: OTEL_RESOURCE_ATTRIBUTES
                      value: k8s.namespace.name=${schema.metadata.namespace},k8s.deployment.name=${schema.metadata.name},eks.agent=${schema.metadata.name},aws.service.type=gen_ai_agent
                    - name: OTEL_EXPORTER_OTLP_PROTOCOL
                      value: http/protobuf

                    {{- if .Values.memory.sessionStateEndpoint }}
                    # Session state, so the agent holds nothing between turns in its own memory --
                    # which is what lets it be load balanced, and what makes MCP session affinity a
                    # non-problem. The cluster-scoped egress policy has to permit this destination
                    # too; see networkPolicy.inClusterDestinations.
                    - name: SESSION_STATE_ENDPOINT
                      {{- /*
                        Tolerates both shapes. Terraform writes "address:port", but the
                        ElastiCache attribute this comes from is a SET OF OBJECTS, and a plain
                        `| quote` of that renders a Go structure the agent cannot parse:

                          SESSION_STATE_ENDPOINT=[map[address:...amazonaws.com port:6379]]

                        A values file written against the older output still has the list, so
                        handle it here rather than producing that silently again.
                      */}}
                      {{- $ep := .Values.memory.sessionStateEndpoint }}
                      {{- if kindIs "slice" $ep }}
                      {{- $first := index $ep 0 }}
                      value: {{ printf "%s:%v" $first.address $first.port | quote }}
                      {{- else }}
                      value: {{ $ep | quote }}
                      {{- end }}
                    {{- end }}
                    {{- if .Values.memory.vectorBucketArn }}
                    # Semantic recall (rung 2). The index names are the platform's semantic_recall_indexes keys.
                    - name: AGENT_VECTOR_BUCKET_ARN
                      value: {{ .Values.memory.vectorBucketArn | quote }}
                    # The agent's role cannot ListIndexes, so the names come from the platform.
                    - name: AGENT_VECTOR_INDEXES
                      value: {{ .Values.memory.vectorIndexes | default "" | quote }}
                    {{- end }}
                    {{- if .Values.memory.memoryId }}
                    # Consolidation (rung 3): the AgentCore Memory id for CreateEvent and RetrieveMemoryRecords.
                    - name: AGENT_MEMORY_ID
                      value: {{ .Values.memory.memoryId | quote }}
                    # Where the strategies write records. ListMemoryRecords matches a namespace exactly.
                    - name: AGENT_MEMORY_NAMESPACES
                      value: {{ .Values.memory.memoryNamespaces | default "" | quote }}
                    {{- end }}
                    {{- if .Values.memory.consolidation.dbSecretArn }}
                    # Consolidation (rung 3) on the open source path: Mem0 as a library, on pgvector.
                    # The login is read from Secrets Manager with the agent's own role; extraction and
                    # embedding calls go to the gateway on the agent's own token, embeddings on
                    # <gateway>/llm/<agent>/embeddings.
                    - name: AGENT_CONSOLIDATION_DB_SECRET_ARN
                      value: {{ .Values.memory.consolidation.dbSecretArn | quote }}
                    - name: AGENT_CONSOLIDATION_DB_HOST
                      value: {{ .Values.memory.consolidation.dbHost | quote }}
                    - name: AGENT_CONSOLIDATION_DB_NAME
                      value: {{ .Values.memory.consolidation.dbName | quote }}
                    - name: AGENT_CONSOLIDATION_EMBEDDING_MODEL
                      value: {{ .Values.memory.consolidation.embeddingModelId | quote }}
                    - name: AGENT_CONSOLIDATION_EMBEDDING_DIMS
                      value: {{ .Values.memory.consolidation.embeddingDims | quote }}
                    # Mem0's anonymous usage telemetry posts to PostHog, which the egress policy
                    # refuses anyway; off, so the attempt is not made. MEM0_DIR moves its local state
                    # (a history database and an id file) off the read-only root filesystem.
                    - name: MEM0_TELEMETRY
                      value: "false"
                    - name: MEM0_DIR
                      value: /tmp/mem0
                    {{- end }}

{{- if .Values.observability.enabled }}
                    # The endpoint, which is the one piece of this that is not optional. Without it
                    # the SDK defaults to localhost:4318 and silently drops everything -- a model
                    # call succeeds, the dashboard stays empty, and nothing reports a fault.
                    - name: OTEL_EXPORTER_OTLP_ENDPOINT
                      value: {{ .Values.observability.otlpEndpoint | default (ternary "http://opentelemetry-collector.monitoring.svc.cluster.local:4318" (printf "http://adot-collector.%s.svc.cluster.local:4318" (.Values.observability.collectorNamespace | default "opentelemetry-operator-system")) (eq .Values.path "open-source")) | quote }}
{{- else }}
                    # NO COLLECTOR (observability.enabled false). No endpoint, so the reference agent
                    # logs that it exports nothing and starts no exporter; and the standard switch
                    # that turns an OpenTelemetry SDK off, so an agent built on another SDK does not
                    # fall back to localhost:4318 and retry against nothing.
                    - name: OTEL_SDK_DISABLED
                      value: "true"
{{- end }}

                  # HEALTH PROBES, only on an agent that serves (expose is not "none"). An agent driven
                  # by a schedule or a queue serves no HTTP, and a probe on it would hold it unready
                  # forever and, as liveness, restart it in a loop. The workload is therefore composed
                  # twice in 40-agent-rgd.yaml, probed and unprobed, selected by includeWhen on expose:
                  # kro cannot leave a field out per instance. omit() is behind a feature gate the EKS
                  # capability does not enable, and optional.none() is accepted when the graph is
                  # built but renders as the literal "null", which the Sandbox CRD rejects (kro
                  # 0.9.4-eks-2).
                  #
                  # THE HANDLER, from agentResource.healthProbe (values.yaml): exec by default, httpGet
                  # on request. httpGet needs nothing in the image, but on a sandboxed pod in an
                  # ambient namespace it never succeeds: the kubelet's connection is captured and the
                  # reply from the Nitro guest never comes back through the pod's network namespace,
                  # so liveness restarts a healthy agent in a loop. An exec probe runs inside the
                  # container and makes no connection to capture. The httpGet failure reads as
                  # "context deadline exceeded" while /healthz answers 200 inside the pod.
                  {{- $hp := .Values.agentResource.healthProbe | default dict }}
                  {{- $handler := $hp.handler | default "exec" }}
                  {{- if not (has $handler (list "httpGet" "exec" "none")) }}
                  {{- fail (printf "agentResource.healthProbe.handler is %q: want exec, httpGet or none" $handler) }}
                  {{- end }}
                  {{- $execCommand := $hp.execCommand }}
                  {{- if and (eq $handler "exec") (not $execCommand) }}
                  {{- fail "agentResource.healthProbe.handler is exec, the default, but healthProbe.execCommand is empty" }}
                  {{- end }}
                  {{- if and $probed (ne $handler "none") }}
                  {{- range $kind, $timing := dict "readinessProbe" (dict "periodSeconds" 10 "timeoutSeconds" 3 "failureThreshold" 3) "livenessProbe" (dict "initialDelaySeconds" 30 "periodSeconds" 20 "timeoutSeconds" 5 "failureThreshold" 6) }}
                  {{ $kind }}:
                    {{- if eq $handler "exec" }}
                    exec:
                      command: {{ toJson $execCommand }}
                    {{- else }}
                    httpGet: {path: /healthz, port: '${schema.spec.port}'}
                    {{- end }}
                    {{- range $k, $v := $timing }}
                    {{ $k }}: {{ $v }}
                    {{- end }}
                  {{- end }}
                  {{- end }}
                  resources:
                    requests:
                      # The sandbox is sized from these, so they are not only a scheduling hint. A
                      # pod with no requests gets a small default sandbox.
                      cpu: ${schema.spec.cpuRequest}
                      memory: ${schema.spec.memoryRequest}
                    limits:
                      cpu: ${schema.spec.cpuLimit}
                      memory: ${schema.spec.memoryLimit}

                  securityContext:
                    allowPrivilegeEscalation: false
                    readOnlyRootFilesystem: true
                    capabilities:
                      drop: ["ALL"]

                  volumeMounts:
                    - { name: tmp, mountPath: /tmp }
                    - { name: workspace, mountPath: /workspace }
                    - name: gateway-identity
                      mountPath: /var/run/secrets/eks-agents/gateway
                      readOnly: true
                    - name: eks-pod-identity-token
                      mountPath: /var/run/secrets/pods.eks.amazonaws.com/serviceaccount
                      readOnly: true
                    {{- /* second audience, for a directly-called MCP server */}}
                    - name: mcp-identity
                      mountPath: /var/run/secrets/eks-agents/mcp
                      readOnly: true
                    # The platform team's secrets for this agent, as FILES: a Secret named
                    # <agent>-secrets, one file per key. Files rather than environment variables,
                    # because an agent runs model-generated code and an environment is the first
                    # thing such code prints. Optional, so an agent without one starts unchanged.
                    - name: agent-secrets
                      mountPath: /var/run/secrets/eks-agents/app
                      readOnly: true

              volumes:
                - name: tmp
                  emptyDir: {}
                - name: agent-secrets
                  secret:
                    secretName: ${schema.metadata.name}-secrets
                    optional: true
                    defaultMode: 0440
                - name: workspace
                  emptyDir: {}

                # The token the Pod Identity credential endpoint authenticates. Its audience is
                # fixed by that endpoint and is NOT the gateway's -- two projected tokens for two
                # relying parties, which is the whole point of audience scoping. Mirrors exactly
                # what EKS would have injected, so a pod carrying this is indistinguishable from one
                # the webhook got to in time.
                # The second audience, for an MCP server the agent calls directly. Projected
                # unconditionally with the audience from the schema: when mcpAudience is empty the
                # token names nothing any server accepts, and AGENT_MCP_TOKEN_FILE is unset so
                # nothing reads it. A conditional volume would mean a Deployment whose shape changes
                # with a field, which rolls every pod on an unrelated edit.
                - name: mcp-identity
                  projected:
                    defaultMode: 420
                    sources:
                      - serviceAccountToken:
                          audience: '${schema.spec.mcpAudience != "" ? schema.spec.mcpAudience : "unused"}'
                          expirationSeconds: 3600
                          path: token

                - name: eks-pod-identity-token
                  projected:
                    defaultMode: 420
                    sources:
                      - serviceAccountToken:
                          audience: pods.eks.amazonaws.com
                          # One hour, not the roughly 24 hours EKS itself injects. The
                          # kubelet refreshes a projected token in place well before expiry and the
                          # credential endpoint re-reads it per request, so a short lifetime costs
                          # nothing and bounds the damage if the file is read off a compromised pod.
                          # scripts/validate.sh refuses anything above 3600 here.
                          expirationSeconds: 3600
                          path: eks-pod-identity-token

                # The credential the agent presents to the gateway, and the only one it holds for
                # anything outside the cluster.
                #
                # A projected token rather than the default service account mount, because the
                # gateway's JWT authentication is audience-scoped: it accepts a token minted for
                # itself and rejects one the agent obtained for some other relying party. The
                # default mount carries the API server's audience and would be rejected -- and it is
                # off on this service account anyway, which is the second reason this has to be
                # here rather than assumed.
                #
                # It grants nothing anywhere. It only names the caller. The gateway validates it
                # against the cluster's OIDC issuer, matches jwt.sub against the agents the
                # platform team declared, and then assumes THIS agent's IAM role with its own
                # credentials to sign the outbound call. So a copy of this token lets a holder be
                # attributed as the agent at the gateway, which is why the expiry is short and the
                # audience is narrow.
                #
                # Isolated-sandbox mode replicates a projected, audience-bound token into the
                # guest: the same path EKS Pod Identity and IRSA already use. What it withholds is
                # only the default cluster API token mount, which is off here. If you author a
                # sandbox policy to constrain what runs in the sandbox, declare this volume as
                # expected, or the sandbox refuses to replicate it -- and that
                # refusal happens when the policy is generated, naming this volume, rather than at
                # runtime as an agent that cannot authenticate.
                - name: gateway-identity
                  projected:
                    defaultMode: 0400
                    sources:
                      - serviceAccountToken:
                          path: token
                          audience: ${schema.spec.gatewayAudience}
                          # Ten minutes. The kubelet refreshes a projected token at 80% of its
                          # lifetime and rewrites the file in place, so a short expiry costs
                          # nothing operationally and bounds what a leaked copy is worth. An agent
                          # that reads the file once at startup and caches the string breaks after
                          # this interval, which is the correct way for that bug to surface.
                          expirationSeconds: 600

{{- end }}
{{- end }}
