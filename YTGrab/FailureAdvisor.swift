import Foundation

/// Turns a failed job's error and log into something a person can act on.
///
/// "yt-dlp exited with 1" tells nobody anything. Nearly every real-world
/// failure falls into one of a dozen causes with a known fix, and most of
/// those fixes are a button the app can offer directly.
struct FailureAdvice: Sendable, Equatable {

    enum Action: Sendable, Equatable {
        case retry
        case updateTools
        case repairTools
        case openYouTubeSettings
        case chooseFolder
        case openPrivacySettings
    }

    var title: String
    var message: String
    var action: Action?
    /// Retrying the same request cannot help (private, removed, bad link).
    var isPermanent: Bool = false

    var actionTitle: String? {
        switch action {
        case .retry:               return "Try Again"
        case .updateTools:         return "Update Download Engine"
        case .repairTools:         return "Repair Tools"
        case .openYouTubeSettings: return "Open Settings"
        case .chooseFolder:        return "Choose Another Folder"
        case .openPrivacySettings: return "Open Privacy Settings"
        case nil:                  return nil
        }
    }

    static func explain(_ error: Error, log: [String] = []) -> FailureAdvice {
        if let job = error as? JobError {
            switch job {
            case .cancelled:
                return FailureAdvice(title: "Cancelled", message: "The download was stopped.", action: .retry)
            case .processKilled:
                return FailureAdvice(
                    title: "macOS stopped a helper tool",
                    message: "macOS security blocked one of YTGrab's built-in tools. Repair Tools reinstalls them from the app, which usually fixes this straight away.",
                    action: .repairTools
                )
            case .missingTools, .toolSetupFailed:
                return FailureAdvice(
                    title: "Built-in tools need repair",
                    message: job.localizedDescription,
                    action: .repairTools
                )
            case .unsupportedArchitecture(let detail):
                return FailureAdvice(title: "Wrong build for this Mac", message: detail, action: nil, isPermanent: true)
            case .notEnoughSpace:
                return FailureAdvice(
                    title: "Not enough disk space",
                    message: job.localizedDescription + " Free up space or choose a folder on another drive.",
                    action: .chooseFolder
                )
            case .timedOut:
                return FailureAdvice(
                    title: "YouTube didn't respond",
                    message: "The request timed out. Check your connection and try again.",
                    action: .retry
                )
            default:
                break
            }
        }

        let text = ([error.localizedDescription] + log.suffix(40)).joined(separator: "\n").lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }

