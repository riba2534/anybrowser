/// Versions of the engine and Passkey Box that `scripts/build-app.sh` embeds. A unit test keeps
/// these in step with `scripts/versions.env`, so presets and tests never drift from the packaged app.
public enum BundledVersions {
    public static let engine = "148.0.7778.215"
    public static var engineMajor: Int { Int(engine.split(separator: ".")[0])! }
    public static let passkeyBox = "0.5.0"
}
