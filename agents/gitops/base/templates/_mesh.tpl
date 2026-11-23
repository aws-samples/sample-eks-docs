{{/*
One variable decides the mesh configuration, and everything else in the chart derives from it.

  mesh.mode = none | ambient

  none      no mesh. The network policy still makes the gateway the only reachable destination, so
            egress fails closed -- but pointing an agent at the gateway is then a convention the
            agent could ignore rather than something it cannot evade.
  ambient   a proxy per node. Traffic of an unsandboxed pod is captured below the workload and the
            pod holds no mesh key; a pod in a Nitro sandbox isn't captured.

There is no sidecar mode. An agent runs in a Nitro sandbox in a namespace that enforces Pod Security
restricted, and istio-init's NET_ADMIN, NET_RAW and root are refused there; a sidecar would also put
a mesh private key inside the pod that runs model-generated code. The agents-mesh page of the EKS
User Guide compares the two modes and says what each one costs.

These helpers exist so the rest of the chart never parses the mode string. A template asking "is
this ambient" asks `include "mesh.isAmbient" .`, so adding a mode is one edit here rather than a
string comparison in six files.
*/}}

{{- define "mesh.validModes" -}}
none ambient
{{- end -}}

{{/*
Validate once, and name the alternatives in the failure. A typo would otherwise render a chart with
no mesh at all, which looks like a working install with the enforcement layer quietly missing --
and on this stack the enforcement layer is most of the point.
*/}}
{{- define "mesh.mode" -}}
{{- $mode := .Values.mesh.mode | default "" -}}
{{- if not (has $mode (splitList " " (include "mesh.validModes" .))) -}}
{{- fail (printf "mesh.mode is %q, which is not one of: %s. See https://docs.aws.amazon.com/eks/latest/userguide/agents-mesh.html." $mode (include "mesh.validModes" .)) -}}
{{- end -}}
{{- $mode -}}
{{- end -}}

{{/* True when a per-node proxy captures traffic. */}}
{{- define "mesh.isAmbient" -}}
{{- if eq (include "mesh.mode" .) "ambient" }}true{{ end -}}
{{- end -}}

{{/* True when a mesh is in the path at all. Several templates are no-ops without one. */}}
{{- define "mesh.enabled" -}}
{{- if ne (include "mesh.mode" .) "none" }}true{{ end -}}
{{- end -}}

{{/*
Whether L7 authorization policy needs an extra proxy in the path.

This is the difference that costs most to discover late: ambient needs a waypoint for L7 policy,
because ztunnel is L4 and cannot read a request -- and an L7 rule with no waypoint is accepted and
then misenforced rather than rejected.

So the inbound rows of the identity table that need a token checked cost a proxy per namespace in
ambient. This stack deploys no waypoint: in an agent namespace the
admission policy refuses its unsandboxed pods, and a sandboxed agent's traffic is not captured by
ztunnel either way (gitops/examples/inbound-callers/README.md).
*/}}
{{- define "mesh.l7NeedsWaypoint" -}}
{{- if include "mesh.isAmbient" . }}true{{ end -}}
{{- end -}}

{{/*
The SPIFFE trust domain, which the mesh's own certificate authority issues under.

It is a per-cluster domain, conventionally cluster.local, so an identity under it means nothing
outside this cluster.

Named through a helper rather than read directly because getting it wrong produces an
AuthorizationPolicy whose principals match nothing -- which fails closed and looks like a network
fault.
*/}}
{{- define "mesh.trustDomain" -}}
{{- .Values.mesh.trustDomain | default "cluster.local" -}}
{{- end -}}
