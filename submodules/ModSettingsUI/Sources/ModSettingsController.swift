import Foundation
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import Display
import ItemListUI
import AccountContext
import TelegramCore
import TelegramPresentationData
import SwiftSignalKit
import LegacyMediaPickerUI
import ModCore

private enum Category: Int, CaseIterable {
    case profile, gifts, banner, backup

    var title: String {
        switch self {
        case .profile: return "Профиль и статус"
        case .gifts: return "Фейковые подарки и звёзды"
        case .banner: return "Баннер профиля и обои"
        case .backup: return "Экспорт / Импорт и сброс"
        }
    }

    var subtitle: String {
        switch self {
        case .profile: return "Premium, верификация, номер, юзернеймы и ID"
        case .gifts: return "Локальный каталог подарков и виртуальный баланс"
        case .banner: return "Фото, GIF или видео и прозрачность"
        case .backup: return "Резервная копия настроек в JSON"
        }
    }

    var icon: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .gifts: return "gift"
        case .banner: return "photo.on.rectangle"
        case .backup: return "arrow.up.arrow.down"
        }
    }
}

private enum Page {
    case root
    case category(Category)
    case gift(UUID)
}

private struct Row: ItemListNodeEntry {
    enum Content: Equatable {
        case link(label: String, icon: String?)
        case text
        case toggle(Bool, String?)
        case input(String, String, Bool)
        case action(Bool)
    }

    let stableId: String
    let index: Int
    let section: Int32
    let title: String
    let subtitle: String
    let content: Content
    let tap: () -> Void
    let edit: (String) -> Void
    let toggle: (Bool) -> Void

    static func < (lhs: Row, rhs: Row) -> Bool { lhs.index < rhs.index }

    static func == (lhs: Row, rhs: Row) -> Bool {
        return lhs.stableId == rhs.stableId && lhs.index == rhs.index && lhs.section == rhs.section
            && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle && lhs.content == rhs.content
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self.content {
        case let .link(label, icon):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass,
                icon: icon.flatMap { UIImage(systemName: $0)?.withTintColor(presentationData.theme.list.itemAccentColor, renderingMode: .alwaysOriginal) },
                title: self.title, label: label, additionalDetailLabel: self.subtitle.isEmpty ? nil : self.subtitle,
                sectionId: self.section, style: .blocks, disclosureStyle: self.stableId == "logo" ? .none : .arrow, action: self.stableId == "logo" ? nil : self.tap)
        case .text:
            return ItemListTextItem(presentationData: presentationData, text: .plain(self.title), sectionId: self.section)
        case let .toggle(value, description):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass,
                title: self.title, text: description, value: value, maximumNumberOfLines: 0,
                sectionId: self.section, style: .blocks, updated: self.toggle)
        case let .input(value, placeholder, number):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass,
                title: self.title.isEmpty ? NSAttributedString() : NSAttributedString(string: self.title + "  ", textColor: presentationData.theme.list.itemPrimaryTextColor),
                text: value, placeholder: placeholder,
                type: number ? .decimal : .regular(capitalization: false, autocorrection: false),
                clearType: .always, maxLength: number ? 64 : 512, sectionId: self.section, textUpdated: self.edit,
                shouldUpdateText: { !number || $0.allSatisfy { "0123456789.-,".contains($0) } }, action: self.tap)
        case let .action(destructive):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: self.title,
                kind: destructive ? .destructive : .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: self.tap)
        }
    }
}

public func modSettingsController(context: AccountContext) -> ViewController {
    return makeController(context: context, page: .root)
}

