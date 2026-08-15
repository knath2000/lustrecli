import Foundation
import LustreCore

struct DownloadedFeedHistory {
    private let urls: [String: Date]
    private let pornHubViewkeys: [String: Date]

    init(jobs: [DownloadJob]) {
        var urls: [String: Date] = [:]
        var pornHubViewkeys: [String: Date] = [:]
        for job in jobs where job.status == .completed {
            let url = Self.normalizedURL(job.sourcePageURL)
            if urls[url] == nil { urls[url] = job.updatedAt }
            if let viewkey = Self.pornHubViewkey(job.sourcePageURL), pornHubViewkeys[viewkey] == nil {
                pornHubViewkeys[viewkey] = job.updatedAt
            }
        }
        self.urls = urls
        self.pornHubViewkeys = pornHubViewkeys
    }

    func downloadedAt(for url: URL) -> Date? {
        if let viewkey = Self.pornHubViewkey(url), let date = pornHubViewkeys[viewkey] { return date }
        return urls[Self.normalizedURL(url)]
    }

    func decorate(_ page: FeedPage) -> FeedPage {
        FeedPage(items: page.items.map { item in
            FeedItem(
                id: item.id,
                siteID: item.siteID,
                title: item.title,
                sourcePageURL: item.sourcePageURL,
                thumbnailURL: item.thumbnailURL,
                previewURLs: item.previewURLs,
                uploadedAt: item.uploadedAt,
                uploadedAtIsApproximate: item.uploadedAtIsApproximate,
                viewCount: item.viewCount,
                studio: item.studio,
                queueCapability: item.queueCapability,
                downloadedAt: downloadedAt(for: item.sourcePageURL)
            )
        }, page: page.page, hasMore: page.hasMore)
    }

    static func normalizedURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    static func pornHubViewkey(_ url: URL) -> String? {
        guard url.host?.lowercased().hasSuffix("pornhub.com") == true,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name.caseInsensitiveCompare("viewkey") == .orderedSame })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value.lowercased()
    }
}
