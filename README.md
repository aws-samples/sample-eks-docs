# Amazon EKS User Guide reference samples

Reference code for the [Amazon EKS User Guide](https://docs.aws.amazon.com/eks/latest/userguide/). Each sample here backs a walkthrough in the user guide. The user guide explains the concepts and the steps, and this repository holds the Terraform, Kubernetes manifests and scripts those steps run.

The samples are written to be read as well as run. Each one shows a working way to set up a pattern on Amazon EKS, with its defaults and trade-offs called out, so you can adapt it to your own environment.

## Contents

| Section | What it covers | User Guide section |
| --- | --- | --- |
| [AI/ML on EKS](ai-ml/) | GPU-ready clusters, model serving, shared storage and GPU health testing | [AI/ML on Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/ml-on-eks.html) |
| [AI agents on EKS](agents/) | An agent platform on EKS Auto Mode, on an open source path or an AWS services path: Nitro Sandbox isolation, network policy, an egress gateway, a per-agent identity, and the layers each page turns on | [AI agents on Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/agents.html) |

## Repository layout

Each top-level directory is one section of the EKS User Guide and has its own README. That README is the entry point for the section, listing the samples, their prerequisites, and the order to run them in. Each sample inside a section has a README next to its code that says what it does, how to run it, how to check that it worked, and how to clean it up.

## AI/ML on EKS

Samples for the [AI/ML on Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/ml-on-eks.html) section of the guide. They start with Terraform for a GPU-ready cluster, in an EKS Auto Mode variant and a self-managed Karpenter variant, and build on it with manifests for serving a model, mounting FSx for Lustre, and testing GPU fault detection and node repair. Start with the [AI/ML README](ai-ml/).

## AI agents on EKS

Terraform and GitOps templates for the [AI agents on Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/agents.html) section of the guide. The base is an EKS Auto Mode cluster that runs a sandboxed agent; each page of the guide then turns on one layer, such as the gateway, the mesh, ingress, memory, observability or evaluations, on either the open source path or the AWS services path. Start with the [agents README](agents/).

## Before you run a sample

- **Costs.** The samples create billable AWS resources, and some of them (such as capacity reservations and file systems) bill whether or not anything runs on them. Each sample's README names the resources it creates and how to remove them. Clean up when you finish.
- **Security.** These are samples, not production configurations. Some defaults favor getting started quickly, such as endpoints open to `0.0.0.0/0`. Read a sample's variables and README before you run it in a shared or long-lived account, and narrow access to your own address range.
- **Tools.** Most samples use [Terraform](https://developer.hashicorp.com/terraform/install), the [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), [kubectl](https://kubernetes.io/docs/tasks/tools/) and `envsubst`. Each section's README lists the versions it needs.

## Conventions

- Commands in a README run from the directory that README is in, unless the command says otherwise.
- Manifests with `${VARIABLE}` placeholders are rendered with `envsubst` before `kubectl apply`. Preview the output first (`envsubst < file.yaml | cat`) to confirm no placeholder is left unresolved.
- Terraform state can hold sensitive values. The repository's `.gitignore` excludes state and `*.tfvars` files; keep them out of commits.

## Contributing

Issues and pull requests are welcome; see [CONTRIBUTING](CONTRIBUTING.md). A change to a sample should keep its User Guide walkthrough working, so name the page it affects in the pull request.

To add a section:

1. Create a top-level directory for it, named after the User Guide section.
2. Add a README there that links to the guide, lists the samples, and gives their prerequisites.
3. Give each sample its own README covering what it does, how to run and verify it, and how to clean it up.
4. Add a row to the [Contents](#contents) table and a short section to this README.

## Security

To report a security issue, see [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications). Do not open a public GitHub issue.

## License

This project is licensed under the Apache-2.0 License. See [LICENSE](LICENSE).
