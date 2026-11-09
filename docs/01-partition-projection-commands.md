# 운영 개선 ① 실습 명령어·쿼리 (실행 순서)

- PowerShell 명령은 작업 폴더에서 실행
- `<ACCOUNT_ID>`는 12자리 계정 ID로 바꿔서 실행
- Athena 쿼리는 리전 시드니(ap-southeast-2), 워크그룹 `dso-workgroup`에서 하나씩 실행
- 날짜는 실습 당시 기준 (1단계: 2026/10/1~10/21, 2단계: 2026/10/22~10/27)

---

# 1단계: 사전 검증 (검증용 스택 `dso-athena-projection`, 더미 로그)

## 1-1. 준비 (PowerShell)

```powershell
cd "<작업 폴더 경로>"
$env:AWS_CLI_FILE_ENCODING = "UTF-8"   # cp949 디코딩 오류 방지 (창을 열 때마다)

aws sts get-caller-identity             # Arn이 user/dso-cli-practice 인지
aws configure get region                # ap-southeast-2 인지
```

## 1-2. 1차 배포: 테이블 없이 (PowerShell)

```powershell
aws cloudformation deploy --template-file athena-projection.yaml --stack-name dso-athena-projection --parameter-overrides DeployTable=false
```

## 1-3. 더미 로그 생성·업로드: 10/1~10/20 (PowerShell)

```powershell
# 이전 생성물 정리 (처음이면 생략 가능)
Remove-Item ct_dummy, dummy, ct_today, dummy_today -Recurse -Force -ErrorAction SilentlyContinue
aws s3 rm s3://dso-config-logs-<ACCOUNT_ID>/AWSLogs/ --recursive

# 생성
python gen_dummy_cloudtrail_logs.py --account <ACCOUNT_ID>
python gen_dummy_config_logs.py --account <ACCOUNT_ID>
dir                                      # ct_dummy, dummy 폴더 확인

# 업로드
aws s3 cp ct_dummy/ s3://dso-config-logs-<ACCOUNT_ID>/ --recursive
aws s3 cp dummy/ s3://dso-config-logs-<ACCOUNT_ID>/ --recursive

# 업로드 확인 -> PRE CloudTrail/, PRE Config/
aws s3 ls s3://dso-config-logs-<ACCOUNT_ID>/AWSLogs/<ACCOUNT_ID>/
```

## 1-4. Config Before: 수동 등록 문제 재현 (Athena)

```sql
-- 3-1. 파티션 프로젝션 없이 테이블 생성
CREATE EXTERNAL TABLE config_logs.config_history_manual (
  fileversion string,
  configurationitems array<struct<
    configurationitemcapturetime: string,
    resourcetype: string,
    resourceid: string,
    resourcename: string,
    awsregion: string,
    configuration: struct<
      configrulelist: array<struct<
        configrulename: string,
        compliancetype: string
      >>
    >
  >>
)
PARTITIONED BY (dt string)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
LOCATION 's3://dso-config-logs-<ACCOUNT_ID>/AWSLogs/<ACCOUNT_ID>/Config/ap-southeast-2/';

-- 3-2. 조회 -> 데이터가 있는데도 0건 (등록된 파티션이 없기 때문)
SELECT count(*) AS file_count FROM config_logs.config_history_manual;

-- 3-3. MSCK REPAIR 시도 -> 경로가 dt=값 형식이 아니라서 파티션을 찾지 못함
MSCK REPAIR TABLE config_logs.config_history_manual;

-- 3-4. 하루치만 수동 등록
ALTER TABLE config_logs.config_history_manual ADD PARTITION (dt = '2026/10/1')
LOCATION 's3://dso-config-logs-<ACCOUNT_ID>/AWSLogs/<ACCOUNT_ID>/Config/ap-southeast-2/2026/10/1/ConfigHistory/';

-- 3-5. 날짜별 건수 -> 등록한 하루치만 나옴 (나머지 19일은 하나씩 등록해야 함)
SELECT dt, count(*) AS file_count
FROM config_logs.config_history_manual
GROUP BY dt
ORDER BY dt;
```

## 1-5. Config After: 파티션 프로젝션 적용 (Athena)

