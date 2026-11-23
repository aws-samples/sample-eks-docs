output "cluster_name" {
  value       = module.cluster.cluster_name
  description = "EKS cluster name."
}

output "cluster_endpoint" {
  value       = module.cluster.cluster_endpoint
  description = "Private Kubernetes API endpoint."
}

output "kubeconfig_command" {
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.cluster.cluster_name}"
  description = "Run this from inside the VPC: the API endpoint is private."
}

output "model_endpoint" {
  description = "The OpenAI-compatible model endpoint agents call. Set as OPENAI_BASE_URL."
  value       = try(module.gateway[0].model_endpoint, "(no gateway: enable_gateway is false)")
}

output "mcp_endpoint" {
  description = "The MCP endpoint agents call for tools."
  value       = try(module.gateway[0].mcp_endpoint, "(no gateway: enable_gateway is false)")
}

output "gateway_log_group" {
  value       = try(module.gateway[0].gateway_log_group_name, "(no gateway: enable_gateway is false)")
  description = "The gateway's application log. A tool call that returns 'An internal error occurred' says why only here."
}

output "gateway_url" {
  value       = try(module.gateway[0].gateway_url, "(no gateway: enable_gateway is false)")
  description = "The MCP endpoint agents call. Nothing in AWS forces an agent's traffic here; the cluster-scoped network policy is what makes it the only reachable destination."
}

output "gateway_hostname" {
  value       = try(module.gateway[0].gateway_hostname, "(no gateway: enable_gateway is false)")
  description = "Hostname for the network policy's domainNames rule."
}

output "oauth2_callback_urls" {
  value       = try(module.gateway[0].oauth2_callback_urls, {})
  description = "Register each of these with that service's own app configuration before the first consent flow."
}

output "agent_role_arns" {
  value       = { for k, m in module.agent_identity : k => m.role_arn }
  description = "Per-agent IAM roles. With enable_gateway = false the agent signs its own model calls with these, so CloudTrail attributes a model call to the agent; with the gateway on, the gateway signs model calls with its own role."
}

output "agent_subjects" {
  value       = local.agent_subjects
  description = "The service account subjects the gateway admits, written out one by one rather than as a namespace prefix."
}

output "checkpoint_bucket_name" {
  value       = try(module.checkpoints[0].bucket_name, "")
  description = "Durable checkpoint bucket."
}

output "session_state_endpoint" {
  value       = module.memory.session_state_endpoint
  description = "Valkey endpoint for session state. Also what removes the need for MCP session affinity: an agent holding no session in the pod can be load balanced freely."
}

output "memory_id" {
  value       = module.memory.memory_id
  description = "AgentCore Memory ID, empty when consolidation is not enabled. Reached from application code: there is no ACK controller for it, so it is the one AWS dependency here that cannot be composed into the agent-shaped resource."
}

output "genai_observability_console_url" {
  value       = try(module.observability[0].genai_observability_console_url, "(no observability: enable_observability is false)")
  description = "Where the curated agent views are read."
}

output "ecr_repository_urls" {
  value       = module.cluster.ecr_repository_urls
  description = "Where agent images go."
}

