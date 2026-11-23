#!/usr/bin/env bash
#
# Build and push the agent images into the ECR repositories Terraform created.
#
#   # From a Terraform root. With enable_image_build (the default) it builds in the stack's CodeBuild
#   # project -- this working tree, staged in S3 -- and needs only the AWS CLI here. Without it, it
#   # builds through scripts/run-stack.sh: on the stack's bastion, or on this machine with Docker or
#   # Finch, where an Arm machine (Apple silicon) cross-builds for --platform, linux/amd64 by
#   # default, through emulation.
#   ./scripts/build-images.sh --root terraform/open-source
#
#   # Given the URL map instead of a root, always on this machine:
#   terraform -chdir=terraform/open-source output -json ecr_repository_urls > urls.json
#   ./scripts/build-images.sh --urls urls.json
#
# WHY THIS EXISTS. Every Agent names an image, and the images are built in your account. Built by
# hand, one docker command per repository, the architecture, the build context and the
# reasoning-direct build argument are each a way to get it wrong. Each of those is encoded below.
#
# WHAT IS BUILT. One image per repository in ecr_repository_urls that has a source here:
#
#   agents/reasoning         agents/reference, MODEL_ROUTE=gateway
#   agents/reasoning-direct  agents/reference, MODEL_ROUTE=bedrock-direct
#   agents/execution         the reasoning image, retagged: the Agent gives it no network, not a build
#   agents/mcp-server        agents/mcp-server
#   agents/chat-ui           agents/chat-ui
#   agents/evals             agents/evals
#   agents/consent-receiver  agents/consent-receiver (oauth_consent / agentcore_consent)
#
# The context is agents/, not each directory: every Dockerfile COPYs common/. The repositories are
# IMMUTABLE: a tag already in ECR is skipped, so rerunning this after a component adds a repository
# builds only the new one. To rebuild an image, pass a new --tag and point the Agents and
# chatUi.imageTag at it.
#
# --root builds THE WORKING TREE YOU HAVE, wherever it builds, not whatever the bastion cloned.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG=v1
URLS=""
URLS_TMP=""
TF_ROOT=""
# The nodes' architecture, not this host's. EKS Auto Mode's default pool is x86_64, and an arm64 image
# there fails with 'exec format error' after a pull that succeeded. Set linux/arm64 only for Graviton
# pools.
PLATFORM=linux/amd64
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)     TAG="$2"; shift 2 ;;
    --urls)    URLS="$2"; shift 2 ;;
    --root)    TF_ROOT="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    -h|--help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$TF_ROOT" && -z "$URLS" ]]; then
  URLS_TMP="$(mktemp -d)"; URLS="$URLS_TMP/ecr-urls.json"
  trap 'rm -rf "$URLS_TMP"' EXIT
  terraform -chdir="$TF_ROOT" output -json ecr_repository_urls > "$URLS"
fi
[[ -n "$URLS" && -s "$URLS" ]] || { echo "--urls <file> or --root <terraform root> is required" >&2; exit 2; }

# --- in CodeBuild (enable_image_build, the default) -----------------------------
# The working tree goes to the stack's image-build bucket, one build runs this script there with
# Docker, natively for the project's architecture, and its log comes back here.
IMAGE_BUILD=null
[[ -n "$TF_ROOT" && -z "${RUN_STACK:-}" ]] && IMAGE_BUILD="$(terraform -chdir="$TF_ROOT" output -json image_build 2>/dev/null || echo null)"
if [[ "$IMAGE_BUILD" != null && -n "$IMAGE_BUILD" ]]; then
  ib() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$IMAGE_BUILD" "$1"; }
  PROJECT="$(ib project_name)"; BUCKET="$(ib source_bucket)"; LOGS="$(ib log_group)"
  REGION="$(python3 -c 'import json,sys; print(next(iter(json.load(open(sys.argv[1])).values())).split("/")[0].split(".")[3])' "$URLS")"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK" ${URLS_TMP:+"$URLS_TMP"}' EXIT
  REPO_ROOT="$ROOT"
  # shellcheck source=lib/stage-tree.sh
  . "$ROOT/scripts/lib/stage-tree.sh"
  cp "$URLS" "$WORK/ecr-urls.json"
  stage_tree "$WORK/tree" "$WORK/ecr-urls.json"
  (cd "$WORK/tree" && python3 -c 'import shutil,sys; shutil.make_archive(sys.argv[1], "zip", ".")' "$WORK/ctx")
  KEY="build-context/$(date -u +%Y%m%dT%H%M%SZ)-$$.zip"
  aws s3 cp --only-show-errors --region "$REGION" "$WORK/ctx.zip" "s3://$BUCKET/$KEY"
  trap 'aws s3 rm --only-show-errors --region "$REGION" "s3://$BUCKET/$KEY" || true; rm -rf "$WORK" ${URLS_TMP:+"$URLS_TMP"}' EXIT
  BID="$(aws codebuild start-build --region "$REGION" --project-name "$PROJECT" \
    --source-location-override "$BUCKET/$KEY" \
    --environment-variables-override "name=TAG,value=$TAG,type=PLAINTEXT" "name=PLATFORM,value=$PLATFORM,type=PLAINTEXT" \
    --query build.id --output text)"
  echo "building :$TAG in CodeBuild ($PROJECT, build $BID)"
  echo "  log: https://$REGION.console.aws.amazon.com/codesuite/codebuild/projects/$PROJECT/build/${BID//:/%3A}/log"
  last=""
  while true; do
    read -r STATUS PHASE <<<"$(aws codebuild batch-get-builds --region "$REGION" --ids "$BID" \
      --query 'builds[0].[buildStatus,currentPhase]' --output text 2>/dev/null || echo "IN_PROGRESS UNKNOWN")"
    [[ "$PHASE" != "$last" ]] && { echo "  $PHASE"; last="$PHASE"; }
    [[ "$STATUS" == IN_PROGRESS ]] || break
    sleep 10
  done
  # The build's own output: what build-images.sh printed inside it.
  STREAM="$(aws codebuild batch-get-builds --region "$REGION" --ids "$BID" --query 'builds[0].logs.streamName' --output text)"
  aws logs get-log-events --region "$REGION" --log-group-name "$LOGS" --log-stream-name "$STREAM" --start-from-head \
    --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' \
    | grep -E '^(===|pushed|digest|building|this host|    push|denied|ERROR|error|failed)' || true
  [[ "$STATUS" == SUCCEEDED ]] || { echo "the CodeBuild build ended $STATUS; the full log is at the link above" >&2; exit 1; }
  exit 0
