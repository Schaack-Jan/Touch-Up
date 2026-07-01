//
//  TUCTouchInputManager.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import "TUCTouchInputManager.h"

#import "HIDInterpreter.h"
#import "TUCCursorUtilities.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hid/IOHIDElement.h>

@class TUCTouchInputManager;

@interface TUCInputSourceState : NSObject

@property NSInteger sourceIdentifier;
@property NSInteger currentFrameID;

@property (weak, nullable) TUCTouch *cursorTouch;
@property (weak, nullable) TUCTouch *gestureAdditionalTouch;

@property BOOL cursorTouchQualifiedForTap; // if the cursor entered moving state once it can no longer be interpreted as tap
@property BOOL cursorTouchDidHold;
@property (strong) NSDate *cursorTouchStationarySinceDate;

@property CGFloat pinchDistance;
@property TUCCursorGesture identifiedMultitouchGesture;

@end

@implementation TUCInputSourceState
@end

@interface TUCUSBHIDTouchDevice : NSObject

@property (weak, nullable) TUCTouchInputManager *manager;
@property NSInteger sourceIdentifier;
@property uint64_t registryID;
@property NSUInteger assignedDisplayID;
@property NSInteger vendorID;
@property NSInteger productID;
@property (copy) NSString *name;

@property (assign, nonatomic) IOHIDDeviceRef hidDeviceRef;
@property (strong) NSMutableData *hidReportBuffer;
@property CGFloat hidCurrentX;
@property CGFloat hidCurrentY;
@property BOOL hidCurrentButton;

- (void)close;

@end

@implementation TUCUSBHIDTouchDevice

- (void)close {
    if (_hidDeviceRef) {
        IOHIDDeviceUnscheduleFromRunLoop(_hidDeviceRef, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDDeviceClose(_hidDeviceRef, kIOHIDOptionsTypeNone);
        CFRelease(_hidDeviceRef);
        _hidDeviceRef = NULL;
    }
    _hidReportBuffer = nil;
}

- (void)dealloc {
    [self close];
}

@end

@interface TUCTouchInputManager ()

// ─── IOKit HID device ─────────────────────────────────────────────────────
@property IONotificationPortRef usbNotificationPort;
@property io_iterator_t usbAppearedIterator;
@property io_iterator_t usbRemovedIterator;
@property (strong) NSMutableDictionary<NSNumber *, TUCUSBHIDTouchDevice *> *hidTouchDevicesByRegistryID;
@property (strong) NSMutableDictionary<NSNumber *, TUCInputSourceState *> *inputSourceStatesByIdentifier;
@property NSInteger nextTouchDeviceIdentifier;

- (void)processHIDValuesForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice;
- (void)removeHIDDeviceForService:(io_service_t)hidService;
- (TUCScreen *)screenForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice;
- (TUCInputSourceState *)inputSourceStateForIdentifier:(NSInteger)sourceIdentifier;
- (void)didProcessReportForSourceIdentifier:(NSInteger)sourceIdentifier;
- (void)cancelTouchesForSourceIdentifier:(NSInteger)sourceIdentifier;

@end


@implementation TUCTouchInputManager

#pragma mark   Start & Stop

- (void)start {
    [self startUSBHIDListening];
}

- (void)stop {
    [self stopUSBHIDListening];
}


#pragma mark - HID Device Listening

// Value callback fires once per element that changed within a report.
// We track the latest X, Y, and button state; processHIDValues assembles them.
static void hidValueCallback(void *ctx, IOReturn result, void *sender, IOHIDValueRef value) {
    if (result != kIOReturnSuccess) return;
    TUCUSBHIDTouchDevice *touchDevice = (__bridge TUCUSBHIDTouchDevice *)ctx;
    IOHIDElementRef elem = IOHIDValueGetElement(value);
    uint32_t up   = IOHIDElementGetUsagePage(elem);
    uint32_t u    = IOHIDElementGetUsage(elem);
    CFIndex  val  = IOHIDValueGetIntegerValue(value);
    CFIndex  lMin = IOHIDElementGetLogicalMin(elem);
    CFIndex  lMax = IOHIDElementGetLogicalMax(elem);
    if (lMax <= lMin) return;

    if (up == 0x01 && u == 0x30) {         // Generic Desktop X
        touchDevice.hidCurrentX = (CGFloat)(val - lMin) / (CGFloat)(lMax - lMin);
    } else if (up == 0x01 && u == 0x31) {  // Generic Desktop Y
        touchDevice.hidCurrentY = (CGFloat)(val - lMin) / (CGFloat)(lMax - lMin);
    } else if ((up == 0x09 && u == 0x01) || (up == 0x0D && u == 0x42)) {
        touchDevice.hidCurrentButton = (val != 0);  // Button 1 or Tip Switch
    }
}

// Report callback fires once per complete HID report, after all value callbacks for that report.
static void hidReportCallback(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                              uint32_t reportID, uint8_t *report, CFIndex len) {
    if (result != kIOReturnSuccess || len <= 0) return;
    TUCUSBHIDTouchDevice *touchDevice = (__bridge TUCUSBHIDTouchDevice *)ctx;
    [touchDevice.manager processHIDValuesForTouchDevice:touchDevice];
}

static void usbAppearedCallback(void *refcon, io_iterator_t iterator) {
    [(__bridge TUCTouchInputManager *)refcon handleUSBIterator:iterator appeared:YES];
}
static void usbRemovedCallback(void *refcon, io_iterator_t iterator) {
    [(__bridge TUCTouchInputManager *)refcon handleUSBIterator:iterator appeared:NO];
}

- (void)startUSBHIDListening {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _usbNotificationPort = IONotificationPortCreate(kIOMasterPortDefault);
#pragma clang diagnostic pop
    CFRunLoopSourceRef src = IONotificationPortGetRunLoopSource(_usbNotificationPort);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopDefaultMode);

    CFMutableDictionaryRef matchAppear = IOServiceMatching("IOHIDDevice");
    CFMutableDictionaryRef matchRemove = IOServiceMatching("IOHIDDevice");

    IOServiceAddMatchingNotification(_usbNotificationPort, kIOFirstMatchNotification,
        matchAppear, usbAppearedCallback, (__bridge void *)self, &_usbAppearedIterator);
    [self handleUSBIterator:_usbAppearedIterator appeared:YES];

    IOServiceAddMatchingNotification(_usbNotificationPort, kIOTerminatedNotification,
        matchRemove, usbRemovedCallback, (__bridge void *)self, &_usbRemovedIterator);
    [self handleUSBIterator:_usbRemovedIterator appeared:NO];
}

