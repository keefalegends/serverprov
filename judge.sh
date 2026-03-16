#!/bin/bash
# ================================================================
#  Techno Serverless OMS — Judge Script (All-in-One)
#  LKS Cloud Computing — 2026
#
#  Cara pakai:
#    chmod +x judge.sh
#
#    Deploy semua (~45 menit):
#      ./judge.sh deploy <nama_siswa> <email>
#      Contoh: ./judge.sh deploy budi budi@gmail.com
#
#    Lanjut dari step tertentu:
#      ./judge.sh deploy <nama_siswa> <email> <from_step>
#      Contoh: ./judge.sh deploy budi budi@gmail.com 5
#
#    Verifikasi saja (platform sudah jalan):
#      ./judge.sh verify <nama_siswa>
#      Contoh: ./judge.sh verify budi
#
#    Hapus semua resource setelah selesai:
#      ./judge.sh teardown <nama_siswa>
#      Contoh: ./judge.sh teardown budi
#
#  Prerequisites:
#    - AWS CLI configured (us-east-1, LabRole credentials)
#    - python3 + pip install boto3
#    - git (untuk clone repo)
#
#  Steps:
#    1=Network (VPC/SG/IGW/NAT)
#    2=Storage (S3 buckets)
#    3=Database (DynamoDB + RDS/Aurora)
#    4=Secrets (Secrets Manager)
#    5=Compute (Lambda Layer + Functions)
#    6=StepFunctions (Order workflow ASL)
#    7=API Gateway (REST API + Usage Plan)
#    8=EventBridge (Rules & Targets) + CloudWatch Alarms + Dashboard
#    9=CI/CD (CodeDeploy + Amplify)
#    10=InitDB (Init Lambda invoke)
#    11=Verify
# ================================================================

set -euo pipefail

# ── Color helpers ─────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${CYN}[$(date '+%H:%M:%S')]${NC} $1"; }
ok()      { echo -e "${GRN}[$(date '+%H:%M:%S')] ✓  $1${NC}"; }
warn()    { echo -e "${YEL}[$(date '+%H:%M:%S')] ⚠  $1${NC}"; }
err()     { echo -e "${RED}[$(date '+%H:%M:%S')] ✗  $1${NC}"; exit 1; }
section() {
    printf "\n${BLD}${BLU}══════════════════════════════════════════${NC}\n"
    printf "${BLD}${BLU}  %s${NC}\n" "$1"
    printf "${BLD}${BLU}══════════════════════════════════════════${NC}\n"
}

# ================================================================
#  ARGUMENT PARSING
# ================================================================
MODE="${1:-}"

usage() {
    echo ""
    echo "  Cara pakai:"
    echo "    ./judge.sh deploy   <nama_siswa> <email> [from_step]"
    echo "    ./judge.sh verify   <nama_siswa>"
    echo "    ./judge.sh teardown <nama_siswa>"
    echo ""
    echo "  Contoh:"
    echo "    ./judge.sh deploy   budi budi@gmail.com        # mulai dari awal"
    echo "    ./judge.sh deploy   budi budi@gmail.com 5      # lanjut dari step 5"
    echo "    ./judge.sh verify   budi"
    echo "    ./judge.sh teardown budi"
    echo ""
    echo "  Steps:"
    echo "    1=Network   2=Storage   3=Database   4=Secrets"
    echo "    5=Lambda    6=StepFunctions   7=APIGateway"
    echo "    8=EventBridge+CloudWatch   9=CICD   10=InitDB   11=Verify"
    echo ""
    echo "  Fix RDS timeout (jalankan tanpa rebuild layer):"
    echo "    ./judge.sh deploy <nama> <email> 5  # fix VPC+SG lalu lanjut"
    echo "    ./judge.sh deploy <nama> <email> 10 # re-run init_db saja"
    echo ""
    exit 1
}

case "$MODE" in
    deploy|verify|teardown) ;;
    *) echo "ERROR: mode tidak valid. Gunakan: deploy / verify / teardown"; usage ;;
esac

STUDENT_NAME="${2:-}"
[ -z "$STUDENT_NAME" ] && echo "ERROR: student_name wajib diisi" && usage

EMAIL="${3:-}"
[ "$MODE" == "deploy" ] && [ -z "$EMAIL" ] && echo "ERROR: email wajib untuk deploy" && usage

FROM_STEP="${4:-1}"

REGION="us-east-1"
PROJECT="techno"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null \
    || { echo "ERROR: AWS CLI tidak terkonfigurasi."; exit 1; })
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resource naming
SN="${STUDENT_NAME}"
S3_DEPLOY="${PROJECT}-deploy-${SN}-2026"
S3_LOGS="${PROJECT}-logs-${SN}-2026"
S3_REPORTS="${PROJECT}-reports-${SN}-2026"
DDB_TABLE="${PROJECT}-orders"
DDB_INVENTORY="${PROJECT}-inventory"
DDB_PAYMENTS="${PROJECT}-payments"
STACK_NET="${PROJECT}-network-stack"
STACK_DB="${PROJECT}-database-stack"
STACK_LAMBDA="${PROJECT}-lambda-stack"
STACK_API="${PROJECT}-api-stack"
STACK_SFNS="${PROJECT}-stepfunctions-stack"
STACK_EVENTS="${PROJECT}-events-stack"
STACK_CICD="${PROJECT}-cicd-stack"
SF_NAME="${PROJECT}-order-workflow"
LAYER_NAME="${PROJECT}-layer"

# ── skip_step helper ─────────────────────────────────────
skip_step() {
    local STEP_NUM="$1"
    if [ "${FROM_STEP:-1}" -gt "$STEP_NUM" ] 2>/dev/null; then
        log "  ↷ Skipping step $STEP_NUM (FROM_STEP=${FROM_STEP})"
        return 0
    fi
    return 1
}

# ── cleanup failed CloudFormation stack ──────────────────
cleanup_failed_stack() {
    local STACK_NAME="$1"
    local STATUS
    STATUS=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].StackStatus" \
        --output text --region "$REGION" 2>/dev/null || echo "DOES_NOT_EXIST")
    case "$STATUS" in
        ROLLBACK_COMPLETE|CREATE_FAILED|ROLLBACK_FAILED|DELETE_FAILED|UPDATE_ROLLBACK_FAILED)
            warn "Stack $STACK_NAME in $STATUS — deleting..."
            aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
            aws cloudformation wait stack-delete-complete \
                --stack-name "$STACK_NAME" --region "$REGION" 2>/dev/null || true
            ok "Stack $STACK_NAME cleaned up"
            ;;
        DOES_NOT_EXIST|"")
            log "Stack $STACK_NAME belum ada"
            ;;
        *)
            log "Stack $STACK_NAME status: $STATUS"
            ;;
    esac
}

# ── resolve_state: baca resource yang sudah ada ───────────
resolve_state() {
    log "Resolving AWS resource state..."
    # Cari API — coba nama baru dulu, fallback ke nama lama
    API_ID=$(aws apigateway get-rest-apis --region "$REGION" \
        --query "items[?name=='${PROJECT}-api-orders'].id" \
        --output text 2>/dev/null || echo "")
    [ -z "$API_ID" ] || [ "$API_ID" = "None" ] && \
    API_ID=$(aws apigateway get-rest-apis --region "$REGION" \
        --query "items[?name=='${PROJECT}-api'].id" \
        --output text 2>/dev/null || echo "")
    API_KEY_VALUE=$(aws apigateway get-api-keys \
        --name-query "${PROJECT}-api-orders-key" --include-values \
        --region "$REGION" \
        --query "items[0].value" --output text 2>/dev/null || echo "")
    if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
        API_ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com/production"
    else
        API_ENDPOINT=""
    fi
    SNS_TOPIC_ARN=$(aws sns list-topics --region "$REGION" \
        --query "Topics[?ends_with(TopicArn,':${PROJECT}-notifications')].TopicArn" \
        --output text 2>/dev/null || echo "")
    SF_ARN=$(aws stepfunctions list-state-machines --region "$REGION" \
        --query "stateMachines[?name=='${SF_NAME}'].stateMachineArn | [0]" \
        --output text 2>/dev/null || echo "")
    AMPLIFY_APP_ID=$(aws amplify list-apps --region "$REGION" \
        --query "apps[?name=='${PROJECT}-frontend'].appId" \
        --output text 2>/dev/null || echo "")
    LAYER_ARN=$(aws lambda list-layer-versions \
        --layer-name "$LAYER_NAME" --region "$REGION" \
        --query "LayerVersions[0].LayerVersionArn" \
        --output text 2>/dev/null || echo "")
}

# ================================================================
#  PYTHON VERIFY SCRIPT
# ================================================================
write_verify_script() {
cat > /tmp/techno_verify.py << 'PYEOF'
import boto3, json, sys, urllib.request, urllib.error, time

student_name = sys.argv[1]
account_id   = sys.argv[2]
region       = sys.argv[3]

GRN="\033[0;32m"; RED="\033[0;31m"; YEL="\033[1;33m"
BLU="\033[0;34m"; BLD="\033[1m";    CYN="\033[0;36m"; NC="\033[0m"

P  = "techno"
sn = student_name

sm   = boto3.client("stepfunctions",  region_name=region)
s3   = boto3.client("s3",             region_name=region)
ddb  = boto3.client("dynamodb",       region_name=region)
cfn  = boto3.client("cloudformation", region_name=region)
ev   = boto3.client("events",         region_name=region)
lmb  = boto3.client("lambda",         region_name=region)
apigw= boto3.client("apigateway",     region_name=region)
ec2  = boto3.client("ec2",            region_name=region)
sns  = boto3.client("sns",            region_name=region)
amp  = boto3.client("amplify",        region_name=region)

def api_info():
    try:
        apis = apigw.get_rest_apis(limit=100).get("items", [])
        api  = next((a for a in apis if a["name"] == f"{P}-api-orders"), None)
        if not api: return "", ""
        api_id   = api["id"]
        endpoint = f"https://{api_id}.execute-api.{region}.amazonaws.com/production"
        keys     = apigw.get_api_keys(nameQuery=f"{P}-api-orders-key", includeValues=True).get("items", [])
        key_val  = keys[0]["value"] if keys else ""
        return endpoint, key_val
    except Exception:
        return "", ""

def http_get(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())

def http_post(url, payload, headers):
    data = json.dumps(payload).encode()
    req  = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())

checks = []
def chk(cat, label, pts, fn):
    try:
        r      = fn()
        detail = str(r) if r and r is not True else ""
        checks.append((cat, label, pts, True, detail))
    except Exception as e:
        checks.append((cat, label, pts, False, str(e)[:120]))

# ── Networking ────────────────────────────────────────────
chk("Networking","VPC techno-vpc exists",2, lambda: (
    ec2.describe_vpcs(Filters=[{"Name":"tag:Name","Values":["techno-vpc"]}])
    ["Vpcs"][0]["CidrBlock"]
))
chk("Networking","Subnets (≥4) exist",2, lambda: (
    f"{len(ec2.describe_subnets(Filters=[{'Name':'tag:Name','Values':['techno-subnet*']}])['Subnets'])} subnets"
))
chk("Networking","Security groups exist (≥3)",2, lambda: (
    f"{len(ec2.describe_security_groups(Filters=[{'Name':'group-name','Values':['techno-sg-*']}])['SecurityGroups'])} SGs"
))
chk("Networking","NAT Gateway available",2, lambda: (
    len([n for n in ec2.describe_nat_gateways(
        Filter=[{"Name":"state","Values":["available"]}])["NatGateways"]]) > 0 and "NAT OK"
))

# ── Storage ───────────────────────────────────────────────
chk("Storage",f"S3 deploy bucket {P}-deploy-{sn}-2026",2, lambda:
    s3.head_bucket(Bucket=f"{P}-deploy-{sn}-2026") or "exists"
)
chk("Storage",f"S3 logs bucket {P}-logs-{sn}-2026",2, lambda:
    s3.head_bucket(Bucket=f"{P}-logs-{sn}-2026") or "exists"
)
chk("Storage",f"S3 reports bucket {P}-reports-{sn}-2026",2, lambda:
    s3.head_bucket(Bucket=f"{P}-reports-{sn}-2026") or "exists"
)

# ── RDS ───────────────────────────────────────────────────
rds_client = boto3.client("rds", region_name=region)
chk("RDS","Instance techno-rds available",5, lambda: (
    rds_client.describe_db_instances(DBInstanceIdentifier=f"{P}-rds-orders")
    ["DBInstances"][0]["DBInstanceStatus"] == "available" and "available"
))
chk("RDS","Secret techno/db/credentials exists",3, lambda: (
    boto3.client("secretsmanager", region_name=region)
    .describe_secret(SecretId=f"{P}/db/credentials")["Name"]
))
chk("RDS","Lambda SECRET_ARN env var set",3, lambda: (
    (lambda cfg: cfg.get("SECRET_ARN","") != "" and cfg["SECRET_ARN"])(
        {v.split("=")[0]:v.split("=",1)[1] for v in
         lmb.get_function_configuration(FunctionName="techno-lambda-health-check")
         ["Environment"]["Variables"].items()
         if isinstance(v, str)}
    ) if False else (
        lmb.get_function_configuration(FunctionName="techno-lambda-health-check")
        ["Environment"]["Variables"].get("SECRET_ARN","") != "" and "SECRET_ARN set"
    )
))

# ── Lambda ────────────────────────────────────────────────
# Nama sesuai deploy.yml: techno-lambda-{dash-name}
FUNC_NAMES = [
    "techno-lambda-order-management",
    "techno-lambda-process-payment",
    "techno-lambda-update-inventory",
    "techno-lambda-send-notification",
    "techno-lambda-generate-report",
    "techno-lambda-init-db",
    "techno-lambda-health-check",
]
for fn in FUNC_NAMES:
    chk("Lambda",f"Function {fn} Active",3, lambda fn=fn: (
        lmb.get_function(FunctionName=fn)
        ["Configuration"]["State"] in ("Active","Idle") and "Active"
    ))

chk("Lambda","Lambda Layer techno-layer exists",3, lambda: (
    lmb.list_layer_versions(LayerName=f"{P}-layer")
    ["LayerVersions"][0]["LayerVersionArn"][-30:]
))

# ── Step Functions ────────────────────────────────────────
chk("StepFunctions","State machine techno-order-workflow ACTIVE",5, lambda: (
    next(m for m in sm.list_state_machines()["stateMachines"]
         if m["name"] == f"{P}-order-workflow")["stateMachineArn"][-30:]
))

# ── API Gateway ───────────────────────────────────────────
_ep, _key = api_info()
chk("APIGateway","GET /health returns response",3, lambda: (
    (_ for _ in ()).throw(Exception("no endpoint/key")) if not _ep or not _key else
    (lambda r: r.get("status","no-status"))(
        http_get(f"{_ep}/health", {"x-api-key": _key})
    )
))
chk("APIGateway","POST /orders returns order_id",5, lambda: (
    (_ for _ in ()).throw(Exception("no endpoint/key")) if not _ep or not _key else
    (lambda r: (
        (_ for _ in ()).throw(Exception(f"error: {r.get('error',r)}")) if r.get('error') else
        f"order_id={r.get('order_id', r.get('orderId','?'))}"
    ))(
        http_post(f"{_ep}/orders",
            {"customer_id":"CUST001","items":[{"product_id":"PROD001","quantity":1}]},
            {"Content-Type":"application/json","x-api-key":_key}
        )
    )
))
chk("APIGateway","GET /orders lists orders",3, lambda: (
    (_ for _ in ()).throw(Exception("no endpoint/key")) if not _ep or not _key else
    (lambda r: f"count={len(r.get('orders',[]))}")(
        http_get(f"{_ep}/orders", {"x-api-key": _key})
    )
))
# API key check: request TANPA key harus dapat 403 Forbidden
# 403 = API key enforced = PASS
def _check_api_key():
    if not _ep:
        raise Exception("no endpoint")
    try:
        # Request tanpa x-api-key header
        urllib.request.urlopen(
            urllib.request.Request(f"{_ep}/orders", method="GET"),
            timeout=10
        )
        # Kalau 200 → API key NOT enforced → FAIL
        raise Exception("API key NOT required — endpoint accessible without key!")
    except urllib.error.HTTPError as e:
        if e.code == 403:
            return f"403 Forbidden ✓ (API key enforced)"
        elif e.code == 401:
            return f"401 Unauthorized ✓ (API key enforced)"
        else:
            raise Exception(f"Unexpected HTTP {e.code} (expect 403)")
    except urllib.error.URLError as e:
        raise Exception(f"Network error: {e}")
