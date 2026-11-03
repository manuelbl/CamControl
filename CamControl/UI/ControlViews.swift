//
//  ControlViews.swift
//  The three grouped control sections (Exposure & Color · Image · Framing) and their rows.
//  Hosted inside a `.formStyle(.grouped)` Form (see ContentView), which supplies the native
//  System Settings card/window colors, row dividers, insets and header alignment. Only the
//  controls the camera *supports* are rendered; unsupported ones are omitted and a section
//  with no rows is dropped entirely. The one surviving "disabled but visible" widget is an
//  auto pair's slider (exposure time, WB temperature) while its Auto is on. Widget edits update the UI
//  optimistically and are written through to the camera by `AppModel.setValue`.
//

import SwiftUI

private let labelWidth: CGFloat = 116
private let readoutWidth: CGFloat = 64   // fits "1/10000 s"

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
                    Slider(value: sliderBinding(model, id), in: bounds)
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

/// An auto pair (Exposure, White Balance): an optional Auto checkbox over the manual
/// slider. Rendered only when the manual control is supported; the Auto checkbox appears
/// only when that control is *also* supported. Auto on → slider disabled but still
/// visible, frozen at its last-read value — the sole survivor of "disabled but visible"
/// under the hide-unsupported rule.
private struct AutoPairRow: View {
    let model: AppModel
    let pair: AutoPair

    var body: some View {
        let auto = model.state(pair.autoID)
        let manual = model.state(pair.manualID)
        let autoSupported = auto?.supported ?? false
        let autoOn = autoSupported && (auto?.isToggledOn ?? false)

        HStack(spacing: 12) {
            Text(pair.label).frame(width: labelWidth, alignment: .leading)
            if autoSupported {
                Toggle("Auto", isOn: autoBinding)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            Group {
                if let bounds = manual?.sliderBounds {
                    Slider(value: sliderBinding(model, pair.manualID), in: bounds)
                } else {
                    Slider(value: .constant(0), in: 0...1).disabled(true)
                }
            }
            .disabled(autoOn)
            Text(manual?.displayText ?? "—")
                .frame(width: readoutWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var autoBinding: Binding<Bool> {
        Binding(
            get: { model.state(pair.autoID)?.isToggledOn ?? false },
            set: { on in
                guard let r = model.state(pair.autoID)?.range else { return }
                model.setValue(on ? r.maximum : r.minimum, for: pair.autoID)
            })
    }
}

/// Binds a slider to a control: positions map to native values via `ControlUIState`
/// (linear, or logarithmic for exposure time), snapped to the control's resolution.
@MainActor
private func sliderBinding(_ model: AppModel, _ id: ControlID) -> Binding<Double> {
    Binding(
        get: { model.state(id)?.sliderPosition ?? 0 },
        set: { position in
            guard let s = model.state(id) else { return }
            model.setValue(s.value(atSliderPosition: position), for: id)
        })
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

    /// A section for one group, or nothing when the group has no rendered rows.
    @ViewBuilder
    private func section(_ group: ControlGroup) -> some View {
        let rows = model.renderableRows(in: group)
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row($0) }
            } header: {
                Text(group.title)
            }
        }
    }

    @ViewBuilder
    private func row(_ row: ControlRow) -> some View {
        switch row {
        case .autoPair(let pair):
            AutoPairRow(model: model, pair: pair)
        case .single(let id):
            switch model.state(id)?.descriptor.kind {
            case .slider:    SliderControlRow(model: model, id: id)
            case .toggle:    ToggleControlRow(model: model, id: id)
            case .segmented: SegmentedControlRow(model: model, id: id)
            case .none:      EmptyView()
            }
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
