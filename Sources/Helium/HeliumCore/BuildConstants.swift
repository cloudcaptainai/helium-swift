/**
 Note that this file is the source of truth for package/pod version, and GitHub actions rely on it. Do not change this file
 at all other than to update the version. Adjusting this file wlll kick off a flow to ultimately create a new release.
 
 See CONTRIBUTING.md for full details on the release process and GitHub action workflows.
 
 Note - if you end the version in -pre, it will create as a pre-release.
 */
public struct BuildConstants {
    /// Current SDK version
    public static let version = "3.0.10"
}
