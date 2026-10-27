import Foundation

/// AiDot cloud region (`prod-{region}-api.arnoo.com`).
public enum AiDotRegion: String, Sendable, Codable, CaseIterable, Hashable {
    case us
    case eu
    case jp

    /// `https://prod-{region}-api.arnoo.com/v35` (python-aidot `login_const.API_URL_TEMPLATE`).
    public var baseURL: URL { URL(string: "https://prod-\(rawValue)-api.arnoo.com/v35")! }
}

/// A country the AiDot app offers at sign-in, with its cloud region.
public struct AiDotCountry: Sendable, Hashable, Codable, Identifiable {
    /// ISO 3166-1 alpha-2 code.
    public var code: String
    /// Name exactly as python-aidot sends it in `countryKey: "region:<name>"`.
    public var name: String
    public var region: AiDotRegion

    public var id: String { code }

    public init(code: String, name: String, region: AiDotRegion) {
        self.code = code
        self.name = name
        self.region = region
    }

    /// `countryKey` login field.
    public var countryKey: String { "region:\(name.trimmingCharacters(in: .whitespaces))" }

    /// Default country used by python-aidot.
    public static let defaultCountry = AiDotCountry(code: "US", name: "United States", region: .us)

    /// Looks up an ISO code (case-insensitive).
    public static func named(code: String) -> AiDotCountry? {
        let c = code.uppercased()
        return all.first { $0.code == c }
    }

    /// Region for an ISO code, `nil` if the country is not offered.
    public static func region(forCountryCode code: String) -> AiDotRegion? { named(code: code)?.region }