private func makeController(context: AccountContext, page: Page) -> ViewController {
    let coordinator = SettingsPage(context: context, page: page)
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let updates = Signal<Void, NoError> { subscriber in
        let observer = NotificationCenter.default.addObserver(forName: ModSettings.didChange, object: nil, queue: .main) { _ in
            subscriber.putNext(())
        }
        subscriber.putNext(())
        return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
    }
    let state = combineLatest(context.sharedContext.presentationData, updates, coordinator.query.get())
    |> deliverOnMainQueue
    |> map { data, _, query -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let presentation = ItemListPresentationData(data)
        let controllerState = ItemListControllerState(presentationData: presentation, title: .text(coordinator.title),
            leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: data.strings.Common_Back))
        let nodeState = ItemListNodeState(presentationData: presentation, entries: coordinator.rows(query: query), style: .blocks, animateChanges: false)
        return (controllerState, (nodeState, coordinator))
    }
    let controller = ItemListController(presentationData: ItemListPresentationData(presentationData),
        updatedPresentationData: context.sharedContext.presentationData |> map(ItemListPresentationData.init(_:)),
        state: state, tabBarItem: nil)
    coordinator.controller = controller
    return controller
}

private final class SettingsPage: NSObject, PHPickerViewControllerDelegate {
    let context: AccountContext
    let page: Page
    weak var controller: ItemListController?
    let query = ValuePromise<String>("", ignoreRepeated: true)
    let store = ModSettings.shared
    var account: Int64 { self.context.account.id.int64 }

    init(context: AccountContext, page: Page) {
        self.context = context
        self.page = page
        super.init()
    }

    var title: String {
        switch self.page {
        case .root: return ModSettings.title
        case let .category(category): return category.title
        case .gift: return "Настройки подарка"
        }
    }

