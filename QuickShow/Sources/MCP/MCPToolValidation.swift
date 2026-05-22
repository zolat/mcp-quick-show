import Foundation
import MCP

// Shared validation helpers for MCP tool handlers. Mirrors the
// chokepoint pattern of `sidecar/src/handlers/_groupingFields.ts` and
// `sidecar/src/pathResolver.ts` — every `show_*` tool flows through
// the same grouping-fields parse, the same name/width/return_screenshot
// parse, and (for path-form tools) the same path resolver.

/// `group` / `description` / `hud_description` triple. Empty string
/// matters: empty → "clear", missing → "leave alone".
struct GroupingFields: Sendable {
    let group: String?
    let description: String?
    let hudDescription: String?
}

/// Schema caps shared by every show_* tool — kept in lockstep with
/// `sidecar/src/handlers/_groupingFields.ts`.
enum ToolValidation {
    static let groupMaxBytes = 256
    static let descriptionMaxBytes = 256
    static let hudDescriptionMaxBytes = 4 * 1024
    static let widthMin: Double = 100
    static let widthMax: Double = 4096

    struct Error: Swift.Error, Sendable {
        let message: String
    }

    /// Non-empty `name` argument. Trimmed; whitespace-only rejected.
    static func parseName(_ args: [String: Value]) throws -> String {
        guard let v = args["name"], let s = v.stringValue,
              !s.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw Error(message: "`name` must be a non-empty string")
        }
        return s
    }

    /// Optional integer width in points, clamped to [100, 4096]. Returns
    /// nil when absent or null. Accepts JSON number or integer.
    static func parseWidth(_ args: [String: Value]) throws -> Int? {
        guard let v = args["width"], !v.isNull else { return nil }
        let asDouble: Double? = v.doubleValue ?? v.intValue.map { Double($0) }
        guard let w = asDouble, w.isFinite, w >= widthMin, w <= widthMax else {
            throw Error(message: "`width` must be a finite number between 100 and 4096 points")
        }
        return Int(w.rounded())
    }

    /// `return_screenshot` — defaults to true when absent.
    static func parseReturnScreenshot(_ args: [String: Value]) -> Bool {
        if let v = args["return_screenshot"], let b = v.boolValue { return b }
        return true
    }

    /// Parse the standard grouping triple shared by every show_* tool.
    static func parseGroupingFields(_ args: [String: Value]) throws -> GroupingFields {
        return GroupingFields(
            group: try parseBytesCapped(args, key: "group", cap: groupMaxBytes),
            description: try parseBytesCapped(args, key: "description", cap: descriptionMaxBytes),
            hudDescription: try parseBytesCapped(args, key: "hud_description", cap: hudDescriptionMaxBytes)
        )
    }

    /// String field with a UTF-8 byte cap. Returns nil when absent/null
    /// so callers preserve "missing means leave-alone" semantics vs
    /// "empty means clear".
    static func parseBytesCapped(_ args: [String: Value], key: String, cap: Int) throws -> String? {
        guard let v = args[key] else { return nil }
        if v.isNull { return nil }
        guard let s = v.stringValue else {
            throw Error(message: "`\(key)` must be a string when present")
        }
        let bytes = Data(s.utf8).count
        if bytes > cap {
            throw Error(message: "`\(key)` too large: \(bytes) bytes > \(cap) byte cap")
        }
        return s
    }

    /// Object subschema for the grouping triple. Spread into every
    /// show_* tool's `properties` map.
    static let groupingSchemaProps: [String: Value] = [
        "group": .object([
            "type": .string("string"),
            "description": .string(
                "Optional grouping key. Panels sharing a `group` are rendered as tabs in the same floating HUD."
            ),
        ]),
        "description": .object([
            "type": .string("string"),
            "description": .string(
                "Optional short framing line for THIS tab, shown in the panel's description banner above the rendered content. Plain text, ≤256 bytes."
            ),
        ]),
        "hud_description": .object([
            "type": .string("string"),
            "description": .string(
                "Optional framing paragraph for the whole HUD, shown above the per-tab description. Plain text, ≤4 KB."
            ),
        ]),
    ]
}

// MARK: - Filesystem chokepoint

/// Sibling of `sidecar/src/pathResolver.ts`. Expands `~`, resolves
/// relative paths against the current working directory at the time
/// of resolution, stats the file, enforces a size cap, and
/// magic-byte-sniffs MIME for image formats. Used by `show_image`
/// (and `show_markdown`'s path form).
enum MCPPathResolver {
    struct Resolved {
        let absolutePath: String
        let size: Int
        let mime: String
    }

    struct Error: Swift.Error, Sendable {
        let message: String
    }

    static func resolve(
        _ rawPath: String,
        maxBytes: Int,
        allowedMimes: [String]? = nil
    ) throws -> Resolved {
        let absolute = try resolveAbsolute(rawPath)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: absolute, isDirectory: &isDir) else {
            throw Error(message: "file not found: \(absolute)")
        }
        if isDir.boolValue {
            throw Error(message: "not a regular file: \(absolute)")
        }
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: absolute)
        } catch {
            throw Error(message: "stat failed: \(absolute) (\(error.localizedDescription))")
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size > maxBytes {
            throw Error(message: "file too large: \(size) bytes > cap \(maxBytes)")
        }
        let mime = sniffMime(absolutePath: absolute)
        if let allowed = allowedMimes, !allowed.contains(mime) {
            throw Error(
                message: "unsupported MIME '\(mime)' for \(absolute); allowed: \(allowed.joined(separator: ", "))"
            )
        }
        return Resolved(absolutePath: absolute, size: size, mime: mime)
    }

    static func resolveAbsolute(_ raw: String) throws -> String {
        if raw.isEmpty { throw Error(message: "empty path") }
        var expanded = raw
        if expanded.hasPrefix("~/") {
            expanded = NSHomeDirectory() + String(expanded.dropFirst(1))
        } else if expanded == "~" {
            expanded = NSHomeDirectory()
        }
        if expanded.hasPrefix("/") {
            return (expanded as NSString).standardizingPath
        }
        let cwd = FileManager.default.currentDirectoryPath
        return ((cwd as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    /// Magic-byte MIME sniff for common image formats + UTF-8 text.
    /// Defaults to `text/plain` when nothing matches (markdown is a
    /// text format, so this is the safe default for show_markdown's
    /// path form).
    private static func sniffMime(absolutePath: String) -> String {
        guard let fh = FileHandle(forReadingAtPath: absolutePath) else {
            return "text/plain"
        }
        defer { try? fh.close() }
        let head: Data = (try? fh.read(upToCount: 16)) ?? Data()
        let bytes = [UInt8](head)
        if bytes.count >= 4 {
            // PNG: 89 50 4E 47
            if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
                return "image/png"
            }
            // JPEG: FF D8 FF
            if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
                return "image/jpeg"
            }
            // GIF: 47 49 46 38
            if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
                return "image/gif"
            }
        }
        if bytes.count >= 12 {
            // WebP: RIFF????WEBP
            if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
               bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
                return "image/webp"
            }
        }
        return "text/plain"
    }
}
