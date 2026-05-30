#!/bin/bash
# Manual test script for mascot download animation
# This script helps verify the implementation against acceptance criteria

set -e

echo "🧪 Mascot Download Animation - Manual Test Guide"
echo "================================================"
echo ""

# Build the app
echo "📦 Building TokenBar..."
swift build --target TokenBar > /dev/null 2>&1
echo "✅ Build successful"
echo ""

# Check asset exists
echo "🎨 Checking mascot asset..."
if [ -f "Resources/Assets.xcassets/mascot-wave.imageset/mascot-wave.png" ]; then
    echo "✅ Mascot asset found in Assets.xcassets"
else
    echo "❌ Mascot asset missing"
    exit 1
fi
echo ""

# Check component files exist
echo "📄 Checking component files..."
components=(
    "Sources/TokenBar/Views/Components/MascotDownloadView.swift"
    "Sources/TokenBar/Views/Components/UpdateNotificationCard.swift"
)

for component in "${components[@]}"; do
    if [ -f "$component" ]; then
        echo "✅ $component"
    else
        echo "❌ $component missing"
        exit 1
    fi
done
echo ""

# Check integration
echo "🔗 Checking ContentView integration..."
if grep -q "UpdateNotificationCard" Sources/TokenBar/Views/ContentView.swift; then
    echo "✅ UpdateNotificationCard integrated into ContentView"
else
    echo "❌ UpdateNotificationCard not found in ContentView"
    exit 1
fi
echo ""

# Check RuntimeModel method
echo "🔧 Checking RuntimeModel methods..."
if grep -q "dismissUpdateNotification" Sources/TokenBar/App/TokenBarRuntimeModel.swift; then
    echo "✅ dismissUpdateNotification() method added"
else
    echo "❌ dismissUpdateNotification() method missing"
    exit 1
fi
echo ""

echo "✅ All automated checks passed!"
echo ""
echo "📋 Manual Testing Checklist"
echo "============================"
echo ""
echo "To complete verification, please manually test the following:"
echo ""
echo "1. Visual States:"
echo "   [ ] Idle state: Mascot displays at 120×120 pt"
echo "   [ ] Downloading state: Progress ring appears around mascot"
echo "   [ ] Downloading state: Percentage text shows below mascot"
echo "   [ ] Completed state: Green checkmark badge appears"
echo "   [ ] Failed state: Red warning badge appears"
echo ""
echo "2. Animations:"
echo "   [ ] Downloading: Mascot floats up/down (±8pt)"
echo "   [ ] Downloading: Mascot rotates slightly (±5°)"
echo "   [ ] Downloading: Progress ring animates smoothly"
echo "   [ ] Completed: Mascot bounces (scale 1.0 → 1.15 → 1.0)"
echo "   [ ] Failed: Mascot shakes briefly"
echo ""
echo "3. Interactions:"
echo "   [ ] Click '下载更新' → enters downloading state"
echo "   [ ] Progress updates in real-time"
echo "   [ ] Click '安装更新' → opens DMG"
echo "   [ ] Click 'X' button → dismisses notification"
echo "   [ ] Click '重试下载' → restarts download"
echo ""
echo "4. Accessibility:"
echo "   [ ] VoiceOver reads state correctly"
echo "   [ ] Reduce Motion: animations disabled"
echo "   [ ] Dark mode: colors adapt correctly"
echo ""
echo "5. Performance:"
echo "   [ ] Animation runs at ≥30 FPS"
echo "   [ ] CPU usage < 5% during animation"
echo "   [ ] No memory leaks"
echo ""
echo "To run the app for manual testing:"
echo "  swift run TokenBar"
echo ""
echo "To simulate an update available:"
echo "  1. Modify UpdateChecker to return a fake update"
echo "  2. Or wait for a real update check"
echo ""
