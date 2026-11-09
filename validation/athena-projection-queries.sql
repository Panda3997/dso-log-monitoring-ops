-- =====================================================================
-- Athena 파티션 프로젝션 실습 쿼리
-- 실행 전: Athena 콘솔에서 워크그룹을 'dso-workgroup'으로 선택
-- <ACCOUNT_ID> 는 본인 12자리 계정 ID로 모두 바꿔서 실행
-- 쿼리 하나씩 실행하고, 결과와 '쿼리 통계'의 스캔한 데이터를 캡처
-- =====================================================================


-- ---------------------------------------------------------------------
-- [3단계] BEFORE : 프로젝션 없는 테이블 (기존 방식 재현)
-- ---------------------------------------------------------------------

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


-- ---------------------------------------------------------------------
-- [4단계] AFTER : 같은 테이블에 파티션 프로젝션 적용
-- ---------------------------------------------------------------------

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

-- 4-6. 새 날짜 테스트 : 오늘(UTC) 더미 로그 업로드 후 실행
--      등록 작업 없이 바로 조회되면 성공 (날짜는 오늘 UTC 날짜로 수정)
SELECT dt, count(*) AS file_count
FROM config_logs.config_history_manual
WHERE dt = '2026/10/21'
GROUP BY dt;


-- ---------------------------------------------------------------------
-- [CT단계] CloudTrail 사전 검증 : 형식이 다른 로그도 프로젝션으로 읽히는지 확인
--   - Before(수동 등록) 재현은 Config에서 했으므로 생략
--   - CloudTrail 경로는 월/일에 0이 붙음 -> 형식 yyyy/MM/dd
-- ---------------------------------------------------------------------

-- CT-1. (쿼리 없음) cloudtrail_logs 데이터베이스는 1차 스택 배포에서 이미 생성됨
--       Athena 왼쪽 데이터베이스 목록에 cloudtrail_logs가 있는지만 확인

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

-- CT-9. 새 날짜 테스트 : 오늘(UTC) 더미 로그 업로드 후 실행 (날짜는 스크립트 출력 기준으로 수정)
SELECT dt, count(*) AS event_count
FROM cloudtrail_logs.cloudtrail_events_manual
WHERE dt = '2026/10/21'
GROUP BY dt;


-- ---------------------------------------------------------------------
-- [5단계] IaC로 이전 : 수동 테이블 삭제 후 CloudFormation으로 재생성
-- ---------------------------------------------------------------------

-- 5-1. 수동 테이블 삭제 (외부 테이블이라 S3의 로그 파일은 지워지지 않음)
DROP TABLE config_logs.config_history_manual;
DROP TABLE cloudtrail_logs.cloudtrail_events_manual;

-- 5-2. 스택 업데이트(DeployTable=true) 후, CloudFormation이 만든 테이블로 동일하게 확인
SELECT dt, count(*) AS file_count
FROM config_logs.config_history
GROUP BY dt
ORDER BY dt;

SELECT dt, count(*) AS event_count
FROM cloudtrail_logs.cloudtrail_events
GROUP BY dt
ORDER BY dt;