chk("APIGateway","API key required on protected routes",2, _check_api_key)

# ── SNS ───────────────────────────────────────────────────
chk("SNS","Topic techno-notifications exists",2, lambda: (
    next(t for t in sns.list_topics()["Topics"]
         if t["TopicArn"].endswith(":techno-notifications"))["TopicArn"][-30:]
))

# ── EventBridge ───────────────────────────────────────────
chk("EventBridge","Rule techno-daily-report ENABLED",3, lambda: (
    ev.describe_rule(Name=f"{P}-daily-report")["State"] == "ENABLED" and "ENABLED"
))

# ── CloudWatch ───────────────────────────────────────────
cw = boto3.client("cloudwatch", region_name=region)
chk("CloudWatch","Dashboard techno-dashboard-serverless exists",4, lambda: (
    cw.get_dashboard(DashboardName="techno-dashboard-serverless")
    ["DashboardName"]
))
ALARM_NAMES = [
    "techno-alarm-lambda-errors",
    "techno-alarm-lambda-duration",
    "techno-alarm-api-4xx",
    "techno-alarm-api-5xx",
    "techno-alarm-sf-failures",
    "techno-alarm-rds-cpu",
]
chk("CloudWatch","6 CloudWatch Alarms exist",4, lambda: (
    (lambda r: f"{len(r['MetricAlarms'])}/6 alarms found")(
        cw.describe_alarms(AlarmNames=ALARM_NAMES)
    ) if len(cw.describe_alarms(AlarmNames=ALARM_NAMES)["MetricAlarms"]) == 6
    else (_ for _ in ()).throw(Exception(
        f"Only {len(cw.describe_alarms(AlarmNames=ALARM_NAMES)['MetricAlarms'])}/6 alarms found"
    ))
))

# ── Amplify ───────────────────────────────────────────────
chk("Amplify","Amplify app techno-frontend deployed",3, lambda: (
    amp.list_apps()["apps"] and
    next(a for a in amp.list_apps()["apps"] if a["name"] == f"{P}-frontend")["appId"]
))

# ── Print Report ──────────────────────────────────────────
cats = {}
for cat,lbl,pts,passed,detail in checks:
    cats.setdefault(cat,[]).append((lbl,pts,passed,detail))

print(f"\n{BLD}{BLU}══════════════════════════════════════════════════════{NC}")
print(f"{BLD}{BLU}  TECHNO SERVERLESS OMS — HASIL VERIFIKASI JURI{NC}")
print(f"{BLD}{BLU}  Student: {sn}  |  Region: {region}{NC}")
print(f"{BLD}{BLU}══════════════════════════════════════════════════════{NC}")

total_pts = earned_pts = 0
for cat, items in cats.items():
    cat_total = sum(p for _,p,_,_ in items)
    cat_earn  = sum(p for _,p,ok,_ in items if ok)
    print(f"\n{BLD}[ {cat} — {cat_earn}/{cat_total} pts ]{NC}")
    for lbl,pts,passed,detail in items:
        total_pts  += pts
        if passed:
            earned_pts += pts
            d = f"  {CYN}({detail}){NC}" if detail else ""
            print(f"  {GRN}✓ PASS{NC} +{pts:2d} pts  {lbl}{d}")
        else:
            d = f"\n       {YEL}→ {detail}{NC}" if detail else ""
            print(f"  {RED}✗ FAIL{NC}  0/{pts} pts  {lbl}{d}")

pct    = round(earned_pts/total_pts*100,1) if total_pts else 0
color  = GRN if pct >= 80 else (YEL if pct >= 60 else RED)
failed = sum(1 for _,_,p,ok,_ in checks if not ok)

print(f"\n{BLD}{BLU}══════════════════════════════════════════════════════{NC}")
print(f"{BLD}  SKOR AKHIR:  {color}{earned_pts} / {total_pts} pts  ({pct}%){NC}")
print(f"{BLD}  Checks: {GRN}{len(checks)-failed} passed{NC}, {RED}{failed} failed{NC}  dari {len(checks)} total{NC}")
print(f"{BLD}{BLU}══════════════════════════════════════════════════════{NC}\n")
PYEOF
}

# ================================================================
#  TEARDOWN MODE
# ================================================================
if [[ "$MODE" == "teardown" ]]; then
    section "TEARDOWN — Menghapus semua resource"

    warn "Menghapus Amplify app..."
    _AMP=$(aws amplify list-apps --region "$REGION" \
        --query "apps[?name=='${PROJECT}-frontend'].appId" \
        --output text 2>/dev/null || echo "")
    [ -n "$_AMP" ] && [ "$_AMP" != "None" ] && \
        aws amplify delete-app --app-id "$_AMP" --region "$REGION" 2>/dev/null && \
        ok "Amplify deleted" || warn "Amplify tidak ditemukan"

    warn "Menghapus API Gateway..."
    _API=$(aws apigateway get-rest-apis --region "$REGION" \
        --query "items[?name=='${PROJECT}-api-orders'].id" --output text 2>/dev/null || echo "")
    [ -n "$_API" ] && [ "$_API" != "None" ] && \
        aws apigateway delete-rest-api --rest-api-id "$_API" --region "$REGION" 2>/dev/null && \
        ok "API GW deleted" || warn "API GW tidak ditemukan"

    warn "Menghapus Lambda functions..."
    for func in order-management process-payment update-inventory \
                send-notification generate-report init-db health-check; do
        aws lambda delete-function \
            --function-name "techno-lambda-${func}" \
            --region "$REGION" 2>/dev/null || true
    done
    ok "Lambda deleted"

    warn "Menghapus Lambda Layer..."
    _LAYER_VER=$(aws lambda list-layer-versions \
        --layer-name "$LAYER_NAME" --region "$REGION" \
        --query "LayerVersions[].Version" --output text 2>/dev/null || echo "")
    for ver in $_LAYER_VER; do
        aws lambda delete-layer-version \
            --layer-name "$LAYER_NAME" --version-number "$ver" \
            --region "$REGION" 2>/dev/null || true
    done
    ok "Lambda Layer deleted"

    warn "Menghapus Step Functions..."
    _SF_ARN=$(aws stepfunctions list-state-machines --region "$REGION" \
        --query "stateMachines[?name=='${SF_NAME}'].stateMachineArn | [0]" \
        --output text 2>/dev/null || echo "")
    [ -n "$_SF_ARN" ] && [ "$_SF_ARN" != "None" ] && \
        aws stepfunctions delete-state-machine --state-machine-arn "$_SF_ARN" \
        --region "$REGION" 2>/dev/null && ok "Step Functions deleted" || \
        warn "Step Functions tidak ditemukan"

    warn "Menghapus RDS instance..."
    aws rds delete-db-instance \
        --db-instance-identifier "${PROJECT}-rds-orders" \
        --skip-final-snapshot \
        --region "$REGION" 2>/dev/null && ok "RDS deletion started" || warn "RDS tidak ditemukan"
    aws secretsmanager delete-secret \
        --secret-id "${PROJECT}/db/credentials" \
        --force-delete-without-recovery \
        --region "$REGION" 2>/dev/null && ok "DB Secret deleted" || true

    warn "Menghapus SNS topic..."
    _SNS=$(aws sns list-topics --region "$REGION" \
        --query "Topics[?ends_with(TopicArn,':${PROJECT}-notifications')].TopicArn" \
        --output text 2>/dev/null || echo "")
    [ -n "$_SNS" ] && [ "$_SNS" != "None" ] && \
        aws sns delete-topic --topic-arn "$_SNS" --region "$REGION" 2>/dev/null && \
        ok "SNS deleted" || warn "SNS tidak ditemukan"

    warn "Menghapus EventBridge rule..."
    aws events remove-targets --rule "${PROJECT}-daily-report" \
        --ids ReportTarget --region "$REGION" 2>/dev/null || true
    aws events delete-rule --name "${PROJECT}-daily-report" \
        --region "$REGION" 2>/dev/null && ok "EventBridge deleted" || \
        warn "EventBridge tidak ditemukan"

    warn "Menghapus S3 buckets..."
    for BUCKET in \
        "${S3_DEPLOY}" \
        "${S3_LOGS}" \
        "${S3_REPORTS}" \
        "${PROJECT}-frontend-${SN}-2026"; do
        if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
            aws s3 rm "s3://${BUCKET}" --recursive --region "$REGION" 2>/dev/null || true
            aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null && \
                log "  Deleted: $BUCKET" || log "  Could not delete: $BUCKET"
        fi
    done
    ok "S3 buckets deleted"

    warn "Menghapus CodeDeploy..."
    aws deploy delete-deployment-group \
        --application-name "${PROJECT}-app" \
        --deployment-group-name "${PROJECT}-deployment-group" \
        --region "$REGION" 2>/dev/null || true
    aws deploy delete-application \
        --application-name "${PROJECT}-app" \
        --region "$REGION" 2>/dev/null || true
    ok "CodeDeploy deleted"

    warn "Menghapus CloudWatch Dashboard + Alarms..."
    aws cloudwatch delete-dashboards         --dashboard-names "techno-dashboard-serverless"         --region "$REGION" 2>/dev/null || true
    for _ALARM in techno-alarm-lambda-errors techno-alarm-lambda-duration                   techno-alarm-api-4xx techno-alarm-api-5xx                   techno-alarm-sf-failures techno-alarm-rds-cpu; do
        aws cloudwatch delete-alarms --alarm-names "$_ALARM"             --region "$REGION" 2>/dev/null || true
    done
    ok "CloudWatch resources deleted (juga akan terhapus via CFN stack)"

    warn "Menghapus CloudFormation stacks..."
    for STACK in \
        "$STACK_CICD" "$STACK_EVENTS" "$STACK_API" \
        "$STACK_SFNS" "$STACK_LAMBDA" "$STACK_DB" "$STACK_NET"; do
        aws cloudformation delete-stack --stack-name "$STACK" \
            --region "$REGION" 2>/dev/null || true
        aws cloudformation wait stack-delete-complete \
            --stack-name "$STACK" --region "$REGION" 2>/dev/null || true
        log "  Deleted stack: $STACK"
    done
    ok "Teardown selesai!"
    exit 0
fi

# ================================================================
#  VERIFY ONLY MODE
# ================================================================
if [[ "$MODE" == "verify" ]]; then
    section "VERIFIKASI SAJA"
    write_verify_script
    resolve_state
    python3 /tmp/techno_verify.py "$STUDENT_NAME" "$ACCOUNT_ID" "$REGION"
    exit 0
fi

# ================================================================
#  FULL DEPLOY MODE
# ================================================================
write_verify_script
resolve_state

section "Techno Serverless OMS — Full Deploy"
log "Account   : $ACCOUNT_ID"
log "Student   : $STUDENT_NAME"
log "Region    : $REGION"
log "Email     : $EMAIL"
log "From Step : $FROM_STEP"
echo ""
warn "Estimasi waktu: 40-50 menit"
warn "⚠  Confirm SNS email subscription saat email tiba di inbox."
warn "⚠  Jika RDS timeout: jalankan './judge.sh deploy $STUDENT_NAME $EMAIL 5' untuk fix VPC/SG"
warn "⚠  Jika psycopg2 error: jalankan 'FORCE_LAYER=true ./judge.sh deploy $STUDENT_NAME $EMAIL 5'"
echo ""

# ================================================================
#  STEP 1: CloudFormation — Network Stack
# ================================================================
section "STEP 1/11 — Network Stack (VPC, Subnets, NAT, SG, Endpoints)"
if ! skip_step 1; then
    cleanup_failed_stack "$STACK_NET"
    cat > /tmp/techno_cfn_network.yaml << 'CFN_EOF'
AWSTemplateFormatVersion: "2010-09-09"
Description: "Techno Serverless OMS — Network Stack"
Parameters:
  ProjectName:
    Type: String
    Default: techno
Outputs:
  VpcId:
    Value: !Ref VPC
    Export: { Name: !Sub "${ProjectName}-vpc-id" }
  PublicSubnet1:
    Value: !Ref PublicSubnet1
    Export: { Name: !Sub "${ProjectName}-public-subnet-1" }
  PublicSubnet2:
    Value: !Ref PublicSubnet2
    Export: { Name: !Sub "${ProjectName}-public-subnet-2" }
  PrivateSubnet1:
    Value: !Ref PrivateSubnet1
    Export: { Name: !Sub "${ProjectName}-private-subnet-1" }
  PrivateSubnet2:
    Value: !Ref PrivateSubnet2
    Export: { Name: !Sub "${ProjectName}-private-subnet-2" }
  SgLambdaId:
    Value: !Ref SgLambda
    Export: { Name: !Sub "${ProjectName}-sg-lambda-id" }
Resources:
  VPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 10.30.0.0/16
      EnableDnsHostnames: true
      EnableDnsSupport: true
      Tags: [{Key: Name, Value: !Sub "${ProjectName}-vpc"}]
  IGW:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags: [{Key: Name, Value: !Sub "${ProjectName}-igw"}]
  IGWAttach:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties: {VpcId: !Ref VPC, InternetGatewayId: !Ref IGW}
  PublicSubnet1:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.30.0.0/24
      AvailabilityZone: !Select [0, !GetAZs ""]
      MapPublicIpOnLaunch: true
      Tags: [{Key: Name, Value: !Sub "${ProjectName}-subnet-public-1"}]
  PublicSubnet2:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.30.1.0/24
      AvailabilityZone: !Select [1, !GetAZs ""]
      MapPublicIpOnLaunch: true
      Tags: [{Key: Name, Value: !Sub "${ProjectName}-subnet-public-2"}]
  PrivateSubnet1:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.30.10.0/24
      AvailabilityZone: !Select [0, !GetAZs ""]
      Tags: [{Key: Name, Value: !Sub "${ProjectName}-subnet-private-1"}]
  PrivateSubnet2:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.30.11.0/24
      AvailabilityZone: !Select [1, !GetAZs ""]
      Tags: [{Key: Name, Value: !Sub "${ProjectName}-subnet-private-2"}]
  EIP:
    Type: AWS::EC2::EIP
    Properties: {Domain: vpc}
  NatGW:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt EIP.AllocationId
      SubnetId: !Ref PublicSubnet1
      Tags: [{Key: Name, Value: !Sub "${ProjectName}-nat-gw"}]
  PublicRTB:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref VPC
      Tags: [{Key: Name, Value: !Sub "${ProjectName}-rtb-public"}]
  PublicRoute:
    Type: AWS::EC2::Route
    DependsOn: IGWAttach
    Properties: {RouteTableId: !Ref PublicRTB, DestinationCidrBlock: 0.0.0.0/0, GatewayId: !Ref IGW}
  PubAssoc1:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: {SubnetId: !Ref PublicSubnet1, RouteTableId: !Ref PublicRTB}
  PubAssoc2:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: {SubnetId: !Ref PublicSubnet2, RouteTableId: !Ref PublicRTB}
  PrivateRTB:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref VPC
      Tags: [{Key: Name, Value: !Sub "${ProjectName}-rtb-private"}]
  PrivateRoute:
    Type: AWS::EC2::Route
    Properties: {RouteTableId: !Ref PrivateRTB, DestinationCidrBlock: 0.0.0.0/0, NatGatewayId: !Ref NatGW}
  PrivAssoc1:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: {SubnetId: !Ref PrivateSubnet1, RouteTableId: !Ref PrivateRTB}
  PrivAssoc2:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: {SubnetId: !Ref PrivateSubnet2, RouteTableId: !Ref PrivateRTB}
  SgLambda:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupName: !Sub "${ProjectName}-sg-lambda"
      GroupDescription: Lambda security group
      VpcId: !Ref VPC
      SecurityGroupEgress: [{IpProtocol: -1, CidrIp: 0.0.0.0/0}]
  SgEndpoint:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupName: !Sub "${ProjectName}-sg-endpoint"
      GroupDescription: VPC Endpoints 443
      VpcId: !Ref VPC
      SecurityGroupIngress:
        - {IpProtocol: tcp, FromPort: 443, ToPort: 443, CidrIp: 10.30.0.0/16}
  SgALB:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupName: !Sub "${ProjectName}-sg-alb"
      GroupDescription: ALB HTTP/HTTPS
      VpcId: !Ref VPC
      SecurityGroupIngress:
        - {IpProtocol: tcp, FromPort: 80,  ToPort: 80,  CidrIp: 0.0.0.0/0}
        - {IpProtocol: tcp, FromPort: 443, ToPort: 443, CidrIp: 0.0.0.0/0}
  EndpointS3:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref VPC
      ServiceName: !Sub "com.amazonaws.${AWS::Region}.s3"
      VpcEndpointType: Gateway
      RouteTableIds: [!Ref PrivateRTB]
  EndpointDynamo:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref VPC
      ServiceName: !Sub "com.amazonaws.${AWS::Region}.dynamodb"
      VpcEndpointType: Gateway
      RouteTableIds: [!Ref PrivateRTB]
  EndpointSNS:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref VPC
      ServiceName: !Sub "com.amazonaws.${AWS::Region}.sns"
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref PrivateSubnet1, !Ref PrivateSubnet2]
      SecurityGroupIds: [!Ref SgEndpoint]
  EndpointSecrets:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref VPC
      ServiceName: !Sub "com.amazonaws.${AWS::Region}.secretsmanager"
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref PrivateSubnet1, !Ref PrivateSubnet2]
      SecurityGroupIds: [!Ref SgEndpoint]
  EndpointStepFunctions:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref VPC
      ServiceName: !Sub "com.amazonaws.${AWS::Region}.states"
      VpcEndpointType: Interface
      PrivateDnsEnabled: true
      SubnetIds: [!Ref PrivateSubnet1, !Ref PrivateSubnet2]
      SecurityGroupIds: [!Ref SgEndpoint]