- (void)stopUSBHIDListening {
    for (TUCUSBHIDTouchDevice *touchDevice in [_hidTouchDevicesByRegistryID allValues]) {
        [touchDevice close];
    }
    [_hidTouchDevicesByRegistryID removeAllObjects];
    [_inputSourceStatesByIdentifier removeAllObjects];

    if (_usbAppearedIterator) { IOObjectRelease(_usbAppearedIterator); _usbAppearedIterator = 0; }
    if (_usbRemovedIterator)  { IOObjectRelease(_usbRemovedIterator);  _usbRemovedIterator  = 0; }
    if (_usbNotificationPort) { IONotificationPortDestroy(_usbNotificationPort); _usbNotificationPort = nil; }
}

- (void)handleUSBIterator:(io_iterator_t)iterator appeared:(BOOL)appeared {
    io_service_t service;
    int count = 0;
    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        count++;
        if (appeared) {
            [self considerHIDDevice:service];
        } else {
            [self removeHIDDeviceForService:service];
        }
        IOObjectRelease(service);
    }
    if (appeared) NSLog(@"[TouchUp] HID: iterator drained, %d IOHIDDevice services found", count);
}

- (void)considerHIDDevice:(io_service_t)hidDevice {
    CFMutableDictionaryRef propsRef = nil;
    if (IORegistryEntryCreateCFProperties(hidDevice, &propsRef, kCFAllocatorDefault, 0) != KERN_SUCCESS) return;
    NSDictionary *props = CFBridgingRelease(propsRef);

    if (![props[@"Transport"] isEqualToString:@"USB"]) return;

    NSInteger usagePage = [props[@"PrimaryUsagePage"] integerValue];
    NSInteger usage     = [props[@"PrimaryUsage"]     integerValue];

    NSLog(@"[TouchUp] HID: device usagePage=%ld usage=%ld VendorID=%@ ProductID=%@",
          (long)usagePage, (long)usage, props[@"VendorID"], props[@"ProductID"]);

    BOOL isDigitizer = (usagePage == 0x0D);
    BOOL isPointer   = (usagePage == 0x01 && (usage == 1 || usage == 2));
    if (!isDigitizer && !isPointer) {
        NSLog(@"[TouchUp] HID: not a touch device — skipping");
        return;
    }

    [self openIOHIDDevice:hidDevice properties:props requiresAbsolutePointer:isPointer && !isDigitizer];
}

- (BOOL)hidDeviceHasUsableTouchElements:(IOHIDDeviceRef)device requiresTouchButton:(BOOL)requiresTouchButton {
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);
    if (!elements) return NO;

    BOOL hasAbsoluteX = NO;
    BOOL hasAbsoluteY = NO;
    BOOL hasTouchButton = NO;

    for (CFIndex i = 0; i < CFArrayGetCount(elements); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        uint32_t page = IOHIDElementGetUsagePage(element);
        uint32_t usage = IOHIDElementGetUsage(element);
        CFIndex lMin = IOHIDElementGetLogicalMin(element);
        CFIndex lMax = IOHIDElementGetLogicalMax(element);
        BOOL hasRange = lMax > lMin;

        if (page == 0x01 && usage == 0x30 && hasRange && !IOHIDElementIsRelative(element)) {
            hasAbsoluteX = YES;
        } else if (page == 0x01 && usage == 0x31 && hasRange && !IOHIDElementIsRelative(element)) {
            hasAbsoluteY = YES;
        } else if ((page == 0x09 && usage == 0x01) || (page == 0x0D && usage == 0x42)) {
            hasTouchButton = YES;
        }
    }

    CFRelease(elements);
    return hasAbsoluteX && hasAbsoluteY && (!requiresTouchButton || hasTouchButton);
}

- (uint64_t)registryIDForService:(io_service_t)hidService {
    uint64_t registryID = 0;
    kern_return_t ret = IORegistryEntryGetRegistryEntryID(hidService, &registryID);
    return ret == KERN_SUCCESS ? registryID : (uint64_t)hidService;
}

- (NSString *)displayNameForHIDProperties:(NSDictionary *)properties {
    NSString *product = properties[@"Product"] ?: properties[@"ProductString"];
    NSString *manufacturer = properties[@"Manufacturer"] ?: properties[@"ManufacturerString"];
    if (product.length > 0 && manufacturer.length > 0) {
        return [NSString stringWithFormat:@"%@ %@", manufacturer, product];
    }
    return product ?: manufacturer ?: @"USB HID Touch";
}

