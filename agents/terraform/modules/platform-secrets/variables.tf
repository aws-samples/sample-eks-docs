variable "name" {
  description = "Cluster name, used to prefix the Secrets Manager secret names and the reader roles."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster the Pod Identity associations are created on."
  type        = string
}

variable "cluster_arn" {
  description = "The cluster's ARN. The Pod Identity trust policy is restricted to it with aws:SourceArn."
  type        = string
}

variable "namespaces" {
  description = <<-EOT
    Which namespace each group of platform secrets is read from. Keyed by component group so the
    reader role can be scoped to the secrets that group actually needs, rather than one role for
    every platform secret on the cluster.
  EOT
  type = object({
    session_state = optional(string, "agent-memory")
    observability = optional(string, "monitoring")
    tracing       = optional(string, "langfuse")
    ingress       = optional(string, "ingress")
    evals         = optional(string, "agent-evals")
    gateway       = optional(string, "agentgateway-system")
  })
  default = {
    session_state = "agent-memory"
    observability = "monitoring"
    tracing       = "langfuse"
    ingress       = "ingress"
    evals         = "agent-evals"
    gateway       = "agentgateway-system"
  }
}

variable "external_secrets" {
  description = <<-EOT
    Secrets this module does not create but syncs: Secrets Manager secrets another module owns,
    keyed by the Kubernetes Secret name to write, with the namespace that reads it and the JSON keys
    to project. The open source path passes the egress gateway's third-party credentials here, so a
    GitHub token set out of band reaches the gateway's namespace as a Kubernetes Secret.

    The owning secret's resource policy must admit this module's reader role for that namespace,
    `<name>-secrets-<namespace key>`; the caller computes that ARN by name, to avoid a cycle.

    A value set after the syncer started reaches the cluster only when the syncer's pod is
    recreated: the CSI driver writes the Kubernetes Secret at mount time and rotation is off.
  EOT
  type = map(object({
    namespace = string
    arn       = string
    sm_name   = string
    keys      = list(string)
  }))
  default = {}
}

variable "include_platform_components" {
  description = <<-EOT
    Generate the open source path's secrets -- valkey's auth, Grafana's admin, Langfuse's own,
    Langfuse's first user and project keys, and the collector's export header for that project.
    False on the AWS services path, which runs none of those components and uses this module only
    for the ingress direct OIDC client secret.
  EOT
  type        = bool
  default     = true
}

variable "include_observability" {
  description = <<-EOT
    Generate the secrets that live with the telemetry stack in namespaces.observability: Grafana's
    admin and the collector's Langfuse export header. False when no collector, Prometheus or Grafana
    is installed (enable_observability = false on the open source path).
  EOT
  type        = bool
  default     = true
}

variable "include_evals" {
  description = <<-EOT
    Project the Langfuse project keys into the evaluation runner's namespace (namespaces.evals) as
    langfuse-evals-api, for gitops/charts/agent-evals. Needs include_platform_components, which is
    what generates the keys.
  EOT
  type        = bool
  default     = false
}

variable "ingress_oidc" {
  description = <<-EOT
    The direct OIDC provider's client, when ingress_idp is "oidc-direct": the client id, and the
    ARN of a Secrets Manager secret whose SecretString is the client secret. This module writes both
    into one secret shaped for the listener rule -- keys `clientID` and `clientSecret` -- which
    gitops/charts/platform-secrets syncs into namespaces.ingress as a Kubernetes Secret.

    The client secret is read at plan time and lands in Terraform state; nothing about a Kubernetes
    Secret lets the listener rule read it from anywhere else.
  EOT
  type = object({
    client_id         = string
    client_secret_arn = string
  })
  default = null
}

variable "service_account_name" {
  description = "Service account the Secrets Store CSI driver's mounting pod runs as, in each namespace. Must match the one gitops/charts/platform-secrets creates."
  type        = string
  default     = "platform-secrets"
}

variable "recovery_window_in_days" {
  description = "Secrets Manager recovery window. Short because these are regenerable and hold no customer data; 0 is irreversible and makes a re-apply fail on a name that still exists."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags for the secrets and roles."
  type        = map(string)
  default     = {}
}

variable "include_session_state" {
  description = "Generate valkey's password (session state on the open source path)."
  type        = bool
  default     = true
}

variable "include_langfuse" {
  description = "Generate Langfuse's own secrets and its project keys."
  type        = bool
  default     = true
}

variable "include_memory_db" {
  description = "Generate the memory tier's agent login (consolidation)."
  type        = bool
  default     = true
}