```sql
-- 4-1. 프로젝션 속성 추가
ALTER TABLE config_logs.config_history_manual SET TBLPROPERTIES (
  'projection.enabled'          = 'true',
  'projection.dt.type'          = 'date',
  'projection.dt.format'        = 'yyyy/M/d',
  'projection.dt.range'         = '2026/10/1,NOW',
  'projection.dt.interval'      = '1',
  'projection.dt.interval.unit' = 'DAYS',
  'storage.location.template'   = 's3://dso-config-logs-<ACCOUNT_ID>/AWSLogs/<ACCOUNT_ID>/Config/ap-southeast-2/${dt}/ConfigHistory/'
);

-- 4-2. 날짜별 건수 -> 등록 작업 없이 20일치 전부 나옴
SELECT dt, count(*) AS file_count
FROM config_logs.config_history_manual
GROUP BY dt
ORDER BY dt;

-- 4-3. 특정 날짜의 규정 미준수 리소스 조회 (Lambda가 매일 실행할 쿼리의 형태)
SELECT
  dt,
  ci.configurationitemcapturetime AS captured_at,
  ci.resourceid,
  r.configrulename,
  r.compliancetype
FROM config_logs.config_history_manual
CROSS JOIN UNNEST(configurationitems) AS t(ci)
CROSS JOIN UNNEST(ci.configuration.configrulelist) AS t2(r)
WHERE dt = '2026/10/20'
  AND r.compliancetype = 'NON_COMPLIANT'
ORDER BY captured_at;

-- 4-4. 스캔량 비교 : 아래 두 쿼리의 '스캔한 데이터'를 각각 캡처
-- (A) 날짜 조건 없음 -> 전체 기간 스캔
SELECT count(*) FROM config_logs.config_history_manual
CROSS JOIN UNNEST(configurationitems) AS t(ci);

-- (B) 날짜 조건 있음 -> 해당 날짜 경로만 스캔
SELECT count(*) FROM config_logs.config_history_manual
CROSS JOIN UNNEST(configurationitems) AS t(ci)
WHERE dt = '2026/10/20';

-- 4-5. 한 자리 날짜 확인 (0 미포함 경로가 제대로 읽히는지)
SELECT dt, count(*) AS file_count
FROM config_logs.config_history_manual
WHERE dt IN ('2026/10/1', '2026/10/5', '2026/10/9')
GROUP BY dt;
```

## 1-6. CloudTrail 검증 (Athena)

```sql
-- CT-2. 프로젝션을 포함해 테이블 생성 (처음부터 프로젝션 적용)
CREATE EXTERNAL TABLE cloudtrail_logs.cloudtrail_events_manual (
  eventversion string,
  useridentity struct<
    type: string,
    principalid: string,
    arn: string,
    accountid: string,
    username: string
  >,
  eventtime string,
  eventsource string,
  eventname string,
  awsregion string,
  sourceipaddress string,
  useragent string,
  errorcode string,
  errormessage string,
  requestid string,
  eventid string,
  readonly string,
  eventtype string,
  recipientaccountid string
)
PARTITIONED BY (dt string)
ROW FORMAT SERDE 'org.apache.hive.hcatalog.data.JsonSerDe'
STORED AS INPUTFORMAT 'com.amazon.emr.cloudtrail.CloudTrailInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION 's3://dso-config-logs-<ACCOUNT_ID>/AWSLogs/<ACCOUNT_ID>/CloudTrail/ap-southeast-2/'
TBLPROPERTIES (
  'projection.enabled'          = 'true',
  'projection.dt.type'          = 'date',
  'projection.dt.format'        = 'yyyy/MM/dd',
  'projection.dt.range'         = '2026/10/01,NOW',
  'projection.dt.interval'      = '1',
  'projection.dt.interval.unit' = 'DAYS',
  'storage.location.template'   = 's3://dso-config-logs-<ACCOUNT_ID>/AWSLogs/<ACCOUNT_ID>/CloudTrail/ap-southeast-2/${dt}/'
);

-- CT-3. 날짜별 이벤트 수 -> 등록 작업 없이 20일치 전부 나오는지 확인
--       (dt 값이 '2026/10/01'처럼 0이 붙어 나오는 것도 확인)
SELECT dt, count(*) AS event_count
FROM cloudtrail_logs.cloudtrail_events_manual
GROUP BY dt
ORDER BY dt;

-- CT-4. 형식 비교 실험 : 0을 빼고 조회하면 어떻게 되는지 확인 (0건 예상)
--       -> Config와 CloudTrail의 형식 차이를 보여주는 캡처용
SELECT count(*) AS event_count
FROM cloudtrail_logs.cloudtrail_events_manual
WHERE dt = '2026/10/1';

-- CT-5. 이상 징후 날짜 찾기 : 날짜별 권한 오류 수
--       (더미 스크립트가 출력한 '이상 징후 포함' 날짜가 가장 크게 나와야 함)
SELECT dt, count(*) AS access_denied
FROM cloudtrail_logs.cloudtrail_events_manual
WHERE errorcode = 'AccessDenied'
GROUP BY dt
ORDER BY access_denied DESC;

-- CT-6. 이상 징후 날짜의 시간대별 API 호출 수 (QuickSight 그래프와 같은 형태)
--       dt 값은 CT-5에서 가장 위에 나온 날짜로 수정
SELECT substr(eventtime, 12, 2) AS hour_utc, count(*) AS event_count
FROM cloudtrail_logs.cloudtrail_events_manual
WHERE dt = '2026/10/11'
GROUP BY substr(eventtime, 12, 2)
ORDER BY hour_utc;

-- CT-7. 이상 징후 상세 : 어떤 IP가 어떤 API를 호출했는지
SELECT sourceipaddress, useridentity.username AS user_name, eventname,
       count(*) AS calls,
       count_if(errorcode = 'AccessDenied') AS denied
FROM cloudtrail_logs.cloudtrail_events_manual
WHERE dt = '2026/10/11'
GROUP BY sourceipaddress, useridentity.username, eventname
ORDER BY calls DESC
LIMIT 10;

-- CT-8. 스캔량 비교 : 아래 두 쿼리의 '스캔한 데이터'를 각각 캡처
-- (A) 날짜 조건 없음
SELECT count(*) FROM cloudtrail_logs.cloudtrail_events_manual
WHERE errorcode = 'AccessDenied';
-- (B) 날짜 조건 있음
SELECT count(*) FROM cloudtrail_logs.cloudtrail_events_manual
WHERE dt = '2026/10/11' AND errorcode = 'AccessDenied';
```