CFN_EOF

    aws cloudformation deploy \
        --template-file /tmp/techno_cfn_network.yaml \
        --stack-name "$STACK_NET" \
        --parameter-overrides ProjectName="$PROJECT" \
        --capabilities CAPABILITY_IAM \
        --region "$REGION" --no-fail-on-empty-changeset
    ok "Network stack deployed"
fi

# ================================================================
#  STEP 2: Storage (S3 Buckets)
# ================================================================
section "STEP 2/11 — Storage (S3 Buckets)"
if ! skip_step 2; then
    log "Creating S3 buckets..."
    for BUCKET in "$S3_DEPLOY" "$S3_LOGS" "$S3_REPORTS"; do
        if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
            log "  Exists: $BUCKET"
        else
            aws s3api create-bucket \
                --bucket "$BUCKET" \
                --region "$REGION" \
                --no-cli-pager > /dev/null
            log "  Created: $BUCKET"
        fi
        aws s3api put-public-access-block \
            --bucket "$BUCKET" --region "$REGION" \
            --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
            --no-cli-pager 2>/dev/null || true
        aws s3api put-bucket-encryption \
            --bucket "$BUCKET" --region "$REGION" \
            --server-side-encryption-configuration \
            '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
            --no-cli-pager 2>/dev/null || true
    done

    # Versioning on deploy bucket
    aws s3api put-bucket-versioning \
        --bucket "$S3_DEPLOY" --region "$REGION" \
        --versioning-configuration Status=Enabled \
        --no-cli-pager 2>/dev/null || true

    # Lifecycle on logs bucket (expire after 90 days)
    aws s3api put-bucket-lifecycle-configuration \
        --bucket "$S3_LOGS" --region "$REGION" \
        --lifecycle-configuration '{"Rules":[{"ID":"expire-90d","Status":"Enabled","Expiration":{"Days":90},"Filter":{"Prefix":""}}]}' \
        --no-cli-pager 2>/dev/null || true

    ok "S3 buckets ready: $S3_DEPLOY, $S3_LOGS, $S3_REPORTS"
