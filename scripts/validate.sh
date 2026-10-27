#!/usr/bin/env bash
# PR 검증 (GitHub Actions validate.yml 이 실행 — 로컬에서도 같은 명령으로 실행 가능)
#   1) 앱 정의(envs/prod/*/chart.yaml) 형식 — type 별 필수 값, git 차트는 커밋 SHA 고정
#   2) 이미지 태그가 커밋 SHA 형식인지 (latest · 브랜치 이름 금지)
#   2-1) 이미지 태그 · backend chart revision · 프론트 version 이 모노레포 main 이력의 커밋인지 (리뷰를 거쳐 main 에 들어간 코드만 배포)
#        REQUIRE_MAIN_HISTORY=false(구축 기간, 첫 릴리스 전)면 main 밖 SHA 는 경고만. 로컬 기본값은 true
#   2-3) 프론트 values (version 40자 SHA, build 는 VITE_* 키만) — envs/prod/frontend 가 없으면(첫 프론트 릴리스 전) 건너뜀
#   3) 앱마다 ArgoCD 와 같은 차트 · values 로 렌더링 (helm template), 3-1) root 앱 차트 렌더링
#   4) 렌더링 결과 Kubernetes 스키마 검증 (kubeconform)
# enabled: false 인 앱은 1) 의 형식만 보고 2) – 4) 에서 뺀다.
# 필요한 도구: git, yq(v4), helm(v3), docker
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="$ROOT/envs/prod"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

K8S_VERSION="${K8S_VERSION:-1.35.0}"          # 운영 클러스터 kube_version(1.35, 모노레포 group_vars/aws.yml) 과 맞춤
KUBECONFORM_IMAGE="ghcr.io/yannh/kubeconform:v0.6.7"

fail() { echo "❌ $*" >&2; exit 1; }
field() { yq "$2" "$1/chart.yaml"; }
enabled() { [[ "$(field "$1" '.enabled')" != "false" ]]; }   # yq 의 // 는 false 도 빈 값으로 봄

