# AGENTS.md

Native macOS dashboard for many git repos. Swift + SwiftUI, macOS 14+, SwiftPM only: the dev machine has no Xcode, so build with `swift build` and package with `./bundle.sh`.

## Identity

- Brand colour is git orange `#F05032`, defined once as `Color.brand` / `NSColor.brand` in `Sources/RepoCommons/Icon.swift`.
- Identity elements use `.brand`: the app icon, sidebar icons, and any new icon or accent.
- State signals keep the system colours: `.orange` for attention (changes, ahead, "sem upstream"), `.red` for failures.
- App icon is an orange honeycomb on a white rounded square, drawn in code in `Icon.swift`. Change it there; `bundle.sh` renders the `.icns` from it.

## Conventions

- UI text is Brazilian Portuguese, hardcoded. Dates use the `pt_BR` locale.
- Clean-room project: inspired by RepoFlock, built only from original code, names and assets.
- Pull is always `git pull --ff-only` and push is a plain `git push`, never forced. Both run only on a user click. Batch git operations run at most 4 at a time (`Git.batch`).
- Tests are integration tests against real git repos in a temp dir, at the `RepoCommonsCore` public API. New core behaviour gets its test there first.
