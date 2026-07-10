/// Namespace marker for the StickerStoriesKit module.
///
/// The real content (pack manifest models, canvas state, story selection,
/// entitlement logic) arrives with the pack-loading layer.
public enum StickerStoriesKitInfo {
    /// The manifest schema version this build of the Kit understands.
    /// Must match `docs/pack-format.md` and the Go validator.
    public static let supportedSchemaVersion = 1
}
