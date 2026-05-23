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

@interface TUCTouchInputManager ()

// ─── IOKit HID device ─────────────────────────────────────────────────────
@property IONotificationPortRef usbNotificationPort;
@property io_iterator_t usbAppearedIterator;
@property io_iterator_t usbRemovedIterator;
@property (assign, nonatomic) IOHIDDeviceRef hidDeviceRef;
@property (strong) NSMutableData *hidReportBuffer;
@property CGFloat hidCurrentX;
@property CGFloat hidCurrentY;
@property BOOL hidCurrentButton;

@property NSInteger currentFrameID;

@property (weak, nullable) TUCTouch *cursorTouch;
@property (weak, nullable) TUCTouch *gestureAdditionalTouch;

@property BOOL cursorTouchQualifiedForTap; // if the cursor entered moving state once it can no longer be interpreted as tap
@property BOOL cursorTouchDidHold; //
@property (strong) NSDate *cursorTouchStationarySinceDate;

@property CGFloat pinchDistance;

@property TUCCursorGesture identifiedMultitouchGesture;

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
    TUCTouchInputManager *mgr = (__bridge TUCTouchInputManager *)ctx;
    IOHIDElementRef elem = IOHIDValueGetElement(value);
    uint32_t up   = IOHIDElementGetUsagePage(elem);
    uint32_t u    = IOHIDElementGetUsage(elem);
    CFIndex  val  = IOHIDValueGetIntegerValue(value);
    CFIndex  lMin = IOHIDElementGetLogicalMin(elem);
    CFIndex  lMax = IOHIDElementGetLogicalMax(elem);
    if (lMax <= lMin) return;

    if (up == 0x01 && u == 0x30) {         // Generic Desktop X
        mgr.hidCurrentX = (CGFloat)(val - lMin) / (CGFloat)(lMax - lMin);
    } else if (up == 0x01 && u == 0x31) {  // Generic Desktop Y
        mgr.hidCurrentY = (CGFloat)(val - lMin) / (CGFloat)(lMax - lMin);
    } else if ((up == 0x09 && u == 0x01) || (up == 0x0D && u == 0x42)) {
        mgr.hidCurrentButton = (val != 0);  // Button 1 or Tip Switch
    }
}