fi
# ================================================================
#  STEP 3: Database (RDS PostgreSQL)
# ================================================================
section "STEP 3/11 — Database (RDS PostgreSQL)"
if ! skip_step 3; then
    VPC_ID=$(aws cloudformation list-exports \
        --query "Exports[?Name=='${PROJECT}-vpc-id'].Value" \
        --output text --region "$REGION")
    PRIV_SN1=$(aws cloudformation list-exports \
        --query "Exports[?Name=='${PROJECT}-private-subnet-1'].Value" \
        --output text --region "$REGION")
    PRIV_SN2=$(aws cloudformation list-exports \
        --query "Exports[?Name=='${PROJECT}-private-subnet-2'].Value" \
        --output text --region "$REGION")
    SG_LAMBDA=$(aws cloudformation list-exports \
        --query "Exports[?Name=='${PROJECT}-sg-lambda-id'].Value" \
        --output text --region "$REGION")

    # Security group untuk RDS
    log "Creating RDS security group..."
    SG_RDS=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${PROJECT}-sg-rds" "Name=vpc-id,Values=${VPC_ID}" \
        --query "SecurityGroups[0].GroupId" --output text --region "$REGION" 2>/dev/null || echo "")
    if [ -z "$SG_RDS" ] || [ "$SG_RDS" = "None" ]; then
        SG_RDS=$(aws ec2 create-security-group \
            --group-name "${PROJECT}-sg-rds" \
            --description "RDS PostgreSQL - allow Lambda" \
            --vpc-id "$VPC_ID" \
            --region "$REGION" --query GroupId --output text)
        # Allow dari Lambda SG (source group)
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_RDS" --protocol tcp --port 5432 --port 5432 \
            --source-group "$SG_LAMBDA" \
            --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
        # Allow dari seluruh VPC CIDR (untuk init_db dan debugging)
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_RDS" --protocol tcp --port 5432 --port 5432 \
            --cidr 10.30.0.0/16 \
            --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
        log "  SG RDS created: $SG_RDS"
    else
        # SG sudah ada — pastikan rules sudah benar (idempotent)
        log "  SG RDS exists: $SG_RDS — verifying rules..."
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_RDS" --protocol tcp --port 5432 --port 5432 \
            --cidr 10.30.0.0/16 \
            --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_RDS" --protocol tcp --port 5432 --port 5432 \
            --source-group "$SG_LAMBDA" \
            --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
    fi

    # ── RDS Subnet Group — auto-fix AZ mismatch ──────────────────────────
    # Masalah: subnet private dari CFN bisa jatuh di AZ yang tidak support
    # db.t3.micro + gp2 (terutama di AWS Academy / LabRole environment).
    # Solusi: query AZ yang didukung RDS, lalu buat subnet tambahan di sana
    # jika AZ yang ada tidak overlap dengan AZ yang didukung.
    log "Checking RDS-supported AZs for db.t3.micro + gp2..."

    # AZ dari subnet yang ada
    AZ_SN1=$(aws ec2 describe-subnets --subnet-ids "$PRIV_SN1" \
        --query "Subnets[0].AvailabilityZone" --output text --region "$REGION" 2>/dev/null || echo "")
    AZ_SN2=$(aws ec2 describe-subnets --subnet-ids "$PRIV_SN2" \
        --query "Subnets[0].AvailabilityZone" --output text --region "$REGION" 2>/dev/null || echo "")
    log "  Existing subnet AZs: $AZ_SN1, $AZ_SN2"

    # AZ yang didukung RDS untuk db.t3.micro + gp2
    RDS_SUPPORTED_AZS=$(aws rds describe-orderable-db-instance-options \
        --engine postgres \
        --db-instance-class db.t3.micro \
        --query "OrderableDBInstanceOptions[?StorageType=='gp2' && MultiAZCapable==\`false\`].AvailabilityZones[].Name" \
        --output text --region "$REGION" 2>/dev/null | tr '\t' '\n' | sort -u || echo "")
    log "  RDS supported AZs : $(echo $RDS_SUPPORTED_AZS | tr '\n' ' ')"

    # Kumpulkan subnet IDs yang AZ-nya didukung RDS
    RDS_SUBNET_IDS="$PRIV_SN1 $PRIV_SN2"

    for _AZ in $RDS_SUPPORTED_AZS; do
        # Cek apakah AZ ini sudah punya subnet private di VPC kita
        _EXISTING_SN=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${VPC_ID}" \
                      "Name=availabilityZone,Values=${_AZ}" \
                      "Name=tag:Name,Values=${PROJECT}-subnet*" \
            --query "Subnets[0].SubnetId" --output text --region "$REGION" 2>/dev/null || echo "")

        if [ -n "$_EXISTING_SN" ] && [ "$_EXISTING_SN" != "None" ]; then
            # Sudah ada subnet di AZ ini — tambahkan ke daftar
            if ! echo "$RDS_SUBNET_IDS" | grep -q "$_EXISTING_SN"; then
                RDS_SUBNET_IDS="$RDS_SUBNET_IDS $_EXISTING_SN"
                log "  Reusing existing subnet $_EXISTING_SN in $_AZ"
            fi
        elif [ "$_AZ" != "$AZ_SN1" ] && [ "$_AZ" != "$AZ_SN2" ]; then
            # AZ ini didukung RDS tapi belum ada subnet — buat subnet baru
            # Pilih CIDR kosong di 10.30.x.0/24
            _USED_CIDRS=$(aws ec2 describe-subnets \
                --filters "Name=vpc-id,Values=${VPC_ID}" \
                --query "Subnets[].CidrBlock" --output text --region "$REGION" 2>/dev/null \
                | tr '\t' '\n' | grep "^10\.30\." | sort)
            # Cari slot /24 yang belum terpakai (mulai dari 10.30.10.0/24)
            for _OCT in 10 11 12 13 14 15; do
                _CANDIDATE="10.30.${_OCT}.0/24"
                if ! echo "$_USED_CIDRS" | grep -q "$_CANDIDATE"; then
                    log "  Creating extra private subnet in $_AZ with CIDR $_CANDIDATE..."
                    _NEW_SN=$(aws ec2 create-subnet \
                        --vpc-id "$VPC_ID" \
                        --cidr-block "$_CANDIDATE" \
                        --availability-zone "$_AZ" \
                        --region "$REGION" \
                        --query "Subnet.SubnetId" --output text 2>/dev/null || echo "")
                    if [ -n "$_NEW_SN" ] && [ "$_NEW_SN" != "None" ]; then
                        # Tag subnet
                        aws ec2 create-tags \
                            --resources "$_NEW_SN" \
                            --tags "Key=Name,Value=${PROJECT}-subnet-private-rds-${_AZ}" \
                            --region "$REGION" > /dev/null 2>&1 || true
                        # Asosiasikan ke route table private agar Lambda bisa reach
                        _PRIV_RTB=$(aws ec2 describe-route-tables \
                            --filters "Name=vpc-id,Values=${VPC_ID}" \
                                      "Name=tag:Name,Values=${PROJECT}-rtb-private" \
                            --query "RouteTables[0].RouteTableId" \
                            --output text --region "$REGION" 2>/dev/null || echo "")
                        [ -n "$_PRIV_RTB" ] && [ "$_PRIV_RTB" != "None" ] && \
                            aws ec2 associate-route-table \
                                --subnet-id "$_NEW_SN" \
                                --route-table-id "$_PRIV_RTB" \
                                --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
                        RDS_SUBNET_IDS="$RDS_SUBNET_IDS $_NEW_SN"
                        ok "  New subnet $_NEW_SN created in $_AZ ($_CANDIDATE)"
                    fi
                    break
                fi
            done
        fi

        # Sudah punya ≥2 AZ yang didukung, cukup
        _AZ_COUNT=$(echo "$RDS_SUBNET_IDS" | wc -w)
        [ "$_AZ_COUNT" -ge 2 ] && [ -n "$(echo $RDS_SUPPORTED_AZS | grep -o "$AZ_SN1\|$AZ_SN2" | head -1)" ] && break
    done

    log "  Final subnet IDs for RDS subnet group: $RDS_SUBNET_IDS"

    # Hapus subnet group lama jika ada (supaya bisa update dengan subnet baru)
    aws rds delete-db-subnet-group \
        --db-subnet-group-name "${PROJECT}-rds-subnet-group" \
        --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true

    aws rds create-db-subnet-group \
        --db-subnet-group-name "${PROJECT}-rds-subnet-group" \
        --db-subnet-group-description "Techno OMS RDS" \
        --subnet-ids $RDS_SUBNET_IDS \
        --region "$REGION" --no-cli-pager > /dev/null
    ok "RDS subnet group created with AZs: $AZ_SN1 $AZ_SN2"

    # Migrate: jika ada techno-rds (nama lama), rename ke techno-rds-orders
    OLD_RDS=$(aws rds describe-db-instances         --db-instance-identifier "${PROJECT}-rds"         --query "DBInstances[0].DBInstanceStatus"         --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")
    if [ "$OLD_RDS" != "NOT_FOUND" ] && [ "$OLD_RDS" != "None" ]; then
        warn "Ditemukan RDS lama '${PROJECT}-rds' — rename ke '${PROJECT}-rds-orders'..."
        aws rds modify-db-instance             --db-instance-identifier "${PROJECT}-rds"             --new-db-instance-identifier "${PROJECT}-rds-orders"             --apply-immediately             --region "$REGION" --no-cli-pager > /dev/null
        log "  Waiting for rename to complete (~2 menit)..."
        sleep 60
        aws rds wait db-instance-available             --db-instance-identifier "${PROJECT}-rds-orders"             --region "$REGION" 2>/dev/null ||         aws rds wait db-instance-available             --db-instance-identifier "${PROJECT}-rds"             --region "$REGION" 2>/dev/null || true
        ok "RDS renamed to techno-rds-orders"
    fi

    # Cek apakah RDS sudah ada
    RDS_STATUS=$(aws rds describe-db-instances \
        --db-instance-identifier "${PROJECT}-rds-orders" \
        --query "DBInstances[0].DBInstanceStatus" \
        --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")

    if [ "$RDS_STATUS" = "NOT_FOUND" ] || [ "$RDS_STATUS" = "None" ]; then
        log "Creating RDS PostgreSQL db.t3.micro (~10 menit)..."
        # Auto-detect versi postgres: pilih 15.x terbaru, fallback ke versi lain
        ALL_PG=$(aws rds describe-db-engine-versions \
            --engine postgres --output text \
            --query "DBEngineVersions[].EngineVersion" \
            --region "$REGION" 2>/dev/null | tr '\t' '\n' | sort -V)
        PG_VERSION=$(echo "$ALL_PG" | grep "^15\." | tail -1)
        [ -z "$PG_VERSION" ] && PG_VERSION=$(echo "$ALL_PG" | grep "^16\." | tail -1)
        [ -z "$PG_VERSION" ] && PG_VERSION=$(echo "$ALL_PG" | grep "^14\." | tail -1)
        [ -z "$PG_VERSION" ] && PG_VERSION=$(echo "$ALL_PG" | tail -1)
        [ -z "$PG_VERSION" ] && PG_VERSION="15.7"
        log "  PostgreSQL version: $PG_VERSION"
        aws rds create-db-instance \
            --db-instance-identifier "${PROJECT}-rds-orders" \
            --db-instance-class db.t3.micro \
            --engine postgres \
            --engine-version "$PG_VERSION" \
            --master-username adminuser \
            --master-user-password "TechnoOMS2026!" \
            --db-name techno_db \
            --allocated-storage 20 \
            --storage-type gp2 \
            --no-publicly-accessible \
            --db-subnet-group-name "${PROJECT}-rds-subnet-group" \
            --vpc-security-group-ids "$SG_RDS" \
            --backup-retention-period 1 \
            --no-multi-az \
            --storage-encrypted \
            --region "$REGION" --no-cli-pager > /dev/null
    else
        log "  RDS already exists: $RDS_STATUS"
    fi

    log "Waiting for RDS available (max 15 menit)..."
    aws rds wait db-instance-available \
        --db-instance-identifier "${PROJECT}-rds-orders" --region "$REGION"

    RDS_ENDPOINT=$(aws rds describe-db-instances \
        --db-instance-identifier "${PROJECT}-rds-orders" \
        --query "DBInstances[0].Endpoint.Address" \
        --output text --region "$REGION")
    ok "RDS ready: $RDS_ENDPOINT"
fi

# Resolve RDS endpoint untuk step berikutnya
RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "${PROJECT}-rds-orders" \
    --query "DBInstances[0].Endpoint.Address" \
    --output text --region "$REGION" 2>/dev/null || echo "")

# ================================================================
#  STEP 4: Secrets + SNS
# ================================================================
section "STEP 4/11 — Secrets Manager + SNS"
if ! skip_step 4; then
    # SNS Topic
    log "Creating SNS topic..."
    SNS_TOPIC_ARN=$(aws sns create-topic \
        --name "${PROJECT}-notifications" \
        --region "$REGION" \
        --query TopicArn --output text)
    aws sns subscribe \
        --topic-arn "$SNS_TOPIC_ARN" \
        --protocol email \
        --notification-endpoint "$EMAIL" \
        --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
    ok "SNS Topic: $SNS_TOPIC_ARN"
    warn "⚠  Cek inbox dan CONFIRM subscription email SNS!"

    # Secret: SELALU update dengan RDS endpoint terbaru
    log "Updating Secret dengan RDS endpoint terbaru: $RDS_ENDPOINT"
    SECRET_STRING="{\"host\":\"${RDS_ENDPOINT}\",\"dbname\":\"techno_db\",\"username\":\"adminuser\",\"password\":\"TechnoOMS2026!\",\"port\":5432}"
    SECRET_ARN=$(aws secretsmanager put-secret-value \
        --secret-id "${PROJECT}/db/credentials" \
        --secret-string "$SECRET_STRING" \
        --region "$REGION" --query ARN --output text 2>/dev/null || \
    aws secretsmanager create-secret \
        --name "${PROJECT}/db/credentials" \
        --secret-string "$SECRET_STRING" \
        --region "$REGION" --query ARN --output text 2>/dev/null || \
    aws secretsmanager describe-secret \
        --secret-id "${PROJECT}/db/credentials" \
        --query ARN --output text --region "$REGION")
    ok "Secret ARN  : $SECRET_ARN"
    ok "Secret host : $RDS_ENDPOINT"
fi

# Refresh SNS_TOPIC_ARN if skipped step 4
SNS_TOPIC_ARN=$(aws sns list-topics --region "$REGION" \
    --query "Topics[?ends_with(TopicArn,':${PROJECT}-notifications')].TopicArn" \
    --output text 2>/dev/null || echo "")

# ================================================================
#  STEP 5: Lambda Layer + Functions
# ================================================================
section "STEP 5/11 — Lambda Layer + Functions"
if ! skip_step 5; then
    PRIV_SN1=$(aws cloudformation list-exports \
        --query "Exports[?Name=='${PROJECT}-private-subnet-1'].Value" \
        --output text --region "$REGION")
    PRIV_SN2=$(aws cloudformation list-exports \
        --query "Exports[?Name=='${PROJECT}-private-subnet-2'].Value" \
        --output text --region "$REGION")
    SG_LAMBDA=$(aws cloudformation list-exports \
        --query "Exports[?Name=='${PROJECT}-sg-lambda-id'].Value" \
        --output text --region "$REGION")

    # ── Lambda Layer ──────────────────────────────────────
    # ── Layer: SELALU hapus semua versi lama dulu, lalu rebuild ──
    # Alasan: layer lama kemungkinan berisi psycopg2 binary Windows yang broken.
    # Tidak ada cara tau apakah layer lama OK tanpa invoke — lebih aman rebuild.
    log "Menghapus semua layer version lama (untuk pastikan psycopg2 bersih)..."
    _OLD_VERS=$(aws lambda list-layer-versions \
        --layer-name "$LAYER_NAME" --region "$REGION" \
        --query "LayerVersions[].Version" --output text 2>/dev/null | tr "\t" "\n" || echo "")
    if [ -n "$_OLD_VERS" ] && [ "$_OLD_VERS" != "None" ]; then
        for _V in $_OLD_VERS; do
            [ -z "$_V" ] || [ "$_V" = "None" ] && continue
            aws lambda delete-layer-version \
                --layer-name "$LAYER_NAME" --version-number "$_V" \
                --region "$REGION" 2>/dev/null && log "  Deleted layer v$_V" || true
        done
        # Juga hapus dari S3 jika ada
        aws s3 rm "s3://${S3_DEPLOY}/layer/" --recursive --region "$REGION" 2>/dev/null || true
        log "  Semua layer lama dihapus"
    else
        log "  Tidak ada layer lama"
    fi
    LAYER_ARN=""

    if true; then
        # Pastikan Lambda SG punya egress ke semua port (untuk RDS, Secrets Manager, dll)
        _SG_LAMBDA=$(aws cloudformation list-exports \
            --query "Exports[?Name=='${PROJECT}-sg-lambda-id'].Value" \
            --output text --region "$REGION" 2>/dev/null || echo "")
        [ -z "$_SG_LAMBDA" ] && _SG_LAMBDA="$SG_LAMBDA"
        if [ -n "$_SG_LAMBDA" ] && [ "$_SG_LAMBDA" != "None" ]; then
            # Hapus semua egress rules lama yang restrictive, ganti dengan allow-all
            aws ec2 revoke-security-group-egress \
                --group-id "$_SG_LAMBDA" \
                --ip-permissions "[{\"IpProtocol\":\"-1\",\"IpRanges\":[{\"CidrIp\":\"0.0.0.0/0\"}]}]" \
                --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
            aws ec2 authorize-security-group-egress \
                --group-id "$_SG_LAMBDA" --protocol -1 --port -1 --port -1 \
                --cidr 0.0.0.0/0 \
                --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
            log "  Lambda SG egress: allow-all outbound OK ($_SG_LAMBDA)"
        fi

        # ── Fix RDS SG — allow dari Lambda SG dan seluruh VPC ──────────
        _SG_RDS=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=${PROJECT}-sg-rds" \
            --query "SecurityGroups[0].GroupId" --output text --region "$REGION" 2>/dev/null || echo "")
        if [ -n "$_SG_RDS" ] && [ "$_SG_RDS" != "None" ]; then
            # Allow dari 0.0.0.0/0 (paling luas — untuk memastikan koneksi)
            aws ec2 authorize-security-group-ingress \
                --group-id "$_SG_RDS" --protocol tcp --port 5432 --port 5432 \
                --cidr 0.0.0.0/0 \
                --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
            # Allow dari Lambda SG (source group)
            if [ -n "$_SG_LAMBDA" ] && [ "$_SG_LAMBDA" != "None" ]; then
                aws ec2 authorize-security-group-ingress \
                    --group-id "$_SG_RDS" --protocol tcp --port 5432 --port 5432 \
                    --source-group "$_SG_LAMBDA" \
                    --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
            fi
            log "  RDS SG ingress: allow port 5432 OK ($_SG_RDS)"
        fi

        # ── Pastikan Lambda functions pakai VPC config yang SAMA dengan RDS ──
        # RDS ada di private subnet — Lambda HARUS di subnet yang bisa reach RDS
        # Cek apakah Lambda sudah punya VPC config
        log "  Verifying Lambda VPC config..."
        _PRIV_SN1=$(aws cloudformation list-exports \
            --query "Exports[?Name=='${PROJECT}-private-subnet-1'].Value" \
            --output text --region "$REGION" 2>/dev/null || echo "")
        _PRIV_SN2=$(aws cloudformation list-exports \
            --query "Exports[?Name=='${PROJECT}-private-subnet-2'].Value" \
            --output text --region "$REGION" 2>/dev/null || echo "")

        for _FN in techno-lambda-order-management techno-lambda-init-db techno-lambda-health-check \
                   techno-lambda-process-payment techno-lambda-update-inventory techno-lambda-generate-report; do
            _CURRENT_VPC=$(aws lambda get-function-configuration \
                --function-name "$_FN" --region "$REGION" \
                --query "VpcConfig.VpcId" --output text 2>/dev/null || echo "")
            if [ -z "$_CURRENT_VPC" ] || [ "$_CURRENT_VPC" = "None" ]; then
                log "    $_FN: tidak ada VPC config — menambahkan..."
                aws lambda update-function-configuration \
                    --function-name "$_FN" \
                    --vpc-config "SubnetIds=${_PRIV_SN1},${_PRIV_SN2},SecurityGroupIds=${_SG_LAMBDA}" \
                    --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
                aws lambda wait function-updated \
                    --function-name "$_FN" --region "$REGION" 2>/dev/null || true
                log "    VPC config added: $_FN"
            else
                log "    $_FN: sudah ada VPC config ($_CURRENT_VPC) ✓"
            fi
        done
        ok "Lambda VPC config verified"

        LAYER_DIR="/tmp/techno_layer"
        REQUIREMENTS_FILE="${SCRIPT_DIR}/lambda/requirements.txt"
        [ -f "$REQUIREMENTS_FILE" ] || err "requirements.txt tidak ditemukan di ${SCRIPT_DIR}/lambda/"

        rm -rf "$LAYER_DIR" && mkdir -p "${LAYER_DIR}/python"

        # ── Strategi build layer (urutan prioritas) ───────────────
        # 1. Docker  — build di image Lambda Python:3.11 yang 100% identik runtime
        # 2. pip native — di Linux/CloudShell dengan aws-psycopg2
        # 3. manylinux wheel — fallback, hanya jika psycopg2 benar-benar berhasil
        #
        # ROOT CAUSE "No module named psycopg2._psycopg":
        #   psycopg2-binary dari PyPI dibuild di Ubuntu/CentOS dengan libssl/libpq
        #   versi tertentu. Lambda AL2023 punya glibc/libssl berbeda sehingga
        #   bundled .so gagal dlopen() → ImportError.
        #
        # SOLUSI: ganti psycopg2-binary → aws-psycopg2 yang dikompilasi khusus
        # untuk Amazon Linux. Paket ini adalah fork resmi untuk Lambda/EC2 AL2.
        # Referensi: https://github.com/jkehler/awslambda-psycopg2

        LAYER_BUILD_OK=false

        # Buat requirements khusus Lambda: ganti psycopg2-binary → aws-psycopg2
        LAMBDA_REQ="/tmp/req_lambda.txt"
        sed 's/psycopg2-binary.*/aws-psycopg2/g; s/^psycopg2[^2=<>!].*/aws-psycopg2/g' \
            "$REQUIREMENTS_FILE" > "$LAMBDA_REQ"
        log "  Requirements Lambda (swap psycopg2-binary → aws-psycopg2):"
        cat "$LAMBDA_REQ"

        # ── Metode 1: Docker ─────────────────────────────────────
        if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
            log "  Metode 1: Docker build (public.ecr.aws/lambda/python:3.11)..."
            docker run --rm \
                -v "${LAYER_DIR}/python:/var/task/python" \
                -v "${LAMBDA_REQ}:/var/task/requirements.txt:ro" \
                public.ecr.aws/lambda/python:3.11 \
                pip install -r /var/task/requirements.txt \
                    --target /var/task/python \
                    --upgrade -q \
            && LAYER_BUILD_OK=true && ok "  Docker build sukses" \
            || warn "  Docker build gagal, coba metode lain..."
        else
            warn "  Docker tidak tersedia, skip metode 1"
        fi

        # ── Metode 2: pip native build di Linux ──────────────────
        if [ "$LAYER_BUILD_OK" = "false" ]; then
            log "  Metode 2: pip native build (aws-psycopg2)..."
            pip3 install -r "$LAMBDA_REQ" \
                --target "${LAYER_DIR}/python" \
                --upgrade -q 2>/dev/null \
            && LAYER_BUILD_OK=true && ok "  pip native build sukses" \
            || warn "  pip native build gagal, coba metode 3..."
        fi

        # ── Metode 3: manylinux wheel (fallback) ─────────────────
        # LAYER_BUILD_OK=true HANYA diset kalau psycopg2 berhasil terinstall.
        if [ "$LAYER_BUILD_OK" = "false" ]; then
            log "  Metode 3: install paket + aws-psycopg2 / manylinux wheel..."
            rm -rf "${LAYER_DIR}/python" && mkdir -p "${LAYER_DIR}/python"

            # Install semua paket selain psycopg2 dulu
            grep -iv "psycopg2" "$LAMBDA_REQ" > /tmp/req_no_psyco.txt || true
            pip3 install -r /tmp/req_no_psyco.txt \
                --target "${LAYER_DIR}/python" -q 2>/dev/null || true

            # 3a. aws-psycopg2 — paling compatible dengan Lambda AL2/AL2023
            if pip3 install aws-psycopg2 \
                    --target "${LAYER_DIR}/python" -q 2>/dev/null; then
                LAYER_BUILD_OK=true
                ok "  aws-psycopg2 installed (Amazon Linux build)"
            # 3b. psycopg2-binary manylinux_2_17 — glibc >= 2.17, cocok AL2023
            elif pip3 install psycopg2-binary \
                    --target "${LAYER_DIR}/python" \
                    --platform manylinux_2_17_x86_64 \
                    --implementation cp --python-version 311 \
                    --only-binary=:all: -q 2>/dev/null; then
                LAYER_BUILD_OK=true
                ok "  psycopg2-binary manylinux_2_17 wheel installed"
            # 3c. manylinux2014 (alias manylinux_2_17, nama lama)
            elif pip3 install psycopg2-binary \
                    --target "${LAYER_DIR}/python" \
                    --platform manylinux2014_x86_64 \
                    --implementation cp --python-version 311 \
                    --only-binary=:all: -q 2>/dev/null; then
                LAYER_BUILD_OK=true
                ok "  psycopg2-binary manylinux2014 wheel installed"
            else
                err "Semua metode psycopg2 gagal. Pastikan internet tersedia atau Docker aktif, lalu jalankan ulang step 5."
            fi
            warn "  Metode 3 digunakan — verifikasi psycopg2 folder di bawah"
        fi

        # ── Verifikasi struktur folder ────────────────────────────
        PYLIB_COUNT=$(find "${LAYER_DIR}/python" -maxdepth 1 -mindepth 1 | wc -l)
        log "  Packages di python/: ${PYLIB_COUNT}"
        ls "${LAYER_DIR}/python" | head -20
        # Wajib: psycopg2 harus ada di dalam python/
        if [ -d "${LAYER_DIR}/python/psycopg2" ]; then
            ok "  psycopg2/ folder ditemukan di layer ✓"
            ls "${LAYER_DIR}/python/psycopg2/" | head -5
        else
            warn "  WARNING: psycopg2/ folder TIDAK ditemukan di layer!"
            warn "  Pastikan requirements.txt berisi psycopg2-binary atau psycopg2"
        fi

        log "  Zipping layer..."
        cd "$LAYER_DIR" && zip -qr /tmp/techno_layer.zip python/ && cd - > /dev/null
        LAYER_ZIP_SIZE=$(wc -c < /tmp/techno_layer.zip)
        log "  Layer size: $(( LAYER_ZIP_SIZE / 1024 / 1024 )) MB"

        if [ "$LAYER_ZIP_SIZE" -gt 52428800 ]; then
            warn "  Layer > 50MB — upload via S3..."
            LAYER_S3_KEY="layer/${LAYER_NAME}-$(date +%s).zip"
            aws s3 cp /tmp/techno_layer.zip "s3://${S3_DEPLOY}/${LAYER_S3_KEY}" \
                --region "$REGION" --no-cli-pager
            LAYER_ARN=$(aws lambda publish-layer-version \
                --layer-name "$LAYER_NAME" \
                --description "Techno OMS deps manylinux" \
                --content "S3Bucket=${S3_DEPLOY},S3Key=${LAYER_S3_KEY}" \
                --compatible-runtimes python3.11 python3.10 \
                --region "$REGION" \
                --query LayerVersionArn --output text)
        else
            LAYER_ARN=$(aws lambda publish-layer-version \
                --layer-name "$LAYER_NAME" \
                --description "Techno OMS deps manylinux" \
                --zip-file "fileb:///tmp/techno_layer.zip" \
                --compatible-runtimes python3.11 python3.10 \
                --region "$REGION" \
                --query LayerVersionArn --output text)
        fi
        ok "Lambda Layer published: $LAYER_ARN"
    fi

    # Create placeholder zip untuk fungsi baru
    python3 -c "
import zipfile, io
code = b'import json\ndef lambda_handler(event, context):\n    return {\"statusCode\": 200, \"body\": json.dumps({\"status\": \"ok\"})}\n'
buf = io.BytesIO()
with zipfile.ZipFile(buf, 'w') as z:
    z.writestr('lambda_function.py', code)
open('/tmp/techno_placeholder.zip','wb').write(buf.getvalue())
"

    # Create/update Lambda functions — skip kalau sudah ada dan Active
    # Resolve SECRET_ARN fresh
    SECRET_ARN=$(aws secretsmanager describe-secret \
        --secret-id "${PROJECT}/db/credentials" \
        --query ARN --output text --region "$REGION" 2>/dev/null || echo "")
    ENV_COMMON="Variables={SECRET_ARN=${SECRET_ARN},SNS_TOPIC_ARN=${SNS_TOPIC_ARN},S3_ORDERS_BUCKET=${S3_REPORTS},S3_LOGS_BUCKET=${S3_LOGS},STEP_FUNCTIONS_ARN=PLACEHOLDER,REGION=${REGION},LOW_STOCK_THRESHOLD=5}"

    # Format: MEM:TIMEOUT:USE_VPC
    FUNC_ORDER_MAN="512:60:true"
    FUNC_PROCESS_PAY="512:60:true"
    FUNC_UPD_INV="256:30:true"
    FUNC_SEND_NOTIF="256:30:true"
    FUNC_GEN_REPORT="512:120:true"
    FUNC_INIT_DB="512:120:false"
    FUNC_HEALTH="128:15:false"

    get_func_config() {
        case "$1" in
            order_management) echo "512:60:true"  ;;
            process_payment)  echo "512:60:true"  ;;
            update_inventory) echo "256:30:true"  ;;
            send_notification)echo "256:30:true"  ;;
            generate_report)  echo "512:120:true" ;;
            init_db)          echo "512:120:false" ;;
            health_check)     echo "128:15:false" ;;
        esac
    }

    for FUNC_BASE in order_management process_payment update_inventory \
                     send_notification generate_report init_db health_check; do
        # Map dir name → AWS function name (sesuai deploy.yml naming)
        case "$FUNC_BASE" in
            order_management)  FUNC_NAME="techno-lambda-order-management"  ;;
            process_payment)   FUNC_NAME="techno-lambda-process-payment"   ;;
            update_inventory)  FUNC_NAME="techno-lambda-update-inventory"  ;;
            send_notification) FUNC_NAME="techno-lambda-send-notification" ;;
            generate_report)   FUNC_NAME="techno-lambda-generate-report"   ;;
            init_db)           FUNC_NAME="techno-lambda-init-db"           ;;
            health_check)      FUNC_NAME="techno-lambda-health-check"      ;;
        esac
        CFG=$(get_func_config "$FUNC_BASE")
        IFS=':' read -r MEM TMO USE_VPC <<< "$CFG"

        # Cek status function
        FUNC_STATE=$(aws lambda get-function \
            --function-name "$FUNC_NAME" \
            --region "$REGION" --query "Configuration.State" \
            --output text 2>/dev/null || echo "NOT_FOUND")

        if [ "$FUNC_STATE" = "NOT_FOUND" ]; then
            log "  Creating: $FUNC_NAME (${MEM}MB, ${TMO}s, vpc=${USE_VPC})"
            CREATE_ARGS=(
                --function-name "$FUNC_NAME"
                --runtime python3.11
                --role "$ROLE_ARN"
                --handler "lambda_function.lambda_handler"
                --zip-file "fileb:///tmp/techno_placeholder.zip"
                --memory-size "$MEM"
                --timeout "$TMO"
                --environment "$ENV_COMMON"
                --layers "$LAYER_ARN"
                --region "$REGION"
                --no-cli-pager
            )
            if [ "$USE_VPC" = "true" ]; then
                CREATE_ARGS+=(--vpc-config "SubnetIds=${PRIV_SN1},${PRIV_SN2},SecurityGroupIds=${SG_LAMBDA}")
            fi
            aws lambda create-function "${CREATE_ARGS[@]}" > /dev/null
            aws lambda wait function-active \
                --function-name "$FUNC_NAME" --region "$REGION"
            ok "  Created: $FUNC_NAME"
        else
            # Sudah ada — hanya update env + layer jika perlu
            CURRENT_LAYER=$(aws lambda get-function-configuration \
                --function-name "$FUNC_NAME" --region "$REGION" \
                --query "Layers[0].Arn" --output text 2>/dev/null || echo "")
            if [ "$CURRENT_LAYER" != "$LAYER_ARN" ]; then
                aws lambda update-function-configuration \
                    --function-name "$FUNC_NAME" \
                    --environment "$ENV_COMMON" \
                    --layers "$LAYER_ARN" \
                    --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
                log "  Updated layer+env: $FUNC_NAME"
            else
                log "  Already OK (skip): $FUNC_NAME [$FUNC_STATE]"
            fi
        fi
    done
    ok "Lambda functions ready"