mapfile -t APPS < <(find "$ENV_DIR" -mindepth 2 -maxdepth 2 -name chart.yaml -exec dirname {} \; | sort)
[[ ${#APPS[@]} -gt 0 ]] || fail "envs/prod/*/chart.yaml 이 없습니다"

echo "== 1) 앱 정의"
declare -A RELEASES
for dir in "${APPS[@]}"; do
  app="$(basename "$dir")"
  type="$(field "$dir" '.type')"
  ns="$(field "$dir" '.namespace // ""')"
  rel="$(field "$dir" '.release // ""')"
  [[ -n "$ns" && -n "$rel" ]] || fail "$app: namespace · release 가 필요합니다"
  [[ "$(field "$dir" '.order // 50')" =~ ^[0-9]+$ ]] || fail "$app: order 는 정수여야 합니다"
  [[ -z "${RELEASES[$ns/$rel]:-}" ]] || fail "$app: ${RELEASES[$ns/$rel]} 와 릴리스($ns/$rel)가 겹칩니다"
  RELEASES[$ns/$rel]="$app"
  case "$type" in
    helm)
      [[ "$(field "$dir" '.chart // ""')" != "" ]] || fail "$app: chart 가 필요합니다"
      # cert-manager 처럼 차트 버전에 v 가 붙는 차트가 있다 (v 를 떼면 helm 이 가장 가까운 버전으로 대체)
      [[ "$(field "$dir" '.version // ""')" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]] || fail "$app: version 은 고정 버전이어야 합니다"
      [[ "$(field "$dir" '.chart')" == oci://* || "$(field "$dir" '.repo // ""')" != "" ]] || fail "$app: repo 가 필요합니다"
      ;;
    git)
      [[ "$(field "$dir" '.path // ""')" != "" ]] || fail "$app: path 가 필요합니다"
      if enabled "$dir"; then
        [[ "$(field "$dir" '.revision')" =~ ^[0-9a-f]{40}$ ]] ||
          fail "$app: revision 은 커밋 SHA(40자)여야 합니다 (브랜치 이름 금지): $(field "$dir" '.revision')"
      fi
      ;;
    local)
      [[ -f "$dir/$(field "$dir" '.path // "chart"')/Chart.yaml" ]] || fail "$app: 차트(path)가 없습니다"
      ;;
    *) fail "$app: type 은 helm · git · local 중 하나여야 합니다: $type" ;;
  esac
  enabled "$dir" && echo "OK $app ($type, $ns/$rel)" || echo "OK $app (enabled: false — 렌더링 제외)"
done

echo "== 2) 이미지 태그 형식"
for pair in "backend/values.yaml:.global.imageTag" "payment/values.yaml:.image.imageTag"; do
  file="${pair%%:*}"
  expr="${pair#*:}"
  app_dir="$ENV_DIR/$(dirname "$file")"
  if [[ -f "$app_dir/chart.yaml" ]] && ! enabled "$app_dir"; then
    echo "건너뜀 $file (enabled: false)"
    continue
  fi
  tag="$(yq "$expr" "$ENV_DIR/$file")"
  [[ "$tag" =~ ^[0-9a-f]{7,40}$ ]] || fail "$file $expr 는 커밋 SHA 여야 합니다 (latest · 브랜치 이름 금지): $tag"
  echo "OK $file → $tag"
done

# 프론트는 앱 정의가 아니다 (ArgoCD 가 읽지 않고 sync-frontend-version 이 CloudFront KeyValueStore 에 씀)
frontend_values="$ENV_DIR/frontend/values.yaml"

echo "== 2-1) 모노레포 main 이력"
# validate.yml 의 env. 첫 릴리스(rc.1) gitops PR 이 merge 된 뒤 true 로 바꾼다 (그 전 값은 develop 커밋)
REQUIRE_MAIN_HISTORY="${REQUIRE_MAIN_HISTORY:-true}"
backend_def="$ENV_DIR/backend/chart.yaml"
if [[ -f "$backend_def" ]] && enabled "$ENV_DIR/backend"; then
  mono="$WORK/monorepo"
  git init -q "$mono"
  # 커밋 이력만 받는다 (파일 내용 없음)
  git -C "$mono" fetch -q --filter=blob:none --no-tags "$(field "$ENV_DIR/backend" '.repo')" \
    +refs/heads/main:refs/remotes/origin/main +refs/heads/develop:refs/remotes/origin/develop ||
    fail "모노레포 main · develop 이력을 가져오지 못했습니다"
  checks=(
    "backend/chart.yaml .revision"
    "backend/values.yaml .global.imageTag"
    "payment/values.yaml .image.imageTag"
  )
  [[ -f "$frontend_values" ]] && checks+=("frontend/values.yaml .version")
  for c in "${checks[@]}"; do
    file="${c% *}"
    expr="${c#* }"
    sha="$(yq "$expr" "$ENV_DIR/$file")"
    # 결제 서버 첫 릴리스 전 자리표시(0) — 구축 기간에만 허용
    if [[ "$sha" =~ ^0+$ ]]; then
      [[ "$REQUIRE_MAIN_HISTORY" == "true" ]] && fail "$file $expr 가 자리표시($sha)입니다 — 릴리스 SHA 가 필요합니다"
      echo "경고 $file $expr → 자리표시 $sha (구축 기간 예외)"
      continue
    fi
    if full="$(git -C "$mono" rev-parse -q --verify "$sha^{commit}" 2>/dev/null)" &&
      git -C "$mono" merge-base --is-ancestor "$full" origin/main; then
      echo "OK $file $expr → ${full:0:8} (main)"
      continue
    fi
    if [[ -n "$full" ]] && git -C "$mono" merge-base --is-ancestor "$full" origin/develop; then
      where="develop 커밋"
    else
      where="main · develop 어디에도 없는 커밋 (squash 된 작업 브랜치 등)"
    fi
    [[ "$REQUIRE_MAIN_HISTORY" == "true" ]] &&
      fail "$file $expr 의 $sha 는 모노레포 main 이력에 없습니다 — $where (릴리스 PR 로 main 에 들어간 커밋만 배포)"
    echo "경고 $file $expr → $sha 는 $where 입니다 (구축 기간 예외, REQUIRE_MAIN_HISTORY=false)"
  done
else
  echo "건너뜀 (backend enabled: false)"
fi

echo "== 2-2) 결제 서버 env"
# 결제 서버 pull agent(모노레포 60-payment-app templates/payment-deploy.sh)와 같은 규칙. merge 전에 막는다
payment_values="$ENV_DIR/payment/values.yaml"
reserved='^(PAYMENT_DB_.*|TOSS_SECRET_KEY|SQS_.*|PAYMENT_RESULT_QUEUE_URL|PG_MOCK_SERVICE_URL|AWS_.*|HEALTH_PORT)$'
while IFS= read -r key; do
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || fail "payment/values.yaml env 키는 대문자 · 숫자 · _ 만 씁니다: $key"
  [[ "$key" =~ $reserved ]] && fail "payment/values.yaml env.$key 는 인프라(Terraform · Secrets Manager)가 넣는 값이라 쓸 수 없습니다"
done < <(yq '(.env // {}) | keys | .[]' "$payment_values")
[[ "$(yq '[(.env // {}) | .[] | select(tag == "!!map" or tag == "!!seq" or (tostring | test("\n")))] | length' "$payment_values")" == "0" ]] ||
  fail "payment/values.yaml env 값은 한 줄 문자열이어야 합니다"
provider="$(yq '.env.PAYMENT_PROVIDER // ""' "$payment_values")"
[[ "$provider" == "TOSS" || "$provider" == "MOCK" ]] || fail "payment/values.yaml env.PAYMENT_PROVIDER 는 TOSS 또는 MOCK 이어야 합니다: $provider"
echo "OK payment env ($(yq '(.env // {}) | keys | join(" ")' "$payment_values"))"

echo "== 2-3) 프론트 values"
if [[ -f "$frontend_values" ]]; then
  # CloudFront Function 이 40자 SHA 만 경로로 쓴다 (짧은 SHA 는 503). 자리표시(0) 는 2-1 이 판단
  version="$(yq '.version' "$frontend_values")"
  [[ "$version" =~ ^[0-9a-f]{40}$ ]] || fail "frontend/values.yaml version 은 커밋 SHA(40자)여야 합니다: $version"
  # build 는 빌드에 들어간 값의 기록 — 공개 Vite 변수만 (모노레포 release:frontend 와 같은 규칙)
  while IFS= read -r key; do
    [[ "$key" =~ ^VITE_[A-Z0-9_]+$ ]] || fail "frontend/values.yaml build 에는 VITE_* 키만 둡니다: $key"
  done < <(yq '(.build // {}) | keys | .[]' "$frontend_values")
  echo "OK frontend version → ${version:0:8}"
else
  echo "건너뜀 (envs/prod/frontend 없음 — 첫 프론트 릴리스 전)"
fi

echo "== 3) helm template"
mkdir -p "$WORK/rendered"
# clusterValues: true 인 앱은 ArgoCD root 앱이 클러스터 값(계정 ID 등)을 더 넘긴다. 검증은 더미 값으로 한다.
# 숫자로 읽히지 않도록 문자열로 쓴다 (root 앱도 JSON 문자열로 넘김)
cat > "$WORK/cluster-values.yaml" <<'EOF'
{"global": {"awsAccountId": "000000000000"}}
EOF
for dir in "${APPS[@]}"; do
  enabled "$dir" || continue
  app="$(basename "$dir")"
  values=()
  [[ -f "$dir/values.yaml" ]] && values=(-f "$dir/values.yaml")
  [[ "$(field "$dir" '.clusterValues')" == "true" ]] && values+=(-f "$WORK/cluster-values.yaml")
  case "$(field "$dir" '.type')" in
    helm)
      chart="$(field "$dir" '.chart')"
      src=("$chart" --version "$(field "$dir" '.version')")
      [[ "$chart" == oci://* ]] || src+=(--repo "$(field "$dir" '.repo')")
      ;;
    git)
      rev="$(field "$dir" '.revision')"
      git init -q "$WORK/src-$app"
      git -C "$WORK/src-$app" fetch -q --depth 1 "$(field "$dir" '.repo')" "$rev" || fail "$app: 커밋 $rev 를 찾을 수 없습니다"
      git -C "$WORK/src-$app" checkout -q FETCH_HEAD
      src=("$WORK/src-$app/$(field "$dir" '.path')")
      ;;
    local)
      src=("$dir/$(field "$dir" '.path // "chart"')")
      ;;
  esac
  helm template "$(field "$dir" '.release')" "${src[@]}" -n "$(field "$dir" '.namespace')" \
    "${values[@]}" > "$WORK/rendered/$app.yaml"
  echo "OK $app $(grep -c '^kind:' "$WORK/rendered/$app.yaml") 개 리소스"