// Report callback fires once per complete HID report, after all value callbacks for that report.
static void hidReportCallback(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                              uint32_t reportID, uint8_t *report, CFIndex len) {
    if (result != kIOReturnSuccess || len <= 0) return;
    [(__bridge TUCTouchInputManager *)ctx processHIDValues];
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
    if (_hidDeviceRef) {
        IOHIDDeviceUnscheduleFromRunLoop(_hidDeviceRef, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDDeviceClose(_hidDeviceRef, kIOHIDOptionsTypeNone);
        CFRelease(_hidDeviceRef);
        _hidDeviceRef = NULL;
    }
    _hidReportBuffer = nil;

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
            if (_hidDeviceRef && IOObjectIsEqualTo(IOHIDDeviceGetService(_hidDeviceRef), service)) {
                IOHIDDeviceUnscheduleFromRunLoop(_hidDeviceRef, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
                IOHIDDeviceClose(_hidDeviceRef, kIOHIDOptionsTypeNone);
                CFRelease(_hidDeviceRef);
                _hidDeviceRef = NULL;
                _hidReportBuffer = nil;
                TouchInputManagerDidDisconnectTouchscreen((__bridge void *)self);
            }
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

    [self openIOHIDDevice:hidDevice];
}

// Open the IOHIDDevice for shared (non-exclusive) input report access.
// For digitizer devices (usage page 0x0D), this does not trigger the Input Monitoring TCC prompt.
// Element value callbacks update X/Y/button state; report callback fires once per complete report.
- (void)openIOHIDDevice:(io_service_t)hidService {
    if (_hidDeviceRef) return;

    IOHIDDeviceRef device = IOHIDDeviceCreate(kCFAllocatorDefault, hidService);
    if (!device) {
        NSLog(@"[TouchUp] HID: IOHIDDeviceCreate failed");
        return;
    }

    IOReturn ret = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    if (ret != kIOReturnSuccess) {
        NSLog(@"[TouchUp] HID: IOHIDDeviceOpen failed: 0x%08x", ret);
        CFRelease(device);
        return;
    }

    // 512 bytes covers all USB HID reports (USB full-speed max is 64, but some devices use more)
    NSUInteger bufSize = 512;
    _hidReportBuffer = [NSMutableData dataWithLength:bufSize];

    IOHIDDeviceRegisterInputValueCallback(device, hidValueCallback, (__bridge void *)self);
    IOHIDDeviceRegisterInputReportCallback(device, _hidReportBuffer.mutableBytes,
                                           (CFIndex)bufSize, hidReportCallback, (__bridge void *)self);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    _hidDeviceRef = device; // owned — caller of IOHIDDeviceCreate holds the only reference

    TouchInputManagerDidConnectTouchscreen((__bridge void *)self);
    NSLog(@"[TouchUp] HID: device opened, listening for reports");
}

- (void)processHIDValues {
    CGFloat x = MAX(0.0, MIN(1.0, _hidCurrentX));
    CGFloat y = MAX(0.0, MIN(1.0, _hidCurrentY));
    TouchInputManagerUpdateTouchPosition((__bridge void *)self, 0, x, y, (Boolean)_hidCurrentButton, 1);
    TouchInputManagerDidProcessReport((__bridge void *)self);
}

- (void)didConnectTouchscreen {
    [self.delegate touchscreenDidConnect];
}

- (void)didDisconnectTouchscreen {
    [self.delegate touchscreenDidDisconnect];
}





#pragma mark - Reacting to HID Events

- (void)didProcessReport {
    // go through all touches: if the frame is not the latest one, the touch might be old and should be removed.
    
    for (TUCTouch *touch in self.touchSet) {
        
        if (touch.lastUpdated + self.errorResistance < self.currentFrameID) {
            [touch setPhase:NSTouchPhaseCancelled];
            [self removeTouch:touch now:NO];
        }
    }
    
    if ([[self activeTouches] count] == 0) {
        [self stopCurrentGesture];
    }
    
    ++self.currentFrameID;
    
    [self processTouchesForCursorInput];
    
}


- (void)stopCurrentGesture {
    [[TUCCursorUtilities sharedInstance] stopDraggingCursor];
    [[TUCCursorUtilities sharedInstance] stopMagnifying];

    self.identifiedMultitouchGesture = _TUCCursorGestureNone;
}



/**
 Most important event handling callback: it posts the events to the system where the touches need to go
 */
- (void)updateTouch:(NSInteger)contactID withLocation:(CGPoint)digitizerPoint onSurface:(BOOL)isOnSurface tooLargeForFinger:(BOOL)confidenceFlag {
    
    // assume that this is an erroneous message!!!
    if (self.ignoreOriginTouches && CGPointEqualToPoint(digitizerPoint, CGPointZero)) {
        return;
    }
    
    CGPoint point = [self convertDigitizerPointToRelativeScreenPoint:digitizerPoint];
    
    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID isNew:&isNewTouch];
    
    if (isNewTouch && (self.cursorTouch == nil || !self.cursorTouch.isActive)) {
        self.cursorTouch = touch;
        self.cursorTouchQualifiedForTap = YES;
        self.cursorTouchDidHold = NO;
        self.cursorTouchStationarySinceDate = nil;
    }
    
    [touch setLocation: point];
    [touch setIsOnSurface:isOnSurface];
    [touch setConfidenceFlag:confidenceFlag];
    [touch setLastUpdated:self.currentFrameID];
    
    if (!isOnSurface) {
        [touch setPhase: NSTouchPhaseEnded];
        [self removeTouch:touch now:NO];
        [self.delegate touchesDidChange];
        return;
        
    }
    
    if(touch.previousPhase != NSTouchPhaseEnded && !isNewTouch) {
        // update to an existing touch... check if stationary or not
        CGFloat digitizerRelDistance = sqrt(pow(touch.location.x - touch.previousLocation.x, 2) + pow(touch.location.y - touch.previousLocation.y, 2));
        CGFloat screenSize = [self touchscreen].physicalSize.width;
        BOOL isStationary = (digitizerRelDistance * screenSize) < 0.1;
//        BOOL isStationary = CGPointEqualToPoint(touch.location, touch.previousLocation);
        
        if (touch.uuid == self.cursorTouch.uuid) {
            if (!isStationary) {
                self.cursorTouchQualifiedForTap = NO;
                self.cursorTouchStationarySinceDate = nil;
                
            } else if (touch.phase !=  NSTouchPhaseStationary) {
                self.cursorTouchStationarySinceDate = [NSDate date];
            }
        }
        
        [touch setPhase:isStationary ? NSTouchPhaseStationary : NSTouchPhaseMoved];
    }
    
    
    [self.delegate touchesDidChange];
    
    return;
}


- (void)updateTouch:(NSInteger)contactID withSize:(CGSize)size azimuth:(CGFloat)azimuth {
    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID isNew:&isNewTouch];
    [touch setLastUpdated:self.currentFrameID];
    
    [touch setSize:size];
    [touch setAzimuth:azimuth];
}



