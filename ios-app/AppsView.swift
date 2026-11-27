import SwiftUI

// MARK: - Models

/// One provisioning profile, decoded from the CMS blob misagent returns.
///
/// The CMS signature isn't verified (the device already trusts installed
/// profiles). The plist payload is found by scanning the blob, as StikDebug
/// does, rather than using `CMSDecoder`.
struct ProvisioningProfile: Identifiable, Equatable {

    /// Apple's name for the App ID the profile was issued against, e.g.
    /// "SideStore" — not the app's display name, though they usually match.
    let appIDName: String
    /// The full `TEAMID.bundle.id` from the profile's entitlements. This is the
    /// App ID as the developer portal knows it, and may end in `*`.
    let applicationIdentifier: String
    let teamName: String
    let uuid: String
    let creationDate: Date?
    let expirationDate: Date?
    /// Entitlements granted by the profile, as a plist dictionary.
    let entitlements: [String: Any]

    var id: String { uuid }

    /// Compares identity only (UUID and expiry); `[String: Any]` isn't `Equatable`.
    static func == (lhs: ProvisioningProfile, rhs: ProvisioningProfile) -> Bool {
        lhs.uuid == rhs.uuid && lhs.expirationDate == rhs.expirationDate
    }

    /// The bundle ID without the team prefix:
    /// `A1B2C3D4E5.com.example.app` → `com.example.app`.
    var bundleIdentifier: String {
        guard let dot = applicationIdentifier.firstIndex(of: ".") else {
            return applicationIdentifier
        }
        return String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
    }

    /// The team prefix on its own, or nil when the identifier has no prefix.
    var teamIdentifier: String? {
        guard let dot = applicationIdentifier.firstIndex(of: ".") else { return nil }
        return String(applicationIdentifier[..<dot])
    }

    /// True when the App ID is a wildcard (ends in `*`).
    var isWildcard: Bool { applicationIdentifier.hasSuffix("*") }

    /// True for an App Store distribution profile, the kind TestFlight builds
    /// carry. Nothing can be sideloaded with one, so the page leaves it out.
    var isAppStoreDistribution: Bool { entitlements["beta-reports-active"] as? Bool == true }

    /// Calendar days until expiry (1 = tomorrow); negative once expired.
    var daysRemaining: Int? {
        guard let expirationDate else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents([.day],
                                       from: calendar.startOfDay(for: Date()),
                                       to: calendar.startOfDay(for: expirationDate)).day
    }

    var isExpired: Bool {
        guard let expirationDate else { return false }
        return expirationDate < Date()
    }

    /// Entitlement keys to display, excluding the four every profile has.
    var capabilityKeys: [String] {
        let boilerplate: Set<String> = [
            "application-identifier",
            "com.apple.developer.team-identifier",
            "keychain-access-groups",
            "get-task-allow",
        ]
        return entitlements.keys.filter { !boilerplate.contains($0) }.sorted()
    }

    /// Decodes a `.mobileprovision` payload. Returns nil if no readable plist is
    /// found; such profiles are left off the page.
    init?(data: Data) {
        guard let payload = Self.plistPayload(in: data),
              let plist = try? PropertyListSerialization.propertyList(from: payload, format: nil),
              let dict = plist as? [String: Any] else { return nil }

        let entitlements = dict["Entitlements"] as? [String: Any] ?? [:]
        self.entitlements = entitlements
        self.appIDName = dict["AppIDName"] as? String ?? ""
        self.applicationIdentifier = entitlements["application-identifier"] as? String ?? ""
        self.teamName = dict["TeamName"] as? String ?? ""
        self.uuid = dict["UUID"] as? String ?? UUID().uuidString
        self.creationDate = dict["CreationDate"] as? Date
        self.expirationDate = dict["ExpirationDate"] as? Date
    }

    /// Rebuilds a profile from the Home Screen cache.
    init(appIDName: String, applicationIdentifier: String, teamName: String,
         uuid: String, creationDate: Date?, expirationDate: Date?) {
        self.appIDName = appIDName
        self.applicationIdentifier = applicationIdentifier
        self.teamName = teamName
        self.uuid = uuid
        self.creationDate = creationDate
        self.expirationDate = expirationDate
        self.entitlements = ["application-identifier": applicationIdentifier]
    }

    /// Find the plist inside the CMS wrapper: XML between `<?xml` and `</plist>`,
    /// or everything from `bplist00` on. Apple has shipped both.
    private static func plistPayload(in data: Data) -> Data? {
        let xmlStart = Data("<?xml".utf8)
        let xmlEnd = Data("</plist>".utf8)
        if let start = data.range(of: xmlStart),
           let end = data.range(of: xmlEnd, options: [], in: start.lowerBound..<data.endIndex) {
            return data[start.lowerBound..<end.upperBound]
        }
        if let start = data.range(of: Data("bplist00".utf8)) {
            return data[start.lowerBound..<data.endIndex]
        }
        return nil
    }
}

/// One app installation_proxy reported, kept only when it was installed with a
/// provisioning profile — i.e. sideloaded rather than from the App Store.
struct SideloadedApp: Identifiable, Equatable {

    let bundleID: String
    let name: String
    let version: String?
    /// `TEAMID.bundle.id` from the app's signed entitlements. When missing,
    /// profile matching falls back to the bundle ID.
    let applicationIdentifier: String?
    /// The app's real Home Screen icon from SpringBoard, when it came back.
    var iconData: Data? = nil

    var id: String { bundleID }

    /// Rebuilds an app from the Home Screen cache.
    init(bundleID: String, name: String, version: String?, applicationIdentifier: String?,
         iconData: Data? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.applicationIdentifier = applicationIdentifier
        self.iconData = iconData
    }

    /// Returns nil unless `ProfileValidated` is set. installd sets it only for
    /// apps installed with a provisioning profile, not App Store apps. TestFlight
    /// apps carry a profile too, so they're left out separately.
    init?(plist: [String: Any]) {
        guard plist["ProfileValidated"] != nil,
              let bundleID = plist["CFBundleIdentifier"] as? String else { return nil }
        let entitlements = plist["Entitlements"] as? [String: Any]
        guard !Self.isFromTestFlight(signer: plist["SignerIdentity"] as? String,
                                     entitlements: entitlements) else { return nil }
        self.bundleID = bundleID
        let display = plist["CFBundleDisplayName"] as? String
        let bundleName = plist["CFBundleName"] as? String
        self.name = display?.isEmpty == false ? display! : (bundleName?.isEmpty == false ? bundleName! : bundleID)
        self.version = plist["CFBundleShortVersionString"] as? String
        self.applicationIdentifier = entitlements?["application-identifier"] as? String
    }