        if has("sign in to confirm", "not a bot", "confirm you’re not a bot", "confirm you're not a bot") {
            return FailureAdvice(
                title: "YouTube wants you to sign in",
                message: "YouTube is asking this connection to prove it isn't a bot. In Settings › YouTube Access, choose the browser where you're signed in to YouTube, then try again.",
                action: .openYouTubeSettings
            )
        }
        if has("confirm your age", "age-restricted", "inappropriate for some users") {
            return FailureAdvice(
                title: "Age-restricted video",
                message: "This video needs a signed-in account. Turn on cookies from your browser in Settings › YouTube Access.",
                action: .openYouTubeSettings
            )
        }
        if has("members-only", "join this channel", "available to this channel's members") {
            return FailureAdvice(
                title: "Members-only video",
                message: "Only channel members can watch this. If you are a member, turn on cookies from your browser in Settings › YouTube Access.",
                action: .openYouTubeSettings
            )
        }
        if has("private video") {
            return FailureAdvice(title: "Private video", message: "The owner has made this video private.", action: nil, isPermanent: true)
        }
        if has("not available in your country", "geo restrict", "geo-restrict") {
            return FailureAdvice(title: "Not available in your region", message: "The uploader has blocked this video where you are.", action: nil, isPermanent: true)
        }
        if has("video unavailable", "has been removed", "account associated with this video has been terminated", "this video is no longer available") {
            return FailureAdvice(title: "Video unavailable", message: "YouTube says this video no longer exists or can't be played.", action: nil, isPermanent: true)
        }
        if has("live event will begin", "premieres in", "this live event", "is_upcoming", "is live", "live stream") {
            return FailureAdvice(
                title: "Live stream or premiere",
                message: "This video hasn't finished streaming yet. Try again after the stream ends.",
                action: .retry,
                isPermanent: true
            )
        }
        if has("unsupported url", "is not a valid url", "no video formats found") {
            return FailureAdvice(title: "Link not recognised", message: "That link doesn't point to a video YTGrab can download.", action: nil, isPermanent: true)
        }
        if has("requested format is not available") {
            return FailureAdvice(
                title: "That quality isn't offered",
                message: "YouTube doesn't have this video at the quality you picked. Choose Best available and try again.",
                action: .retry
            )
        }
        if has("429", "too many requests") {
            return FailureAdvice(
                title: "YouTube is limiting requests",
                message: "Too many downloads in a short time. Wait a few minutes, or turn on cookies from your browser in Settings › YouTube Access.",
                action: .openYouTubeSettings
            )
        }
        if has("nsig", "n challenge", "signature extraction", "unable to extract", "js runtime", "javascript runtime",
               "challenge solving", "ejs", "403", "forbidden", "po token", "sabr", "only images are available") {
            return FailureAdvice(
                title: "YouTube changed something",
                message: "YouTube updates its site often, and the download engine needs to keep up. Update it, then try again.",
                action: .updateTools
            )
        }
        if has("could not copy", "cookie", "keychain") && AppSettings.cookies != .none {
            if has("operation not permitted", "permission denied") && AppSettings.cookies == .safari {
                return FailureAdvice(
                    title: "Safari cookies need Full Disk Access",
                    message: "macOS protects Safari's cookies. Give YTGrab Full Disk Access in System Settings › Privacy & Security, or choose a different browser.",
                    action: .openPrivacySettings
                )
            }
            return FailureAdvice(
                title: "Couldn't read browser cookies",
                message: "YTGrab couldn't read cookies from \(AppSettings.cookies.title). Quit that browser and try again, or choose another one in Settings.",
                action: .openYouTubeSettings
            )
        }
        if has("no space left on device") {
            return FailureAdvice(title: "Disk full", message: "The destination drive ran out of space.", action: .chooseFolder)
        }
        if has("operation not permitted", "permission denied", "read-only file system") {
            return FailureAdvice(
                title: "Can't write to that folder",
                message: "macOS didn't let YTGrab save there. Choose another folder, or allow access in System Settings › Privacy & Security › Files and Folders.",
                action: .chooseFolder
            )
        }
        if has("bad cpu type", "exec format error") {
            return FailureAdvice(
                title: "Wrong build for this Mac",
                message: "This copy of YTGrab doesn't include tools for this Mac's processor. Download the universal build.",
                action: .repairTools,
                isPermanent: true
            )
        }
        if has("unable to download webpage", "urlopen error", "timed out", "nodename nor servname", "network is unreachable",
               "connection reset", "temporary failure in name resolution", "ssl", "certificate", "getaddrinfo") {
            return FailureAdvice(
                title: "Network problem",
                message: "YTGrab couldn't reach YouTube. Check your connection, VPN or firewall. On some networks, turning on Force IPv4 in Settings helps.",
                action: .retry
            )
        }
        if has("videotoolbox", "error while opening encoder", "encoder", "conversion failed", "invalid data found") {
            return FailureAdvice(
                title: "Conversion failed",
                message: "The video downloaded but couldn't be converted. Try Original, or switch the encoder to Software in Advanced options.",
                action: .retry
            )
        }

        let detail = error.localizedDescription
        return FailureAdvice(
            title: "Download failed",
            message: detail.isEmpty ? "Something went wrong. Open the details below for the full log." : detail,
            action: .retry
        )
    }
}
