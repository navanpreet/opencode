#!/usr/bin/env bash
set -euo pipefail

# Usage: ./deploy.sh <version>
# Example: ./deploy.sh 1.0.9

VERSION="${1:?Usage: ./deploy.sh <version>}"
MODELS_URL="https://get.abundance.sh"
S3_BUCKET="s3://abundance-apex"
AWS_PROFILE="abundance"
AWS_REGION="us-east-2"
CF_DISTRIBUTION="ETL8BNP504ZP8"
DIST="packages/opencode/dist"
TARGETS=(darwin-arm64 darwin-x64 linux-arm64 linux-x64)

echo "==> Building Apex Code v${VERSION}"
rm -f ~/.cache/opencode/models.json
OPENCODE_VERSION="$VERSION" OPENCODE_CHANNEL=latest OPENCODE_MODELS_URL="$MODELS_URL" \
  bun run --cwd packages/opencode build

echo "==> Packaging tarballs"
TMP=$(mktemp -d)
for target in "${TARGETS[@]}"; do
  cp "$DIST/opencode-${target}/bin/opencode" "$TMP/apex"
  tar -czf "/tmp/apex-${target}-v${VERSION}.tar.gz" -C "$TMP" apex
  rm "$TMP/apex"
  echo "    apex-${target}-v${VERSION}.tar.gz"
done
rm -rf "$TMP"

echo "==> Installing locally (darwin-arm64)"
cp "$DIST/opencode-darwin-arm64/bin/opencode" ~/.local/bin/apex
codesign -s - ~/.local/bin/apex 2>/dev/null || true
echo "    $(apex --version)"

echo "==> Uploading to S3"
for target in "${TARGETS[@]}"; do
  for attempt in 1 2 3; do
    if aws s3 cp "/tmp/apex-${target}-v${VERSION}.tar.gz" \
      "${S3_BUCKET}/apex-${target}-v${VERSION}.tar.gz" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null; then
      echo "    ${target} uploaded"
      break
    fi
    echo "    ${target} attempt ${attempt} failed, retrying..."
  done
done

echo "==> Updating version.txt to ${VERSION}"
echo -n "${VERSION}" | aws s3 cp - "${S3_BUCKET}/version.txt" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" --content-type "text/plain"

echo "==> Invalidating CloudFront"
aws cloudfront create-invalidation \
  --distribution-id "$CF_DISTRIBUTION" --paths "/*" \
  --profile "$AWS_PROFILE" --output text | head -3

echo "==> Done! Apex Code v${VERSION} deployed."