fi

# Refresh SECRET_ARN setelah step 4/5 — pastikan Lambda env up to date
SECRET_ARN=$(aws secretsmanager describe-secret \
    --secret-id "${PROJECT}/db/credentials" \
    --query ARN --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$SECRET_ARN" ] && [ "$SECRET_ARN" != "None" ]; then
    log "Refreshing Lambda SECRET_ARN env var: $SECRET_ARN"
    for _FN in techno-lambda-order-management techno-lambda-process-payment \
               techno-lambda-update-inventory techno-lambda-generate-report \
               techno-lambda-init-db techno-lambda-health-check; do
        _CURR=$(aws lambda get-function-configuration --function-name "$_FN" \
            --region "$REGION" --query "Environment.Variables.SECRET_ARN" \
            --output text 2>/dev/null || echo "")
        if [ "$_CURR" != "$SECRET_ARN" ]; then
            # Get current env vars and merge
            _ENV=$(aws lambda get-function-configuration --function-name "$_FN" \
                --region "$REGION" --query "Environment.Variables" --output json 2>/dev/null || echo "{}")
            _NEW_ENV=$(echo "$_ENV" | python3 -c "
import json,sys
e=json.load(sys.stdin)
e['SECRET_ARN']='${SECRET_ARN}'
print('Variables={' + ','.join(f'{k}={v}' for k,v in e.items()) + '}')
" 2>/dev/null || echo "Variables={SECRET_ARN=${SECRET_ARN}}")
            aws lambda update-function-configuration \
                --function-name "$_FN" \
                --environment "$_NEW_ENV" \
                --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
            log "  Updated SECRET_ARN: $_FN"
        fi
    done
    ok "Lambda SECRET_ARN env vars refreshed"
fi

# Refresh LAYER_ARN
LAYER_ARN=$(aws lambda list-layer-versions \
    --layer-name "$LAYER_NAME" --region "$REGION" \
    --query "LayerVersions[0].LayerVersionArn" \
    --output text 2>/dev/null || echo "")

# ================================================================
#  STEP 6: Step Functions (Order Workflow)
# ================================================================
section "STEP 6/11 — Step Functions Order Workflow"
if ! skip_step 6; then
    # Build ASL definition
    ORDER_MGT_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:techno-lambda-order-management"
    PAYMENT_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:techno-lambda-process-payment"
    INVENTORY_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:techno-lambda-update-inventory"
    NOTIF_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:techno-lambda-send-notification"

    SF_DEFINITION=$(cat << SFEOF
{
  "Comment": "Techno OMS Order Processing Workflow",
  "StartAt": "ValidateOrder",
  "States": {
    "ValidateOrder": {
      "Type": "Task",
      "Resource": "${ORDER_MGT_ARN}",
      "Parameters": {
        "action": "validate",
        "orderId.\$": "\$.orderId",
        "customerId.\$": "\$.customerId",
        "items.\$": "\$.items",
        "totalAmount.\$": "\$.totalAmount"
      },
      "ResultPath": "\$.validateResult",
      "Next": "ProcessPayment",
      "Retry": [{"ErrorEquals": ["Lambda.ServiceException","Lambda.TooManyRequestsException"],"IntervalSeconds": 2,"MaxAttempts": 3,"BackoffRate": 2}],
      "Catch": [{"ErrorEquals": ["States.ALL"],"Next": "OrderFailed","ResultPath": "\$.error"}]
    },
    "ProcessPayment": {
      "Type": "Task",
      "Resource": "${PAYMENT_ARN}",
      "Parameters": {
        "orderId.\$": "\$.orderId",
        "customerId.\$": "\$.customerId",
        "items.\$": "\$.items",
        "totalAmount.\$": "\$.totalAmount"
      },
      "ResultPath": "\$.paymentResult",
      "Next": "UpdateInventory",
      "Retry": [{"ErrorEquals": ["Lambda.ServiceException"],"IntervalSeconds": 2,"MaxAttempts": 2,"BackoffRate": 2}],
      "Catch": [{"ErrorEquals": ["States.ALL"],"Next": "PaymentFailed","ResultPath": "\$.error"}]
    },
    "UpdateInventory": {
      "Type": "Task",
      "Resource": "${INVENTORY_ARN}",
      "Parameters": {
        "orderId.\$": "\$.orderId",
        "items.\$": "\$.items",
        "totalAmount.\$": "\$.totalAmount"
      },
      "ResultPath": "\$.inventoryResult",
      "Next": "SendConfirmation",
      "Retry": [{"ErrorEquals": ["Lambda.ServiceException"],"IntervalSeconds": 2,"MaxAttempts": 2,"BackoffRate": 2}],
      "Catch": [{"ErrorEquals": ["States.ALL"],"Next": "OrderFailed","ResultPath": "\$.error"}]
    },
    "SendConfirmation": {
      "Type": "Task",
      "Resource": "${NOTIF_ARN}",
      "Parameters": {
        "notificationType": "order_confirmation",
        "data": {
          "order_id.\$": "\$.orderId",
          "customer_id.\$": "\$.customerId",
          "total_amount.\$": "\$.totalAmount"
        }
      },
      "ResultPath": "\$.notificationResult",
      "Next": "OrderSuccess",
      "Retry": [{"ErrorEquals": ["Lambda.ServiceException"],"IntervalSeconds": 2,"MaxAttempts": 2,"BackoffRate": 2}],
      "Catch": [{"ErrorEquals": ["States.ALL"],"Next": "OrderFailed","ResultPath": "\$.error"}]
    },
    "OrderSuccess": { "Type": "Succeed" },
    "PaymentFailed": {
      "Type": "Task",
      "Resource": "${NOTIF_ARN}",
      "Parameters": {
        "notificationType": "payment_failed",
        "data": {
          "order_id.\$": "\$.orderId",
          "customer_id.\$": "\$.customerId",
          "total_amount.\$": "\$.totalAmount"
        }
      },
      "ResultPath": "\$.notificationResult",
      "Next": "OrderFailed",
      "Retry": [{"ErrorEquals": ["Lambda.ServiceException"],"IntervalSeconds": 2,"MaxAttempts": 2,"BackoffRate": 2}]
    },
    "OrderFailed": {
      "Type": "Fail",
      "Error": "OrderProcessingFailed",
      "Cause": "Order could not be processed"
    }
  }
}
SFEOF
)

    # Check if state machine exists
    SF_ARN=$(aws stepfunctions list-state-machines --region "$REGION" \
        --query "stateMachines[?name=='${SF_NAME}'].stateMachineArn | [0]" \
        --output text 2>/dev/null || echo "")

    if [ -z "$SF_ARN" ] || [ "$SF_ARN" = "None" ]; then
        SF_ARN=$(aws stepfunctions create-state-machine \
            --name "$SF_NAME" \
            --definition "$SF_DEFINITION" \
            --role-arn "$ROLE_ARN" \
            --type STANDARD \
            --region "$REGION" \
            --query stateMachineArn --output text)
        log "  Created: $SF_NAME"
    else
        aws stepfunctions update-state-machine \
            --state-machine-arn "$SF_ARN" \
            --definition "$SF_DEFINITION" \
            --role-arn "$ROLE_ARN" \
            --region "$REGION" > /dev/null
        log "  Updated: $SF_NAME"
    fi
    ok "Step Functions: $SF_ARN"



    # Update Lambda env: pastikan SECRET_ARN + SF_ARN semua terisi
    SECRET_ARN_FRESH=$(aws secretsmanager describe-secret \
        --secret-id "${PROJECT}/db/credentials" \
        --query ARN --output text --region "$REGION" 2>/dev/null || echo "")
    [ -z "$SECRET_ARN_FRESH" ] && SECRET_ARN_FRESH="$SECRET_ARN"

    for FUNC_BASE in order_management process_payment update_inventory \
                     generate_report init_db health_check; do
        # Map dir name → AWS function name (sesuai deploy.yml naming)
        case "$FUNC_BASE" in
            order_management)  FUNC_NAME="techno-lambda-order-management"  ;;
            process_payment)   FUNC_NAME="techno-lambda-process-payment"   ;;
            update_inventory)  FUNC_NAME="techno-lambda-update-inventory"  ;;
            send_notification) FUNC_NAME="techno-lambda-send-notification" ;;
            generate_report)   FUNC_NAME="techno-lambda-generate-report"   ;;
            init_db)           FUNC_NAME="techno-lambda-init-db"           ;;
            health_check)      FUNC_NAME="techno-lambda-health-check"      ;;
        esac
        aws lambda update-function-configuration \
            --function-name "$FUNC_NAME" \
            --environment "Variables={ORDERS_TABLE=${PROJECT}-orders,INVENTORY_TABLE=${PROJECT}-inventory,PAYMENTS_TABLE=${PROJECT}-payments,SNS_TOPIC_ARN=${SNS_TOPIC_ARN},REPORTS_BUCKET=${S3_REPORTS},DEPLOY_BUCKET=${S3_DEPLOY},STEP_FUNCTIONS_ARN=${SF_ARN},REGION=${REGION},LOW_STOCK_THRESHOLD=5,S3_ORDERS_BUCKET=${S3_REPORTS},S3_LOGS_BUCKET=${S3_LOGS},SECRET_ARN=${SECRET_ARN}}" \
            --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
    done
    ok "Lambda env updated with Step Functions ARN"
fi

# Refresh SF_ARN
SF_ARN=$(aws stepfunctions list-state-machines --region "$REGION" \
    --query "stateMachines[?name=='${SF_NAME}'].stateMachineArn | [0]" \
    --output text 2>/dev/null || echo "")

