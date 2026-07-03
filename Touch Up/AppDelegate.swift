//
//  AppDelegate.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 03.02.23.
//

import Cocoa
import SwiftUI
import Combine
import TouchUpCore


@main
class AppDelegate: NSObject, NSApplicationDelegate {

    let model = TouchUp()
    
    
    var statusItem: NSStatusItem!
    @IBOutlet weak var statusMenu: NSMenu!
    @IBOutlet weak var activationMenuItem: NSMenuItem!
    
    var observers = [AnyCancellable]()
    
    
    
    lazy var settingsWindow: SettingsWindow = {
        return SettingsWindow.window(model: self.model)
    }()
    
    lazy var debugOverlay: DebugOverlay = {
        return DebugOverlay.overlay(model: self.model)
    }()

    var calibrationOverlay: CalibrationOverlay?
    var touchMappingOverlay: TouchMappingOverlay?
    var touchMappingScreens = [TUCScreen]()
    var touchMappingIndex = 0
    var touchMappingSourceIdentifiers = Set<Int>()
    var touchMappingPreviousPublishingState = true
    var didScheduleStartupTouchMapping = false
    
    @IBAction func toggleActivationMenu(_ sender: Any) {
        self.model.isPublishingMouseEventsEnabled.toggle()
    }
    
    
    
    //MARK: - Lifecycle
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem.menu = self.statusMenu
        
        self.observers.append(
            self.model.$connectionState
                .receive(on: DispatchQueue.main)
                .sink{status in
                    DispatchQueue.main.async {
                        self.statusItem.button?.image = status.image
                    }
                    
                }
        )
        
        self.observers.append(
            self.model.$isPublishingMouseEventsEnabled
                .receive(on: DispatchQueue.main)
                .sink{
                    self.activationMenuItem.state = $0 ? .on : .off
                }
        )
        
        if model.needsPermissionsPrompt {
            self.showPreferences(nil)
        } else {
            self.model.startTouchManagerIfPermissionsAreGranted()
            self.scheduleStartupTouchMappingIfNeeded()
        }
        
        #if DEBUG
//        self.showPreferences(nil)
//        self.showDebugOverlay()
        #endif
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
        self.model.stopTouchManager()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        self.model.checkAccessibilityAccessGranted()
        self.model.checkHIDListenEventAccessGranted()
        if self.model.startTouchManagerIfPermissionsAreGranted() {
            self.scheduleStartupTouchMappingIfNeeded()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    
    @IBAction func showPreferences(_ sender: Any?) {
        self.model.checkAccessibilityAccessGranted()
        self.model.checkHIDListenEventAccessGranted()
        self.model.startTouchManagerIfPermissionsAreGranted()
        self.settingsWindow.makeVisible()
    }
    
    func showDebugOverlay() {
        let preState = self.model.isPublishingMouseEventsEnabled
        self.model.isPublishingMouseEventsEnabled = false
        DebugOverlay.completion = {[unowned self] in
            self.debugOverlay.close()
            self.model.isPublishingMouseEventsEnabled = preState
        }
        
        self.debugOverlay.makeVisible()
    }

    func showCalibrationOverlay(for screen: TUCScreen) {
        let preState = self.model.isPublishingMouseEventsEnabled
        self.model.isPublishingMouseEventsEnabled = false

        let overlay = CalibrationOverlay.overlay(model: self.model, screen: screen) { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .completed(let calibration):
                self.model.applyGeneratedCalibration(calibration, for: screen)
            case .cancelled:
                break
            }

            self.calibrationOverlay?.close()
            self.calibrationOverlay = nil
            self.model.isPublishingMouseEventsEnabled = preState
            self.settingsWindow.makeVisible()
        }

        self.calibrationOverlay = overlay
        overlay.makeVisible()
    }

