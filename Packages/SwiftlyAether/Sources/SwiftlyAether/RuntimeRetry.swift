// A downloaded file built from one audio track has no duration in its header, so the engine refuses it with
// "source has zero duration". The engine then loads it ONCE MORE with the stored runtime; only when that fails too
// may the screen fall back to the stream. One decision, used by the load catch, the state report and the failure
// report, so no path can tell the screen "failed" while the retry runs (that started the stream in parallel).
public enum RuntimeRetry {
    /// `true` while the failure `reason` is the missing-duration one and the stored-runtime retry is still due.
    public static func isDue(isFileURL: Bool, storedRuntime: Double, alreadyDeclared: Bool, reason: String) -> Bool {
        isFileURL && storedRuntime > 0 && !alreadyDeclared && reason.contains("zero duration")
    }
}