    /// Whether an app came from TestFlight: Apple signed it (only App Store and
    /// TestFlight builds carry Apple's own signer) or it has the
    /// `beta-reports-active` entitlement, which only App Store distribution
    /// profiles grant. Neither is ever true of a sideloaded app.
    static func isFromTestFlight(signer: String?, entitlements: [String: Any]?) -> Bool {
        if let signer, signer.hasPrefix("Apple iPhone OS Application Signing") { return true }
        return entitlements?["beta-reports-active"] as? Bool == true
    }
}

/// An installed app with every profile on the device that could have signed it,
/// latest expiry first. Multiple profiles are normal: each re-sign leaves one.
struct SideloadedAppStatus: Identifiable, Equatable {

    var app: SideloadedApp
    let profiles: [ProvisioningProfile]

    var id: String { app.bundleID }

    /// The profile in use: the one that expires last.
    var current: ProvisioningProfile? { profiles.first }

    /// Profiles kept only for history, shown on the detail page.
    var superseded: [ProvisioningProfile] { Array(profiles.dropFirst()) }

    /// Sort key: expiry date. Apps without a profile sort last.
    var sortKey: Date { current?.expirationDate ?? .distantFuture }
}

/// Expiry urgency bands and colors (same as AltStore/StikDebug), scaled to a
/// free profile's seven days.
enum ExpiryUrgency {
    case expired, critical, soon, later, comfortable, unknown

    static func of(_ profile: ProvisioningProfile?) -> ExpiryUrgency {
        guard let profile, let days = profile.daysRemaining else { return .unknown }
        if profile.isExpired { return .expired }
        switch days {
        case ...1:  return .critical
        case 2...3: return .soon
        case 4...5: return .later
        default:    return .comfortable
        }
    }

    var color: Color {
        switch self {
        case .expired, .critical: return Theme.negative
        case .soon:               return Theme.warning
        // Between the warning and the positive, toned like them.
        case .later:              return Color(red: 214 / 255, green: 194 / 255, blue: 86 / 255)
        case .comfortable:        return Theme.positive
        case .unknown:            return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .expired:  return "exclamationmark.triangle"
        case .critical: return "clock.badge.exclamationmark"
        case .unknown:  return "questionmark.circle"
        default:        return "clock"
        }
    }

    /// Expiry text, e.g. "Expires today", "Expires in 5 days — 23 Aug",
    /// "Expired 12 Aug". More than 30 days out shows only the date.
    static func text(for profile: ProvisioningProfile?) -> String {
        guard let profile, let expiration = profile.expirationDate else {
            return L("No matching profile")
        }
        let formatted = expiration.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Localizer.locale))
        if profile.isExpired { return L("Expired %@", formatted) }
        switch profile.daysRemaining {
        case 0:            return L("Expires today")
        case 1:            return L("Expires tomorrow")
        case .some(2...30): return L("Expires in %d days — %@", profile.daysRemaining ?? 0, formatted)
        default:           return L("Expires %@", formatted)
        }
    }
}

// MARK: - Matching

/// Matches installed apps to the profiles that signed them. Static functions
/// with no device or UI state, so the logic can be tested on its own.
enum ProfileMatcher {

    /// Index every profile by the App ID it was issued against, then hand each
    /// app the ones that could have signed it.
    static func match(apps: [SideloadedApp],
                      profiles: [ProvisioningProfile]) -> (entries: [SideloadedAppStatus],
                                                           unmatched: [ProvisioningProfile]) {
        let sorted = profiles.sorted { expiry($0) > expiry($1) }
        // A wildcard App ID covers every bundle id under it, so those can't be
        // looked up — they have to be tried against each app in turn.
        let wildcards = sorted.filter(\.isWildcard)
        let specific = sorted.filter { !$0.isWildcard }
        let byAppID = Dictionary(grouping: specific, by: \.applicationIdentifier)
        // Also index by bundle ID, for apps that don't report
        // `application-identifier`.
        let byBundleID = Dictionary(grouping: specific, by: \.bundleIdentifier)

        var claimed = Set<String>()
        let entries = apps.map { app -> SideloadedAppStatus in
            let matched = matchingProfiles(for: app, byAppID: byAppID,
                                           byBundleID: byBundleID, wildcards: wildcards)
            claimed.formUnion(matched.map(\.uuid))
            return SideloadedAppStatus(app: app, profiles: matched)
        }

        // Profiles no app matched (deleted apps, unused wildcards). Shown because
        // they count toward a free account's App ID limit.
        let unmatched = sorted.filter { !claimed.contains($0.uuid) }

        return (entries.sorted(by: order), unmatched)
    }

    /// Soonest expiry first, then by name.
    private static func order(_ lhs: SideloadedAppStatus, _ rhs: SideloadedAppStatus) -> Bool {
        if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
        return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
    }

    /// The profiles that could have signed `app`, latest expiry first.
    ///
    /// Profiles for this exact App ID or bundle ID take priority. Wildcards are
    /// used only when there are none, so a long-lived wildcard can't hide an
    /// app-specific profile's earlier expiry.
    private static func matchingProfiles(for app: SideloadedApp,
                                         byAppID: [String: [ProvisioningProfile]],
                                         byBundleID: [String: [ProvisioningProfile]],
                                         wildcards: [ProvisioningProfile]) -> [ProvisioningProfile] {
        let target = app.applicationIdentifier ?? app.bundleID
        let specific = (byAppID[target] ?? []) + (byBundleID[app.bundleID] ?? [])
        if !specific.isEmpty { return deduplicated(specific) }
        return deduplicated(wildcards.filter { covers(pattern: $0.applicationIdentifier, app) })
    }

    /// Whether a wildcard App ID covers this app. Checks the app's identifier
    /// first, then its bundle ID against the pattern without the team prefix.
    static func covers(pattern: String, _ app: SideloadedApp) -> Bool {
        if let identifier = app.applicationIdentifier, matches(pattern: pattern, identifier) {
            return true
        }
        guard let dot = pattern.firstIndex(of: ".") else {
            return matches(pattern: pattern, app.bundleID)
        }
        return matches(pattern: String(pattern[pattern.index(after: dot)...]), app.bundleID)
    }

