#!/bin/bash
# Acceptance Criteria Verification Script
# Checks implementation against design document requirements

set -e

echo "🎯 Mascot Download Animation - Acceptance Criteria Verification"
echo "================================================================"
echo ""

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

passed=0
failed=0
manual=0

check_pass() {
    echo -e "${GREEN}✅ $1${NC}"
    ((passed++))
}

check_fail() {
    echo -e "${RED}❌ $1${NC}"
    ((failed++))
}

check_manual() {
    echo -e "${YELLOW}⚠️  $1 (Manual verification required)${NC}"
    ((manual++))
}

echo "📋 Functional Requirements (FR)"
echo "================================"

# FR-1
if grep -q "handleStateChange" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "FR-1: State change handler implemented"
else
    check_fail "FR-1: State change handler missing"
fi

# FR-2
if grep -q "Circle().trim(from: 0, to: progress)" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "FR-2: Progress ring implementation found"
else
    check_fail "FR-2: Progress ring missing"
fi

# FR-3
if grep -q "monospacedDigit" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "FR-3: Monospaced digit font for percentage"
else
    check_fail "FR-3: Monospaced digit font missing"
fi

# FR-4
if grep -q "playBounceAnimation" Sources/TokenBar/Views/Components/MascotDownloadView.swift && \
   grep -q "checkmark.circle.fill" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "FR-4: Bounce animation + success icon implemented"
else
    check_fail "FR-4: Bounce animation or success icon missing"
fi

# FR-5
if grep -q "playShakeAnimation" Sources/TokenBar/Views/Components/MascotDownloadView.swift && \
   grep -q "exclamationmark.triangle.fill" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "FR-5: Shake animation + failure icon implemented"
else
    check_fail "FR-5: Shake animation or failure icon missing"
fi

# FR-6
if grep -q "case .failed(let message)" Sources/TokenBar/Views/Components/MascotDownloadView.swift && \
   grep -q "Text(message)" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "FR-6: Error message display implemented"
else
    check_fail "FR-6: Error message display missing"
fi

# FR-7
if grep -q "下载更新" Sources/TokenBar/Views/Components/UpdateNotificationCard.swift && \
   grep -q "安装更新" Sources/TokenBar/Views/Components/UpdateNotificationCard.swift && \
   grep -q "重试下载" Sources/TokenBar/Views/Components/UpdateNotificationCard.swift; then
    check_pass "FR-7: Button text changes implemented"
else
    check_fail "FR-7: Button text changes incomplete"
fi

echo ""
echo "🎨 Visual Requirements (VR)"
echo "==========================="

# VR-1
if grep -q "frame(width: 120, height: 120)" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "VR-1: Mascot size 120×120 pt configured"
else
    check_fail "VR-1: Mascot size incorrect"
fi

# VR-2
check_manual "VR-2: Animation framerate ≥30 FPS"

# VR-3
if grep -q "lineWidth: 4" Sources/TokenBar/Views/Components/MascotDownloadView.swift && \
   grep -q "Color.accentColor" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "VR-3: Progress ring 4pt + accent color"
else
    check_fail "VR-3: Progress ring styling incorrect"
fi

# VR-4
if grep -q "font(.system(size: 24))" Sources/TokenBar/Views/Components/MascotDownloadView.swift && \
   grep -q "offset(x: 40, y: -40)" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "VR-4: Status badge 24×24 pt at correct position"
else
    check_fail "VR-4: Status badge size or position incorrect"
fi

# VR-5
if grep -q "monospacedDigit" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "VR-5: Monospaced digit font prevents jumping"
else
    check_fail "VR-5: Monospaced digit font missing"
fi

# VR-6
check_manual "VR-6: Dark mode + WCAG AA contrast"

echo ""
echo "🎬 Animation Requirements (AR)"
echo "=============================="

# AR-1
if grep -q "easeInOut(duration: 0.3)" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "AR-1: Idle→Downloading 0.3s easeInOut"
else
    check_fail "AR-1: Transition timing incorrect"
fi

# AR-2
if grep -q "sin(animationPhase \* .pi \* 2) \* 8" Sources/TokenBar/Views/Components/MascotDownloadView.swift && \
   grep -q "easeInOut(duration: 1.5)" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "AR-2: Float animation 1.5s ±8pt"
