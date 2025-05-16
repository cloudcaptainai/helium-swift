# Releases and CI / CD

## Running Tests on a Branch

You can run tests on a branch in two ways:

### 1. Via Pull Request
Tests run automatically when:
- A new PR is opened
- New commits are pushed to an existing PR

### 2. Manually
You can manually trigger tests on any branch:
1. Go to the Actions tab in the repository
2. Select the "Branch CI Testing" workflow
3. Click "Run workflow", fill in form and run

### Monitoring Test Results
- Tests are executed in the `helium-demo` repository
- Check the status directly on your PR or commit
- For detailed logs, visit the Actions tab of the [helium-demo](https://github.com/cloudcaptainai/helium-demo/actions) repository

## Creating a Release

```
Release Overview:
Push new version (BuildConstants.swift) to main →
Release CI - Trigger Tests workflow → 
Tests run in helium-demo → Tests passed →
Create Release workflow →
Create CocoaPod workflow
```

Full outline:

### 1. Automated Tests
Tests are automatically triggered when:
- Changes are pushed to `main` that modify `BuildConstants.swift` (where the sdk's version is specified)
- OR manually via the "Release CI - Trigger Tests" workflow

The workflow:
1. Extracts the version from `BuildConstants.swift`
2. Triggers tests in the `helium-demo` repository
3. Passes along version information

### 2. Create Release
If tests pass, the release is created automatically:
- A git tag is created with the version number
- A GitHub draft release is created
- Release notes are auto-generated

You can also create a release manually:
1. Go to the "Create Release" workflow
2. Provide:
   - Version tag
   - Commit SHA
   - Whether it's a pre-release (optional)

### 3. Create CocoaPod
Once a release is created:
- The CocoaPod is automatically linted and published to the CocoaPods trunk

You can also manually trigger the CocoaPod creation via the "Create CocoaPod" workflow.

