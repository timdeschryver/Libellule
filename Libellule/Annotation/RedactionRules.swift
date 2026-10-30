import Foundation

struct CustomRedactionRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = String(localized: "Custom rule")
    var pattern = ""
    var isRegularExpression = false
    var isEnabled = true

    var expression: NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: isRegularExpression ? pattern : NSRegularExpression.escapedPattern(for: pattern), options: [.caseInsensitive])
    }

    var isValid: Bool { pattern.isEmpty || expression != nil }
}

enum RedactionRules {
    static let defaultsKey = "customRedactionRules"
    static let disabledKey = "disabledRedactionCategories"

    static var custom: [CustomRedactionRule] {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
            return (try? JSONDecoder().decode([CustomRedactionRule].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: defaultsKey) }
        }
    }

    static var disabled: Set<Redactor.Kind> {
        get { Set((UserDefaults.standard.array(forKey: disabledKey) as? [Int] ?? []).compactMap(Redactor.Kind.init(rawValue:))) }
        set { UserDefaults.standard.set(newValue.map(\.rawValue), forKey: disabledKey) }
    }
}
