# Memory on the AWS-managed path, as three separate rungs a platform team climbs only as far as its
# use case reaches.
#
#   session state      ElastiCache Serverless (Valkey)    an agent holds state between turns
#   semantic recall    S3 Vectors                         an agent retrieves by meaning
#   consolidation      AgentCore Memory                   an agent personalizes across sessions
#
# Most agents need the first rung and nothing else. A coding or build agent needs none of them: its
# state is ephemeral and the execution tier reaches a volume and a bucket, not a store. An agent
# answering questions over a corpus usually stops at semantic recall, because what it needs is
# retrieval rather than memory. Consolidation is the rung most teams do not reach, and a team that
# cannot name its case for it is better off without it.
#
# Every rung is off by default here, so enabling one is a decision rather than a side effect of
# choosing this path. The agents-memory page of the EKS User Guide says which rung this module
# implements and what a customer already on Milvus does instead.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  tags = merge(var.tags, {
    "app.kubernetes.io/part-of" = "eks-agents-paved-paths"
    ManagedBy                   = "terraform/modules/memory-aws"
  })
}

# ---------------------------------------------------------------------------
# Rung 1: session state
# ---------------------------------------------------------------------------

# A key-value store is the whole answer for the state an agent holds between the turns of one task.
# ElastiCache Serverless because the alternative on this rung is operating a cache, and a platform
# team on the managed path chose it to avoid exactly that.
#
# This is also the table that removes the need for MCP session affinity. An agent holding no session
# in the pod can be load balanced freely, which is how AWS's own hosted MCP services are built and
# why they need no stickiness. See the agents-ingress page of the EKS User Guide.
resource "aws_security_group" "session_state" {
  count = var.enable_session_state ? 1 : 0

  name = "${var.name}-agent-session-state"

  # NO APOSTROPHE, and no em dash. EC2 accepts only
  # `a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*` in a security group description and rejects the whole
  # CreateSecurityGroup call otherwise:
  #
  #   InvalidParameterValue: Invalid security group description. Valid descriptions are strings
  #   less than 256 characters from the following set: ...
  #
  # A single apostrophe fails the apply at CreateSecurityGroup, after the cluster has been created.
  # Terraform does not validate this at plan time.
  description = "Agent session state cache for cluster ${var.cluster_name}. Reachable from the pod CIDR of that cluster only."
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.name}-agent-session-state" })

  lifecycle {
    create_before_destroy = true
  }
}

# Ingress from the cluster's own security group, not from a CIDR. A CIDR rule survives a VPC
# re-address and keeps permitting whatever moved into those addresses; a security group reference
# names the cluster.
#
# Keyed by position rather than by the security group ID. The ID is normally the cluster security
# group, which EKS creates, so it is not known at plan time; a for_each over the IDs themselves
# cannot be planned at all. The list length is known, so the index can be the key.
resource "aws_vpc_security_group_ingress_rule" "session_state" {
  for_each = var.enable_session_state ? { for i, sg in var.client_security_group_ids : tostring(i) => sg } : {}

  security_group_id            = aws_security_group.session_state[0].id
  referenced_security_group_id = each.value
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Valkey from the cluster"

  tags = local.tags
}

