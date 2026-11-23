# The passwords no human should have to invent, and the IAM that lets the cluster read them.
#
# WHAT THIS REPLACES. Components on the open source path that read an existing Kubernetes Secret
# nothing created: valkey's auth, Grafana's admin, Langfuse's own secrets, and the project keys that
# the collector and the evaluation runner use to reach Langfuse. Each one leaves its
# component waiting indefinitely, and the symptom is never a message about a missing secret --
# Grafana sits in CreateContainerConfigError and valkey in ContainerCreating, with the reason only
# in `kubectl describe pod`. All five apply on a fresh cluster on this path.
#
# WHY NOT IN GIT, AND WHY NOT HELM-GENERATED. A generated password committed to Git is wrong. A
# Helm-generated one changes on every render, which makes Argo CD diff forever. So the value is
# generated here, stored in AWS Secrets Manager, and projected into the cluster by the Secrets Store CSI driver.
#
# WHAT THE CLUSTER SEES. A real Kubernetes Secret, because every one of the five consumers is a
# third-party chart that reads `existingSecret` and this stack does not control its pod spec. The
# CSI driver's `secretObjects` does that sync, which is the only shape that works without forking
# three charts. gitops/charts/platform-secrets carries the SecretProviderClass objects and the
# reason the sync needs a pod to mount them.