## 1-7. 새 날짜 테스트: 오늘(UTC) 1일치 (PowerShell → Athena)

프로젝션을 적용한 **뒤에 새로 생긴 날짜**도 등록 없이 조회되는지 확인합니다. 먼저 오늘 날짜 더미 로그를 올리고(①), 그다음 4-6과 CT-9를 실행합니다(②).

**① 오늘 날짜 더미 로그 업로드**

```powershell
python gen_dummy_cloudtrail_logs.py --account <ACCOUNT_ID> --today-only --out ct_today
python gen_dummy_config_logs.py --account <ACCOUNT_ID> --today-only --out dummy_today
aws s3 cp ct_today/ s3://dso-config-logs-<ACCOUNT_ID>/ --recursive
aws s3 cp dummy_today/ s3://dso-config-logs-<ACCOUNT_ID>/ --recursive
```

**② 새 날짜 조회 (Athena)**

```sql
-- 4-6. 새 날짜 테스트 : 오늘(UTC) 더미 로그 업로드 후 실행
--      등록 작업 없이 바로 조회되면 성공 (날짜는 오늘 UTC 날짜로 수정)
SELECT dt, count(*) AS file_count
FROM config_logs.config_history_manual
WHERE dt = '2026/10/21'
GROUP BY dt;

-- CT-9. 새 날짜 테스트 : 오늘(UTC) 더미 로그 업로드 후 실행 (날짜는 스크립트 출력 기준으로 수정)
SELECT dt, count(*) AS event_count
FROM cloudtrail_logs.cloudtrail_events_manual
WHERE dt = '2026/10/21'
GROUP BY dt;
```

## 1-8. IaC 이전 (Athena → PowerShell → Athena)

수동으로 만든 실습 테이블을 지우고(①), 같은 설정을 템플릿으로 다시 만든 뒤(②), 같은 결과가 나오는지 확인합니다(③). 외부 테이블이라 테이블을 지워도 S3의 로그 파일은 남아 있어서, 새로 만든 테이블이 같은 로그를 바로 읽습니다.

```sql
-- 5-1. 수동 테이블 삭제 (외부 테이블이라 S3의 로그 파일은 지워지지 않음)
DROP TABLE config_logs.config_history_manual;
DROP TABLE cloudtrail_logs.cloudtrail_events_manual;
```

```powershell
aws cloudformation deploy --template-file athena-projection.yaml --stack-name dso-athena-projection --parameter-overrides DeployTable=true
```

```sql
-- 5-2. 스택 업데이트(DeployTable=true) 후, CloudFormation이 만든 테이블로 동일하게 확인
SELECT dt, count(*) AS file_count
FROM config_logs.config_history
GROUP BY dt
ORDER BY dt;

SELECT dt, count(*) AS event_count
FROM cloudtrail_logs.cloudtrail_events
GROUP BY dt
ORDER BY dt;
```

## 1-9. 검증용 스택 삭제 (PowerShell)

```powershell
aws s3 rm s3://dso-config-logs-<ACCOUNT_ID> --recursive
aws s3 rm s3://dso-athena-results-<ACCOUNT_ID> --recursive
aws cloudformation delete-stack --stack-name dso-athena-projection
aws cloudformation wait stack-delete-complete --stack-name dso-athena-projection
```

---

# 2단계: 실제 적용 (v2 기반 스택 `dso-base`, 운영 스택 `dso-ops`)

## 2-1. 남은 리소스 확인 (PowerShell)