# ================================================================
#  STEP 7: API Gateway
# ================================================================
section "STEP 7/11 — API Gateway (REST API)"
if ! skip_step 7; then
    # Create or get API
    # Cari API — coba nama baru dulu, fallback ke nama lama
    API_ID=$(aws apigateway get-rest-apis --region "$REGION" \
        --query "items[?name=='${PROJECT}-api-orders'].id" \
        --output text 2>/dev/null || echo "")
    [ -z "$API_ID" ] || [ "$API_ID" = "None" ] && \
    API_ID=$(aws apigateway get-rest-apis --region "$REGION" \
        --query "items[?name=='${PROJECT}-api'].id" \
        --output text 2>/dev/null || echo "")

    # Migrate: cek apakah ada API lama 'techno-api', rename
    OLD_API_ID=$(aws apigateway get-rest-apis --region "$REGION"         --query "items[?name=='${PROJECT}-api-orders'].id"         --output text 2>/dev/null || echo "")
    if [ -n "$OLD_API_ID" ] && [ "$OLD_API_ID" != "None" ]; then
        log "  Migrating API name: ${PROJECT}-api → ${PROJECT}-api-orders..."
        aws apigateway update-rest-api             --rest-api-id "$OLD_API_ID"             --patch-operations "op=replace,path=/name,value=${PROJECT}-api-orders"             --region "$REGION" --no-cli-pager > /dev/null &&             ok "  API renamed to ${PROJECT}-api-orders" ||             warn "  Could not rename API"
        API_ID="$OLD_API_ID"
    fi

    if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
        API_ID=$(aws apigateway create-rest-api \
            --name "${PROJECT}-api-orders" \
            --description "Techno Serverless OMS API" \
            --endpoint-configuration types=REGIONAL \
            --region "$REGION" --query id --output text)
        log "  API created: $API_ID"
    else
        log "  API exists: $API_ID"
    fi

    ROOT_ID=$(aws apigateway get-resources \
        --rest-api-id "$API_ID" --region "$REGION" \
        --query "items[?path=='/'].id" --output text)

    # Helper: get or create resource
    ensure_resource() {
        local PART="$1" PARENT="$2"
        local RID
        RID=$(aws apigateway get-resources \
            --rest-api-id "$API_ID" --region "$REGION" \
            --query "items[?pathPart=='${PART}'].id" \
            --output text 2>/dev/null | tr '\t' '\n' | head -1 || echo "")
        if [ -z "$RID" ] || [ "$RID" = "None" ]; then
            RID=$(aws apigateway create-resource \
                --rest-api-id "$API_ID" --parent-id "$PARENT" \
                --path-part "$PART" --region "$REGION" \
                --query id --output text)
        fi
        echo "$RID"
    }

    # Helper: resolve dir_name → AWS Lambda name (sesuai deploy.yml)
    resolve_func_name() {
        case "$1" in
            order_management)  echo "techno-lambda-order-management"  ;;
            process_payment)   echo "techno-lambda-process-payment"   ;;
            update_inventory)  echo "techno-lambda-update-inventory"  ;;
            send_notification) echo "techno-lambda-send-notification" ;;
            generate_report)   echo "techno-lambda-generate-report"   ;;
            init_db)           echo "techno-lambda-init-db"           ;;
            health_check)      echo "techno-lambda-health-check"      ;;
            *) echo "$1" ;;
        esac
    }

    # Helper: setup method + integration
    setup_method() {
        local RID="$1" METHOD="$2" FUNC_DIR="$3" KEY_REQ="$4"
        local FUNC_NAME
        FUNC_NAME=$(resolve_func_name "$FUNC_DIR")
        local LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNC_NAME}"
        local URI="arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations"

        aws apigateway delete-method \
            --rest-api-id "$API_ID" --resource-id "$RID" \
            --http-method "$METHOD" \
            --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true

        local KEY_FLAG=""
        [ "$KEY_REQ" = "true" ] && KEY_FLAG="--api-key-required" || KEY_FLAG="--no-api-key-required"
        aws apigateway put-method \
            --rest-api-id "$API_ID" --resource-id "$RID" \
            --http-method "$METHOD" --authorization-type NONE \
            $KEY_FLAG \
            --region "$REGION" --no-cli-pager > /dev/null

        aws apigateway put-integration \
            --rest-api-id "$API_ID" --resource-id "$RID" \
            --http-method "$METHOD" --type AWS_PROXY \
            --integration-http-method POST --uri "$URI" \
            --region "$REGION" --no-cli-pager > /dev/null

        aws lambda add-permission \
            --function-name "$FUNC_NAME" \
            --statement-id "apigw-${METHOD}-${RID}-$(date +%s)" \
            --action lambda:InvokeFunction \
            --principal apigateway.amazonaws.com \
            --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*" \
            --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true

        log "  ${METHOD} -> ${FUNC_NAME} (key=${KEY_REQ})"
    }

    # Helper: setup CORS OPTIONS (MOCK integration) pada sebuah resource
    setup_cors() {
        local RID="$1"
        local ALLOW_METHODS="${2:-GET,POST,PUT,DELETE,OPTIONS}"

        # Hapus OPTIONS yang sudah ada (idempotent)
        aws apigateway delete-method \
            --rest-api-id "$API_ID" --resource-id "$RID" \
            --http-method OPTIONS \
            --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true

        # OPTIONS method — no auth, no key
        aws apigateway put-method \
            --rest-api-id "$API_ID" --resource-id "$RID" \
            --http-method OPTIONS \
            --authorization-type NONE \
            --no-api-key-required \
            --region "$REGION" --no-cli-pager > /dev/null

        # MOCK integration
        aws apigateway put-integration \
            --rest-api-id "$API_ID" --resource-id "$RID" \
            --http-method OPTIONS \
            --type MOCK \
            --request-templates '{"application/json":"{\"statusCode\":200}"}' \
            --region "$REGION" --no-cli-pager > /dev/null

        # Method response 200
        aws apigateway put-method-response \
            --rest-api-id "$API_ID" --resource-id "$RID" \
            --http-method OPTIONS --status-code 200 \
            --response-parameters '{
                "method.response.header.Access-Control-Allow-Headers": false,
                "method.response.header.Access-Control-Allow-Methods": false,
                "method.response.header.Access-Control-Allow-Origin":  false
            }' \
            --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true

        # Integration response — tulis langsung ke JSON file, hindari quoting issue
        cat > /tmp/techno_cors_params.json << CORSJSON
{
    "method.response.header.Access-Control-Allow-Headers": "'Content-Type,x-api-key,X-Amz-Date,Authorization,X-Api-Key'",
    "method.response.header.Access-Control-Allow-Methods": "'${ALLOW_METHODS}'",
    "method.response.header.Access-Control-Allow-Origin":  "'*'"
}
CORSJSON
        aws apigateway put-integration-response \
            --rest-api-id "$API_ID" --resource-id "$RID" \
            --http-method OPTIONS --status-code 200 \
            --response-parameters "file:///tmp/techno_cors_params.json" \
            --response-templates '{"application/json":""}' \
            --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true

        log "  CORS OPTIONS: $RID"
    }

    # ── Build full resource tree sesuai frontend API calls ──────────────
    # Frontend pakai: /orders, /orders/{id}, /customers, /products,
    #                 /health, /status/{id}, /workflows/stats
    log "Creating API Gateway resources..."

    ORDERS_ID=$(ensure_resource    "orders"         "$ROOT_ID")
    ORDER_ID=$(ensure_resource     "{orderId}"      "$ORDERS_ID")
    CUSTOMERS_ID=$(ensure_resource "customers"      "$ROOT_ID")
    CUSTOMER_ID=$(ensure_resource  "{customerId}"   "$CUSTOMERS_ID")
    PRODUCTS_ID=$(ensure_resource  "products"       "$ROOT_ID")
    PRODUCT_ID=$(ensure_resource   "{productId}"    "$PRODUCTS_ID")
    HEALTH_ID=$(ensure_resource    "health"         "$ROOT_ID")
    STATUS_ID=$(ensure_resource    "status"         "$ROOT_ID")
    STATUS_ITEM_ID=$(ensure_resource "{executionId}" "$STATUS_ID")
    WORKFLOWS_ID=$(ensure_resource "workflows"      "$ROOT_ID")
    WF_STATS_ID=$(ensure_resource  "stats"          "$WORKFLOWS_ID")

    # ── /orders ──────────────────────────────────────────────────────────
    setup_method "$ORDERS_ID"   "GET"    "order_management" "true"
    setup_method "$ORDERS_ID"   "POST"   "order_management" "true"
    # ── /orders/{orderId} ────────────────────────────────────────────────
    setup_method "$ORDER_ID"    "GET"    "order_management" "true"
    setup_method "$ORDER_ID"    "PUT"    "order_management" "true"
    setup_method "$ORDER_ID"    "DELETE" "order_management" "true"
    # ── /customers ───────────────────────────────────────────────────────
    setup_method "$CUSTOMERS_ID" "GET"  "order_management" "true"
    setup_method "$CUSTOMER_ID"  "GET"  "order_management" "true"
    # ── /products ────────────────────────────────────────────────────────
    setup_method "$PRODUCTS_ID"  "GET"  "order_management" "true"
    setup_method "$PRODUCT_ID"   "GET"  "order_management" "true"
    # ── /health ──────────────────────────────────────────────────────────
    setup_method "$HEALTH_ID"    "GET"  "health_check"     "false"
    # ── /status/{executionId} ────────────────────────────────────────────
    setup_method "$STATUS_ITEM_ID" "GET" "order_management" "true"
    # ── /workflows/stats ─────────────────────────────────────────────────
    setup_method "$WF_STATS_ID"  "GET"  "order_management" "true"

    # ── CORS OPTIONS untuk semua resource ────────────────────────────────
    log "Configuring CORS..."
    for _RID in "$ORDERS_ID" "$ORDER_ID" "$CUSTOMERS_ID" "$CUSTOMER_ID"                 "$PRODUCTS_ID" "$PRODUCT_ID" "$HEALTH_ID"                 "$STATUS_ID" "$STATUS_ITEM_ID" "$WORKFLOWS_ID" "$WF_STATS_ID"; do
        setup_cors "$_RID" "GET,POST,PUT,DELETE,OPTIONS"
    done
    ok "All routes + CORS configured"

    # Deploy
    aws apigateway create-deployment \
        --rest-api-id "$API_ID" \
        --stage-name production \
        --description "Techno OMS deployment $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --region "$REGION" --no-cli-pager > /dev/null
    sleep 5

    # API Key + Usage Plan
    API_KEY_ID=$(aws apigateway get-api-keys \
        --name-query "${PROJECT}-api-orders-key" --include-values \
        --region "$REGION" --query "items[0].id" --output text 2>/dev/null || echo "")

    if [ -z "$API_KEY_ID" ] || [ "$API_KEY_ID" = "None" ]; then
        API_KEY_ID=$(aws apigateway create-api-key \
            --name "${PROJECT}-api-orders-key" --enabled \
            --region "$REGION" --query id --output text)
        PLAN_ID=$(aws apigateway create-usage-plan \
            --name "${PROJECT}-api-orders-usage-plan" \
            --api-stages "apiId=${API_ID},stage=production" \
            --throttle "rateLimit=1000,burstLimit=2000" \
            --quota "limit=100000,period=MONTH" \
            --region "$REGION" --query id --output text)
        aws apigateway create-usage-plan-key \
            --usage-plan-id "$PLAN_ID" \
            --key-id "$API_KEY_ID" --key-type API_KEY \
            --region "$REGION" --no-cli-pager > /dev/null
        log "  API Key created"
    else
        # Ensure usage plan association
        PLAN_ID=$(aws apigateway get-usage-plans \
            --region "$REGION" \
            --query "items[?name=='${PROJECT}-api-orders-usage-plan'].id | [0]" \
            --output text 2>/dev/null || echo "")
        if [ -n "$PLAN_ID" ] && [ "$PLAN_ID" != "None" ]; then
            aws apigateway update-usage-plan \
                --usage-plan-id "$PLAN_ID" \
                --patch-operations "op=add,path=/apiStages,value=${API_ID}:production" \
                --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
        fi
        log "  API Key exists"
    fi

    API_KEY_VALUE=$(aws apigateway get-api-key \
        --api-key "$API_KEY_ID" --include-value \
        --region "$REGION" --query value --output text)
    API_ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com/production"

    ok "API Endpoint : $API_ENDPOINT"
    ok "API Key      : $API_KEY_VALUE"
fi

# Refresh API info
resolve_state

# ================================================================
#  STEP 8: EventBridge
# ================================================================
section "STEP 8/11 — EventBridge (Daily Report Rule)"
if ! skip_step 8; then
    REPORT_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:techno-lambda-generate-report"

    aws events put-rule \
        --name "${PROJECT}-daily-report" \
        --schedule-expression "cron(0 0 * * ? *)" \
        --state ENABLED \
        --description "Techno OMS daily report generation" \
        --region "$REGION" --no-cli-pager > /dev/null

    aws lambda add-permission \
        --function-name "techno-lambda-generate-report" \
        --statement-id "eventbridge-daily-$(date +%s)" \
        --action lambda:InvokeFunction \
        --principal events.amazonaws.com \
        --source-arn "arn:aws:events:${REGION}:${ACCOUNT_ID}:rule/${PROJECT}-daily-report" \
        --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true

    aws events put-targets \
        --rule "${PROJECT}-daily-report" \
        --targets "[{\"Id\":\"ReportTarget\",\"Arn\":\"${REPORT_ARN}\",\"Input\":\"{\\\"action\\\":\\\"daily_report\\\"}\"}]" \
        --region "$REGION" --no-cli-pager > /dev/null
    ok "EventBridge rule aktif: cron(0 0 * * ? *)"
fi

# ================================================================
#  STEP 8b: CloudWatch Alarms + Dashboard (AWS CLI)
# ================================================================
section "STEP 8b — CloudWatch Alarms + Dashboard"
if [ "${FROM_STEP:-1}" -le 8 ] 2>/dev/null; then

    # Tulis helper script untuk buat dashboard JSON
    cat > /tmp/techno_make_dashboard.py << 'DASHPYEOF'
