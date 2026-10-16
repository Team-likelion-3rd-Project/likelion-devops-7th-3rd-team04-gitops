#!/usr/bin/env bash
# PR 검증 (GitHub Actions validate.yml 이 실행 — 로컬에서도 같은 명령으로 실행 가능)
#   1) 차트 고정값(chart.yaml revision)이 커밋 SHA 인지
#   2) 이미지 태그가 커밋 SHA 형식인지 (latest · 브랜치 이름 금지)
#   3) 고정된 모노레포 커밋의 차트로 prod values 를 렌더링 (helm template)
#   4) 렌더링 결과 Kubernetes 스키마 검증 (kubeconform)
# 필요한 도구: git, yq(v4), helm(v3), docker
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="$ROOT/envs/prod"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

K8S_VERSION="${K8S_VERSION:-1.33.0}"          # EKS 버전 확정 후 맞춤
KUBECONFORM_IMAGE="ghcr.io/yannh/kubeconform:v0.6.7"

fail() { echo "❌ $*" >&2; exit 1; }

echo "== 1) 차트 고정값"
CHART_REPO="$(yq '.repo' "$ENV_DIR/backend/chart.yaml")"
CHART_PATH="$(yq '.path' "$ENV_DIR/backend/chart.yaml")"
CHART_REV="$(yq '.revision' "$ENV_DIR/backend/chart.yaml")"
[[ "$CHART_REV" =~ ^[0-9a-f]{40}$ ]] || fail "chart.yaml revision 은 커밋 SHA(40자)여야 합니다: $CHART_REV"
echo "OK $CHART_REV"

echo "== 2) 이미지 태그 형식"
for pair in "backend/values.yaml:.global.imageTag" "payment/values.yaml:.image.imageTag"; do
  file="${pair%%:*}"
  expr="${pair#*:}"
  tag="$(yq "$expr" "$ENV_DIR/$file")"
  [[ "$tag" =~ ^[0-9a-f]{7,40}$ ]] || fail "$file $expr 는 커밋 SHA 여야 합니다 (latest · 브랜치 이름 금지): $tag"
  echo "OK $file → $tag"
done

echo "== 3) helm template (모노레포 $CHART_REV 의 $CHART_PATH)"
git init -q "$WORK/mono"
git -C "$WORK/mono" remote add origin "$CHART_REPO"
git -C "$WORK/mono" fetch -q --depth 1 origin "$CHART_REV" || fail "모노레포에서 커밋 $CHART_REV 를 찾을 수 없습니다"
git -C "$WORK/mono" checkout -q FETCH_HEAD
helm template backend "$WORK/mono/$CHART_PATH" -n backend \
  -f "$ENV_DIR/backend/values.yaml" > "$WORK/rendered.yaml"
echo "OK $(grep -c '^kind:' "$WORK/rendered.yaml") 개 리소스"

echo "== 4) kubeconform (Kubernetes $K8S_VERSION)"
docker run --rm -v "$WORK:/work:ro" "$KUBECONFORM_IMAGE" \
  -strict -summary -ignore-missing-schemas \
  -kubernetes-version "$K8S_VERSION" /work/rendered.yaml

echo "✅ 검증 통과"
