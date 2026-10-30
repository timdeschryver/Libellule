#if os(macOS)
import SwiftUI

struct RedactionReview: Identifiable {
    let id = UUID()
    let image: CGImage
    let preview: CGImage
    let findings: [Redactor.Finding]
}

struct RedactionReviewView: View {
    let review: RedactionReview
    let apply: ([Redactor.Finding]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int>

    init(review: RedactionReview, apply: @escaping ([Redactor.Finding]) -> Void) {
        self.review = review
        self.apply = apply
        _selected = State(initialValue: Set(review.findings.indices))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Redactions").font(.title2.bold())
            Text("Select the areas to hide. Uncheck a finding to leave it visible.")
                .foregroundStyle(.secondary)
            HStack {
                GeometryReader { proxy in
                    let fit = min(proxy.size.width / CGFloat(review.image.width), proxy.size.height / CGFloat(review.image.height))
                    let size = CGSize(width: CGFloat(review.image.width) * fit, height: CGFloat(review.image.height) * fit)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: review.preview, scale: 1).resizable()
                        ForEach(Array(review.findings.enumerated()), id: \.offset) { index, finding in
                            Rectangle().fill(selected.contains(index) ? Color.red.opacity(0.3) : Color.clear)
                                .border(selected.contains(index) ? Color.red : Color.gray, width: 2)
                                .frame(width: finding.box.width * size.width, height: finding.box.height * size.height)
                                .offset(x: finding.box.minX * size.width, y: finding.box.minY * size.height)
                                .onTapGesture { toggle(index) }
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                List {
                    ForEach(Array(review.findings.enumerated()), id: \.offset) { index, finding in
                        Toggle("\(index + 1). \(finding.kind.describe(count: 1))", isOn: Binding(get: { selected.contains(index) }, set: { enabled in
                            if enabled { selected.insert(index) } else { selected.remove(index) }
                        }))
                    }
                }.frame(width: 220)
            }
            HStack {
                Button("Select All") { selected = Set(review.findings.indices) }
                Button("Select None") { selected.removeAll() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Hide Selected Areas") {
                    apply(review.findings.enumerated().filter { selected.contains($0.offset) }.map(\.element))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }.padding(20).frame(width: 860, height: 540)
    }

    private func toggle(_ index: Int) {
        if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
    }
}
#endif
