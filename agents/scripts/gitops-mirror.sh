#!/usr/bin/env bash
#
# A CodeCommit repository Argo CD can read with no stored credential, holding this directory's code.
#
#   ./scripts/gitops-mirror.sh create --name agents-test --region us-west-2
#       -> creates <name>-gitops and prints the tfvars lines that point the platform at it
#   ./scripts/gitops-mirror.sh push --name agents-test --region us-west-2 [--branch b]
#       -> pushes this directory's committed tree (HEAD) to <branch> (default: the name)
#   ./scripts/gitops-mirror.sh delete --name agents-test --region us-west-2
#
# The platform reads its charts from the public repository by default (gitops_repo_url), and the
# stack's own values never go to any repository: Terraform renders them locally and
# scripts/bootstrap-gitops.sh passes them through the root Application. A repository of your own is
# for code you change: templates you've modified, or the Agent manifests you manage from Git
# (agents-application-setup, Step 6). CodeCommit is the one Git host the EKS Argo CD capability reaches
# with no stored credential (argocd_codecommit_repository_arns grants it).
#
# The push never touches your own remotes or branches: it builds one commit of HEAD's tree in a
# temporary worktree and pushes it to the repository by URL. Uncommitted changes are not pushed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-}"; shift || true
NAME="" REGION="${AWS_REGION:-}" BRANCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --path) shift 2 ;;   # accepted and ignored: the push carries no path-specific values
    --branch) BRANCH="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$NAME" && -n "$REGION" && "$ACTION" =~ ^(create|push|delete)$ ]] || {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
REPO_NAME="$NAME-gitops"
BRANCH="${BRANCH:-$NAME}"
aws_() { aws --region "$REGION" "$@"; }

case "$ACTION" in
create)
  read -r URL ARN < <(aws_ codecommit create-repository --repository-name "$REPO_NAME" \
      --repository-description "GitOps mirror for $NAME (scripts/gitops-mirror.sh)" \
      --tags "eks-agents/test-fixture=$NAME" \
      --query 'repositoryMetadata.[cloneUrlHttp,Arn]' --output text)
  cat <<EOF
gitops_repo_url                   = "$URL"
argocd_codecommit_repository_arns = ["$ARN"]
EOF
  ;;
push)
  URL="$(aws_ codecommit get-repository --repository-name "$REPO_NAME" --query repositoryMetadata.cloneUrlHttp --output text)"
  # THIS DIRECTORY MAY NOT BE THE REPOSITORY'S ROOT: in sample-eks-docs it is agents/. Its own tree is
  # what goes to the mirror, so a stack that reads from the mirror sets gitops_repo_path = "".
  PREFIX="$(git -C "$ROOT" rev-parse --show-prefix)"
  SRC="$(git -C "$ROOT" rev-parse --short HEAD)"
  # ONE PARENTLESS COMMIT OF HEAD'S TREE, NO HISTORY. Argo CD reads a tree, so the mirror needs nothing
  # else, and CodeCommit can refuse a push of the whole history ("remote unpack failed: internal
  # error") to a repository that takes a one-commit push. Built without a worktree or a checkout.
  FLAT="$(git -C "$ROOT" -c user.name="gitops-mirror" -c user.email="gitops-mirror@localhost" \
    commit-tree "HEAD:${PREFIX}" -m "The tree of $SRC")"
  # The CodeCommit helper explicitly, and any keychain helper cleared first: on macOS the keychain
  # serves a stale CodeCommit credential and the push fails 403.
  git -C "$ROOT" -c credential.helper= -c credential.helper='!aws --region '"$REGION"' codecommit credential-helper $@' \
    -c credential.UseHttpPath=true push -q -f "$URL" "$FLAT:refs/heads/$BRANCH"
  echo "pushed $(git -C "$ROOT" rev-parse --short "$FLAT") (the tree of $SRC) to $REPO_NAME@$BRANCH"
  ;;
delete)
  # A repository that is already gone is success, so a rerun after a partial teardown is clean. Any
  # other failure -- an expired credential, a denial -- is not: swallowing it too would leave the
  # mirror behind while the script exits 0.
  if out="$(aws_ codecommit delete-repository --repository-name "$REPO_NAME" --query repositoryId --output text 2>&1)"; then
    if [[ -z "$out" || "$out" == "None" ]]; then echo "$REPO_NAME does not exist; nothing to delete"; else echo "deleted $REPO_NAME"; fi
  elif grep -q 'RepositoryDoesNotExist' <<<"$out"; then
    echo "$REPO_NAME does not exist; nothing to delete"
  else
    echo "could not delete $REPO_NAME: $out" >&2; exit 1
  fi
  ;;
esac
