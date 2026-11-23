# shellcheck shell=bash
# Sourced by scripts/bootstrap-gitops.sh and scripts/install-platform.sh: the root Application, with
# the values files Terraform rendered folded into its helm.values.
#
#   root_app <path> <workdir>   -> prints the path of the assembled root-app.yaml
#
# Terraform renders gitops/bootstrap/<path>/root-app.local.yaml with the repository, the revision and
# the layers that are off. Each values file Terraform wrote beside the platform chart goes in under its
# own key, in place of the VALUES_FILES line, so an edit to one of them reaches the cluster on the next
# sync with nothing committed. Text, not a YAML library: the bastion's python has none.
root_app() {
  local P="$REPO_ROOT/gitops/platform/$1" WORKDIR="$2" B="$REPO_ROOT/gitops/bootstrap/$1"
  local src="$B/root-app.yaml"; [[ -f "$B/root-app.local.yaml" ]] && src="$B/root-app.local.yaml"
  render_root "$src"
}
render_root() {  # root-app file -> the file with the values files folded in (P, WORKDIR from root_app)
  local src="$1" out="$WORKDIR/root-app.yaml" key file
  grep -q '# VALUES_FILES' "$src" || { cp "$src" "$out"; echo "$out"; return; }
  : > "$out"
  while IFS= read -r line; do
    if [[ "$line" == *"# VALUES_FILES"* ]]; then
      for key in terraform:terraform-values.yaml collector:collector-values.yaml \
                 externalDns:external-dns-values.yaml agentEvals:agent-evals-values.yaml; do
        file="$P/${key#*:}"
        [[ -f "$file" ]] || continue
        printf '        %s:\n' "${key%%:*}" >> "$out"
        # Ten spaces: two under the key, inside the block scalar's eight.
        sed -e 's/^/          /' -e 's/^ *$//' "$file" >> "$out"
        printf '\n' >> "$out"
      done
    else
      printf '%s\n' "$line" >> "$out"
    fi
  done < "$src"
  echo "$out"
}
