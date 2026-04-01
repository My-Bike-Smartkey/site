#!/bin/bash
# =============================================================================
# build_and_distribute.sh
# Build IPA và upload lên TestFlight
# 
# Usage:
#   TestFlight: ./build_and_distribute.sh testflight
#   Chỉ build:  ./build_and_distribute.sh
# =============================================================================

set -e

# ── Cấu hình ──────────────────────────────────────────────────────────────
PROJECT="DatBikeSmartkey.xcodeproj"
SCHEME="DatBikeSmartkey"
ARCHIVE_PATH="./build/DatBikeSmartkey.xcarchive"
OUTPUT_DIR="./build"
IPA_PATH="$OUTPUT_DIR/DatBikeSmartkey.ipa"

DISTRIBUTION="${1:-}" # testflight | (trống = chỉ build)
RELEASE_NOTES="Beta $(date '+%d/%m/%Y %H:%M'): Fix BLE Zombie Session, Auto-Reconnect"

# Xử lý App Store Connect API Key (Nếu chạy trực tiếp không qua Xcode)
XCODEBUILD_AUTH_ARGS=""
if [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ] && [ -n "$ASC_KEY_PATH" ]; then
    log_info "Sử dụng App Store Connect API Key để xác thực..."
    XCODEBUILD_AUTH_ARGS="-authenticationKeyPath \"$ASC_KEY_PATH\" -authenticationKeyID \"$ASC_KEY_ID\" -authenticationKeyIssuerID \"$ASC_ISSUER_ID\""
fi

# ExportOptions theo loại distribution
if [ "$DISTRIBUTION" = "testflight" ]; then
    EXPORT_OPTIONS="./ExportOptions.testflight.plist"
else
    EXPORT_OPTIONS="./ExportOptions.plist"
fi

# ── Màu sắc log ───────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${YELLOW}► $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; exit 1; }
log_step()    { echo -e "${BLUE}━━━ $1 ━━━${NC}"; }

echo ""
log_step "MyBike Smartkey — Build Script"
echo "Distribution: ${DISTRIBUTION:-'Build only'}"
echo ""

# ── 1. Clean ──────────────────────────────────────────────────────────────
log_info "Dọn build cũ..."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# ── 2. Archive ────────────────────────────────────────────────────────────
log_info "Đang archive ($SCHEME)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  -allowProvisioningUpdates \
  $XCODEBUILD_AUTH_ARGS \
  -quiet

log_success "Archive thành công!"

# ── 3. Export IPA ─────────────────────────────────────────────────────────
log_info "Đang export ($EXPORT_OPTIONS)..."
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$OUTPUT_DIR" \
  -allowProvisioningUpdates \
  $XCODEBUILD_AUTH_ARGS \
  -quiet

if [ "$DISTRIBUTION" != "testflight" ] && [ ! -f "$IPA_PATH" ]; then
  log_error "Không tìm thấy IPA tại $IPA_PATH"
fi

log_success "Export thành công!"

# ── 4. Distribution ───────────────────────────────────────────────────────
case "$DISTRIBUTION" in

  "testflight")
    log_info "Đã upload lên App Store Connect (TestFlight)!"
    log_success "Vào https://appstoreconnect.apple.com → Tools → TestFlight để mời tester."
    echo ""
    echo "  → Vào App Store Connect"
    echo "  → Chọn app MyBike Smartkey"  
    echo "  → TestFlight tab → Invite testers bằng email"
    ;;

  *)
    IPA_SIZE=$(du -sh "$IPA_PATH" 2>/dev/null | cut -f1 || echo "N/A")
    log_success "Build xong! IPA ($IPA_SIZE) tại: $IPA_PATH"
    echo ""
    echo "Upload thủ công:"
    echo "  TestFlight: ./build_and_distribute.sh testflight"
    echo ""
    echo "Lưu ý nếu build TestFlight không có Xcode UI, cần set biến môi trường:"
    echo "  export ASC_KEY_ID='your_key_id'"
    echo "  export ASC_ISSUER_ID='your_issuer_id'"
    echo "  export ASC_KEY_PATH='/path/to/AuthKey.p8'"
    ;;
esac

echo ""
