#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║   fix-layer.sh — Rebuild & re-attach psycopg2 Lambda layer  ║
# ║   Jalankan ini jika Lambda error: No module named psycopg2  ║
# ╚══════════════════════════════════════════════════════════════╝
set -e

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
LAYER_NAME="techno-layer-dependencies"
TMP="/tmp/fix-layer-$$"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${YELLOW}[→] $1${NC}"; }
success() { echo -e "${GREEN}[✓] $1${NC}"; }
error()   { echo -e "${RED}[✗] $1${NC}"; exit 1; }

# ── Validasi credentials ──────────────────────────────────────
info "Mengecek AWS credentials..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || error "AWS credentials tidak valid."
success "Account: $ACCOUNT_ID | Region: $REGION"

# ── Cari S3 bucket layer ──────────────────────────────────────
info "Mencari S3 bucket layer..."
LAYER_BUCKET=$(aws s3 ls 2>/dev/null | awk '{print $3}' | grep "techno-layer" | head -1)
[ -z "$LAYER_BUCKET" ] && error "Bucket techno-layer-* tidak ditemukan."
success "Bucket: $LAYER_BUCKET"

# ── Build layer ───────────────────────────────────────────────
mkdir -p "$TMP/python"
info "Building layer untuk Lambda Amazon Linux 2 (python3.11 x86_64)..."

# Metode 1: pip dengan platform flag (untuk binary yang kompatibel Lambda)
if pip3 install \
    psycopg2-binary \
    aws-xray-sdk \
    wrapt \
    -t "$TMP/python/" \
    --quiet \
    --no-cache-dir \
    --python-version 3.11 \
    --platform manylinux2014_x86_64 \
    --implementation cp \
    --only-binary=:all: 2>/dev/null; then
  success "Build via pip --platform OK"

# Metode 2: Docker (paling akurat, sama persis environment Lambda)
elif command -v docker &>/dev/null; then
  info "Fallback: build via Docker (Amazon Linux 2)..."
  rm -rf "$TMP/python" && mkdir -p "$TMP/python"
  docker run --rm \
    -v "$TMP/python:/var/task/python" \
    public.ecr.aws/lambda/python:3.11 \
    pip install psycopg2-binary aws-xray-sdk wrapt \
      -t /var/task/python \
      --quiet --no-cache-dir
  success "Build via Docker OK"

else
  error "pip --platform gagal dan Docker tidak tersedia. Install Docker atau upgrade pip: pip3 install --upgrade pip"
fi

# ── Verifikasi ────────────────────────────────────────────────
[ -d "$TMP/python/psycopg2" ] || error "psycopg2 tidak ada di hasil build"

# Pastikan ada .so file yang benar untuk manylinux
SO_FILE=$(find "$TMP/python/psycopg2" -name "_psycopg*.so" 2>/dev/null | head -1)
if [ -z "$SO_FILE" ]; then
  error "File _psycopg*.so tidak ditemukan — binary tidak kompatibel Lambda"
fi
success "Binary OK: $(basename $SO_FILE)"

# ── Zip ───────────────────────────────────────────────────────
info "Membuat zip..."
cd "$TMP"
zip -r "techno-layer-dependencies.zip" python/ -q
success "Layer zip: $(du -sh techno-layer-dependencies.zip | cut -f1)"

# Verifikasi struktur zip
FIRST=$(unzip -l "$TMP/techno-layer-dependencies.zip" | grep psycopg2 | head -1 | awk '{print $NF}')
[[ "$FIRST" == python/* ]] || error "Struktur zip salah: $FIRST (harus python/...)"
success "Struktur zip benar: python/psycopg2/ ✓"

# ── Upload S3 ─────────────────────────────────────────────────
info "Upload ke s3://$LAYER_BUCKET/layer/..."
aws s3 cp "$TMP/techno-layer-dependencies.zip" \
  "s3://${LAYER_BUCKET}/layer/techno-layer-dependencies.zip" \
  --region "$REGION"
success "Upload selesai"

# ── Publish layer version baru ────────────────────────────────
info "Publish layer version..."
LAYER_ARN=$(aws lambda publish-layer-version \
  --layer-name "$LAYER_NAME" \
  --description "psycopg2-binary manylinux2014_x86_64 python3.11" \
  --content "S3Bucket=${LAYER_BUCKET},S3Key=layer/techno-layer-dependencies.zip" \
  --compatible-runtimes python3.11 \
  --region "$REGION" \
  --query 'LayerVersionArn' \
  --output text \
  --no-cli-pager)
success "Layer ARN: $LAYER_ARN"

# ── Attach ke semua 7 fungsi ──────────────────────────────────
info "Attaching layer ke semua Lambda functions..."
FUNCTIONS=(order-management process-payment update-inventory send-notification generate-report init-db health-check)

for fn in "${FUNCTIONS[@]}"; do
  FUNC="techno-lambda-${fn}"
  printf "  %-40s" "$FUNC"
  if aws lambda update-function-configuration \
      --function-name "$FUNC" \
      --layers "$LAYER_ARN" \
      --region "$REGION" \
      --no-cli-pager --output text --query 'FunctionName' &>/dev/null; then
    aws lambda wait function-updated --function-name "$FUNC" --region "$REGION" 2>/dev/null
    echo -e "${GREEN}OK${NC}"
  else
    echo -e "${RED}SKIP${NC}"
  fi
done

# ── Test invoke ───────────────────────────────────────────────
info "Testing invoke health-check..."
aws lambda invoke \
  --function-name techno-lambda-health-check \
  --payload '{}' \
  --region "$REGION" \
  --no-cli-pager \
  "$TMP/result.json" &>/dev/null

RESULT=$(cat "$TMP/result.json" 2>/dev/null || echo '{}')

if echo "$RESULT" | grep -q "psycopg2\|ImportModule"; then
  echo -e "${RED}[✗] Masih error: $RESULT${NC}"
  echo "    Coba jalankan script ini di AWS CloudShell (sudah Amazon Linux)"
elif echo "$RESULT" | grep -q '"status"'; then
  STATUS=$(echo "$RESULT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null)
  success "Health check: $STATUS"
else
  echo "  Response: $RESULT"
fi

rm -rf "$TMP"
echo ""
success "Selesai! Layer ARN: $LAYER_ARN"