// Open the IOHIDDevice for shared (non-exclusive) input report access.
// For digitizer devices (usage page 0x0D), this does not trigger the Input Monitoring TCC prompt.
// Element value callbacks update X/Y/button state; report callback fires once per complete report.
- (void)openIOHIDDevice:(io_service_t)hidService properties:(NSDictionary *)properties requiresAbsolutePointer:(BOOL)requiresAbsolutePointer {
    uint64_t registryID = [self registryIDForService:hidService];
    NSNumber *registryKey = @(registryID);
    if (registryID != 0 && _hidTouchDevicesByRegistryID[registryKey] != nil) return;

    IOHIDDeviceRef device = IOHIDDeviceCreate(kCFAllocatorDefault, hidService);
    if (!device) {
        NSLog(@"[TouchUp] HID: IOHIDDeviceCreate failed");
        return;
    }

    if (![self hidDeviceHasUsableTouchElements:device requiresTouchButton:requiresAbsolutePointer]) {
        NSLog(@"[TouchUp] HID: no usable absolute touch axes — skipping");
        CFRelease(device);
        return;
    }

    IOReturn ret = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    if (ret != kIOReturnSuccess) {
        NSLog(@"[TouchUp] HID: IOHIDDeviceOpen failed: 0x%08x", ret);
        CFRelease(device);
        return;
    }

    TUCUSBHIDTouchDevice *touchDevice = [TUCUSBHIDTouchDevice new];
    touchDevice.manager = self;
    touchDevice.sourceIdentifier = self.nextTouchDeviceIdentifier++;
    touchDevice.registryID = registryID;
    touchDevice.vendorID = [properties[@"VendorID"] integerValue];
    touchDevice.productID = [properties[@"ProductID"] integerValue];
    touchDevice.name = [self displayNameForHIDProperties:properties];
    touchDevice.hidDeviceRef = device; // owned — caller of IOHIDDeviceCreate holds the only reference

    [self screenForTouchDevice:touchDevice];
    [self inputSourceStateForIdentifier:touchDevice.sourceIdentifier];

    // 512 bytes covers all USB HID reports (USB full-speed max is 64, but some devices use more)
    NSUInteger bufSize = 512;
    touchDevice.hidReportBuffer = [NSMutableData dataWithLength:bufSize];

    _hidTouchDevicesByRegistryID[registryKey] = touchDevice;

    IOHIDDeviceRegisterInputValueCallback(device, hidValueCallback, (__bridge void *)touchDevice);
    IOHIDDeviceRegisterInputReportCallback(device, touchDevice.hidReportBuffer.mutableBytes,
                                           (CFIndex)bufSize, hidReportCallback, (__bridge void *)touchDevice);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    if (_hidTouchDevicesByRegistryID.count == 1) {
        TouchInputManagerDidConnectTouchscreen((__bridge void *)self);
    }
    NSLog(@"[TouchUp] HID: device opened, source=%ld name='%@' VendorID=%ld ProductID=%ld listening for reports",
          (long)touchDevice.sourceIdentifier,
          touchDevice.name,
          (long)touchDevice.vendorID,
          (long)touchDevice.productID);
}

- (void)removeHIDDeviceForService:(io_service_t)hidService {
    NSNumber *matchedKey = nil;
    TUCUSBHIDTouchDevice *matchedDevice = nil;
    for (NSNumber *key in _hidTouchDevicesByRegistryID) {
        TUCUSBHIDTouchDevice *touchDevice = _hidTouchDevicesByRegistryID[key];
        if (touchDevice.hidDeviceRef && IOObjectIsEqualTo(IOHIDDeviceGetService(touchDevice.hidDeviceRef), hidService)) {
            matchedKey = key;
            matchedDevice = touchDevice;
            break;
        }
    }

    if (!matchedDevice) return;

    [self cancelTouchesForSourceIdentifier:matchedDevice.sourceIdentifier];
    [_inputSourceStatesByIdentifier removeObjectForKey:@(matchedDevice.sourceIdentifier)];
    [matchedDevice close];
    [_hidTouchDevicesByRegistryID removeObjectForKey:matchedKey];

    NSLog(@"[TouchUp] HID: device removed, source=%ld name='%@'",
          (long)matchedDevice.sourceIdentifier,
          matchedDevice.name);

    if (_hidTouchDevicesByRegistryID.count == 0) {
        TouchInputManagerDidDisconnectTouchscreen((__bridge void *)self);
    }
}

- (void)processHIDValuesForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice {
    CGFloat x = MAX(0.0, MIN(1.0, touchDevice.hidCurrentX));
    CGFloat y = MAX(0.0, MIN(1.0, touchDevice.hidCurrentY));
    TUCScreen *screen = [self screenForTouchDevice:touchDevice];
    [self updateTouch:0
         withLocation:CGPointMake(x, y)
            onSurface:(Boolean)touchDevice.hidCurrentButton
    tooLargeForFinger:1
               screen:screen
     sourceIdentifier:touchDevice.sourceIdentifier];
    [self didProcessReportForSourceIdentifier:touchDevice.sourceIdentifier];
}

- (void)didConnectTouchscreen {
    [self.delegate touchscreenDidConnect];
}

- (void)didDisconnectTouchscreen {
    [self.delegate touchscreenDidDisconnect];
}





#pragma mark - Reacting to HID Events

- (void)didProcessReport {
    [self didProcessReportForSourceIdentifier:0];
}

- (void)didProcessReportForSourceIdentifier:(NSInteger)sourceIdentifier {
    TUCInputSourceState *sourceState = [self inputSourceStateForIdentifier:sourceIdentifier];
    // go through all touches: if the frame is not the latest one, the touch might be old and should be removed.
    
    for (TUCTouch *touch in self.touchSet) {
        
        if (touch.sourceIdentifier == sourceIdentifier && touch.lastUpdated + self.errorResistance < sourceState.currentFrameID) {
            [touch setPhase:NSTouchPhaseCancelled];
            [self removeTouch:touch now:NO];
        }
    }
    
    if ([[self activeTouchesForSourceIdentifier:sourceIdentifier] count] == 0) {
        [self stopCurrentGestureForSourceState:sourceState];
    }
    
    ++sourceState.currentFrameID;
    
    [self processTouchesForCursorInputForSourceState:sourceState];
    
}


- (void)stopCurrentGestureForSourceState:(TUCInputSourceState *)sourceState {
    [[TUCCursorUtilities sharedInstance] stopDraggingCursor];
    [[TUCCursorUtilities sharedInstance] stopMagnifying];

    sourceState.identifiedMultitouchGesture = _TUCCursorGestureNone;
}



/**
 Most important event handling callback: it posts the events to the system where the touches need to go
 */
- (void)updateTouch:(NSInteger)contactID withLocation:(CGPoint)digitizerPoint onSurface:(BOOL)isOnSurface tooLargeForFinger:(BOOL)confidenceFlag {
    [self updateTouch:contactID
         withLocation:digitizerPoint
            onSurface:isOnSurface
    tooLargeForFinger:confidenceFlag
               screen:[self touchscreen]
     sourceIdentifier:0];
}

