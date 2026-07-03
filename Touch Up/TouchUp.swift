//
//  Model.swift
//  Touch Up
//
//  Created by Sebastian Hueber on 03.02.23.
//

import AppKit
import Combine
import TouchUpCore

class TouchUp: NSObject, ObservableObject {
    
    let touchManager: TUCTouchInputManager
    private let gestureDefaultsVersion = 3
    private let calibrationStoreDefaultsKey = "touchCalibrationStore.v1"
    @Published var touches = [TUCTouch]()
    
    
    var observers = [AnyCancellable]()
    
    
    @Published var isPublishingMouseEventsEnabled = true
    
    @Published var connectionState: ConnectionState = .disconnected
    
    
    
    @Published var holdDuration: TimeInterval = 0.55
    @Published var doubleClickDistance: CGFloat = 3 //mm
    @Published var errorResistance: NSInteger = 0 // num of Reports to wait before cancelling a touch
    @Published var ignoreOriginTouches: Bool = false
    
    
    
    @Published var isWindowTitleBarDragEnabled = true
    @Published var isSecondaryClickEnabled = true
    @Published var isTwoFingerScrollEnabled = true
    
    
    
    @Published var connectedScreens = [TUCScreen]()

    @Published var calibrationStore = TouchCalibrationStore.empty
    @Published var calibrationDrafts = [String: TouchCalibration]()
    @Published var isMappingTouchscreens = false
    
    
    @Published var isAccessibilityAccessGranted = false
    @Published var isHIDListenEventAccessGranted = false

    var needsAccessibilityAccessPrompt: Bool {
        isPublishingMouseEventsEnabled && !isAccessibilityAccessGranted
    }

    var needsHIDListenEventAccessPrompt: Bool {
        !isHIDListenEventAccessGranted
    }

    var needsPermissionsPrompt: Bool {
        needsAccessibilityAccessPrompt || needsHIDListenEventAccessPrompt
    }
    
    @objc func screenParametersDidChange() {
        self.connectedScreens = TUCScreen.allScreens() as! [TUCScreen]
        self.touchManager.refreshScreenAssignments()
        self.syncCalibrationsToTouchManager()
    }
    
    
    @discardableResult
    func checkAccessibilityAccessGranted(prompt: Bool = false) -> Bool {
        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let isGranted = AXIsProcessTrustedWithOptions([checkOptPrompt: prompt] as CFDictionary?)
        self.isAccessibilityAccessGranted = isGranted
        return isGranted
    }

    func grantAccessibilityAccess() {
        grantRequiredAccess()
    }

    func grantRequiredAccess() {
        checkAccessibilityAccessGranted(prompt: true)
        requestHIDListenEventAccess(openSettingsIfDenied: false)
        closeSettingsIfPermissionsAreGranted()
    }

    @discardableResult
    func checkHIDListenEventAccessGranted(restartIfNewlyGranted: Bool = false) -> Bool {
        let wasGranted = isHIDListenEventAccessGranted
        let isGranted = touchManager.checkHIDListenEventAccessGranted()
        isHIDListenEventAccessGranted = isGranted

        if restartIfNewlyGranted && isGranted && !wasGranted {
            touchManager.stop()
            touchManager.start()
        }

        return isGranted
    }

    func grantHIDListenEventAccess() {
        requestHIDListenEventAccess(openSettingsIfDenied: true)
    }

    private func requestHIDListenEventAccess(openSettingsIfDenied: Bool) {
        let wasGranted = isHIDListenEventAccessGranted
        let requestGranted = touchManager.requestHIDListenEventAccess()
        let isGranted = requestGranted || touchManager.checkHIDListenEventAccessGranted()
        isHIDListenEventAccessGranted = isGranted

        if isGranted {
            if !wasGranted {
                touchManager.stop()
                touchManager.start()
            }
            closeSettingsIfPermissionsAreGranted()
        } else {
            touchManager.stop()
            touchManager.start()
            if openSettingsIfDenied {
                openInputMonitoringPrivacySettings()
            }
        }
    }

