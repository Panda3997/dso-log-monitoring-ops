# AWS 통합 로그 모니터링: 운영 개선

보안 관점으로 구축한 AWS 통합 로그 모니터링 프로젝트를 운영 관점에서 다시 점검하고 개선한 기록입니다.
기존(v1)에서 콘솔로 만들던 리소스까지 CloudFormation으로 옮긴 v2 템플릿과, 각 개선의 검증에 사용한 스크립트·쿼리·런북을 담고 있습니다.

기존 프로젝트 : [AWS 통합 로그 모니터링 및 운영 자동화 구축](https://blog.naver.com/pandarimi/223906171232)


## 개선 내용

| 순서 | 개선 | 기존 문제 | 블로그 |
| --- | --- | --- | --- |
| 1 | Athena 파티션 프로젝션 | Config는 Lambda가 매일 파티션 등록, CloudTrail은 날짜마다 수동 등록 | ([링크](https://blog.naver.com/pandarimi/224467770051)) |
| 2 | 파이프라인 자체 모니터링 | 알림 누락을 사람이 발견 | 작성 예정 |
| 3 | S3 수명 주기 정책 | 로그 무기한 누적 | 작성 예정 |
| 4 | 알림 메시지 개선 + 런북 | 알림만 오고 대응 기준 없음 | 작성 예정 |


## 아키텍처 (v2)

| 스택 | 템플릿 | 리소스 |
| --- | --- | --- |
| 기반 스택 `dso-base` | `templates/dso-base-v2.yaml` | S3(로그, Athena 결과), 버킷 정책, CloudTrail 트레일, Config 레코더·전달 채널·규칙, Glue DB·테이블(파티션 프로젝션), Athena 워크그룹 |
| 운영 스택 `dso-ops` | `templates/dso-ops-v2.yaml` | 규정 준수 점검 Lambda, EventBridge Scheduler, SNS(보안 알림, 운영 알림), CloudWatch 알람(실행 오류, 미실행) |

바뀌는 주기가 다른 리소스를 두 스택으로 나눴고, 운영 스택은 기반 스택의 출력값(Export)을 가져다 씁니다.


## v1 → v2에서 바뀐 점

기존 프로젝트(v1)에서는 반복 수정이 많을 것으로 보고 일부 리소스를 콘솔에서 만들어, 템플릿만으로는 환경을 다시 만들 수 없었습니다. v2에서는 콘솔 리소스까지 모두 템플릿에 포함했습니다.

| 리소스 | v1 | v2 |
| --- | --- | --- |
| S3 로그 버킷, CloudTrail 트레일, Config 규칙 | 콘솔 | 기반 스택 |
| Athena 테이블 | 콘솔 SQL, Lambda가 매일 파티션 등록 | 기반 스택, 파티션 프로젝션 |
| 점검 Lambda, EventBridge Scheduler | 콘솔 | 운영 스택 |
| 점검 실행 시각 (UTC) | 00:30 (Config 로그 갱신 00:10~00:20을 측정해 조정) | 01:00 (전달 지연까지 고려해 여유 확보) |


## v2 배포 중 겪은 문제

| 현상 | 원인 | 해결 |
| --- | --- | --- |
| 변경 세트 생성 실패 (ResourceExistenceCheck) | v1에서 콘솔로 만든 Config 규칙이 스택 삭제 후에도 남아 있음 | 남은 리소스 확인 후 삭제 |
| Config 레코더 생성 실패 (NotStabilized) | 전달 채널이 레코더 완료를 기다리도록 설정한 의존 순서 | CloudTrail 이벤트 기록에서 기록 시작 API 반복을 확인, 의존 관계 제거 |
| 롤백 중 로그 버킷 삭제 실패 | 트레일이 먼저 생성돼 바로 로그를 씀 | 트레일을 마지막에 생성하도록 순서 변경 |
| 템플릿 배포 시 cp949 디코딩 오류 | Windows 기본 인코딩과 템플릿(UTF-8) 불일치 | `AWS_CLI_FILE_ENCODING=UTF-8` |


## 폴더 구조

```
templates/      v2 CloudFormation 템플릿 (기반 스택, 운영 스택)
validation/     파티션 프로젝션 사전 검증용 템플릿과 쿼리 (더미 로그 기준)
scripts/        더미 로그 생성 스크립트, 테스트용 정책, 배포 사용자 권한 정책
docs/           실행 명령어·쿼리 정리, 런북
```


## 배포

```powershell
# Windows 한국어 환경에서 템플릿 한글 주석을 읽기 위해 필요
$env:AWS_CLI_FILE_ENCODING = "UTF-8"

aws cloudformation deploy --template-file templates/dso-base-v2.yaml --stack-name dso-base --capabilities CAPABILITY_NAMED_IAM
aws cloudformation deploy --template-file templates/dso-ops-v2.yaml --stack-name dso-ops --capabilities CAPABILITY_NAMED_IAM --parameter-overrides AlertEmail=<이메일>
```

삭제는 운영 스택 → 버킷 비우기 → 기반 스택 순서로 합니다 (운영 스택이 기반 스택 출력값을 참조).


## 참고

- 리전: ap-southeast-2
- 파티션 프로젝션 사전 검증은 직접 생성한 더미 로그로 진행했고, 실제 적용 후 실제 로그로 다시 확인했습니다.
- 계정 ID는 모든 파일에서 `<ACCOUNT_ID>`로 표기했습니다.