- (void)updateTouch:(NSInteger)contactID
       withLocation:(CGPoint)digitizerPoint
          onSurface:(BOOL)isOnSurface
  tooLargeForFinger:(BOOL)confidenceFlag
             screen:(nullable TUCScreen *)screen
   sourceIdentifier:(NSInteger)sourceIdentifier {
    
    // assume that this is an erroneous message!!!
    if (self.ignoreOriginTouches && CGPointEqualToPoint(digitizerPoint, CGPointZero)) {
        return;
    }

    TUCInputSourceState *sourceState = [self inputSourceStateForIdentifier:sourceIdentifier];
    TUCScreen *touchscreen = screen ?: [self touchscreen];
    
    CGPoint point = [self convertDigitizerPoint:digitizerPoint toRelativeScreenPointOnScreen:touchscreen];
    
    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID sourceIdentifier:sourceIdentifier isNew:&isNewTouch];
    
    if (isNewTouch && (sourceState.cursorTouch == nil || !sourceState.cursorTouch.isActive)) {
        sourceState.cursorTouch = touch;
        sourceState.cursorTouchQualifiedForTap = YES;
        sourceState.cursorTouchDidHold = NO;
        sourceState.cursorTouchStationarySinceDate = nil;
    }
    
    [touch setLocation: point];
    [touch setIsOnSurface:isOnSurface];
    [touch setConfidenceFlag:confidenceFlag];
    [touch setScreen:touchscreen];
    [touch setLastUpdated:sourceState.currentFrameID];
    
    if (!isOnSurface) {
        [touch setPhase: NSTouchPhaseEnded];
        [self removeTouch:touch now:NO];
        [self.delegate touchesDidChange];
        return;
        
    }
    
    if(touch.previousPhase != NSTouchPhaseEnded && !isNewTouch) {
        // update to an existing touch... check if stationary or not
        CGFloat digitizerRelDistance = sqrt(pow(touch.location.x - touch.previousLocation.x, 2) + pow(touch.location.y - touch.previousLocation.y, 2));
        CGFloat screenSize = touchscreen.physicalSize.width;
        BOOL isStationary = (digitizerRelDistance * screenSize) < 0.1;
//        BOOL isStationary = CGPointEqualToPoint(touch.location, touch.previousLocation);
        
        if (touch.uuid == sourceState.cursorTouch.uuid) {
            if (!isStationary) {
                sourceState.cursorTouchQualifiedForTap = NO;
                sourceState.cursorTouchStationarySinceDate = nil;
                
            } else if (touch.phase !=  NSTouchPhaseStationary) {
                sourceState.cursorTouchStationarySinceDate = [NSDate date];
            }
        }
        
        [touch setPhase:isStationary ? NSTouchPhaseStationary : NSTouchPhaseMoved];
    }
    
    
    [self.delegate touchesDidChange];
    
    return;
}


- (void)updateTouch:(NSInteger)contactID withSize:(CGSize)size azimuth:(CGFloat)azimuth {
    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID sourceIdentifier:0 isNew:&isNewTouch];
    TUCInputSourceState *sourceState = [self inputSourceStateForIdentifier:0];
    [touch setLastUpdated:sourceState.currentFrameID];
    
    [touch setSize:size];
    [touch setAzimuth:azimuth];
}



#pragma mark - Mouse Cursor Management



- (void)processTouchesForCursorInputForSourceState:(TUCInputSourceState *)sourceState {
    
    if(!sourceState.cursorTouch || !self.postMouseEvents) {
        return;
    }
    
    TUCTouch *cursorTouch = sourceState.cursorTouch;
    
    
    NSArray<TUCTouch *> *touches = [[self activeTouchesForSourceIdentifier:sourceState.sourceIdentifier] allObjects];
    NSTouchPhase phase = cursorTouch.phase;
    
    
    if (phase == NSTouchPhaseBegan) {
        [self performMouseEventForGesture:TUCCursorGestureTouchDown sourceState:sourceState];
        return;
    }
    
    
    else if (phase == NSTouchPhaseStationary) {
        NSTimeInterval holdDuration = 0;
        if (sourceState.cursorTouchStationarySinceDate != nil) {
            holdDuration = [[NSDate date] timeIntervalSinceDate:sourceState.cursorTouchStationarySinceDate];
        }
        if (sourceState.cursorTouchQualifiedForTap && holdDuration > self.holdDuration) {
            // the user left the finger on the screen for the min duration required to produce a hold
            sourceState.cursorTouchDidHold = YES;
        }
        
        [self checkForSecondaryClickForSourceState:sourceState];
        
        return;
    }
    
    
    else if (phase == NSTouchPhaseEnded) {
        if (sourceState.identifiedMultitouchGesture == _TUCCursorGestureNone ) {
            if (sourceState.cursorTouchDidHold) {
                [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag sourceState:sourceState];
            } else if (!sourceState.cursorTouchQualifiedForTap) {
                [self performMouseEventForGesture:TUCCursorGestureDrag sourceState:sourceState];
            }
        }
        
        TUCCursorGesture endedGesture = sourceState.identifiedMultitouchGesture;
        BOOL qualifiedForTap = sourceState.cursorTouchQualifiedForTap;
        [self stopCurrentGestureForSourceState:sourceState];
        
        if (qualifiedForTap) {
            [self performMouseEventForGesture:TUCCursorGestureTap sourceState:sourceState];
        } else {
            if (endedGesture != _TUCCursorGestureNone) {
                [self performMouseEventForGesture:endedGesture sourceState:sourceState];
            }
        }
        
        return;
    }
    
    
    else if (phase == NSTouchPhaseCancelled) {
        [self stopCurrentGestureForSourceState:sourceState];
        return;
    }
    
    if ([self checkForSecondaryClickForSourceState:sourceState]) {
        return;
    }
    
    if ([touches count] == 2 && [touches containsObject: cursorTouch]) {
        // check if we need to initiate two finger drag, pinch, ...
        if (sourceState.identifiedMultitouchGesture == _TUCCursorGestureNone ) {

            TUCTouch *otherTouch = touches[1];
            if (otherTouch.uuid == cursorTouch.uuid) {
                otherTouch = touches[0];
            }
            
            sourceState.gestureAdditionalTouch = otherTouch;
            
            if (sourceState.gestureAdditionalTouch.isActive) {
                CGPoint trajectoryA = [cursorTouch trajectorySign];
                CGPoint trajectoryB = [otherTouch trajectorySign];
                
                
                if (   !CGPointEqualToPoint(trajectoryA, CGPointZero)
                    && !CGPointEqualToPoint(trajectoryB, CGPointZero)) {
                    
                    if (!CGPointEqualToPoint(trajectoryA, trajectoryB)) {
                        sourceState.identifiedMultitouchGesture = TUCCursorGesturePinch;
                    }
//                    else {
//                        sourceState.identifiedMultitouchGesture = TUCCursorGestureTwoFingerDrag;
//                    }
                }
                
            } else {
                // secondary click
                [self removeTouch:sourceState.gestureAdditionalTouch now:YES];
                sourceState.gestureAdditionalTouch = nil;
                [self performMouseEventForGesture:TUCCursorGestureTapSecondFinger sourceState:sourceState];
            }
        }
        
        // other finger lifted, gesture ended
        if (!sourceState.gestureAdditionalTouch.isActive) {
            [self stopCurrentGestureForSourceState:sourceState];
        }
        
        
        if(sourceState.identifiedMultitouchGesture != _TUCCursorGestureNone) {
            [self performMouseEventForGesture:sourceState.identifiedMultitouchGesture sourceState:sourceState];
            return;
        }
        
    }
    

    if (sourceState.cursorTouchDidHold) {
        [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag sourceState:sourceState];
    } else {
        [self performMouseEventForGesture:TUCCursorGestureDrag sourceState:sourceState];
    }
}


