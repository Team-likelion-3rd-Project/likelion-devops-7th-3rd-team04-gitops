# likelion-devops-7th-3rd-team04-gitops

호텔 예약 서비스 **prod(AWS) 배포 상태**를 담는 레포입니다. 여기 있는 값이 곧 prod 에 배포되어야 할 상태이고, **모든 변경은 PR 로만** 들어옵니다 (변경 이력 = PR 이력).

- 코드 · Helm 차트: [likelion-devops-7th-3rd-team04](https://github.com/Team-likelion-3rd-Project/likelion-devops-7th-3rd-team04) (모노레포)
- dev(온프레미스) 배포 상태는 이 레포가 아니라 온프레미스 GitLab `team04/infra/backend-gitops` 에 있습니다.

```
envs/prod/              # 원본: 모노레포 infra/gitops/prod (1:1)
├── Chart.yaml · values.yaml · templates/ · files/   # ArgoCD root 앱 차트 — 앱 정의(chart.yaml) → Application, 배포 결과 알림
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
├── backend-secrets/    # backend Secret(ExternalSecret) · RDS CA ConfigMap (type: local)
├── backend/
│   ├── chart.yaml      # 모노레포 차트 위치 + 고정 커밋 SHA (브랜치 금지), clusterValues
│   └── values.yaml     # backend Helm values (이미지 태그, ECR, Ingress, replicas ...)
└── payment/
    └── values.yaml     # 결제 서버(결제 VPC, 클러스터 밖) 이미지 태그 · 비밀 아닌 설정 — 앱 정의 아님
scripts/validate.sh    # PR 검증 (로컬에서도 실행)
.github/               # CODEOWNERS, PR 템플릿, workflow (validate · sync-payment-tag)
```

## 규칙

1. **main 에 직접 push 하지 않습니다.** 보호 규칙(ruleset)이 막습니다 — 관리자도 예외 없음.
2. **비밀값은 넣지 않습니다.** public 레포이고, 한 번 커밋되면 이력에서 지울 수 없습니다. 비밀은 AWS Secrets Manager 에 두고 클러스터(External Secrets) · 결제 서버가 직접 읽습니다. PR 의 gitleaks 검사가 1차로 막습니다.
3. **차트는 커밋 SHA 로 고정합니다** (`envs/prod/backend/chart.yaml`). 차트 변경도 PR 로 올라옵니다.
4. **이미지 태그는 커밋 SHA** 입니다 (`latest` · 브랜치 이름 금지, ECR 도 IMMUTABLE). 릴리스 태그는 모노레포 **main 커밋 SHA 40자**이고 backend `chart.yaml` 의 `revision` 과 같은 값입니다.
   `validate` 가 태그 · revision 이 모노레포 main 이력에 있는지 확인하고, 없으면 거부합니다 (`validate.yml` 의 `REQUIRE_MAIN_HISTORY: "true"`, 첫 릴리스 v1.0.0-rc.1 부터).
5. 결제 쪽 계약(payment.proto · SQS 메시지 · 결제 마이그레이션)이 바뀌면 **결제 서버 PR 을 먼저** merge · 반영합니다.

## 변경 흐름

```
모노레포 릴리스 PR merge (develop · hotfix → main) ─▶ GitLab 미러 ─▶ GitLab main 파이프라인 (AWS Runner)
    ├▶ 이미지 10개 빌드 → ECR push (태그 = main 커밋 SHA)
    └▶ 이 레포에 PR 자동 생성 "chore(prod): backend · payment → <sha 8자>" (GitHub App, 브랜치 release/<sha>)
리뷰(CODEOWNERS) · validate 통과 ─▶ merge ─▶ 배포
    ├▶ 메인 클러스터: ArgoCD root 앱(prod-apps)이 3분 안에 main 을 읽어 sync → Slack #deploy 결과 알림
    └▶ 결제 서버: sync-payment-tag workflow 가 태그를 Parameter Store 에 기록 → 결제 서버 pull agent
롤백 ─▶ 해당 PR 을 revert 하는 PR
```

- 자동 PR 은 **만들기까지만** 합니다. merge 는 사람이 합니다.
- PR 은 GitHub App `team04-hotel-release-bot` 이 만듭니다. **이 레포에만 설치**되어 Contents · Pull requests 쓰기만 있고, main 은 ruleset(bypass 없음, 승인 1)이라 App 이 merge 할 수 없습니다. 개인 키는 AWS Secrets Manager 에 있고 GitLab 의 AWS Runner 만 읽습니다 (PAT · CI 변수 없음).
- 결제 서버 태그 동기화는 GitHub OIDC 로 AWS Role 을 받습니다. Role 은 이 레포 **main** 실행만 신뢰하고 파라미터 하나만 쓸 수 있습니다. Role ARN 은 Secret `AWS_SSM_SYNC_ROLE_ARN` (public 레포라 Actions 로그가 공개 — 계정 ID 가 찍히지 않게).
- 릴리스 절차(runbook)와 실패 대응은 모노레포 [`infra/gitops/prod/README.md`](https://github.com/Team-likelion-3rd-Project/likelion-devops-7th-3rd-team04/blob/develop/infra/gitops/prod/README.md) "릴리스".
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

**Settings → Secrets and variables → Actions → Secrets**: `AWS_SSM_SYNC_ROLE_ARN` = `arn:aws:iam::<계정 ID>:role/team04-hotel-gitops-ssm-sync` (모노레포 Terraform 10-global)

**Settings → GitHub Apps (조직)**: `team04-hotel-release-bot` 이 이 레포에만 설치되어 있는지 확인

**Settings → Collaborators and teams**: 팀원 4명(`rbsxo135`, `wkdtpgns5016`, `kimjhn4188-ctrl`, `jack7051105`) 모두 **Write 이상** — CODEOWNERS 는 쓰기 권한이 있는 사람만 소유자로 인정됩니다. 관리자(Admin)는 최소 인원

## 배포 (ArgoCD)

운영 Main 클러스터는 ArgoCD 가 이 레포 `main` 의 `envs/prod` 를 배포합니다 (모노레포 LDP-166, 이전에는 CronJob `gitops-sync` 배포 agent). 설치 · 동작 · 운영 방법은 모노레포 [`infra/gitops/prod/README.md`](https://github.com/Team-likelion-3rd-Project/likelion-devops-7th-3rd-team04/blob/develop/infra/gitops/prod/README.md) "배포 (ArgoCD)".

- **root 앱 `prod-apps`** 가 `envs/prod` 의 root 차트(`Chart.yaml` · `templates/`)를 렌더링해 앱 폴더(`chart.yaml`)마다 Application 을 만듭니다. `order` 는 sync-wave 이고, 앞 wave 가 Healthy 가 되어야 다음으로 갑니다. 이 레포 소스는 root 와 같은 커밋에 고정되어 **merge 하나 = 배포 하나** 입니다.
- 앱 정의 `chart.yaml`: `type`(`helm` · `git` · `local`), `repo` · `chart` · `version`(helm), `repo` · `path` · `revision`(git), `path`(local), `namespace`, `release`, `order`, `enabled`, `clusterValues`. `validate` 가 같은 형식으로 앱마다 렌더링하고 root 차트도 렌더링합니다.
- **계정 ID 는 이 레포에 쓰지 않습니다.** `clusterValues: true` 인 앱은 root 앱이 클러스터 값(`global.awsAccountId`)을 더 넘기므로 values 에서 `{{ .Values.global.awsAccountId }}` 로 씁니다 (차트가 템플릿을 지원하는 곳, 예: pod-identity-webhook 의 `RoleARN`). `validate` 는 더미 값으로 렌더링합니다.
- **자동 롤백은 없습니다.** 하위 앱은 계속 재시도하고, root sync 가 시간 제한(15분) 안에 끝나지 않으면 `#deploy` 에 실패 알림이 갑니다 → **수정 PR 또는 그 PR 의 revert PR 을 merge** 합니다.
- ArgoCD 는 이 레포 하나와 `chart.yaml` 의 차트 저장소만 읽습니다(public, 자격 증명 없음). 그래서 main 보호 규칙이 곧 운영 배포 승인입니다.
- 앱 폴더를 지우면 Application 만 지워지고 클러스터 리소스는 남습니다 (지우는 것은 사람이 함).
- 결제 서버는 클러스터 밖이라 ArgoCD 대상이 아닙니다. `envs/prod/payment/values.yaml` 의 태그로 결제 VPC 의 서버를 갱신합니다 (merge 후 `sync-payment-tag` workflow → SSM Parameter Store → 결제 서버 pull agent).

## 알려진 제약 / TODO

- `envs/prod/backend` 의 `TODO` (도메인 · CORS · PrivateLink 결제 엔드포인트)는 도메인 구매 · 결제 단계에서 채웁니다. 계정 ID · 큐 URL 은 클러스터 값(`global.awsAccountId`)으로 조립합니다.
- 첫 릴리스(v1.0.0-rc.1) 전에는 `backend` 의 `revision` · `imageTag` 를 수동 PR 로 넣었습니다. rc.1 부터는 릴리스 PR 만 이 값을 바꾸고, `validate` 가 모노레포 main 이력 밖의 SHA 를 거부합니다. 수동으로 값을 바꾸는 비상 PR 도 main 커밋 SHA 만 쓸 수 있습니다.
- `payment` 의 `image.registry` · `env` 의 `<account-id>` 와 결제 → booking 경로는 결제 단계에서 정리합니다.
- payment-service 는 아직 booking-service 를 gRPC 로 직접 호출합니다. prod 는 결제 → 메인 경로가 없으므로(PrivateLink 는 메인 → 결제만) 백엔드 변경 전까지 `BOOKING_SERVICE_HOST` 는 미정입니다.
