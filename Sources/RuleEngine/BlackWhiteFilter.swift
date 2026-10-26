//
//  BlackWhiteFilter.swift
//  MacStroke
//
//  Black/white list filter for app bundle ID matching.
//  Patterns use the original's `LIKE` semantics (`*` and `?`, whole-string).
//

import Foundation

/// Thread-safe singleton for black/white list filtering.
public final class BlackWhiteFilter: @unchecked Sendable {

    /// Shared singleton instance backed by the app's standard defaults.
    public static let shared = BlackWhiteFilter()

    private let lock = NSLock()
    private let defaults: UserDefaults

    /// Creates a filter over an explicit defaults domain. Tests use an isolated
    /// suite so they never touch the real black/white lists; the app keeps
    /// using `shared`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether whitelist mode is active. When true, only whitelisted apps pass;
    /// when false, all apps pass except blacklisted ones.
    private var inWhiteListMode: Bool {
        get { defaults.bool(forKey: "filterIsInWhiteMode") }
        set { defaults.set(newValue, forKey: "filterIsInWhiteMode"); defaults.synchronize() }
    }

    /// Blacklist items stored as an array of pattern strings.
    private var blackList: [String] {
        get { defaults.stringArray(forKey: "filterBlackList") ?? [] }
        set { defaults.set(newValue, forKey: "filterBlackList"); defaults.synchronize() }
    }

    /// Whitelist items stored as an array of pattern strings.
    private var whiteList: [String] {
        get { defaults.stringArray(forKey: "filterWhiteList") ?? [] }
        set { defaults.set(newValue, forKey: "filterWhiteList"); defaults.synchronize() }
    }

    /// Plain-text blacklist with one pattern per line (UI binding).
    public var blackListText: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return blackList.joined(separator: "\n")
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            blackList = Self.patterns(from: newValue)
        }
    }

    /// Plain-text whitelist with one pattern per line (UI binding).
    public var whiteListText: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return whiteList.joined(separator: "\n")
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            whiteList = Self.patterns(from: newValue)
        }
    }

    /// One pattern per line, trimmed, blank lines dropped — the original's
    /// `filterViewApplyClicked:` normalisation.
    private static func patterns(from text: String) -> [String] {
        text.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Whether to hook mouse events for the given bundle ID.
    /// In whitelist mode, only whitelisted apps pass.
    /// In blacklist mode, all apps pass except blacklisted ones.
    public func shouldHookMouseEventForApp(_ bundleName: String) -> Bool {
        if inWhiteListMode {
            return match(bundleName: bundleName, against: whiteList)
        } else {
            return !match(bundleName: bundleName, against: blackList)
        }
    }

    /// Match a bundle ID against the configured lists.
    /// Returns true if the bundle ID matches any pattern.
    /// Original `bundleName:fitWithRules:`: every list item is a `LIKE` pattern
    /// (`*` / `?`, whole-string, case-folded) — no regex support.
    public func match(bundleName: String) -> Bool {
        let patterns = inWhiteListMode ? whiteList : blackList
        return match(bundleName: bundleName, against: patterns)
    }

    /// Check if bundleName matches any pattern in the list.
    private func match(bundleName: String, against patterns: [String]) -> Bool {
        wildcardArray(bundleName, patterns: patterns, ignoreCase: true)
    }

    /// Migrate from old "blockFilter" UserDefaults key.
    public func compatibleProcedureWithPreviousVersion() {
        if let oldBlockFilter = defaults.string(forKey: "blockFilter") {
            inWhiteListMode = false
            blackListText = oldBlockFilter.replacingOccurrences(of: "|", with: "\n")
            defaults.removeObject(forKey: "blockFilter")
            defaults.synchronize()
        }
    }
}