- (BOOL)checkForSecondaryClickForSourceState:(TUCInputSourceState *)sourceState {
//    if (sourceState.identifiedMultitouchGesture != _TUCCursorGestureNone) {
//        return NO;
//    }
    
    NSSet<TUCTouch *> *touchesInProximity = [self touchesInProximityTo:sourceState.cursorTouch.location maxDistance:60 sourceState:sourceState];
    if (touchesInProximity.count >= 2 && sourceState.identifiedMultitouchGesture == _TUCCursorGestureNone) {

        // TUCCursorGestureTwoFingerTap
        NSPredicate *p1 = [NSPredicate predicateWithFormat:@"phase == %d", NSTouchPhaseEnded];
        NSPredicate *p2 = [NSPredicate predicateWithFormat:@"phase == %d", NSTouchPhaseCancelled];

        NSPredicate *p3 = [NSPredicate predicateWithFormat:@"contactID != %d", sourceState.cursorTouch.contactID];

        NSPredicate *p4 = [NSCompoundPredicate orPredicateWithSubpredicates:@[p1, p2]];
        NSPredicate *p5 = [NSCompoundPredicate andPredicateWithSubpredicates:@[p3, p4]];

        NSSet<TUCTouch *> *endedTouches = [touchesInProximity filteredSetUsingPredicate:p5];

        if (endedTouches.count == 1) {
            for (TUCTouch* touchToRemove in endedTouches) {
                [self removeTouch:touchToRemove now:YES];
            }

            [self performMouseEventForGesture:TUCCursorGestureTapSecondFinger sourceState:sourceState];
            return YES;
        }
    }
    return NO;
}


- (void)performMouseEventForGesture:(TUCCursorGesture)gesture sourceState:(TUCInputSourceState *)sourceState {
    TUCTouch *touch = sourceState.cursorTouch;

    TUCScreen *ts = touch.screen ?: [self touchscreen];
    TUCScreen *secondFingerScreen = sourceState.gestureAdditionalTouch.screen ?: ts;
    CGPoint screenLocation = [self convertScreenPointRelativeToAbsolute:touch.location onScreen:ts];
    CGPoint location2ndFinger = [self convertScreenPointRelativeToAbsolute:sourceState.gestureAdditionalTouch.location onScreen:secondFingerScreen];

    NSLog(@"[TouchUp] screen='%@' frame={{%.0f,%.0f},{%.0f,%.0f}} relTouch=(%.3f,%.3f) absTouch=(%.0f,%.0f)",
          ts.name,
          ts.frame.origin.x, ts.frame.origin.y,
          ts.frame.size.width, ts.frame.size.height,
          touch.location.x, touch.location.y,
          screenLocation.x, screenLocation.y);
    
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    
    TUCCursorAction action = [self actionForGesture:gesture];
    
    CGFloat doubleClickSpan = self.doubleClickTolerance * [ts pixelsPerMM];
    [[TUCCursorUtilities sharedInstance] setDoubleClickTolerance:doubleClickSpan];
    
    switch (action) {
        case TUCCursorActionNone:
            break;
            
        case TUCCursorActionMove:
            [utils moveCursorTo:screenLocation];
            break;
            
        case TUCCursorActionMoveClickIfNeeded:
            [utils moveCursorTo:screenLocation];
            if ([self isLocationOutsideFrontmostWindow:screenLocation onScreen:ts]) {
                [utils performClickAt:screenLocation];
            }
            
            break;
            
        case TUCCursorActionPointAndClick:
            [utils moveCursorTo:screenLocation];
            if (touch.phase == NSTouchPhaseEnded) {
                [utils performClickAt:screenLocation];
            }
            break;
            
        case TUCCursorActionDrag:
            [utils dragCursorTo:screenLocation phase:touch.phase];
            break;
            
        case TUCCursorActionClick:
            [utils performClickAt:screenLocation];
            break;
            
        case TUCCursorActionSecondaryClick:
            [utils performSecondaryClickAt: screenLocation];
            break;
            
        case TUCCursorActionScroll: {
            CGPoint prevLocation = [self convertScreenPointRelativeToAbsolute:touch.previousLocation onScreen:ts];
            CGPoint translation = CGPointMake(screenLocation.x - prevLocation.x,
                                              screenLocation.y - prevLocation.y);
            [utils scroll:translation phase:touch.phase];
            
            break; }
            
        case TUCCursorActionMagnify:
            [utils magnifyLocationA:screenLocation
                          locationB:location2ndFinger
            relativeP1:sourceState.cursorTouch.location relP2:sourceState.gestureAdditionalTouch.location];
            
            if (touch.phase == NSTouchPhaseEnded || sourceState.gestureAdditionalTouch.phase == NSTouchPhaseEnded) {
                [utils stopMagnifying];
            }
            break;
    }
}


- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture {
    
    if (self.delegate != nil) {
        return [self.delegate actionForGesture:gesture];
    }
    
    switch(gesture) {
        case TUCCursorGestureTouchDown:         return TUCCursorActionMoveClickIfNeeded;
        case TUCCursorGestureTap:               return TUCCursorActionClick;
        case TUCCursorGestureLongPress:         return TUCCursorActionClick;
        case TUCCursorGestureDrag:              return TUCCursorActionScroll;
        case TUCCursorGestureHoldAndDrag:       return TUCCursorActionDrag;
        case TUCCursorGestureTapSecondFinger:   return TUCCursorActionSecondaryClick;
        case TUCCursorGestureTwoFingerDrag:     return TUCCursorActionDrag;
            
        case TUCCursorGesturePinch:             return TUCCursorActionMagnify;
        case _TUCCursorGestureNone:             return TUCCursorActionNone;
    }
}


