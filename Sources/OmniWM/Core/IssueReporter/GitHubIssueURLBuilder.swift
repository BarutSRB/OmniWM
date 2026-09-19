// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct GitHubIssueURLBuilder {
    enum Submission: Equatable {
        case url(URL)
        case clipboard(markdown: String, fallbackURL: URL)
    }

    var newIssueURLString: String
    var maxURLLength: Int
    var appVersion: String
    var osVersion: String

    init(
        appVersion: String = Bundle.main.appVersion ?? "unknown",
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        newIssueURLString: String = "https://github.com/OmniNull/OmniWM/issues/new",
        maxURLLength: Int = 8000
    ) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.newIssueURLString = newIssueURLString
        self.maxURLLength = maxURLLength
    }

    func environmentBlock() -> String {
        """
        ## Environment
        - OmniWM version: \(appVersion)
        - macOS version: \(osVersion)
        """
    }

    func composedBody(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed)\n\n\(environmentBlock())"
    }

    func submission(title: String, body: String) -> Submission {
        let fullBody = composedBody(body)
        if let url = issueURL(title: title, body: fullBody), url.absoluteString.count <= maxURLLength {
            return .url(url)
        }
        let fallback = issueURL(title: title, body: nil)
            ?? URL(string: newIssueURLString)
            ?? URL(fileURLWithPath: "/")
        return .clipboard(markdown: fullBody, fallbackURL: fallback)
    }

    private func issueURL(title: String, body: String?) -> URL? {
        guard var components = URLComponents(string: newIssueURLString) else {
            return nil
        }
        var items = [URLQueryItem(name: "title", value: title)]
        if let body {
            items.append(URLQueryItem(name: "body", value: body))
        }
        components.queryItems = items
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
