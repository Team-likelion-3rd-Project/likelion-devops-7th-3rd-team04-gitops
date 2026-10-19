#!/usr/bin/env bash
# PR 검증 (GitHub Actions validate.yml 이 실행 — 로컬에서도 같은 명령으로 실행 가능)
#   1) 앱 정의(envs/prod/*/chart.yaml) 형식 — type 별 필수 값, git 차트는 커밋 SHA 고정
#   2) 이미지 태그가 커밋 SHA 형식인지 (latest · 브랜치 이름 금지)
#   3) 앱마다 배포 agent 와 같은 차트 · values 로 렌더링 (helm template)
#   4) 렌더링 결과 Kubernetes 스키마 검증 (kubeconform)
# enabled: false 인 앱은 1) 의 형식만 보고 2) – 4) 에서 뺀다.
# 필요한 도구: git, yq(v4), helm(v3), docker
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="$ROOT/envs/prod"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

K8S_VERSION="${K8S_VERSION:-1.33.0}"          # 운영 클러스터 kube_version(1.33) 과 맞춤
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
      [[ "$(field "$dir" '.version // ""')" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || fail "$app: version 은 고정 버전이어야 합니다"
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

echo "== 3) helm template"
mkdir -p "$WORK/rendered"
for dir in "${APPS[@]}"; do
  enabled "$dir" || continue
  app="$(basename "$dir")"
  values=()
  [[ -f "$dir/values.yaml" ]] && values=(-f "$dir/values.yaml")
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

echo "== 4) kubeconform (Kubernetes $K8S_VERSION)"
# CRD 리소스(Traefik IngressRoute 등)는 스키마가 없어 건너뜀
docker run --rm -v "$WORK/rendered:/work:ro" "$KUBECONFORM_IMAGE" \
  -strict -summary -ignore-missing-schemas \
  -kubernetes-version "$K8S_VERSION" /work

echo "✅ 검증 통과"
