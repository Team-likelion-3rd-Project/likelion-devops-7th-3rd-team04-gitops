# likelion-devops-7th-3rd-team04-gitops

호텔 예약 서비스 **prod(AWS) 배포 상태**를 담는 레포입니다. 여기 있는 값이 곧 prod 에 배포되어야 할 상태이고, **모든 변경은 PR 로만** 들어옵니다 (변경 이력 = PR 이력).

- 코드 · Helm 차트: [likelion-devops-7th-3rd-team04](https://github.com/Team-likelion-3rd-Project/likelion-devops-7th-3rd-team04) (모노레포)
- dev(온프레미스) 배포 상태는 이 레포가 아니라 온프레미스 GitLab `team04/infra/backend-gitops` 에 있습니다.

```
envs/prod/
├── backend/
│   ├── chart.yaml     # 모노레포 차트 위치 + 고정 커밋 SHA (브랜치 금지)
│   └── values.yaml    # EKS backend Helm values (이미지 태그, ECR, ALB Ingress, replicas ...)
└── payment/
    └── values.yaml    # 결제 서버(결제 VPC, EKS 밖) 이미지 태그 · 비밀 아닌 설정
scripts/validate.sh    # PR 검증 (로컬에서도 실행)
.github/               # CODEOWNERS, PR 템플릿, validate workflow
```

## 규칙

1. **main 에 직접 push 하지 않습니다.** 보호 규칙(ruleset)이 막습니다 — 관리자도 예외 없음.
2. **비밀값은 넣지 않습니다.** public 레포이고, 한 번 커밋되면 이력에서 지울 수 없습니다. 비밀은 AWS Secrets Manager 에 두고 클러스터(External Secrets) · 결제 서버가 직접 읽습니다. PR 의 gitleaks 검사가 1차로 막습니다.
3. **차트는 커밋 SHA 로 고정합니다** (`envs/prod/backend/chart.yaml`). 차트 변경도 PR 로 올라옵니다.
4. **이미지 태그는 커밋 SHA** 입니다 (`latest` · 브랜치 이름 금지, ECR 도 IMMUTABLE).
5. 결제 쪽 계약(payment.proto · SQS 메시지 · 결제 마이그레이션)이 바뀌면 **결제 서버 PR 을 먼저** merge · 반영합니다.

## 변경 흐름

```
모노레포 main merge ─▶ GitLab 미러 ─▶ GitLab main 파이프라인: 빌드 → ECR push
                                     └▶ 이 레포에 PR 자동 생성 "chore(prod): backend/payment → <sha>"
리뷰(CODEOWNERS) · validate 통과 ─▶ merge ─▶ 배포 (지금: 배포 도구가 main 을 읽음 / 이후: ArgoCD sync)
롤백 ─▶ 해당 PR 을 revert 하는 PR
```

- 자동 PR 은 **만들기까지만** 합니다. merge 는 사람이 합니다.
- GitLab 이 쓰는 토큰은 **이 레포에만** Contents · Pull requests 쓰기 권한이 있는 fine-grained PAT(또는 GitHub App)입니다. GitLab CI 변수(masked, protected)로 둡니다.
- 설정값(replicas, 리소스, 도메인 등)은 사람이 직접 PR 을 엽니다.

## 레포 설정 (관리자 1회)

**Settings → General**: 기본 브랜치 `main` · Allow merge commits 끄고 Squash merge 만 (이력 한 줄) · Automatically delete head branches 켜기

**Settings → Rules → Rulesets → New branch ruleset** (`main`, Enforcement: Active)
| 규칙 | 값 |
|---|---|
| Bypass list | **비움** |
| Restrict deletions / Block force pushes | 켜기 |
| Require linear history | 켜기 |
| Require a pull request before merging | **Required approvals: 1** · Dismiss stale approvals · **Require review from Code Owners** · Require conversation resolution |
| Require status checks to pass | `validate` (Require branches to be up to date 켜기) |

- 리뷰 규칙: 팀원 4명 전원이 CODEOWNERS(`*`)라 누구나 리뷰할 수 있고, **PR 작성자를 제외한 1명의 승인**이 있어야 merge 됩니다 (GitHub 는 작성자 본인 승인을 세지 않음).
- PR 을 열면 4명 모두 리뷰어로 자동 지정됩니다.

**Settings → Collaborators and teams**: 팀원 4명(`rbsxo135`, `wkdtpgns5016`, `kimjhn4188-ctrl`, `jack7051105`) 모두 **Write 이상** — CODEOWNERS 는 쓰기 권한이 있는 사람만 소유자로 인정됩니다. 관리자(Admin)는 최소 인원

## ArgoCD 도입 전 / 후

지금은 ArgoCD 도입 전입니다 (dev 와 같은 단계). 이 레포의 **값 형식은 도입 후에도 그대로** 쓰도록 맞춰 두었습니다.

**도입 전 (지금)**
- 배포는 별도 배포 도구(파이프라인 job / 수동 helm)가 `main` 의 `envs/prod/backend` 를 읽어 `helm upgrade --install backend <chart.yaml 의 차트@revision> -f values.yaml` 로 합니다.
- 결제 서버는 `envs/prod/payment/values.yaml` 의 태그로 결제 VPC 의 서버를 갱신합니다 (방식은 Terraform 60-payment-app 과 함께 확정).

**도입 시 바꿀 것**
1. `argocd/root.yaml`(app-of-apps)과 `argocd/apps/backend.yaml` 추가 — multi-source:
   - source 1: 모노레포 `backend-deploy/charts/backend`, `targetRevision` = `envs/prod/backend/chart.yaml` 의 `revision`
   - source 2: 이 레포 `main`, `ref: values` → `valueFiles: [$values/envs/prod/backend/values.yaml]`
   - `destination.namespace: backend`, `syncOptions: [CreateNamespace=false]`
   - HPA 를 켠 서비스는 `ignoreDifferences` 에 Deployment `/spec/replicas` (2nd 프로젝트에서 HPA 와 selfHeal 이 서로 되돌린 문제)
2. `chart.yaml` 의 `revision` 을 Application `targetRevision` 으로 옮기고 `chart.yaml` 삭제 (`validate.sh` 도 Application 에서 읽도록 수정)
3. 배포 도구의 helm 단계 제거 — 이후 배포 = PR merge → ArgoCD sync. 자동 PR 흐름은 그대로
4. ArgoCD 가 이 레포를 읽을 권한: public 이라 별도 자격증명 불필요
5. 결제 서버는 EKS 밖이라 ArgoCD 대상이 아님 — 태그 반영 방식(예: merge 시 GitHub Actions → SSM Parameter Store → 결제 서버가 읽음)은 그대로 유지

## 알려진 제약 / TODO

- `envs/prod/**` 의 `TODO` (계정 ID · 도메인 · PrivateLink 엔드포인트 · 큐 URL · 첫 배포 SHA)는 prod 인프라 구축 후 채웁니다. 그 전까지 `validate` 의 차트 고정 검사는 실패합니다 (`revision` 이 0 으로 채워져 있음).
- ECR 리포지토리(Terraform 11-registry)에 `main-migrations` · `payment-migrations` 가 아직 없습니다.
- Terraform 11-registry 의 SSM Parameter Store `image-tag/*` 는 "CI 가 갱신"하는 설계입니다 — 이 레포가 태그의 원본이 되므로, SSM 은 이 레포 merge 결과를 따라가도록(결제 서버용) 바꾸거나 정리합니다.
- payment-service 는 아직 booking-service 를 gRPC 로 직접 호출합니다. prod 는 결제 → 메인 경로가 없으므로(PrivateLink 는 메인 → 결제만) 백엔드 변경 전까지 `BOOKING_SERVICE_HOST` 는 미정입니다.