    /// Does `pattern` — an App ID that may end in `*` — cover `value`?
    static func matches(pattern: String, _ value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        return value.range(of: "^" + escaped + "$", options: .regularExpression) != nil
    }

    /// Removes duplicate profiles (the two indexes overlap) and sorts by latest
    /// expiry.
    private static func deduplicated(_ profiles: [ProvisioningProfile]) -> [ProvisioningProfile] {
        var seen = Set<String>()
        return profiles
            .filter { seen.insert($0.uuid).inserted }
            .sorted { expiry($0) > expiry($1) }
    }

    private static func expiry(_ profile: ProvisioningProfile) -> Date {
        profile.expirationDate ?? .distantPast
    }

    /// Whether an installed app was built from the IPA with `ipaBundleID`.
    /// isideload signs apps as `<bundle id>.<team id>`, so this checks for that
    /// suffix: `teamID` when known, otherwise any 10-character team ID.
    static func installed(_ bundleID: String, isBuiltFrom ipaBundleID: String,
                          teamID: String?) -> Bool {
        if bundleID == ipaBundleID { return true }        // signed by something else
        if let teamID, !teamID.isEmpty { return bundleID == "\(ipaBundleID).\(teamID)" }
        guard bundleID.hasPrefix(ipaBundleID + ".") else { return false }
        let suffix = bundleID.dropFirst(ipaBundleID.count + 1)
        // A team id is ten characters, upper-case letters and digits only.
        return suffix.count == 10 && suffix.allSatisfy { $0.isUppercase || $0.isNumber }
    }
}

/// One app a refresh will act on: what is installed, and the IPA on disk it
/// will be signed again from.
struct RefreshJob: Identifiable, Equatable {

    enum State: Equatable {
        case pending, working, done
        case failed(String)
    }

    /// The bundle id as installed — team id and all.
    let bundleID: String
    let name: String
    let ipa: URL
    /// Team ID the app is currently signed under (from its current profile).
    let teamID: String?
    var state: State = .pending

    var id: String { bundleID }
}

// MARK: - Manager

/// Drives the Sideloaded apps page: loads installed apps and profiles from the
/// device, matches them, and runs "Refresh all" through the install pipeline.
///
/// One for the app, so the Shortcuts actions (AppsShortcuts.swift) see and
/// refresh the same apps as the page.
@MainActor
final class SideloadedAppsManager: ObservableObject {

    static let shared = SideloadedAppsManager()

    /// How a refresh run went.
    struct RefreshOutcome {
        /// Why the run couldn't start (no device link, or no sign-in).
        var failure: String?
        /// The apps it went through, each `done` or `failed`.
        var jobs: [RefreshJob] = []
        var refreshed: Int { jobs.filter { $0.state == .done }.count }
    }

    @Published private(set) var entries: [SideloadedAppStatus] = []
    /// Profiles belonging to no installed app — deleted apps' leftovers.
    @Published private(set) var unmatched: [ProvisioningProfile] = []
    @Published private(set) var isWorking = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var lastRefreshed: Date?
    @Published var lastError: String?

    /// The apps a refresh can act on: an installed app whose IPA is still in
    /// Documents. Rebuilt on every load.
    @Published private(set) var refreshable: [RefreshJob] = []
    /// Apps on the page with no IPA to sign again from, for the note that says
    /// why they aren't included.
    @Published private(set) var unrefreshable = 0
    /// The run in progress, or the last one's results until another starts.
    @Published private(set) var jobs: [RefreshJob] = []
    @Published private(set) var isRefreshing = false
    /// What the refresh is doing right now, shown on the button.
    @Published private(set) var refreshStatus: String?
    /// How the last finished run went, e.g. "Refreshed 2 of 3 apps."
    @Published private(set) var refreshSummary: String?

    private var engine: Engine { Engine.shared }

    /// The last Home Screen, kept so the app opens on its icons like
    /// Strata's instead of an empty page waiting for the tunnel.
    private struct CachedApp: Codable {
        var bundleID: String
        var name: String
        var version: String?
        var applicationIdentifier: String?
        var iconData: Data?
        var profiles: [CachedProfile]
    }
    private struct CachedProfile: Codable {
        var appIDName: String
        var applicationIdentifier: String
        var teamName: String
        var uuid: String
        var creationDate: Date?
        var expirationDate: Date?
    }

    init() {
        guard let data = UserDefaults.standard.data(forKey: "HomeScreenCache"),
              let cached = try? JSONDecoder().decode([CachedApp].self, from: data),
              !cached.isEmpty else { return }
        entries = cached.map { app in
            SideloadedAppStatus(
                app: SideloadedApp(bundleID: app.bundleID, name: app.name,
                                   version: app.version,
                                   applicationIdentifier: app.applicationIdentifier,
                                   iconData: app.iconData),
                profiles: app.profiles.map {
                    ProvisioningProfile(appIDName: $0.appIDName,
                                        applicationIdentifier: $0.applicationIdentifier,
                                        teamName: $0.teamName, uuid: $0.uuid,
                                        creationDate: $0.creationDate,
                                        expirationDate: $0.expirationDate)
                })
        }
        hasLoaded = true
    }

