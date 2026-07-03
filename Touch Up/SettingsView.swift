//
//  SettingsView.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 03.02.23.
//

import SwiftUI
import TouchUpCore

private let calibrationNumberFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 6
    formatter.usesGroupingSeparator = false
    return formatter
}()

struct SettingsView: View {
    
    @ObservedObject var model: TouchUp
    
    var welcomeBanner: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Touch Up 🐑")
                    .font(.largeTitle)
                Text("Touch Up converts USB HID data from any Windows certified touchscreen to mouse events.\nReading touch reports requires macOS Input Monitoring access, and injecting mouse events requires Accessibility access. Touch Up filters for USB touchscreens and does not listen to keyboard input.")
            }
            
            HStack {
                Spacer()
                Button {
                    model.grantRequiredAccess()
                } label: {
                    
                    Text("Grant Required Access")
                }
                .buttonStyle(BorderedProminentButtonStyle())
            }
        }
    }

    var inputMonitoringBanner: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("Input Monitoring Required")
                    .font(.title2)
                Text("macOS groups low-level HID report access under Input Monitoring. Touch Up uses it only for USB touch/digitizer reports and does not install a keyboard event tap.")
            }

            HStack {
                Spacer()
                Button {
                    model.grantHIDListenEventAccess()
                } label: {
                    Text("Grant Input Monitoring Access")
                }
                .buttonStyle(BorderedProminentButtonStyle())
            }
        }
    }
    
    var top: some View {
        Group {
            Toggle(model.uiLabels(for: \.isPublishingMouseEventsEnabled).title, isOn: $model.isPublishingMouseEventsEnabled)
        }
    }
    
    
    var gestureSettings: some View {
        Group {
            Toggle(isOn: $model.isWindowTitleBarDragEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isWindowTitleBarDragEnabled))
            }
            
            Toggle(isOn: $model.isSecondaryClickEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isSecondaryClickEnabled))
            }
            
            Toggle(isOn: $model.isTwoFingerScrollEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isTwoFingerScrollEnabled))
            }
            
        }
    }
    
    
    var parameterSettings: some View {
        Group {
            Slider(value: $model.holdDuration, in: 0.3...1.2, step: 0.05){
                SettingsExplanationLabel(labels: model.uiLabels(for: \.holdDuration))
            }
            
            Slider(value: $model.doubleClickDistance, in: 0...8, step: 1) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.doubleClickDistance))
            }
        }
    }

    var calibrationSettings: some View {
        Group {
            if model.connectedScreens.isEmpty {
                Text("No connected monitors")
                    .foregroundColor(.secondary)
            } else {
                ForEach(model.connectedScreens) { screen in
                    MonitorCalibrationView(model: model, screen: screen)
                }
            }
        }
    }

    var mappingSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                (NSApp.delegate as? AppDelegate)?.showTouchMappingOverlay()
            } label: {
                Label("Map Touchscreens", systemImage: "hand.point.up.left")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.connectedScreens.isEmpty || model.isMappingTouchscreens)

            Text("Touch Up will show each external monitor fullscreen. Touch the shown monitor once to bind that touch device to it.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    
    var troubleshootingSettings: some View {
        Group {
            let errorResistance_ = Binding {Double(model.errorResistance)} set: {
                model.errorResistance = NSInteger(Int($0)) }
            
            Slider(value: errorResistance_ , in: 0...10, step: 1) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.errorResistance))
            }
            
            Toggle(isOn: $model.ignoreOriginTouches) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.ignoreOriginTouches))
            }
            
            Button(action: {
                (NSApp.delegate as? AppDelegate)?.showDebugOverlay()
            }, label: {
                HStack {
                    Text("Open Fullscreen Test Environment")
                    Spacer()
                    Image(systemName: "arrow.up.forward.app.fill")
                }
                
            })
            .foregroundColor(.accentColor)
            .buttonStyle(PlainButtonStyle())
            
        }
    }
    
    
    var footer: some View {
        HStack {
            Spacer()
            VStack {
                if let versionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("Touch Up v\(versionString)")
                        .font(.title2)
                }

                Text("Made with 🐑 in Aachen")
                    .font(.footnote)
                
                Link(destination: URL(string: "https://github.com/shueber/Touch-Up")!, label: {
                    Label("GitHub", systemImage: "link")
                        .foregroundColor(.accentColor)
                })
            }
            .padding(.vertical)
            Spacer()
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        
    }
    
    var container: some View {
        if #available(macOS 13.0, *) {
            return Form {
                if model.needsAccessibilityAccessPrompt {
                    Section {
                        welcomeBanner
                    } footer: {
                        Rectangle()
                            .frame(width:0, height:0)
                            .foregroundColor(.clear)
                    }

                }

                if !model.needsAccessibilityAccessPrompt && model.needsHIDListenEventAccessPrompt {
                    Section {
                        inputMonitoringBanner
                    } footer: {
                        Rectangle()
                            .frame(width:0, height:0)
                            .foregroundColor(.clear)
                    }
                }
                
                Section {
                    top
                }

                Section("Gestures") {
                    gestureSettings
                }
                
                Section("Parameters") {
                    parameterSettings
                }

                Section("Mapping") {
                    mappingSettings
                }

                Section("Calibration") {
                    calibrationSettings
                }

                Section {
                    troubleshootingSettings
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    footer
                }



            }
            .formStyle(.grouped)

        } else {
            return List {
                if model.needsAccessibilityAccessPrompt {
                    LegacySection {
                        welcomeBanner
                    }
                }

                if !model.needsAccessibilityAccessPrompt && model.needsHIDListenEventAccessPrompt {
                    LegacySection {
                        inputMonitoringBanner
                    }
                }

                LegacySection {
                    top
                }
                
                LegacySection(title: "Gestures") {
                    gestureSettings
                }
                
                LegacySection(title: "Parameters") {
                    parameterSettings
                }

                LegacySection(title: "Mapping") {
                    mappingSettings
                }

                LegacySection(title: "Calibration") {
                    calibrationSettings
                }
                
                LegacySection(title: "Troubleshooting") {
                    troubleshootingSettings
                }
                
                footer
                
            }
            .toggleStyle(.switch)
            
        }
    }
    
    
    
    var body: some View {
        container
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 350,  maxHeight: .infinity)
        .onAppear {
            model.checkAccessibilityAccessGranted()
            model.checkHIDListenEventAccessGranted()
        }
        
    }
}