locals {
  # One Secrets Manager secret per Kubernetes Secret, named for the cluster so a teardown sweep can
  # find them by prefix as well as by tag.
  #
  # Filtered rather than a ternary against {}: the two branches would be different object types, which
  # Terraform refuses as an inconsistent conditional.
  secrets = { for name, spec in {
    valkey-auth = {
      namespace = var.namespaces.session_state
      keys      = { password = "generate" }
    }
    # The memory tier's Postgres login for agents (rungs 2 and 3), a role separate from the
    # database owner. Two readers, two routes: CloudNativePG reads it in agent-memory as the managed
    # role's password (gitops/platform/open-source/templates/61-semantic-recall.yaml), and an agent reads it
    # straight from Secrets Manager on its own Pod Identity role, because a pod in a Nitro sandbox
    # takes no CSI volume and an agent namespace runs nothing but sandboxed pods. basic-auth,
    # because CloudNativePG reads `username` and `password` from a Secret of that type.
    agent-memory-db = {
      namespace = var.namespaces.session_state
      type      = "kubernetes.io/basic-auth"
      keys      = { username = "agent_memory", password = "generate" }
      # CloudNativePG reconciles a managed role's password only from a Secret carrying this label.
      # Without it, a Cluster created before the Secret exists (semantic recall on before
      # consolidation, the documented order) records `cannotReconcile: secret not found` and never
      # retries, and every agent login fails `password authentication failed for user
      # "agent_memory"`. It also carries a rotated password through.
      labels = { "cnpg.io/reload" = "true" }
    }
    grafana-admin = {
      namespace = var.namespaces.observability
      keys      = { admin-user = "admin", admin-password = "generate" }
    }
    langfuse-secrets = {
      namespace = var.namespaces.tracing
      # Langfuse reads these three from one secret. salt and encryption key are not passwords a
      # person picks: the encryption key must be 64 hex characters, which is why it is generated
      # with a different shape below rather than from the same random_password.
      keys = { nextauth-secret = "generate", salt = "generate", encryption-key = "generate-hex" }
    }
    # Langfuse's first user and project, created by Langfuse itself at startup from these
    # (LANGFUSE_INIT_*, gitops/platform/open-source/templates/51-langfuse.yaml). The project's API keys are
    # generated HERE rather than clicked into the UI, because two other components need them before
    # anybody has logged in: the collector, to export traces into the project, and the evaluation
    # runner, to read them and write scores back. The prefixes are the ones Langfuse issues.
    langfuse-init = {
      namespace = var.namespaces.tracing
      keys = {
        password   = "generate"
        public-key = "generate:pk-lf-"
        secret-key = "generate:sk-lf-"
      }
    }
    # The same project keys, as the header the collector's OTLP exporter sends to Langfuse's OTLP
    # endpoint: HTTP Basic, public key as user, secret key as password.
    langfuse-otlp = {
      namespace = var.namespaces.observability
      keys      = { authorization = "basic:langfuse-init/public-key:secret-key" }
    }
    # LANGFUSE'S OWN DATA-TIER CREDENTIALS, generated here rather than by the chart. The chart
    # generates them with randAlphaNum and keeps them stable with Helm `lookup`, which Argo CD does
    # not run, so every render after a new commit produces new passwords and the sync writes them
    # over the ones Postgres, ClickHouse, Valkey and SeaweedFS were initialised with: Langfuse then
    # fails its own Postgres login (P1000) and every trace upload (SignatureDoesNotMatch).
    # ignoreDifferences + RespectIgnoreDifferences does not stop it. Each tier's
    # existingSecret in gitops/platform/open-source/templates/51-langfuse.yaml points at these, and the chart
    # then renders none of its own. Key names are the ones each consumer reads.
    langfuse-postgresql-platform = {
      namespace = var.namespaces.tracing
      keys = {
        POSTGRES_USER     = "postgres"
        POSTGRES_PASSWORD = "generate"
        POSTGRES_DB       = "langfuse"
        USERDB_USER       = "langfuse"
        USERDB_PASSWORD   = "generate"
      }
    }
    langfuse-clickhouse-platform = {
      namespace = var.namespaces.tracing
      keys      = { password = "generate" }
    }
    # One key per Valkey ACL user; `default` is the user Langfuse connects as.
    langfuse-redis-platform = {
      namespace = var.namespaces.tracing
      keys      = { default = "generate" }
    }
    # SeaweedFS reads its users from seaweedfs_s3_config, an IAM JSON document naming the same key
    # pair Langfuse signs with.
    langfuse-s3-platform = {
      namespace = var.namespaces.tracing
      keys = {
        accessKey           = "langfuse"
        secretKey           = "generate"
        seaweedfs_s3_config = "seaweedfs-s3:langfuse:langfuse-s3-platform/secretKey"
      }
    }
  } : name => spec if var.include_platform_components && lookup(local.secret_needed_by, name, true) }

  # Each generated secret only when the component that reads it is on, so the base generates none
  # and the Secrets Store CSI driver is not installed for nothing.
  secret_needed_by = {
    valkey-auth                  = var.include_session_state
    grafana-admin                = var.include_observability
    langfuse-secrets             = var.include_langfuse
    langfuse-init                = var.include_langfuse
    langfuse-otlp                = var.include_observability && var.include_langfuse
    langfuse-postgresql-platform = var.include_langfuse
    langfuse-clickhouse-platform = var.include_langfuse
    langfuse-redis-platform      = var.include_langfuse
    langfuse-s3-platform         = var.include_langfuse
    agent-memory-db              = var.include_memory_db
  }

  # The evaluation runner's copy of the project keys, in its own namespace, when it is deployed.
  # A copy rather than a second key pair: Langfuse's headless init creates exactly one.
  evals_secrets = { for name, spec in {
    langfuse-evals-api = {
      namespace = var.namespaces.evals
      keys = {
        public-key = "copy:langfuse-init/public-key"
        secret-key = "copy:langfuse-init/secret-key"
      }
    }
  } : name => spec if var.include_platform_components && var.include_evals }

  # Flattened to one entry per key, because a password is generated per key rather than per secret.
  all_generated = merge(local.secrets, local.evals_secrets)

  secret_keys = merge([
    for name, spec in local.all_generated : {
      for key, kind in spec.keys : "${name}/${key}" => {
        secret = name
        key    = key
        kind   = kind
      }
    }
  ]...)
}

# --- the ingress direct OIDC client --------------------------------------
#
# Separate from local.secrets on purpose. Its value is read from a Secrets Manager secret the operator
# owns, so it is SENSITIVE -- and a sensitive value anywhere in local.secrets would make the for_each
# maps derived from it sensitive too, which Terraform refuses outright.

data "aws_secretsmanager_secret_version" "ingress_oidc" {
  count = var.ingress_oidc != null ? 1 : 0

  secret_id = var.ingress_oidc.client_secret_arn
}