#pragma mark - Mouse Cursor Management



- (void)processTouchesForCursorInput {
    
    if(!self.cursorTouch || !self.postMouseEvents) {
        return;
    }
    
    TUCTouch *cursorTouch = self.cursorTouch;
    
    
    NSArray<TUCTouch *> *touches = [[self activeTouches] allObjects];
    NSTouchPhase phase = cursorTouch.phase;
    
    
    if (phase == NSTouchPhaseBegan) {
        if (self.restoresCursorPositionAfterTouch) {
            [[TUCCursorUtilities sharedInstance] saveCursorPosition];
        }
        [self performMouseEventForGesture:TUCCursorGestureTouchDown];
        return;
    }
    
    
    else if (phase == NSTouchPhaseStationary) {
        NSTimeInterval holdDuration = 0;
        if (self.cursorTouchStationarySinceDate != nil) {
            holdDuration = [[NSDate date] timeIntervalSinceDate:self.cursorTouchStationarySinceDate];
        }
        if (self.cursorTouchQualifiedForTap && holdDuration > self.holdDuration) {
            // the user left the finger on the screen for the min duration required to produce a hold
            self.cursorTouchDidHold = YES;
        }
        
        [self checkForSecondaryClick];
        
        return;
    }
    
    
    else if (phase == NSTouchPhaseEnded) {
        if (self.identifiedMultitouchGesture == _TUCCursorGestureNone ) {
            if (self.cursorTouchDidHold) {
                [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
            } else if (!self.cursorTouchQualifiedForTap) {
                [self performMouseEventForGesture:TUCCursorGestureDrag];
            }
        }

        [self stopCurrentGesture];

        if (self.cursorTouchQualifiedForTap) {
            [self performMouseEventForGesture:TUCCursorGestureTap];
        } else {
            if (self.identifiedMultitouchGesture != _TUCCursorGestureNone) {
                [self performMouseEventForGesture:self.identifiedMultitouchGesture];
            }
        }

        if (self.restoresCursorPositionAfterTouch && !self.cursorTouchDidHold) {
            [[TUCCursorUtilities sharedInstance] restoreCursorPosition];
        }

        return;
    }
    
    
    else if (phase == NSTouchPhaseCancelled) {
        [self stopCurrentGesture];
        return;
    }
    
    if ([self checkForSecondaryClick]) {
        return;
    }
    
    if ([touches count] == 2 && [touches containsObject: cursorTouch]) {
        // check if we need to initiate two finger drag, pinch, ...
        if (self.identifiedMultitouchGesture == _TUCCursorGestureNone ) {

            TUCTouch *otherTouch = touches[1];
            if (otherTouch.uuid == cursorTouch.uuid) {
                otherTouch = touches[0];
            }
            
            self.gestureAdditionalTouch = otherTouch;
            
            if (self.gestureAdditionalTouch.isActive) {
                CGPoint trajectoryA = [cursorTouch trajectorySign];
                CGPoint trajectoryB = [otherTouch trajectorySign];
                
                
                if (   !CGPointEqualToPoint(trajectoryA, CGPointZero)
                    && !CGPointEqualToPoint(trajectoryB, CGPointZero)) {
                    
                    if (!CGPointEqualToPoint(trajectoryA, trajectoryB)) {
                        self.identifiedMultitouchGesture = TUCCursorGesturePinch;
                    } else {
                        self.identifiedMultitouchGesture = TUCCursorGestureTwoFingerDrag;
                    }
                }
                
            } else {
                // secondary click
                [self removeTouch:self.gestureAdditionalTouch now:YES];
                self.gestureAdditionalTouch = nil;
                [self performMouseEventForGesture:TUCCursorGestureTapSecondFinger];
            }
        }
        
        // other finger lifted, gesture ended
        if (!self.gestureAdditionalTouch.isActive) {
            [self stopCurrentGesture];
        }
        
        
        if(self.identifiedMultitouchGesture != _TUCCursorGestureNone) {
            [self performMouseEventForGesture:self.identifiedMultitouchGesture];
            return;
        }
        
    }
    

    if (self.cursorTouchDidHold) {
        [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
    } else {
        [self performMouseEventForGesture:TUCCursorGestureDrag];
    }
}


- (BOOL)checkForSecondaryClick {
//    if (self.identifiedMultitouchGesture != _TUCCursorGestureNone) {
//        return NO;
//    }
    
    NSSet<TUCTouch *> *touchesInProximity = [self touchesInProximityTo:self.cursorTouch.location maxDistance:60];
    if (touchesInProximity.count >= 2 && self.identifiedMultitouchGesture == _TUCCursorGestureNone) {

        // TUCCursorGestureTwoFingerTap
        NSPredicate *p1 = [NSPredicate predicateWithFormat:@"phase == %d", NSTouchPhaseEnded];
        NSPredicate *p2 = [NSPredicate predicateWithFormat:@"phase == %d", NSTouchPhaseCancelled];

        NSPredicate *p3 = [NSPredicate predicateWithFormat:@"contactID != %d", self.cursorTouch.contactID];

        NSPredicate *p4 = [NSCompoundPredicate orPredicateWithSubpredicates:@[p1, p2]];
        NSPredicate *p5 = [NSCompoundPredicate andPredicateWithSubpredicates:@[p3, p4]];

        NSSet<TUCTouch *> *endedTouches = [touchesInProximity filteredSetUsingPredicate:p5];

        if (endedTouches.count == 1) {
            for (TUCTouch* touchToRemove in endedTouches) {
                [self removeTouch:touchToRemove now:YES];
            }

            [self performMouseEventForGesture:TUCCursorGestureTapSecondFinger];
            return YES;
        }
    }
    return NO;
}


- (void)performMouseEventForGesture:(TUCCursorGesture)gesture {
    TUCTouch *touch = self.cursorTouch;

    TUCScreen *ts = [self touchscreen];
    CGPoint screenLocation = [self convertScreenPointRelativeToAbsolute:touch.location];
    CGPoint location2ndFinger = [self convertScreenPointRelativeToAbsolute:self.gestureAdditionalTouch.location];

    NSLog(@"[TouchUp] screen='%@' frame={{%.0f,%.0f},{%.0f,%.0f}} relTouch=(%.3f,%.3f) absTouch=(%.0f,%.0f)",
          ts.name,
          ts.frame.origin.x, ts.frame.origin.y,
          ts.frame.size.width, ts.frame.size.height,
          touch.location.x, touch.location.y,
          screenLocation.x, screenLocation.y);
    
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    
    TUCCursorAction action = [self actionForGesture:gesture];
    
    CGFloat doubleClickSpan = self.doubleClickTolerance * [[self touchscreen] pixelsPerMM];
    [[TUCCursorUtilities sharedInstance] setDoubleClickTolerance:doubleClickSpan];
    
    switch (action) {
        case TUCCursorActionNone:
            break;
            
        case TUCCursorActionMove:
            [utils moveCursorTo:screenLocation];
            break;
            
        case TUCCursorActionMoveClickIfNeeded:
            [utils moveCursorTo:screenLocation];
            if ([self isLocationOutsideFrontmostWindow:screenLocation]) {
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
            CGPoint prevLocation = [self convertScreenPointRelativeToAbsolute:touch.previousLocation];
            CGPoint translation = CGPointMake(screenLocation.x - prevLocation.x,
                                              screenLocation.y - prevLocation.y);
            [utils scroll:translation phase:touch.phase];
            
            break; }
            
        case TUCCursorActionMagnify:
            [utils magnifyLocationA:screenLocation
                          locationB:location2ndFinger
            relativeP1:self.cursorTouch.location relP2:self.gestureAdditionalTouch.location];
            
            if (touch.phase == NSTouchPhaseEnded || self.gestureAdditionalTouch.phase == NSTouchPhaseEnded) {
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



- (CGFloat)distanceBetweenPoint:(CGPoint)p1 and:(CGPoint)p2 {
    CGFloat dx = p1.x - p2.x;
    CGFloat dy = p1.y - p2.y;
    
    return sqrt( pow(dx, 2) + pow(dy, 2) );
}


/**
 maxDistance in mm
 */
- (NSSet<TUCTouch *> *)touchesInProximityTo:(CGPoint)point maxDistance:(CGFloat)mmDistance {
    
    CGFloat screenDistance = mmDistance * [[self touchscreen] pixelsPerMM];
    CGPoint distance = CGPointMake(screenDistance /  [self touchscreen].frame.size.width,
                                   screenDistance /  [self touchscreen].frame.size.height);
    
    NSPredicate * predicate = [NSPredicate predicateWithBlock: ^BOOL(TUCTouch *t, NSDictionary *bind) {
        
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


/**
 Checks the touch set if a touch exists
 */
- (TUCTouch *)findTouchWithID:(NSInteger)contactID includingPastTouches:(BOOL)includePastTouches {
    NSSet *set = includePastTouches ? self.touchSet : [self activeTouches];
    
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"contactID == %d", contactID];
    TUCTouch *touch = [[set filteredSetUsingPredicate:predicate] anyObject];
    return touch;
}

/**
 Returns the existing touch object or a new one if this ID does not exist in the set yet.
 */
- (TUCTouch *)obtainTouchWithID:(NSInteger)contactID isNew:(BOOL*)isNew {
    TUCTouch *touch = [self findTouchWithID:contactID includingPastTouches:NO];
    *isNew = NO;
    if(!touch) {
        touch = [[TUCTouch alloc] initWithContactID:contactID];
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
    CGFloat rotation = [self touchscreen].rotation;
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
    return [[self touchscreen] convertPointRelativeToAbsolute:relativePoint];
}



- (TUCScreen *)touchscreen {
    if (self.delegate != nil) {
        return [self.delegate touchscreen];
    }
    
    return [[TUCScreen allScreens] firstObject];
}



- (BOOL)isPointInMenuBar:(CGPoint)point {
    CGFloat menuBarHeight = [[[NSApplication sharedApplication] mainMenu] menuBarHeight];

    CGRect screenFrame = [self touchscreen].frame;
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
    
    if ([self isPointInMenuBar:point]) {
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
        
        self.cursorTouchQualifiedForTap = NO;
        self.cursorTouchStationarySinceDate = nil;
        
        self.currentFrameID = 0;
        self.identifiedMultitouchGesture = _TUCCursorGestureNone;
        
        self.doubleClickTolerance = 5;
        self.holdDuration = 0.08;
        self.errorResistance = 0;
        
        self.ignoreOriginTouches = NO;
        self.restoresCursorPositionAfterTouch = NO;
    }
    return self;
}


- (NSString *)debugDescription {
    NSMutableString *str = [[NSString stringWithFormat:@"Touch Set contains %ld touches:{\n", [self.touchSet count]] mutableCopy];
    
    for (TUCTouch *touch in [[self.touchSet allObjects] sortedArrayUsingSelector:@selector(compareWithAnotherTouch:)] ) {
        [str appendString: [NSString stringWithFormat:@"  %@", [touch debugDescription]] ];
        if (touch.contactID == self.cursorTouch.contactID) {
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
