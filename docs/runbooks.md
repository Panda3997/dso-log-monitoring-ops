# 통합 로그 모니터링 런북

알림을 받은 사람이 무엇을 확인하고, 어떻게 판단하고, 무엇을 조치하는지 정리한 대응 절차입니다.
모든 명령은 ap-southeast-2 기준이며, 계정 ID와 버킷 이름은 환경에 맞게 바꿔 사용합니다.

| 런북 | 알림 | 알림 경로 |
| --- | --- | --- |
| RB-01 S3 퍼블릭 읽기 위반 | [SECURITY][HIGH] s3-bucket-public-read-prohibited | dso-security-alerts |
| RB-02 점검 Lambda 실행 오류 | ALARM: dso-compliance-check-errors | dso-ops-alerts |
| RB-03 점검 Lambda 미실행 | ALARM: dso-compliance-check-not-running | dso-ops-alerts |

---

## RB-01. S3 퍼블릭 읽기 위반

**심각도:** HIGH (버킷의 데이터가 외부에 노출될 수 있음)

**알림의 의미:** 점검 대상 날짜(UTC)에 Config 규칙 `s3-bucket-public-read-prohibited`가 해당 버킷을 비준수로 평가한 기록이 있다는 뜻입니다. 알림은 전날 기록을 다음 날 오전에 점검해 보내므로, **알림을 받은 시점에는 이미 복구되어 있을 수도 있습니다.** 그래서 현재 상태 확인이 첫 단계입니다.

### 1. 현재 상태 확인

```powershell
aws configservice get-compliance-details-by-config-rule --config-rule-name s3-bucket-public-read-prohibited --compliance-types NON_COMPLIANT
aws s3api get-bucket-policy-status --bucket <버킷 이름>
aws s3api get-public-access-block --bucket <버킷 이름>
```

- 비준수 목록에 버킷이 있고 `IsPublic: true` → 현재도 위반 중, 2단계로
- 이미 준수 상태 → 2단계(변경자 확인)와 6단계(기록)만 진행

### 2. 누가, 언제 바꿨는지 확인

```sql
SELECT eventtime, useridentity.arn, eventname, sourceipaddress
FROM cloudtrail_logs.cloudtrail_events
WHERE dt = '<알림의 점검 대상 날짜, 예: 2026/10/28>'
  AND eventname IN ('PutBucketPolicy', 'DeleteBucketPolicy',
                    'PutBucketPublicAccessBlock', 'DeleteBucketPublicAccessBlock',
                    'PutBucketAcl')
ORDER BY eventtime;
```

### 3. 판단

- 의도된 공개인가? (정적 웹 호스팅 등) → 변경자에게 확인
- 의도된 공개라면 조치하지 않고, 예외로 관리할지 검토 후 기록
- 의도되지 않았거나 확인되지 않으면 → 4단계 조치

### 4. 조치

정책을 지우기 전에 원인 분석을 위해 현재 정책을 먼저 백업합니다.

