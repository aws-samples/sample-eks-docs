variable "name" {
  description = "Name prefix, normally the cluster name."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster the agents run on. Descriptions only."
  type        = string
}

variable "vpc_id" {
  description = "VPC the session state cache lives in. Required when enable_session_state is set."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Private subnets for the session state cache. Required when enable_session_state is set."
  type        = list(string)
  default     = []
}

variable "client_security_group_ids" {
  description = "Security groups permitted to reach the session state cache, normally the EKS cluster security group. Referenced by ID rather than by CIDR, so the rule names the cluster and does not survive a VPC re-address."
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for every rung that supports one. Null uses the service default on each."
  type        = string
  default     = null
}

# --- Rung 1 ------------------------------------------------------------------

variable "enable_session_state" {
  description = "Create the ElastiCache Serverless cache for session and working state. This is the rung most agents need and the only one; an agent whose memory lives and dies with one task needs nothing above it."
  type        = bool
  default     = false
}

variable "session_state_max_storage_gb" {
  description = "Cap on cached data. A cap, not a reservation: it is what stops one agent's session growth from becoming an unbounded bill."
  type        = number
  default     = 10
}

variable "session_state_max_ecpu" {
  description = "Cap on eCPU per second."
  type        = number
  default     = 5000
}

variable "session_state_snapshot_retention_days" {
  description = "Daily snapshot retention. Zero by default: session state is working state, reconstructible from the durable checkpoint, and a snapshot of it is a copy of conversation content with its own retention question."
  type        = number
  default     = 0
}

variable "session_state_user_group_id" {
  description = <<-EOT
    An ElastiCache user group you manage. Null is the normal case and makes this module create one.

    Null does not mean "no authentication": the module creates a user group with the default user
    disabled (`off -@all`) and an IAM-authenticated user for the agents, so reaching the cache on
    the network is not the same as being able to use it. Attaching no user group at all is what
    leaves a cache on its default user, and a cache in that state answers PING, SET and GET from an
    agent pod with no credential at all.
  EOT
  type        = string
  default     = null
}

variable "session_state_agent_keyspaces" {
  description = <<-EOT
    One ElastiCache user per agent, each confined to its own key prefix. Map an agent's short name
    to the Valkey key pattern it owns, without the leading `~`:

        session_state_agent_keyspaces = {
          research = "agent:research:*"
          triage   = "agent:triage:*"
        }

    Empty is the default and leaves every agent sharing one user whose access string is `~*`, which
    means each of them can read and write every other agent's keys. That is fine for one agent and
    wrong for several.

    The key pattern is enforced -- a user created `on ~agent:a:*` is refused
    another agent's key with `NOPERM`, read and write alike. Pair each entry with an
    `elasticache:Connect` grant naming the cache and ONLY that agent's own user ARN (see the
    session_state_agent_user_arns output): a role scoped that way is refused with `WRONGPASS` at
    AUTH if it tries to present a different agent's user.

    Two limits this does not lift. SCAN still lists other agents' key NAMES, because the pattern
    governs access to a key rather than its appearance in a listing -- so a key name is not a place
    for anything sensitive. And `Users per User Group` is 100 by default, which bounds this at
    dozens of agents until the quota is raised.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for p in values(var.session_state_agent_keyspaces) : !startswith(p, "~")])
    error_message = "Give the key pattern without a leading '~'; the module adds it."
  }

  validation {
    condition     = alltrue([for p in values(var.session_state_agent_keyspaces) : p != "*"])
    error_message = "A pattern of '*' is the shared keyspace this variable exists to avoid. Leave the map empty instead."
  }
}

# --- Rung 2 ------------------------------------------------------------------

variable "enable_semantic_recall" {
  description = "Create the S3 Vectors bucket and indexes. An agent that answers questions over a corpus usually stops at this rung, because what it needs is retrieval and not memory."
  type        = bool
  default     = false
}

variable "semantic_recall_bucket_name" {
  description = "Vector bucket name. Required when enable_semantic_recall is set."
  type        = string
  default     = null
}

