# An MCP tool backend as a Lambda function

`handler.py` is a worked tool backend for an Amazon Bedrock AgentCore Gateway Lambda target, on the AWS services path. Use this shape when the tool is code you write rather than a service that already exists.

## Why a Lambda function

AgentCore Gateway runs outside your VPC and can't reach a ClusterIP Service. An in-cluster MCP server behind it needs a private endpoint (`private_endpoint` on an `mcp_server_targets` or `open_api_targets` entry) and an HTTPS address routable in the VPC, such as an internal load balancer in front of the Service with a certificate the gateway trusts. Terraform places the endpoint's network interface; the address and the certificate are yours to provide. A Lambda target needs no network path: the gateway invokes the function with its own role.

On the open source path, the gateway runs in the cluster, so use the in-cluster server in [`gitops/examples/mcp-server`](../../gitops/examples/mcp-server) instead.

## What the gateway handles

The gateway owns the MCP protocol. It advertises the tool catalog, accepts `tools/list` and `tools/call` from the agent, and invokes the function once per tool call. The function has no JSON-RPC, no transport, and no authentication of its own, because the gateway already verified the agent's identity.

The tool name arrives in the Lambda client context under `bedrockAgentCoreToolName`, namespaced as `<target>___<tool>` (three underscores). The event body is the tool's arguments.

The catalog is `lambda_targets[*].tool_schema` in Terraform, and the gateway advertises exactly those tools. A tool the function implements but the schema doesn't name is unreachable; a tool the schema names but the function doesn't implement returns an `unknown tool` error.

## Deploy it

Terraform takes the function's ARN rather than creating the function. Create it yourself:

```bash
cd apps/mcp-lambda
zip fn.zip handler.py

aws iam create-role --role-name my-agents-mcp-tools \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name my-agents-mcp-tools \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

aws lambda create-function --function-name my-agents-mcp-tools \
  --runtime python3.13 --handler handler.handler --zip-file fileb://fn.zip \
  --role arn:aws:iam::111122223333:role/my-agents-mcp-tools
```

Then add it as a target in your `.tfvars`:

```hcl
lambda_targets = {
  ordertools = {
    description  = "Order lookup and clock, as MCP tools."
    function_arn = "arn:aws:lambda:us-west-2:111122223333:function:my-agents-mcp-tools"
    tool_schema = [
      {
        name        = "lookup_order"
        description = "Look up an order's status, items and ETA by order id."
        properties = [
          { name = "order_id", type = "string", description = "The order id, e.g. ORD-12345.", required = true },
        ]
      },
      { name = "get_time", description = "The current UTC time." },
    ]
  }
}
```

`lambda_target_arns` grants the gateway's role `lambda:InvokeFunction`. It defaults to every function ARN in `lambda_targets`, so set it only to widen or narrow the grant.

## Permit it in the policy engine

When `enable_policy_engine` is on, a Cedar policy has to permit the target for each agent that calls it, or the call is denied by default. `action in AgentCore::Action::"<target name>"` covers every tool on the target. Name the principal in every permit, because a permit with an unconstrained principal admits every caller; `scripts/validate.sh` refuses one in a `.tfvars` file.

```hcl
cedar_policies = {
  research_may_call_order_tools = {
    description = "The research agent may call the order-tools Lambda target."
    statement   = "permit(principal == AgentCore::OAuthUser::\"system:serviceaccount:agents:research\", action in AgentCore::Action::\"ordertools\", resource == AgentCore::Gateway::\"{{gateway_arn}}\");"
  }
}
```

An action in a policy must already exist on the gateway, so apply the target first and add the policy in a second apply. `terraform/aws-services/example.tfvars` has annotated examples.