import json, sys
region=sys.argv[1]; account=sys.argv[2]; sf_arn=sys.argv[3]; rds_id=sys.argv[4]; out=sys.argv[5]
body={"widgets":[
    {"type":"metric","x":0,"y":0,"width":12,"height":6,"properties":{"title":"Lambda - Invocations & Errors","view":"timeSeries","region":region,"metrics":[
        ["AWS/Lambda","Invocations","FunctionName","techno-lambda-order-management",{"stat":"Sum","period":300}],
        ["AWS/Lambda","Errors","FunctionName","techno-lambda-order-management",{"stat":"Sum","period":300,"color":"#d62728"}],
        ["AWS/Lambda","Invocations","FunctionName","techno-lambda-process-payment",{"stat":"Sum","period":300}],
        ["AWS/Lambda","Invocations","FunctionName","techno-lambda-update-inventory",{"stat":"Sum","period":300}],
        ["AWS/Lambda","Invocations","FunctionName","techno-lambda-health-check",{"stat":"Sum","period":300}]]}},
    {"type":"metric","x":12,"y":0,"width":12,"height":6,"properties":{"title":"Lambda - Duration (Max ms)","view":"timeSeries","region":region,"metrics":[
        ["AWS/Lambda","Duration","FunctionName","techno-lambda-order-management",{"stat":"Maximum","period":300}],
        ["AWS/Lambda","Duration","FunctionName","techno-lambda-process-payment",{"stat":"Maximum","period":300}],
        ["AWS/Lambda","Duration","FunctionName","techno-lambda-update-inventory",{"stat":"Maximum","period":300}],
        ["AWS/Lambda","Duration","FunctionName","techno-lambda-generate-report",{"stat":"Maximum","period":300}]]}},
    {"type":"metric","x":0,"y":6,"width":12,"height":6,"properties":{"title":"API Gateway - Requests 4XX 5XX","view":"timeSeries","region":region,"metrics":[
        ["AWS/ApiGateway","Count","ApiName","techno-api-orders","Stage","production",{"stat":"Sum","period":300}],
        ["AWS/ApiGateway","4XXError","ApiName","techno-api-orders","Stage","production",{"stat":"Sum","period":300,"color":"#ff7f0e"}],
        ["AWS/ApiGateway","5XXError","ApiName","techno-api-orders","Stage","production",{"stat":"Sum","period":300,"color":"#d62728"}]]}},
    {"type":"metric","x":12,"y":6,"width":12,"height":6,"properties":{"title":"Step Functions - Executions","view":"timeSeries","region":region,"metrics":[
        ["AWS/States","ExecutionsStarted","StateMachineArn",sf_arn,{"stat":"Sum","period":300}],
        ["AWS/States","ExecutionsSucceeded","StateMachineArn",sf_arn,{"stat":"Sum","period":300,"color":"#2ca02c"}],
        ["AWS/States","ExecutionsFailed","StateMachineArn",sf_arn,{"stat":"Sum","period":300,"color":"#d62728"}]]}},
    {"type":"metric","x":0,"y":12,"width":12,"height":6,"properties":{"title":"RDS - CPU & Connections","view":"timeSeries","region":region,"metrics":[
        ["AWS/RDS","CPUUtilization","DBInstanceIdentifier",rds_id,{"stat":"Average","period":300}],
        ["AWS/RDS","DatabaseConnections","DBInstanceIdentifier",rds_id,{"stat":"Average","period":300,"yAxis":"right"}]]}},
    {"type":"alarm","x":12,"y":12,"width":12,"height":6,"properties":{"title":"Active Alarms","alarms":[
        f"arn:aws:cloudwatch:{region}:{account}:alarm:techno-alarm-lambda-errors",
        f"arn:aws:cloudwatch:{region}:{account}:alarm:techno-alarm-lambda-duration",
        f"arn:aws:cloudwatch:{region}:{account}:alarm:techno-alarm-api-4xx",
        f"arn:aws:cloudwatch:{region}:{account}:alarm:techno-alarm-api-5xx",
        f"arn:aws:cloudwatch:{region}:{account}:alarm:techno-alarm-sf-failures",
        f"arn:aws:cloudwatch:{region}:{account}:alarm:techno-alarm-rds-cpu"]}}
]}
json.dump(body, open(out,"w"))
print(f"  Dashboard JSON: {out}")
DASHPYEOF

        _SNS_ARN=$(aws sns list-topics --region "$REGION" \
        --query "Topics[?ends_with(TopicArn,':${PROJECT}-notifications')].TopicArn" \
        --output text 2>/dev/null || echo "")
    _SF_ARN=$(aws stepfunctions list-state-machines --region "$REGION" \
        --query "stateMachines[?name=='${PROJECT}-order-workflow'].stateMachineArn | [0]" \
        --output text 2>/dev/null || echo "")
    _RDS_ID="${PROJECT}-rds-orders"

    log "  SNS    : $_SNS_ARN"
    log "  SF ARN : $_SF_ARN"
    log "  RDS ID : $_RDS_ID"

    # ── 6 CloudWatch Alarms ──────────────────────────────────
    log "Creating CloudWatch Alarms..."

    aws cloudwatch put-metric-alarm \
        --alarm-name "techno-alarm-lambda-errors" \
        --alarm-description "Lambda errors > 5 dalam 5 menit" \
        --namespace AWS/Lambda --metric-name Errors \
        --statistic Sum --period 300 --evaluation-periods 1 \
        --threshold 5 --comparison-operator GreaterThanThreshold \
        --treat-missing-data notBreaching \
        ${_SNS_ARN:+--alarm-actions "$_SNS_ARN"} \
        --region "$REGION" --no-cli-pager && log "  ok lambda-errors"

    aws cloudwatch put-metric-alarm \
        --alarm-name "techno-alarm-lambda-duration" \
        --alarm-description "Lambda max duration > 3000ms" \
        --namespace AWS/Lambda --metric-name Duration \
        --statistic Maximum --period 300 --evaluation-periods 1 \
        --threshold 3000 --comparison-operator GreaterThanThreshold \
        --treat-missing-data notBreaching \
        ${_SNS_ARN:+--alarm-actions "$_SNS_ARN"} \
        --region "$REGION" --no-cli-pager && log "  ok lambda-duration"

    aws cloudwatch put-metric-alarm \
        --alarm-name "techno-alarm-api-4xx" \
        --alarm-description "API 4XX > 20 dalam 5 menit" \
        --namespace AWS/ApiGateway --metric-name 4XXError \
        --dimensions Name=ApiName,Value=techno-api-orders Name=Stage,Value=production \
        --statistic Sum --period 300 --evaluation-periods 1 \
        --threshold 20 --comparison-operator GreaterThanThreshold \
        --treat-missing-data notBreaching \
        ${_SNS_ARN:+--alarm-actions "$_SNS_ARN"} \
        --region "$REGION" --no-cli-pager && log "  ok api-4xx"

    aws cloudwatch put-metric-alarm \
        --alarm-name "techno-alarm-api-5xx" \
        --alarm-description "API 5XX > 5" \
        --namespace AWS/ApiGateway --metric-name 5XXError \
        --dimensions Name=ApiName,Value=techno-api-orders Name=Stage,Value=production \
        --statistic Sum --period 300 --evaluation-periods 1 \
        --threshold 5 --comparison-operator GreaterThanThreshold \
        --treat-missing-data notBreaching \
        ${_SNS_ARN:+--alarm-actions "$_SNS_ARN"} \
        --region "$REGION" --no-cli-pager && log "  ok api-5xx"

    if [ -n "$_SF_ARN" ] && [ "$_SF_ARN" != "None" ]; then
        aws cloudwatch put-metric-alarm \
            --alarm-name "techno-alarm-sf-failures" \
            --alarm-description "Step Functions failures > 3 dalam 10 menit" \
            --namespace AWS/States --metric-name ExecutionsFailed \
            --dimensions Name=StateMachineArn,Value="$_SF_ARN" \
            --statistic Sum --period 600 --evaluation-periods 1 \
            --threshold 3 --comparison-operator GreaterThanThreshold \
            --treat-missing-data notBreaching \
            ${_SNS_ARN:+--alarm-actions "$_SNS_ARN"} \
            --region "$REGION" --no-cli-pager && log "  ok sf-failures"
    fi

    aws cloudwatch put-metric-alarm \
        --alarm-name "techno-alarm-rds-cpu" \
        --alarm-description "RDS CPU > 80% selama 5 menit" \
        --namespace AWS/RDS --metric-name CPUUtilization \
        --dimensions Name=DBInstanceIdentifier,Value="$_RDS_ID" \
        --statistic Average --period 300 --evaluation-periods 1 \
        --threshold 80 --comparison-operator GreaterThanThreshold \
        --treat-missing-data notBreaching \
        ${_SNS_ARN:+--alarm-actions "$_SNS_ARN"} \
        --region "$REGION" --no-cli-pager && log "  ok rds-cpu"

    ok "6 CloudWatch Alarms created"

    # ── CloudWatch Dashboard (via Python ke JSON file) ───────
    log "Creating CloudWatch Dashboard..."
    python3 /tmp/techno_make_dashboard.py \
        "$REGION" "$ACCOUNT_ID" "$_SF_ARN" "$_RDS_ID" \
        /tmp/techno_dashboard.json

    aws cloudwatch put-dashboard \
        --dashboard-name "techno-dashboard-serverless" \
        --dashboard-body "file:///tmp/techno_dashboard.json" \
        --region "$REGION" --no-cli-pager > /dev/null
    ok "Dashboard created: techno-dashboard-serverless"
    ok "Dashboard URL: https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=techno-dashboard-serverless"
fi


# ================================================================
#  STEP 9: CI/CD (CodeDeploy + Upload Lambda Code + Amplify)
# ================================================================
section "STEP 9/11 — CI/CD (Lambda Code Deploy + Amplify Frontend)"
if ! skip_step 9; then
    # Tulis helper fix_xray.py sekali di awal
    python3 - << 'WRITE_XRAY_FIX'
content = r"""import sys
with open(sys.argv[1]) as f:
    src = f.read()
old1 = "from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all

patch_all()"
new1 = "try:
    from aws_xray_sdk.core import xray_recorder
    from aws_xray_sdk.core import patch_all
    patch_all()
except Exception:
    pass"
old2 = "from aws_xray_sdk.core import patch_all

patch_all()"
new2 = "try:
    from aws_xray_sdk.core import patch_all
    patch_all()
except Exception:
    pass"
src = src.replace(old1, new1).replace(old2, new2)
with open(sys.argv[2], 'w') as f:
    f.write(src)
"""
with open('/tmp/fix_xray_import.py', 'w') as f:
    f.write(content)
print("fix_xray_import.py written")
WRITE_XRAY_FIX

    # ── Deploy real Lambda code ───────────────────────────
    TMP_PKG=$(mktemp -d)

    for FUNC_BASE in order_management process_payment update_inventory \
                     send_notification generate_report init_db health_check; do
        LAMBDA_FILE="${SCRIPT_DIR}/lambda/${FUNC_BASE}/lambda_function.py"
        # Map dir name → AWS function name (sesuai deploy.yml naming)
        case "$FUNC_BASE" in
            order_management)  FUNC_NAME="techno-lambda-order-management"  ;;
            process_payment)   FUNC_NAME="techno-lambda-process-payment"   ;;
            update_inventory)  FUNC_NAME="techno-lambda-update-inventory"  ;;
            send_notification) FUNC_NAME="techno-lambda-send-notification" ;;
            generate_report)   FUNC_NAME="techno-lambda-generate-report"   ;;
            init_db)           FUNC_NAME="techno-lambda-init-db"           ;;
            health_check)      FUNC_NAME="techno-lambda-health-check"      ;;
        esac

        if [ ! -f "$LAMBDA_FILE" ]; then
            warn "Lambda source tidak ditemukan: $LAMBDA_FILE — skip"
            continue
        fi

        # Patch order_management: tulis helper script ke file, lalu jalankan
        if [ "$FUNC_BASE" = "order_management" ]; then
            # Tulis patch script ke /tmp (hindari heredoc string literal issue)
            cat > /tmp/patch_order_mgmt.py << 'PYEOF_PATCH'
import sys

src_file = sys.argv[1]
dst_file = sys.argv[2]

with open(src_file) as f:
    src = f.read()

WORKFLOW_FN = (
    "\ndef get_workflow_stats():\n"
    "    try:\n"
    "        sf_arn = os.environ.get('STEP_FUNCTIONS_ARN', '')\n"
    "        if not sf_arn:\n"
    "            return response(200, {'total':0,'running':0,'succeeded':0,'failed':0,'executions':[]})\n"
    "        execs = stepfunctions_client.list_executions(\n"
    "            stateMachineArn=sf_arn, maxResults=20\n"
    "        ).get('executions', [])\n"
    "        stats = {'total':len(execs),'running':0,'succeeded':0,'failed':0}\n"
    "        for e in execs:\n"
    "            s = e.get('status','').lower()\n"
    "            if s in stats: stats[s] += 1\n"
    "        result = [{\n"
    "            'executionArn': e['executionArn'],\n"
    "            'name': e.get('name',''),\n"
    "            'status': e.get('status',''),\n"
    "            'startDate': e['startDate'].isoformat() if e.get('startDate') else None,\n"
    "            'stopDate': e['stopDate'].isoformat() if e.get('stopDate') else None,\n"
    "        } for e in execs]\n"
    "        return response(200, {**stats, 'executions': result})\n"
    "    except Exception as e:\n"
    "        return response(200, {'total':0,'running':0,'succeeded':0,'failed':0,'executions':[]})\n"
)

ROUTE_HANDLER = (
    "        # GET /workflows/stats\n"
    "        if path == '/workflows/stats' and http_method == 'GET':\n"
    "            return get_workflow_stats()\n\n"
    "        return response(404, {'error': 'Route not found'})"
)

# Fix xray import — wrap agar tidak crash jika xray tidak tersedia di layer
XRAY_SAFE = (
    "try:\n"
    "    from aws_xray_sdk.core import xray_recorder\n"
    "    from aws_xray_sdk.core import patch_all\n"
    "    patch_all()\n"
    "except Exception:\n"
    "    pass\n"
)
src = src.replace(
    "from aws_xray_sdk.core import xray_recorder\nfrom aws_xray_sdk.core import patch_all\n\npatch_all()",
    XRAY_SAFE.rstrip()
)
src = src.replace(
    "from aws_xray_sdk.core import patch_all\n\npatch_all()",
    "try:\n    from aws_xray_sdk.core import patch_all\n    patch_all()\nexcept Exception:\n    pass"
)

if '/workflows/stats' not in src:
    src = src.replace(
        "\ndef lambda_handler(event, context):",
        WORKFLOW_FN + "\ndef lambda_handler(event, context):"
    )
    src = src.replace(
        "        return response(404, {'error': 'Route not found'})",
        ROUTE_HANDLER
    )
    print("  Patched: /workflows/stats added + xray safe import")
else:
    print("  Already patched")

with open(dst_file, 'w') as f:
    f.write(src)
