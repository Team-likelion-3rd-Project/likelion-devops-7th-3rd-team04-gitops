# likelion-devops-7th-3rd-team04-gitops

호텔 예약 서비스 **prod(AWS) 배포 상태**를 담는 레포입니다. 여기 있는 값이 곧 prod 에 배포되어야 할 상태이고, **모든 변경은 PR 로만** 들어옵니다 (변경 이력 = PR 이력).

- 코드 · Helm 차트: [likelion-devops-7th-3rd-team04](https://github.com/Team-likelion-3rd-Project/likelion-devops-7th-3rd-team04) (모노레포)
- dev(온프레미스) 배포 상태는 이 레포가 아니라 온프레미스 GitLab `team04/infra/backend-gitops` 에 있습니다.

```
envs/prod/              # 원본: 모노레포 infra/gitops/prod (1:1)
├── traefik/            # Ingress Controller (워커 NodePort 30080)
│   ├── chart.yaml      # 앱 정의 — 차트 종류 · 위치 · 버전, namespace, release, order
│   └── values.yaml
├── cert-manager/       # pod-identity-webhook TLS 인증서
├── pod-identity-webhook/  # IRSA 주입 (ns/SA → Role 매핑, clusterValues)
├── whoami/             # 수직 경로 검증용 테스트 백엔드 (/whoami)
│   ├── chart.yaml
│   ├── values.yaml
│   └── chart/          # type: local 차트
├── external-secrets/   # External Secrets Operator
├── cluster-secret-store/  # ClusterSecretStore aws-secrets-manager (type: local)
├── backend/
│   ├── chart.yaml      # 모노레포 차트 위치 + 고정 커밋 SHA (브랜치 금지), 지금은 enabled: false
│   └── values.yaml     # backend Helm values (이미지 태그, ECR, Ingress, replicas ...)
└── payment/
    └── values.yaml     # 결제 서버(결제 VPC, 클러스터 밖) 이미지 태그 · 비밀 아닌 설정 — 앱 정의 아님
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
리뷰(CODEOWNERS) · validate 통과 ─▶ merge ─▶ 배포 (지금: 클러스터의 배포 agent 가 1분 안에 main 을 읽음 / 이후: ArgoCD sync)
롤백 ─▶ 해당 PR 을 revert 하는 PR
```

- 자동 PR 은 **만들기까지만** 합니다. merge 는 사람이 합니다.
- GitLab 이 쓰는 토큰은 **이 레포에만** Contents · Pull requests 쓰기 권한이 있는 fine-grained PAT(또는 GitHub App)입니다. GitLab CI 변수(masked, protected)로 둡니다.
- 설정값(replicas, 리소스, 도메인 등)은 모노레포 `infra/gitops/prod` 를 먼저 고칩니다. v1.0.0(2026-10-27) 전까지는 같은 내용으로 이 레포에 PR 을 직접 열고, 이후에는 모노레포 릴리스 PR 의 자동 PR 과 비상 경로만 씁니다.

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

**도입 전 (지금) — 배포 agent**
- 운영 Main 클러스터의 CronJob `gitops-sync`(1분)가 `main` 의 SHA 가 바뀌면 `envs/prod/*/chart.yaml` 을 `order` 순으로 `helm upgrade --install --atomic` 합니다. 설치 · 동작 · 운영 방법은 모노레포 [`infra/gitops/prod/README.md`](https://github.com/Team-likelion-3rd-Project/likelion-devops-7th-3rd-team04/blob/develop/infra/gitops/prod/README.md).
- 앱 정의 `chart.yaml`: `type`(`helm` · `git` · `local`), `repo` · `chart` · `version`(helm), `repo` · `path` · `revision`(git), `path`(local), `namespace`, `release`, `order`, `enabled`, `clusterValues`. `validate` 가 같은 형식으로 앱마다 렌더링합니다.
- **계정 ID 는 이 레포에 쓰지 않습니다.** `clusterValues: true` 인 앱은 agent 가 클러스터 값(`global.awsAccountId`)을 더 넘기므로 values 에서 `{{ .Values.global.awsAccountId }}` 로 씁니다 (차트가 템플릿을 지원하는 곳, 예: pod-identity-webhook 의 `RoleARN`). `validate` 는 더미 값으로 렌더링합니다.
- 실패한 SHA(렌더링 오류 · readiness 실패)는 `--atomic` 으로 이전 릴리스를 유지하고 다시 시도하지 않습니다 → **수정 PR 을 merge** 합니다. 차트 다운로드 같은 네트워크 실패는 매 분 재시도합니다.
- 배포 agent 는 이 레포 하나만 읽습니다(public, 자격 증명 없음). 그래서 main 보호 규칙이 곧 운영 배포 승인입니다.
- 결제 서버는 `envs/prod/payment/values.yaml` 의 태그로 결제 VPC 의 서버를 갱신합니다 (merge 후 GitHub Actions → SSM Parameter Store → 결제 서버 pull agent).

**도입 시 바꿀 것**
1. `argocd/root.yaml`(app-of-apps)과 앱 폴더마다 Application 추가 (`chart.yaml` 하나 = Application 하나, `order` → sync-wave). backend 는 multi-source:
   - source 1: 모노레포 `backend-deploy/charts/backend`, `targetRevision` = `envs/prod/backend/chart.yaml` 의 `revision`
   - source 2: 이 레포 `main`, `ref: values` → `valueFiles: [$values/envs/prod/backend/values.yaml]`
   - `destination.namespace: backend`, `syncOptions: [CreateNamespace=false]`
   - HPA 를 켠 서비스는 `ignoreDifferences` 에 Deployment `/spec/replicas` (2nd 프로젝트에서 HPA 와 selfHeal 이 서로 되돌린 문제)
2. `chart.yaml` 의 `revision` 을 Application `targetRevision` 으로 옮기고 `chart.yaml` 삭제 (`validate.sh` 도 Application 에서 읽도록 수정)
3. 배포 agent 제거 — 운영 클러스터 재생성 때 Ansible 이 agent 대신 ArgoCD 를 설치. 이후 배포 = PR merge → ArgoCD sync. 자동 PR 흐름은 그대로
4. ArgoCD 가 이 레포를 읽을 권한: public 이라 별도 자격증명 불필요
5. 결제 서버는 EKS 밖이라 ArgoCD 대상이 아님 — 태그 반영 방식(예: merge 시 GitHub Actions → SSM Parameter Store → 결제 서버가 읽음)은 그대로 유지

## 알려진 제약 / TODO

- `envs/prod/**` 의 `TODO` (계정 ID · 도메인 · PrivateLink 엔드포인트 · 큐 URL · 첫 배포 SHA)는 prod 인프라 구축 후 채웁니다. 그 전까지 backend 는 `enabled: false` 라 배포 agent · `validate` 렌더링 대상이 아닙니다 (`revision` 이 0 으로 채워져 있음, LDP-79 에서 `true`).
- ECR 리포지토리(Terraform 11-registry)에 `main-migrations` · `payment-migrations` 가 아직 없습니다.
- Terraform 11-registry 의 SSM Parameter Store `image-tag/*` 는 "CI 가 갱신"하는 설계입니다 — 이 레포가 태그의 원본이 되므로, SSM 은 이 레포 merge 결과를 따라가도록(결제 서버용) 바꾸거나 정리합니다.
- payment-service 는 아직 booking-service 를 gRPC 로 직접 호출합니다. prod 는 결제 → 메인 경로가 없으므로(PrivateLink 는 메인 → 결제만) 백엔드 변경 전까지 `BOOKING_SERVICE_HOST` 는 미정입니다.
