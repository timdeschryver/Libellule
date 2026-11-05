#if os(macOS)
import SwiftUI
import Vision

struct RecognizedWord: Identifiable, Equatable {
    var id = UUID()
    var text: String
    /// In picture points, with a top-left origin.
    var rect: CGRect
    var line: Int
}

enum TextMarkup {
    static func words(in image: CGImage, size: CGSize) async throws -> [RecognizedWord] {
        // Vision supplies character-range boxes, so highlights don't approximate words by character count.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image)
        try await Task.detached {
            try handler.perform([request])
        }.value
        let observations = (request.results ?? []).sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.012 { return $0.boundingBox.midY > $1.boundingBox.midY }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        var words: [RecognizedWord] = []
        for (line, observation) in observations.enumerated() {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            string.enumerateSubstrings(in: string.startIndex..<string.endIndex, options: .byWords) { substring, range, _, _ in
                guard let substring, let box = try? candidate.boundingBox(for: range)?.boundingBox else { return }
                let rect = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
                words.append(RecognizedWord(text: substring, rect: rect, line: line))
            }
        }
        return words
    }

    enum Action { case highlight, underline, redact, redactMatches }

    static func apply(_ action: Action, words: [RecognizedWord], selected: Set<UUID>, layer: AnnotationLayer) {
        let chosen = words.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let targets: [RecognizedWord]
        if action == .redactMatches {
            let strings = Set(chosen.map { $0.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })
            targets = words.filter { strings.contains($0.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) }
        } else { targets = chosen }
        if action == .redact || action == .redactMatches {
            layer.addRedactions(targets.map { $0.rect.insetBy(dx: -2, dy: -2) }, style: .blackout)
            return
        }
        // Adjacent selected words in the same line form one continuous highlight or underline.
        let ordered = targets.sorted { $0.line == $1.line ? $0.rect.minX < $1.rect.minX : $0.line < $1.line }
        var runs: [(line: Int, rect: CGRect)] = []
        for word in ordered {
            if let last = runs.last, last.line == word.line, word.rect.minX - last.rect.maxX <= max(8, word.rect.height) {
                runs[runs.count - 1].rect = last.rect.union(word.rect)
            } else { runs.append((word.line, word.rect)) }
        }
        let annotations = runs.map { run -> Annotation in
            let rect = run.rect
            if action == .underline {
                return Annotation(shape: .line(from: CGPoint(x: rect.minX, y: rect.maxY + 2), to: CGPoint(x: rect.maxX, y: rect.maxY + 2)), color: layer.toolbox.resolvedColor, lineWidth: 2)
            }
            let width = max(1, (rect.height - 6) / 3)
            return Annotation(shape: .highlight([CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)]), color: layer.toolbox.resolvedColor, lineWidth: width)
        }
        layer.apply(layer.annotations + annotations, actionName: action == .underline ? "Underline Text" : "Highlight Text")
    }
}

struct TextMarkupView: View {
    let image: CGImage
    let words: [RecognizedWord]
    let pointSize: CGSize
    let apply: (TextMarkup.Action, Set<UUID>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var query = ""
    @State private var anchor: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Annotate Recognized Text").font(.title2.bold())
            Text("Click words in the preview. Shift-click selects a range; Command-click adds or removes a word.")
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                let fit = min(proxy.size.width / CGFloat(image.width), proxy.size.height / CGFloat(image.height))
                let width = CGFloat(image.width) * fit
                let height = CGFloat(image.height) * fit
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1).resizable()
                    ForEach(Array(words.enumerated()), id: \.element.id) { index, word in
                        let box = CGRect(x: word.rect.minX / pointSize.width, y: word.rect.minY / pointSize.height, width: word.rect.width / pointSize.width, height: word.rect.height / pointSize.height)
                        Button { select(index) } label: {
                            Rectangle().fill(selected.contains(word.id) ? Color.accentColor.opacity(0.3) : Color.clear)
                                .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .frame(width: box.width * width, height: box.height * height)
                        .offset(x: box.minX * width, y: box.minY * height)
                        .help(word.text)
                        .accessibilityLabel(word.text)
                        .accessibilityAddTraits(selected.contains(word.id) ? .isSelected : [])
                    }
                }
                .frame(width: width, height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                TextField("Find text", text: $query)
                Button("Select Matches") {
                    selected = Set(words.filter { $0.text.localizedStandardContains(query) }.map(\.id))
                }.disabled(query.isEmpty)
                Button("Select All") { selected = Set(words.map(\.id)) }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                actionButton("Highlight", action: .highlight)
                actionButton("Underline", action: .underline)
                actionButton("Redact", action: .redact)
                actionButton("Redact All Matches", action: .redactMatches)
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 620)
    }

    private func select(_ index: Int) {
        if NSEvent.modifierFlags.contains(.shift), let anchor {
            selected.formUnion(words[min(anchor, index)...max(anchor, index)].map(\.id))
        } else if NSEvent.modifierFlags.contains(.command) {
            if !selected.insert(words[index].id).inserted { selected.remove(words[index].id) }
        } else { selected = [words[index].id] }
        anchor = index
    }

    private func actionButton(_ title: LocalizedStringKey, action: TextMarkup.Action) -> some View {
        Button(title) { apply(action, selected); dismiss() }.disabled(selected.isEmpty)
    }
}
#endif