done

echo "== 3-1) root 앱 차트 (ArgoCD prod-apps)"
# root 차트(envs/prod/Chart.yaml · templates/)가 앱 정의를 Application 으로 바꾸는지. 클러스터 값 · 커밋은 더미
if [[ -f "$ENV_DIR/Chart.yaml" ]]; then
  helm template prod-apps "$ENV_DIR" -n argocd --set-string gitopsRevision=0000000000000000000000000000000000000000 \
    --set-json "clusterValues=$(cat "$WORK/cluster-values.yaml")" > "$WORK/rendered/_root.yaml"
  want=0
  for dir in "${APPS[@]}"; do enabled "$dir" && want=$((want + 1)); done
  got="$(yq ea '[select(.kind == "Application")] | length' "$WORK/rendered/_root.yaml")"
  [[ "$got" == "$want" ]] || fail "root 앱 차트의 Application $got 개 ≠ 배포 대상 앱 $want 개"
  echo "OK root Application $got 개 $(yq ea '[select(.kind == "Application") | .metadata.annotations["argocd.argoproj.io/sync-wave"] + ":" + .metadata.name] | join(" ")' "$WORK/rendered/_root.yaml")"
else
  echo "건너뜀 (envs/prod/Chart.yaml 없음 — ArgoCD 전환 전)"
fi

echo "== 4) kubeconform (Kubernetes $K8S_VERSION)"
# CRD 리소스(Traefik IngressRoute 등)는 스키마가 없어 건너뜀
docker run --rm -v "$WORK/rendered:/work:ro" "$KUBECONFORM_IMAGE" \
  -strict -summary -ignore-missing-schemas \
  -kubernetes-version "$K8S_VERSION" /work

echo "✅ 검증 통과"