```powershell
aws s3api get-bucket-policy --bucket <버킷 이름> --output text > policy-backup.json
aws s3api delete-bucket-policy --bucket <버킷 이름>
aws s3api put-public-access-block --bucket <버킷 이름> --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### 5. 복구 확인

```powershell
aws configservice start-config-rules-evaluation --config-rule-names s3-bucket-public-read-prohibited
```

몇 분 뒤 Config 콘솔에서 해당 버킷이 **준수**로 돌아왔는지 확인합니다.

### 6. 기록

| 항목 | 내용 |
| --- | --- |
| 발생 시각 | CloudTrail에서 확인한 변경 시각 |
| 탐지 시각 | Config 비준수 평가 시각 / 알림 수신 시각 |
| 조치 시각 | 복구 명령 실행 시각 |
| 변경자 | CloudTrail의 사용자 ARN |
| 원인 | 의도/실수 여부 |
| 재발 방지 | 계정 단위 퍼블릭 차단 검토, 권한 축소 등 |

### 실제 대응 사례 (2026-10-28, 장애 주입 테스트)

| 시각 (KST) | 이벤트 | 근거 |
| --- | --- | --- |
| 10/28 21:00 | 버킷 퍼블릭 차단 해제 (PutBucketPublicAccessBlock) | CloudTrail |
| 10/28 21:05 | 퍼블릭 읽기 정책 적용 (PutBucketPolicy) | CloudTrail |
| 10/28 밤 | Config 규칙이 비준수로 평가 | Config 콘솔 |
| 10/28 22:39 | 정책 삭제 (DeleteBucketPolicy) | CloudTrail |
| 10/28 22:41 | 퍼블릭 차단 복구 (PutBucketPublicAccessBlock) | CloudTrail |
| 10/29 10:00 | 정기 점검이 10/28 기록에서 위반을 찾아 알림 발송 | 보안 알림 메일 |

---

## RB-02. 점검 Lambda 실행 오류

**심각도:** MEDIUM (그날 규정 점검이 실패해 위반을 놓칠 수 있음)

### 1. 오류 내용 확인

CloudWatch Logs Insights, 로그 그룹 `/aws/lambda/dso-compliance-check`

```
fields @timestamp, @message
| filter @message like /Error|Exception|FAILED/
| sort @timestamp desc
| limit 20
```

### 2. 원인별 판단

| 오류 메시지 | 가능한 원인 | 확인할 곳 |
| --- | --- | --- |
| `Athena query FAILED` + DB/테이블 없음 | 환경 변수 값 변경, 테이블 삭제 | Lambda 환경 변수, Glue 테이블 |
| `AccessDenied` | IAM 권한 변경 | Lambda 실행 역할 정책 |
| SNS 관련 오류 | 주제 삭제, 권한 | SNS 주제, 역할 정책 |
| `Task timed out` | Athena 대기 시간 초과 | Athena 쿼리 기록, Lambda 제한 시간 |

### 3. 설정이 바뀌었는지 확인

CloudFormation → `dso-ops` → 스택 작업 → **드리프트 감지**. `MODIFIED`가 있으면 누군가 콘솔에서 직접 바꾼 것입니다.

### 4. 조치

- 수동 변경이 원인이면 **드리프트 인지 변경 세트**로 템플릿 상태로 되돌림 (콘솔에서 손으로 되돌리지 않음)
- 권한이나 리소스 문제면 템플릿을 고쳐 스택을 업데이트

### 5. 놓친 날짜 다시 점검

```powershell
Set-Content payload.json '{"target_date":"<놓친 날짜, 예: 2026/10/28>"}'
aws lambda invoke --function-name dso-compliance-check --payload fileb://payload.json out.json
type out.json
```

### 6. 복구 확인

- 실행 결과가 `no_violation` 또는 `violation`으로 정상 종료
- 오류 알람이 **정상(OK)** 으로 돌아옴 (정상으로 돌아와야 다음 장애를 다시 감지할 수 있음)
- 드리프트 감지 `IN_SYNC`

### 실제 대응 사례 (2026-10-23, 장애 주입 테스트)

| 시각 (KST) | 이벤트 |
| --- | --- |
| 17:35 | 환경 변수 DATABASE를 잘못된 값으로 바꿔 실행 → 오류 발생 |
| 17:38 | 오류 알람 경보, dso-ops-alerts 알림 발송 (약 3분) |
| 이후 | 드리프트 감지 MODIFIED 확인 → 드리프트 인지 변경 세트로 복구 |
| 17:43 | 오류 알람 정상 복구, 알림 발송 |

---

## RB-03. 점검 Lambda 미실행

**심각도:** MEDIUM (점검 자체가 실행되지 않아 위반을 놓칠 수 있음)

### 1. 스케줄 상태 확인

```powershell
aws scheduler get-schedule --name dso-daily-compliance-check --query "[State,ScheduleExpression,Target.Arn]"
```

- `DISABLED` → 누군가 스케줄을 멈춤
- `ENABLED`인데 실행되지 않음 → 대상 Lambda나 스케줄러 역할 확인

### 2. 최근 실행 기록 확인

```
fields @timestamp, @message
| filter @message like /NON_COMPLIANT|SNS sent/
| sort @timestamp desc
| limit 10
```

### 3. 조치

스케줄은 스택 파라미터로 관리하므로 콘솔이 아니라 스택 업데이트로 되돌립니다.

```powershell
aws cloudformation deploy --template-file dso-ops-v2.yaml --stack-name dso-ops --capabilities CAPABILITY_NAMED_IAM --parameter-overrides ScheduleState=ENABLED HeartbeatPeriodSeconds=86400
```

### 4. 놓친 날짜 다시 점검

RB-02의 5단계와 같습니다.

### 5. 복구 확인

- 다음 정기 실행(매일 KST 10:00)이 로그에 기록됨
- 미실행 알람이 **정상(OK)** 으로 돌아옴

### 실제 대응 사례 (2026-10-23 ~ 10-24, 장애 주입 테스트)

| 시각 (KST) | 이벤트 |
| --- | --- |
| 10/23 저녁 | 스케줄 DISABLED, 알람 기간 1시간으로 변경 |
| 10/23 20:43 | 실행이 없어 미실행 알람 경보 |
| 10/24 07:43 | 스택 업데이트로 스케줄 복구, 알람 정상 |
| 10/24 10:00 | 정기 실행 재개 확인 |