#pragma mark - Touch Set

/**
 The `touchSet` can contain touches whose phase is ended or cancelled. activeTouches. filteres those out
 */
- (NSSet<TUCTouch *> *)activeTouches {
    NSPredicate *p1 = [NSPredicate predicateWithFormat:@"phase != %d", NSTouchPhaseEnded];
    NSPredicate *p2 = [NSPredicate predicateWithFormat:@"phase != %d", NSTouchPhaseCancelled];
    
    NSPredicate *predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[p1, p2]];
    
    return [self.touchSet filteredSetUsingPredicate:predicate];
}

- (NSSet<TUCTouch *> *)activeTouchesForSourceIdentifier:(NSInteger)sourceIdentifier {
    NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(TUCTouch *touch, NSDictionary *bindings) {
        return touch.sourceIdentifier == sourceIdentifier && touch.isActive;
    }];
    return [self.touchSet filteredSetUsingPredicate:p];
}



- (CGFloat)distanceBetweenPoint:(CGPoint)p1 and:(CGPoint)p2 {
    CGFloat dx = p1.x - p2.x;
    CGFloat dy = p1.y - p2.y;
    
    return sqrt( pow(dx, 2) + pow(dy, 2) );
}


/**
 maxDistance in mm
 */
- (NSSet<TUCTouch *> *)touchesInProximityTo:(CGPoint)point maxDistance:(CGFloat)mmDistance sourceState:(TUCInputSourceState *)sourceState {
    
    TUCScreen *touchscreen = sourceState.cursorTouch.screen ?: [self touchscreen];
    CGFloat screenDistance = mmDistance * [touchscreen pixelsPerMM];
    CGPoint distance = CGPointMake(screenDistance /  touchscreen.frame.size.width,
                                   screenDistance /  touchscreen.frame.size.height);
    
    NSPredicate * predicate = [NSPredicate predicateWithBlock: ^BOOL(TUCTouch *t, NSDictionary *bind) {
        if (t.sourceIdentifier != sourceState.sourceIdentifier) {
            return NO;
        }
        
        CGFloat dx = [t location].x - point.x;
        CGFloat dy = [t location].y - point.y;
        
        return sqrt( pow(dx, 2) + pow(dy, 2) ) < distance.x;
    }];
    
    return [self.touchSet filteredSetUsingPredicate:predicate];
}


/**
 Removes a touch from the touch set. As a previous touch might be important for gesture evaluation, it is removed after half a second
 */
- (void)removeTouch:(TUCTouch *)touch now:(BOOL)instantDeletion{
//    if (touch.uuid == self.touchUsedForCursor.uuid) {
//        [self processTouchesForCursorInput];
//        self.touchUsedForCursor = nil;
//    }
    
    if (instantDeletion) {
        [[self touchSet] removeObject:touch];
        [[self delegate] touchesDidChange];
        return;
    }
    
    __weak id weakSelf = self;
    NSUUID *uuid = touch.uuid;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        for(TUCTouch *touch in [weakSelf touchSet]) {
            if (touch.uuid == uuid && [[weakSelf touchSet] containsObject:touch]) {
                [[weakSelf touchSet] removeObject:touch];
                [[weakSelf delegate] touchesDidChange];
                return;
            }
        }
    });
}

- (void)cancelTouchesForSourceIdentifier:(NSInteger)sourceIdentifier {
    NSArray<TUCTouch *> *touches = [self.touchSet allObjects];
    for (TUCTouch *touch in touches) {
        if (touch.sourceIdentifier == sourceIdentifier) {
            [touch setPhase:NSTouchPhaseCancelled];
            [self removeTouch:touch now:YES];
        }
    }
}


/**
 Checks the touch set if a touch exists
 */
- (TUCTouch *)findTouchWithID:(NSInteger)contactID includingPastTouches:(BOOL)includePastTouches {
    return [self findTouchWithID:contactID sourceIdentifier:0 includingPastTouches:includePastTouches];
}

- (TUCTouch *)findTouchWithID:(NSInteger)contactID sourceIdentifier:(NSInteger)sourceIdentifier includingPastTouches:(BOOL)includePastTouches {
    NSSet *set = includePastTouches ? self.touchSet : [self activeTouchesForSourceIdentifier:sourceIdentifier];
    
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(TUCTouch *touch, NSDictionary *bindings) {
        return touch.contactID == contactID && touch.sourceIdentifier == sourceIdentifier;
    }];
    TUCTouch *touch = [[set filteredSetUsingPredicate:predicate] anyObject];
    return touch;
}

/**
 Returns the existing touch object or a new one if this ID does not exist in the set yet.
 */
- (TUCTouch *)obtainTouchWithID:(NSInteger)contactID isNew:(BOOL*)isNew {
    return [self obtainTouchWithID:contactID sourceIdentifier:0 isNew:isNew];
}

- (TUCTouch *)obtainTouchWithID:(NSInteger)contactID sourceIdentifier:(NSInteger)sourceIdentifier isNew:(BOOL*)isNew {
    TUCTouch *touch = [self findTouchWithID:contactID sourceIdentifier:sourceIdentifier includingPastTouches:NO];
    *isNew = NO;
    if(!touch) {
        touch = [[TUCTouch alloc] initWithContactID:contactID sourceIdentifier:sourceIdentifier];
        [self.touchSet addObject:touch];
        *isNew = YES;
    }
    return touch;
}





#pragma mark - Screen Characteristics

/**
 the relative hardware points are always in the direction the digitizer is built in.
 If the display is rotated, we need to rotate these points
 */
- (CGPoint)convertDigitizerPointToRelativeScreenPoint:(CGPoint)devicePoint {
    return [self convertDigitizerPoint:devicePoint toRelativeScreenPointOnScreen:[self touchscreen]];
}

