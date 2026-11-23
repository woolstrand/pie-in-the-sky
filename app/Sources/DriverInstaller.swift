import Foundation

/// Installs the HAL driver bundled inside the app into /Library/Audio/Plug-Ins/HAL.
enum DriverInstaller {
    static let bundleName = "PieInTheSky.driver"
    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL").appendingPathComponent(bundleName)
    static var bundledURL: URL? { Bundle.main.resourceURL?.appendingPathComponent(bundleName) }

    enum Status { case missing, outdated, current }

    static var status: Status {
        guard FileManager.default.fileExists(atPath: installedURL.path) else { return .missing }
        return version(at: installedURL) == bundledURL.flatMap(version) ? .current : .outdated
    }

    private static func version(at url: URL) -> String? {
        // Read the plist directly: Bundle(url:) returns nil for a second bundle with the same identifier.
        (NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleVersion"] as? String
    }

    /// Copies the driver and restarts coreaudiod (audio drops for a second). Asks for an admin password.
    static func install() -> String? {
        guard let src = bundledURL, FileManager.default.fileExists(atPath: src.path) else {
            return "The driver is missing from the app bundle."
        }
        return runAsAdmin("""
            rm -rf \(q(installedURL.path)) && \
            cp -R \(q(src.path)) /Library/Audio/Plug-Ins/HAL/ && \
            chown -R root:wheel \(q(installedURL.path)) && \
            killall coreaudiod
            """)
    }

    static func uninstall() -> String? {
        runAsAdmin("rm -rf \(q(installedURL.path)) && killall coreaudiod")
    }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Returns an error message, or nil on success.
    private static func runAsAdmin(_ command: String) -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled." }
        return error[NSAppleScript.errorMessage] as? String ?? "Unknown error."
    }
}
