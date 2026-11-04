import Foundation

/// App-target counterpart of `SoundIsleCore.L`. Kept local so view code can
/// call `L(...)` without importing a core symbol for presentation strings.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

func Lf(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
