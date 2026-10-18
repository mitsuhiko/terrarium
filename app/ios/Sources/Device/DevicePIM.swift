import Contacts
import CoreLocation
import EventKit
import Security
import UIKit
import UserNotifications

/// Keychain, notifications, contacts and reminders for the device modules (D40).
@MainActor
final class DevicePIM {
    unowned let bridge: DeviceBridge
    private lazy var contacts = CNContactStore()
    private lazy var events = EKEventStore()
    private lazy var locationForTriggers = CLLocationManager()

    init(bridge: DeviceBridge) {
        self.bridge = bridge
    }

    func perform(_ op: String, _ v: [String: Any]) async throws -> Any? {
        if op.hasPrefix("keychain.") { return try keychain(op, v) }
        if op.hasPrefix("notification.") { return try await notification(op, v) }
        if op.hasPrefix("contacts.") { return try await contact(op, v) }
        if op.hasPrefix("reminders.") { return try await reminder(op, v) }
        throw DeviceBridge.Failure(kind: "NotImplementedError", message: "device.\(op)")
    }

    // MARK: keychain

    /// Kept apart from the app's own items (the agent's credentials, D33).
    private static let servicePrefix = "eu.ronacher.pyterrarium.user:"

    private func keychain(_ op: String, _ v: [String: Any]) throws -> Any? {
        func query(_ service: String, _ account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.servicePrefix + service, kSecAttrAccount as String: account]
        }
        let service = v.string("service") ?? "", account = v.string("account") ?? ""
        switch op {
        case "keychain.get":
            var q = query(service, account)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case "keychain.set":
            SecItemDelete(query(service, account) as CFDictionary)
            var q = query(service, account)
            q[kSecValueData as String] = Data((v.string("password") ?? "").utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(q as CFDictionary, nil)
            guard status == errSecSuccess else { throw DeviceBridge.Failure.io("the keychain refused the password (\(status))") }
            return nil
        case "keychain.delete":
            SecItemDelete(query(service, account) as CFDictionary)
            return nil
        case "keychain.services", "keychain.reset":
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
            var out: CFTypeRef?
            SecItemCopyMatching(q as CFDictionary, &out)
            let items = (out as? [[String: Any]] ?? []).compactMap { item -> (String, String)? in
                guard let s = item[kSecAttrService as String] as? String, s.hasPrefix(Self.servicePrefix) else { return nil }
                return (String(s.dropFirst(Self.servicePrefix.count)), item[kSecAttrAccount as String] as? String ?? "")
            }
            if op == "keychain.services" { return items.map { [$0.0, $0.1] } }
            for (s, a) in items { SecItemDelete(query(s, a) as CFDictionary) }
            return nil
        default:
            throw DeviceBridge.Failure(kind: "NotImplementedError", message: "device.\(op)")
        }
    }

    // MARK: notifications

