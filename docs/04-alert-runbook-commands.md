# 운영 개선 ④ 실습 명령어 (실행 순서): 알림 메시지 개선 + 런북

- PowerShell 명령은 작업 폴더에서 실행 (`templates/dso-ops-v2.yaml`, `scripts/dso-test-public-policy.json` 기준)
- `<ACCOUNT_ID>`는 12자리 계정 ID로 바꿔서 실행 (`dso-test-public-policy.json` 안의 값도)
- 테스트 버킷 `dso-test-<ACCOUNT_ID>`는 ①에서 Config 변경을 만들 때 생성한 빈 버킷
- 날짜와 시각은 실습 당시 기준 (2026/10/28 ~ 10/29, 8번만 10/23)

```powershell
$env:AWS_CLI_FILE_ENCODING = "UTF-8"
```

---

## 1. 운영 스택 업데이트: 알림 메시지 개선 (변경 세트로 먼저 확인)

`AlertEmail` 등 기존 파라미터는 입력하지 않음 (기존 값 유지, 구독 교체 방지). 새 파라미터 `RunbookUrl`은 기본값(빈 값).

```powershell
aws cloudformation deploy --template-file dso-ops-v2.yaml --stack-name dso-ops --capabilities CAPABILITY_NAMED_IAM --no-execute-changeset
```

변경 세트 확인 후 실행:

| 리소스 | 작업 | 교체 | 바뀌는 내용 |
| --- | --- | --- | --- |
| ComplianceCheckFunction | Modify | False | 코드 변경, 환경 변수 `SEVERITY` 추가 (`attributeChangeType: Add`) |
| LambdaErrorAlarm, LambdaHeartbeatAlarm | Modify | False | 알람 설명을 영어로 변경 |

`SecurityAlertSubscription`, `OpsAlertSubscription`이나 제거(Remove)가 보이면 실행하지 않음.

## 2. 바뀐 Lambda 확인

```powershell
Set-Content payload.json '{"target_date":"2026/10/26"}'
aws lambda invoke --function-name dso-compliance-check --payload fileb://payload.json out.json
type out.json                            # {"status": "no_violation", "dt": "2026/10/26"}
```

Lambda 콘솔 → 구성 → 환경 변수에서 `SEVERITY = HIGH` 확인

## 3. 계정 단위 퍼블릭 차단 확인

```powershell
aws s3control get-public-access-block --account-id <ACCOUNT_ID>
```

네 값이 모두 `true`면 버킷을 퍼블릭으로 바꿀 수 없음. 이 경우 계정 설정은 끄지 않고 다른 방법으로 테스트.

실습 결과: `NoSuchPublicAccessBlockConfiguration` 오류 → 계정 단위 설정이 없음(막는 것 없음). 계정 설정은 바꾸지 않고 테스트 버킷의 버킷 단위 차단만 해제.

## 4. 위반 만들기 → 즉시 되돌리기 (10/28 21:00 ~ 22:41 KST)

퍼블릭으로 전환 (빈 버킷):

```powershell
aws s3api put-public-access-block --bucket dso-test-<ACCOUNT_ID> --public-access-block-configuration BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false
aws s3api put-bucket-policy --bucket dso-test-<ACCOUNT_ID> --policy file://dso-test-public-policy.json
```

Config 콘솔 → 규칙 → `s3-bucket-public-read-prohibited` → 범위 내 리소스에서 `dso-test`가 **미준수** (주석: The S3 bucket policy allows public read access). 오래 걸리면 작업 → 재평가.

즉시 되돌리기:

```powershell
aws s3api delete-bucket-policy --bucket dso-test-<ACCOUNT_ID>
aws s3api put-public-access-block --bucket dso-test-<ACCOUNT_ID> --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

몇 분 뒤 규칙이 **준수**로 돌아왔는지 확인. 되돌려도 그날(UTC 10/28) 기록에는 미준수가 남아 다음 날 점검에서 알림이 감.

## 5. 다음 날 정기 점검 알림 확인 (10/29 10:00 KST)

`dso-security-alerts` 메일 확인:

```
제목: [SECURITY][HIGH] s3-bucket-public-read-prohibited - 1 resource(s)

