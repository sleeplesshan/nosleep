import AppKit
import CoreText
import SwiftUI

/// Bundled Paperlogy fonts are registered for this process, never installed system-wide.
@MainActor
enum AppTypography {
    private static let faces = [
        "Paperlogy-4Regular",
        "Paperlogy-5Medium",
        "Paperlogy-6SemiBold",
        "Paperlogy-7Bold"
    ]
    private static var registeredFaces: Set<String> = []

    /// The app packager copies the original fonts and their OFL into Resources/Fonts.
    /// Returns false if any required face is missing or could not be registered.
    @discardableResult
    static func register() -> Bool {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true) else {
            return false
        }
        for face in faces where !registeredFaces.contains(face) {
            let url = directory.appendingPathComponent(face).appendingPathExtension("ttf")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var error: Unmanaged<CFError>?
            let success = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            // Repeated registration can report alreadyRegistered; resolve the exact face.
            let registrationError = error?.takeRetainedValue()
            let alreadyRegistered = registrationError.map {
                CFErrorGetCode($0) == CTFontManagerError.alreadyRegistered.rawValue
            } ?? false
            guard success || alreadyRegistered,
                  let font = NSFont(name: face, size: 13), font.fontName == face else { continue }
            registeredFaces.insert(face)
        }
        return registeredFaces.count == faces.count
    }

    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let face = faceName(weight: weight)
        guard registeredFaces.contains(face) else {
            return .system(size: size, weight: weight)
        }
        return .custom(face, fixedSize: size)
    }

    static func nsFont(size: CGFloat, weight: Font.Weight = .regular) -> NSFont {
        let face = faceName(weight: weight)
        if registeredFaces.contains(face), let font = NSFont(name: face, size: size) {
            return font
        }
        return .systemFont(ofSize: size, weight: nativeWeight(weight))
    }

    private static func faceName(weight: Font.Weight) -> String {
        if weight == .bold || weight == .heavy || weight == .black { return "Paperlogy-7Bold" }
        if weight == .semibold { return "Paperlogy-6SemiBold" }
        if weight == .medium { return "Paperlogy-5Medium" }
        return "Paperlogy-4Regular"
    }

    private static func nativeWeight(_ weight: Font.Weight) -> NSFont.Weight {
        if weight == .bold || weight == .heavy || weight == .black { return .bold }
        if weight == .semibold { return .semibold }
        if weight == .medium { return .medium }
        return .regular
    }
}
