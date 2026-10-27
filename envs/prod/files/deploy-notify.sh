#!/usr/bin/env bash
# 배포 결과 알림 — root Application(prod-apps) 의 결과를 10-global 배포 토픽(→ AWS Chatbot → Slack #deploy)에 발행한다
# (templates/deploy-notify.yaml). 메시지 형식은 이전 배포 agent(gitops-sync)와 같다.
#   RESULT=success  PostSync hook Job: 모든 하위 앱이 GITOPS_REVISION 으로 Synced · Healthy
#   RESULT=failed   CronJob deploy-notify-watch(1분): root sync 가 Failed · Error 로 끝났으면 발행. 자동 롤백은 없다
#                   (SyncFail hook 은 시간 제한 · 사람의 종료로 끝난 sync 에서 실행되지 않아 쓰지 않는다)
#
# 클러스터 생성 후 첫 sync(root 성공 이력 없음, 매일 재생성)의 성공과 같은 커밋 재sync 의 성공은 발행하지 않는다.
# 실패는 첫 sync 여도 서비스가 뜨지 않은 것이라 발행하고, 같은 sync 의 실패는 상태 ConfigMap 으로 한 번만 발행한다.
# 발행 실패는 배포 결과에 영향을 주지 않도록 항상 0 으로 끝난다
set -uo pipefail

: "${RESULT:?}" "${ROOT_APP:?}" "${ARGOCD_NAMESPACE:?}" "${GITOPS_REVISION:?}" "${DEPLOY_TOPIC_ARN:?}"
STATE_CM=deploy-notify-state
log() { echo "[deploy-notify] $*" >&2; }

root="$(kubectl -n "$ARGOCD_NAMESPACE" get application "$ROOT_APP" -o json 2>/dev/null)" ||
  { log "root Application 조회 실패 — 발행하지 않음"; exit 0; }
# history 는 성공한 sync 만 남는다 (진행 중인 sync 는 끝난 뒤에 추가됨)
previous="$(jq -r '.status.history // [] | last | .revision // ""' <<<"$root")"
target="$GITOPS_REVISION"

if [[ "$RESULT" == "success" ]]; then
  [[ -n "$previous" ]] || { log "클러스터 생성 후 첫 sync 성공 — 발행하지 않음"; exit 0; }
  [[ "$previous" != "$target" ]] || { log "같은 커밋 재sync — 발행하지 않음"; exit 0; }
  title=":white_check_mark: 메인 클러스터 배포 성공"
  # busybox date 는 ISO 8601(Z) 을 못 읽을 수 있어 jq 로 계산
  seconds="$(jq -r '.status.operationState.startedAt // empty | now - fromdateiso8601 | floor' <<<"$root" 2>/dev/null)"
  failed_apps=""
  message=""
else
  phase="$(jq -r '.status.operationState.phase // ""' <<<"$root")"
  [[ "$phase" == "Failed" || "$phase" == "Error" ]] || exit 0
  # 끝난 sync 하나를 시작 시각 + 커밋으로 식별 (같은 커밋을 다시 sync 해 실패해도 시작 시각이 다름)
  target="$(jq -r '.status.operationState.syncResult.revision // .status.operationState.operation.sync.revision // ""' <<<"$root")"
  key="$(jq -r '.status.operationState.startedAt // ""' <<<"$root")/$target"
  notified="$(kubectl -n "$ARGOCD_NAMESPACE" get configmap "$STATE_CM" -o jsonpath='{.data.failed}' 2>/dev/null || true)"
  [[ "$key" != "$notified" ]] || exit 0
  # 발행 전에 기록한다 — 발행이 실패해도 매 분 같은 실패를 다시 보내지 않게
  kubectl -n "$ARGOCD_NAMESPACE" create configmap "$STATE_CM" --from-literal=failed="$key" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null ||
    { log "상태 기록 실패 — 중복 발행을 막기 위해 발행하지 않음 ($key)"; exit 0; }
  title=":x: 메인 클러스터 배포 실패 (자동 롤백 없음)"
  seconds="$(jq -r '.status.operationState | select(.startedAt and .finishedAt)
    | (.finishedAt | fromdateiso8601) - (.startedAt | fromdateiso8601)' <<<"$root" 2>/dev/null)"
  # 이 커밋으로 Synced · Healthy 가 되지 못한 하위 앱과 그 사유
  failed_apps="$(kubectl -n "$ARGOCD_NAMESPACE" get applications -l "team04.io/root-app=$ROOT_APP" -o json 2>/dev/null |
    jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
      | "\(.metadata.name)(\(.status.sync.status // "?")/\(.status.health.status // "?"))"' | paste -sd ' ' -)"
  message="$(jq -r '.status.operationState.message // ""' <<<"$root" | tail -c 300)"
fi
seconds="${seconds:-?}"

aws sns publish --topic-arn "$DEPLOY_TOPIC_ARN" --message "$(
  jq -cn --arg title "$title" --arg result "$RESULT" --arg release "${RELEASE:-?}" --arg target "$target" \
    --arg previous "$previous" --arg seconds "$seconds" --arg apps "${APPS:-}" \
    --arg failed_apps "$failed_apps" --arg message "$message" '
    {version: "1.0", source: "custom",
     content: {
       textType: "client-markdown",
       title: $title,
       description: ("*릴리스* `\($release[0:8])`\n*gitops* `\($target[0:7])`"
                     + (if $previous == "" then " (클러스터 생성 후 첫 sync)" else " (이전 `\($previous[0:7])`)" end)
                     + "\n*소요* \($seconds)초"
                     + (if $result == "success" then "\n*앱* \($apps)"
                        else "\n*실패* \(if $failed_apps == "" then "root" else $failed_apps end) — 수정 커밋 또는 gitops revert PR 로 복구"
                             + (if $message == "" then "" else "\n```\($message)```" end) end))},
     metadata: {summary: $title, eventType: ("main_deploy_" + $result),
                additionalContext: {release: $release, gitops: $target}}}')" \
  >/dev/null && log "발행: $RESULT $target" || log "배포 알림 발행 실패 (배포 결과와 무관)"
exit 0
