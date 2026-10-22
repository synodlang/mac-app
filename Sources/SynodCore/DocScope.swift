import Foundation

/// The result of `synod doc --json` (format `synod-doc/1`). Unknown keys are ignored and a
/// major version other than 1 is rejected.
public struct DocReport: Sendable, Equatable, Decodable {
    /// The file `--scope` was asked about, with the packages it can see.
    public struct Scope: Sendable, Equatable, Decodable {
        public struct Import: Sendable, Equatable, Decodable {
            public let path: String
            /// How this file writes the package: the alias under `use … as`, else the last segment.
            public let qualifier: String
        }

        public let file: String
        /// The file's own package name.
        public let package: String
        public let imports: [Import]

        enum CodingKeys: String, CodingKey { case file, package, imports }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            file = try c.decode(String.self, forKey: .file)
            package = try c.decodeIfPresent(String.self, forKey: .package) ?? ""
            imports = try c.decodeIfPresent([Import].self, forKey: .imports) ?? []
        }
    }

    public struct Position: Sendable, Equatable, Decodable {
        public let file: String
        public let line: Int
        public let col: Int
    }

    /// One item of a pattern: a word, or a hole with its type.
    public struct Item: Sendable, Equatable, Decodable {
        public let word: String?
        public let hole: String?
        public let type: String?
    }

    public struct Block: Sendable, Equatable, Decodable {
        public let word: String
        /// The block hole's name, `""` for an unnamed one.
        public let hole: String
    }

    public struct Receiver: Sendable, Equatable, Decodable {
        public let name: String
        public let type: String
    }

    public struct Phrase: Sendable, Equatable, Decodable {
        public let pattern: String
        public let items: [Item]
        public let blocks: [Block]
        public let receiver: Receiver?
        public let gives: String
        /// Std only; nil for other packages.
        public let contexts: [String]?
        /// `phrase`, `node-event` or `trace-event`.
        public let kind: String
        public let native: Bool
        public let exported: Bool
        public let doc: String
        public let def: Position?

        enum CodingKeys: String, CodingKey {
            case pattern, items, blocks, receiver, gives, contexts, kind, native, exported, doc, def
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pattern = try c.decode(String.self, forKey: .pattern)
            items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
            blocks = try c.decodeIfPresent([Block].self, forKey: .blocks) ?? []
            receiver = try c.decodeIfPresent(Receiver.self, forKey: .receiver)
            gives = try c.decodeIfPresent(String.self, forKey: .gives) ?? "—"
            contexts = try c.decodeIfPresent([String].self, forKey: .contexts)
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "phrase"
            native = try c.decodeIfPresent(Bool.self, forKey: .native) ?? false
            exported = try c.decodeIfPresent(Bool.self, forKey: .exported) ?? true
            doc = try c.decodeIfPresent(String.self, forKey: .doc) ?? ""
            def = try c.decodeIfPresent(Position.self, forKey: .def)
        }

        public var isEvent: Bool { kind != "phrase" }
    }

    public struct Field: Sendable, Equatable, Decodable {
        public let name: String
        public let type: String
        public let exported: Bool

        enum CodingKeys: String, CodingKey { case name, type, exported }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
            exported = try c.decodeIfPresent(Bool.self, forKey: .exported) ?? true
        }
    }

    public struct Record: Sendable, Equatable, Decodable {
        public let name: String
        public let doc: String
        public let fields: [Field]

        enum CodingKeys: String, CodingKey { case name, doc, fields }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            doc = try c.decodeIfPresent(String.self, forKey: .doc) ?? ""
            fields = try c.decodeIfPresent([Field].self, forKey: .fields) ?? []
        }
    }

    public struct NodeType: Sendable, Equatable, Decodable {
        public let doc: String
        public let fields: [Field]

        enum CodingKeys: String, CodingKey { case doc, fields }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            doc = try c.decodeIfPresent(String.self, forKey: .doc) ?? ""
            fields = try c.decodeIfPresent([Field].self, forKey: .fields) ?? []
        }
    }

    public struct Package: Sendable, Equatable, Decodable {
        public let path: String
        public let name: String
        public let qualifier: String
        public let title: String
        public let std: Bool
        public let activates: Bool
        public let phrases: [Phrase]
        public let records: [Record]
        public let node: NodeType?

        enum CodingKeys: String, CodingKey {
            case path, name, qualifier, title, std, activates, phrases, records, node
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            qualifier = try c.decodeIfPresent(String.self, forKey: .qualifier) ?? name
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            std = try c.decodeIfPresent(Bool.self, forKey: .std) ?? false
            activates = try c.decodeIfPresent(Bool.self, forKey: .activates) ?? false
            phrases = try c.decodeIfPresent([Phrase].self, forKey: .phrases) ?? []
            records = try c.decodeIfPresent([Record].self, forKey: .records) ?? []
            node = try c.decodeIfPresent(NodeType.self, forKey: .node)
        }
    }

    public let format: String
    public let diagnostics: [CheckReport.Diagnostic]
    public let scope: Scope?
    public let packages: [Package]

    enum CodingKeys: String, CodingKey { case format, diagnostics, scope, packages }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        try FormatError.require(format, name: "synod-doc")
        diagnostics = try c.decodeIfPresent([CheckReport.Diagnostic].self, forKey: .diagnostics) ?? []
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope)
        packages = try c.decodeIfPresent([Package].self, forKey: .packages) ?? []
    }

    /// Reads a `synod doc --json` document.
    public static func parse(_ data: Data) throws -> DocReport {
        do {
            return try JSONDecoder().decode(DocReport.self, from: data)
        } catch let e as FormatError {
            throw e
        } catch let e as DecodingError {
            throw FormatError.malformed("doc report: \(e.localizedDescription)")
        }
    }

    /// With `--scope`, the file's own package: the first one listed. Nil for a plain listing.
    public var ownPackage: Package? { scope == nil ? nil : packages.first }

    /// With `--scope`, the imported packages, in import order.
    public var importedPackages: [Package] { scope == nil ? [] : Array(packages.dropFirst()) }
}