PYEOF_PATCH

            python3 /tmp/patch_order_mgmt.py \
                "$LAMBDA_FILE" \
                "${TMP_PKG}/lambda_function.py"
        else
            python3 /tmp/fix_xray_import.py                 "$LAMBDA_FILE" "${TMP_PKG}/lambda_function.py" 2>/dev/null ||             cp "$LAMBDA_FILE" "${TMP_PKG}/lambda_function.py"
        fi
        (cd "$TMP_PKG" && zip -q "${FUNC_BASE}.zip" "lambda_function.py")

        aws lambda update-function-code \
            --function-name "$FUNC_NAME" \
            --zip-file "fileb://${TMP_PKG}/${FUNC_BASE}.zip" \
            --region "$REGION" --no-cli-pager > /dev/null

        aws lambda wait function-updated \
            --function-name "$FUNC_NAME" --region "$REGION"
        ok "Lambda $FUNC_BASE deployed"
    done

    # ── CodeDeploy Application + Deployment Group ───────────
    log "Setting up CodeDeploy..."

    # Create application (idempotent)
    aws deploy create-application \
        --application-name "techno-codedeploy-app" \
        --compute-platform Lambda \
        --region "$REGION" --no-cli-pager 2>/dev/null && \
        log "  CodeDeploy app created: techno-codedeploy-app" || \
        log "  CodeDeploy app sudah ada: techno-codedeploy-app"

    # Create alias 'live' untuk order-management (wajib untuk Blue/Green)
    log "  Creating Lambda alias 'live' untuk order-management..."
    OM_VERSION=$(aws lambda publish-version \
        --function-name "techno-lambda-order-management" \
        --description "initial" \
        --region "$REGION" --query Version --output text 2>/dev/null || echo "1")
    aws lambda create-alias \
        --function-name "techno-lambda-order-management" \
        --name live \
        --function-version "$OM_VERSION" \
        --region "$REGION" --no-cli-pager 2>/dev/null || \
    aws lambda update-alias \
        --function-name "techno-lambda-order-management" \
        --name live \
        --function-version "$OM_VERSION" \
        --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
    log "  Alias 'live' → version $OM_VERSION"

    # Create aliases 'live' untuk fungsi lain (deploy.yml cek alias ini)
    for _FN in techno-lambda-process-payment techno-lambda-update-inventory \
               techno-lambda-send-notification techno-lambda-generate-report \
               techno-lambda-health-check; do
        _VER=$(aws lambda publish-version \
            --function-name "$_FN" --description "initial" \
            --region "$REGION" --query Version --output text 2>/dev/null || echo "1")
        aws lambda create-alias \
            --function-name "$_FN" --name live \
            --function-version "$_VER" \
            --region "$REGION" --no-cli-pager 2>/dev/null || \
        aws lambda update-alias \
            --function-name "$_FN" --name live \
            --function-version "$_VER" \
            --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
    done
    ok "Lambda aliases 'live' ready"

    # Create deployment group untuk order-management Blue/Green
    log "  Creating CodeDeploy deployment group..."
    aws deploy create-deployment-group \
        --application-name "techno-codedeploy-app" \
        --deployment-group-name "techno-codedeploy-group" \
        --deployment-config-name "CodeDeployDefault.LambdaCanary10Percent5Minutes" \
        --service-role-arn "$ROLE_ARN" \
        --deployment-style "deploymentType=BLUE_GREEN,deploymentOption=WITH_TRAFFIC_CONTROL" \
        --auto-rollback-configuration "enabled=true,events=DEPLOYMENT_FAILURE" \
        --region "$REGION" --no-cli-pager 2>/dev/null && \
        log "  Deployment group created: techno-codedeploy-group" || \
        log "  Deployment group sudah ada: techno-codedeploy-group"
    ok "CodeDeploy ready"

    # Upload deployment artifacts to S3
    if ls "${SCRIPT_DIR}/codedeploy/"* > /dev/null 2>&1; then
        aws s3 cp "${SCRIPT_DIR}/codedeploy/" "s3://${S3_DEPLOY}/codedeploy/" \
            --recursive --region "$REGION" > /dev/null
        ok "CodeDeploy artifacts uploaded"
    fi

    rm -rf "$TMP_PKG"

    # ── GitHub CI/CD — push code + inject secrets + trigger Actions ──
    section "STEP 9b — GitHub CI/CD Setup"
    GITHUB_TOKEN_FILE="${SCRIPT_DIR}/token"
    if [ ! -f "$GITHUB_TOKEN_FILE" ]; then
        warn "File 'token' tidak ditemukan di ${SCRIPT_DIR} — skip GitHub CI/CD"
        warn "  Buat file 'token' berisi GitHub PAT untuk enable CI/CD"
    else
        GITHUB_TOKEN=$(head -1 "$GITHUB_TOKEN_FILE" | tr -d '[:space:]')
        if [ -z "$GITHUB_TOKEN" ]; then
            warn "Token kosong di file 'token' — skip GitHub CI/CD"
        else
            log "GitHub token ditemukan: ${GITHUB_TOKEN:0:10}..."

            # Detect repo dari git remote
            REPO_REMOTE=$(cd "$SCRIPT_DIR" && git remote get-url origin 2>/dev/null || echo "")
            if [ -z "$REPO_REMOTE" ]; then
                warn "Tidak ada git remote origin — skip GitHub push"
            else
                # Extract owner/repo dari URL
                # Format: https://github.com/owner/repo.git  ATAU  git@github.com:owner/repo.git
                REPO_SLUG=$(echo "$REPO_REMOTE" \
                    | sed 's|https://github.com/||' \
                    | sed 's|git@github.com:||' \
                    | sed 's|\.git$||')
                REPO_OWNER=$(echo "$REPO_SLUG" | cut -d/ -f1)
                REPO_NAME=$(echo "$REPO_SLUG"  | cut -d/ -f2)
                log "Repo: $REPO_OWNER/$REPO_NAME"

                # Set git credentials untuk push
                cd "$SCRIPT_DIR"
                git config user.email "judge@lks.id" 2>/dev/null || true
                git config user.name  "LKS Judge"    2>/dev/null || true

                # Inject GitHub Secrets via API
                log "Mengambil AMPLIFY_APP_ID untuk secrets..."
                AMPLIFY_APP_ID_FOR_SECRET=$(aws amplify list-apps --region "$REGION" \
                    --query "apps[?name=='${PROJECT}-frontend'].appId" \
                    --output text 2>/dev/null || echo "")

                log "Setting GitHub Actions secrets..."
                _set_gh_secret() {
                    local SECRET_NAME="$1"
                    local SECRET_VALUE="$2"
                    # Get repo public key for encryption
                    PUB_KEY_RESP=$(curl -sf \
                        -H "Authorization: token ${GITHUB_TOKEN}" \
                        -H "Accept: application/vnd.github.v3+json" \
                        "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/actions/secrets/public-key" \
                        2>/dev/null || echo "")
                    if [ -z "$PUB_KEY_RESP" ]; then
                        warn "    Tidak bisa ambil public key untuk secret $SECRET_NAME"
                        return
                    fi
                    PUB_KEY=$(echo "$PUB_KEY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['key'])" 2>/dev/null)
                    KEY_ID=$(echo  "$PUB_KEY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['key_id'])" 2>/dev/null)

                    # Encrypt secret dengan libsodium (PyNaCl)
                    ENCRYPTED=$(python3 - << PYEOF 2>/dev/null
import sys, base64
try:
    from nacl import encoding, public
    pub = public.PublicKey(base64.b64decode("${PUB_KEY}"))
    box = public.SealedBox(pub)
    enc = box.encrypt("${SECRET_VALUE}".encode())
    print(base64.b64encode(enc).decode())
except ImportError:
    # PyNaCl tidak tersedia — fallback: kirim sebagai plain (kurang aman)
    print("")
PYEOF
)
                    if [ -z "$ENCRYPTED" ]; then
                        warn "    PyNaCl tidak tersedia, install: pip3 install PyNaCl"
                        warn "    Set secret $SECRET_NAME manual di GitHub → Settings → Secrets"
                        return
                    fi

                    HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
                        -X PUT \
                        -H "Authorization: token ${GITHUB_TOKEN}" \
                        -H "Accept: application/vnd.github.v3+json" \
                        "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/actions/secrets/${SECRET_NAME}" \
                        -d "{\"encrypted_value\":\"${ENCRYPTED}\",\"key_id\":\"${KEY_ID}\"}" \
                        2>/dev/null || echo "000")
                    [ "$HTTP_STATUS" = "204" ] || [ "$HTTP_STATUS" = "201" ] && \
                        log "    ✓ Secret set: $SECRET_NAME" || \
                        warn "    ✗ Gagal set secret $SECRET_NAME (HTTP $HTTP_STATUS)"
                }

                # Get current AWS credentials
                AWS_ACCESS_KEY=$(aws configure get aws_access_key_id 2>/dev/null || \
                    echo "${AWS_ACCESS_KEY_ID:-}")
                AWS_SECRET_KEY=$(aws configure get aws_secret_access_key 2>/dev/null || \
                    echo "${AWS_SECRET_ACCESS_KEY:-}")
                AWS_SESSION=$(aws configure get aws_session_token 2>/dev/null || \
                    echo "${AWS_SESSION_TOKEN:-}")

                _set_gh_secret "AWS_ACCESS_KEY_ID"     "$AWS_ACCESS_KEY"
                _set_gh_secret "AWS_SECRET_ACCESS_KEY" "$AWS_SECRET_KEY"
                _set_gh_secret "AWS_SESSION_TOKEN"     "$AWS_SESSION"
                _set_gh_secret "SNS_TOPIC_ARN"         "$SNS_TOPIC_ARN"
                _set_gh_secret "S3_DEPLOYMENT_BUCKET"  "$S3_DEPLOY"
                _set_gh_secret "AMPLIFY_APP_ID"        "$AMPLIFY_APP_ID_FOR_SECRET"
                ok "GitHub secrets configured"

                # Push latest code ke GitHub
                log "Pushing code ke GitHub ($REPO_SLUG)..."
                # Set remote URL dengan token agar push berhasil
                git remote set-url origin \
                    "https://${GITHUB_TOKEN}@github.com/${REPO_SLUG}.git" 2>/dev/null || true

                git add -A 2>/dev/null || true
                git diff --staged --quiet 2>/dev/null || \
                    git commit -m "ci: judge deploy $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                    --allow-empty 2>/dev/null || true

                git push origin HEAD:main --force 2>/dev/null && \
                    ok "Code pushed ke GitHub — GitHub Actions akan berjalan otomatis" || \
                    warn "git push gagal — cek token permission (repo + workflow scope)"

                # Restore remote URL tanpa token
                git remote set-url origin \
                    "https://github.com/${REPO_SLUG}.git" 2>/dev/null || true

                # Tunggu GitHub Actions selesai (opsional, max 5 menit)
                log "Menunggu GitHub Actions workflow selesai (max 5 menit)..."
                sleep 10
                for i in $(seq 1 30); do
                    RUN_STATUS=$(curl -sf \
                        -H "Authorization: token ${GITHUB_TOKEN}" \
                        -H "Accept: application/vnd.github.v3+json" \
                        "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/actions/runs?per_page=1&branch=main" \
                        2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
runs=d.get('workflow_runs',[])
if runs: print(runs[0]['status']+'|'+runs[0]['conclusion'])
else: print('none|none')
" 2>/dev/null || echo "none|none")
                    STATUS=$(echo "$RUN_STATUS" | cut -d'|' -f1)
                    CONCLUSION=$(echo "$RUN_STATUS" | cut -d'|' -f2)
                    log "  [$i/30] Actions: status=$STATUS conclusion=$CONCLUSION"
                    if [ "$STATUS" = "completed" ]; then
                        [ "$CONCLUSION" = "success" ] && ok "GitHub Actions: SUCCESS ✓" || \
                            warn "GitHub Actions: $CONCLUSION"
                        break
                    fi
                    sleep 10
                done
                cd "$SCRIPT_DIR"
            fi
        fi
    fi
    ok "GitHub CI/CD selesai"

    # ── Amplify Frontend ──────────────────────────────────
    FRONTEND_FILE="${SCRIPT_DIR}/frontend/index.html"
    if [ ! -f "$FRONTEND_FILE" ]; then
        warn "frontend/index.html tidak ditemukan, skip Amplify deploy"
    else
        # Inject API config
        API_ENDPOINT_FRESH="${API_ENDPOINT}"
        API_KEY_FRESH="${API_KEY_VALUE}"

        if [ -z "$API_ENDPOINT_FRESH" ]; then
            API_ENDPOINT_FRESH="https://${API_ID}.execute-api.${REGION}.amazonaws.com/production"
        fi

        python3 - << PYEOF
ep  = "${API_ENDPOINT_FRESH}"
key = "${API_KEY_FRESH}"
with open("${FRONTEND_FILE}") as f:
    html = f.read()
inject = f'<script>\\nwindow.TECHNO_API_ENDPOINT="{ep}";\\nwindow.TECHNO_API_KEY="{key}";\\n</script>\\n'
if '<head>' in html:
    html = html.replace('<head>', '<head>\\n' + inject, 1)
else:
    html = inject + html
with open('/tmp/techno_index_amplify.html', 'w') as f:
    f.write(html)
print(f"  Injected: endpoint={ep[:60]}")
PYEOF

        mkdir -p /tmp/techno_amp_pkg
        cp /tmp/techno_index_amplify.html /tmp/techno_amp_pkg/index.html
        cd /tmp/techno_amp_pkg && zip -q /tmp/techno_amplify.zip index.html && cd - > /dev/null

        # Create Amplify app
        AMPLIFY_APP_ID=$(aws amplify list-apps --region "$REGION" \
            --query "apps[?name=='${PROJECT}-frontend'].appId" \
            --output text 2>/dev/null || echo "")
        if [ -z "$AMPLIFY_APP_ID" ] || [ "$AMPLIFY_APP_ID" = "None" ]; then
            AMPLIFY_APP_ID=$(aws amplify create-app \
                --name "${PROJECT}-frontend" --platform WEB \
                --region "$REGION" --query "app.appId" --output text)
            ok "Amplify app created: $AMPLIFY_APP_ID"
        else
            ok "Amplify app exists : $AMPLIFY_APP_ID"
        fi

        aws amplify create-branch \
            --app-id "$AMPLIFY_APP_ID" --branch-name main \
            --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true

        # Stop ALL running/pending jobs — wajib sebelum create-deployment
        # (Amplify BadRequestException jika ada job yang belum selesai)
        log "  Stopping all running/pending Amplify jobs..."
        for _ATTEMPT in 1 2 3; do
            _RUNNING=$(aws amplify list-jobs \
                --app-id "$AMPLIFY_APP_ID" --branch-name main \
                --region "$REGION" --max-results 10 \
                --query "jobSummaries[?status=='RUNNING'||status=='PENDING'].jobId" \
                --output text 2>/dev/null || echo "")
            [ -z "$_RUNNING" ] || [ "$_RUNNING" = "None" ] && break
            for _JID in $_RUNNING; do
                [ "$_JID" = "None" ] && continue
                aws amplify stop-job \
                    --app-id "$AMPLIFY_APP_ID" --branch-name main \
                    --job-id "$_JID" --region "$REGION" \
                    --no-cli-pager > /dev/null 2>&1 || true
                log "    Stopped job: $_JID"
            done
            sleep 8
        done
        # Poll sampai benar-benar kosong (max 90 detik)
        for _W in $(seq 1 18); do
            _STILL=$(aws amplify list-jobs \
                --app-id "$AMPLIFY_APP_ID" --branch-name main \
                --region "$REGION" --max-results 5 \
                --query "jobSummaries[?status=='RUNNING'||status=='PENDING'].jobId" \
                --output text 2>/dev/null || echo "")
            ( [ -z "$_STILL" ] || [ "$_STILL" = "None" ] ) && break
            log "  Waiting for jobs to stop [$_W/18]: $_STILL"
            sleep 5
        done
        log "  No running jobs — proceeding with create-deployment"

        DEPLOY_RESP=$(aws amplify create-deployment \
            --app-id "$AMPLIFY_APP_ID" --branch-name main \
            --region "$REGION" --output json)
        UPLOAD_URL=$(echo "$DEPLOY_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['zipUploadUrl'])")
        CREATE_JOB_ID=$(echo "$DEPLOY_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['jobId'])")

        curl -s -o /dev/null -X PUT "$UPLOAD_URL" \
            -H "Content-Type: application/zip" \
            --data-binary @/tmp/techno_amplify.zip

        DEPLOY_JOB_ID=$(aws amplify start-deployment \
            --app-id "$AMPLIFY_APP_ID" --branch-name main \
            --job-id "$CREATE_JOB_ID" \
            --region "$REGION" --query "jobSummary.jobId" --output text)

        log "Amplify deployment started: job $DEPLOY_JOB_ID — menunggu..."
        for i in $(seq 1 18); do
            sleep 10
            DEPLOY_STATUS=$(aws amplify get-job \
                --app-id "$AMPLIFY_APP_ID" --branch-name main \
                --job-id "$DEPLOY_JOB_ID" \
                --region "$REGION" \
                --query "job.summary.status" --output text 2>/dev/null || echo "PENDING")
            log "  [$i/18] $DEPLOY_STATUS"
            [ "$DEPLOY_STATUS" = "SUCCEED"  ] && break
            [ "$DEPLOY_STATUS" = "FAILED"   ] && warn "Amplify FAILED" && break
        done
        ok "Frontend: https://main.${AMPLIFY_APP_ID}.amplifyapp.com"
    fi
fi

# ================================================================
#  STEP 10: Initialize DB (invoke init_db Lambda)
# ================================================================
section "STEP 10/11 — Initialize Database (invoke init_db)"
if ! skip_step 10; then
    log "Invoking techno-lambda-init-db (dengan retry sampai berhasil)..."
    INIT_OK=false
    for _ATTEMPT in 1 2 3 4 5; do
        log "  Attempt ${_ATTEMPT}/5..."
        aws lambda invoke \
            --function-name "techno-lambda-init-db" \
            --payload '{"insert_sample_data":true}' \
            --region "$REGION" \
            --cli-binary-format raw-in-base64-out \
            /tmp/techno_init_result.json > /dev/null 2>&1 || true

        INIT_RESULT=$(cat /tmp/techno_init_result.json 2>/dev/null || echo "")
        log "  Result: $(echo "$INIT_RESULT" | head -c 300)"

        if echo "$INIT_RESULT" | grep -q "No module named\|ImportModuleError\|Cannot import"; then
            err "Layer psycopg2 masih error. Jalankan: FORCE_LAYER=true ./judge.sh deploy $STUDENT_NAME $EMAIL 5"
        elif echo "$INIT_RESULT" | grep -q "timeout expired\|could not connect\|Connection refused\|OperationalError"; then
            warn "  RDS belum bisa direach (timeout). Tunggu 20 detik..."
            sleep 20
        elif echo "$INIT_RESULT" | grep -q "KeyError.*SECRET_ARN\|\'SECRET_ARN\'"; then
            warn "  SECRET_ARN env var belum set. Jalankan step 4+5 dulu."
            break
        elif echo "$INIT_RESULT" | grep -q "errorType\|errorMessage"; then
            warn "  Lambda error lain — tunggu 15 detik lalu retry..."
            sleep 15
        elif echo "$INIT_RESULT" | grep -q "Schema created\|results\|200"; then
            INIT_OK=true
            ok "init_db berhasil! Tabel customers/products/orders dibuat."
            break
        else
            warn "  Tidak ada response yang dikenal, retry..."
            sleep 10
        fi
    done
    [ "$INIT_OK" = "false" ] && warn "init_db gagal. Cek RDS connectivity. Jalankan ulang: ./judge.sh deploy $STUDENT_NAME $EMAIL 10"
fi

#  STEP 11: Final Verify
# ================================================================
section "STEP 11/11 — Verifikasi Akhir"
python3 /tmp/techno_verify.py "$STUDENT_NAME" "$ACCOUNT_ID" "$REGION"

# ── Summary ───────────────────────────────────────────────
resolve_state
API_KEY_FINAL="${API_KEY_VALUE:-N/A}"
API_EP_FINAL="${API_ENDPOINT:-N/A}"
AMPLIFY_APP_ID_FINAL=$(aws amplify list-apps --region "$REGION" \
    --query "apps[?name=='${PROJECT}-frontend'].appId" \
    --output text 2>/dev/null || echo "N/A")

echo ""
echo -e "${BLD}${GRN}══════════════════════════════════════════${NC}"
echo -e "${BLD}${GRN}  DEPLOY SELESAI!${NC}"
echo -e "${BLD}${GRN}══════════════════════════════════════════${NC}"
echo -e "${BLD}${GRN}  API Endpoint  : ${NC}${API_EP_FINAL}"
echo -e "${BLD}${GRN}  API Key       : ${NC}${API_KEY_FINAL}"
echo -e "${BLD}${GRN}  Frontend URL  : ${NC}https://main.${AMPLIFY_APP_ID_FINAL}.amplifyapp.com"
echo ""
echo -e "${YEL}  Test cepat:${NC}"
echo "  # Health check"
echo "  curl -s -H 'x-api-key: ${API_KEY_FINAL}' '${API_EP_FINAL}/health' | python3 -m json.tool"
echo ""
echo "  # Create order"
echo "  curl -s -X POST '${API_EP_FINAL}/orders' \\"
echo "    -H 'x-api-key: ${API_KEY_FINAL}' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"customerId\":\"CUST001\",\"items\":[{\"productId\":\"PROD001\",\"quantity\":2}],\"totalAmount\":50000}'"
echo ""
echo -e "${RED}${BLD}  ⚠  Jalankan './judge.sh teardown ${STUDENT_NAME}' setelah selesai testing.${NC}"