- (CGPoint)convertDigitizerPoint:(CGPoint)devicePoint toRelativeScreenPointOnScreen:(TUCScreen *)screen {
    CGFloat rotation = screen.rotation;
    if (rotation == 0) {
        return devicePoint;
        
    } else if (rotation == 180) {
        return CGPointMake(1 - devicePoint.x, 1 - devicePoint.y);
        
    } else if (rotation == 90) {
        return CGPointMake(1 - devicePoint.y, devicePoint.x);
        
    } else if (rotation == 270) {
        return CGPointMake(devicePoint.y, 1 - devicePoint.x);
    }
    
    return devicePoint;
}



- (CGPoint)convertScreenPointRelativeToAbsolute:(CGPoint)relativePoint {
    return [self convertScreenPointRelativeToAbsolute:relativePoint onScreen:[self touchscreen]];
}

- (CGPoint)convertScreenPointRelativeToAbsolute:(CGPoint)relativePoint onScreen:(TUCScreen *)screen {
    return [screen convertPointRelativeToAbsolute:relativePoint];
}



- (TUCScreen *)touchscreen {
    if (self.delegate != nil) {
        return [self.delegate touchscreen];
    }
    
    return [[TUCScreen allScreens] firstObject];
}

- (NSString *)normalizedDisplayMatchingString:(NSString *)string {
    NSMutableString *normalized = [NSMutableString string];
    NSString *lowercase = [string lowercaseString];
    NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < lowercase.length; i++) {
        unichar character = [lowercase characterAtIndex:i];
        if ([allowed characterIsMember:character]) {
            [normalized appendFormat:@"%C", character];
        }
    }
    return normalized;
}

- (TUCScreen *)screenMatchingTouchDeviceName:(NSString *)deviceName
                                     screens:(NSArray<TUCScreen *> *)screens
                         excludingDisplayIDs:(NSSet<NSNumber *> *)excludedDisplayIDs {
    NSString *normalizedDeviceName = [self normalizedDisplayMatchingString:deviceName];
    if (normalizedDeviceName.length < 4) return nil;

    for (TUCScreen *screen in screens) {
        if ([excludedDisplayIDs containsObject:@(screen.id)]) continue;

        NSString *normalizedScreenName = [self normalizedDisplayMatchingString:screen.name];
        if (normalizedScreenName.length < 4) continue;

        if ([normalizedScreenName containsString:normalizedDeviceName] ||
            [normalizedDeviceName containsString:normalizedScreenName]) {
            return screen;
        }
    }

    NSArray<NSString *> *tokens = [deviceName componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]];
    for (NSString *token in tokens) {
        NSString *normalizedToken = [self normalizedDisplayMatchingString:token];
        if (normalizedToken.length < 4) continue;

        for (TUCScreen *screen in screens) {
            if ([excludedDisplayIDs containsObject:@(screen.id)]) continue;

            NSString *normalizedScreenName = [self normalizedDisplayMatchingString:screen.name];
            if ([normalizedScreenName containsString:normalizedToken]) {
                return screen;
            }
        }
    }

    return nil;
}

- (TUCScreen *)screenWithDisplayID:(NSUInteger)displayID screens:(NSArray<TUCScreen *> *)screens {
    for (TUCScreen *screen in screens) {
        if (screen.id == displayID) {
            return screen;
        }
    }
    return nil;
}

- (TUCScreen *)screenForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice {
    NSArray<TUCScreen *> *screens = (NSArray<TUCScreen *> *)[TUCScreen allScreens];
    if (screens.count == 0) return nil;

    if (touchDevice.assignedDisplayID != 0) {
        TUCScreen *existingScreen = [self screenWithDisplayID:touchDevice.assignedDisplayID screens:screens];
        if (existingScreen) return existingScreen;
    }

    NSMutableSet<NSNumber *> *assignedDisplayIDs = [NSMutableSet set];
    for (TUCUSBHIDTouchDevice *otherDevice in [_hidTouchDevicesByRegistryID allValues]) {
        if (otherDevice != touchDevice && otherDevice.assignedDisplayID != 0) {
            [assignedDisplayIDs addObject:@(otherDevice.assignedDisplayID)];
        }
    }

    TUCScreen *nameMatch = [self screenMatchingTouchDeviceName:touchDevice.name
                                                       screens:screens
                                           excludingDisplayIDs:assignedDisplayIDs];
    if (nameMatch) {
        touchDevice.assignedDisplayID = nameMatch.id;
        NSLog(@"[TouchUp] HID: source=%ld name='%@' matched display '%@'",
              (long)touchDevice.sourceIdentifier,
              touchDevice.name,
              nameMatch.name);
        return nameMatch;
    }

    if (_hidTouchDevicesByRegistryID.count <= 1) {
        TUCScreen *preferred = [self touchscreen];
        if (preferred) {
            touchDevice.assignedDisplayID = preferred.id;
            NSLog(@"[TouchUp] HID: source=%ld name='%@' using preferred display '%@'",
                  (long)touchDevice.sourceIdentifier,
                  touchDevice.name,
                  preferred.name);
            return preferred;
        }
    }

    TUCScreen *preferred = [self touchscreen];
    if (preferred && ![assignedDisplayIDs containsObject:@(preferred.id)]) {
        touchDevice.assignedDisplayID = preferred.id;
        NSLog(@"[TouchUp] HID: source=%ld name='%@' using unassigned preferred display '%@'",
              (long)touchDevice.sourceIdentifier,
              touchDevice.name,
              preferred.name);
        return preferred;
    }

    for (TUCScreen *screen in screens) {
        if (![assignedDisplayIDs containsObject:@(screen.id)]) {
            touchDevice.assignedDisplayID = screen.id;
            NSLog(@"[TouchUp] HID: source=%ld name='%@' using next unassigned display '%@'",
                  (long)touchDevice.sourceIdentifier,
                  touchDevice.name,
                  screen.name);
            return screen;
        }
    }

    TUCScreen *fallback = preferred ?: [screens firstObject];
    touchDevice.assignedDisplayID = fallback.id;
    NSLog(@"[TouchUp] HID: source=%ld name='%@' using fallback display '%@'",
          (long)touchDevice.sourceIdentifier,
          touchDevice.name,
          fallback.name);
    return fallback;
}