resource "aws_secretsmanager_secret" "ingress_oidc" {
  count = var.ingress_oidc != null ? 1 : 0

  name        = "${var.name}/platform/ingress-oidc"
  description = "The ingress direct OIDC client, shaped for the ALB listener rule. Written by terraform/modules/platform-secrets from the operator's client id and client secret; read by the Secrets Store CSI driver into the ${var.namespaces.ingress} namespace as the Kubernetes Secret ingress-oidc."

  recovery_window_in_days = var.recovery_window_in_days

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "ingress_oidc" {
  count = var.ingress_oidc != null ? 1 : 0

  secret_id = aws_secretsmanager_secret.ingress_oidc[0].id

  # The keys the load balancer controller reads: `clientID` and `clientSecret`
  # (pkg/gateway/routeutils/route_rule_action.go, buildAuthenticateOIDCAction).
  secret_string = jsonencode({
    clientID     = var.ingress_oidc.client_id
    clientSecret = data.aws_secretsmanager_secret_version.ingress_oidc[0].secret_string
  })
}

locals {
  # Every secret this module writes, with the namespace that reads it -- the one map the IAM
  # scoping, the Pod Identity associations and the chart values are all derived from, so they
  # cannot disagree.
  all_secrets = merge(
    {
      for name, spec in local.all_generated : name => {
        namespace = spec.namespace
        arn       = aws_secretsmanager_secret.this[name].arn
        sm_name   = aws_secretsmanager_secret.this[name].name
        keys      = keys(spec.keys)
        type      = try(spec.type, "Opaque")
        labels    = try(spec.labels, {})
        version   = aws_secretsmanager_secret_version.this[name].version_id
      }
    },
    # A filtered for expression rather than a ternary against {} (inconsistent object types), and
    # try() because the literal is evaluated before the filter, when the secret may not exist.
    {
      for name, spec in {
        ingress-oidc = {
          namespace = var.namespaces.ingress
          arn       = try(aws_secretsmanager_secret.ingress_oidc[0].arn, "")
          sm_name   = try(aws_secretsmanager_secret.ingress_oidc[0].name, "")
          keys      = ["clientID", "clientSecret"]
          version   = try(aws_secretsmanager_secret_version.ingress_oidc[0].version_id, "")
        }
      } : name => spec if var.ingress_oidc != null
    },
    # Owned elsewhere; synced here. No version: this module does not write them, so a new value is
    # picked up when the syncer's pod is next created (see var.external_secrets).
    { for name, spec in var.external_secrets : name => merge(spec, { version = "" }) },
  )

  # Namespaces that actually read something. A reader role, policy and association only where one
  # is needed: on the AWS services path that is the ingress namespace alone.
  reading_namespaces = {
    for k, ns in var.namespaces : k => ns
    if length([for name, spec in local.all_secrets : name if spec.namespace == ns]) > 0
  }
}

resource "random_password" "generated" {
  # "generate", or "generate:<prefix>" for a value that must carry a fixed prefix.
  for_each = { for k, v in local.secret_keys : k => v if v.kind == "generate" || startswith(v.kind, "generate:") }

  length = 32
  # No punctuation. These land in connection strings, env vars and Redis AUTH, and a quoted special
  # character is a class of failure that is hard to see and easy to avoid.
  special = false
}

# A 64-hex-character key, which is what Langfuse's ENCRYPTION_KEY requires. random_password cannot
# express that alphabet, so this is random_id's hex of 32 bytes.
resource "random_id" "hex" {
  for_each = { for k, v in local.secret_keys : k => v if v.kind == "generate-hex" }

  byte_length = 32
}

locals {
  # Every generated value by "<secret>/<key>", so a "copy:" or "basic:" key can name another
  # secret's value. Only generated kinds are referenceable: a copy of a literal is just the literal.
  generated_values = merge(
    { for k, v in local.secret_keys : k => (
      v.kind == "generate" ? random_password.generated[k].result :
      "${trimprefix(v.kind, "generate:")}${random_password.generated[k].result}"
    ) if v.kind == "generate" || startswith(v.kind, "generate:") },
    { for k, v in local.secret_keys : k => random_id.hex[k].hex if v.kind == "generate-hex" },
  )

  # The value written for one key. Kinds:
  #   generate                 32 random alphanumerics
  #   generate:<prefix>        the same, after a fixed prefix
  #   generate-hex             64 hex characters
  #   copy:<secret>/<key>      another key's generated value
  #   basic:<secret>/<u>:<p>   "Basic " + base64("<u's value>:<p's value>"), both keys of <secret>
  #   seaweedfs-s3:<user>:<secret>/<key>
  #                            a SeaweedFS S3 identity file: access key <user>, secret key the
  #                            generated value of <secret>/<key>, full rights on every bucket
  #   anything else            written as given
  secret_values = { for k, v in local.secret_keys : k => (
    contains(keys(local.generated_values), k) ? local.generated_values[k] :
    startswith(v.kind, "copy:") ? local.generated_values[trimprefix(v.kind, "copy:")] :
    startswith(v.kind, "basic:") ? format("Basic %s", base64encode(format("%s:%s",
      local.generated_values["${split("/", trimprefix(v.kind, "basic:"))[0]}/${split(":", split("/", trimprefix(v.kind, "basic:"))[1])[0]}"],
      local.generated_values["${split("/", trimprefix(v.kind, "basic:"))[0]}/${split(":", split("/", trimprefix(v.kind, "basic:"))[1])[1]}"],
    ))) :
    startswith(v.kind, "seaweedfs-s3:") ? jsonencode({ identities = [{
      name = split(":", v.kind)[1]
      credentials = [{
        accessKey = split(":", v.kind)[1]
        secretKey = local.generated_values[split(":", v.kind)[2]]
      }]
      actions = ["Admin", "Read", "Write", "List", "Tagging"]
    }] }) :
    v.kind
  ) }
}

resource "aws_secretsmanager_secret" "this" {
  for_each = local.all_generated

  name        = "${var.name}/platform/${each.key}"
  description = "Generated by terraform/modules/platform-secrets for the ${var.name} agent platform. Read by the Secrets Store CSI driver into the ${each.value.namespace} namespace as the Kubernetes Secret ${each.key}."

  # Short, because these are regenerable: nothing in them is customer data, and a deleted cluster's
  # secrets should not keep costing or keep existing. Not zero -- a recovery window of 0 is
  # irreversible and this is the one knob where that bites during a re-apply.
  recovery_window_in_days = var.recovery_window_in_days

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "this" {
  for_each = local.all_generated

  secret_id = aws_secretsmanager_secret.this[each.key].id

  # A JSON document, because the CSI provider's jmesPath can project one key per Kubernetes Secret
  # key from a single secret -- which is what keeps five Secrets Manager secrets from becoming
  # eleven.
  secret_string = jsonencode({
    for key, _ in each.value.keys : key => local.secret_values["${each.key}/${key}"]
  })
}

# --- the role the CSI provider assumes, per namespace -------------------------
#
# ONE ROLE PER NAMESPACE, not one for the cluster. The CSI provider reads Secrets Manager with the
# identity of the POD that mounts the volume, so a role scoped to the three secrets a namespace
# needs is the difference between "tracing can read Langfuse's secrets" and "anything that can
# mount a volume can read every platform secret".

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    # Restricted to this cluster, as every other Pod Identity role in this stack is. Without it the
    # role could be delivered to a service account of the same name on any cluster in the account.
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.cluster_arn]
    }
  }
}

