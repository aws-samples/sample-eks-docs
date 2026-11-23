# image-build

A CodeBuild project that builds the agent images and pushes them to the stack's ECR repositories. `scripts/build-images.sh --root terraform/<path>` stages the working tree in this module's bucket, starts one build, streams its log and returns its result. Terraform creates only the project: `apply` builds nothing.

The build runs on the node architecture (`architecture`, x86_64 by default) next to ECR, so a workstation needs only the AWS CLI. Both roots call it when `enable_image_build` is on (the default).

| Resource | What it is |
|---|---|
| CodeBuild project | `<name>-agent-images`, privileged for Docker, one-hour timeout |
| IAM role | `<name>-image-build`: reads the staged tree, writes its log, pushes to this stack's repositories only |
| Source bucket | `<name>-image-build-<account>`, public access blocked, TLS only, objects expire after a day, force-destroyed with the stack |
| Log group | `/aws/codebuild/<name>-agent-images` |

To use images already in a registry you choose, set the root's `agent_image_registry` instead; nothing is then built.