    func openInputMonitoringPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?listenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]

        for urlString in candidates {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func closeSettingsIfPermissionsAreGranted() {
        if !needsPermissionsPrompt {
            (NSApp.delegate as? AppDelegate)?.settingsWindow.close()
        }
    }

    override init() {
        self.touchManager = TUCTouchInputManager()
        
        super.init()
        
        self.screenParametersDidChange()
        
        self.touchManager.delegate = self
        
        NotificationCenter.default.addObserver(self, selector: #selector(TouchUp.screenParametersDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        initPreferences()
        
        checkAccessibilityAccessGranted()
        checkHIDListenEventAccessGranted()
    }
    
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
}


// MARK: - Loading, Saving and Syncing Settings with Framework
extension TouchUp {
    
    func initPreferences() {
        let defaults = UserDefaults.standard
        
        defaults.register(defaults: [
            "holdDuration" : 0.55,
            "doubleClickDistance" : 8,
            "errorResistance" : 4,
            "ignoreOriginTouches" : true,
            
            "isWindowTitleBarDragEnabled" : true,
            "isSecondaryClickEnabled" : true,
            "isTwoFingerScrollEnabled" : true,
        ])

        if defaults.integer(forKey: "gestureDefaultsVersion") < gestureDefaultsVersion {
            defaults.set(0.55, forKey: "holdDuration")
            defaults.set(false, forKey: "isScrollingWithOneFingerEnabled")
            defaults.set(false, forKey: "isClickOnLiftEnabled")
            defaults.set(true, forKey: "isWindowTitleBarDragEnabled")
            defaults.set(true, forKey: "isSecondaryClickEnabled")
            defaults.set(true, forKey: "isTwoFingerScrollEnabled")
            defaults.set(false, forKey: "isMagnificationEnabled")
            defaults.set(gestureDefaultsVersion, forKey: "gestureDefaultsVersion")
        }
        
        holdDuration = defaults.double(forKey: "holdDuration")
        doubleClickDistance = defaults.double(forKey: "doubleClickDistance")
        errorResistance = defaults.integer(forKey: "errorResistance")
        ignoreOriginTouches = defaults.bool(forKey: "ignoreOriginTouches")
        
        loadCalibrationStore()
        syncCalibrationsToTouchManager()
        
        self.observers = [
            $isPublishingMouseEventsEnabled.assign(to: \.postMouseEvents, on: touchManager),
            $holdDuration.assign(to: \.holdDuration, on: touchManager),
            $doubleClickDistance.assign(to: \.doubleClickTolerance, on: touchManager),
            $errorResistance.assign(to: \.errorResistance, on: touchManager),
            $ignoreOriginTouches.assign(to: \.ignoreOriginTouches, on: touchManager),
            $isWindowTitleBarDragEnabled.assign(to: \.windowTitleBarDragEnabled, on: touchManager),
            $isSecondaryClickEnabled.assign(to: \.twoFingerTapSecondaryClickEnabled, on: touchManager),
            $isTwoFingerScrollEnabled.assign(to: \.twoFingerScrollEnabled, on: touchManager)
        ]
        
        
        
        isWindowTitleBarDragEnabled = defaults.bool(forKey: "isWindowTitleBarDragEnabled")
        isSecondaryClickEnabled = defaults.bool(forKey: "isSecondaryClickEnabled")
        isTwoFingerScrollEnabled = defaults.bool(forKey: "isTwoFingerScrollEnabled")
    }
    
    
    func savePreferences() {
        let defaults = UserDefaults.standard
        
        defaults.set(holdDuration, forKey: "holdDuration")
        defaults.set(doubleClickDistance, forKey: "doubleClickDistance")
        defaults.set(errorResistance, forKey: "errorResistance")
        defaults.set(ignoreOriginTouches, forKey: "ignoreOriginTouches")
        
        defaults.set(isWindowTitleBarDragEnabled, forKey: "isWindowTitleBarDragEnabled")
        defaults.set(isSecondaryClickEnabled, forKey: "isSecondaryClickEnabled")
        defaults.set(isTwoFingerScrollEnabled, forKey: "isTwoFingerScrollEnabled")
    }
    
}


// MARK: - Touchscreen Calibration
extension TouchUp {

    func calibration(for screen: TUCScreen) -> TouchCalibration {
        calibrationStore.calibration(for: screen)
    }

    func draftCalibration(for screen: TUCScreen) -> TouchCalibration {
        calibrationDrafts[screen.calibrationKey] ?? calibration(for: screen)
    }

    func updateCalibrationDraft(_ calibration: TouchCalibration, for screen: TUCScreen) {
        calibrationDrafts[screen.calibrationKey] = calibration.sanitized(for: screen)
    }

    func learnTouchAssignment(from touch: TUCTouch, to screen: TUCScreen) {
        learnTouchAssignment(sourceIdentifier: touch.sourceIdentifier, to: screen)
    }

    func learnTouchAssignment(sourceIdentifier: Int, to screen: TUCScreen) {
        touchManager.learnDisplayAssignment(forSourceIdentifier: sourceIdentifier, displayID: screen.id)
    }

    func resetTouchAssignments() {
        touchManager.resetDisplayAssignments()
        touches = touchManager.touchSet.allObjects as? [TUCTouch] ?? []
    }

    func screensForTouchMapping() -> [TUCScreen] {
        let sortedScreens = connectedScreens.sorted {
            if $0.frame.origin.x == $1.frame.origin.x {
                return $0.frame.origin.y < $1.frame.origin.y
            }
            return $0.frame.origin.x < $1.frame.origin.x
        }
        let externalScreens = sortedScreens.filter { screen in
            CGDisplayIsBuiltin(CGDirectDisplayID(screen.id)) == 0
        }

        return externalScreens.isEmpty ? sortedScreens : externalScreens
    }

    func applyCalibration(for screen: TUCScreen) {
        calibrationStore.apply(draftCalibration(for: screen), for: screen)
        saveCalibrationStore()
        calibrationDrafts[screen.calibrationKey] = calibration(for: screen)
        syncCalibrationsToTouchManager()
    }

    func applyGeneratedCalibration(_ calibration: TouchCalibration, for screen: TUCScreen) {
        calibrationDrafts[screen.calibrationKey] = calibration.sanitized(for: screen)
        applyCalibration(for: screen)
    }

    func undoCalibration(for screen: TUCScreen) {
        calibrationStore.undo(for: screen)
        saveCalibrationStore()
        calibrationDrafts[screen.calibrationKey] = calibration(for: screen)
        syncCalibrationsToTouchManager()
    }

    func resetCalibration(for screen: TUCScreen) {
        calibrationStore.reset(for: screen)
        saveCalibrationStore()
        calibrationDrafts[screen.calibrationKey] = calibration(for: screen)
        syncCalibrationsToTouchManager()
    }

    func calibrationHistory(for screen: TUCScreen) -> [TouchCalibration] {
        calibrationStore.history(for: screen)
    }

    func restoreCalibrationVersion(_ calibration: TouchCalibration, for screen: TUCScreen) {
        calibrationStore.restore(calibration, for: screen)
        saveCalibrationStore()
        calibrationDrafts[screen.calibrationKey] = self.calibration(for: screen)
        syncCalibrationsToTouchManager()
    }

    func canUndoCalibration(for screen: TUCScreen) -> Bool {
        !calibrationHistory(for: screen).isEmpty
    }

    func syncCalibrationsToTouchManager() {
        var calibrations = [String: TUCTouchCalibration]()

        for (key, calibration) in calibrationStore.current {
            calibrations[key] = calibration.objectiveCCalibration()
        }

        touchManager.calibrationsByMonitorKey = calibrations
    }

    private func loadCalibrationStore() {
        let defaults = UserDefaults.standard

        guard let data = defaults.data(forKey: calibrationStoreDefaultsKey) else {
            calibrationStore = .empty
            calibrationDrafts = [:]
            return
        }

        do {
            var store = try JSONDecoder().decode(TouchCalibrationStore.self, from: data)
            store.normalize()
            calibrationStore = store
        } catch {
            calibrationStore = .empty
        }

        calibrationDrafts = [:]
    }

    private func saveCalibrationStore() {
        do {
            let data = try JSONEncoder().encode(calibrationStore)
            UserDefaults.standard.set(data, forKey: calibrationStoreDefaultsKey)
        } catch {
            assertionFailure("Failed to encode touch calibration store: \(error)")
        }
    }
}



extension TouchUp: TUCTouchDelegate {
    
    func touchesDidChange() {
        self.touches = self.touchManager.touchSet.allObjects as! [TUCTouch]
    }
    
    
    func touchscreen() -> TUCScreen? {
        self.connectedScreens.first
    }

    func touchscreenDidConnect() {
        self.connectionState = .connectedAutomatic
        self.touchManager.refreshScreenAssignments()
    }
    
    func touchscreenDidDisconnect() {
        self.connectionState = .disconnected
    }
}


extension TouchUp {
    func uiLabels<T>(for keyPath: KeyPath<TouchUp, T>) -> (title:String, description:String) {
        switch keyPath {
        case \.isPublishingMouseEventsEnabled:
            return("Control Mouse with Touch",
                   "Turns the driver on or off.")
            
        case \.isWindowTitleBarDragEnabled:
            return("Move Windows by Title Bar Drag",
                   "Drag from a window title bar to move that window.")

        case \.isSecondaryClickEnabled:
            return("Two Finger Tap Secondary Click",
                   "Tap with two fingers to generate a secondary click.")
            
        case \.isTwoFingerScrollEnabled:
            return("Scroll with 2 Fingers",
                   "Drag two fingers over the touchscreen to scroll content.")
            
        case \.holdDuration:
            return("Press and Hold Duration",
                   "How long you have to hold a finger before a right-click begins.")
            
        case \.doubleClickDistance:
            return("Double Click Zone",
                   "How many mm can two taps be apart from each other to qualify double click")
            
        case \.ignoreOriginTouches:
            return("Ignore Origin Touches",
                   "If your touchscreen randomly sends coordinate (0,0) in its datastream, toggle this option to make input more stable.")
            
        case \.errorResistance:
            return("Error Resistance",
                   "If your touchscreen is really unreliable at reporting touches, increase this slider to make inputs more stable at the cost of higher latency in detecting liftoffs.")
            
        default:
            return("\(keyPath)", "")
        }
    }
}


enum ConnectionState: Int {
    case uncertain
    case disconnected
    case connectedAutomatic
    
    var image: NSImage? {
        let image: NSImage?
        
        switch self {
        case .uncertain:
            image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
        case .disconnected:
            image = NSImage(systemSymbolName: "rectangle.badge.xmark", accessibilityDescription: nil)
        case .connectedAutomatic:
            image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: nil)
        }

        image?.isTemplate = true
        
        return image
    }
    
    var isConnected: Bool {
        return self == .connectedAutomatic
    }
}


extension TUCScreen: @retroactive Identifiable {}