[보안 규정 위반] s3-bucket-public-read-prohibited
- 심각도: HIGH
- 위반 리소스 (1건):
    * dso-test-<ACCOUNT_ID>
- 리전: ap-southeast-2
- 점검 대상 로그 날짜(UTC): 2026/10/28
- 점검 시각(KST): 2026-10-29 10:00
- 대응 절차(런북): (미등록)
```

## 6. 누가, 언제 바꿨는지 확인 (런북 RB-01 2단계)

```sql
SELECT eventtime, useridentity.arn, eventname, sourceipaddress
FROM cloudtrail_logs.cloudtrail_events
WHERE dt = '2026/10/28'
  AND eventname IN ('PutBucketPolicy', 'DeleteBucketPolicy', 'PutBucketPublicAccessBlock', 'DeleteBucketPublicAccessBlock')
ORDER BY eventtime;
```

결과 (UTC): 12:00:39 PutBucketPublicAccessBlock → 12:05:19 PutBucketPolicy → 13:39:38 DeleteBucketPolicy → 13:41:05 PutBucketPublicAccessBlock

## 7. 런북 주소 반영

런북(`docs/runbooks.md`)을 블로그에 발행한 뒤, 글 주소를 파라미터로 넣어 배포:

```powershell
aws cloudformation deploy --template-file dso-ops-v2.yaml --stack-name dso-ops --capabilities CAPABILITY_NAMED_IAM --parameter-overrides "RunbookUrl=<런북 글 주소>" --no-execute-changeset
```

변경 세트: `ComplianceCheckFunction` 수정만, JSON 변경 사항에서 `RUNBOOK_URL`의 `afterValue`가 주소와 같은지 확인 후 실행 (주소에 `<>`를 넣지 않음, 전체를 큰따옴표로 감쌈)

메일 확인:

```powershell
Set-Content payload.json '{"target_date":"2026/10/28"}'
aws lambda invoke --function-name dso-compliance-check --payload fileb://payload.json out.json
```

→ 메일 맨 아래 `대응 절차(런북)`에 주소 표시 (수동 실행이라 점검 시각은 10/29 18:48 KST)

## 8. 런북 RB-02 확인: 콘솔 복구가 남긴 수동 변경 정리 (10/23 18:07 KST ~)

운영 개선 ②의 장애 주입(콘솔 복구) 뒤, 같은 변경을 다시 만들어 RB-02의 "드리프트 감지 → 드리프트 인지 변경 세트" 단계를 확인함.

**① 수동 변경 만들기 (콘솔)**

Lambda 콘솔 → `dso-compliance-check` → 구성 → 환경 변수 → `DATABASE`를 `config_logs_wrong`으로 변경

**② 드리프트 감지**

CloudFormation 콘솔 → `dso-ops` → 스택 작업 → **드리프트 감지** → `ComplianceCheckFunction`이 `MODIFIED`
→ **드리프트 세부 정보 보기**: `DATABASE` 예상 값 `config_logs` / 현재 값 `config_logs_wrong`

CLI로 확인하는 경우:

```powershell
aws cloudformation detect-stack-drift --stack-name dso-ops
aws cloudformation describe-stack-resource-drifts --stack-name dso-ops --stack-resource-drift-status-filters MODIFIED
```

**③ 템플릿 기준으로 복구 (드리프트 인지 변경 세트)**

드리프트 화면의 **변경 세트 생성** → 설명: `Revert drift: restore DATABASE env var after fault injection test`
→ JSON 변경 사항에서 `path: /Properties/Environment/Variables/DATABASE`, `beforeValue: config_logs_wrong`, `afterValue: config_logs`, `requiresRecreation: Never` 확인 → 실행

**④ 복구 확인**

- 드리프트 감지 다시 실행 → `IN_SYNC`
- 기능 확인:

```powershell
Set-Content payload.json '{"target_date":"2026/10/22"}'
aws lambda invoke --function-name dso-compliance-check --payload fileb://payload.json out.json
type out.json                            # {"status": "no_violation", ...}
```

참고: 일반 스택 업데이트로는 이 드리프트가 되돌아가지 않음 (업데이트는 이전 템플릿과 새 템플릿만 비교하고, `DATABASE`는 템플릿상 바뀐 값이 없음)
