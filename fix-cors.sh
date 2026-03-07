#!/bin/bash
# fix-cors.sh — Enable CORS di API Gateway yang sudah ada
set -e

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
API_ID="ptqqkylqke"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${YELLOW}[→] $1${NC}"; }
success() { echo -e "${GREEN}[✓] $1${NC}"; }
error()   { echo -e "${RED}[✗] $1${NC}"; exit 1; }

# Resolve AWS CLI secara eksplisit
AWS=$(which aws 2>/dev/null || echo "/usr/local/bin/aws")
[ -x "$AWS" ] || error "AWS CLI tidak ditemukan: $AWS"
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

# Override API ID jika ada argument
[ -n "$1" ] && API_ID="$1"

info "AWS CLI: $AWS"
info "API ID: $API_ID | Region: $REGION"

# Validasi credentials
$AWS sts get-caller-identity --query Account --output text > /dev/null \
  || error "AWS credentials tidak valid"

# Ambil semua resource IDs
info "Mengambil daftar resources..."
mapfile -t RES_LIST < <($AWS apigateway get-resources \
  --rest-api-id "$API_ID" \
  --region "$REGION" \
  --query 'items[?path!=`/`].[id,path]' \
  --output text --no-cli-pager)

info "Menambah OPTIONS method ke setiap resource..."
for ROW in "${RES_LIST[@]}"; do
  RES_ID=$(echo "$ROW" | awk '{print $1}')
  RES_PATH=$(echo "$ROW" | awk '{print $2}')
  [ -z "$RES_ID" ] && continue

  printf "  %-25s" "$RES_PATH"

  # Cek OPTIONS sudah ada
  EXISTING=$($AWS apigateway get-method \
    --rest-api-id "$API_ID" --resource-id "$RES_ID" \
    --http-method OPTIONS --region "$REGION" \
    --output text --no-cli-pager 2>/dev/null || echo "")
  if [ -n "$EXISTING" ]; then
    echo -e "${YELLOW}skip (exists)${NC}"; continue
  fi

  # OPTIONS method
  $AWS apigateway put-method \
    --rest-api-id "$API_ID" --resource-id "$RES_ID" \
    --http-method OPTIONS --authorization-type NONE --no-api-key-required \
    --region "$REGION" --no-cli-pager > /dev/null

  # MOCK integration
  $AWS apigateway put-integration \
    --rest-api-id "$API_ID" --resource-id "$RES_ID" \
    --http-method OPTIONS --type MOCK \
    --request-templates '{"application/json":"{\"statusCode\":200}"}' \
    --region "$REGION" --no-cli-pager > /dev/null

  # Method response
  $AWS apigateway put-method-response \
    --rest-api-id "$API_ID" --resource-id "$RES_ID" \
    --http-method OPTIONS --status-code 200 \
    --response-parameters '{"method.response.header.Access-Control-Allow-Headers":false,"method.response.header.Access-Control-Allow-Methods":false,"method.response.header.Access-Control-Allow-Origin":false}' \
    --region "$REGION" --no-cli-pager > /dev/null

  # Integration response dengan CORS headers
  $AWS apigateway put-integration-response \
    --rest-api-id "$API_ID" --resource-id "$RES_ID" \
    --http-method OPTIONS --status-code 200 \
    --response-parameters '{"method.response.header.Access-Control-Allow-Headers":"'"'"'Content-Type,x-api-key,X-Amz-Date,Authorization'"'"'","method.response.header.Access-Control-Allow-Methods":"'"'"'GET,POST,PUT,DELETE,OPTIONS'"'"'","method.response.header.Access-Control-Allow-Origin":"'"'"'*'"'"'"}' \
    --region "$REGION" --no-cli-pager > /dev/null

  echo -e "${GREEN}OK${NC}"
done

# Deploy ke stage production
info "Deploy ke stage production..."
DEPLOY_ID=$($AWS apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name production \
  --description "CORS fix $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --region "$REGION" \
  --query 'id' --output text --no-cli-pager)
success "Deployed: $DEPLOY_ID"

# Test preflight
info "Test CORS preflight /health..."
sleep 2
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X OPTIONS \
  -H "Origin: https://main.d3tsxar96e7e6a.amplifyapp.com" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: x-api-key" \
  "https://${API_ID}.execute-api.${REGION}.amazonaws.com/production/health")

[ "$HTTP" = "200" ] && success "Preflight OK (HTTP 200)" || echo "  HTTP $HTTP"

echo ""
success "CORS fix selesai! Refresh browser Amplify."
