#!/bin/bash
# Quick demo script to simulate update states
# This creates a standalone demo window to showcase the mascot animation

cat << 'SWIFT_CODE' > /tmp/MascotAnimationDemo.swift
import SwiftUI
import TokenBarCore

@main
struct MascotAnimationDemoApp: App {
    var body: some Scene {
        WindowGroup {
            DemoView()
        }
    }
}

struct DemoView: View {
    @State private var selectedState = 0
    @State private var progress: Double = 0.0
    @State private var isAnimating = false

    let states = ["Idle", "Downloading", "Completed", "Failed"]

    var currentDownloadState: AppUpdateDownloadState {
        switch selectedState {
        case 0: return .idle
        case 1: return .downloading(progress: progress)
        case 2: return .completed(localURL: URL(fileURLWithPath: "/tmp/TokenBar-demo.dmg"))
        case 3: return .failed(message: "Network connection lost")
        default: return .idle
        }
    }

    var body: some View {
        VStack(spacing: 30) {
            Text("🎭 Mascot Animation Demo")
                .font(.title)
                .fontWeight(.bold)

            // Mascot display
            MascotDownloadView(downloadState: currentDownloadState)
                .frame(width: 200, height: 200)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(radius: 4)
                )

            // State selector
            Picker("State", selection: $selectedState) {
                ForEach(0..<states.count, id: \.self) { index in
                    Text(states[index]).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 400)
            .onChange(of: selectedState) { _, newValue in
                if newValue == 1 {
                    startProgressAnimation()
                } else {
                    stopProgressAnimation()
                }
            }

            // Progress slider (only for Downloading state)
            if selectedState == 1 {
                VStack(spacing: 8) {
                    Text("Progress: \(Int(progress * 100))%")
                        .font(.caption)
                        .monospacedDigit()

                    Slider(value: $progress, in: 0...1)
                        .frame(width: 300)

                    HStack {
                        Button("Auto Animate") {
                            startProgressAnimation()
                        }
                        Button("Reset") {
                            stopProgressAnimation()
                            progress = 0
                        }
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                )
            }

            // Instructions
            VStack(alignment: .leading, spacing: 8) {
                Text("Instructions:")
                    .font(.headline)
                Text("• Select different states to see animations")
                Text("• In Downloading state, use slider or Auto Animate")
                Text("• Watch for float, rotation, and progress ring")
                Text("• Completed state shows bounce animation")
                Text("• Failed state shows shake animation")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding()
            .frame(maxWidth: 400)
        }
        .padding(40)
        .frame(width: 600, height: 700)
    }

    private func startProgressAnimation() {
        isAnimating = true
        progress = 0

        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if !isAnimating || progress >= 1.0 {
                timer.invalidate()
                return
            }
            progress = min(1.0, progress + 0.01)
        }
    }

    private func stopProgressAnimation() {
        isAnimating = false
    }
}
SWIFT_CODE

echo "#!/bin/bash" > /tmp/run-demo.sh
echo "cd /Users/travis/Documents/TeamFile/claude-workspace/tokenbar" >> /tmp/run-demo.sh
echo "swift run MascotAnimationDemo" >> /tmp/run-demo.sh
chmod +x /tmp/run-demo.sh

echo "📱 方法 3: 独立演示程序（推荐用于快速验证）"
echo "==========================================="
echo ""
echo "我创建了一个独立的演示程序，可以快速切换所有状态："
echo ""
echo "特点："
echo "  ✅ 无需等待真实更新"
echo "  ✅ 可以手动切换所有 4 种状态"
echo "  ✅ 可以拖动进度条或自动播放下载动画"
echo "  ✅ 实时查看所有动画效果"
echo ""
echo "⚠️  注意: 这个演示程序需要将代码添加到项目中"
echo ""
echo "演示代码已生成到: /tmp/MascotAnimationDemo.swift"
echo ""
echo "要运行演示，需要："
echo "1. 将演示代码集成到项目"
echo "2. 或者使用 Xcode Preview（更简单）"
echo ""
