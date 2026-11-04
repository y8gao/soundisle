import Foundation

/// Looks `key` up in the app bundle's localization tables. Chinese literals are
/// the keys, so an untranslated string (and unit tests, which have no bundle
/// localization) fall back to the Chinese source text.
public func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

/// Localizes a format string and fills its placeholders.
public func Lf(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