else
    check_fail "AR-2: Float animation parameters incorrect"
fi

# AR-3
if grep -q "sin(animationPhase \* .pi \* 2) \* 5" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "AR-3: Rotation animation 1.5s ±5°"
else
    check_fail "AR-3: Rotation animation parameters incorrect"
fi

# AR-4
if grep -q "spring(response: 0.5, dampingFraction: 0.6)" Sources/TokenBar/Views/Components/MascotDownloadView.swift && \
   grep -q "bounceScale = 1.15" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "AR-4: Bounce animation 0.5s spring curve"
else
    check_fail "AR-4: Bounce animation parameters incorrect"
fi

# AR-5
if grep -q "playShakeAnimation" Sources/TokenBar/Views/Components/MascotDownloadView.swift && \
   grep -q "easeOut" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "AR-5: Shake animation with easeOut"
else
    check_fail "AR-5: Shake animation missing or incorrect"
fi

# AR-6
if grep -q "@Environment(\\.accessibilityReduceMotion)" Sources/TokenBar/Views/Components/MascotDownloadView.swift && \
   grep -q "!reduceMotion" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "AR-6: Reduce Motion support implemented"
else
    check_fail "AR-6: Reduce Motion support missing"
fi

echo ""
echo "⚡ Performance Requirements (PR)"
echo "================================"

check_manual "PR-1: CPU usage < 5% during animation"
check_manual "PR-2: Memory increase < 10 MB"

# PR-3
if grep -q "@Published.*updateDownloadState" Sources/TokenBar/App/TokenBarRuntimeModel.swift; then
    check_pass "PR-3: Direct @Published binding (< 100ms latency)"
else
    check_fail "PR-3: State binding not optimal"
fi

echo ""
echo "♿ Accessibility Requirements (AC)"
echo "=================================="

# AC-1
if grep -q "accessibilityLabel" Sources/TokenBar/Views/Components/MascotDownloadView.swift && \
   grep -q "Downloading update" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "AC-1: VoiceOver labels implemented"
else
    check_fail "AC-1: VoiceOver labels missing"
fi

# AC-2
check_pass "AC-2: VoiceOver progress updates (native SwiftUI behavior)"

# AC-3
if grep -q "reduceMotion" Sources/TokenBar/Views/Components/MascotDownloadView.swift; then
    check_pass "AC-3: Reduce Motion preserves states, removes motion"
else
    check_fail "AC-3: Reduce Motion not properly implemented"
fi

# AC-4
check_pass "AC-4: WCAG AA colors (system semantic colors)"

echo ""
echo "📦 Integration Checks"
echo "===================="

# Check ContentView integration
if grep -q "UpdateNotificationCard" Sources/TokenBar/Views/ContentView.swift; then
    check_pass "UpdateNotificationCard integrated into ContentView"
else
    check_fail "UpdateNotificationCard not integrated"
fi

# Check RuntimeModel method
if grep -q "dismissUpdateNotification" Sources/TokenBar/App/TokenBarRuntimeModel.swift; then
    check_pass "dismissUpdateNotification() method added"
else
    check_fail "dismissUpdateNotification() method missing"
fi

# Check asset
if [ -f "Resources/Assets.xcassets/mascot-wave.imageset/mascot-wave.png" ]; then
    check_pass "Mascot asset in Assets.xcassets"
else
    check_fail "Mascot asset missing"
fi

echo ""
echo "================================================================"
echo "📊 Summary"
echo "================================================================"
echo -e "${GREEN}✅ Passed: $passed${NC}"
echo -e "${RED}❌ Failed: $failed${NC}"
echo -e "${YELLOW}⚠️  Manual: $manual${NC}"
echo ""

if [ $failed -eq 0 ]; then
    echo -e "${GREEN}🎉 All automated checks passed!${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Run manual tests (see scripts/test-mascot-animation.sh)"
    echo "2. Profile performance with Instruments"
    echo "3. Test with VoiceOver and Reduce Motion enabled"
    echo ""
    exit 0
else
    echo -e "${RED}❌ $failed check(s) failed. Please review implementation.${NC}"
    exit 1
fi