struct MonitorCalibrationView: View {
    @ObservedObject var model: TouchUp
    let screen: TUCScreen
    @State private var showsAdvanced = false
    @State private var showsHistory = false

    var body: some View {
        let draft = draftBinding()
        let current = model.calibration(for: screen)
        let history = model.calibrationHistory(for: screen)

        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(screen.calibrationKey)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Toggle("Enable Calibration", isOn: draft.enabled)

                Button("Auto Calibrate") {
                    (NSApp.delegate as? AppDelegate)?.showCalibrationOverlay(for: screen)
                }
                .buttonStyle(.borderedProminent)

                CalibrationNumberField(title: "X Offset (%)", value: scaledBinding(draft.xOffset, by: 100))
                CalibrationNumberField(title: "Y Offset (%)", value: scaledBinding(draft.yOffset, by: 100))
                CalibrationNumberField(title: "X Scale", value: draft.xScale)
                CalibrationNumberField(title: "Y Scale", value: draft.yScale)

                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        CalibrationNumberField(title: "X Skew (%)", value: scaledBinding(draft.xSkew, by: 100))
                        CalibrationNumberField(title: "Y Skew (%)", value: scaledBinding(draft.ySkew, by: 100))
                    }
                    .padding(.top, 4)
                }

                HStack {
                    Button("Apply") {
                        model.applyCalibration(for: screen)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Undo") {
                        model.undoCalibration(for: screen)
                    }
                    .disabled(!model.canUndoCalibration(for: screen))

                    Button("Reset to Default") {
                        model.resetCalibration(for: screen)
                    }

                    Spacer()
                }

                DisclosureGroup("Previous Versions", isExpanded: $showsHistory) {
                    VStack(alignment: .leading, spacing: 8) {
                        if history.isEmpty {
                            Text("No previous versions")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(history) { version in
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                        Text(summary(for: version))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Button("Restore") {
                                        model.restoreCalibrationVersion(version, for: screen)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Text(screen.name)
                Spacer()
                Text(current.enabled ? "Active" : "Default")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func draftBinding() -> Binding<TouchCalibration> {
        Binding {
            model.draftCalibration(for: screen)
        } set: { calibration in
            model.updateCalibrationDraft(calibration, for: screen)
        }
    }

    private func summary(for calibration: TouchCalibration) -> String {
        String(
            format: "offset %.4g%%, %.4g%%  scale %.4g, %.4g  skew %.4g%%, %.4g%%",
            calibration.xOffset * 100,
            calibration.yOffset * 100,
            calibration.xScale,
            calibration.yScale,
            calibration.xSkew * 100,
            calibration.ySkew * 100
        )
    }

    private func scaledBinding(_ binding: Binding<CGFloat>, by scale: CGFloat) -> Binding<CGFloat> {
        Binding {
            binding.wrappedValue * scale
        } set: { value in
            binding.wrappedValue = value / scale
        }
    }
}

struct CalibrationNumberField: View {
    let title: String
    @Binding var value: CGFloat

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: $value, formatter: calibrationNumberFormatter)
                .multilineTextAlignment(.trailing)
                .frame(width: 96)
        }
    }
}

enum TouchMappingAssistantResult {
    case mapped(Int)
    case cancelled
}

struct TouchMappingAssistantView: View {
    @ObservedObject var model: TouchUp
    let screen: TUCScreen
    let stepIndex: Int
    let totalSteps: Int
    let excludedSourceIdentifiers: Set<Int>
    let completion: (TouchMappingAssistantResult) -> Void

    @State private var waitingForLift = true
    @State private var didComplete = false

    private let timer = Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color(white: 0.06)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Text(screen.name)
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                Text("Mapping \(stepIndex) of \(totalSteps)")
                    .font(.title3)
                    .foregroundColor(.secondary)

                ZStack {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 6)
                        .frame(width: 132, height: 132)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                }
                .padding(.vertical, 22)

                Text(waitingForLift ? "Lift all fingers" : "Touch this monitor")
                    .font(.title2)
                    .foregroundColor(.white)

                Button("Cancel") {
                    completion(.cancelled)
                }
                .keyboardShortcut(.cancelAction)
                .padding(.top, 20)
            }
            .foregroundColor(.white)
            .padding(36)
        }
        .onReceive(timer) { _ in
            updateMapping()
        }
        .onChange(of: model.touches.count) { _ in
            updateMapping()
        }
    }

    private func updateMapping() {
        guard !didComplete else {
            return
        }

        let activeTouches = model.touches.filter { $0.isActive() }
        guard !activeTouches.isEmpty else {
            waitingForLift = false
            return
        }

        guard !waitingForLift else {
            return
        }

        guard let touch = activeTouches.first(where: { !excludedSourceIdentifiers.contains($0.sourceIdentifier) }) else {
            return
        }

        didComplete = true
        model.learnTouchAssignment(sourceIdentifier: touch.sourceIdentifier, to: screen)
        NSLog("[TouchUp] HID: manual mapping assigned source=%ld displayID=%lu display='%@'",
              touch.sourceIdentifier,
              screen.id,
              screen.name)
        completion(.mapped(touch.sourceIdentifier))
    }
}


struct LegacySection<Content: View>: View {
    var title: String? = nil
    var content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading) {
            if let title = title {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, 12)
            }
            
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .foregroundColor(.secondary.opacity(0.1))
                    .shadow(radius: 1)
                    
                    
                
                VStack(alignment: .leading, spacing: 16, content: content)
                    .padding(12)
            }
            
        }
        .padding(.bottom)
    }
}


struct SettingsExplanationLabel: View {
    
    let labels: (title:String, description:String)
    
    var body: some View {
        VStack(alignment:.leading, spacing: 4) {
            Text(labels.title)
            Text(labels.description)
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }
}



struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(model: TouchUp())
    }
}
