import AppKit
import GrokGaugeCore
import SwiftUI

// MARK: - Grouped rows in the System Settings style

struct PrefGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            if let footer {
                Text(.init(footer))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

struct PrefRow<Trailing: View>: View {
    let label: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Drag-to-reorder list with show/hide checkboxes

struct ReorderList<ID: Hashable & Codable & Sendable & CaseIterable & RawRepresentable>: View where ID.RawValue == String {
    @Binding var items: [OrderedToggle<ID>]
    let title: (ID) -> String
    let icon: (ID) -> AnyView
    var note: (ID) -> String? = { _ in nil }
    @ViewState var targeted: ID? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(index: index, item: item)
                if index < items.count - 1 { Divider() }
            }
        }
    }

    private func row(index: Int, item: OrderedToggle<ID>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
                .accessibilityHidden(true)
            Toggle(isOn: Binding(get: { items[safe: index]?.visible ?? false },
                                 set: { v in if items.indices.contains(index) { items[index].visible = v } })) {
                HStack(spacing: 6) {
                    icon(item.id).frame(width: 18)
                    Text(title(item.id))
                    if let n = note(item.id) {
                        Text(n).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            HStack(spacing: 2) {
                Button { move(item.id, to: index - 1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .accessibilityLabel("Move \(title(item.id)) up")
                Button { move(item.id, to: index + 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == items.count - 1)
                    .accessibilityLabel("Move \(title(item.id)) down")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(targeted == item.id ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .draggable(item.id.rawValue) {
            Text(title(item.id))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
        }
        .dropDestination(for: String.self) { dropped, _ in
            guard let raw = dropped.first, let id = ID(rawValue: raw) else { return false }
            move(id, to: index)
            return true
        } isTargeted: { on in
            if on { targeted = item.id } else if targeted == item.id { targeted = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move up") { move(item.id, to: index - 1) }
        .accessibilityAction(named: "Move down") { move(item.id, to: index + 1) }
    }

    private func move(_ id: ID, to target: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(target, 0), items.count - 1)
        guard from != to else { return }
        var copy = items
        let item = copy.remove(at: from)
        copy.insert(item, at: to)
        if reduceMotion { items = copy } else { withAnimation(.easeInOut(duration: 0.18)) { items = copy } }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Two-handle range slider for the level boundaries

struct RangeSlider: View {
    @Binding var value: LevelThresholds
    let colors: (normal: Color, warning: Color, critical: Color)
    private let knob: CGFloat = 20
    private let track: CGFloat = 8

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let usable = max(1, geo.size.width - knob)
                let x: (Int) -> CGFloat = { v in knob / 2 + usable * CGFloat(v) / 100 }
                let toValue: (CGFloat) -> Int = { px in Int(((px - knob / 2) / usable * 100).rounded()) }
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        Rectangle().fill(colors.normal).frame(width: max(0, x(value.warningAbove) - knob / 2))
                        Rectangle().fill(colors.warning).frame(width: max(0, x(value.criticalAbove) - x(value.warningAbove)))
                        Rectangle().fill(colors.critical)
                    }
                    .frame(width: usable, height: track)
                    .clipShape(Capsule())
                    .offset(x: knob / 2, y: (knob - track) / 2 + 2)
                    .accessibilityHidden(true)

                    handle(value.warningAbove, label: "Warning starts above", color: colors.warning,
                           x: x(value.warningAbove)) { value.setWarning(toValue($0)) } adjust: { d in
                        value.setWarning(value.warningAbove + d)
                    }
                    handle(value.criticalAbove, label: "Critical starts above", color: colors.critical,
                           x: x(value.criticalAbove)) { value.setCritical(toValue($0)) } adjust: { d in
                        value.setCritical(value.criticalAbove + d)
                    }
                }
                .coordinateSpace(name: "range")
            }
            .frame(height: knob + 4)
            HStack {
                Text("0%")
                Spacer()
                Text("100%")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
    }

    private func handle(_ v: Int, label: String, color: Color, x: CGFloat,
                        drag: @escaping (CGFloat) -> Void, adjust: @escaping (Int) -> Void) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(color, lineWidth: 3))
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
            .frame(width: knob, height: knob)
            .contentShape(Circle().inset(by: -6))
            .position(x: x, y: knob / 2 + 2)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("range"))
                .onChanged { g in drag(g.location.x) })
            .help("\(label) \(v)%")
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(v) percent")
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: adjust(1)
                case .decrement: adjust(-1)
                @unknown default: break
                }
            }
    }
}

/// "Warning above [80] %   Critical above [90] %" with steppers.
struct ThresholdFields: View {
    @Binding var value: LevelThresholds

    var body: some View {
        HStack(spacing: 16) {
            field("Warning above", value.warningAbove) { value.setWarning($0) }
            field("Critical above", value.criticalAbove) { value.setCritical($0) }
            Spacer()
        }
    }

    private func field(_ label: String, _ v: Int, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, value: Binding(get: { v }, set: set), format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .labelsHidden()
            Text("%").foregroundStyle(.secondary)
            Stepper(label, value: Binding(get: { v }, set: set), in: 1...99)
                .labelsHidden()
        }
        .font(.callout)
    }
}

// MARK: - Shortcut recorder

struct HotKeyRecorder: View {
    @Binding var hotKey: HotKey
    var onRecording: (Bool) -> Void = { _ in }
    @ViewState var recording = false
    @ViewState var monitor: Any? = nil

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type a shortcut…" : hotKey.display)
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 120)
        }
        .controlSize(.large)
        .help(recording ? "Press a key with ⌃, ⌥ or ⌘. Esc cancels." : "Click to record a new shortcut")
        .accessibilityLabel("Keyboard shortcut")
        .accessibilityValue(recording ? "recording" : hotKey.display)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        onRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }   // Esc
            let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = HotKey(enabled: true, keyCode: UInt32(e.keyCode), control: f.contains(.control),
                             option: f.contains(.option), command: f.contains(.command), shift: f.contains(.shift))
            if key.isValid {
                hotKey = key
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            onRecording(false)
        }
    }
}

// MARK: - Menu bar preview

struct MenuBarPreview: View {
    let segments: [MenuBarSegment]
    let showLogo: Bool
    let logoColor: Color?
    let palette: Palette

    var body: some View {
        HStack(spacing: 0) {
            if showLogo {
                GrokMarkView(size: 15)
                    .foregroundStyle(logoColor ?? Color.white.opacity(0.92))
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                Text(seg.text)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(seg.level.map { palette.color($0) } ?? Color.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Menu bar preview")
        .accessibilityValue(segments.map(\.text).joined().trimmingCharacters(in: .whitespaces))
    }
}
