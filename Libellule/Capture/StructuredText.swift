#if os(macOS)
import AppKit
import SwiftUI
import Vision

struct StructuredTextResult {
    var blocks: [String]
    var tables: [[[String]]]
}

enum TableTextFormat: String, CaseIterable, Identifiable {
    case text, csv, markdown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: String(localized: "Text Blocks")
        case .csv: "CSV"
        case .markdown: "Markdown"
        }
    }
}

enum StructuredTextRecognizer {
    static func recognize(_ image: CGImage) async throws -> StructuredTextResult {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        let observations = try await request.perform(on: image)
        var blocks: [String] = []
        var tables: [[[String]]] = []
        for observation in observations {
            let document = observation.document
            let paragraphs = document.paragraphs.map(\.transcript).filter { !$0.isEmpty }
            blocks += paragraphs.isEmpty ? [document.text.transcript].filter { !$0.isEmpty } : paragraphs
            for table in document.tables {
                let rows = (0..<table.rows.count).map { row in
                    (0..<table.columns.count).map { column -> String in
                        guard let cell = table.cell(row: row, col: column),
                              cell.rowRange.lowerBound == row, cell.columnRange.lowerBound == column else { return "" }
                        return cell.content.text.transcript
                    }
                }
                if !rows.isEmpty { tables.append(rows) }
            }
        }
        return StructuredTextResult(blocks: blocks, tables: tables)
    }

    static func csv(_ rows: [[String]]) -> String {
        normalized(rows).map { row in
            row.map { cell in
                if cell.contains(where: { ",\"\r\n".contains($0) }) { return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                return cell
            }.joined(separator: ",")
        }.joined(separator: "\r\n")
    }

    static func markdown(_ rows: [[String]]) -> String {
        let rows = normalized(rows)
        guard let first = rows.first, !first.isEmpty else { return "" }
        func line(_ cells: [String]) -> String {
            "| " + cells.map {
                $0.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\r\n", with: "<br>")
                    .replacingOccurrences(of: "\r", with: "<br>")
                    .replacingOccurrences(of: "\n", with: "<br>")
            }.joined(separator: " | ") + " |"
        }
        return ([line(first), line(Array(repeating: "---", count: first.count))] + rows.dropFirst().map(line)).joined(separator: "\n")
    }

    private static func normalized(_ rows: [[String]]) -> [[String]] {
        let columns = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
    }
}

struct StructuredTextView: View {
    let image: CGImage
    @State private var result: StructuredTextResult?
    @State private var selectedBlocks: Set<Int> = []
    @State private var format = TableTextFormat.text
    @State private var tableIndex = 0
    @State private var errorMessage: String?
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    init(image: CGImage, result: StructuredTextResult? = nil) {
        self.image = image
        _result = State(initialValue: result)
        _selectedBlocks = State(initialValue: Set(result?.blocks.indices ?? 0..<0))
    }

    private var output: String {
        guard let result else { return "" }
        if format == .text {
            return result.blocks.enumerated().filter { selectedBlocks.contains($0.offset) }.map(\.element).joined(separator: "\n\n")
        }
        guard result.tables.indices.contains(tableIndex) else { return "" }
        return format == .csv ? StructuredTextRecognizer.csv(result.tables[tableIndex]) : StructuredTextRecognizer.markdown(result.tables[tableIndex])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extract Text and Tables").font(.title2.bold())
            Picker("Format", selection: $format) {
                ForEach(TableTextFormat.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            if let result {
                if format == .text {
                    HStack {
                        Button("Select All") { selectedBlocks = Set(result.blocks.indices) }
                        Button("Select None") { selectedBlocks.removeAll() }
                    }
                    List(Array(result.blocks.enumerated()), id: \.offset) { index, block in
                        Toggle(isOn: Binding(get: { selectedBlocks.contains(index) }, set: { enabled in
                            if enabled { selectedBlocks.insert(index) } else { selectedBlocks.remove(index) }
                        })) {
                            Text(block).textSelection(.enabled)
                        }
                    }
                    if result.blocks.isEmpty { Text("No text was found.").foregroundStyle(.secondary) }
                } else if result.tables.isEmpty {
                    ContentUnavailableView("No Tables Found", systemImage: "tablecells", description: Text("Try a tighter capture around the table, or copy the text blocks."))
                } else {
                    Picker("Table", selection: $tableIndex) {
                        ForEach(result.tables.indices, id: \.self) { Text("Table \($0 + 1)").tag($0) }
                    }
                    ScrollView([.horizontal, .vertical]) {
                        Text(output).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding()
                    }.background(.quinary)
                    Text("CSV preserves cells, commas, quotes, and line breaks. Markdown uses the first row as its header.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let message = errorMessage { Text(message).foregroundStyle(.red) }
            else { ProgressView("Recognizing document structure…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            Spacer(minLength: 0)
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                    copied = true
                }.disabled(output.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 740, height: 560)
        .onChange(of: output) { _, _ in copied = false }
        .task {
            guard result == nil else { return }
            do {
                let recognized = try await StructuredTextRecognizer.recognize(image)
                result = recognized
                selectedBlocks = Set(recognized.blocks.indices)
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
#endif
