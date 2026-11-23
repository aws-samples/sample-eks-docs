# Sourced by scripts/run-stack.sh and scripts/build-images.sh: the working tree a command runs in.
#
#   stage_tree <dest> [extra file ...]
#
# Tracked and untracked files under apps/, scripts/ and gitops/ -- never terraform/, which
# holds state and tfvars that name an account -- plus the bootstrap objects Terraform rendered
# (gitops/bootstrap/*/*.local.yaml, gitignored and exactly what a bootstrap needs), plus each extra
# file at the tree's root under its own base name. REPO_ROOT names the repository root.
#
# Nothing else: nothing on the bastion or in CodeBuild reads the rest, and every run-stack.sh call
# uploads this archive, which the bastion then downloads and unpacks, so it is kept small.
stage_tree() {
  local dest="$1" f; shift
  mkdir "$dest"
  (cd "$REPO_ROOT" && git ls-files -co --exclude-standard -- apps scripts gitops) \
    | (cd "$REPO_ROOT" && tar -cf - -T -) | tar -C "$dest" -xf -
  for f in "$REPO_ROOT"/gitops/bootstrap/*/*.local.yaml; do
    [[ -f "$f" ]] && { mkdir -p "$dest/${f#$REPO_ROOT/}"; rmdir "$dest/${f#$REPO_ROOT/}"; cp "$f" "$dest/${f#$REPO_ROOT/}"; }
  done
  for f in "$@"; do cp "$f" "$dest/$(basename "$f")"; done
}
