import Foundation

public enum ModBadge: String, Codable, CaseIterable, Sendable {
    case verified
    case star
    case mod

    public var title: String {
        switch self {
        case .verified: return "Галочка"
        case .star: return "Звезда"
        case .mod: return "MOD"
        }
    }
}

public struct ModGift: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var sender: String = ""
    public var anonymous = false
    public var date = Date()
    public var comment = ""
    public var showsInProfile = true

    public init(title: String) {
        self.id = UUID()
        self.title = title
    }
}

public struct ModBanner: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case photo, gif, video
    }

    public let id: UUID
    public let kind: Kind

    fileprivate init(kind: Kind) {
        self.id = UUID()
        self.kind = kind
    }
}

public struct ModConfiguration: Codable, Equatable, Sendable {
    public var localPremium = false
    public var verified = false
    public var badge: ModBadge = .verified
    public var phone = ""
    public var hidePhone = false
    public var usernames: [String] = []
    public var showPeerIdAndDC = false
    public var fakeStars = false
    public var stars = "0"
    public var fakeGram = false
    public var gram = "0"
    public var fakeGifts = false
    public var showAllGifts = false
    public var gifts: [ModGift] = []
    public var bannerEnabled = false
    public var bannerOpacity = 70
    public fileprivate(set) var banner: ModBanner?

    public var displayedStars: String? { self.fakeStars ? Self.displayAmount(self.stars) : nil }
    public var displayedGram: String? { self.fakeGram ? Self.displayAmount(self.gram) : nil }

    public func displayPhone(real: String?) -> String? {
        if self.hidePhone { return nil }
        return self.phone.isEmpty ? real : self.phone
    }

    fileprivate static func displayAmount(_ amount: String) -> String {
        let parts = amount.split(separator: ".", omittingEmptySubsequences: false)
        let integral = parts.first ?? ""
        let digits = integral.first == "-" ? integral.dropFirst() : integral
        guard parts.count <= 2, !digits.isEmpty, digits.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              parts.dropFirst().allSatisfy({ $0.utf8.allSatisfy { (48 ... 57).contains($0) } }) else { return "0" }
        return amount
    }
}

public final class ModSettings: @unchecked Sendable {
    public enum SettingsError: LocalizedError {
        case invalidConfiguration, mediaTooLarge, unavailableStorage, insufficientBalance

        public var errorDescription: String? {
            switch self {
            case .invalidConfiguration: return "Не удалось применить локальные настройки."
            case .mediaTooLarge: return "Файл пустой или превышает допустимый размер."
            case .unavailableStorage: return "Хранилище приложения недоступно."
            case .insufficientBalance: return "Недостаточно средств на включённом виртуальном балансе."
            }
        }
    }

    public enum Currency: Equatable {
        case stars, gram
    }

    public static let shared = ModSettings()
    public static let didChange = Notification.Name("ModSettings.didChange")
    public static let title = "Telegram Mod"

    private struct Export: Codable {
        var version = 1
        var settings: ModConfiguration
        var media: Data?
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let fileManager = FileManager.default
    private let mediaLimit = 64 * 1024 * 1024

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ account: Int64) -> String {
        return "telegram.mod.v1.\(account)"
    }

    private func read(_ account: Int64) -> ModConfiguration {
        guard let data = self.defaults.data(forKey: self.key(account)),
              let settings = try? JSONDecoder().decode(ModConfiguration.self, from: data) else {
            return ModConfiguration()
        }
        return settings
    }

    private func write(_ settings: ModConfiguration, account: Int64) throws {
        self.defaults.set(try JSONEncoder().encode(settings), forKey: self.key(account))
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    public func settings(account: Int64) -> ModConfiguration {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.read(account)
    }

    public func update(account: Int64, _ change: (inout ModConfiguration) -> Void) {
        self.lock.lock()
        defer { self.lock.unlock() }
        let previous = self.read(account)
        var settings = previous
        change(&settings)
        if settings != previous {
            try? self.write(settings, account: account)
        }
    }

    public func addUsername(_ username: String, account: Int64) {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(trimmed.drop(while: { $0 == "@" }))
        guard !name.isEmpty, name.utf8.count <= 32, name.utf8.allSatisfy({
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 95
        }) else { return }
        self.update(account: account) { settings in
            if !settings.usernames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                settings.usernames.append(name)
            }
        }
    }