    private func saveCache() {
        let cached = entries.map { status in
            CachedApp(bundleID: status.app.bundleID, name: status.app.name,
                      version: status.app.version,
                      applicationIdentifier: status.app.applicationIdentifier,
                      iconData: status.app.iconData,
                      profiles: status.profiles.map {
                          CachedProfile(appIDName: $0.appIDName,
                                        applicationIdentifier: $0.applicationIdentifier,
                                        teamName: $0.teamName, uuid: $0.uuid,
                                        creationDate: $0.creationDate,
                                        expirationDate: $0.expirationDate)
                      })
        }
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: "HomeScreenCache")
        }
    }

    /// Silent audio, so a refresh a shortcut started with SideInstaller in the
    /// background isn't suspended halfway, as the location page keeps it
    /// running.
    private let keepAlive = KeepAlive()

    /// Keeps `autoLoad` to a single attempt.
    private var didAutoLoad = false

    /// The refresh in flight, kept so it can be called off between apps.
    private var refreshTask: Task<RefreshOutcome, Never>?

    /// What went wrong last, as a popup `RootView` stacks over the app.
    var popups: [ToolPopup] { lastError.map { [.error($0)] } ?? [] }

    func closePopup(_ popup: ToolPopup) { lastError = nil }

    /// Number of apps expiring within a day (shown in the header pill).
    var expiringSoon: Int {
        entries.filter { status in
            switch ExpiryUrgency.of(status.current) {
            case .expired, .critical: return true
            default: return false
            }
        }.count
    }

    /// Loads once per launch when the tunnel is up, without showing
    /// errors, even when the cache already filled the Home Screen — the
    /// reload is what brings in real icons and fresh expiry dates.
    /// Opening the page doesn't start LocalDevVPN; Load does.
    func autoLoad() {
        guard !didAutoLoad, !isWorking else { return }
        didAutoLoad = true
        load(quiet: true)
    }

    /// Ask the device what it has. `quiet` logs failures instead of showing them.
    func load(quiet: Bool = false) {
        guard !isWorking, !isRefreshing else { return }
        isWorking = true
        lastError = nil
        if !quiet { engine.log("=== Sideloaded apps: reading the device ===") }
        Task {
            do {
                try await performLoad()
            } catch {
                let message = Self.text(for: error)
                if quiet {
                    engine.log("Sideloaded apps: not ready yet (\(message))")
                } else {
                    lastError = message
                    engine.log("⛔️ Sideloaded apps: \(message)")
                }
            }
            isWorking = false
        }
    }

    /// Reads the device's apps and profiles and matches them. The caller holds
    /// `isWorking`.
    private func performLoad() async throws {
        let inventory = try await engine.sideloadedAppInventory()
        let apps = inventory.apps.compactMap(SideloadedApp.init(plist:))
        // TestFlight apps' profiles would otherwise show as unused.
        let profiles = inventory.profiles.compactMap(ProvisioningProfile.init(data:))
            .filter { !$0.isAppStoreDistribution }
        let matched = ProfileMatcher.match(apps: apps, profiles: profiles)
        entries = matched.entries.map { status in
            var status = status
            status.app.iconData = inventory.icons[status.app.bundleID]
            return status
        }
        unmatched = matched.unmatched
        saveCache()
        await rebuildRefreshable()
        hasLoaded = true
        lastRefreshed = Date()
        engine.log("Sideloaded apps: \(apps.count) sideloaded, \(profiles.count) profile(s) decoded.")
    }

    // MARK: - Refresh all

    /// Re-signs and reinstalls every refreshable app, one at a time (they share
    /// one device link and signing queue, and Apple's API is rate-limited).
    func refreshAll() {
        guard !isRefreshing, !isWorking, !refreshable.isEmpty else { return }
        guard !engine.isRunning else {
            lastError = ErrorHelp.explained(L("An install is already running. Wait for it to finish, then refresh."))
            return
        }
        startRefresh(refreshable, showsFailure: true)
    }

    /// Refreshes `selected` in the background, as the page lists them. A run
    /// that can't start says why in a popup when `showsFailure` is set.
    @discardableResult
    private func startRefresh(_ selected: [RefreshJob], showsFailure: Bool) -> Task<RefreshOutcome, Never> {
        jobs = selected
        isRefreshing = true
        lastError = nil
        refreshSummary = nil
        refreshStatus = L("Getting ready")
        engine.log("=== Refresh all: \(jobs.count) app(s) ===")

        let task = Task { () -> RefreshOutcome in
            defer {
                isRefreshing = false
                refreshStatus = nil
                refreshTask = nil
            }
            do {
                try await engine.prepareRefresh()
            } catch {
                let message = Self.text(for: error)
                if showsFailure { lastError = message }
                engine.log("⛔️ Refresh all: \(message)")
                jobs = []
                return RefreshOutcome(failure: message)
            }

            var refreshed = 0
            for index in jobs.indices {
                // Cancellation is checked between apps; signing and installing
                // can't be interrupted midway.
                if Task.isCancelled { break }
                let job = jobs[index]
                // Skip apps signed by a different team: the new bundle ID would
                // install a second copy instead of replacing the app.
                if let team = engine.signingTeamID, let installed = job.teamID, installed != team {
                    jobs[index].state = .failed(
                        L("Signed by team %@, not the one you're signed in as — refreshing it here would install a second copy.", installed))
                    continue
                }
                jobs[index].state = .working
                refreshStatus = L("Refreshing %@", job.name)
                do {
                    try await engine.refreshInstalledApp(named: job.name, ipaPath: job.ipa.path)
                    jobs[index].state = .done
                    refreshed += 1
                } catch {
                    let message = Self.text(for: error)
                    jobs[index].state = .failed(message)
                    engine.log("⛔️ Refresh \(job.name): \(message)")
                }
            }

            refreshSummary = jobs.count == 1
                ? (refreshed == 1 ? L("Refreshed. Its seven days start again now.")
                                  : L("Nothing was refreshed."))
                : L("Refreshed %d of %d apps.", refreshed, jobs.count)
            engine.log("Refresh all finished: \(refreshed)/\(jobs.count) refreshed.")
            let outcome = RefreshOutcome(jobs: jobs)
            // Read the device again, so the days on screen are the new ones.
            if refreshed > 0 {
                isRefreshing = false        // `load` won't run while a refresh holds the link
                load(quiet: true)
            }
            return outcome
        }
        refreshTask = task
        return task
    }

    // MARK: - Shortcuts

    /// Reads the device afresh for a Shortcuts action, once the page's own
    /// load or refresh is done.
    func loadForShortcut() async throws {
        try await waitUntilIdle()
        isWorking = true
        defer { isWorking = false }
        lastError = nil
        try await performLoad()
    }

    /// Reads the device afresh, then refreshes the refreshable apps whose
    /// bundle ids are in `bundleIDs`, or all of them when it's nil, as Refresh
    /// all does. Returns once the last one is done.
    func refreshForShortcut(_ bundleIDs: Set<String>? = nil) async throws -> RefreshOutcome {
        try await loadForShortcut()
        guard !engine.isRunning else {
            throw EngineError.message(L("An install is already running. Wait for it to finish, then refresh."))
        }
        let selected = bundleIDs.map { ids in refreshable.filter { ids.contains($0.bundleID) } }
            ?? refreshable
        guard !selected.isEmpty else {
            if entries.isEmpty {
                throw EngineError.message(L("Nothing on this device was installed with a provisioning profile. App Store apps don't expire, so they aren't listed here."))
            }
            let names = entries.filter { bundleIDs?.contains($0.app.bundleID) ?? true }.map(\.app.name)
            // An app picked in a shortcut may be gone since: its bundle ID, then.
            let named = names.isEmpty ? (bundleIDs ?? []).sorted() : names
            throw EngineError.message(L("%@ can't be refreshed: SideInstaller has no IPA to sign it again from. Refresh it in whatever installed it, or import its .ipa into SideInstaller first.",
                                        named.joined(separator: ", ")))
        }
        // A load from the page may have started meanwhile.
        try await waitUntilIdle()
        // Signing in, signing and installing each app outlast the time iOS
        // gives an action in the background.
        keepAlive.startAudio()
        defer { keepAlive.stopAudio() }
        let run = startRefresh(selected, showsFailure: false)
        // Stopping the shortcut stops the run after the app being refreshed,
        // as the page's Stop does.
        let outcome = await withTaskCancellationHandler {
            await run.value
        } onCancel: {
            run.cancel()
        }
        if let failure = outcome.failure { throw EngineError.message(failure) }
        return outcome
    }

    /// Returns once the page isn't loading or refreshing.
    private func waitUntilIdle() async throws {
        while isWorking || isRefreshing {
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Stops the run after the current app finishes. Remaining apps are left
    /// unchanged.
    func cancelRefresh() {
        guard isRefreshing, refreshTask != nil else { return }
        refreshTask?.cancel()
        refreshStatus = L("Stopping after this app")
        engine.log("Refresh all: stopping after the current app.")
    }

    /// A thrown error as the page should print it.
    private static func text(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Finds which listed apps have a matching IPA in Documents. The IPAs are
    /// read off the main thread.
    private func rebuildRefreshable() async {
        let installed = entries.map {
            InstalledRef(bundleID: $0.app.bundleID, name: $0.app.name,
                         teamID: $0.current?.teamIdentifier)
        }
        let matched = await Task.detached(priority: .userInitiated) {
            SideloadedAppsManager.pair(installed, with: IPALibrary.installable())
        }.value
        refreshable = matched
        unrefreshable = max(0, entries.count - matched.count)
        engine.log("Sideloaded apps: \(matched.count) of \(entries.count) can be refreshed from an IPA on disk.")
    }

    /// A page entry cut down to what the matching needs, so that work can be
    /// handed off the main actor.
    private struct InstalledRef: Sendable {
        let bundleID: String
        let name: String
        let teamID: String?
    }

    /// One job per installed app that an IPA on disk would reinstall, in the
    /// page's own order.
    private nonisolated static func pair(
        _ installed: [InstalledRef],
        with library: [(entry: IPALibrary.Entry, info: IPALibrary.AppInfo)]
    ) -> [RefreshJob] {
        installed.compactMap { app in
            guard let match = library.first(where: {
                ProfileMatcher.installed(app.bundleID, isBuiltFrom: $0.info.bundleID,
                                         teamID: app.teamID)
            }) else { return nil }
            return RefreshJob(bundleID: app.bundleID, name: app.name,
                              ipa: match.entry.url, teamID: app.teamID)
        }
    }
}

// MARK: - View

/// Sideloaded apps page: apps installed with a provisioning profile, their App
/// ID, and time until expiry. Pushed from Tools (relies on its `NavigationStack`).
struct AppsView: View {
    /// Observed so labels redraw when the language changes.
    @EnvironmentObject private var loc: Localizer
    /// Observed for `installProgress` during a refresh.
    @Environment(Engine.self) private var engine
    @ObservedObject var manager: SideloadedAppsManager

    @State private var showSettings = false
    /// Shows the "Refresh all" confirmation alert.
    @State private var confirmRefresh = false
    /// The App Library search, filtering the Home Screen grid by name.
    @State private var searchText = ""

    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(spacing: 16) {
                // Errors show as a popup, which `RootView` lays over the app.
                appList
                Spacer(minLength: 24)
                pagePill
                dock
                controlRow
                refreshRunCard
                refreshNote
                unmatchedSection
            }
            .frame(minHeight: geometry.size.height - 40)
            .padding(20)
            .pageColumn()
            .animation(.smooth(duration: 0.35), value: manager.entries)
            .animation(.smooth(duration: 0.3), value: manager.isWorking)
            .animation(.smooth(duration: 0.35), value: manager.jobs)
            .animation(.smooth(duration: 0.35), value: manager.refreshable)
        }
        }
        .background(AppBackground())
        .toolbar { settingsToolbarItem(isPresented: $showSettings) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear { manager.autoLoad() }
        .alert(L("Refresh all apps?"), isPresented: $confirmRefresh) {
            Button(L("Refresh all")) { manager.refreshAll() }
            Button(L("Cancel"), role: .cancel) { }
        } message: {
            Text(manager.refreshable.count == 1
                 ? L("%@ will be signed again with your Apple ID and installed over the copy on this device. It keeps its data, and its seven days start over.",
                     manager.refreshable.first?.name ?? "")
                 : L("%d apps will be signed again with your Apple ID and installed over the copies on this device. They keep their data, and their seven days start over.",
                     manager.refreshable.count))
        }
    }

    // MARK: Header

    private var header: some View {
        BrandHeader(icon: "app.badge.clock", image: "AppsLogo", title: L("Sideloaded apps")) {
            if manager.hasLoaded {
                let expiring = manager.expiringSoon
                StatusDot(text: expiring > 0
                             ? (expiring == 1 ? L("%d app needs refreshing", expiring)
                                              : L("%d apps need refreshing", expiring))
                             : (manager.entries.count == 1 ? L("%d app", manager.entries.count)
                                                           : L("%d apps", manager.entries.count)),
                          color: expiring > 0 ? Theme.warning : Theme.positive)
                    .transition(.opacity)
            }
        }
    }

    // MARK: Controls

    /// Small glass pills under the dock: load or reload, and refresh all
    /// when an app can be refreshed. Nothing big or red on the Home Screen.
    private var controlRow: some View {
        HStack(spacing: 12) {
            if manager.isRefreshing {
                glassPill(icon: nil, title: L("Cancel")) { manager.cancelRefresh() }
            } else {
                glassPill(icon: manager.hasLoaded ? "arrow.clockwise" : "iphone.and.arrow.forward",
                          title: manager.isWorking ? L("Reading the device")
                                : (manager.hasLoaded ? L("Reload") : L("Load apps"))) {
                    manager.load()
                }
                .disabled(manager.isWorking)
            }
            if manager.hasLoaded && !manager.refreshable.isEmpty && !manager.isRefreshing {
                glassPill(icon: "arrow.triangle.2.circlepath", title: L("Refresh all")) {
                    confirmRefresh = true
                }
                .disabled(manager.isWorking)
            }
            if manager.isRefreshing {
                ProgressView().tint(.white)
                Text(manager.refreshStatus ?? L("Getting ready"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .cascadeItem(2)
    }

    private func glassPill(icon: String?, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .cardSurface(in: Capsule())
        }
        .buttonStyle(.plain, sound: .tap)
    }

    // MARK: Refresh run

    /// Per-app refresh progress and results. Stays visible after the run so
    /// failures can be read.
    @ViewBuilder
    private var refreshRunCard: some View {
        if !manager.jobs.isEmpty {
            PanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Refresh all"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    // Enumerated so rows redraw on a language change.
                    ForEach(Array(manager.jobs.enumerated()), id: \.element.id) { _, job in
                        jobRow(job)
                    }
                    if let summary = manager.refreshSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .transition(.cardAppear)
            .cascadeItem(3)
        }
    }

    private func jobRow(_ job: RefreshJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                jobIcon(job.state)
                Text(job.name)
                    .font(.caption.weight(.medium))
                Spacer(minLength: 6)
                Text(Self.stateText(job.state))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Self.stateColor(job.state))
            }
            if case let .failed(message) = job.state {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func jobIcon(_ state: RefreshJob.State) -> some View {
        switch state {
        case .pending:  Image(systemName: "clock").foregroundStyle(Theme.muted)
        case .working:  ProgressView().controlSize(.small)
        case .done:     Image(systemName: "checkmark.circle").foregroundStyle(Theme.positive)
        case .failed:   Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.negative)
        }
    }

    private static func stateText(_ state: RefreshJob.State) -> String {
        switch state {
        case .pending: return L("Waiting")
        case .working: return L("In progress")
        case .done:    return L("Done")
        case .failed:  return L("Failed")
        }
    }

    private static func stateColor(_ state: RefreshJob.State) -> Color {
        switch state {
        case .pending, .working: return .secondary
        case .done:              return Theme.positive
        case .failed:            return Theme.negative
        }
    }

    /// Note explaining that apps without an IPA in SideInstaller can't be
    /// refreshed.
    @ViewBuilder
    private var refreshNote: some View {
        if manager.hasLoaded && manager.unrefreshable > 0 && !manager.entries.isEmpty {
            Text(manager.unrefreshable == 1
                 ? L("%d app here has no IPA in SideInstaller, so it can't be refreshed from this page. Refresh it in whatever installed it, or import its .ipa first.",
                     manager.unrefreshable)
                 : L("%d apps here have no IPA in SideInstaller, so they can't be refreshed from this page. Refresh them in whatever installed them, or import their .ipa first.",
                     manager.unrefreshable))
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cascadeItem(5 + manager.entries.count)
        }
    }

    // MARK: Home Screen

    /// Apps matching the App Library search.
    private var visibleEntries: [SideloadedAppStatus] {
        guard !searchText.isEmpty else { return manager.entries }
        return manager.entries.filter { $0.app.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// A clean Home Screen like Strata's: an App Library search pill, a
    /// four-column icon grid over the wallpaper, a page pill, and a glass
    /// dock. Tapping an icon opens the app's profile page.
    @ViewBuilder
    private var appList: some View {
        if manager.hasLoaded && manager.entries.isEmpty && !manager.isWorking {
            emptyState.transition(.cardAppear)
        } else if !manager.entries.isEmpty {
            VStack(spacing: 20) {
                appLibraryPill
                LazyVGrid(columns: Self.homeColumns, spacing: 22) {
                    ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { idx, status in
                        NavigationLink {
                            AppProfileDetail(status: status)
                        } label: {
                            homeIcon(status, showLabel: true)
                        }
                        .buttonStyle(.plain, sound: .tick)
                        .cascadeItem(1 + idx)
                    }
                }
            }
        } else if !manager.hasLoaded {
            appLibraryPill
        }
    }

    private static let homeColumns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)

    /// The App Library search pill from Strata's Home Screen.
    private var appLibraryPill: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
            TextField("", text: $searchText, prompt: Text(L("App Library")).foregroundStyle(.white))
                .font(.system(size: 20))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .frame(height: 54)
        .cardSurface(in: Capsule())
    }

    /// The search-and-page pill above the dock.
    private var pagePill: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
            Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 14)
            Circle().fill(.white).frame(width: 7, height: 7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 34)
        .cardSurface(in: Capsule())
    }

    /// The glass dock: the first four apps, no labels.
    private var dock: some View {
        HStack(spacing: 0) {
            ForEach(Array(manager.entries.prefix(4).enumerated()), id: \.element.id) { _, status in
                NavigationLink {
                    AppProfileDetail(status: status)
                } label: {
                    homeIcon(status, showLabel: false)
                }
                .buttonStyle(.plain, sound: .tick)
                .frame(maxWidth: .infinity)
            }
            if manager.entries.count < 4 {
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .cardSurface(in: RoundedRectangle(cornerRadius: 34, style: .continuous))
    }

    /// One Home Screen icon: a 60pt tile with the app's initial, its name
    /// under it, and a dot in the corner for expiry urgency.
    private func homeIcon(_ status: SideloadedAppStatus, showLabel: Bool) -> some View {
        let urgency = ExpiryUrgency.of(status.current)
        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                SideloadedAppIconView(status: status)
                Circle()
                    .fill(urgency.color)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                    .offset(x: 4, y: -4)
            }
            if showLabel {
                Text(status.app.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
                    .lineLimit(1)
                    .frame(width: 82)
            }
        }
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        PanelCard {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.app.dashed")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.muted)
                Text(L("No sideloaded apps"))
                    .font(.headline)
                Text(L("Nothing on this device was installed with a provisioning profile. App Store apps don't expire, so they aren't listed here."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    // MARK: Leftover profiles

    /// Profiles not used by any installed app (e.g. from deleted apps). Useful
    /// because a free Apple ID is limited to ten App IDs a week.
    @ViewBuilder
    private var unmatchedSection: some View {
        if !manager.unmatched.isEmpty {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Unused profiles"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(L("Issued to App IDs no installed app is running on."))
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Enumerated so rows redraw on a language change (a plain
                // `ForEach` over an `Equatable` array may skip re-rendering).
                ForEach(Array(manager.unmatched.enumerated()), id: \.element.id) { idx, profile in
                    PanelCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.appIDName.isEmpty ? profile.bundleIdentifier : profile.appIDName)
                                .font(.subheadline.weight(.medium))
                            Text(profile.applicationIdentifier)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(ExpiryUrgency.text(for: profile))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(ExpiryUrgency.of(profile).color)
                        }
                    }
                    .cascadeItem(7 + manager.entries.count + idx)
                }
            }
            .cascadeItem(6 + manager.entries.count)
        }
    }
}

// MARK: - Home

/// One app's icon: its real Home Screen icon when SpringBoard gave one,
/// otherwise a letter tile.
struct SideloadedAppIconView: View {
    let status: SideloadedAppStatus
    var size: CGFloat = 60

    var body: some View {
        Group {
            if let data = status.app.iconData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Theme.navy, .black],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(String(status.app.name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.46, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }
}

/// Opens an installed app by bundle ID, the way a home screen does.
enum AppLauncher {
    static func open(bundleID: String) {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject
        else { return }
        _ = workspace.perform(NSSelectorFromString("openApplicationWithBundleID:"), with: bundleID)
    }
}

/// The Home tab: Strata's clean Home Screen and App Library, nothing else.
/// Swipe between the two pages; the dock and page pill sit under the Home
/// page. Refreshing and profiles stay on the Tools page.
struct HomeView: View {
    @EnvironmentObject private var loc: Localizer
    @Environment(Engine.self) private var engine
    @ObservedObject var manager: SideloadedAppsManager

    @State private var page = 0
    @State private var infoStatus: SideloadedAppStatus?
    @State private var searchText = ""
    @State private var showFolder = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 14) {
                TabView(selection: $page) {
                    homePage.tag(0)
                    libraryPage.tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                if page == 0 {
                    pagePill
                    dock
                }
                if !manager.hasLoaded && manager.entries.isEmpty {
                    loadPill
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .animation(.smooth(duration: 0.3), value: page)
        }
        .toolbar { settingsToolbarItem(isPresented: $showSettings) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showFolder) { folderSheet }
        .onAppear { manager.autoLoad() }
        .navigationDestination(isPresented: Binding(
            get: { infoStatus != nil },
            set: { if !$0 { infoStatus = nil } }
        )) {
            if let infoStatus { AppProfileDetail(status: infoStatus) }
        }
    }

    // MARK: Home page

    private var homePage: some View {
        VStack {
            LazyVGrid(columns: Self.columns, spacing: 24) {
                ForEach(manager.entries) { status in
                    Button { AppLauncher.open(bundleID: status.app.bundleID) } label: {
                        VStack(spacing: 6) {
                            SideloadedAppIconView(status: status)
                            Text(status.app.name)
                                .font(.system(size: 12))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
                                .lineLimit(1)
                                .frame(width: 82)
                        }
                    }
                    .buttonStyle(.plain, sound: .tick)
                    .contextMenu {
                        Button { infoStatus = status } label: {
                            Label(L("App info"), systemImage: "info.circle")
                        }
                    }
                }
            }
            .padding(.top, 24)
            Spacer()
        }
    }

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)

    /// The search-and-page pill above the dock.
    private var pagePill: some View {
        HStack(spacing: 10) {
            Button { page = 1 } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 14)
            Circle().fill(.white).frame(width: 7, height: 7)
            Circle().fill(.white.opacity(0.4)).frame(width: 7, height: 7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 34)
        .cardSurface(in: Capsule())
    }

    /// The glass dock: the first four apps, centered, no labels.
    private var dock: some View {
        HStack(spacing: 24) {
            ForEach(manager.entries.prefix(4)) { status in
                Button { AppLauncher.open(bundleID: status.app.bundleID) } label: {
                    SideloadedAppIconView(status: status)
                }
                .buttonStyle(.plain, sound: .tick)
                .contextMenu {
                    Button { infoStatus = status } label: {
                        Label(L("App info"), systemImage: "info.circle")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .cardSurface(in: RoundedRectangle(cornerRadius: 34, style: .continuous))
    }

    // MARK: App Library page

    private var libraryPage: some View {
        VStack(spacing: 22) {
            searchPill
            if searchText.isEmpty {
                folderTile
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: Self.columns, spacing: 24) {
                    ForEach(filtered) { status in
                        Button { AppLauncher.open(bundleID: status.app.bundleID) } label: {
                            VStack(spacing: 6) {
                                SideloadedAppIconView(status: status)
                                Text(status.app.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
                                    .lineLimit(1)
                                    .frame(width: 82)
                            }
                        }
                        .buttonStyle(.plain, sound: .tick)
                        .contextMenu {
                            Button { infoStatus = status } label: {
                                Label(L("App info"), systemImage: "info.circle")
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.top, 10)
    }

    private var filtered: [SideloadedAppStatus] {
        manager.entries.filter { $0.app.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var searchPill: some View {
        HStack(spacing: 10) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
            TextField("", text: $searchText,
                      prompt: Text(L("App Library")).foregroundStyle(.white))
                .font(.system(size: 20))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minWidth: 140)
                .fixedSize(horizontal: true, vertical: false)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .frame(height: 54)
        .cardSurface(in: Capsule())
    }

    /// The App Library folder: three big icons and a mini grid, like the
    /// picture. Every sideloaded app lives in it.
    private var folderTile: some View {
        Button { showFolder = true } label: {
            VStack(spacing: 8) {
                folderPreview
                Text(L("Other"))
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
            }
        }
        .buttonStyle(.plain, sound: .tick)
        .disabled(manager.entries.isEmpty)
    }

    private var folderPreview: some View {
        let apps = manager.entries
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                folderIcon(apps, 0)
                folderIcon(apps, 1)
            }
            HStack(spacing: 12) {
                folderIcon(apps, 2)
                miniGrid(apps)
            }
        }
        .padding(14)
        .frame(width: 176, height: 176)
        .cardSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    @ViewBuilder
    private func folderIcon(_ apps: [SideloadedAppStatus], _ index: Int) -> some View {
        if apps.indices.contains(index) {
            SideloadedAppIconView(status: apps[index], size: 64)
        } else {
            Color.clear.frame(width: 64, height: 64)
        }
    }

    /// The folder's fourth cell: the next apps, small.
    private func miniGrid(_ apps: [SideloadedAppStatus]) -> some View {
        let rest = Array(apps.dropFirst(3).prefix(4))
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                miniIcon(rest, 0)
                miniIcon(rest, 1)
            }
            HStack(spacing: 6) {
                miniIcon(rest, 2)
                miniIcon(rest, 3)
            }
        }
        .frame(width: 64, height: 64)
    }

    @ViewBuilder
    private func miniIcon(_ apps: [SideloadedAppStatus], _ index: Int) -> some View {
        if apps.indices.contains(index) {
            SideloadedAppIconView(status: apps[index], size: 29)
        } else {
            Color.clear.frame(width: 29, height: 29)
        }
    }

    private var folderSheet: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                VStack(spacing: 20) {
                    HStack {
                        Text(L("Other"))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Button(L("Done")) { showFolder = false }
                            .foregroundStyle(.white)
                    }
                    LazyVGrid(columns: Self.columns, spacing: 24) {
                        ForEach(manager.entries) { status in
                            Button { AppLauncher.open(bundleID: status.app.bundleID) } label: {
                                VStack(spacing: 6) {
                                    SideloadedAppIconView(status: status)
                                    Text(status.app.name)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
                                        .lineLimit(1)
                                        .frame(width: 82)
                                }
                            }
                            .buttonStyle(.plain, sound: .tick)
                            .contextMenu {
                                Button { infoStatus = status } label: {
                                    Label(L("App info"), systemImage: "info.circle")
                                }
                            }
                        }
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        if !manager.refreshable.isEmpty && !manager.isRefreshing {
                            Button { manager.refreshAll() } label: {
                                Label(L("Refresh all"), systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(manager.isWorking)
                        }
                        if manager.isRefreshing {
                            ProgressView().tint(.white)
                            Text(manager.refreshStatus ?? L("Getting ready"))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                            Button(L("Cancel")) { manager.cancelRefresh() }
                        } else {
                            Button { manager.load() } label: {
                                Label(L("Reload"), systemImage: "arrow.clockwise")
                            }
                            .disabled(manager.isWorking)
                        }
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    if let summary = manager.refreshSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(20)
            }
            .navigationDestination(isPresented: Binding(
                get: { infoStatus != nil },
                set: { if !$0 { infoStatus = nil } }
            )) {
                if let infoStatus { AppProfileDetail(status: infoStatus) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: First load

    /// Shown only until the apps have loaded once; after that the cache
    /// keeps the Home Screen filled and this never comes back.
    private var loadPill: some View {
        Button { manager.load() } label: {
            HStack(spacing: 8) {
                if manager.isWorking {
                    ProgressView().tint(.white)
                    Text(L("Reading the device"))
                } else {
                    Image(systemName: "iphone.and.arrow.forward")
                    Text(L("Load apps"))
                }
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .cardSurface(in: Capsule())
        }
        .buttonStyle(.plain, sound: .tap)
        .disabled(manager.isWorking)
    }
}

// MARK: - Detail

/// Everything the device knows about one app: its App ID, the profile it is
/// living on, and the older profiles left behind by earlier signings.
private struct AppProfileDetail: View {
    let status: SideloadedAppStatus

    @EnvironmentObject private var loc: Localizer

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                appCard.cascadeItem(0)
                if let current = status.current {
                    profileCard(current, isCurrent: true).cascadeItem(1)
                } else {
                    noProfileCard.cascadeItem(1)
                }
                if !status.superseded.isEmpty {
                    HStack {
                        Text(L("Older profiles"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .cascadeItem(2)
                    ForEach(Array(status.superseded.enumerated()), id: \.element.id) { idx, profile in
                        profileCard(profile, isCurrent: false).cascadeItem(3 + idx)
                    }
                }
            }
            .padding(20)
            .pageColumn()
        }
        .background(AppBackground())
        .navigationTitle(status.app.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(status.app.name)
                    .font(.title3.weight(.semibold))
                field(L("Bundle identifier"), status.app.bundleID)
                if let identifier = status.app.applicationIdentifier ?? status.current?.applicationIdentifier {
                    field(L("App ID"), identifier)
                }
                if let version = status.app.version {
                    field(L("Version"), version)
                }
            }
        }
    }

    private func profileCard(_ profile: ProvisioningProfile, isCurrent: Bool) -> some View {
        let urgency = ExpiryUrgency.of(profile)
        return PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: urgency.symbol)
                        .foregroundStyle(urgency.color)
                    Text(ExpiryUrgency.text(for: profile))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(urgency.color)
                    Spacer(minLength: 6)
                    if isCurrent {
                        Text(L("In use"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                    }
                }
                if !profile.appIDName.isEmpty {
                    field(L("Profile name"), profile.appIDName)
                }
                if !profile.teamName.isEmpty {
                    field(L("Team"), profile.teamName)
                }
                if let team = profile.teamIdentifier {
                    field(L("Team ID"), team)
                }
                if profile.isWildcard {
                    // A wildcard App ID can't hold per-app capabilities, which
                    // is the usual reason an entitlement won't stick.
                    Text(L("Wildcard App ID — it covers any bundle id under it, and can't carry app-specific capabilities."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let created = profile.creationDate {
                    field(L("Issued"), created.formatted(
                        Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Localizer.locale)))
                }
                field(L("Profile UUID"), profile.uuid)
                capabilities(profile)
            }
        }
    }

    @ViewBuilder
    private func capabilities(_ profile: ProvisioningProfile) -> some View {
        let keys = profile.capabilityKeys
        if !keys.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Capabilities"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.top, 2)
        }
    }

    private var noProfileCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 4) {
                Label(L("No matching profile"), systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.medium))
                Text(L("The device has no provisioning profile for this App ID. The app may already have stopped launching — install it again to fix that."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A labelled value with selectable text, so identifiers can be copied.
    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
