output "cluster_name" {
  value       = module.cluster.cluster_name
  description = "EKS cluster name."
}

output "cluster_endpoint" {
  value       = module.cluster.cluster_endpoint
  description = "Private Kubernetes API endpoint."
}

output "cluster_oidc_issuer_url" {
  value       = module.cluster.cluster_oidc_issuer_url
  description = "The issuer AgentGateway validates an agent's service account token against. Per-cluster: a rule written against it covers one cluster and not a fleet."
}

output "kubeconfig_command" {
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.cluster.cluster_name}"
  description = "Run this from inside the VPC: the API endpoint is private."
}

output "gateway_role_arn" {
  value       = coalesce(one(module.gateway[*].gateway_role_arn), "(no gateway: enable_gateway is false)")
  description = "AgentGateway's IAM role. Holds nothing but permission to assume the agent roles below."
}

output "agent_role_arns" {
  value       = { for k, m in module.agent_identity : k => m.role_arn }
  description = "Per-agent IAM roles. This set is also the whole of the gateway's AWS authority."
}

output "agent_spiffe_ids" {
  value       = { for k, m in module.agent_identity : k => "spiffe://${var.mesh_trust_domain}/ns/${m.namespace}/sa/${m.service_account}" }
  description = "The identity each agent presents to the gateway and to mesh peers on this stack. Mesh-issued and scoped to this cluster; it is not a name the platform attested and it cannot be presented outside the cluster."
}

output "checkpoint_bucket_name" {
  value       = try(module.checkpoints[0].bucket_name, "")
  description = "Durable checkpoint bucket."
}

output "ecr_repository_urls" {
  value       = module.cluster.ecr_repository_urls
  description = "Where agent images go."
}

output "third_party_secret_names" {
  value       = var.enable_gateway ? one(module.gateway[*].third_party_secret_names) : {}
  description = "Secrets the gateway reads to attach a credential per caller. Set the values out of band; they are not in Terraform state."
}

output "next_steps" {
  description = "What apply did not do. Read it: the cluster is not an agent platform until these are done."
  value       = <<-EOT
    %{if module.cluster.endpoint_public_access}0. kubectl runs on this machine. The API endpoint is public, open to
       ${length(local.cluster_public_access_cidrs) > 0 ? join(", ", local.cluster_public_access_cidrs) : "the cluster's own public access CIDRs"}, so point kubectl at it:
         aws eks update-kubeconfig --region ${var.region} --name ${var.name}
       From a different address, apply again to move the allowlist; the endpoint keeps refusing
       for a few minutes while EKS rolls the change out. To see why this machine cannot reach it:
         ./scripts/check-endpoint.sh --root terraform/open-source
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
         ./scripts/run-stack.sh --root terraform/open-source -- kubectl get agents -A
       or open a shell on the bastion, where kubectl is already configured:
         aws ssm start-session --region ${var.region} --target ${try(module.bastion[0].instance_id, "(no bastion)")}
    %{endif}

    1. Nothing to commit or push. This apply wrote this stack's values beside the platform chart
       (gitops/platform/open-source/*-values.yaml); the next step passes them to the cluster in the root
       Application, and Argo CD reads the platform's code from ${var.gitops_repo_url} at
       ${var.gitops_repo_revision}.

    2. Build the agent images${var.enable_image_build ? " (in the stack's CodeBuild project; this needs only the AWS CLI)" : ""}:
         ./scripts/build-images.sh --root terraform/open-source

    3. Install the platform and wait until every component is Synced and Healthy:
         ./scripts/run-stack.sh --root terraform/open-source -- ./scripts/bootstrap-gitops.sh --path open-source --sync
       It applies the three bootstrap objects and runs the root Application's first sync, which is
       manual on purpose.%{if !var.enable_argocd} With enable_argocd = false there is no Argo CD; install
       from the same Applications instead:
         ./scripts/run-stack.sh --root terraform/open-source -- ./scripts/install-platform.sh --path open-source%{endif}

    4. Deploy your first agent: an `Agent` naming the image built in step 2 and the model ARNs
       from `terraform output agent_model_arns` (see "Deploy an agent" in the EKS User Guide).
       Then check every layer that is on:
         ./scripts/exercise.sh --path open-source
%{if var.enable_gateway && length(try(one(module.gateway[*].third_party_secret_names), {})) > 0}
    5. Set the brokered credential values. Terraform created the secrets and never their values:
       ${join(", ", values(one(module.gateway[*].third_party_secret_names)))}
       Where the service needs a person's consent, the value exists only after they approve it.
%{endif}%{if !var.enable_platform_secrets}
    ${var.enable_gateway && length(try(one(module.gateway[*].third_party_secret_names), {})) > 0 ? 6 : 5}. enable_platform_secrets is false, so valkey-auth, grafana-admin, langfuse-secrets,
       langfuse-init and langfuse-otlp are yours to create; each component waits until it exists.
%{endif}
    Later: apply an example with its placeholders filled in from this cluster's values:
         ./scripts/run-stack.sh --root terraform/open-source -- bash -c './scripts/render-example.sh <file> | kubectl apply -f -'
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

output "identity_change_topic_arn" {
  description = "The SNS topic that reports changes to the gateway's role, the person roles, the cluster's Pod Identity associations and the user pool (identity_change_alerts). Empty without it."
  value       = try(module.identity_change_alerts[0].topic_arn, "")
}

output "region" {
  description = "The stack's Region. scripts/run-stack.sh and check-endpoint.sh read it, so a shell whose default Region is another one still reaches this stack."
  value       = var.region
}
