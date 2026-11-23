# 운영 개선 ② 실습 명령어 (실행 순서): 파이프라인 자체 모니터링

- PowerShell 명령은 작업 폴더에서 실행 (`templates/dso-ops-v2.yaml` 기준)
- `<ACCOUNT_ID>`는 12자리 계정 ID, `<이메일>`은 알림 받을 주소로 바꿔서 실행
- 기반 스택(`dso-base`)이 이미 배포된 상태에서 시작
- 날짜와 시각은 실습 당시 기준 (2026/10/23 ~ 10/27)

```powershell
$env:AWS_CLI_FILE_ENCODING = "UTF-8"   # 템플릿 한글 주석 디코딩 오류 방지 (창을 열 때마다)
```

---

## 1. 운영 스택 배포: 모니터링 없이 (10/23)

```powershell
aws cloudformation deploy --template-file dso-ops-v2.yaml --stack-name dso-ops --capabilities CAPABILITY_NAMED_IAM --parameter-overrides AlertEmail=<이메일> EnableMonitoring=false
```

배포 후 "AWS Notification - Subscription Confirmation" 메일에서 **Confirm subscription** 클릭 (`dso-security-alerts`).

동작 확인:

```powershell
Set-Content payload.json '{"target_date":"2026/10/22"}'
aws lambda invoke --function-name dso-compliance-check --payload fileb://payload.json out.json
type out.json                            # {"status": "no_violation", "dt": "2026/10/22"}
```

## 2. 모니터링 알람 추가: 변경 세트로 먼저 확인

```powershell
aws cloudformation deploy --template-file dso-ops-v2.yaml --stack-name dso-ops --capabilities CAPABILITY_NAMED_IAM --parameter-overrides AlertEmail=<이메일> EnableMonitoring=true --no-execute-changeset
```

CloudFormation 콘솔 → `dso-ops` → **변경 세트**에서 아래 4개가 `추가(Add)`이고 기존 리소스에 교체·제거가 없는지 확인 후 **변경 세트 실행**.

| 리소스 | 작업 |
| --- | --- |
| OpsAlertTopic, OpsAlertSubscription | Add |
| LambdaErrorAlarm, LambdaHeartbeatAlarm | Add |

`dso-ops-alerts` 구독 확인 메일에서 **Confirm subscription** 클릭.

## 3. 오류 알람 장애 주입 (10/23 17:35 ~ 17:43 KST)

**① 장애 만들기 (콘솔)**

Lambda 콘솔 → `dso-compliance-check` → 구성 → 환경 변수 → `DATABASE`를 `config_logs_wrong`으로 변경

```powershell
aws lambda invoke --function-name dso-compliance-check --payload fileb://payload.json out.json
type out.json                            # errorMessage: Athena query FAILED ...
```

→ 약 3분 뒤 `dso-ops-alerts`로 ALARM 메일 (OK → ALARM, 08:38:34 UTC)

**② 콘솔에서 복구**

Lambda 콘솔 → 환경 변수 → `DATABASE`를 `config_logs`로 되돌린 뒤 다시 실행

```powershell
aws lambda invoke --function-name dso-compliance-check --payload fileb://payload.json out.json
type out.json                            # {"status": "no_violation", ...}
```

→ 약 5분 뒤 오류 알람 OK 메일 (ALARM → OK, 08:43:34 UTC = 17:43 KST)

**③ 복구 확인**

CloudFormation 콘솔 → `dso-ops` → 스택 작업 → **드리프트 감지** → `IN_SYNC` (17:47 KST). 콘솔에서 원래 값으로 되돌렸으므로 템플릿과 실제 값이 같음.

콘솔 복구 뒤 수동 변경을 찾아 템플릿 기준으로 되돌리는 과정(드리프트 감지 → 드리프트 인지 변경 세트)은 운영 개선 ④ 런북 RB-02에서 다룸 → `docs/04-alert-runbook-commands.md` 8번

## 4. 미실행 알람 테스트 (10/23 저녁 ~ 10/24 아침)

스케줄을 멈추고 알람 기간을 1시간으로 줄임:

```powershell
aws cloudformation deploy --template-file dso-ops-v2.yaml --stack-name dso-ops --capabilities CAPABILITY_NAMED_IAM --parameter-overrides EnableMonitoring=true ScheduleState=DISABLED HeartbeatPeriodSeconds=3600
```

→ 마지막 실행 후 1~2시간 뒤 `dso-compliance-check-not-running` ALARM 메일 (10/23 20:43 KST)

원래대로 복구 (정기 점검 KST 10:00 전에):

```powershell
aws cloudformation deploy --template-file dso-ops-v2.yaml --stack-name dso-ops --capabilities CAPABILITY_NAMED_IAM --parameter-overrides EnableMonitoring=true ScheduleState=ENABLED HeartbeatPeriodSeconds=86400
```

→ 알람 OK 복구 (10/24 07:43 KST), 10:00 정기 실행 재개

`AlertEmail`은 다시 입력하지 않음. 입력하지 않은 파라미터는 기존 값을 쓰고, 값이 조금이라도 달라지면 이메일 구독이 교체됨.

## 5. 평상시 정기 실행 확인 (10/27)

CloudWatch Logs Insights, 로그 그룹 `/aws/lambda/dso-compliance-check`, 기간 1주:

```
SOURCE "/aws/lambda/dso-compliance-check" START=-1w END=0s |
fields @timestamp, @message
| filter @message like /NON_COMPLIANT|SNS sent/
| sort @timestamp asc
```

결과: 10/24 ~ 10/27 매일 UTC 01:00:06 실행, `dt`가 매번 전날

알람 상태: CloudWatch → 알람 → 두 알람 `정상`, 작업 활성화됨 → 각 알람의 그래프·기록 탭에서 ALARM ↔ OK 이력 확인

## 6. 알림 경로 점검: 중복 구독 정리 (10/26)

```powershell
aws sns list-subscriptions --query "Subscriptions[].[TopicArn,Endpoint,SubscriptionArn]" --output table
```

`dso-security-alerts`에 같은 이메일 구독이 2개 → 스택이 관리하는 구독 확인:

```powershell
aws cloudformation describe-stack-resource --stack-name dso-ops --logical-resource-id SecurityAlertSubscription --query "StackResourceDetail.PhysicalResourceId" --output text
```

스택이 관리하지 않는 쪽을 삭제:

```powershell
aws sns unsubscribe --subscription-arn <중복 구독 ARN>
aws sns list-subscriptions --query "Subscriptions[].[TopicArn,SubscriptionArn]" --output table
```

원인 추정: 10/24 스택 업데이트 때 구독이 교체되며 CloudFormation 이벤트에는 기존 구독 `DELETE_COMPLETE`로 기록됐지만 실제로는 남아 있었음