```powershell
aws s3 ls | findstr dso
aws glue get-databases --query "DatabaseList[].Name"
aws athena list-work-groups --query "WorkGroups[].Name"
aws configservice describe-config-rules --query "ConfigRules[].ConfigRuleName"
aws configservice describe-config-rules --config-rule-names s3-bucket-public-read-prohibited --query "ConfigRules[].[ConfigRuleName,CreatedBy]"
aws configservice describe-configuration-recorders
aws configservice describe-delivery-channels
```

## 2-2. 트러블슈팅 1: 배포 전 검사 실패 → v1 Config 규칙 삭제

```powershell
aws configservice delete-config-rule --config-rule-name s3-bucket-public-read-prohibited

aws cloudformation delete-stack --stack-name dso-base
aws cloudformation wait stack-delete-complete --stack-name dso-base
```

## 2-3. 기반 스택 배포

```powershell
$env:AWS_CLI_FILE_ENCODING = "UTF-8"
aws cloudformation deploy --template-file dso-base-v2.yaml --stack-name dso-base --capabilities CAPABILITY_NAMED_IAM
```

## 2-4. 트러블슈팅 2·3: 레코더 안정화 실패, 롤백 실패

```powershell
# 처음 실패한 리소스 찾기
aws cloudformation describe-stack-events --stack-name dso-base --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].[LogicalResourceId,ResourceStatusReason]" --output table

# CloudTrail 이벤트 기록으로 배포 시각의 Config API 호출 확인
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventSource,AttributeValue=config.amazonaws.com --start-time 2026-10-22T13:05:00Z --end-time 2026-10-22T13:20:00Z --query "Events[].[EventTime,EventName]" --output table

# 남은 버킷 비우고 실패 스택 삭제
aws s3 rm s3://dso-logs-<ACCOUNT_ID> --recursive
aws cloudformation delete-stack --stack-name dso-base
aws cloudformation wait stack-delete-complete --stack-name dso-base

# 템플릿 수정 후 재배포 -> 성공 (10/23 02:15)
aws cloudformation deploy --template-file dso-base-v2.yaml --stack-name dso-base --capabilities CAPABILITY_NAMED_IAM

# Config 레코더 기록 중인지 확인 -> "recording": true
aws configservice describe-configuration-recorder-status
```

## 2-5. CloudTrail 새 날짜 확인 (PowerShell → Athena)

```powershell
aws s3 ls s3://dso-logs-<ACCOUNT_ID>/AWSLogs/<ACCOUNT_ID>/CloudTrail/ap-southeast-2/2026/10/
```

```sql
SELECT dt, count(*) AS events
FROM cloudtrail_logs.cloudtrail_events
WHERE dt IN ('2026/10/22', '2026/10/23')
GROUP BY dt
ORDER BY dt;
```

## 2-6. Config 변경 만들기: 테스트 버킷 생성 (PowerShell)

```powershell
aws s3 mb s3://dso-test-<ACCOUNT_ID>
```

## 2-7. 운영 스택 배포와 Lambda(v2) 실행 (PowerShell)

```powershell
aws cloudformation deploy --template-file dso-ops-v2.yaml --stack-name dso-ops --capabilities CAPABILITY_NAMED_IAM --parameter-overrides AlertEmail=<이메일> EnableMonitoring=false

Set-Content payload.json '{"target_date":"2026/10/22"}'
aws lambda invoke --function-name dso-compliance-check --payload fileb://payload.json out.json
type out.json                            # {"status": "no_violation", "dt": "2026/10/22"}
```

## 2-8. `no_violation`이 실제 데이터 기반인지 + Config 새 날짜 확인 (Athena)

```sql
SELECT dt, rule.configrulename, rule.compliancetype, count(*) AS items
FROM config_logs.config_flat_confighistory
CROSS JOIN UNNEST(configurationitems) AS t(item)
CROSS JOIN UNNEST(item.configuration.configrulelist) AS t2(rule)
WHERE dt IN ('2026/10/22', '2026/10/23', '2026/10/24', '2026/10/25')
GROUP BY dt, rule.configrulename, rule.compliancetype
ORDER BY dt;
```

결과: 10/22 COMPLIANT 2건, 10/23 COMPLIANT 1건(dso-test), 10/24·25 없음(변경 없는 날), 스캔 3.66KB

## 2-9. 매일 새 날짜를 점검했는지 확인 (CloudWatch Logs Insights)

로그 그룹 `/aws/lambda/dso-compliance-check`, 기간 1주

```
SOURCE "/aws/lambda/dso-compliance-check" START=-1w END=0s |
fields @timestamp, @message
| filter @message like /NON_COMPLIANT|SNS sent/
| sort @timestamp asc
```

결과: 10/24~10/27 매일 UTC 01:00:06 실행, `dt`가 매번 전날
