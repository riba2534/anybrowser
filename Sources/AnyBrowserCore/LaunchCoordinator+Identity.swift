import Foundation

// "整套重新生成": a new identity goes into the editor first and deletes nothing. Saving it records
// that the old identity's site data must go; that mark stays in the database until the data is
// gone, whether right away (stopped), at the restart (running) or at the next launch after
// AnyBrowser quit. A running browser is never cleared over DevTools: its open pages would write
// the old identity back before the restart.
extension LaunchCoordinator {
    /// A new identity for `profile` (saved or not), with language and time zone from its proxy's
    /// exit, or from this Mac without a proxy. Nothing is saved or deleted. The Profile counts as
    /// busy meanwhile, so the editor and launches wait for the exit lookup.
    public func generateIdentity(for profile: BrowserProfile) async throws -> (profile: BrowserProfile, exitLookupFailed: Bool) {
        let id = profile.id
        guard !isBusy(id) else { throw ProfileError.invalid("「\(profile.name)」正在执行另一个操作。") }
        regenerating.insert(id)
        defer { regenerating.remove(id) }
        let proxy = profile.proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        var locale: IdentitySampler.LocaleHint?
        var lookupFailed = false
        if proxy.isEmpty {
            locale = .host
        } else if let exit = await exitLookup(proxy) {
            locale = IdentitySampler.LocaleHint(exit: exit)
        } else {
            lookupFailed = true
        }
        return (try store.regenerateIdentity(profile, locale: locale), lookupFailed)
    }

    /// Saves `profile` with the identity `generateIdentity` gave it and marks the old identity's
    /// site data for deletion. The Profile is saved first: should the mark fail to save, its next
    /// launch still asks what to do with the old data, because the seed changed.
    public func saveNewIdentity(_ profile: BrowserProfile) throws {
        guard !isBusy(profile.id) else { throw ProfileError.invalid("「\(profile.name)」正在执行另一个操作。") }
        var value = profile
        // The identity reset clears the stored session, so restoring it would bring back nothing.
        value.launch.restoreSession = false
        try store.save(value)
        do {
            try store.setPendingIdentityReset(profile.id, true)
        } catch {
            throw ProfileError.invalid("新身份已保存，但未能记下要清除的旧网站数据（\(error.localizedDescription)）。")
        }
    }

    /// Deletes the site data a pending identity reset is waiting for, then clears the mark, while
    /// the Profile's browser is stopped. Returns false without deleting anything when it runs: the
    /// restart clears it. When the deletion fails the mark stays, and the next launch tries again.
    @discardableResult
    public func clearPendingSiteData(_ id: UUID) async throws -> Bool {
        guard store.pendingIdentityReset(id) else { return true }
        guard !isBusy(id) else { throw ProfileError.invalid("该 Profile 正在执行另一个操作。") }
        switch runtime.status(for: id) {
        case .running, .starting, .stopping:
            return false
        case .stopped, .failed:
            break
        }
        regenerating.insert(id)
        defer { regenerating.remove(id) }
        // Checked just above with nothing in between, so this is the on-disk clearing.
        try await runtime.clearSiteData(for: id)
        try store.setPendingIdentityReset(id, false)
        // The site data now belongs to the new fingerprint, so its next launch has nothing to ask.
        if let fingerprint = store.profiles.first(where: { $0.id == id })?.fingerprint {
            store.recordLaunchFingerprint(id, fingerprint)
        }
        return true
    }

    /// The stages of `resetAndRandomize`, reported as it runs for the window's progress text.
    public enum ResetPhase: Equatable, Sendable {
        case stopping, clearing, generating, saving, starting

        /// Progress text, while the stage runs.
        public var progress: String {
            switch self {
            case .stopping: return "正在停止浏览器…"
            case .clearing: return "正在清空网站登录与数据…"
            case .generating: return "正在生成新身份…"
            case .saving: return "正在保存新身份…"
            case .starting: return "正在以新身份启动…"
            }
        }

        /// The stage as named in an error.
        var name: String {
            switch self {
            case .stopping: return "停止浏览器"
            case .clearing: return "清空网站登录与数据"
            case .generating: return "生成新身份"
            case .saving: return "保存新身份"
            case .starting: return "以新身份启动"
            }
        }
    }

    /// "重置且随机指纹": stops the Profile's browser if it runs (forcefully when it does not quit in
    /// time), deletes every bit of its site data, gives it a whole new identity, saves it and
    /// starts it with that identity. Warnings that did not stop it come back with the outcome; a
    /// failure stops at the stage it happened and throws there, leaving what was already done.
    @discardableResult
    public func resetAndRandomize(_ id: UUID, phase: (ResetPhase) -> Void = { _ in }) async throws -> LaunchOutcome {
        guard let profile = profile(id) else { throw ProfileError.invalid("找不到这个 Profile。") }
        guard !isBusy(id) else { throw ProfileError.invalid("「\(profile.name)」正在执行另一个操作。") }
        regenerating.insert(id)
        defer { regenerating.remove(id) }
        var warnings: [String] = []

        if runtime.status(for: id).isRunning {
            phase(.stopping)
            do {
                try await runtime.stop(id)
            } catch {
                do {
                    try await runtime.stop(id, force: true)
                } catch let forced {
                    throw stageFailure(.stopping, forced)
                }
                warnings.append("浏览器没有及时退出，已强制结束，最近写入的数据可能没有保存。")
            }
            forgetLaunch(id)
        } else if case .failed = runtime.status(for: id) {
            forgetLaunch(id)
        }

        phase(.clearing)
        do {
            try await runtime.clearSiteData(for: id)
        } catch {
            throw stageFailure(.clearing, error)
        }

        // The new identity speaks the language and lives in the time zone of the proxy's exit.
        var locale: IdentitySampler.LocaleHint?
        let proxy = profile.proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        if proxy.isEmpty {
            locale = .host
        } else if let exit = await exitLookup(proxy) {
            locale = IdentitySampler.LocaleHint(exit: exit)
        } else {
            warnings.append("代理出口检测失败，语言和时区保持随机。")
        }

        phase(.generating)
        let fresh: BrowserProfile
        do {
            fresh = try store.resetIdentity(id, locale: locale)
        } catch {
            throw stageFailure(.generating, error)
        }

        phase(.saving)
        var value = fresh
        // As `saveNewIdentity`: the cleared session is not restored, and the reset stays marked
        // until the data is confirmed gone; the launch below clears it again and clears the mark.
        value.launch.restoreSession = false
        do {
            try store.save(value)
            try store.setPendingIdentityReset(id, true)
        } catch {
            throw stageFailure(.saving, error)
        }

        phase(.starting)
        // `start` counts the coordinator's own `regenerating` as busy; let go right before it.
        regenerating.remove(id)
        do {
            let outcome = try await start(id, fingerprintChange: .keepSiteData)
            return LaunchOutcome(startedFresh: outcome.startedFresh, warnings: warnings + outcome.warnings)
        } catch {
            throw stageFailure(.starting, error)
        }
    }

    private func stageFailure(_ phase: ResetPhase, _ error: Error) -> ProfileError {
        .invalid("重置且随机指纹在「\(phase.name)」阶段失败：\(error.localizedDescription)")
    }

    /// The same without a progress callback, for the automation backend.
    @discardableResult
    public func resetAndRandomize(_ id: UUID) async throws -> LaunchOutcome {
        try await resetAndRandomize(id, phase: { _ in })
    }
}