    func rows(query: String) -> [Row] {
        let settings = self.store.settings(account: self.account)
        var rows: [Row] = []
        func append(_ id: String, _ section: Int32, _ title: String, _ content: Row.Content, subtitle: String = "",
                    tap: @escaping () -> Void = {}, edit: @escaping (String) -> Void = { _ in }, toggle: @escaping (Bool) -> Void = { _ in }) {
            rows.append(Row(stableId: id, index: rows.count, section: section, title: title, subtitle: subtitle, content: content, tap: tap, edit: edit, toggle: toggle))
        }
        func toggle(_ id: String, _ section: Int32, _ title: String, _ key: WritableKeyPath<ModConfiguration, Bool>, description: String? = nil) {
            append(id, section, title, .toggle(settings[keyPath: key], description), subtitle: description ?? "", toggle: { [weak self] value in
                self?.update { $0[keyPath: key] = value }
            })
        }
        func input(_ id: String, _ section: Int32, _ title: String, _ key: WritableKeyPath<ModConfiguration, String>, placeholder: String, number: Bool = false) {
            append(id, section, title, .input(settings[keyPath: key], placeholder, number), subtitle: placeholder, edit: { [weak self] value in
                self?.update { $0[keyPath: key] = number ? value.replacingOccurrences(of: ",", with: ".") : value }
            })
        }

        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let categories: [Category]
        switch self.page {
        case .root:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            append("logo", 0, ModSettings.title, .link(label: "\(version) (\(build))", icon: "paperplane.circle.fill"), subtitle: "Версия сборки")
            append("search", 1, "", .input(query, "Поиск настроек", false), edit: { [weak self] value in self?.query.set(value) })
            if search.isEmpty {
                for category in Category.allCases {
                    append("category-\(category.rawValue)", Int32(category.rawValue + 2), category.title, .link(label: "", icon: category.icon), subtitle: category.subtitle, tap: { [weak self] in
                        self?.open(.category(category))
                    })
                }
                return rows
            }
            categories = Category.allCases
        case let .category(category):
            categories = [category]
        case let .gift(id):
            guard let gift = settings.gifts.first(where: { $0.id == id }) else { return [] }
            append("gift-title", 0, gift.title, .text)
            append("sender", 1, "Отправитель", .input(gift.sender, "Имя или @username", false), edit: { [weak self] value in
                self?.editGift(id) { $0.sender = value }
            })
            append("anon", 1, "Анонимно", .toggle(gift.anonymous, nil), toggle: { [weak self] value in
                self?.editGift(id) { $0.anonymous = value }
            })
            append("date", 1, "Дата и время", .link(label: DateFormatter.localizedString(from: gift.date, dateStyle: .short, timeStyle: .short), icon: "calendar"), tap: { [weak self] in
                self?.editDate(gift)
            })
            append("comment", 1, "Комментарий", .input(gift.comment, "Текст", false), edit: { [weak self] value in
                self?.editGift(id) { $0.comment = value }
            })
            append("visible", 2, "Показывать в профиле", .toggle(gift.showsInProfile, nil), toggle: { [weak self] value in
                self?.editGift(id) { $0.showsInProfile = value }
            })
            append("delete", 3, "Удалить подарок", .action(true), tap: { [weak self] in
                self?.update { $0.gifts.removeAll { $0.id == id } }
                self?.controller?.navigationController?.popViewController(animated: true)
            })
            return rows
        }

        for category in categories {
            let start = rows.count
            let section = Int32(category.rawValue * 4 + 2)
            switch category {
            case .profile:
                toggle("premium", section, "Локальный Premium", \.localPremium, description: "Клиентское оформление профиля и меню Premium")
                toggle("verified", section, "Verified", \.verified, description: "Локальная отметка в своём профиле")
                append("badge", section, "Бейдж верификации / мода", .link(label: settings.badge.title, icon: nil), tap: { [weak self] in self?.chooseBadge() })
                input("phone", section + 1, "Номер телефона", \.phone, placeholder: "+888 2020 6555")
                toggle("hidePhone", section + 1, "Скрыть мой номер телефона", \.hidePhone, description: "В профиле и настройках")
                append("username-add", section + 2, "Добавить коллекционный юзернейм", .link(label: "", icon: "at"), tap: { [weak self] in
                    self?.askForText(title: "Коллекционный юзернейм", placeholder: "@username") { [weak self] value in
                        guard let self else { return }
                        self.store.addUsername(value, account: self.account)
                    }
                })
                for (index, username) in settings.usernames.enumerated() {
                    append("username-\(index)", section + 2, "@\(username)", .link(label: "Удалить", icon: nil), subtitle: "Коллекционный юзернейм", tap: { [weak self] in
                        self?.update { $0.usernames.removeAll { $0 == username } }
                    })
                }
                toggle("peerInfo", section + 3, "Отображение ID и DC", \.showPeerIdAndDC, description: "Числовой PeerId и дата-центр подключения")
            case .gifts:
                toggle("fakeStars", section, "Фейковые звёзды", \.fakeStars)
                input("stars", section, "Баланс Stars", \.stars, placeholder: "0", number: true)
                toggle("fakeGram", section, "Фейковые GRAM (TON)", \.fakeGram)
                input("gram", section, "Баланс GRAM", \.gram, placeholder: "0", number: true)
                toggle("fakeGifts", section + 1, "Включить фейковые подарки", \.fakeGifts)
                toggle("allGifts", section + 1, "Показывать все подарки", \.showAllGifts, description: "Локальные покупки используют виртуальные звёзды")
                if settings.fakeGifts && settings.showAllGifts {
                    append("gift-add", section + 2, "Добавить локальный подарок", .link(label: "", icon: "gift"), tap: { [weak self] in
                        self?.askForText(title: "Локальный подарок", placeholder: "Название") { [weak self] title in
                            guard let self else { return }
                            let gift = ModGift(title: title)
                            do {
                                try self.store.addGift(gift, price: 0, account: self.account)
                                self.open(.gift(gift.id))
                            } catch { self.showError(error) }
                        }
                    })
                }
                for gift in settings.gifts {
                    append(gift.id.uuidString, section + 2, gift.title, .link(label: gift.showsInProfile ? "В профиле" : "Скрыт", icon: "gift"), subtitle: gift.comment, tap: { [weak self] in
                        self?.open(.gift(gift.id))
                    })
                }
            case .banner:
                toggle("banner", section, "Анимированный баннер", \.bannerEnabled, description: "В шапке собственного профиля")
                append("media", section, "Выбрать фото, GIF или видео", .link(label: settings.banner?.kind.rawValue ?? "", icon: "photo"), tap: { [weak self] in
                    self?.pickBanner()
                })
                append("alpha", section, "Прозрачность (%)", .link(label: "\(settings.bannerOpacity)%", icon: nil), tap: { [weak self] in
                    self?.editOpacity()
                })
                append("reset-banner", section, "Сбросить баннер", .action(true), tap: { [weak self] in
                    guard let self else { return }
                    self.store.resetBanner(account: self.account)
                })
            case .backup:
                append("export", section, "Экспорт JSON", .link(label: "", icon: "square.and.arrow.up"), subtitle: "Настройки и медиа баннера", tap: { [weak self] in self?.exportSettings() })
                append("import", section, "Импорт JSON", .link(label: "", icon: "square.and.arrow.down"), subtitle: "Восстановить резервную копию", tap: { [weak self] in self?.importSettings() })
                append("reset", section + 1, "Сбросить все настройки", .action(true), tap: { [weak self] in self?.confirmReset() })
            }
            if !search.isEmpty && !(category.title + " " + category.subtitle).localizedCaseInsensitiveContains(search) {
                let matches = rows[start...].filter {
                    let searchableText = [$0.title, $0.subtitle].joined(separator: " ")
                    return searchableText.localizedCaseInsensitiveContains(search)
                        || (category == .gifts && UUID(uuidString: $0.stableId) != nil
                            && "Отправитель Анонимно Дата и время Комментарий Показывать в профиле Удалить подарок".localizedCaseInsensitiveContains(search))
                }
                rows.replaceSubrange(start ..< rows.count, with: matches)
            }
        }
        if !search.isEmpty {
            if rows.count == 2 {
                append("no-results", 20, "Ничего не найдено", .text)
            }
        }
        return rows
    }

