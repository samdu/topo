import Contacts
import Foundation
import TopoTools

struct ContactRecord: Sendable, Equatable {
    var id: String
    var name: String
    var organization: String?
    var phones: [String] = []
    var emails: [String] = []
    var birthday: String?
    var addresses: [String] = []
}

/// The person's contacts, read only: `CNContactStore` on the phone, a fake in the suites.
protocol ContactDirectory: Sendable {
    func search(_ query: String) async throws -> [ContactRecord]
    func contact(id: String) async throws -> ContactRecord?
}

/// `topo contacts`: look people up. Nothing is written.
struct ContactsTool: Tool {
    let directory: any ContactDirectory
    let authorizer: any Authorizer
    let broker: PermissionBroker

    /// At most this many found are shown.
    static let shown = 20

    let name = "contacts"
    let summary = "look people up in the person's contacts (read only)"
    let usage = """
    topo contacts search QUERY          by name, phone number or email address; one a line, id first
    topo contacts show ID               everything Topo can read of one: phones, emails, birthday, addresses
    """

    enum Call: Equatable {
        case search(String)
        case show(id: String)
    }

    func run(_ arguments: [String]) async -> ToolReply {
        await PhoneTool.run(authorizer, broker: broker, usage: usage, parse: { try parse(arguments) }) { call in
            switch call {
            case let .search(query):
                let found = try await directory.search(query)
                var lines = found.prefix(Self.shown).map {
                    PhoneTool.line([$0.id, $0.name, $0.organization, $0.phones.first, $0.emails.first])
                }
                if found.count > Self.shown { lines.append("and \(found.count - Self.shown) more; search more narrowly") }
                return .ok(PhoneTool.lines(lines, none: "nobody found for \(query)"))
            case let .show(id):
                guard let record = try await directory.contact(id: id) else {
                    throw ToolFailure("no contact with the id \(id)")
                }
                var lines = ["name: \(record.name)"]
                if let organization = record.organization { lines.append("organization: \(organization)") }
                lines += record.phones.map { "phone: \($0)" }
                lines += record.emails.map { "email: \($0)" }
                if let birthday = record.birthday { lines.append("birthday: \(birthday)") }
                lines += record.addresses.map { "address: \($0)" }
                return .ok(lines.joined(separator: "\n") + "\n")
            }
        }
    }

    /// The call the arguments make, or why they make none: nothing here needs the permission.
    func parse(_ arguments: [String]) throws -> Call {
        let parsed = try Arguments(arguments)
        switch (parsed.words.first, parsed.words.count) {
        case ("search", 2) where !parsed.words[1].trimmingCharacters(in: .whitespaces).isEmpty:
            return .search(parsed.words[1])
        case ("show", 2):
            return .show(id: parsed.words[1])
        default:
            throw Misuse("contacts takes search QUERY or show ID")
        }
    }
}

struct ContactsAuthorizer: Authorizer {
    let name = "Contacts"

    func access() async -> Access {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: .undetermined
        case .denied: .denied
        case .restricted: .restricted
        // Full access, or iOS 18's limited access to the contacts the person chose.
        default: .granted
        }
    }

    func request() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }
}

/// `CNContactStore`'s fetches are synchronous, so the store is reachable only through `Confined`,
/// on a queue of its own. No note is read: the note key needs an entitlement.
final class ContactStoreDirectory: ContactDirectory, Sendable {
    private let confined = Confined(CNContactStore(), label: "zone.hexagon.topo.contacts")

    private static var keys: [CNKeyDescriptor] { [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactOrganizationNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor, CNContactBirthdayKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
    ] }

    /// What a search query is read as, and so which of Contacts' matchers it goes to.
    enum Match: Equatable {
        case email, phone, name
    }

    /// An email address has an `@`; a phone number is mostly digits, at least four of them, with
    /// its spaces, `+`, dashes and brackets as written; anything else is a name.
    static func match(for query: String) -> Match {
        let digits = query.filter(\.isNumber)
        if query.contains("@") { return .email }
        if digits.count >= 4, digits.count * 2 >= query.filter({ !$0.isWhitespace }).count { return .phone }
        return .name
    }

    static func predicate(for query: String) -> NSPredicate {
        switch match(for: query) {
        case .email: CNContact.predicateForContacts(matchingEmailAddress: query)
        case .phone: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query))
        case .name: CNContact.predicateForContacts(matchingName: query)
        }
    }

    func search(_ query: String) async throws -> [ContactRecord] {
        try await confined.run { store, _ in
            try store.unifiedContacts(matching: Self.predicate(for: query), keysToFetch: Self.keys).map(Self.record)
        }
    }

    func contact(id: String) async throws -> ContactRecord? {
        try await confined.run { store, _ in
            let found = try store.unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers: [id]),
                                                  keysToFetch: Self.keys)
            return found.first.map(Self.record)
        }
    }

    static func record(_ contact: CNContact) -> ContactRecord {
        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        var birthday: String?
        if let date = contact.birthday, let month = date.month, let day = date.day {
            birthday = date.year.map { String(format: "%04d-%02d-%02d", $0, month, day) } ?? String(format: "--%02d-%02d", month, day)
        }
        let postal = CNPostalAddressFormatter()
        return ContactRecord(
            id: contact.identifier, name: name.isEmpty ? contact.organizationName : name,
            organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
            phones: contact.phoneNumbers.map { labelled($0.label, $0.value.stringValue) },
            emails: contact.emailAddresses.map { labelled($0.label, $0.value as String) },
            birthday: birthday,
            addresses: contact.postalAddresses.map { labelled($0.label, postal.string(from: $0.value).replacingOccurrences(of: "\n", with: ", ")) })
    }

    private static func labelled(_ label: String?, _ value: String) -> String {
        guard let label else { return value }
        return "\(CNLabeledValue<NSString>.localizedString(forLabel: label)) \(value)"
    }
}