    public func addGift(_ gift: ModGift, price: Int64, currency: Currency = .stars, account: Int64) throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        var settings = self.read(account)
        guard settings.fakeGifts, settings.showAllGifts, price >= 0 else { throw SettingsError.invalidConfiguration }
        if price > 0 {
            let isStars = currency == .stars
            let value = isStars ? settings.displayedStars : settings.displayedGram
            var cost = isStars ? Decimal(price) : Decimal(price) / Decimal(1_000_000_000)
            guard let value, var balance = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
                  balance >= cost else { throw SettingsError.insufficientBalance }
            var remaining = Decimal()
            guard NSDecimalSubtract(&remaining, &balance, &cost, .plain) == .noError else {
                throw SettingsError.invalidConfiguration
            }
            if isStars {
                settings.stars = NSDecimalNumber(decimal: remaining).stringValue
            } else {
                settings.gram = NSDecimalNumber(decimal: remaining).stringValue
            }
        }
        settings.gifts.append(gift)
        try self.write(settings, account: account)
    }

    public func bannerURL(_ banner: ModBanner) -> URL? {
        guard let directory = self.fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let fileExtension: String
        switch banner.kind {
        case .photo: fileExtension = "image"
        case .gif: fileExtension = "gif"
        case .video: fileExtension = "mov"
        }
        return directory.appendingPathComponent("TelegramMod", isDirectory: true)
            .appendingPathComponent(banner.id.uuidString).appendingPathExtension(fileExtension)
    }

    public func setBanner(from url: URL, kind: ModBanner.Kind, account: Int64) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= self.mediaLimit else { throw SettingsError.mediaTooLarge }
        let media = try Data(contentsOf: url, options: .mappedIfSafe)
        self.lock.lock()
        defer { self.lock.unlock() }
        var settings = self.read(account)
        settings.bannerEnabled = true
        try self.replaceBanner(in: settings, kind: kind, media: media, account: account)
    }

    public func resetBanner(account: Int64) {
        self.lock.lock()
        defer { self.lock.unlock() }
        var settings = self.read(account)
        settings.bannerEnabled = false
        settings.bannerOpacity = 70
        try? self.replaceBanner(in: settings, kind: nil, media: nil, account: account)
    }

    private func replaceBanner(in settings: ModConfiguration, kind: ModBanner.Kind?, media: Data?, account: Int64) throws {
        var settings = settings
        let previous = self.read(account).banner
        var newURL: URL?
        if let kind, let media {
            guard !media.isEmpty, media.count <= self.mediaLimit else { throw SettingsError.mediaTooLarge }
            let banner = ModBanner(kind: kind)
            guard let url = self.bannerURL(banner) else { throw SettingsError.unavailableStorage }
            try self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try media.write(to: url, options: .atomic)
            newURL = url
            settings.banner = banner
        } else {
            settings.banner = nil
        }
        do {
            try self.write(settings, account: account)
        } catch {
            if let newURL { try? self.fileManager.removeItem(at: newURL) }
            throw error
        }
        if let previous, let oldURL = self.bannerURL(previous) {
            try? self.fileManager.removeItem(at: oldURL)
        }
    }

    public func exportJSON(account: Int64) throws -> Data {
        self.lock.lock()
        defer { self.lock.unlock() }
        let settings = self.read(account)
        let media = try settings.banner.flatMap { banner in
            try self.bannerURL(banner).map { try Data(contentsOf: $0, options: .mappedIfSafe) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Export(settings: settings, media: media))
    }

    public func importJSON(_ data: Data, account: Int64) throws {
        guard data.count <= self.mediaLimit * 2 else { throw SettingsError.mediaTooLarge }
        let value = try JSONDecoder().decode(Export.self, from: data)
        guard value.version == 1, (0 ... 100).contains(value.settings.bannerOpacity),
              Set(value.settings.gifts.map(\.id)).count == value.settings.gifts.count,
              (value.settings.banner == nil) == (value.media == nil) else { throw SettingsError.invalidConfiguration }
        self.lock.lock()
        defer { self.lock.unlock() }
        try self.replaceBanner(in: value.settings, kind: value.settings.banner?.kind, media: value.media, account: account)
    }

    public func resetAll(account: Int64) {
        self.lock.lock()
        defer { self.lock.unlock() }
        try? self.replaceBanner(in: ModConfiguration(), kind: nil, media: nil, account: account)
    }
}

public final class ModSettingsObservation {
    private let token: NSObjectProtocol

    public init(_ update: @escaping @Sendable () -> Void) {
        self.token = NotificationCenter.default.addObserver(forName: ModSettings.didChange, object: nil, queue: .main) { _ in
            update()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self.token)
    }
}
