import Playback
import SwiftUI

// MARK: - ActiveRouteChip

/// Small pill that surfaces the current audio route in the now-playing strip.
///
/// Tap to reveal a popover that explains how to change route — the actual
/// picker is `AirPlayButton`, but users may not notice it, so the chip
/// nudges them toward the system picker as well.
public struct ActiveRouteChip: View {
    @ObservedObject var vm: RouteViewModel
    @State private var showPopover = false

    public init(vm: RouteViewModel) {
        self.vm = vm
    }

    public var body: some View {
        Button {
            self.showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: self.vm.current.iconSystemName)
                    .font(.system(size: 12, weight: .semibold))
                Text(self.vm.current.displayName)
                    .font(Typography.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.gray.opacity(0.15))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.gray.opacity(0.25), lineWidth: 0.5)
            )
            .foregroundStyle(Color.textPrimary)
        }
        .buttonStyle(.plain)
        .help(self.helpText)
        .accessibilityLabel("Current output: \(self.vm.current.displayName)")
        .popover(isPresented: self.$showPopover, arrowEdge: .top) {
            self.popoverContent
                .padding(14)
                .frame(width: 260)
        }
    }

    private var helpText: String {
        if let subtitle = vm.current.subtitle {
            "\(self.vm.current.displayName) (\(subtitle))"
        } else {
            self.vm.current.displayName
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: self.vm.current.iconSystemName)
                Text(self.vm.current.displayName)
                    .font(.headline)
            }
            if let subtitle = vm.current.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("To change output, click the AirPlay button next to this chip, or use the AirPlay menu in Control Centre.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