# No egress rule at all. A cache has no reason to open a connection, and the default of a
# Terraform-created security group is no egress, so the absence here is the control.
resource "aws_elasticache_serverless_cache" "session_state" {
  count = var.enable_session_state ? 1 : 0

  name        = "${var.name}-agent-session"
  description = "Session and working state for agents on cluster ${var.cluster_name}."
  engine      = "valkey"

  subnet_ids         = var.subnet_ids
  security_group_ids = [aws_security_group.session_state[0].id]
  kms_key_id         = var.kms_key_arn

  # IAM authentication, not a password. An agent connects with elasticache:Connect on its own role,
  # so access to session state is attributed to the agent and revoked by changing its role rather
  # than by rotating a secret every agent holds.
  #
  # A USER GROUP IS ALWAYS SET. Leaving `session_state_user_group_id` to default to null leaves the
  # cache on its default user, which is no authentication at all -- the IAM design above describes
  # what the cache does only when a group is attached. With no group set, a client with no
  # credential can run PING, SET and GET over TLS, so anything that can reach port 6379 can read
  # and write every agent's session state, which is conversation content. The security group and
  # the network policy would be the only controls, and neither is an authentication decision.
  #
  # The module creates a user group by default. Pass session_state_user_group_id to use one you
  # manage instead.
  user_group_id = coalesce(var.session_state_user_group_id, try(aws_elasticache_user_group.session_state[0].user_group_id, null))

  cache_usage_limits {
    data_storage {
      maximum = var.session_state_max_storage_gb
      unit    = "GB"
    }

    ecpu_per_second {
      maximum = var.session_state_max_ecpu
    }
  }

  # Session state is working state: it is reconstructible from the durable checkpoint, and a daily
  # snapshot of it is a copy of conversation content with its own retention question. Zero is
  # deliberate. Raise it only if the team has decided the content belongs in a backup.
  snapshot_retention_limit = var.session_state_snapshot_retention_days

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Rung 2: semantic recall
# ---------------------------------------------------------------------------

# Retrieval by meaning, which is the job a vector index does. S3 Vectors because it adds an index
# rather than a stateful tier to run; OpenSearch Serverless is the alternative where the workload
# needs hybrid search or filters this does not cover.
resource "aws_s3vectors_vector_bucket" "semantic" {
  count = var.enable_semantic_recall ? 1 : 0

  vector_bucket_name = var.semantic_recall_bucket_name

  encryption_configuration = var.kms_key_arn == null ? null : [{
    sse_type    = "aws:kms"
    kms_key_arn = var.kms_key_arn
  }]

  tags = local.tags
}

resource "aws_s3vectors_index" "semantic" {
  for_each = var.enable_semantic_recall ? var.semantic_recall_indexes : {}

  vector_bucket_name = aws_s3vectors_vector_bucket.semantic[0].vector_bucket_name
  index_name         = each.key
  data_type          = "float32"
  dimension          = each.value.dimension
  distance_metric    = each.value.distance_metric

  # Keys an agent filters on have to be filterable, and everything else should not be: a
  # non-filterable key is cheaper and does not enter the index. Naming them explicitly means a
  # payload field added later does not silently become part of the index.
  #
  # DYNAMIC, not a plain block. non_filterable_metadata_keys is required inside
  # metadata_configuration and takes 1 to 10 entries, so a static block with the variable's own
  # empty default fails the PLAN, not the apply:
  #
  #   Attribute metadata_configuration[0].non_filterable_metadata_keys set must contain at least
  #   1 elements and at most 10 elements, got: 0
  #
  # So enable_semantic_recall = true with any index that does not name a key cannot be planned at
  # all. The block has to be absent rather than present and empty.
  dynamic "metadata_configuration" {
    for_each = length(each.value.non_filterable_metadata_keys) > 0 ? [1] : []

    content {
      non_filterable_metadata_keys = each.value.non_filterable_metadata_keys
    }
  }
}

# ---------------------------------------------------------------------------
# Rung 3: consolidation
# ---------------------------------------------------------------------------

# What AgentCore Memory adds over the two stores below it: it decides what is worth keeping,
# reconciles a new statement against what is stored so a changed preference supersedes instead of
# accumulating, and scopes memory per user and per agent.
#
# One thing to know before adopting it on EKS. AgentCore Memory has no Kubernetes-native interface.
# Every other AWS dependency in this stack is composed per agent by kro through ACK from one
# agent-shaped resource; this one is reached from application code or wired by hand here.
data "aws_iam_policy_document" "memory_assume_role" {
  count = local.memory_policy_needed ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:memory/*"]
    }
  }
}

# Only when it has something to grant (memory_policy_needed below). A built-in strategy runs on
# models AgentCore manages, so otherwise the role has no policy at all and nothing for the service
# to use.
resource "aws_iam_role" "memory" {
  count = local.memory_policy_needed ? 1 : 0

  name               = "${var.name}-agentcore-memory"
  assume_role_policy = data.aws_iam_policy_document.memory_assume_role[0].json
  description        = "Execution role AgentCore Memory uses to run extraction and consolidation for agents on cluster ${var.cluster_name}."
  tags               = local.tags
}

# THE POLICY EXISTS ONLY WHEN IT HAS A STATEMENT. With consolidation on and neither model ARNs nor a
# KMS key -- the shape a built-in strategy (SEMANTIC, SUMMARIZATION, USER_PREFERENCE, EPISODIC) needs
# -- an unconditional model statement would have `resources = []`, and the apply fails on
# PutRolePolicy: `MalformedPolicyDocument: Policy statement must contain resources`.
locals {
  memory_policy_needed = var.enable_consolidation && (length(var.consolidation_model_arns) > 0 || var.kms_key_arn != null)
}

data "aws_iam_policy_document" "memory" {
  count = local.memory_policy_needed ? 1 : 0

  # Extraction and consolidation are model calls the service makes on the platform team's behalf.
  # Scope them to the models named, so the memory layer cannot invoke a model nobody approved.
  dynamic "statement" {
    for_each = length(var.consolidation_model_arns) > 0 ? [1] : []

    content {
      sid       = "InvokeConsolidationModels"
      effect    = "Allow"
      actions   = ["bedrock:InvokeModel"]
      resources = var.consolidation_model_arns
    }
  }

  dynamic "statement" {
    for_each = var.kms_key_arn != null ? [1] : []

    content {
      sid       = "EncryptMemoryRecords"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [var.kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "memory" {
  count = local.memory_policy_needed ? 1 : 0

  name   = "agentcore-memory"
  role   = aws_iam_role.memory[0].id
  policy = data.aws_iam_policy_document.memory[0].json
}

resource "aws_bedrockagentcore_memory" "this" {
  count = var.enable_consolidation ? 1 : 0

  name        = replace("${var.name}_agents", "-", "_")
  description = "Consolidated memory for agents on cluster ${var.cluster_name}."

  # Memory that never expires is a growing record of what people told the agents, under the
  # organization's own retention policy rather than a default. Set it deliberately.
  event_expiry_duration = var.consolidation_event_expiry_duration

  memory_execution_role_arn = local.memory_policy_needed ? aws_iam_role.memory[0].arn : null
  encryption_key_arn        = var.kms_key_arn

  dynamic "indexed_key" {
    for_each = var.consolidation_indexed_keys

    content {
      key  = indexed_key.value.key
      type = indexed_key.value.type
    }
  }

  tags = local.tags

  depends_on = [aws_iam_role_policy.memory]
}

resource "aws_bedrockagentcore_memory_strategy" "this" {
  for_each = var.enable_consolidation ? var.consolidation_strategies : {}

  memory_id = aws_bedrockagentcore_memory.this[0].id
  name      = each.key
  type      = each.value.type

  # Namespaces are what scope a memory per user and per agent. A strategy without them pools every
  # user's memory into one space, which is the failure that makes a personalizing agent return one
  # person's context to another.
  #
  # namespace_templates, not namespaces: the provider deprecated `namespaces` on this resource (and
  # `memory_execution_role_arn`, which now belongs on aws_bedrockagentcore_memory and is set
  # there). Both still work under the `~> 6.73` pin and both emit a deprecation warning on every plan.
  namespace_templates = each.value.namespaces

  # CONFIGURATION BELONGS TO `CUSTOM` AND NOWHERE ELSE, and its type is not the strategy's type.
  #
  # A built-in strategy (SEMANTIC, SUMMARIZATION, USER_PREFERENCE, EPISODIC) takes a name and
  # namespace templates; the extraction and consolidation prompts are the service's. Only CUSTOM
  # takes a configuration, and that configuration is a union over which built-in it OVERRIDES --
  # SEMANTIC_OVERRIDE, SUMMARY_OVERRIDE, USER_PREFERENCE_OVERRIDE, EPISODIC_OVERRIDE -- or
  # SELF_MANAGED, where your own code does the extraction.
  #
  # DYNAMIC, AND ONLY FOR CUSTOM. A static block with `type = each.value.type` cannot be planned
  # for any strategy at all:
  #
  #   Attribute configuration must not be configured when "type" not equals "CUSTOM"
  #   configuration[0].type: Given Value: USER_PREFERENCE
  #     Valid Values: [SEMANTIC_OVERRIDE SUMMARY_OVERRIDE USER_PREFERENCE_OVERRIDE SELF_MANAGED
  #                    EPISODIC_OVERRIDE]
  dynamic "configuration" {
    for_each = each.value.type == "CUSTOM" ? [1] : []

    content {
      type = each.value.configuration_type

      dynamic "extraction" {
        for_each = each.value.extraction_model_id != null ? [1] : []

        content {
          model_id         = each.value.extraction_model_id
          append_to_prompt = each.value.extraction_prompt
        }
      }

      dynamic "consolidation" {
        for_each = each.value.consolidation_model_id != null ? [1] : []

        content {
          model_id         = each.value.consolidation_model_id
          append_to_prompt = each.value.consolidation_prompt
        }
      }
    }
  }
}


# ---------------------------------------------------------------------------
# Who may use session state
# ---------------------------------------------------------------------------
#
# Created unless the operator passes a user group of their own. Two users, because a user group must
# contain one named "default" and that is the user an unauthenticated client lands on -- so the
# whole point is to make that user able to do nothing.

locals {
  create_session_state_user_group = var.enable_session_state && var.session_state_user_group_id == null
}

# For the disabled default user only. See the note on that resource for why a user that cannot
# authenticate still has to be given a password.
resource "random_password" "session_state_default" {
  count = local.create_session_state_user_group ? 1 : 0

  length  = 32
  special = false
}

# The default user, disabled. `off` refuses authentication and `-@all` grants no command, so a
# client that connects without credentials gets a user that cannot run anything. Left enabled,
# this user is the unauthenticated access described above.
#
# IT STILL NEEDS A PASSWORD SET, which reads like a contradiction. Valkey refuses the obvious
# shape:
#
#   InvalidParameterCombination: No-password-required is not allowed for a user with engine Valkey
#
# and IAM authentication is not available either, because it requires user_id and user_name to be
# identical and this user's name has to be "default". So the user carries a random password that
# nothing is ever told. `off` is what actually disables it: the password cannot be used to
# authenticate while the user is off, and the access string grants no command even if it could.
resource "aws_elasticache_user" "session_state_default" {
  count = local.create_session_state_user_group ? 1 : 0

  user_id       = "${var.name}-agent-session-default"
  user_name     = "default"
  engine        = "valkey"
  access_string = "off -@all"

  authentication_mode {
    type = "password"
    # Generated, never output, and never used. Rotating it changes nothing while the user is off.
    passwords = [random_password.session_state_default[0].result]
  }

  lifecycle {
    # ElastiCache keeps deleted user ids reserved for a while; replacing in place avoids a name
    # collision on a re-apply after a destroy.
    create_before_destroy = true
  }
}

# The agents' user. For IAM authentication ElastiCache REQUIRES user_id and user_name to be
# identical, and the client authenticates with a signed token rather than a stored password, so
# nothing here is a credential anybody has to hold or rotate.
resource "aws_elasticache_user" "session_state_agents" {
  count = local.create_session_state_user_group ? 1 : 0

  user_id   = "${var.name}-agents"
  user_name = "${var.name}-agents"
  engine    = "valkey"

  # Every key, every command in the connection, keyspace and generic data groups -- but not admin:
  # an agent has no reason to run CONFIG, FLUSHALL or REPLICAOF against shared session state.
  access_string = "on ~* +@all -@admin -@dangerous"

  authentication_mode {
    type = "iam"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# One user per agent, each confined to its own key prefix. ElastiCache enforces the ACL key
# pattern -- a user created `on ~agent:a:*` is refused another agent's key
# with `NOPERM No permissions to access a key`, on reads and writes alike -- and IAM enforces which
# user a role may present, so a role whose elasticache:Connect names only its own user ARN gets
# `WRONGPASS` at AUTH when it tries to be another agent.
#
# Two things the access string does NOT do. SCAN still lists other agents' key NAMES (only the
# value access is refused), so a key name is not a place for anything sensitive. And `Users per
# User Group` is 100 by default, which bounds this at dozens of agents without a quota increase.
resource "aws_elasticache_user" "session_state_agent" {
  for_each = local.create_session_state_user_group ? var.session_state_agent_keyspaces : {}

  user_id   = "${var.name}-agent-${each.key}"
  user_name = "${var.name}-agent-${each.key}"
  engine    = "valkey"

  # Same command grants as the shared user; the keyspace is what narrows.
  access_string = "on ~${each.value} +@all -@admin -@dangerous"

  authentication_mode {
    type = "iam"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_elasticache_user_group" "session_state" {
  count = local.create_session_state_user_group ? 1 : 0

  user_group_id = "${var.name}-agent-session"
  engine        = "valkey"

  # The shared user is always in the group: an agent not named in
  # session_state_agent_keyspaces still needs an identity to connect as. Giving every agent its own
  # entry is what makes the shared one unused rather than absent.
  user_ids = concat(
    [
      aws_elasticache_user.session_state_default[0].user_id,
      aws_elasticache_user.session_state_agents[0].user_id,
    ],
    [for u in aws_elasticache_user.session_state_agent : u.user_id],
  )

  lifecycle {
    create_before_destroy = true
  }
}
