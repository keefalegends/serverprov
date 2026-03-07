#!/bin/bash
# fix-alias.sh — Update semua alias 'live' ke version terbaru (yang sudah ada layer baru)
set -e

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${YELLOW}[→] $1${NC}"; }
success() { echo -e "${GREEN}[✓] $1${NC}"; }

info "Mengecek credentials..."
aws sts get-caller-identity --query Account --output text > /dev/null || exit 1

FUNCTIONS=(order-management process-payment update-inventory send-notification generate-report health-check)

info "Update alias 'live' ke version terbaru..."
for fn in "${FUNCTIONS[@]}"; do
  FUNC="techno-lambda-${fn}"
  printf "  %-40s" "$FUNC"

  # Publish version baru (dengan layer yang baru ter-attach)
  VERSION=$(aws lambda publish-version \
    --function-name "$FUNC" \
    --region "$REGION" \
    --query 'Version' --output text --no-cli-pager 2>/dev/null)

  # Update alias live ke version baru
  ALIAS_EXISTS=$(aws lambda get-alias \
    --function-name "$FUNC" --name live \
    --region "$REGION" --query 'Name' --output text --no-cli-pager 2>/dev/null || echo "")

  if [ "$ALIAS_EXISTS" = "live" ]; then
    aws lambda update-alias \
      --function-name "$FUNC" --name live \
      --function-version "$VERSION" \
      --region "$REGION" --no-cli-pager --output text --query 'Name' > /dev/null
    echo -e "v${VERSION} ${GREEN}OK${NC}"
  else
    echo -e "${YELLOW}no alias - skipped${NC}"
  fi
done

success "Selesai! Test:"
echo "  curl -s -H \"x-api-key: YOUR_KEY\" https://YOUR_API.execute-api.${REGION}.amazonaws.com/production/health"
