import SwiftUI

/// Live list of steps while the assistant is working.
struct ActivityStepsView: View {
    let steps: [ActivityStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps) { step in
                ActivityStepRow(step: step)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: steps)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

/// Collapsed "Completed N steps in 3m 44s" line on a finished answer;
/// tapping expands the full step list.
struct ActivitySummaryView: View {
    let steps: [ActivityStep]
    let seconds: Double?
    @State private var expanded = false

    private var title: String {
        let count = "Completed \(steps.count) step\(steps.count == 1 ? "" : "s")"
        guard let seconds else { return count }
        return "\(count) in \(Self.duration(seconds))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapse steps" : "Expand steps")

            if expanded {
                ActivityStepsView(steps: steps)
                    .transition(.opacity)
            }
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = max(1, Int(seconds.rounded()))
        return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
    }
}

private struct ActivityStepRow: View {
    let step: ActivityStep

    /// The step's detail; a fetched web address is a link that opens in the default browser.
    private var detailText: Text {
        guard !step.detail.isEmpty else { return Text("") }
        var detail = AttributedString(step.detail)
        if step.verb == "Fetched", let url = URL(string: step.detail), url.isOpenableFromChat {
            detail.link = url
            detail.underlineStyle = .single
        }
        return Text(" \(Text(detail))")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if step.isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: step.symbol)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 18)

            Text("\(Text(step.verb).foregroundStyle(.primary))\(detailText.foregroundStyle(.secondary))")
                .font(.subheadline)
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }
}
