import os, json, csv, io, time, urllib.request
import boto3
from botocore.exceptions import ClientError

s3   = boto3.client("s3")
sqs  = boto3.client("sqs")
ses  = boto3.client("ses")
ssm  = boto3.client("ssm")
ddb  = boto3.client("dynamodb")
idc  = boto3.client("identitystore")
sso  = boto3.client("sso-admin")

IDENTITY_STORE_ID  = os.environ["IDENTITY_STORE_ID"]
INSTANCE_ARN       = os.environ["INSTANCE_ARN"]
PERMISSION_SET_ARN = os.environ["PERMISSION_SET_ARN"]
TARGET_ACCOUNT_ID  = os.environ["TARGET_ACCOUNT_ID"]
SES_SENDER         = os.environ["SES_SENDER"]
SLACK_PARAM        = os.environ.get("SLACK_WEBHOOK_PARAM")
DDB_TABLE          = os.environ["DDB_TABLE"]
CSV_BUCKET         = os.environ["CSV_BUCKET"]
CSV_PREFIX         = os.environ["CSV_PREFIX"]
ACCESS_PORTAL_URL  = os.environ.get("ACCESS_PORTAL_URL", "")
STUDENT_GROUP_NAME = os.environ.get("STUDENT_GROUP_NAME", "")

def _get_slack_url():
    if not SLACK_PARAM: return None
    try:
        p = ssm.get_parameter(Name=SLACK_PARAM, WithDecryption=True)
        return p["Parameter"]["Value"]
    except ClientError:
        return None

SLACK_WEBHOOK_URL = _get_slack_url()

def log(msg): print(msg, flush=True)

def get_existing_user(username=None, email=None):
    # Filter by UserName first (fast), fallback to email
    if username:
        try:
            resp = idc.list_users(
                IdentityStoreId=IDENTITY_STORE_ID,
                Filters=[{"AttributePath":"UserName","AttributeValue":username}],
                MaxResults=1
            )
            if resp.get("Users"): return resp["Users"][0]
        except ClientError as e: log(f"ListUsers by username error: {e}")

    if email:
        try:
            resp = idc.list_users(
                IdentityStoreId=IDENTITY_STORE_ID,
                Filters=[{"AttributePath":"Emails.Value","AttributeValue":email}],
                MaxResults=1
            )
            if resp.get("Users"): return resp["Users"][0]
        except ClientError as e: log(f"ListUsers by email error: {e}")

    return None

def ensure_user(first, last, username, email):
    u = get_existing_user(username=username, email=email)
    if u: return u["UserId"]
    # Create user in Identity Center internal directory
    resp = idc.create_user(
        IdentityStoreId=IDENTITY_STORE_ID,
        UserName=username,
        Name={"GivenName": first, "FamilyName": last},
        DisplayName=f"{first} {last}",
        Emails=[{"Value": email, "Primary": True}],
        UserType="Student"
    )
    return resp["UserId"]

def ensure_group_membership(user_id, group_name):
    if not group_name: return
    # Find group by DisplayName
    try:
        groups = idc.list_groups(IdentityStoreId=IDENTITY_STORE_ID,
                                 Filters=[{"AttributePath":"DisplayName","AttributeValue":group_name}],
                                 MaxResults=1)
        if not groups.get("Groups"): return
        gid = groups["Groups"][0]["GroupId"]
        # Create membership (no easy idempotency API; attempt and ignore duplicates)
        try:
            idc.create_group_membership(IdentityStoreId=IDENTITY_STORE_ID,
                                        GroupId=gid, MemberId={"UserId": user_id})
        except ClientError as e:
            if e.response["Error"]["Code"] != "ConflictException":
                raise
    except ClientError as e:
        log(f"ensure_group_membership error: {e}")

def assignment_wait(instance_arn, status_arn, timeout=90):
    start = time.time()
    while time.time() - start < timeout:
        r = sso.describe_account_assignment_creation_status(
            InstanceArn=instance_arn,
            AccountAssignmentCreationRequestId=status_arn
        )
        st = r["AccountAssignmentCreationStatus"]["Status"]
        if st in ("SUCCEEDED","FAILED"):
            return st
        time.sleep(3)
    return "TIMEOUT"