variable "semantic_recall_indexes" {
  description = <<-EOT
    Vector indexes to create, keyed by name.

    dimension has to match the embedding model: 1024 for Amazon Titan Text Embeddings V2 at its
    default, 1536 for its largest. A mismatch is not caught until the first write.

    non_filterable_metadata_keys names the payload fields an agent does not filter on. Naming them
    is what keeps a field added later from silently entering the index.
  EOT
  type = map(object({
    dimension                    = number
    distance_metric              = optional(string, "cosine")
    non_filterable_metadata_keys = optional(list(string), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.semantic_recall_indexes : contains(["cosine", "euclidean"], v.distance_metric)
    ])
    error_message = "distance_metric must be cosine or euclidean."
  }

  validation {
    condition = alltrue([
      for k, v in var.semantic_recall_indexes : v.dimension > 0 && v.dimension <= 4096
    ])
    error_message = "dimension must be between 1 and 4096, and must match the embedding model the agent uses."
  }
}

# --- Rung 3 ------------------------------------------------------------------

variable "enable_consolidation" {
  description = "Create AgentCore Memory and its strategies. This is the rung most teams do not reach. Enable it where an agent personalizes across sessions, or where several agents share one model of the same user."
  type        = bool
  default     = false
}

variable "consolidation_event_expiry_duration" {
  description = <<-EOT
    How long raw memory events are kept, in DAYS. There is no safe default for a store of what
    people told the agents, so set it from the organization's retention policy.

    DAYS AS A NUMBER, not an ISO-8601 duration. A `P90D`-style string cannot be applied at all:
    the API's eventExpiryDuration is an integer number of days (min 3, max 365) and the provider
    rejects the string at plan time with
    "Inappropriate value for attribute event_expiry_duration: a number is required".
  EOT
  type        = number
  default     = 90

  validation {
    condition     = var.consolidation_event_expiry_duration >= 3 && var.consolidation_event_expiry_duration <= 365
    error_message = "consolidation_event_expiry_duration is a number of days, from 3 to 365 -- the range the AgentCore Memory API accepts."
  }
}

variable "consolidation_model_arns" {
  description = "Model ARNs the memory execution role may invoke for extraction and consolidation. Scoped, so the memory layer cannot invoke a model nobody approved."
  type        = list(string)
  default     = []
}

variable "consolidation_indexed_keys" {
  description = "Event keys to index, so a retrieval can filter on them."
  type = list(object({
    key  = string
    type = string
  }))
  default = []
}

variable "consolidation_strategies" {
  description = <<-EOT
    Memory strategies, keyed by name.

    namespaces is not optional in practice. It is what scopes a memory per user and per agent; a
    strategy without it pools every user's memory into one space, which is the failure that makes a
    personalizing agent return one person's context to another. Use templates such as
    "/agents/{actorId}/{sessionId}".

    type is SEMANTIC, SUMMARIZATION, USER_PREFERENCE, EPISODIC or CUSTOM.

    THE FOUR BUILT-IN TYPES TAKE NOTHING ELSE. Their extraction and consolidation prompts are the
    service's; configuration_type, extraction_model_id and consolidation_model_id apply only to
    CUSTOM and the API refuses a configuration on any other type.

    For CUSTOM, configuration_type says which built-in it overrides -- SEMANTIC_OVERRIDE,
    SUMMARY_OVERRIDE, USER_PREFERENCE_OVERRIDE, EPISODIC_OVERRIDE -- or SELF_MANAGED, where your
    own code does the extraction and the service only triggers it. An *_OVERRIDE is where
    extraction_model_id and consolidation_model_id belong, and every model named there has to
    appear in consolidation_model_arns or the strategy cannot invoke it.
  EOT
  type = map(object({
    type                   = string
    namespaces             = list(string)
    configuration_type     = optional(string)
    extraction_model_id    = optional(string)
    extraction_prompt      = optional(string, "")
    consolidation_model_id = optional(string)
    consolidation_prompt   = optional(string, "")
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.consolidation_strategies : length(v.namespaces) > 0
    ])
    error_message = "Every strategy needs at least one namespace. Without one, every user's memory lands in the same space and a personalizing agent can return one person's context to another."
  }

  validation {
    condition = alltrue([
      for k, v in var.consolidation_strategies :
      contains(["SEMANTIC", "SUMMARIZATION", "USER_PREFERENCE", "EPISODIC", "CUSTOM"], v.type)
    ])
    error_message = "A strategy type is one of SEMANTIC, SUMMARIZATION, USER_PREFERENCE, EPISODIC or CUSTOM."
  }

  validation {
    condition = alltrue([
      for k, v in var.consolidation_strategies :
      v.type == "CUSTOM" ? contains(["SEMANTIC_OVERRIDE", "SUMMARY_OVERRIDE", "USER_PREFERENCE_OVERRIDE", "EPISODIC_OVERRIDE", "SELF_MANAGED"], coalesce(v.configuration_type, "")) : v.configuration_type == null
    ])
    error_message = "configuration_type is required for a CUSTOM strategy -- one of SEMANTIC_OVERRIDE, SUMMARY_OVERRIDE, USER_PREFERENCE_OVERRIDE, EPISODIC_OVERRIDE, SELF_MANAGED -- and must be unset for every other type, which takes no configuration at all."
  }

  validation {
    condition = alltrue([
      for k, v in var.consolidation_strategies :
      v.type == "CUSTOM" || (v.extraction_model_id == null && v.consolidation_model_id == null)
    ])
    error_message = "extraction_model_id and consolidation_model_id apply only to a CUSTOM strategy. A built-in type uses the service's own prompts and the API refuses a configuration on it."
  }
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
