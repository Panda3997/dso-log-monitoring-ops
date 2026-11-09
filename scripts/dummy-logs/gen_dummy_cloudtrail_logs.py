#!/usr/bin/env python3
"""
AWS CloudTrail 형식의 더미 로그를 실제와 같은 날짜별 S3 경로 구조로 생성합니다.
CloudTrail 경로는 Config와 달리 월/일에 0을 붙입니다 (예: 2026/10/01).

사용 예:
  python gen_dummy_cloudtrail_logs.py --account 123456789012                                 # 어제부터 과거 20일치
  python gen_dummy_cloudtrail_logs.py --account 123456789012 --today-only --out ct_today     # 오늘(UTC) 1일치
"""
import argparse
import gzip
import json
import os
import random
import uuid
from datetime import datetime, timedelta, timezone

REGION = "ap-southeast-2"

# (eventSource, eventName, readOnly)
NORMAL_EVENTS = [
    ("s3.amazonaws.com", "GetBucketAcl", True),
    ("s3.amazonaws.com", "ListBuckets", True),
    ("ec2.amazonaws.com", "DescribeInstances", True),
    ("iam.amazonaws.com", "ListRoles", True),
    ("config.amazonaws.com", "DescribeConfigRules", True),
    ("logs.amazonaws.com", "DescribeLogGroups", True),
    ("sts.amazonaws.com", "AssumeRole", True),
    ("lambda.amazonaws.com", "ListFunctions20150331", True),
]
SUSPICIOUS_EVENTS = [
    ("iam.amazonaws.com", "ListUsers", True),
    ("iam.amazonaws.com", "GetUserPolicy", True),
    ("s3.amazonaws.com", "GetBucketPolicy", True),
    ("iam.amazonaws.com", "CreateAccessKey", False),
    ("s3.amazonaws.com", "PutBucketPolicy", False),
]
USERS = ["dso-admin", "dso-operator"]


def make_record(account, t, event, user, error=None, ip=None):
    source, name, read_only = event
    rec = {
        "eventVersion": "1.09",
        "userIdentity": {
            "type": "IAMUser",
            "principalId": "AIDA" + uuid.uuid4().hex[:16].upper(),
            "arn": f"arn:aws:iam::{account}:user/{user}",
            "accountId": account,
            "userName": user,
        },
        "eventTime": t.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "eventSource": source,
        "eventName": name,
        "awsRegion": REGION,
        "sourceIPAddress": ip or f"203.0.113.{random.randint(10, 20)}",
        "userAgent": "aws-cli/2.17.0",
        "requestParameters": None,
        "responseElements": None,
        "requestID": str(uuid.uuid4()),
        "eventID": str(uuid.uuid4()),
        "readOnly": read_only,
        "eventType": "AwsApiCall",
        "managementEvent": True,
        "recipientAccountId": account,
    }
    if error:
        rec["errorCode"] = error
        rec["errorMessage"] = "User is not authorized to perform this operation"
    return rec


def write_day(account, day, out_dir, spike_hour=None):
    # CloudTrail 경로는 월/일에 0을 붙임 (예: 2026/10/01)
    prefix = f"AWSLogs/{account}/CloudTrail/{REGION}/{day.year:04d}/{day.month:02d}/{day.day:02d}"
    path = os.path.join(out_dir, prefix)
    os.makedirs(path, exist_ok=True)

    files = 0
    total = 0
    for hour in range(24):
        records = []
        count = random.randint(5, 25)
        for _ in range(count):
            t = datetime(day.year, day.month, day.day, hour, random.randint(0, 59),
                         random.randint(0, 59), tzinfo=timezone.utc)
            records.append(make_record(account, t, random.choice(NORMAL_EVENTS), random.choice(USERS)))

        # 이상 징후: 특정 시간대에 낯선 IP에서 IAM/S3 API 호출 급증 + 권한 오류
        if hour == spike_hour:
            for _ in range(random.randint(300, 500)):
                t = datetime(day.year, day.month, day.day, hour, random.randint(0, 59),
                             random.randint(0, 59), tzinfo=timezone.utc)
                err = "AccessDenied" if random.random() < 0.4 else None
                records.append(make_record(account, t, random.choice(SUSPICIOUS_EVENTS),
                                           "dso-operator", error=err, ip="198.51.100.77"))

        records.sort(key=lambda r: r["eventTime"])
        stamp = f"{day.year:04d}{day.month:02d}{day.day:02d}T{hour:02d}{random.randint(0, 59):02d}Z"
        name = f"{account}_CloudTrail_{REGION}_{stamp}_{uuid.uuid4().hex[:16]}.json.gz"
        with gzip.open(os.path.join(path, name), "wt", encoding="utf-8") as f:
            f.write(json.dumps({"Records": records}) + "\n")
        files += 1
        total += len(records)
    return prefix, files, total


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--account", required=True, help="AWS 계정 ID (12자리)")
    p.add_argument("--days", type=int, default=20, help="어제부터 과거 며칠치를 만들지")
    p.add_argument("--today-only", action="store_true", help="오늘(UTC) 1일치만 생성")
    p.add_argument("--out", default="ct_dummy", help="출력 폴더")
    a = p.parse_args()

    today = datetime.now(timezone.utc).date()  # CloudTrail 경로 날짜는 UTC 기준
    if a.today_only:
        days = [today]
    else:
        days = [today - timedelta(days=i) for i in range(a.days, 0, -1)]

    spike_day = days[len(days) // 2] if len(days) > 1 else None  # 기간 중간 하루에 이상 징후 1회
    for d in days:
        spike = 9 if d == spike_day else None  # UTC 09시
        prefix, files, total = write_day(a.account, d, a.out, spike)
        mark = "  <- 이상 징후 포함 (UTC 09시)" if spike is not None else ""
        print(f"{prefix}  ({files} files, {total} events){mark}")


if __name__ == "__main__":
    main()