def ensure_account_assignment(user_id):
    try:
        r = sso.create_account_assignment(
            InstanceArn=INSTANCE_ARN,
            TargetId=TARGET_ACCOUNT_ID,
            TargetType="AWS_ACCOUNT",
            PermissionSetArn=PERMISSION_SET_ARN,
            PrincipalType="USER",
            PrincipalId=user_id
        )
        req_id = r["AccountAssignmentCreationStatus"]["RequestId"]
        st = assignment_wait(INSTANCE_ARN, req_id)
        log(f"Assignment status: {st}")
        return st == "SUCCEEDED"
    except ClientError as e:
        # If already exists, AWS returns ConflictException
        if e.response["Error"]["Code"] == "ConflictException":
            log("Assignment already exists")
            return True
        log(f"ensure_account_assignment error: {e}")
        return False

def get_ddb(username):
    r = ddb.get_item(TableName=DDB_TABLE, Key={"username":{"S":username}})
    return r.get("Item")

def put_ddb(username, status, details=None):
    item = {
        "username": {"S": username},
        "status":   {"S": status},
        "ts":       {"N": str(int(time.time()))}
    }
    if details:
        item["details"] = {"S": json.dumps(details)}
    ddb.put_item(TableName=DDB_TABLE, Item=item)

def notify_slack(text):
    if not SLACK_WEBHOOK_URL: return
    try:
        data = json.dumps({"text": text}).encode("utf-8")
        req  = urllib.request.Request(SLACK_WEBHOOK_URL, data=data, headers={"Content-Type":"application/json"})
        urllib.request.urlopen(req, timeout=5).read()
    except Exception as e:
        log(f"Slack notify error: {e}")

def notify_email(first, username, email):
    body_html = f"""
    <p>Hello {first},</p>
    <p>Your AWS Lab user <b>{username}</b> is ready.</p>
    <p>Sign in: <a href="{ACCESS_PORTAL_URL}">{ACCESS_PORTAL_URL}</a></p>
    <p><b>First-time steps</b>:</p>
    <ol>
      <li>Verify email / set password (if prompted)</li>
      <li>Enroll MFA</li>
      <li>Choose account <b>{TARGET_ACCOUNT_ID}</b> and role <b>CustomPolicy</b></li>
    </ol>
    <p>– Web Forx Technology Limited</p>
    """
    try:
        ses.send_email(
            Source=SES_SENDER,
            Destination={"ToAddresses":[email]},
            Message={
                "Subject": {"Data":"Your AWS Lab Access"},
                "Body": {
                    "Html": {"Data": body_html},
                    "Text": {"Data": f"Portal: {ACCESS_PORTAL_URL}\nUsername: {username}\nAccount: {TARGET_ACCOUNT_ID}\nRole: CustomPolicy"}
                }
            }
        )
    except ClientError as e:
        log(f"SES send_email error: {e}")

def process_csv_record(row):
    # Expect header: student_id,first_name,last_name,username,email
    sid   = row.get("student_id","").strip()
    first = row.get("first_name","").strip()
    last  = row.get("last_name","").strip()
    user  = row.get("username","").strip()
    email = row.get("email","").strip()

    if not (first and last and user and email):
        raise ValueError(f"Missing required fields in row: {row}")

    if get_ddb(user) and get_ddb(user).get("status",{}).get("S") == "COMPLETED":
        log(f"Skip {user}: already COMPLETED")
        return

    user_id = ensure_user(first, last, user, email)
    ensure_group_membership(user_id, STUDENT_GROUP_NAME)
    ok = ensure_account_assignment(user_id)

    if ok:
        put_ddb(user, "COMPLETED", {"email":email})
        notify_email(first, user, email)
        notify_slack(f"✅ Provisioned {user} ({email}) in account {TARGET_ACCOUNT_ID}")
    else:
        put_ddb(user, "FAILED", {"email":email})
        notify_slack(f"❌ Failed provisioning {user} ({email})")

def fetch_csv_from_s3(bucket, key):
    obj = s3.get_object(Bucket=bucket, Key=key)
    data = obj["Body"].read()
    text = data.decode("utf-8")
    return list(csv.DictReader(io.StringIO(text)))

def handler(event, context):
    # SQS event with S3 notification(s)
    for rec in event.get("Records", []):
        body = json.loads(rec["body"])
        for s3rec in body.get("Records", []):
            b = s3rec["s3"]["bucket"]["name"]
            k = s3rec["s3"]["object"]["key"]
            if not k.startswith(CSV_PREFIX):
                log(f"Ignoring key {k}")
                continue
            rows = fetch_csv_from_s3(b, k)
            for row in rows:
                try:
                    process_csv_record(row)
                except Exception as e:
                    log(f"Row error: {e}; row={row}")
    return {"status":"ok"}
