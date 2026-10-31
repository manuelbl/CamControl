//
//  ControlViews.swift
//  The three grouped control sections (Exposure & Color · Image · Framing) and their rows.
//  Hosted inside a `.formStyle(.grouped)` Form (see ContentView), which supplies the native
//  System Settings card/window colors, row dividers, insets and header alignment. Only the
//  controls the camera *supports* are rendered; unsupported ones are omitted and a section
//  with no rows is dropped entirely. The one surviving "disabled but visible" widget is the
//  White-Balance temperature slider while WB Auto is on. Widget edits update the UI
//  optimistically and are written through to the camera by `AppModel.setValue`.
//

import SwiftUI

private let labelWidth: CGFloat = 116
private let readoutWidth: CGFloat = 52

// MARK: - Rows

private struct SliderControlRow: View {
    let model: AppModel
    let id: ControlID

    var body: some View {
        let s = model.state(id)
        HStack(spacing: 12) {
            Text(s?.descriptor.displayName ?? "")
                .frame(width: labelWidth, alignment: .leading)
            Group {
                if let bounds = s?.sliderBounds {
                    Slider(value: sliderBinding, in: bounds)
                } else {
                    Slider(value: .constant(0), in: 0...1).disabled(true)
                }
            }
            Text(s?.displayText ?? "—")
                .frame(width: readoutWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .disabled(!(s?.supported ?? false))
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(model.state(id)?.value ?? 0) },
            set: { model.setValue(snapped($0, to: model.state(id)?.range), for: id) })
    }
}

private struct ToggleControlRow: View {
    let model: AppModel
    let id: ControlID

    var body: some View {
        let s = model.state(id)
        HStack {
            Text(s?.descriptor.displayName ?? "")
            Spacer()
            Toggle("", isOn: toggleBinding).labelsHidden().toggleStyle(.switch)
                .controlSize(.small)
        }
        .disabled(!(s?.supported ?? false))
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { model.state(id)?.isToggledOn ?? false },
            set: { on in
                guard let r = model.state(id)?.range else { return }
                model.setValue(on ? r.maximum : r.minimum, for: id)
            })
    }
}

private struct SegmentedControlRow: View {
    let model: AppModel
    let id: ControlID

    var body: some View {
        let s = model.state(id)
        HStack {
            Text(s?.descriptor.displayName ?? "")
            Spacer()
            Picker("", selection: segmentBinding) {
                ForEach(s?.flickerSegments ?? [], id: \.value) { seg in
                    Text(seg.label).tag(seg.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .disabled(!(s?.supported ?? false))
    }

    private var segmentBinding: Binding<Int> {
        Binding(
            get: { Int(model.state(id)?.value ?? 0) },
            set: { model.setValue(Int64($0), for: id) })
    }
}

/// White balance: an optional Auto checkbox over the temperature slider. Rendered only
/// when the temperature slider is supported (so `temp` is non-nil here); the Auto checkbox
/// appears only when that control is *also* supported. Auto on → temperature disabled but
/// still visible, showing its greyed current value — the sole survivor of "disabled but
/// visible" under the hide-unsupported rule.
private struct WhiteBalanceRow: View {
    let model: AppModel

    var body: some View {
        let auto = model.state(.whiteBalanceAuto)
        let temp = model.state(.whiteBalanceTemp)
        let autoSupported = auto?.supported ?? false
        let autoOn = autoSupported && (auto?.value ?? 0) != 0

        HStack(spacing: 12) {
            Text("White Balance").frame(width: labelWidth, alignment: .leading)
            if autoSupported {
                Toggle("Auto", isOn: autoBinding)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            Group {
                if let bounds = temp?.sliderBounds {
                    Slider(value: tempBinding, in: bounds)
                } else {
                    Slider(value: .constant(0), in: 0...1).disabled(true)
                }
            }
            .disabled(autoOn)
            Text(temp?.displayText ?? "—")
                .frame(width: readoutWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var autoBinding: Binding<Bool> {
        Binding(
            get: { (model.state(.whiteBalanceAuto)?.value ?? 0) != 0 },
            set: { model.setValue($0 ? 1 : 0, for: .whiteBalanceAuto) })
    }

    private var tempBinding: Binding<Double> {
        Binding(
            get: { Double(model.state(.whiteBalanceTemp)?.value ?? 0) },
            set: { model.setValue(snapped($0, to: model.state(.whiteBalanceTemp)?.range),
                                  for: .whiteBalanceTemp) })
    }
}

// MARK: - Assembled sections

/// The grouped control sections, built from the model's *renderable* rows so only
/// supported controls appear and an empty group is dropped. Must be placed inside a `Form`
/// (grouped style) so each `Section` renders as a native inset card with the system's
/// colors and dividers. The caller renders this only when at least one row exists.
struct ControlSectionsView: View {
    let model: AppModel

    var body: some View {
        section(.exposureColor)
        section(.image)
        section(.framing)
    }

    /// A section for one group, or nothing when the group has no rendered rows. The
    /// White-Balance row (Exposure & Color only) is appended in catalog position.
    @ViewBuilder
    private func section(_ group: ControlGroup) -> some View {
        let ids = model.renderableSimpleControls(in: group)
        let showsWB = group == .exposureColor && model.showsWhiteBalanceRow
        if !ids.isEmpty || showsWB {
            Section {
                ForEach(ids, id: \.self) { row(for: $0) }
                if showsWB { WhiteBalanceRow(model: model) }
            } header: {
                Text(group.title)
            }
        }
    }

    @ViewBuilder
    private func row(for id: ControlID) -> some View {
        switch model.state(id)?.descriptor.kind {
        case .slider:    SliderControlRow(model: model, id: id)
        case .toggle:    ToggleControlRow(model: model, id: id)
        case .segmented: SegmentedControlRow(model: model, id: id)
        case .none:      EmptyView()
        }
    }
}

#if DEBUG
#Preview("Control sections") {
    Form {
        ControlSectionsView(model: .preview())
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 560)
}
#endif