    private func update(_ change: (inout ModConfiguration) -> Void) {
        self.store.update(account: self.account, change)
    }

    private func editGift(_ id: UUID, _ change: (inout ModGift) -> Void) {
        self.update {
            guard let index = $0.gifts.firstIndex(where: { $0.id == id }) else { return }
            change(&$0.gifts[index])
        }
    }

    private func open(_ page: Page) {
        self.controller?.push(makeController(context: self.context, page: page))
    }

    private func askForText(title: String, placeholder: String, completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = placeholder }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Добавить", style: .default) { [weak alert] _ in
            guard let value = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            completion(value)
        })
        self.controller?.present(alert, animated: true)
    }

    private func chooseBadge() {
        let alert = UIAlertController(title: "Бейдж", message: nil, preferredStyle: .alert)
        for badge in ModBadge.allCases {
            alert.addAction(UIAlertAction(title: badge.title, style: .default) { [weak self] _ in
                self?.update { $0.badge = badge }
            })
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        self.controller?.present(alert, animated: true)
    }

    private func editDate(_ gift: ModGift) {
        let picker = UIDatePicker()
        picker.datePickerMode = .dateAndTime
        picker.preferredDatePickerStyle = .wheels
        picker.date = gift.date
        let editor = ControlEditor(title: "Дата и время", control: picker)
        picker.addAction(UIAction { [weak self, weak picker] _ in
            if let picker { self?.editGift(gift.id) { $0.date = picker.date } }
        }, for: .valueChanged)
        self.controller?.present(editor, animated: true)
    }

    private func editOpacity() {
        let slider = UISlider()
        slider.maximumValue = 100
        slider.value = Float(self.store.settings(account: self.account).bannerOpacity)
        let editor = ControlEditor(title: "\(Int(slider.value))%", control: slider)
        slider.addAction(UIAction { [weak self, weak slider, weak editor] _ in
            guard let slider else { return }
            let value = Int(slider.value.rounded())
            self?.update { $0.bannerOpacity = value }
            editor?.label.text = "\(value)%"
        }, for: .valueChanged)
        self.controller?.present(editor, animated: true)
    }

    private func pickBanner() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .any(of: [.images, .videos])
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        self.controller?.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        let type: UTType
        let kind: ModBanner.Kind
        if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
            type = .gif
            kind = .gif
        } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            type = .movie
            kind = .video
        } else {
            type = .image
            kind = .photo
        }
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, error in
            guard let self else { return }
            do {
                guard let url else { throw error ?? ModSettings.SettingsError.invalidConfiguration }
                try self.store.setBanner(from: url, kind: kind, account: self.account)
            } catch {
                DispatchQueue.main.async { [weak self] in self?.showError(error) }
            }
        }
    }

    private func exportSettings() {
        do {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("TelegramMod-\(UUID().uuidString).json")
            try self.store.exportJSON(account: self.account).write(to: file, options: .atomic)
            let theme = self.context.sharedContext.currentPresentationData.with { $0.theme }
            let picker = legacyICloudFilePicker(theme: theme, mode: .export, url: file, dismissed: {
                try? FileManager.default.removeItem(at: file)
            }, completion: { _ in try? FileManager.default.removeItem(at: file) })
            self.controller?.present(picker, in: .window(.root))
        } catch { self.showError(error) }
    }

    private func importSettings() {
        let theme = self.context.sharedContext.currentPresentationData.with { $0.theme }
        let picker = legacyICloudFilePicker(theme: theme, mode: .import, documentTypes: [UTType.json.identifier]) { [weak self] urls in
            guard let self, let url = urls.first else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 128 * 1024 * 1024 else { throw ModSettings.SettingsError.mediaTooLarge }
                try self.store.importJSON(Data(contentsOf: url, options: .mappedIfSafe), account: self.account)
            } catch { self.showError(error) }
        }
        self.controller?.present(picker, in: .window(.root))
    }

    private func confirmReset() {
        let alert = UIAlertController(title: "Сбросить настройки мода?", message: "Локальные подарки и баннер будут удалены.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Сбросить", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.store.resetAll(account: self.account)
        })
        self.controller?.present(alert, animated: true)
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: ModSettings.title, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.controller?.present(alert, animated: true)
    }
}