    private func notification(_ op: String, _ v: [String: Any]) async throws -> Any? {
        let center = UNUserNotificationCenter.current()
        switch op {
        case "notification.schedule":
            // The self-test can't answer the permission prompt; it schedules without asking.
            if !(bridge.model?.selftest ?? false) {
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                guard granted else { throw DeviceBridge.Failure.permission("Showing notifications") }
            }
            let id = v.string("identifier") ?? UUID().uuidString
            let content = UNMutableNotificationContent()
            content.title = v.string("title") ?? ""
            content.subtitle = v.string("subtitle") ?? ""
            content.body = v.string("message") ?? ""
            if v.string("sound_name") != nil { content.sound = .default }
            var info: [String: Any] = [:]
            if let url = v.string("action_url") { info["url"] = url }
            let actions = v["actions"] as? [[String: Any]] ?? []
            if !actions.isEmpty {
                info["actions"] = actions.map { $0.string("url") ?? "" }
                let category = UNNotificationCategory(identifier: "terrarium.\(id)", actions: actions.enumerated().map { i, a in
                    var options: UNNotificationActionOptions = [.foreground]
                    if a.bool("destructive") == true { options.insert(.destructive) }
                    if a.bool("text_input") == true {
                        return UNTextInputNotificationAction(identifier: "action-\(i)", title: a.string("title") ?? "", options: options,
                                                             textInputButtonTitle: a.string("text_input_button_title") ?? "Send",
                                                             textInputPlaceholder: a.string("text_input_placeholder") ?? "")
                    }
                    return UNNotificationAction(identifier: "action-\(i)", title: a.string("title") ?? "", options: options)
                }, intentIdentifiers: [])
                var categories = await center.notificationCategories()
                categories = categories.filter { $0.identifier != category.identifier }
                categories.insert(category)
                center.setNotificationCategories(categories)
                content.categoryIdentifier = category.identifier
            }
            content.userInfo = info
            for file in v["attachments"] as? [Any] ?? [] {
                let source = try bridge.fileURL(file, mount: v.mount)
                // The attachment is moved into the system's store: give it a copy.
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
                try FileManager.default.copyItem(at: source, to: copy)
                content.attachments.append(try UNNotificationAttachment(identifier: copy.lastPathComponent, url: copy))
            }
            let status = await center.notificationSettings().authorizationStatus
            guard status != .denied && status != .notDetermined else { throw DeviceBridge.Failure.permission("Showing notifications") }
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: try trigger(v)))
            return id
        case "notification.cancel":
            center.removePendingNotificationRequests(withIdentifiers: [v.string("identifier") ?? ""])
            return nil
        case "notification.cancelAll":
            center.removeAllPendingNotificationRequests()
            return nil
        case "notification.scheduled":
            return await center.pendingNotificationRequests().map(\.identifier)
        case "notification.removeDelivered":
            center.removeDeliveredNotifications(withIdentifiers: [v.string("identifier") ?? ""])
            return nil
        case "notification.removeAllDelivered":
            center.removeAllDeliveredNotifications()
            return nil
        default:
            throw DeviceBridge.Failure(kind: "NotImplementedError", message: "device.\(op)")
        }
    }

    private func trigger(_ v: [String: Any]) throws -> UNNotificationTrigger? {
        if let t = v["trigger"] as? [String: Any] {
            let repeats = t.bool("repeats") ?? false
            if let lat = t.double("latitude"), let lng = t.double("longitude") {
                if locationForTriggers.authorizationStatus == .notDetermined { locationForTriggers.requestWhenInUseAuthorization() }
                let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lng), radius: t.double("radius") ?? 100,
                                              identifier: UUID().uuidString)
                region.notifyOnEntry = t.bool("entry") ?? true
                region.notifyOnExit = t.bool("exit") ?? true
                return UNLocationNotificationTrigger(region: region, repeats: repeats)
            }
            var c = DateComponents()
            c.year = t.int("year"); c.quarter = t.int("quarter"); c.month = t.int("month"); c.day = t.int("day")
            c.weekday = t.int("weekday"); c.weekdayOrdinal = t.int("weekday_ordinal"); c.weekOfMonth = t.int("week_of_month")
            c.weekOfYear = t.int("week_of_year"); c.hour = t.int("hour"); c.minute = t.int("minute"); c.second = t.int("second")
            return UNCalendarNotificationTrigger(dateMatching: c, repeats: repeats)
        }
        let delay = v.double("delay") ?? 0
        return delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
    }

    // MARK: contacts

    nonisolated private static var personKeys: [CNKeyDescriptor] { [
        CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey, CNContactNamePrefixKey, CNContactNameSuffixKey,
        CNContactNicknameKey, CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey, CNContactPhoneticFamilyNameKey,
        CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactDepartmentNameKey, CNContactBirthdayKey, CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey, CNContactUrlAddressesKey, CNContactRelationsKey, CNContactPostalAddressesKey,
        CNContactSocialProfilesKey, CNContactInstantMessageAddressesKey, CNContactImageDataKey, CNContactTypeKey,
    ].map { $0 as CNKeyDescriptor } + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)] }

    private func authorizeContacts() async throws {
        let granted = (try? await contacts.requestAccess(for: .contacts)) ?? false
        guard granted else { throw DeviceBridge.Failure.permission("Access to contacts") }
    }

    private func contact(_ op: String, _ v: [String: Any]) async throws -> Any? {
        if op == "contacts.label" { return CNLabeledValue<NSString>.localizedString(forLabel: v.string("label") ?? "") }
        if op == "contacts.authorized" {
            if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined { _ = try? await contacts.requestAccess(for: .contacts) }
            let s = CNContactStore.authorizationStatus(for: .contacts)
            return s == .authorized || s == .limited
        }
        try await authorizeContacts()
        let store = contacts
        switch op {
        case "contacts.people":
            let query = v.string("query")
            let request = CNContactFetchRequest(keysToFetch: Self.personKeys)
            if let query { request.predicate = CNContact.predicateForContacts(matchingName: query) }
            var out: [[String: Any]] = []
            try store.enumerateContacts(with: request) { c, _ in out.append(Self.info(c)) }
            return out
        case "contacts.person":
            guard let c = try? store.unifiedContact(withIdentifier: v.string("id") ?? "", keysToFetch: Self.personKeys) else { return nil }
            return Self.info(c)
        case "contacts.vcard":
            let c = try store.unifiedContact(withIdentifier: v.string("id") ?? "", keysToFetch: [CNContactVCardSerialization.descriptorForRequiredKeys()])
            return String(data: try CNContactVCardSerialization.data(with: [c]), encoding: .utf8)
        case "contacts.groups":
            return try store.groups(matching: nil).map { ["id": $0.identifier, "name": $0.name] }
        case "contacts.save":
            let request = CNSaveRequest()
            var added: [CNMutableContact] = []
            for p in v["add"] as? [[String: Any]] ?? [] {
                let c = CNMutableContact()
                Self.apply(p, to: c)
                request.add(c, toContainerWithIdentifier: nil)
                added.append(c)
            }
            for u in v["update"] as? [[String: Any]] ?? [] {
                guard let c = try? store.unifiedContact(withIdentifier: u.string("id") ?? "", keysToFetch: Self.personKeys).mutableCopy() as? CNMutableContact else { continue }
                Self.apply(u["changes"] as? [String: Any] ?? [:], to: c)
                request.update(c)
            }
            for id in v["remove"] as? [String] ?? [] {
                guard let c = try? store.unifiedContact(withIdentifier: id, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]).mutableCopy() as? CNMutableContact else { continue }
                request.delete(c)
            }
            var groups: [CNMutableGroup] = []
            for name in v["add_groups"] as? [String] ?? [] {
                let g = CNMutableGroup()
                g.name = name
                request.add(g, toContainerWithIdentifier: nil)
                groups.append(g)
            }
            let existing = Dictionary(try store.groups(matching: nil).map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
            for u in v["update_groups"] as? [[String: Any]] ?? [] {
                guard let g = existing[u.string("id") ?? ""]?.mutableCopy() as? CNMutableGroup else { continue }
                g.name = u.string("name") ?? g.name
                request.update(g)
            }
            for id in v["remove_groups"] as? [String] ?? [] {
                if let g = existing[id]?.mutableCopy() as? CNMutableGroup { request.delete(g) }
            }
            try store.execute(request)
            return ["people": added.map(\.identifier), "groups": groups.map(\.identifier)]
        default:
            throw DeviceBridge.Failure(kind: "NotImplementedError", message: "device.\(op)")
        }
    }

    nonisolated private static func info(_ c: CNContact) -> [String: Any] {
        func labeled<T>(_ values: [CNLabeledValue<T>], _ convert: (T) -> Any) -> [[Any]] {
            values.map { [$0.label ?? "", convert($0.value)] }
        }
        var birthday: Any = NSNull()
        if let b = c.birthday, let month = b.month, let day = b.day {
            birthday = String(format: "%04d-%02d-%02d", b.year ?? 1604, month, day)
        }
        return [
            "id": c.identifier, "kind": c.contactType == .organization ? 1 : 0,
            "full_name": CNContactFormatter.string(from: c, style: .fullName) ?? "",
            "first_name": c.givenName, "middle_name": c.middleName, "last_name": c.familyName, "prefix": c.namePrefix,
            "suffix": c.nameSuffix, "nickname": c.nickname, "first_name_phonetic": c.phoneticGivenName,
            "middle_name_phonetic": c.phoneticMiddleName, "last_name_phonetic": c.phoneticFamilyName,
            "organization": c.organizationName, "job_title": c.jobTitle, "department": c.departmentName, "birthday": birthday,
            "phone": labeled(c.phoneNumbers) { $0.stringValue },
            "email": labeled(c.emailAddresses) { $0 as String },
            "url": labeled(c.urlAddresses) { $0 as String },
            "related_names": labeled(c.contactRelations) { $0.name },
            "address": labeled(c.postalAddresses) { a in
                ["Street": a.street, "City": a.city, "State": a.state, "ZIP": a.postalCode, "Country": a.country, "CountryCode": a.isoCountryCode]
            },
            "social_profile": labeled(c.socialProfiles) { ["service": $0.service, "username": $0.username, "url": $0.urlString] },
            "instant_message": labeled(c.instantMessageAddresses) { ["service": $0.service, "username": $0.username] },
            "image_data": c.imageData?.base64EncodedString() ?? NSNull(),
        ]
    }

    private static func apply(_ p: [String: Any], to c: CNMutableContact) {
        func str(_ key: String) -> String? { p.keys.contains(key) ? (p[key] as? String ?? "") : nil }
        if let s = str("first_name") { c.givenName = s }
        if let s = str("middle_name") { c.middleName = s }
        if let s = str("last_name") { c.familyName = s }
        if let s = str("prefix") { c.namePrefix = s }
        if let s = str("suffix") { c.nameSuffix = s }
        if let s = str("nickname") { c.nickname = s }
        if let s = str("first_name_phonetic") { c.phoneticGivenName = s }
        if let s = str("middle_name_phonetic") { c.phoneticMiddleName = s }
        if let s = str("last_name_phonetic") { c.phoneticFamilyName = s }
        if let s = str("organization") { c.organizationName = s }
        if let s = str("job_title") { c.jobTitle = s }
        if let s = str("department") { c.departmentName = s }
        if let k = p["kind"] as? NSNumber { c.contactType = k.intValue == 1 ? .organization : .person }
        if p.keys.contains("birthday") {
            if let s = p["birthday"] as? String, let d = ISODate.parse(s) {
                c.birthday = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: d)
            } else {
                c.birthday = nil
            }
        }
        if p.keys.contains("image_data") { c.imageData = (p["image_data"] as? String).flatMap { Data(base64Encoded: $0) } }
        func pairs(_ key: String) -> [(String, Any)]? {
            guard let list = p[key] as? [[Any]] else { return nil }
            return list.compactMap { $0.count == 2 ? (($0[0] as? String) ?? "", $0[1]) : nil }
        }
        if let l = pairs("phone") { c.phoneNumbers = l.map { CNLabeledValue(label: $0.0, value: CNPhoneNumber(stringValue: "\($0.1)")) } }
        if let l = pairs("email") { c.emailAddresses = l.map { CNLabeledValue(label: $0.0, value: "\($0.1)" as NSString) } }
        if let l = pairs("url") { c.urlAddresses = l.map { CNLabeledValue(label: $0.0, value: "\($0.1)" as NSString) } }
        if let l = pairs("related_names") { c.contactRelations = l.map { CNLabeledValue(label: $0.0, value: CNContactRelation(name: "\($0.1)")) } }
        if let l = pairs("address") {
            c.postalAddresses = l.map { label, value in
                let d = value as? [String: Any] ?? [:]
                let a = CNMutablePostalAddress()
                a.street = d.string("Street") ?? ""; a.city = d.string("City") ?? ""; a.state = d.string("State") ?? ""
                a.postalCode = d.string("ZIP") ?? ""; a.country = d.string("Country") ?? ""; a.isoCountryCode = d.string("CountryCode") ?? ""
                return CNLabeledValue(label: label, value: a as CNPostalAddress)
            }
        }
        if let l = pairs("social_profile") {
            c.socialProfiles = l.map { label, value in
                let d = value as? [String: Any] ?? [:]
                return CNLabeledValue(label: label, value: CNSocialProfile(urlString: d.string("url"), username: d.string("username"), userIdentifier: nil, service: d.string("service")))
            }
        }
        if let l = pairs("instant_message") {
            c.instantMessageAddresses = l.map { label, value in
                let d = value as? [String: Any] ?? [:]
                return CNLabeledValue(label: label, value: CNInstantMessageAddress(username: d.string("username") ?? "", service: d.string("service") ?? ""))
            }
        }
    }

    // MARK: reminders

    private func authorizeReminders() async throws {
        let granted = (try? await events.requestFullAccessToReminders()) ?? false
        guard granted else { throw DeviceBridge.Failure.permission("Access to reminders") }
    }

    private func reminder(_ op: String, _ v: [String: Any]) async throws -> Any? {
        try await authorizeReminders()
        let store = events
        switch op {
        case "reminders.calendars":
            return store.calendars(for: .reminder).map(Self.info)
        case "reminders.defaultCalendar":
            return store.defaultCalendarForNewReminders().map(Self.info)
        case "reminders.reminders":
            let calendars = v.string("calendar").flatMap { id in store.calendars(for: .reminder).filter { $0.calendarIdentifier == id } }
            let predicate: NSPredicate = switch v.bool("completed") {
            case true: store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: calendars)
            case false: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
            default: store.predicateForReminders(in: calendars)
            }
            let found = await withCheckedContinuation { (c: CheckedContinuation<Unchecked, Never>) in
                store.fetchReminders(matching: predicate) { c.resume(returning: Unchecked(value: ($0 ?? []).map(Self.info))) }
            }
            return found.value
        case "reminders.save":
            let r = v["reminder"] as? [String: Any] ?? [:]
            let item: EKReminder
            if let id = r.string("identifier"), let existing = store.calendarItem(withIdentifier: id) as? EKReminder {
                item = existing
            } else {
                item = EKReminder(eventStore: store)
                let calendar = r.string("calendar").flatMap { id in store.calendars(for: .reminder).first { $0.calendarIdentifier == id } }
                guard let target = calendar ?? store.defaultCalendarForNewReminders() else { throw DeviceBridge.Failure.io("there is no reminders list") }
                item.calendar = target
            }
            item.title = r.string("title") ?? ""
            item.notes = r.string("notes")
            item.url = r.string("url").flatMap(URL.init(string:))
            item.priority = r.int("priority") ?? 0
            item.isCompleted = r.bool("completed") ?? false
            if let due = ISODate.parse(r.string("due_date")) {
                item.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: due)
            } else {
                item.dueDateComponents = nil
            }
            if let alarms = r["alarms"] as? [[String: Any]] {
                item.alarms = alarms.map { a in
                    let alarm: EKAlarm
                    if let date = ISODate.parse(a.string("date")) { alarm = EKAlarm(absoluteDate: date) } else { alarm = EKAlarm() }
                    if let loc = a["location"] as? [Any], loc.count >= 3 {
                        let place = EKStructuredLocation(title: loc[0] as? String ?? "")
                        place.geoLocation = CLLocation(latitude: (loc[1] as? NSNumber)?.doubleValue ?? 0, longitude: (loc[2] as? NSNumber)?.doubleValue ?? 0)
                        place.radius = (loc.count > 3 ? (loc[3] as? NSNumber)?.doubleValue : nil) ?? 100
                        alarm.structuredLocation = place
                        alarm.proximity = a.string("proximity") == "enter" ? .enter : a.string("proximity") == "leave" ? .leave : .none
                    }
                    return alarm
                }
            }
            try store.save(item, commit: true)
            return Self.info(item)
        case "reminders.delete":
            guard let item = store.calendarItem(withIdentifier: v.string("identifier") ?? "") as? EKReminder else { return false }
            try store.remove(item, commit: true)
            return true
        case "reminders.saveCalendar":
            let calendar: EKCalendar
            if let id = v.string("identifier"), let existing = store.calendar(withIdentifier: id) {
                calendar = existing
            } else {
                calendar = EKCalendar(for: .reminder, eventStore: store)
                guard let source = store.defaultCalendarForNewReminders()?.source ?? store.sources.first(where: { $0.sourceType == .local }) else {
                    throw DeviceBridge.Failure.io("there is no account for reminder lists")
                }
                calendar.source = source
            }
            calendar.title = v.string("title") ?? calendar.title
            try store.saveCalendar(calendar, commit: true)
            return Self.info(calendar)
        case "reminders.deleteCalendar":
            guard let calendar = store.calendar(withIdentifier: v.string("identifier") ?? "") else { return false }
            try store.removeCalendar(calendar, commit: true)
            return true
        default:
            throw DeviceBridge.Failure(kind: "NotImplementedError", message: "device.\(op)")
        }
    }

    nonisolated private static func info(_ c: EKCalendar) -> [String: Any] {
        ["identifier": c.calendarIdentifier, "title": c.title]
    }

    nonisolated private static func info(_ r: EKReminder) -> [String: Any] {
        [
            "identifier": r.calendarItemIdentifier, "title": r.title ?? "", "notes": r.notes ?? NSNull(),
            "url": r.url?.absoluteString ?? NSNull(), "priority": r.priority, "completed": r.isCompleted,
            "completion_date": ISODate.format(r.completionDate), "due_date": ISODate.format(r.dueDateComponents?.date ?? r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }),
            "calendar": r.calendar?.calendarIdentifier ?? NSNull(),
            "alarms": (r.alarms ?? []).map { a -> [String: Any] in
                var out: [String: Any] = ["date": ISODate.format(a.absoluteDate)]
                if let loc = a.structuredLocation, let geo = loc.geoLocation {
                    out["location"] = [loc.title ?? "", geo.coordinate.latitude, geo.coordinate.longitude, loc.radius]
                    out["proximity"] = a.proximity == .enter ? "enter" : a.proximity == .leave ? "leave" : "none"
                }
                return out
            },
        ]
    }
}

/// Taps on notifications (D40): open the URL the program gave it (a
/// terrarium:// link runs a program), and show them while the app is open.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        var url = info["url"] as? String
        if response.actionIdentifier.hasPrefix("action-"), let i = Int(response.actionIdentifier.dropFirst("action-".count)),
           let actions = info["actions"] as? [String], actions.indices.contains(i) {
            url = actions[i]
        }
        if let text = (response as? UNTextInputNotificationResponse)?.userText {
            url = url?.replacingOccurrences(of: "{text_input}", with: text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text)
        }
        guard let string = url, !string.isEmpty, let target = URL(string: string) else { return }
        await MainActor.run {
            if let action = LaunchAction(url: target) { LaunchRouter.send(action) } else { UIApplication.shared.open(target) }
        }
    }
}
