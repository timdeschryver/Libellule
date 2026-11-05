#if os(macOS)
import SwiftUI

struct AnnotationStylesView: View {
    let layer: AnnotationLayer
    @Bindable var store: AnnotationStyleStore = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var stamp = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Annotation Styles and Stamps").font(.title2.bold())
            Text("Save the selected annotation's style, or the current tool settings. Apply a style to selected annotations or use it for new drawings.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Style name", text: $name)
                Button("Save Style") { store.save(name: name, layer: layer); name = "" }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List {
                ForEach(store.presets) { preset in
                    HStack {
                        Image(systemName: "paintbrush.pointed.fill").foregroundStyle(Color(preset.sample.color))
                        Text(preset.name)
                        Spacer()
                        Button("Apply") { layer.applyStyle(preset); dismiss() }
                        Button(role: .destructive) { store.presets.removeAll { $0.id == preset.id } } label: { Image(systemName: "trash") }
                            .help("Delete style")
                    }
                }
            }.overlay { if store.presets.isEmpty { ContentUnavailableView("No Saved Styles", systemImage: "paintbrush.pointed", description: Text("Save your first style above.")) } }
            Text("Quick Stamps").font(.headline)
            HStack {
                ForEach(["Expected", "Actual", "Click here", "Fixed", "Needs review"], id: \.self) { text in
                    Button(text) { layer.insertStamp(text); dismiss() }
                }
            }
            HStack {
                TextField("Custom stamp text", text: $stamp)
                Button("Save Stamp") {
                    let text = stamp.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !store.stamps.contains(text) { store.stamps.append(text) }
                    stamp = ""
                }.disabled(stamp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Insert Stamp") { layer.insertStamp(stamp); dismiss() }
                    .disabled(stamp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !store.stamps.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(store.stamps, id: \.self) { text in
                            HStack {
                                Button(text) { layer.insertStamp(text); dismiss() }
                                Button { store.stamps.removeAll { $0 == text } } label: { Image(systemName: "xmark.circle") }
                                    .help("Delete stamp")
                            }
                        }
                    }
                }.frame(height: 30)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 660, height: 520)
    }
}

struct RemoveSectionView: View {
    let image: CGImage
    let pointSize: CGSize
    let apply: (CGFloat, CGFloat, AnnotationDocument.CutAxis) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var axis = AnnotationDocument.CutAxis.horizontal
    @State private var start = 0.35
    @State private var end = 0.65
    private var length: CGFloat { axis == .horizontal ? pointSize.height : pointSize.width }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove a Middle Section").font(.title2.bold())
            Text("Remove the marked rows or columns and close the gap. A dashed seam marks the omission. Existing markup becomes part of the image; Undo restores it.")
                .foregroundStyle(.secondary)
            Picker("Remove", selection: $axis) {
                ForEach(AnnotationDocument.CutAxis.allCases) { axis in Text(axis.title).tag(axis) }
            }.pickerStyle(.segmented)
            GeometryReader { proxy in
                let fit = min(proxy.size.width / pointSize.width, proxy.size.height / pointSize.height)
                let size = CGSize(width: pointSize.width * fit, height: pointSize.height * fit)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1).resizable()
                    Rectangle().fill(.red.opacity(0.35))
                        .frame(width: axis == .horizontal ? size.width : size.width * abs(end - start),
                               height: axis == .horizontal ? size.height * abs(end - start) : size.height)
                        .offset(x: axis == .horizontal ? 0 : size.width * min(start, end),
                                y: axis == .horizontal ? size.height * min(start, end) : 0)
                }.frame(width: size.width, height: size.height).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text("Start").frame(width: 40, alignment: .leading)
                Slider(value: $start, in: 0.01...0.99)
                TextField("Start", value: Binding(get: { start * length }, set: { start = min(0.99, max(0.01, $0 / length)) }), format: .number.precision(.fractionLength(0...1)))
                    .multilineTextAlignment(.trailing).frame(width: 70)
                Text("pt")
            }
            HStack {
                Text("End").frame(width: 40, alignment: .leading)
                Slider(value: $end, in: 0.01...0.99)
                TextField("End", value: Binding(get: { end * length }, set: { end = min(0.99, max(0.01, $0 / length)) }), format: .number.precision(.fractionLength(0...1)))
                    .multilineTextAlignment(.trailing).frame(width: 70)
                Text("pt")
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Remove Section") { apply(start * length, end * length, axis); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(abs(start - end) * length < 1)
            }
        }.padding(20).frame(width: 780, height: 600)
    }
}

struct TextMarkupSession: Identifiable {
    let id = UUID()
    let baseImage: CGImage
    let preview: CGImage
    let pointSize: CGSize
    let annotations: [Annotation]
    let words: [RecognizedWord]
}
#endif
