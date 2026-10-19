# PR 제목: `chore(prod): <대상> → <요약>`  (예: `chore(prod): backend → a1b2c3d`)

## 변경 대상

- [ ] backend 이미지 태그 (`envs/prod/backend/values.yaml` 의 `global.imageTag`)
- [ ] backend 차트 고정 (`envs/prod/backend/chart.yaml` 의 `revision`)
- [ ] backend 설정 (`envs/prod/backend/values.yaml` 의 그 외 값)
- [ ] 결제 서버 (`envs/prod/payment/values.yaml`)
- [ ] 클러스터 서비스 (`envs/prod/traefik`, `envs/prod/whoami` 등 — 원본: 모노레포 `infra/gitops/prod`)
- [ ] 앱 추가 · 삭제 · 순서 (`envs/prod/*/chart.yaml`) — 폴더를 지워도 릴리스는 삭제되지 않음 (`helm uninstall` 필요)
- [ ] 레포 규칙 · 검증 (`.github/`, `scripts/`)

## 무엇을 · 왜

<!-- 모노레포 커밋 / PR 링크, GitLab 파이프라인 링크 -->

-

## 배포 순서 확인

- [ ] 결제 쪽 계약(payment.proto · SQS 메시지 · 결제 마이그레이션)이 바뀌는 배포라면 **결제 서버를 먼저** 반영합니다
- [ ] 메인 DB 마이그레이션이 포함된 경우, 이전 버전 앱과 함께 동작 가능한 변경인지 확인했습니다 (롤백 대비)

## 롤백 방법

<!-- 보통은 "이 PR 을 revert 하는 PR". 되돌릴 수 없는 마이그레이션이 있으면 적어 주세요 -->

- 이 PR revert

## 체크리스트

- [ ] 비밀값(비밀번호 · 키 · 토큰)이 없습니다 — 이 레포는 public 입니다
- [ ] `validate` 체크가 통과했습니다
