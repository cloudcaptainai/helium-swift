import Foundation

enum WebViewFailKind {
    case navigation
    case jsCrash
    case processTerminated
}

/// Load-ladder decisions and injected scripts for detecting blank paywall renders.
enum WebViewRenderGuard {

    static func nextLoadAttempt(
        after current: FileLoadAttempt,
        kind: WebViewFailKind,
        hasBackup: Bool
    ) -> FileLoadAttempt? {
        switch current {
        case .initialLoad:
            // A JS crash is deterministic — retrying the same bundle would fail identically.
            if kind == .jsCrash && hasBackup { return .backupLoad }
            return .secondLoad
        case .secondLoad:
            return hasBackup ? .backupLoad : nil
        case .backupLoad:
            return nil
        }
    }

    /// didFinish fires even when the page's JS crashed, so errors stay fatal for a
    /// short window after it; later errors never replace a visible paywall.
    static let postLoadFatalWindow: TimeInterval = 5.0

    static func isWithinFatalWindow(
        isContentLoaded: Bool,
        contentLoadedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        if !isContentLoaded { return true }
        guard let contentLoadedAt else { return true }
        return now.timeIntervalSince(contentLoadedAt) <= postLoadFatalWindow
    }

    /// Runs at document start, before any bundle code. Must never affect the page.
    static func errorHookScriptSource(loadToken: String) -> String {
        """
        (function() {
            try {
                var reported = 0;
                var report = function(source, message, stack) {
                    try {
                        if (reported >= 5) return;
                        reported++;
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.logging) {
                            window.webkit.messageHandlers.logging.postMessage({
                                type: 'js-error',
                                source: source,
                                message: String(message || '').slice(0, 500),
                                stack: String(stack || '').slice(0, 2000),
                                loadToken: '\(loadToken)'
                            });
                        }
                    } catch (e) {}
                };
                // No capture phase: resource load errors must not trigger replacement.
                window.addEventListener('error', function(ev) {
                    try {
                        var err = ev && ev.error;
                        report('error', (err && err.message) || (ev && ev.message), err && err.stack);
                    } catch (e) {}
                });
                window.addEventListener('unhandledrejection', function(ev) {
                    try {
                        var r = ev && ev.reason;
                        report('unhandledrejection', (r && r.message) || String(r), r && r.stack);
                    } catch (e) {}
                });
            } catch (e) {}
        })();
        """
    }

    /// Anything but 'blank' counts as content — when in doubt, never replace a
    /// possibly-working paywall. Always returns a string: the async
    /// `evaluateJavaScript` overload traps on nil.
    static let blankScreenProbeSource = """
        (function() {
            try {
                var b = document.body;
                if (!b || b.childElementCount === 0) return 'blank';
                if (b.getBoundingClientRect().height < 10) return 'blank';
                var els = b.querySelectorAll('*');
                var limit = Math.min(els.length, 300);
                for (var i = 0; i < limit; i++) {
                    var e = els[i];
                    var r = e.getBoundingClientRect();
                    if (r.width < 3 || r.height < 3) continue;
                    var s = window.getComputedStyle(e);
                    if (s.display === 'none' || s.visibility === 'hidden' || parseFloat(s.opacity) === 0) continue;
                    var tag = e.tagName;
                    if (tag === 'IMG' || tag === 'VIDEO' || tag === 'CANVAS' || tag === 'SVG' || tag === 'svg') return 'content';
                    if (s.backgroundImage && s.backgroundImage !== 'none') return 'content';
                    if (tag !== 'SCRIPT' && tag !== 'STYLE' && (e.textContent || '').trim().length > 0) return 'content';
                }
                return 'blank';
            } catch (e) { return 'probe-failed'; }
        })();
        """
}
