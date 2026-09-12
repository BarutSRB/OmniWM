// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

struct WindowTokenIndex<Key: Hashable> {
    private(set) var tokensByKey: [Key: [WindowToken]] = [:]
    private var tokenIndexByKey: [Key: [WindowToken: Int]] = [:]

    mutating func append(
        _ token: WindowToken,
        to key: Key
    ) {
        guard tokenIndexByKey[key]?[token] == nil else { return }
        let index = tokensByKey[key]?.count ?? 0
        tokensByKey[key, default: []].append(token)
        tokenIndexByKey[key, default: [:]][token] = index
    }

    private static func removeTokenFromBucket(
        _ token: WindowToken,
        tokens: inout [WindowToken],
        indexByToken: inout [WindowToken: Int]
    ) -> Bool {
        guard let index = indexByToken.removeValue(forKey: token) else { return tokens.isEmpty }
        tokens.remove(at: index)
        for position in index ..< tokens.count {
            indexByToken[tokens[position]] = position
        }
        return tokens.isEmpty
    }

    mutating func remove(
        _ token: WindowToken,
        from key: Key
    ) {
        guard tokensByKey[key] != nil,
              tokenIndexByKey[key]?[token] != nil
        else {
            return
        }

        let bucketIsEmpty = Self.removeTokenFromBucket(
            token,
            tokens: &tokensByKey[key]!,
            indexByToken: &tokenIndexByKey[key]!
        )
        if bucketIsEmpty {
            tokensByKey.removeValue(forKey: key)
            tokenIndexByKey.removeValue(forKey: key)
        }
    }

    private static func replaceTokenInBucket(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        tokens: inout [WindowToken],
        indexByToken: inout [WindowToken: Int]
    ) {
        guard let index = indexByToken.removeValue(forKey: oldToken) else { return }
        tokens[index] = newToken
        indexByToken[newToken] = index
    }

    mutating func replace(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        in key: Key
    ) {
        guard tokensByKey[key] != nil,
              tokenIndexByKey[key]?[oldToken] != nil
        else {
            return
        }
        Self.replaceTokenInBucket(
            from: oldToken,
            to: newToken,
            tokens: &tokensByKey[key]!,
            indexByToken: &tokenIndexByKey[key]!
        )
    }
}
