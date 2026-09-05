# EyeTracking (vendored)

Local copy of [kyle-fox/ios-eye-tracking](https://github.com/kyle-fox/ios-eye-tracking),
commit `cba4fff6db11` (tag `1.0`, July 2020), MIT licensed. See [LICENSE](LICENSE).

## Why vendored

The upstream package has not been updated since 2020 and cannot be used directly with
current Xcode:

- It pins `GRDB.swift` to 4.x, which fails to compile with Swift 6 toolchains
  (`cannot find 'strcmp' in scope`).
- Its only release tag is `1.0`, which is not a semantic version, so Swift Package Manager
  cannot resolve it by version.
- Its test target declares an `exclude` path that does not exist, which makes xcodebuild
  reject the manifest.

## Local patches

- `Package.swift`: swift-tools-version 6.0, iOS 18 platform, GRDB 7.x, explicit product
  dependency, test target removed, Swift 5 language mode for the legacy sources.
- Sources are otherwise unmodified unless listed below.

## Usage in this repo

`InteractionFingerprintPackage/Package.swift` depends on this package by path. The API is
documented upstream: `EyeTracking(configuration:)`, `startSession()`, `endSession()`,
`export(sessionID:)`, `exportAll()`.