- (TUCInputSourceState *)inputSourceStateForIdentifier:(NSInteger)sourceIdentifier {
    NSNumber *key = @(sourceIdentifier);
    TUCInputSourceState *sourceState = _inputSourceStatesByIdentifier[key];
    if (!sourceState) {
        sourceState = [TUCInputSourceState new];
        sourceState.sourceIdentifier = sourceIdentifier;
        sourceState.currentFrameID = 0;
        sourceState.identifiedMultitouchGesture = _TUCCursorGestureNone;
        _inputSourceStatesByIdentifier[key] = sourceState;
    }
    return sourceState;
}



- (BOOL)isPointInMenuBar:(CGPoint)point {
    return [self isPointInMenuBar:point onScreen:[self touchscreen]];
}

- (BOOL)isPointInMenuBar:(CGPoint)point onScreen:(TUCScreen *)screen {
    CGFloat menuBarHeight = [[[NSApplication sharedApplication] mainMenu] menuBarHeight];

    CGRect screenFrame = screen.frame;
    CGRect menuBarFrame = CGRectMake(screenFrame.origin.x,
                                     screenFrame.origin.y * -1,
                                     screenFrame.size.width,
                                     menuBarHeight);
    
    if (CGRectContainsPoint(menuBarFrame, point)) {
        return YES;
    }
    return NO;
}


- (BOOL)isLocationOutsideFrontmostWindow:(CGPoint)point {
    return [self isLocationOutsideFrontmostWindow:point onScreen:[self touchscreen]];
}

- (BOOL)isLocationOutsideFrontmostWindow:(CGPoint)point onScreen:(TUCScreen *)screen {
    
    if ([self isPointInMenuBar:point onScreen:screen]) {
        return NO;
    }
    
    pid_t frontmostPID = [[[NSWorkspace sharedWorkspace] frontmostApplication] processIdentifier];
    
    CFArrayRef array;
    array = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    
//    NSLog(@"%@", array);
    
    BOOL behindFrontmostWindow = NO;
    
    // propagate through window list the structure of this array is as follows:
    // [control center and menubar] [windows of frontmost app] [windows of other apps]
    // we have to insert a click to bring other windows to front, but not the menubar / control center stuff
    
    BOOL res = NO;
//    CFStringRef name = CFDictionaryGetValue(dic, kCGWindowOwnerPID);
    
    for (CFIndex i=0; i<CFArrayGetCount(array); i++) {
        CFDictionaryRef dic = CFArrayGetValueAtIndex(array, i);
        
        CFNumberRef numPid = CFDictionaryGetValue(dic, kCGWindowOwnerPID);
        pid_t currPID;
        CFNumberGetValue(numPid, kCFNumberIntType,  &currPID);
        BOOL isFrontmostApp = currPID == frontmostPID;
        
        // in fullscreen the app might also own the menu bar backgground window, so we need to test
        CFDictionaryRef bounds = CFDictionaryGetValue(dic, kCGWindowBounds);
        CGRect nextFrame;
        CGRectMakeWithDictionaryRepresentation(bounds, &nextFrame);
        BOOL isInside = CGRectContainsPoint(nextFrame, point);
        
        
        if (isFrontmostApp && !behindFrontmostWindow) {
            behindFrontmostWindow = YES;
        }
        
        
        
        if (isInside && !behindFrontmostWindow) {
            // operate without additional clicks
            res = NO;
            break;
        }
        
        else if (isInside && behindFrontmostWindow && !isFrontmostApp) {
            res = YES;
            break;
        }
        
    }
    
    CFRelease(array);
    return res;
}
        



#pragma mark -

- (instancetype)init {
    if(self = [super init]) {
        self.touchSet = [NSMutableSet new];
        self.postMouseEvents = YES;
        
        self.hidTouchDevicesByRegistryID = [NSMutableDictionary dictionary];
        self.inputSourceStatesByIdentifier = [NSMutableDictionary dictionary];
        self.nextTouchDeviceIdentifier = 1;
        
        self.doubleClickTolerance = 5;
        self.holdDuration = 0.08;
        self.errorResistance = 0;
        
        self.ignoreOriginTouches = NO;
    }
    return self;
}


- (NSString *)debugDescription {
    NSMutableString *str = [[NSString stringWithFormat:@"Touch Set contains %ld touches:{\n", [self.touchSet count]] mutableCopy];
    
    for (TUCTouch *touch in [[self.touchSet allObjects] sortedArrayUsingSelector:@selector(compareWithAnotherTouch:)] ) {
        [str appendString: [NSString stringWithFormat:@"  %@", [touch debugDescription]] ];
        BOOL isCursorTouch = NO;
        for (TUCInputSourceState *sourceState in [_inputSourceStatesByIdentifier allValues]) {
            if (sourceState.cursorTouch.uuid == touch.uuid) {
                isCursorTouch = YES;
                break;
            }
        }
        if (isCursorTouch) {
            [str appendString: @" <<<CURSOR>>>\n" ];
        } else {
            [str appendString: @"\n" ];
        }
    }
    
    [str appendString:@"}"];
    return str;
}

- (void)triggerSystemAccessibilityAccessAlert {
    CGPoint loc = [[TUCCursorUtilities sharedInstance] currentCursorLocation];
    [[TUCCursorUtilities sharedInstance] moveCursorTo:loc];
}

#pragma mark - Bridge calls of C Header to Objective-C

void TouchInputManagerUpdateTouchPosition(void *self, CFIndex contactID, CGFloat x, CGFloat y, Boolean onSurface, Boolean isValid) {
    CGPoint point = CGPointMake(x, y);
    [(__bridge id)self updateTouch:(NSInteger)contactID withLocation:point onSurface:onSurface tooLargeForFinger:isValid];
}

void TouchInputManagerUpdateTouchSize(void *self, CFIndex contactID, CGFloat width, CGFloat height, CGFloat azimuth) {
    CGSize size = CGSizeMake(width, height);
    [(__bridge id)self updateTouch:(NSInteger)contactID withSize:size azimuth:azimuth];
}

void TouchInputManagerDidProcessReport(void *self) {
    [(__bridge id)self didProcessReport];
}

void TouchInputManagerDidConnectTouchscreen(void *self) {
    [(__bridge id)self didConnectTouchscreen];
}

void TouchInputManagerDidDisconnectTouchscreen(void *self) {
    [(__bridge id)self didDisconnectTouchscreen];
}


@end
