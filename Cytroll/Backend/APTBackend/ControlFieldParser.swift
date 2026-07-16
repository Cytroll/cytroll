import Foundation

/// Shared helpers for parsing Debian control-file style blocks
/// (`dpkg status`, APT `_Packages` indices). Both are the same field
/// format (`Key: Value`, with continuation lines indented by whitespace,
/// records separated by a blank line), so this is factored out instead
/// of duplicated per-parser.
///
/// `forEachBlock` is intentionally streaming: large repo indices (Chariz,
/// Havoc, Procursus main) can be several MB of text. Splitting that whole
/// string into a `[block]` array and then each block into a `[line]` array
/// (the old approach) temporarily duplicates the entire file's content 2-3x
/// in memory. Walking it once with `enumerateLines` and building one small
/// per-record dictionary at a time avoids that multiplication — peak extra
/// memory is one record, not the whole file.
public enum ControlFieldParser {

    /// Streams a multi-record control file, invoking `perform` once per
    /// record with that record's `[FieldName: Value]` fields. Continuation
    /// lines (starting with whitespace) are folded into the previous field.
    ///
    /// `perform` is `@escaping` because it's captured inside the
    /// `enumerateLines` closure — the compiler can't see that
    /// `enumerateLines` invokes its own body synchronously and never
    /// stashes it anywhere.
    public static func forEachBlock(in content: String, perform: @escaping ([String: String]) -> Void) {
        var fields: [String: String] = [:]
        var lastKey: String?
        var hasContent = false

        content.enumerateLines { line, _ in
            if line.isEmpty {
                if hasContent { perform(fields) }
                fields = [:]
                lastKey = nil
                hasContent = false
                return
            }

            hasContent = true

            if line.first == " " || line.first == "\t" {
                if let key = lastKey {
                    fields[key, default: ""] += "\n" + line
                }
                return
            }

            guard let colonIndex = line.firstIndex(of: ":") else { return }
            let key = String(line[line.startIndex..<colonIndex])
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
            lastKey = key
        }

        if hasContent { perform(fields) }
    }

    /// Strips a trailing version constraint like `(>= 1.0)` and trims whitespace,
    /// returning just the bare package identifier.
    public static func stripVersionConstraint(_ token: String) -> String {
        var name = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parenIndex = name.firstIndex(of: "(") {
            name = String(name[name.startIndex..<parenIndex])
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses a `Depends:` style field into OR-groups: `"a, b | c"` becomes
    /// `[["a"], ["b", "c"]]` — every group must have at least one satisfied
    /// alternative for the dependency to be considered met.
    public static func parseDependsGroups(_ raw: String?) -> [[String]] {
        guard let raw = raw, !raw.isEmpty else { return [] }
        return raw
            .components(separatedBy: ",")
            .map { group in
                group.components(separatedBy: "|")
                    .map { stripVersionConstraint($0) }
                    .filter { !$0.isEmpty }
            }
            .filter { !$0.isEmpty }
    }

    /// Parses a `Conflicts:`/`Breaks:` style field into a flat list of package IDs.
    public static func parseFlatPackageList(_ raw: String?) -> [String] {
        guard let raw = raw, !raw.isEmpty else { return [] }
        return raw
            .components(separatedBy: CharacterSet(charactersIn: ",|"))
            .map { stripVersionConstraint($0) }
            .filter { !$0.isEmpty }
    }
}
