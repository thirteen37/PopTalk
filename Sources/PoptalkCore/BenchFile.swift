import Foundation

extension BenchReport {
    /// `DateFormatter` format for `date` and result file names: seconds, so runs a minute apart don't collide.
    public static let dateFormat = "yyyy-MM-dd-HHmmss"

    /// `<date>-<provider>-<model>[-<filter>].json`, with `/` in the model and non-alphanumerics in the
    /// `--filter` glob made file-safe (`s-*` → `s`), so separate filtered runs don't overwrite each other.
    public static func fileName(date: String, provider: String, model: String, filter: String?) -> String {
        let slug = (filter ?? "").replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(date)-\(provider)-\(model.replacingOccurrences(of: "/", with: "_"))\(slug.isEmpty ? "" : "-" + slug).json"
    }
}
