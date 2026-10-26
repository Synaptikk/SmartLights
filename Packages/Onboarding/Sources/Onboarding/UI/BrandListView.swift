#if canImport(SwiftUI)
import SwiftUI

/// The "Add brand" list: setup guides first, then every brand/pointer guide grouped by phase,
/// each with a phase badge (and a "Verify wording" badge in debug builds).
public struct BrandListView: View {
    private let catalog: GuideCatalog
    private let onSelect: @MainActor (BrandGuide) -> Void

    public init(catalog: GuideCatalog = .standard, onSelect: @escaping @MainActor (BrandGuide) -> Void) {
        self.catalog = catalog
        self.onSelect = onSelect
    }

    public var body: some View {
        List {
            Section {
                ForEach(catalog.setupGuides) { row($0) }
            } header: {
                Text("Before you start")
            }
            ForEach(catalog.addBrandListByPhase) { group in
                Section {
                    ForEach(group.guides) { row($0) }
                } header: {
                    Text(Self.sectionTitle(for: group.phase))
                }
            }
        }
        .navigationTitle("Add brand")
    }

    private func row(_ guide: BrandGuide) -> some View {
        Button {
            onSelect(guide)
        } label: {
            BrandRow(guide: guide)
        }
        .tint(Color.primary)
    }

    static func sectionTitle(for phase: Int) -> String {
        switch phase {
        case 1: "Available now"
        case 2: "Coming next"
        default: "Later"
        }
    }
}

struct BrandRow: View {
    let guide: BrandGuide

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(guide.title).font(.headline)
                    if guide.needsVerification { VerificationBadge() }
                }
                Text(guide.summary.plainText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            PhaseBadge(guide: guide)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
#endif