    private func scheduleStartupTouchMappingIfNeeded() {
        guard !self.didScheduleStartupTouchMapping,
              !self.model.needsPermissionsPrompt,
              !self.model.isMappingTouchscreens,
              self.model.screensForTouchMapping().count > 1 else {
            return
        }

        self.didScheduleStartupTouchMapping = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self,
                  !self.model.needsPermissionsPrompt,
                  !self.model.isMappingTouchscreens,
                  self.model.screensForTouchMapping().count > 1 else {
                return
            }

            NSLog("[TouchUp] HID: startup manual mapping scheduled")
            self.showTouchMappingOverlay()
        }
    }

    func showTouchMappingOverlay() {
        let screens = self.model.screensForTouchMapping()
        guard !screens.isEmpty else {
            self.settingsWindow.makeVisible()
            return
        }

        self.touchMappingPreviousPublishingState = self.model.isPublishingMouseEventsEnabled
        self.model.isPublishingMouseEventsEnabled = false
        self.model.isMappingTouchscreens = true
        self.model.resetTouchAssignments()

        self.touchMappingScreens = screens
        self.touchMappingIndex = 0
        self.touchMappingSourceIdentifiers = []
        self.settingsWindow.orderOut(nil)

        NSLog("[TouchUp] HID: manual mapping started displays=%@",
              screens.map { "\($0.id):\($0.name)" }.joined(separator: ", "))
        self.showNextTouchMappingOverlay()
    }

    private func showNextTouchMappingOverlay() {
        self.touchMappingOverlay?.close()
        self.touchMappingOverlay = nil

        guard self.touchMappingIndex < self.touchMappingScreens.count else {
            self.finishTouchMapping()
            return
        }

        let screen = self.touchMappingScreens[self.touchMappingIndex]
        NSLog("[TouchUp] HID: manual mapping waiting displayID=%lu display='%@' step=%ld/%ld",
              screen.id,
              screen.name,
              self.touchMappingIndex + 1,
              self.touchMappingScreens.count)
        let overlay = TouchMappingOverlay.overlay(model: self.model,
                                                  screen: screen,
                                                  stepIndex: self.touchMappingIndex + 1,
                                                  totalSteps: self.touchMappingScreens.count,
                                                  excludedSourceIdentifiers: self.touchMappingSourceIdentifiers) { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .mapped(let sourceIdentifier):
                self.touchMappingSourceIdentifiers.insert(sourceIdentifier)
                self.touchMappingIndex += 1
                self.touchMappingOverlay?.close()
                self.touchMappingOverlay = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.showNextTouchMappingOverlay()
                }
            case .cancelled:
                self.finishTouchMapping()
            }
        }

        self.touchMappingOverlay = overlay
        overlay.makeVisible()
    }

    private func finishTouchMapping() {
        self.touchMappingOverlay?.close()
        self.touchMappingOverlay = nil
        self.touchMappingScreens = []
        self.touchMappingIndex = 0
        self.touchMappingSourceIdentifiers = []
        self.model.isMappingTouchscreens = false
        self.model.isPublishingMouseEventsEnabled = self.touchMappingPreviousPublishingState
        self.model.touchManager.refreshScreenAssignments()
        self.settingsWindow.makeVisible()
    }
}



class SettingsWindow: NSWindow {
    
    var model: TouchUp?
    
    static func window(model: TouchUp) -> SettingsWindow {
        let vc = NSHostingController(rootView: SettingsView(model:model))
        let window = SettingsWindow(contentRect: .zero,
                                    styleMask: [.closable, .titled, .fullSizeContentView, .resizable],
                                    backing: .buffered,
                                    defer: true,
                                    screen: nil)
        
        window.title = "Touch Up Settings"
        window.tabbingMode = .disallowed
        window.model = model
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        
        let windowController = NSWindowController(window: window)
        
        windowController.contentViewController = vc
        return window
    }
    
    override func close() {
        self.model?.savePreferences()
        NSApp.stopModal()
        super.close()
    }
    
    func makeVisible() {
        let alreadyOnScreen = self.isVisible
        
        self.setIsVisible(true)
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !alreadyOnScreen {
            self.center()
        }
        
    }
}



class DebugOverlay: NSWindow {
    
    var model: TouchUp?
    static var completion: (()->Void)?
    
    static func overlay(model: TouchUp) -> DebugOverlay {
        let vc = NSHostingController(rootView: DebugView(model:model, closeAction: {
            DebugOverlay.completion?()
        }))
        
        let window = DebugOverlay(contentRect: .zero,
                                    styleMask: [.resizable, .miniaturizable, .fullSizeContentView],
                                    backing: .buffered,
                                    defer: true,
                                    screen: nil)
        
        window.title = "Touches"
        window.tabbingMode = .disallowed
        window.model = model
        
        let windowController = NSWindowController(window: window)
        
        windowController.contentViewController = vc
        
        return window
    }
    
    
    func makeVisible() {
        
        self.setIsVisible(true)
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        if let controller = self.contentViewController {
            if let screen = model?.touchscreen()?.systemScreen() {
                self.level = .screenSaver // prevents notifications from coming in
                let presentationOptions: NSApplication.PresentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
                
                let options: [NSView.FullScreenModeOptionKey : NSNumber] = [
                    .fullScreenModeApplicationPresentationOptions : NSNumber(value: presentationOptions.rawValue),
                    .fullScreenModeWindowLevel : NSNumber(value: kCGNormalWindowLevel),
                    .fullScreenModeAllScreens : NSNumber(booleanLiteral: false)
                ]
                self.setIsVisible(false)
                controller.view.enterFullScreenMode(screen, withOptions: options)
            }
        }
    }
    