fi

# --- through run-stack.sh (no image build) -------------------------------------
if [[ -n "$TF_ROOT" && -z "${RUN_STACK:-}" ]]; then
  # The same script with the URL map, where the stack's cluster is reachable; see scripts/run-stack.sh.
  "$ROOT/scripts/run-stack.sh" --root "$TF_ROOT" --file "$URLS" -- \
    ./scripts/build-images.sh --urls "$(basename "$URLS")" --tag "$TAG" --platform "$PLATFORM"
  exit $?
fi

# --- on the build host --------------------------------------------------------
URLS="$(cd "$(dirname "$URLS")" && pwd)/$(basename "$URLS")"   # absolute: the build runs from agents/
# docker, or Finch (the same CLI surface for build, tag, push, pull and login). DOCKER names another.
DOCKER="${DOCKER:-}"
if [[ -z "$DOCKER" ]]; then
  if command -v docker >/dev/null; then DOCKER=docker; elif command -v finch >/dev/null; then DOCKER=finch; fi
fi
[[ -n "$DOCKER" ]] && command -v "$DOCKER" >/dev/null || { echo "docker (or finch) is required" >&2; exit 2; }
docker() { command "$DOCKER" "$@"; }
# A build for another architecture than this host's goes through BuildKit's emulation (Docker Desktop
# ships it). Refuse up front when the daemon cannot, rather than after the first layer.
case "$(uname -m)" in x86_64|amd64) HOST_PLATFORM=linux/amd64 ;; arm64|aarch64) HOST_PLATFORM=linux/arm64 ;; *) HOST_PLATFORM="" ;; esac
if [[ "$PLATFORM" != "$HOST_PLATFORM" && "$DOCKER" == docker ]]; then
  docker buildx inspect 2>/dev/null | grep -q "$PLATFORM" || {
    echo "this host ($(uname -m)) cannot build $PLATFORM images: docker buildx lists no $PLATFORM platform." >&2
    echo "Docker Desktop builds it out of the box; elsewhere install QEMU binfmt, or build on a stack with a bastion." >&2
    exit 2; }
fi
[[ "$PLATFORM" == "$HOST_PLATFORM" ]] || echo "building $PLATFORM images on a $(uname -m) host, through emulation: expect several minutes per image"
systemctl is-active docker >/dev/null 2>&1 || systemctl start docker 2>/dev/null || true

url() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$URLS" "$1"; }
REG="$(python3 -c 'import json,sys; print(next(iter(json.load(open(sys.argv[1])).values())).split("/")[0])' "$URLS")"
REGION="$(echo "$REG" | cut -d. -f4)"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REG" >/dev/null

