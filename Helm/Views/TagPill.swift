//
//  TagPill.swift
//  Helm
//
//  v7 tags: the shared pill used to render a shift-type tag in agenda rows, the
//  library, search results and the editor, plus a horizontal filter bar of
//  toggleable tags for search/filtering.
//

import SwiftUI

/// One tag rendered as a coloured capsule.
struct TagPill: View {
    let text: String
    var colorHex: String?
    var compact: Bool = false

    var body: some View {
        let color = Color(hex: colorHex) ?? .secondary
        Text(text)
            // Relative font (not a fixed 9pt) so tags scale with Dynamic Type.
            .font(.caption2.weight(compact ? .semibold : .medium))
            .lineLimit(1)
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 1 : 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
    }
}

/// A wrapping row of tag pills (no horizontal scrolling — wraps to lines).
struct TagPillRow: View {
    let tags: [String]
    var colorFor: (String) -> String?

    var body: some View {
        WrappingHStack(tags, spacing: 4, lineSpacing: 4) { tag in
            TagPill(text: tag, colorHex: colorFor(tag), compact: true)
        }
    }
}

/// A horizontal bar of toggleable tag chips for filtering. Empty `selected`
/// means "no filter" (everything shown); a chip dims when filtered out.
struct TagFilterBar: View {
    let tags: [String]
    @Binding var selected: Set<String>
    var colorFor: (String) -> String?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Button {
                        if selected.contains(tag) { selected.remove(tag) } else { selected.insert(tag) }
                    } label: {
                        TagPill(text: tag, colorHex: colorFor(tag))
                            .opacity(selected.isEmpty || selected.contains(tag) ? 1 : 0.35)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }
}

/// A minimal flow layout that wraps its subviews onto multiple lines (SwiftUI's
/// Layout protocol). Used for tag pill stacks that may exceed one line.
struct WrappingHStack<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4
    @ViewBuilder var content: (Data.Element) -> Content

    init(_ data: Data, spacing: CGFloat = 4, lineSpacing: CGFloat = 4, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: spacing, lineSpacing: lineSpacing) {
            ForEach(Array(data), id: \.self) { content($0) }
        }
    }
}

/// Greedy left-to-right flow layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxLineWidth: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                maxLineWidth = max(maxLineWidth, x - spacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        maxLineWidth = max(maxLineWidth, x - spacing)
        return CGSize(width: min(maxWidth, max(0, maxLineWidth)), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            sub.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