resource "aws_iam_role" "reader" {
  for_each = local.reading_namespaces

  name               = "${var.name}-secrets-${each.key}"
  description        = "Reads the platform secrets for the ${each.value} namespace. Assumed by the Secrets Store CSI driver through EKS Pod Identity."
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = var.tags
}

data "aws_iam_policy_document" "read" {
  for_each = local.reading_namespaces

  statement {
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]

    # Only the secrets that namespace's components read. An empty list would render a policy with no
    # resources, which is a plan-time error rather than a permissive policy -- deliberately.
    resources = [
      for name, spec in local.all_secrets : spec.arn if spec.namespace == each.value
    ]
  }
}

resource "aws_iam_role_policy" "read" {
  for_each = local.reading_namespaces

  name   = "read-platform-secrets"
  role   = aws_iam_role.reader[each.key].id
  policy = data.aws_iam_policy_document.read[each.key].json
}

# The association that delivers it. The service account is created by the chart that mounts the
# volume, and an association for a service account that does not exist yet is accepted -- it is
# resolved at pod admission, so the order between this and the chart does not matter.
resource "aws_eks_pod_identity_association" "reader" {
  for_each = local.reading_namespaces

  cluster_name    = var.cluster_name
  namespace       = each.value
  service_account = var.service_account_name
  role_arn        = aws_iam_role.reader[each.key].arn

  tags = var.tags
}
