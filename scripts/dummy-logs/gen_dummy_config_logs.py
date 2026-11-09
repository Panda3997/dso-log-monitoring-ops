#!/usr/bin/env python3
"""
AWS Config ConfigHistory 형식의 더미 로그를 실제와 같은 날짜별 S3 경로 구조로 생성합니다.

사용 예:
  python3 gen_dummy_config_logs.py --account 123456789012                          # 어제부터 과거 20일치
  python3 gen_dummy_config_logs.py --account 123456789012 --today-only --out dummy_today  # 오늘(UTC) 1일치
"""
import argparse
import gzip
import json
import os
import random
import uuid
from datetime import datetime, timedelta, timezone

REGION = "ap-southeast-2"
RULES = ["s3-bucket-public-read-prohibited", "s3-bucket-server-side-encryption-enabled"]
BUCKETS = ["app-data-bucket", "backup-bucket", "my-dso-test"]


def make_item(account, day, bucket, rule, compliance):
    t = datetime(day.year, day.month, day.day,
                 random.randint(0, 23), random.randint(0, 59), random.randint(0, 59),
                 tzinfo=timezone.utc)
    return {
        "configurationItemVersion": "1.3",
        "configurationItemCaptureTime": t.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        "configurationStateId": random.randint(10**12, 10**13),
        "awsAccountId": account,
        "configurationItemStatus": "OK",
        "resourceType": "AWS::Config::ResourceCompliance",
        "resourceId": f"AWS::S3::Bucket/{bucket}",
        "resourceName": f"AWS::S3::Bucket/{bucket}",
        "awsRegion": REGION,
        "configuration": {
            "configRuleList": [{
                "configRuleArn": f"arn:aws:config:{REGION}:{account}:config-rule/config-rule-{uuid.uuid4().hex[:6]}",
                "configRuleName": rule,
                "complianceType": compliance,
            }],
            "complianceType": compliance,
            "resourceId": bucket,
            "resourceType": "AWS::S3::Bucket",
        },
        "tags": {},
        "relationships": [],
    }


def write_day(account, day, out_dir):
    # 실제 Config 경로처럼 월/일에 0을 붙이지 않음 (예: 2026/10/1)
    prefix = f"AWSLogs/{account}/Config/{REGION}/{day.year}/{day.month}/{day.day}/ConfigHistory"
    path = os.path.join(out_dir, prefix)
    os.makedirs(path, exist_ok=True)

    files = random.randint(3, 6)  # 하루에 여러 번 로그가 전달되는 상황 재현
    for n in range(files):
        items = []
        for bucket in BUCKETS:
            for rule in RULES:
                if bucket == "my-dso-test" and rule == RULES[0]:
                    compliance = "NON_COMPLIANT" if random.random() < 0.5 else "COMPLIANT"
                else:
                    compliance = "NON_COMPLIANT" if random.random() < 0.05 else "COMPLIANT"
                items.append(make_item(account, day, bucket, rule, compliance))

        body = {"fileVersion": "1.0", "configurationItems": items}
        stamp = f"{day.year:04d}{day.month:02d}{day.day:02d}T{n:02d}0000Z"
        name = (f"{account}_Config_{REGION}_ConfigHistory_AWS_Config_ResourceCompliance_"  # Windows 호환: 파일명에 콜론(:) 사용 안 함
                f"{stamp}_{uuid.uuid4().hex[:8]}.json.gz")
        with gzip.open(os.path.join(path, name), "wt", encoding="utf-8") as f:
            f.write(json.dumps(body) + "\n")  # Athena JSON SerDe는 한 줄 = 한 레코드
    return prefix, files


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--account", required=True, help="AWS 계정 ID (12자리)")
    p.add_argument("--days", type=int, default=20, help="어제부터 과거 며칠치를 만들지")
    p.add_argument("--today-only", action="store_true", help="오늘(UTC) 1일치만 생성")
    p.add_argument("--out", default="dummy", help="출력 폴더")
    a = p.parse_args()

    today = datetime.now(timezone.utc).date()  # Config 경로 날짜는 UTC 기준
    if a.today_only:
        days = [today]
    else:
        days = [today - timedelta(days=i) for i in range(a.days, 0, -1)]

    for d in days:
        prefix, count = write_day(a.account, d, a.out)
        print(f"{prefix}  ({count} files)")


if __name__ == "__main__":
    main()
