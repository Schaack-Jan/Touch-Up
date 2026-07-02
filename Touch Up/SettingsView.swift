//
//  SettingsView.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 03.02.23.
//

import SwiftUI
import TouchUpCore

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
            
            let id_: Binding<UInt> = Binding {return (model.connectedTouchscreen?.id) ?? 0}
            set: { value in
                model.connectedTouchscreen = model.connectedScreens.first(where:{$0.id == value})
                model.rememeberCues()
            }

            Picker(model.uiLabels(for: \.connectedTouchscreen).title, selection: id_) {
                ForEach(model.connectedScreens) {
                    Text($0.name).tag($0.id)
                }
            }
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