output "next_steps" {
  description = "What apply did not do. Read it: the cluster is not an agent platform until these are done."
  value       = <<-EOT
    %{if module.cluster.endpoint_public_access}0. kubectl runs on this machine. The API endpoint is public, open to
       ${length(local.cluster_public_access_cidrs) > 0 ? join(", ", local.cluster_public_access_cidrs) : "the cluster's own public access CIDRs"}, so point kubectl at it:
         aws eks update-kubeconfig --region ${var.region} --name ${var.name}
       From a different address, apply again to move the allowlist; the endpoint keeps refusing
       for a few minutes while EKS rolls the change out. To see why this machine cannot reach it:
         ./scripts/check-endpoint.sh --root terraform/aws-services
       %{if var.enable_bastion}The bastion still reaches the private endpoint whatever this machine's address:
         aws ssm start-session --region ${var.region} --target ${try(module.bastion[0].instance_id, "(no bastion)")}%{else}
       There is no bastion (enable_bastion = false), so that apply is the only way back in: on a
       network whose traffic leaves through a pool of addresses, name the pool in
       cluster_endpoint_public_access_cidrs.
       Every step below runs here, and scripts/run-stack.sh (which exercise.sh, build-images.sh
       --root and teardown.sh --root use) runs its command here too.%{endif}
    %{else}0. Run every step below on this machine, from the repository root: the steps read this
       root's Terraform outputs, and scripts/run-stack.sh runs the in-cluster part on the bastion,
       because the API endpoint is private. For a kubectl command of your own, wrap it the same way:
         ./scripts/run-stack.sh --root terraform/aws-services -- kubectl get agents -A
       or open a shell on the bastion, where kubectl is already configured:
         aws ssm start-session --region ${var.region} --target ${try(module.bastion[0].instance_id, "(no bastion)")}
    %{endif}

    1. Nothing to commit or push. This apply wrote this stack's values beside the platform chart
       (gitops/platform/aws-services/*-values.yaml); the next step passes them to the cluster in the root
       Application, and Argo CD reads the platform's code from ${var.gitops_repo_url} at
       ${var.gitops_repo_revision}.

    2. Build the agent images${var.enable_image_build ? " (in the stack's CodeBuild project; this needs only the AWS CLI)" : ""}:
         ./scripts/build-images.sh --root terraform/aws-services

    3. Install the platform and wait until every component is Synced and Healthy:
         ./scripts/run-stack.sh --root terraform/aws-services -- ./scripts/bootstrap-gitops.sh --path aws-services --sync
       It applies the three bootstrap objects and runs the root Application's first sync, which is
       manual on purpose.%{if !var.enable_argocd} With enable_argocd = false there is no Argo CD; install
       from the same Applications instead:
         ./scripts/run-stack.sh --root terraform/aws-services -- ./scripts/install-platform.sh --path aws-services%{endif}

    4. Deploy your first agent: an `Agent` naming the image built in step 2 and the model ARNs
       from `terraform output agent_model_arns` (see "Deploy an agent" in the EKS User Guide).
       Then check every layer that is on:
         ./scripts/exercise.sh --path aws-services
%{if length(var.oauth2_providers) + length(var.api_key_providers) > 0}
    5. Set the credential provider secret values. Terraform created the providers and never the
       values. Register these callback URLs with each service first:
       ${length(try(module.gateway[0].oauth2_callback_urls, {})) == 0 ? "(no OAuth2 providers configured)" : join("\n       ", [for k, v in try(module.gateway[0].oauth2_callback_urls, {}) : "${k}: ${v}"])}
       A consented service also needs the consent receiver (scripts/consent.sh).
%{endif}%{if var.enable_observability && var.enable_transaction_search}
    ${length(var.oauth2_providers) + length(var.api_key_providers) > 0 ? 6 : 5}. Confirm Transaction Search is on, or the GenAI Observability views carry no per-invocation
       token counts:
         aws xray get-trace-segment-destination --region ${var.region}
%{endif}
    Later: apply an example with its placeholders filled in from this cluster's values:
         ./scripts/run-stack.sh --root terraform/aws-services -- bash -c './scripts/render-example.sh <file> aws-services | kubectl apply -f -'
    and set activate_cost_allocation_tags = true once agents have
    made calls, with payer-account credentials, to split spend by agent in Cost Explorer.
  EOT
}

output "vpc_id" {
  description = "The VPC the cluster runs in, whether supplied or created here."
  value       = local.vpc_id
}

output "subnet_ids" {
  description = "The private subnets the cluster and its nodes use."
  value       = local.subnet_ids
}

output "network_created_here" {
  description = "True when this configuration created the VPC, so `terraform destroy` will remove it. False when you brought your own, which is never touched."
  value       = var.vpc_id == ""
}

output "dogwood_policies_to_apply" {
  description = "Temporal policies with the gateway ARN resolved, as the gateway module applies them through the AWS CLI (the AWS provider's policy resource does not expose definition.policy). Empty unless dogwood_policies is set."
  value       = try(module.gateway[0].dogwood_policies_to_apply, {})
}

output "agent_model_arns" {
  description = "The ARNs an Agent's modelArns must list to call direct_model_id with no gateway: the inference profile and the foundation model in every Region it routes to. Paste them into the Agent."
  value       = concat([data.aws_bedrock_inference_profile.direct.inference_profile_arn], sort([for m in data.aws_bedrock_inference_profile.direct.models : m.model_arn]))
}

output "image_build" {
  description = "The CodeBuild project scripts/build-images.sh --root starts, and where it stages the tree -- null when enable_image_build is false."
  value = var.enable_image_build && length(module.image_build) > 0 ? {
    project_name  = module.image_build[0].project_name
    source_bucket = module.image_build[0].source_bucket
    log_group     = module.image_build[0].log_group
  } : null
}

output "bastion" {
  description = "How to reach the private API endpoint from outside the VPC -- null when enable_bastion is false, which is allowed only with the public endpoint on (everything then runs from the workstation)."
  value = var.enable_bastion ? {
    instance_id           = module.bastion[0].instance_id
    role_arn              = module.bastion[0].role_arn
    security_group_id     = module.bastion[0].security_group_id
    start_session_command = module.bastion[0].start_session_command
    run_command_example   = module.bastion[0].run_command_example
    readiness_check       = module.bastion[0].readiness_check
    staging_bucket        = module.bastion[0].staging_bucket
  } : null
}

output "ingress" {
  description = "What is left to do by hand after apply, and the names ingress came up with. Empty when ingress is off."
  value = var.enable_ingress ? {
    domain          = module.ingress[0].domain_name
    certificate_arn = module.ingress[0].certificate_arn
    private_zone_id = module.ingress[0].agent_zone_id

    # Register these as the redirect URIs in your provider when ingress_idp is "oidc" (Cognito's
    # endpoint: the provider hands the person back to the pool) or "oidc-direct" (the load
    # balancer's, on every exposed hostname). Empty for the pool's own users.
    idp_redirect_uris = module.ingress[0].idp_redirect_uris

    cognito_user_pool_id = module.ingress[0].cognito_user_pool_id

    # The generated certificate, when one was generated. Nothing trusts it, so a client needs it:
    #   terraform output -raw ingress_certificate_pem > ca.pem
    #   curl --cacert ca.pem https://<agent>.<domain>/
    certificate_pem_available = module.ingress[0].certificate_pem != ""
  } : null
}

output "ingress_certificate_pem" {
  description = "The generated ingress certificate, for a client that has to trust it. Empty unless ingress_self_signed_certificate is set. Separate from the ingress output so it can be redirected to a file with -raw."
  value       = try(module.ingress[0].certificate_pem, "")
}

output "region" {
  description = "The stack's Region. scripts/run-stack.sh and check-endpoint.sh read it, so a shell whose default Region is another one still reaches this stack."
  value       = var.region
}