private final class ControlEditor: UIViewController {
    let label = UILabel()

    init(title: String, control: UIControl) {
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .pageSheet
        self.view.backgroundColor = .systemGroupedBackground
        self.sheetPresentationController?.detents = [.medium()]
        self.label.text = title
        self.label.textAlignment = .center
        self.label.font = .preferredFont(forTextStyle: .headline)
        let close = UIButton(type: .system)
        close.setTitle("Готово", for: .normal)
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [self.label, control, close])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: self.view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: self.view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { return nil }
}

/// Presents a separate purchase UI backed solely by the local, virtual currency store.
public func presentModGiftPurchase(on controller: ViewController, context: AccountContext, title: String, price: Int64, currency: ModSettings.Currency = .stars) {
    let account = context.account.id.int64
    let cost: String
    switch currency {
    case .stars: cost = "\(price) Stars"
    case .gram:
        let amount = NSDecimalNumber(decimal: Decimal(price) / Decimal(1_000_000_000))
        cost = "\(amount.stringValue) GRAM"
    }
    let alert = UIAlertController(title: title, message: "Добавить в свой профиль за \(cost) виртуального баланса?", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
    alert.addAction(UIAlertAction(title: "Купить локально", style: .default) { [weak controller] _ in
        let gift = ModGift(title: title)
        do {
            try ModSettings.shared.addGift(gift, price: price, currency: currency, account: account)
            controller?.push(makeController(context: context, page: .gift(gift.id)))
        } catch {
            DispatchQueue.main.async { [weak controller] in
                let notice = UIAlertController(title: ModSettings.title, message: error.localizedDescription, preferredStyle: .alert)
                notice.addAction(UIAlertAction(title: "OK", style: .default))
                controller?.present(notice, animated: true)
            }
        }
    })
    controller.present(alert, animated: true)
}
