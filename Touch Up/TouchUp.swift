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
    var connectedTouchscreen: TUCScreen?
    
    var lastDateUSBAdded: Date?
    var lastDateScreenAdded: Date?
    var idOfLastAddedScreen: UInt?
    
    let hotPlugTimeInterval: TimeInterval = 10
    
    
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
    
    // MARK: - Attempt to automatically determine touch screen
    
    
    
    var identificationCues: (name:String, id:UInt) {
        get {
            let name = UserDefaults.standard.string(forKey: "touchscreenNameCue") ?? "Digital"
            let id   = UserDefaults.standard.integer(forKey: "touchscreenIDCue")
            return (name, UInt(id))
        }
    }
    
    func rememeberCues() {
        if let connectedTouchscreen = self.touchscreen() {
            UserDefaults.standard.set(connectedTouchscreen.name, forKey: "touchscreenNameCue")
            UserDefaults.standard.set(connectedTouchscreen.id,   forKey: "touchscreenIDCue")
        }
    }
    
    
    /**
     returns true, if the screen list contained the preferred screen which is now assigned the touch screen.
     if screen list empty, it removes the assigned touch screen.
     */
    @discardableResult func identifyPreferredOrNoScreen() -> Bool {
        let cues = identificationCues
        
        
        if connectedScreens.count == 0 {
            self.connectedTouchscreen = nil
            self.connectionState = .uncertain
            print("OH NO SCREEN")
            return true
        }
        
       
        
        // Perfect match: name + ID
        if let perfectMatch = connectedScreens.first(where: { $0.matching(name: cues.name, id: cues.id) == 1}) {
            self.connectedTouchscreen = perfectMatch
            self.connectionState = lastDateUSBAdded == nil ? .connectedPreferred : .connectedHotPlug
            print("PREFERRED SCREEN FOUND (perfect match)")
            return true
        }

        // Partial match by name only — ID can change after reconnect/reboot
        if let nameMatch = connectedScreens.first(where: { $0.matching(name: cues.name, id: cues.id) >= 0.5 }) {
            self.connectedTouchscreen = nameMatch
            self.connectionState = .uncertain
            print("PREFERRED SCREEN FOUND (name match)")
            return true
        }

        return false
    }
    
    
    @discardableResult func identifyHotPlug() -> Bool {
        // if the USB cable of a touch screen was plugged in within last 10 seconds, assign this to the touchscreen
        
        // no need to hot plug during existing connection
        if self.connectionState.isConnected {
            print("HOTPLUG SKIPPED")
            return false
        }
        
        if let lastDateUSBAdded, let lastDateScreenAdded, let idOfLastAddedScreen {
            if Date().timeIntervalSince(lastDateUSBAdded) < hotPlugTimeInterval
                && Date().timeIntervalSince(lastDateScreenAdded) < hotPlugTimeInterval {
                
                
                if let screen = self.connectedScreens.first(where: {$0.id == idOfLastAddedScreen}) {
                    self.connectedTouchscreen = screen
                    let cues = identificationCues
                    let match = screen.matching(name: cues.name, id: cues.id)
                    self.connectionState = match == 1 ? .connectedPreferred : .connectedHotPlug
                    print("HOTPLUG SUCCESS")
                    return true
                }
                
                print("HOTPLUG FAIL")
            }
        }
        
        return false
    }
    
    
    @objc func screenParametersDidChange() {
        // identify which screen is newly added.
        let oldScreenList = self.connectedScreens
        self.connectedScreens = TUCScreen.allScreens() as! [TUCScreen]
        
        // a new screen appeared!
        if connectedScreens.count > oldScreenList.count {
            self.lastDateScreenAdded = Date()
            
            let new = connectedScreens.first { s in
                !(oldScreenList.contains(where: {$0.id == s.id}))
            }
            if let new {
                self.idOfLastAddedScreen = new.id
                identifyHotPlug()
            }
        }
        
        // search for the preferred screen, also important if user rearranged screens (and screen numbers)
        if !self.identifyPreferredOrNoScreen() {
            self.connectedTouchscreen = self.connectedScreens.last
        }
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



extension TouchUp: TUCTouchDelegate {
    
    func touchesDidChange() {
        self.touches = self.touchManager.touchSet.allObjects as! [TUCTouch]
    }
    
    
    func touchscreen() -> TUCScreen? {
        self.connectedTouchscreen ?? self.connectedScreens.last
    }

    func touchscreenDidConnect() {
        self.lastDateUSBAdded = Date()

        if !self.identifyHotPlug() {
            if self.connectionState.isConnected {
                self.connectionState = .uncertain
            }
        }
        
        self.identifyPreferredOrNoScreen()
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
            
        case \.connectedTouchscreen:
            return("Assign Mouse Events to",
                   "Specifies which screen should receive the touch events.")
            
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
    case connectedHotPlug // connected as result from hot plugging within a few seconds
    case connectedPreferred // connected with stored cues matching perfectly
    
    var image: NSImage? {
        let image: NSImage?
        
        switch self {
        case .uncertain:
            image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
        case .disconnected:
            image = NSImage(systemSymbolName: "rectangle.badge.xmark", accessibilityDescription: nil)
        default:
            image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: nil)
        }

        image?.isTemplate = true
        
        return image
    }
    
    var isConnected: Bool {
        return self == .connectedPreferred || self == .connectedHotPlug
    }
}
                 
                 
extension TUCScreen: @retroactive Identifiable {
    func matching(name:String, id:UInt) -> Float {
        let sameName = self.name == name
        let sameID = self.id == id
        
        if sameName && sameID { return 1 }
        else if sameName { return 0.5 }
        else if sameID { return 0.2 }
        else { return 0}
    }
}
