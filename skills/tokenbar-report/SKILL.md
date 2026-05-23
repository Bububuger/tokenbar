# TokenBar

This directory is the TokenBar product codebase.

Current source of truth for product planning:


Current bootstrap:

- Xcode-generated macOS app target (`project.yml` -> `TokenBar.xcodeproj`)
- `TokenBarCore` domain layer with deterministic sample data
- real `swift-testing` coverage for the aggregation layer
- SwiftUI app shell with menu bar extra, main window, and settings placeholder
- `script/build.sh`, `script/test.sh`, `script/build_and_run.sh`
- `script/autoresearch_acceptance.sh`
- project-local Xcode env bootstrap via `script/xcode_env.sh`

Current launch behavior:

- the repo now builds a real development-signed Xcode app target
- on this machine, direct terminal launch still depends on macOS Developer Mode
- `script/build_and_run.sh` therefore falls back to asking Xcode to run the
  `TokenBar` scheme when terminal-launched developer apps are blocked by system
  policy