    override func close() {
        if let controller = self.contentViewController {
            self.level = .normal
            self.setIsVisible(true)
            controller.view.exitFullScreenMode(options: nil)
        }
        super.close()
    }
}

class CalibrationOverlay: NSWindow {

    var calibrationScreen: TUCScreen?

    static func overlay(model: TouchUp, screen: TUCScreen, completion: @escaping (CalibrationAssistantResult) -> Void) -> CalibrationOverlay {
        let vc = NSHostingController(rootView: CalibrationAssistantView(model: model, screen: screen, completion: completion))

        let window = CalibrationOverlay(contentRect: .zero,
                                        styleMask: [.resizable, .miniaturizable, .fullSizeContentView],
                                        backing: .buffered,
                                        defer: true,
                                        screen: nil)

        window.title = "Touch Calibration"
        window.tabbingMode = .disallowed
        window.calibrationScreen = screen

        let windowController = NSWindowController(window: window)
        windowController.contentViewController = vc

        return window
    }

    func makeVisible() {
        self.setIsVisible(true)
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        guard let controller = self.contentViewController,
              let screen = calibrationScreen?.systemScreen() else {
            return
        }

        self.level = .screenSaver
        let presentationOptions: NSApplication.PresentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
        let options: [NSView.FullScreenModeOptionKey: NSNumber] = [
            .fullScreenModeApplicationPresentationOptions: NSNumber(value: presentationOptions.rawValue),
            .fullScreenModeWindowLevel: NSNumber(value: kCGNormalWindowLevel),
            .fullScreenModeAllScreens: NSNumber(booleanLiteral: false)
        ]

        self.setIsVisible(false)
        controller.view.enterFullScreenMode(screen, withOptions: options)
    }

    override func close() {
        if let controller = self.contentViewController {
            self.level = .normal
            self.setIsVisible(true)
            controller.view.exitFullScreenMode(options: nil)
        }

        super.close()
    }
}

class TouchMappingOverlay: NSWindow {

    var mappingScreen: TUCScreen?

    static func overlay(model: TouchUp,
                        screen: TUCScreen,
                        stepIndex: Int,
                        totalSteps: Int,
                        excludedSourceIdentifiers: Set<Int>,
                        completion: @escaping (TouchMappingAssistantResult) -> Void) -> TouchMappingOverlay {
        let vc = NSHostingController(rootView: TouchMappingAssistantView(model: model,
                                                                         screen: screen,
                                                                         stepIndex: stepIndex,
                                                                         totalSteps: totalSteps,
                                                                         excludedSourceIdentifiers: excludedSourceIdentifiers,
                                                                         completion: completion))

        let window = TouchMappingOverlay(contentRect: .zero,
                                         styleMask: [.resizable, .miniaturizable, .fullSizeContentView],
                                         backing: .buffered,
                                         defer: true,
                                         screen: nil)

        window.title = "Touch Mapping"
        window.tabbingMode = .disallowed
        window.mappingScreen = screen

        let windowController = NSWindowController(window: window)
        windowController.contentViewController = vc

        return window
    }

    func makeVisible() {
        self.setIsVisible(true)
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        guard let controller = self.contentViewController,
              let screen = mappingScreen?.systemScreen() else {
            return
        }

        self.level = .screenSaver
        let presentationOptions: NSApplication.PresentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
        let options: [NSView.FullScreenModeOptionKey: NSNumber] = [
            .fullScreenModeApplicationPresentationOptions: NSNumber(value: presentationOptions.rawValue),
            .fullScreenModeWindowLevel: NSNumber(value: kCGNormalWindowLevel),
            .fullScreenModeAllScreens: NSNumber(booleanLiteral: false)
        ]

        self.setIsVisible(false)
        controller.view.enterFullScreenMode(screen, withOptions: options)
    }

    override func close() {
        if let controller = self.contentViewController {
            self.level = .normal
            self.setIsVisible(true)
            controller.view.exitFullScreenMode(options: nil)
        }

        super.close()
    }
}