    /// Countries sorted by display name (for the pairing picker).
    public static var sortedByName: [AiDotCountry] {
        all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `SUPPORTED_COUNTRYS` from python-aidot 0.3.59 `const.py` (130 entries), in upstream order.
    /// Generated from the upstream file; do not edit by hand.
    public static let all: [AiDotCountry] = [
        AiDotCountry(code: "AL", name: "Albania", region: .eu),
        AiDotCountry(code: "AG", name: "Antigua and Barbuda", region: .us),
        AiDotCountry(code: "AR", name: "Argentina", region: .us),
        AiDotCountry(code: "AT", name: "Austria", region: .eu),
        AiDotCountry(code: "AI", name: "Anguilla", region: .us),
        AiDotCountry(code: "AF", name: "Afghanistan", region: .jp),
        AiDotCountry(code: "AM", name: "Armenia", region: .jp),
        AiDotCountry(code: "AZ", name: "Azerbaijan", region: .jp),
        AiDotCountry(code: "AU", name: "Australia", region: .jp),
        AiDotCountry(code: "BO", name: "Bolivia", region: .us),
        AiDotCountry(code: "BR", name: "Brazil", region: .us),
        AiDotCountry(code: "BG", name: "Bulgaria", region: .eu),
        AiDotCountry(code: "BS", name: "Bahamas", region: .us),
        AiDotCountry(code: "BE", name: "Belgium", region: .eu),
        AiDotCountry(code: "BZ", name: "Belize", region: .us),
        AiDotCountry(code: "BB", name: "Barbados", region: .us),
        AiDotCountry(code: "BM", name: "Bermuda", region: .us),
        AiDotCountry(code: "BN", name: "Brunei", region: .jp),
        AiDotCountry(code: "BH", name: "Bahrain", region: .jp),
        AiDotCountry(code: "BD", name: "Bangladesh", region: .jp),
        AiDotCountry(code: "BT", name: "Bhutan", region: .jp),
        AiDotCountry(code: "CA", name: "Canada", region: .us),
        AiDotCountry(code: "CL", name: "Chile", region: .us),
        AiDotCountry(code: "CO", name: "Colombia", region: .us),
        AiDotCountry(code: "CR", name: "Costa Rica", region: .us),
        AiDotCountry(code: "CU", name: "Cuba", region: .us),
        AiDotCountry(code: "CZ", name: "Czech Republic", region: .eu),
        AiDotCountry(code: "HR", name: "Croatia", region: .eu),
        AiDotCountry(code: "KY", name: "Cayman Islands", region: .us),
        AiDotCountry(code: "KH", name: "Cambodia", region: .jp),
        AiDotCountry(code: "CY", name: "Cyprus", region: .jp),
        AiDotCountry(code: "DK", name: "Denmark", region: .eu),
        AiDotCountry(code: "DO", name: "Dominican Republic", region: .us),
        AiDotCountry(code: "EC", name: "Ecuador", region: .us),
        AiDotCountry(code: "SV", name: "El Salvador", region: .us),
        AiDotCountry(code: "EE", name: "Estonia", region: .eu),
        AiDotCountry(code: "FI", name: "Finland", region: .eu),
        AiDotCountry(code: "FR", name: "France", region: .eu),
        AiDotCountry(code: "GF", name: "French Guiana", region: .us),
        AiDotCountry(code: "GR", name: "Greece", region: .eu),
        AiDotCountry(code: "GT", name: "Guatemala", region: .us),
        AiDotCountry(code: "GY", name: "Guyana", region: .us),
        AiDotCountry(code: "DE", name: "Germany", region: .eu),
        AiDotCountry(code: "GD", name: "Grenada", region: .us),
        AiDotCountry(code: "GE", name: "Georgia", region: .jp),
        AiDotCountry(code: "HT", name: "Haiti", region: .us),
        AiDotCountry(code: "HN", name: "Honduras", region: .us),
        AiDotCountry(code: "HU", name: "Hungary", region: .eu),
        AiDotCountry(code: "IS", name: "Iceland", region: .eu),
        AiDotCountry(code: "IE", name: "Ireland", region: .eu),
        AiDotCountry(code: "IT", name: "Italy", region: .eu),
        AiDotCountry(code: "IN", name: "India", region: .jp),
        AiDotCountry(code: "ID", name: "Indonesia", region: .jp),
        AiDotCountry(code: "IR", name: "Iran", region: .jp),
        AiDotCountry(code: "IQ", name: "Iraq", region: .jp),
        AiDotCountry(code: "IL", name: "Israel", region: .eu),
        AiDotCountry(code: "JM", name: "Jamaica", region: .us),
        AiDotCountry(code: "JP", name: "Japan", region: .jp),
        AiDotCountry(code: "JO", name: "Jordan", region: .jp),
        AiDotCountry(code: "KZ", name: "Kazakhstan", region: .jp),
        AiDotCountry(code: "KR", name: "Korea", region: .jp),
        AiDotCountry(code: "KW", name: "Kuwait", region: .jp),
        AiDotCountry(code: "KG", name: "Kyrgyzstan", region: .jp),
        AiDotCountry(code: "LV", name: "Latvia", region: .eu),
        AiDotCountry(code: "LT", name: "Lithuania", region: .eu),
        AiDotCountry(code: "LU", name: "Luxembourg", region: .eu),
        AiDotCountry(code: "LI", name: "Liechtenstein", region: .eu),
        AiDotCountry(code: "LA", name: "Laos", region: .jp),
        AiDotCountry(code: "LB", name: "Lebanon", region: .jp),
        AiDotCountry(code: "MT", name: "Malta", region: .eu),
        AiDotCountry(code: "MX", name: "Mexico", region: .us),
        AiDotCountry(code: "MD", name: "Moldova", region: .eu),
        AiDotCountry(code: "MC", name: "Monaco", region: .eu),
        AiDotCountry(code: "MS", name: "Montserrat", region: .us),
        AiDotCountry(code: "ME", name: "Montenegro", region: .eu),
        AiDotCountry(code: "MY", name: "Malaysia", region: .jp),
        AiDotCountry(code: "MV", name: "Maldives", region: .jp),
        AiDotCountry(code: "MN", name: "Mongolia", region: .jp),
        AiDotCountry(code: "MM", name: "Myanmar", region: .jp),
        AiDotCountry(code: "NL", name: "Netherlands", region: .eu),
        AiDotCountry(code: "NI", name: "Nicaragua", region: .us),
        AiDotCountry(code: "NO", name: "Norway", region: .eu),
        AiDotCountry(code: "MK", name: "North Macedonia", region: .eu),
        AiDotCountry(code: "NZ", name: "New Zealand", region: .jp),
        AiDotCountry(code: "NP", name: "Nepal", region: .jp),
        AiDotCountry(code: "KP", name: "North Korea", region: .jp),
        AiDotCountry(code: "OM", name: "Oman", region: .jp),
        AiDotCountry(code: "PA", name: "Panama", region: .us),
        AiDotCountry(code: "PY", name: "Paraguay", region: .us),
        AiDotCountry(code: "PE", name: "Peru", region: .us),
        AiDotCountry(code: "PT", name: "Portugal", region: .eu),
        AiDotCountry(code: "PK", name: "Pakistan", region: .jp),
        AiDotCountry(code: "PS", name: "Palestine", region: .jp),
        AiDotCountry(code: "PH", name: "Philippines", region: .jp),
        AiDotCountry(code: "PL", name: "Poland", region: .eu),
        AiDotCountry(code: "QA", name: "Qatar", region: .jp),
        AiDotCountry(code: "RO", name: "Romania", region: .eu),
        AiDotCountry(code: "RU", name: "Russia", region: .eu),
        AiDotCountry(code: "SM", name: "San Marino", region: .eu),
        AiDotCountry(code: "SI", name: "Slovenia", region: .eu),
        AiDotCountry(code: "ES", name: "Spain", region: .eu),
        AiDotCountry(code: "LC", name: "St.Lucia", region: .us),
        AiDotCountry(code: "SR", name: "Suriname", region: .us),
        AiDotCountry(code: "SE", name: "Sweden", region: .eu),
        AiDotCountry(code: "SK", name: "Slovakia", region: .eu),
        AiDotCountry(code: "RS", name: "Serbia", region: .eu),
        AiDotCountry(code: "KN", name: "St.Kitts and Nevis", region: .us),
        AiDotCountry(code: "VC", name: "St.Vincent and the Grenadines", region: .us),
        AiDotCountry(code: "SA", name: "Saudi Arabia", region: .jp),
        AiDotCountry(code: "SG", name: "Singapore", region: .jp),
        AiDotCountry(code: "LK", name: "Sri Lanka", region: .jp),
        AiDotCountry(code: "SY", name: "Syria", region: .jp),
        AiDotCountry(code: "CH", name: "Switzerland", region: .eu),
        AiDotCountry(code: "TT", name: "Trinidad and Tobago", region: .us),
        AiDotCountry(code: "TC", name: "Turks & Caicos", region: .us),
        AiDotCountry(code: "TJ", name: "Tajikistan", region: .jp),
        AiDotCountry(code: "TH", name: "Thailand", region: .jp),
        AiDotCountry(code: "TG", name: "Togo", region: .jp),
        AiDotCountry(code: "TR", name: "Turkey", region: .eu),
        AiDotCountry(code: "TM", name: "Turkmenistan", region: .jp),
        AiDotCountry(code: "UA", name: "Ukraine", region: .eu),
        AiDotCountry(code: "GB", name: "United Kingdom", region: .eu),
        AiDotCountry(code: "US", name: "United States", region: .us),
        AiDotCountry(code: "UY", name: "Uruguay", region: .us),
        AiDotCountry(code: "AE", name: "United Arab Emirates", region: .jp),
        AiDotCountry(code: "UZ", name: "Uzbekistan", region: .jp),
        AiDotCountry(code: "VE", name: "Venezuela", region: .us),
        AiDotCountry(code: "VG", name: "Virgin Islands", region: .us),
        AiDotCountry(code: "VN", name: "Vietnam", region: .jp),
        AiDotCountry(code: "YE", name: "Yemen", region: .jp),
    ]
}