cd "$ROOT/apps"
built=(); skipped=()
# ALREADY PUSHED IS DONE, NOT AN ERROR. The repositories are immutable, so a second push of a tag
# is refused -- and the usual reason to run this again is that a component just added a repository
# (enable_chat_ui adds agents/chat-ui, enable_evaluations agents/evals). Without this a rerun would
# fail on the first image the base had already pushed and never reach the new one.
pushed() {  # url -> 0 when url:$TAG is already in ECR
  local repo="${1#*/}"
  aws ecr describe-images --region "$REGION" --repository-name "$repo" --image-ids imageTag="$TAG" >/dev/null 2>&1
}
# A REPOSITORY THE LAST APPLY ADDED CAN REFUSE THE FIRST PUSH. The bastion's ecr-push policy is
# rewritten in the same apply that creates the repository, and a build started seconds later can get
# `denied: ... not authorized to perform: ecr:UploadLayerPart` while the policy already names the
# repository: IAM propagation. Retry that one error, nothing else.
push() {  # image-ref
  local out i
  # A PUSH FROM A WORKSTATION DROPS MID-LAYER often enough to matter (broken pipe, EOF, connection
  # reset on a VPN or a home uplink). The layers already uploaded stay in ECR, so a retry resumes
  # rather than restarting; retry those too.
  for i in 1 2 3 4 5 6; do
    out="$(docker push -q "$1" 2>&1)" && return 0
    if grep -q 'denied: .*not authorized' <<<"$out"; then
      echo "    push of $1 denied (IAM still propagating?), retry $i of 5 in 20 s" >&2
    elif grep -qiE 'broken pipe|EOF|connection reset|i/o timeout|TLS handshake timeout|use of closed network connection|500 Internal Server Error|502 Bad Gateway|503 Service Unavailable' <<<"$out"; then
      echo "    push of $1 dropped ($(tail -1 <<<"$out" | cut -c1-120)), retry $i of 5 in 20 s" >&2
    else
      echo "$out" >&2; return 1
    fi
    sleep 20
  done
  echo "$out" >&2; return 1
}
# THE IMAGES BUILD AT THE SAME TIME, not one after another: each is independent, and in sequence
# they take most of a CodeBuild run. Each build runs in the
# background and records its result in $RESULTS; the arrays are filled from it once all have ended,
# and any one that failed fails the run, with its own output.
RESULTS="$(mktemp -d)"
build() {  # repository dockerfile-dir [build-arg]
  local u out; u="$(url "$1")"
  [[ -n "$u" ]] || return 0
  local key="${1//\//_}"
  if pushed "$u"; then echo "=== $1:$TAG already in ECR, skipped"; echo "skipped $1" > "$RESULTS/$key"; return 0; fi
  echo "=== $1:$TAG from $2/Dockerfile ${3:-}"
  if out="$(docker build -q --platform "$PLATFORM" -f "$2/Dockerfile" ${3:+--build-arg "$3"} -t "$u:$TAG" . 2>&1)" \
     && out="$(push "$u:$TAG" 2>&1)"; then
    echo "built $1" > "$RESULTS/$key"
  else
    { echo "failed $1"; printf '%s\n' "$out"; } > "$RESULTS/$key"
  fi
}
build agents/reasoning        reference  MODEL_ROUTE=gateway &
build agents/reasoning-direct reference  MODEL_ROUTE=bedrock-direct &
build agents/mcp-server       mcp-server &
build agents/chat-ui          chat-ui &
build agents/evals            evals &
build agents/consent-receiver consent-receiver &
wait
for r in agents/reasoning agents/reasoning-direct agents/mcp-server agents/chat-ui agents/evals agents/consent-receiver; do
  f="$RESULTS/${r//\//_}"; [[ -f "$f" ]] || continue
  case "$(head -1 "$f")" in
    "built $r")   built+=("$r") ;;
    "skipped $r") skipped+=("$r") ;;
    *) echo "the build of $r failed:" >&2; tail -n +2 "$f" | tail -20 >&2; rm -rf "$RESULTS"; exit 1 ;;
  esac
done
rm -rf "$RESULTS"
# The execution tier's image is the reasoning image retagged. The base has no agents/reasoning (it
# is the gateway's), so there the source is agents/reasoning-direct; without it the base would leave
# agents/execution empty.
EXEC_SRC=agents/reasoning
[[ -n "$(url agents/reasoning)" ]] || EXEC_SRC=agents/reasoning-direct
if [[ -n "$(url agents/execution)" && -n "$(url "$EXEC_SRC")" ]]; then
  if pushed "$(url agents/execution)"; then
    skipped+=(agents/execution)
  else
    # The source image may have been skipped above, so it is not necessarily local.
    docker image inspect "$(url "$EXEC_SRC"):$TAG" >/dev/null 2>&1 || docker pull -q --platform "$PLATFORM" "$(url "$EXEC_SRC"):$TAG" >/dev/null
    docker tag "$(url "$EXEC_SRC"):$TAG" "$(url agents/execution):$TAG"
    push "$(url agents/execution):$TAG" >/dev/null
    built+=(agents/execution)
  fi
fi
echo "pushed :$TAG for ${built[*]:-nothing new}${skipped[*]:+; already in ECR: ${skipped[*]}}"
# The digest of each tag, the immutable name an Agent or a release record can pin.
for r in ${built[@]+"${built[@]}"} ${skipped[@]+"${skipped[@]}"}; do
  d="$(aws ecr describe-images --region "$REGION" --repository-name "$(url "$r" | cut -d/ -f2-)" \
    --image-ids imageTag="$TAG" --query 'imageDetails[0].imageDigest' --output text 2>/dev/null || true)"
  echo "digest $r:$TAG ${d:-unknown}"
done
