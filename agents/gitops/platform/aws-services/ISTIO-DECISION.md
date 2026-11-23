# Istio ambient on the AWS services path: optional, and off unless the team turns it on.
#
# WHY IT IS OPTIONAL, AND WHY IT BUYS LESS HERE THAN ON THE OTHER PATH.
#
# On both paths the network policy makes the gateway the only reachable destination, so an agent
# that ignores its gateway configuration reaches nothing. That fails closed, and for a platform team
# that builds or packages every agent it runs, it is enough: pointing an agent at the gateway is
# part of the deployment contract.
#
# The mesh buys something different — arrival enforced rather than agreed, for unsandboxed pods; a
# pod in a Nitro sandbox isn't captured. For a captured pod, the per-node proxy intercepts its
# outbound connections and carries them over an mTLS tunnel stamped with the workload's verified
# identity, so the workload needs no gateway configuration of its own.
#
# So: add this if the cluster will run agents the platform team did not build. Leave it out if it
# will not. It is three charts and a data plane to operate, and on this path it buys less than on the
# other one, because the managed gateway is reached over the internet rather than as an in-cluster
# service — the mesh redirects to it, but there is no single in-cluster hop the mesh can make
# unavoidable in the same way.
#
# TO ENABLE AMBIENT: set mesh_mode = "ambient" in the aws-services Terraform. It writes the
# namespace label into the rendered values AND leaves 54-istio-namespace.yaml and 55-istio.yaml out of
# the platform chart's excluded list, so the label and the data plane arrive together. There is no sidecar mode.
#
# mesh_mode defaults to "none" on both paths. In every mode the admission policy in gitops/base
# refuses a pod carrying sidecar injection: Istio resolves a namespace labelled for both data planes
# in favour of sidecar, silently.
#
# The agents-mesh page of the EKS User Guide
# (https://docs.aws.amazon.com/eks/latest/userguide/agents-mesh.html) compares the two values of
# mesh_mode and says what the mesh buys on each path.
#
# This file intentionally contains no Application. It is the decision record for a component this
# path does not install by default, so that "why is there no mesh here" has an answer in the
# repository rather than in somebody's memory.
