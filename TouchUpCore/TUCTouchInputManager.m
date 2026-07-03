//
//  TUCTouchInputManager.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import "TUCTouchInputManager.h"

#import "HIDInterpreter.h"
#import "TUCTouchDisplayAssignmentResolver.h"
#import "TUCCursorUtilities.h"
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hid/IOHIDElement.h>
#import <IOKit/hidsystem/IOHIDLib.h>

@class TUCTouchInputManager;

typedef NS_ENUM(NSInteger, TUCWindowsGestureKind) {
    TUCWindowsGestureKindIdle,
    TUCWindowsGestureKindOneFingerPending,
    TUCWindowsGestureKindOneFingerMove,
    TUCWindowsGestureKindWindowMove,
    TUCWindowsGestureKindRightButtonDown,
    TUCWindowsGestureKindTwoFingerPending,
    TUCWindowsGestureKindTwoFingerScroll,
    TUCWindowsGestureKindPinch,
    TUCWindowsGestureKindSuppressUntilAllLifted
};

@interface TUCInputSourceState : NSObject

@property NSInteger sourceIdentifier;
@property NSInteger currentFrameID;

@property TUCWindowsGestureKind activeGesture;
@property NSInteger primaryContactID;
@property NSInteger secondaryContactID;
@property (strong, nullable) NSDate *gestureStartDate;
@property CGPoint primaryStartLocation;
@property CGPoint secondaryStartLocation;
@property CGPoint lastPrimaryLocation;
@property CGPoint lastSecondaryLocation;
@property CGPoint lastCentroid;
@property CGFloat initialTwoFingerDistance;
@property CGFloat lastTwoFingerDistance;
@property BOOL tapCandidate;
@property BOOL windowMoveCandidate;
@property CGPoint windowMoveStartScreenLocation;
@property NSInteger windowMoveWindowNumber;
@property BOOL rightButtonIsDown;
@property BOOL suppressClickUntilAllLifted;

@end

@implementation TUCInputSourceState

- (instancetype)init {
    if (self = [super init]) {
        _activeGesture = TUCWindowsGestureKindIdle;
        _primaryContactID = NSNotFound;
        _secondaryContactID = NSNotFound;
        _windowMoveWindowNumber = NSNotFound;
    }
    return self;
}

@end

@interface TUCUSBHIDTouchContact : NSObject

@property NSInteger fallbackContactID;
@property NSInteger contactID;
@property BOOL contactIDWasReported;
@property BOOL isDigitizerContact;
@property BOOL enabled;

@property BOOL supportsX;
@property BOOL supportsY;
@property BOOL supportsSurfaceState;
@property BOOL supportsValidityState;
@property BOOL supportsContactID;

@property (assign, nonatomic, nullable) IOHIDElementRef xElement;
@property (assign, nonatomic, nullable) IOHIDElementRef yElement;
@property (assign, nonatomic, nullable) IOHIDElementRef surfaceElement;
@property (assign, nonatomic, nullable) IOHIDElementRef validityElement;
@property (assign, nonatomic, nullable) IOHIDElementRef contactIDElement;

@property BOOL hasCurrentX;
@property BOOL hasCurrentY;
@property CGFloat x;
@property CGFloat y;
@property BOOL isOnSurface;
@property BOOL isValid;
@property BOOL wasDispatchedOnSurface;

@end

@implementation TUCUSBHIDTouchContact

- (instancetype)init {
    if (self = [super init]) {
        _fallbackContactID = NSNotFound;
        _contactID = NSNotFound;
        _isValid = YES;
    }
    return self;
}

@end

@interface TUCUSBHIDTouchDevice : NSObject

@property (weak, nullable) TUCTouchInputManager *manager;
@property NSInteger sourceIdentifier;
@property uint64_t registryID;
@property NSUInteger assignedDisplayID;
@property NSInteger vendorID;
@property NSInteger productID;
@property (copy) NSString *name;
@property (strong) NSDate *connectedDate;
@property TUCTouchDisplayAssignmentReason assignmentReason;
@property TUCTouchDisplayAssignmentConfidence assignmentConfidence;

@property (assign, nonatomic) IOHIDDeviceRef hidDeviceRef;
@property (strong) NSMutableData *hidReportBuffer;
@property BOOL hidDispatchPending;
@property BOOL loggedFirstHIDReport;
@property BOOL loggedFirstHIDContactState;
@property BOOL loggedFirstTouchDispatch;
@property BOOL loggedMissingHIDPosition;
@property BOOL usesRawReportFallback;
@property BOOL rawReportContactActive;
@property BOOL loggedFirstRawReportDispatch;
@property NSUInteger rawReportDispatchGeneration;
@property CGPoint lastRawReportPoint;
@property BOOL requiresTCCAuthorization;
@property (strong) NSMutableDictionary<NSValue *, TUCUSBHIDTouchContact *> *hidContactsByCollection;
@property (strong) NSMutableArray<TUCUSBHIDTouchContact *> *hidContacts;

- (void)close;

@end

@implementation TUCUSBHIDTouchDevice

- (instancetype)init {
    if (self = [super init]) {
        _hidContactsByCollection = [NSMutableDictionary dictionary];
        _hidContacts = [NSMutableArray array];
    }
    return self;
}

- (void)close {
    if (_hidDeviceRef) {
        IOHIDDeviceUnscheduleFromRunLoop(_hidDeviceRef, CFRunLoopGetMain(), kCFRunLoopCommonModes);
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

@implementation TUCTouchCalibration

+ (instancetype)identityCalibration {
    TUCTouchCalibration *calibration = [TUCTouchCalibration new];
    calibration.enabled = NO;
    calibration.xOffset = 0;
    calibration.yOffset = 0;
    calibration.xScale = 1;
    calibration.yScale = 1;
    calibration.xSkew = 0;
    calibration.ySkew = 0;
    return calibration;
}

- (instancetype)init {
    if (self = [super init]) {
        _enabled = NO;
        _xOffset = 0;
        _yOffset = 0;
        _xScale = 1;
        _yScale = 1;
        _xSkew = 0;
        _ySkew = 0;
    }
    return self;
}

- (CGPoint)applyToPoint:(CGPoint)point {
    if (!self.enabled) {
        return point;
    }

    CGFloat calibratedX = point.x * self.xScale + point.y * self.xSkew + self.xOffset;
    CGFloat calibratedY = point.y * self.yScale + point.x * self.ySkew + self.yOffset;

    calibratedX = MAX(0.0, MIN(1.0, calibratedX));
    calibratedY = MAX(0.0, MIN(1.0, calibratedY));

    return CGPointMake(calibratedX, calibratedY);
}

@end

@interface TUCTouchInputManager ()

// ─── IOKit HID device ─────────────────────────────────────────────────────
@property IONotificationPortRef usbNotificationPort;
@property io_iterator_t usbAppearedIterator;
@property io_iterator_t usbRemovedIterator;
@property (strong) NSMutableDictionary<NSNumber *, TUCUSBHIDTouchDevice *> *hidTouchDevicesByRegistryID;
@property (strong) NSMutableDictionary<NSNumber *, TUCInputSourceState *> *inputSourceStatesByIdentifier;
@property (strong) TUCTouchDisplayAssignmentResolver *displayAssignmentResolver;
@property (strong) NSMutableDictionary<NSNumber *, NSNumber *> *learnedDisplayIDsBySourceIdentifier;
@property (strong) NSMutableDictionary<NSString *, NSNumber *> *learnedDisplayIDsByStableIdentifier;
@property (strong, nullable) NSSet<NSNumber *> *knownDisplayIDs;
@property (strong) NSMutableArray<NSNumber *> *pendingHotPlugDisplayIDs;
@property (strong) NSMutableArray<NSNumber *> *pendingHotPlugTouchRegistryIDs;
@property (strong) NSMutableDictionary<NSNumber *, NSDate *> *pendingHotPlugDisplayDatesByID;
@property (strong) NSMutableDictionary<NSNumber *, NSNumber *> *hotPlugDisplayIDsByRegistryID;
@property (strong) NSMutableSet<NSString *> *knownTouchStableIdentifiers;
@property (strong) NSMutableDictionary<NSString *, NSNumber *> *sessionDisplayIDsByStableIdentifier;
@property (strong) NSMutableDictionary<NSString *, NSNumber *> *sessionAssignmentConfidencesByStableIdentifier;
@property NSInteger nextTouchDeviceIdentifier;

- (BOOL)configureTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice
             fromIOHIDDevice:(IOHIDDeviceRef)device
     requiresAbsolutePointer:(BOOL)requiresAbsolutePointer;
- (TUCUSBHIDTouchContact *)contactForHIDElement:(IOHIDElementRef)element
                                    touchDevice:(TUCUSBHIDTouchDevice *)touchDevice
                                         create:(BOOL)create;
- (void)scheduleProcessHIDValuesForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice;
- (void)processHIDValuesForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice;
- (void)refreshHIDContact:(TUCUSBHIDTouchContact *)contact touchDevice:(TUCUSBHIDTouchDevice *)touchDevice;
- (BOOL)processRawHIDReportForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice
                                  reportID:(uint32_t)reportID
                                    report:(uint8_t *)report
                                    length:(CFIndex)len;
- (void)scheduleRawReportLiftForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice
                                  contactID:(NSInteger)contactID
                                     screen:(TUCScreen *)screen;
- (nullable TUCUSBHIDTouchContact *)primaryEnabledContactForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice;
- (void)removeHIDDeviceForService:(io_service_t)hidService;
- (TUCScreen *)screenForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice;
- (TUCScreen *)screenForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice screens:(NSArray<TUCScreen *> *)screens;
- (void)refreshScreenTopologySignalsWithScreens:(NSArray<TUCScreen *> *)screens;
- (NSArray<TUCTouchDeviceDescriptor *> *)touchDeviceDescriptorsIncludingTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice;
- (NSArray<TUCScreenDescriptor *> *)screenDescriptorsForScreens:(NSArray<TUCScreen *> *)screens;
- (NSDictionary<NSNumber *, NSNumber *> *)hotPlugDisplayIDsByRegistryIDForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice;
- (void)recordTouchDeviceForAutomaticPairing:(TUCUSBHIDTouchDevice *)touchDevice;
- (void)restoreSessionAssignmentForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice;
- (void)pairPendingAutomaticAssignments;
- (void)pruneExpiredAutomaticAssignmentSignals;
- (NSString *)stableIdentifierForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice;
- (void)loadLearnedDisplayAssignments;
- (void)persistLearnedDisplayAssignments;
- (TUCInputSourceState *)inputSourceStateForIdentifier:(NSInteger)sourceIdentifier;
- (void)didProcessReportForSourceIdentifier:(NSInteger)sourceIdentifier;
- (void)cancelTouchesForSourceIdentifier:(NSInteger)sourceIdentifier;
- (void)processTouchesForCursorInputForSourceState:(TUCInputSourceState *)sourceState;
- (NSArray<TUCTouch *> *)activeTouchesSortedForSourceIdentifier:(NSInteger)sourceIdentifier;
- (NSArray<TUCTouch *> *)endedTouchesSortedForSourceIdentifier:(NSInteger)sourceIdentifier;
- (nullable TUCTouch *)activeTouchWithContactID:(NSInteger)contactID sourceIdentifier:(NSInteger)sourceIdentifier;
- (nullable TUCTouch *)touchWithContactID:(NSInteger)contactID inTouches:(NSArray<TUCTouch *> *)touches;
- (CGFloat)distanceInMMFrom:(CGPoint)a to:(CGPoint)b onScreen:(TUCScreen *)screen;
- (CGPoint)absoluteLocationForTouch:(TUCTouch *)touch;
- (CGPoint)applyCalibrationToPoint:(CGPoint)point onScreen:(TUCScreen *)screen;
- (TUCTouchCalibration *)calibrationForScreen:(TUCScreen *)screen;
- (CGPoint)centroidForTouch:(TUCTouch *)a otherTouch:(TUCTouch *)b;
- (CGFloat)relativeDistanceBetweenTouch:(TUCTouch *)a otherTouch:(TUCTouch *)b;
- (BOOL)isPointInDraggableWindowArea:(CGPoint)screenPoint onScreen:(TUCScreen *)screen;
- (BOOL)isPointInApproximateTitlebar:(CGPoint)screenPoint windowBounds:(CGRect)windowBounds;
- (void)resetWindowsGestureForSourceState:(TUCInputSourceState *)sourceState endingButtons:(BOOL)endingButtons;
- (void)resetAllWindowsGesturesEndingButtons:(BOOL)endingButtons;

@end


@implementation TUCTouchInputManager

static const uint32_t TUC_HID_USAGE_DIG_FINGER = 0x22;
static const uint32_t TUC_HID_USAGE_DIG_TOUCHSCREEN = 0x04;
static const CGFloat TUCTapMaxMovementMM = 4.0;
static const CGFloat TUCMoveStartThresholdMM = 1.5;
static const CGFloat TUCHoldMaxMovementMM = 3.0;
static const CGFloat TUCWindowMoveStartThresholdMM = 1.5;
static const CGFloat TUCScrollStartThresholdMM = 1.5;
static const CGFloat TUCPinchStartScaleDelta = 0.04;
static const CGFloat TUCScrollPinchSuppressScaleDelta = 0.03;
static const NSTimeInterval TUCDefaultHoldDuration = 0.55;
static const NSTimeInterval TUCDisplayHotPlugCorrelationInterval = 120.0;
static const NSTimeInterval TUCPreDisplayTouchCorrelationGrace = 2.0;
static const NSTimeInterval TUCRawReportLiftTimeout = 0.20;
static NSString * const TUCLearnedDisplayAssignmentsDefaultsKey = @"TUCTouchDisplayAssignmentsByStableIdentifier.v1";

static NSString *TUCNormalizedStableIdentifierComponent(NSString *string) {
    NSMutableString *normalized = [NSMutableString string];
    NSString *lowercase = [string lowercaseString];
    NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
    BOOL previousWasSeparator = NO;

    for (NSUInteger i = 0; i < lowercase.length; i++) {
        unichar character = [lowercase characterAtIndex:i];
        if ([allowed characterIsMember:character]) {
            [normalized appendFormat:@"%C", character];
            previousWasSeparator = NO;
        } else if (!previousWasSeparator && normalized.length > 0) {
            [normalized appendString:@"-"];
            previousWasSeparator = YES;
        }
    }

    if ([normalized hasSuffix:@"-"]) {
        [normalized deleteCharactersInRange:NSMakeRange(normalized.length - 1, 1)];
    }

    return normalized;
}

static BOOL TUCShouldUseSISRawReportFallback(TUCUSBHIDTouchDevice *touchDevice) {
    return touchDevice.vendorID == 1111 &&
           touchDevice.productID == 2073 &&
           [touchDevice.name rangeOfString:@"sis" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static CGFloat TUCNormalizedSISRawCoordinate(uint16_t rawValue, IOHIDElementRef element) {
    CFIndex logicalMin = 0;
    CFIndex logicalMax = 4095;

    if (element) {
        CFIndex elementMin = IOHIDElementGetLogicalMin(element);
        CFIndex elementMax = IOHIDElementGetLogicalMax(element);
        if (elementMax > elementMin &&
            elementMax <= 8191 &&
            rawValue <= elementMax) {
            logicalMin = elementMin;
            logicalMax = elementMax;
        }
    }

    CGFloat normalized = ((CGFloat)rawValue - (CGFloat)logicalMin) / (CGFloat)(logicalMax - logicalMin);
    return MAX(0.0, MIN(1.0, normalized));
}

static BOOL TUCIsTouchSurfaceUsage(uint32_t page, uint32_t usage) {
    return (page == kHIDPage_Button && usage == 1) ||
           (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_TipSwitch) ||
           (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_Touch) ||
           (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_SurfaceSwitch);
}

static BOOL TUCIsTouchValidityUsage(uint32_t page, uint32_t usage) {
    return (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_TouchValid) ||
           (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_DataValid);
}

static BOOL TUCIsTouchXUsage(uint32_t page, uint32_t usage) {
    return page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_X;
}

static BOOL TUCIsTouchYUsage(uint32_t page, uint32_t usage) {
    return page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Y;
}

static BOOL TUCIsTouchPositionUsage(uint32_t page, uint32_t usage) {
    return TUCIsTouchXUsage(page, usage) || TUCIsTouchYUsage(page, usage);
}

static BOOL TUCIsTouchValueUsage(uint32_t page, uint32_t usage) {
    return TUCIsTouchPositionUsage(page, usage) ||
           (page == kHIDPage_Digitizer && (usage == kHIDUsage_Dig_ContactIdentifier ||
                                           usage == kHIDUsage_Dig_TipSwitch)) ||
           TUCIsTouchSurfaceUsage(page, usage) ||
           TUCIsTouchValidityUsage(page, usage);
}

static NSString *TUCHexStringForHIDReport(uint8_t *report, CFIndex len) {
    NSMutableString *hex = [NSMutableString string];
    CFIndex byteCount = MIN(len, 16);
    for (CFIndex i = 0; i < byteCount; i++) {
        if (i > 0) {
            [hex appendString:@" "];
        }
        [hex appendFormat:@"%02x", report[i]];
    }
    if (len > byteCount) {
        [hex appendString:@" ..."];
    }
    return hex;
}

static IOHIDAccessType TUCHIDListenEventAccessType(void) {
    if (@available(macOS 10.15, *)) {
        return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    }
    return kIOHIDAccessTypeGranted;
}

static NSString *TUCHIDListenEventAccessDescription(IOHIDAccessType accessType) {
    switch (accessType) {
        case kIOHIDAccessTypeGranted:
            return @"granted";
        case kIOHIDAccessTypeDenied:
            return @"denied";
        case kIOHIDAccessTypeUnknown:
            return @"unknown";
    }
}

static BOOL TUCHIDListenEventAccessGranted(void) {
    return TUCHIDListenEventAccessType() == kIOHIDAccessTypeGranted;
}

static BOOL TUCListenEventAccessGranted(void) {
    return TUCHIDListenEventAccessGranted();
}

static NSString *TUCListenEventAccessDescription(void) {
    IOHIDAccessType hidAccessType = TUCHIDListenEventAccessType();
    return [NSString stringWithFormat:@"IOHID=%@", TUCHIDListenEventAccessDescription(hidAccessType)];
}

static BOOL TUCHIDElementPropertiesContainTouchCollection(NSArray *elements) {
    for (NSDictionary *element in elements) {
        NSInteger usagePage = [element[@"UsagePage"] integerValue];
        NSInteger usage = [element[@"Usage"] integerValue];
        NSArray *children = element[@"Elements"];

        if (usagePage == kHIDPage_Digitizer &&
            (usage == TUC_HID_USAGE_DIG_TOUCHSCREEN || usage == TUC_HID_USAGE_DIG_FINGER)) {
            return YES;
        }

        if ([children isKindOfClass:[NSArray class]] && TUCHIDElementPropertiesContainTouchCollection(children)) {
            return YES;
        }
    }
    return NO;
}

static void TUCHIDElementPropertiesFindAbsolutePointerParts(NSArray *elements, BOOL *hasX, BOOL *hasY, BOOL *hasSurface) {
    for (NSDictionary *element in elements) {
        NSInteger usagePage = [element[@"UsagePage"] integerValue];
        NSInteger usage = [element[@"Usage"] integerValue];
        BOOL isRelative = [element[@"IsRelative"] boolValue];
        NSInteger min = [element[@"Min"] integerValue];
        NSInteger max = [element[@"Max"] integerValue];
        NSArray *children = element[@"Elements"];

        if (TUCIsTouchXUsage((uint32_t)usagePage, (uint32_t)usage) && !isRelative && max > min) {
            *hasX = YES;
        } else if (TUCIsTouchYUsage((uint32_t)usagePage, (uint32_t)usage) && !isRelative && max > min) {
            *hasY = YES;
        } else if (TUCIsTouchSurfaceUsage((uint32_t)usagePage, (uint32_t)usage) ||
                   TUCIsTouchValidityUsage((uint32_t)usagePage, (uint32_t)usage)) {
            *hasSurface = YES;
        }

        if ([children isKindOfClass:[NSArray class]]) {
            TUCHIDElementPropertiesFindAbsolutePointerParts(children, hasX, hasY, hasSurface);
        }
    }
}

static BOOL TUCHIDElementPropertiesContainAbsolutePointer(NSArray *elements) {
    BOOL hasX = NO;
    BOOL hasY = NO;
    BOOL hasSurface = NO;
    TUCHIDElementPropertiesFindAbsolutePointerParts(elements, &hasX, &hasY, &hasSurface);
    return hasX && hasY && hasSurface;
}

static BOOL TUCHIDDevicePropertiesLookLikeTouch(NSDictionary *properties, NSInteger usagePage, NSInteger usage) {
    // Privacy boundary: only devices with touch/digitizer descriptors, touch-like
    // names, or absolute pointer reports are opened. Keyboards and relative mice
    // are intentionally ignored even though macOS groups the permission under
    // "Input Monitoring".
    if (usagePage == kHIDPage_Digitizer) return YES;

    NSArray *elements = properties[@"Elements"];
    if ([elements isKindOfClass:[NSArray class]] && TUCHIDElementPropertiesContainTouchCollection(elements)) {
        return YES;
    }

    NSString *name = [[NSString stringWithFormat:@"%@ %@ %@ %@",
                       properties[@"Manufacturer"] ?: @"",
                       properties[@"ManufacturerString"] ?: @"",
                       properties[@"Product"] ?: @"",
                       properties[@"ProductString"] ?: @""] lowercaseString];
    BOOL nameLooksTouch = ([name containsString:@"touch"] || [name containsString:@"digitizer"]);
    if (nameLooksTouch) return YES;

    BOOL isGenericPointer = usagePage == kHIDPage_GenericDesktop &&
        (usage == kHIDUsage_GD_Pointer || usage == kHIDUsage_GD_Mouse);
    return isGenericPointer &&
        [elements isKindOfClass:[NSArray class]] &&
        TUCHIDElementPropertiesContainAbsolutePointer(elements);
}

static IOHIDElementRef TUCContactCollectionForElement(IOHIDElementRef element, BOOL *isDigitizerContact) {
    IOHIDElementRef current = IOHIDElementGetParent(element);
    IOHIDElementRef fallback = NULL;
    BOOL fallbackIsDigitizer = NO;

    while (current != NULL) {
        if (IOHIDElementGetType(current) == kIOHIDElementTypeCollection) {
            uint32_t page = (uint32_t)IOHIDElementGetUsagePage(current);
            uint32_t usage = (uint32_t)IOHIDElementGetUsage(current);

            if (page == kHIDPage_Digitizer) {
                fallback = current;
                fallbackIsDigitizer = YES;
                if (usage == TUC_HID_USAGE_DIG_FINGER || usage == TUC_HID_USAGE_DIG_TOUCHSCREEN) {
                    if (isDigitizerContact) *isDigitizerContact = YES;
                    return current;
                }
            } else if (!fallback && page == kHIDPage_GenericDesktop &&
                       (usage == kHIDUsage_GD_Pointer || usage == kHIDUsage_GD_Mouse)) {
                fallback = current;
                fallbackIsDigitizer = NO;
            }
        }
        current = IOHIDElementGetParent(current);
    }

    if (isDigitizerContact) *isDigitizerContact = fallbackIsDigitizer;
    return fallback;
}

#pragma mark   Start & Stop

- (BOOL)isHIDListenEventAccessGranted {
    return [self checkHIDListenEventAccessGranted];
}

- (BOOL)checkHIDListenEventAccessGranted {
    return TUCListenEventAccessGranted();
}

- (BOOL)requestHIDListenEventAccess {
    if (@available(macOS 10.15, *)) {
        // macOS uses the broad "Input Monitoring" TCC category for IOHID report
        // access. Touch Up does not install a keyboard event tap; the permission
        // is used only after the device descriptor has been filtered for touch
        // or digitizer input.
        BOOL hidGranted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        BOOL granted = hidGranted || TUCListenEventAccessGranted();
        NSLog(@"[TouchUp] HID: requested Input Monitoring access (%@)", TUCListenEventAccessDescription());
        return granted;
    }
    return YES;
}

- (void)start {
    [self refreshScreenAssignments];
    [self startUSBHIDListening];
}

- (void)stop {
    [self stopUSBHIDListening];
}

- (void)refreshScreenAssignments {
    NSArray<TUCScreen *> *screens = (NSArray<TUCScreen *> *)[TUCScreen allScreens];
    [self refreshScreenTopologySignalsWithScreens:screens];

    for (TUCUSBHIDTouchDevice *touchDevice in [_hidTouchDevicesByRegistryID allValues]) {
        [self screenForTouchDevice:touchDevice screens:screens];
    }
}

- (void)resetDisplayAssignments {
    [self.learnedDisplayIDsBySourceIdentifier removeAllObjects];
    [self.learnedDisplayIDsByStableIdentifier removeAllObjects];
    [self persistLearnedDisplayAssignments];

    [self.pendingHotPlugDisplayIDs removeAllObjects];
    [self.pendingHotPlugTouchRegistryIDs removeAllObjects];
    [self.pendingHotPlugDisplayDatesByID removeAllObjects];
    [self.hotPlugDisplayIDsByRegistryID removeAllObjects];
    [self.sessionDisplayIDsByStableIdentifier removeAllObjects];
    [self.sessionAssignmentConfidencesByStableIdentifier removeAllObjects];

    for (TUCUSBHIDTouchDevice *touchDevice in [_hidTouchDevicesByRegistryID allValues]) {
        touchDevice.assignedDisplayID = 0;
        touchDevice.assignmentReason = TUCTouchDisplayAssignmentReasonUnknown;
        touchDevice.assignmentConfidence = TUCTouchDisplayAssignmentConfidenceUnknown;
        [self cancelTouchesForSourceIdentifier:touchDevice.sourceIdentifier];
    }

    [self refreshScreenAssignments];
}

- (void)learnDisplayAssignmentForSourceIdentifier:(NSInteger)sourceIdentifier
                                        displayID:(NSUInteger)displayID {
    TUCUSBHIDTouchDevice *matchedDevice = nil;
    for (TUCUSBHIDTouchDevice *touchDevice in [_hidTouchDevicesByRegistryID allValues]) {
        if (touchDevice.sourceIdentifier == sourceIdentifier) {
            matchedDevice = touchDevice;
            break;
        }
    }

    NSString *stableIdentifier = matchedDevice ? [self stableIdentifierForTouchDevice:matchedDevice] : @"";

    if (displayID == 0) {
        [self.learnedDisplayIDsBySourceIdentifier removeObjectForKey:@(sourceIdentifier)];
        if (stableIdentifier.length > 0) {
            [self.learnedDisplayIDsByStableIdentifier removeObjectForKey:stableIdentifier];
            [self persistLearnedDisplayAssignments];
        }
        return;
    }

    self.learnedDisplayIDsBySourceIdentifier[@(sourceIdentifier)] = @(displayID);

    if (stableIdentifier.length > 0) {
        self.learnedDisplayIDsByStableIdentifier[stableIdentifier] = @(displayID);
        [self persistLearnedDisplayAssignments];
        NSLog(@"[TouchUp] HID: learned assignment source=%ld stableID='%@' displayID=%lu",
              (long)sourceIdentifier,
              stableIdentifier,
              (unsigned long)displayID);
    }

    if (matchedDevice) {
        [self screenForTouchDevice:matchedDevice];
    }
}

- (void)setPostMouseEvents:(BOOL)postMouseEvents {
    if (_postMouseEvents == postMouseEvents) {
        return;
    }

    _postMouseEvents = postMouseEvents;

    if (!postMouseEvents) {
        [self resetAllWindowsGesturesEndingButtons:YES];
    }
}


#pragma mark - HID Device Listening

// Value callback fires once per element that changed within a report.
// We keep per-contact state because some controllers hide real touch data inside
// vendor-defined top-level devices with nested digitizer collections.
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

    if (!TUCIsTouchValueUsage(up, u)) return;

    TUCUSBHIDTouchContact *contact = [touchDevice.manager contactForHIDElement:elem touchDevice:touchDevice create:NO];
    if (!contact || !contact.enabled) return;

    if (TUCIsTouchXUsage(up, u)) {
        contact.x = (CGFloat)(val - lMin) / (CGFloat)(lMax - lMin);
        contact.hasCurrentX = YES;
    } else if (TUCIsTouchYUsage(up, u)) {
        contact.y = (CGFloat)(val - lMin) / (CGFloat)(lMax - lMin);
        contact.hasCurrentY = YES;
    } else if (up == kHIDPage_Digitizer && u == kHIDUsage_Dig_ContactIdentifier) {
        contact.contactID = val;
        contact.contactIDWasReported = YES;
    } else if (TUCIsTouchSurfaceUsage(up, u)) {
        contact.isOnSurface = (val != 0);
    } else if (TUCIsTouchValidityUsage(up, u)) {
        contact.isValid = (val != 0);
    }

    [touchDevice.manager scheduleProcessHIDValuesForTouchDevice:touchDevice];
}

// Report callback fires once per complete HID report, after all value callbacks for that report.
static void hidReportCallback(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                              uint32_t reportID, uint8_t *report, CFIndex len) {
    if (result != kIOReturnSuccess || len <= 0) return;
    if (type != kIOHIDReportTypeInput) return;

    TUCUSBHIDTouchDevice *touchDevice = (__bridge TUCUSBHIDTouchDevice *)ctx;
    if (!touchDevice.loggedFirstHIDReport) {
        touchDevice.loggedFirstHIDReport = YES;
        NSLog(@"[TouchUp] HID: first input report source=%ld reportID=%u length=%ld bytes=%@",
              (long)touchDevice.sourceIdentifier,
              reportID,
              (long)len,
              TUCHexStringForHIDReport(report, len));
    }

    if ([touchDevice.manager processRawHIDReportForTouchDevice:touchDevice
                                                      reportID:reportID
                                                        report:report
                                                        length:len]) {
        return;
    }

    [touchDevice.manager scheduleProcessHIDValuesForTouchDevice:touchDevice];
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
    [self resetAllWindowsGesturesEndingButtons:YES];

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
    BOOL looksLikeTouch = TUCHIDDevicePropertiesLookLikeTouch(props, usagePage, usage);
    if (!looksLikeTouch) {
        return;
    }

    [self openIOHIDDevice:hidDevice properties:props requiresAbsolutePointer:isPointer && !isDigitizer];
}

- (BOOL)configureTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice
             fromIOHIDDevice:(IOHIDDeviceRef)device
     requiresAbsolutePointer:(BOOL)requiresTouchButton {
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);
    if (!elements) return NO;

    [touchDevice.hidContactsByCollection removeAllObjects];
    [touchDevice.hidContacts removeAllObjects];
    NSInteger fallbackContactID = 0;

    for (CFIndex i = 0; i < CFArrayGetCount(elements); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        uint32_t page = IOHIDElementGetUsagePage(element);
        uint32_t usage = IOHIDElementGetUsage(element);
        CFIndex lMin = IOHIDElementGetLogicalMin(element);
        CFIndex lMax = IOHIDElementGetLogicalMax(element);
        BOOL hasRange = lMax > lMin;

        if (!TUCIsTouchValueUsage(page, usage)) continue;

        TUCUSBHIDTouchContact *contact = [self contactForHIDElement:element touchDevice:touchDevice create:YES];
        if (!contact) continue;

        if (contact.fallbackContactID == NSNotFound) {
            contact.fallbackContactID = fallbackContactID++;
        }

        if (TUCIsTouchXUsage(page, usage) && hasRange && !IOHIDElementIsRelative(element)) {
            contact.supportsX = YES;
            contact.xElement = element;
        } else if (TUCIsTouchYUsage(page, usage) && hasRange && !IOHIDElementIsRelative(element)) {
            contact.supportsY = YES;
            contact.yElement = element;
        } else if (TUCIsTouchSurfaceUsage(page, usage)) {
            contact.supportsSurfaceState = YES;
            contact.surfaceElement = element;
        } else if (TUCIsTouchValidityUsage(page, usage)) {
            contact.supportsValidityState = YES;
            contact.validityElement = element;
        } else if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_ContactIdentifier) {
            contact.supportsContactID = YES;
            contact.contactIDElement = element;
        }
    }

    CFRelease(elements);

    BOOL hasDigitizerContact = NO;
    for (TUCUSBHIDTouchContact *contact in touchDevice.hidContacts) {
        if (contact.isDigitizerContact &&
            contact.supportsX &&
            contact.supportsY &&
            (contact.supportsSurfaceState || contact.supportsValidityState)) {
            hasDigitizerContact = YES;
            break;
        }
    }

    NSMutableArray<TUCUSBHIDTouchContact *> *enabledContacts = [NSMutableArray array];
    NSInteger validityContacts = 0;
    for (TUCUSBHIDTouchContact *contact in touchDevice.hidContacts) {
        BOOL usablePosition = contact.supportsX && contact.supportsY;
        BOOL usableSurface = contact.supportsSurfaceState ||
                             (contact.isDigitizerContact && !requiresTouchButton);
        contact.enabled = usablePosition && usableSurface && (hasDigitizerContact ? contact.isDigitizerContact : YES);

        if (contact.enabled) {
            [enabledContacts addObject:contact];
            if (contact.supportsValidityState) {
                validityContacts++;
            }
        }
    }

    NSLog(@"[TouchUp] HID: descriptor profile contacts=%ld enabled=%ld validity=%ld digitizer=%@ requiresTouchButton=%@",
          (long)touchDevice.hidContacts.count,
          (long)enabledContacts.count,
          (long)validityContacts,
          hasDigitizerContact ? @"yes" : @"no",
          requiresTouchButton ? @"yes" : @"no");

    return enabledContacts.count > 0;
}

- (TUCUSBHIDTouchContact *)contactForHIDElement:(IOHIDElementRef)element
                                    touchDevice:(TUCUSBHIDTouchDevice *)touchDevice
                                         create:(BOOL)create {
    BOOL isDigitizerContact = NO;
    IOHIDElementRef collection = TUCContactCollectionForElement(element, &isDigitizerContact);
    if (!collection) return nil;

    NSValue *key = [NSValue valueWithPointer:collection];
    TUCUSBHIDTouchContact *contact = touchDevice.hidContactsByCollection[key];
    if (!contact && create) {
        contact = [TUCUSBHIDTouchContact new];
        contact.isDigitizerContact = isDigitizerContact;
        touchDevice.hidContactsByCollection[key] = contact;
        [touchDevice.hidContacts addObject:contact];
    } else if (contact && isDigitizerContact) {
        contact.isDigitizerContact = YES;
    }

    return contact;
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

// Open the IOHIDDevice for shared (non-exclusive) access.
// Element value callbacks update per-contact touch state; report callbacks are kept
// registered only so controllers that expect a report buffer still behave normally.
- (void)openIOHIDDevice:(io_service_t)hidService properties:(NSDictionary *)properties requiresAbsolutePointer:(BOOL)requiresAbsolutePointer {
    uint64_t registryID = [self registryIDForService:hidService];
    NSNumber *registryKey = @(registryID);
    if (registryID != 0 && _hidTouchDevicesByRegistryID[registryKey] != nil) return;

    IOHIDDeviceRef device = IOHIDDeviceCreate(kCFAllocatorDefault, hidService);
    if (!device) {
        NSLog(@"[TouchUp] HID: IOHIDDeviceCreate failed");
        return;
    }

    TUCUSBHIDTouchDevice *touchDevice = [TUCUSBHIDTouchDevice new];
    touchDevice.manager = self;
    touchDevice.sourceIdentifier = self.nextTouchDeviceIdentifier++;
    touchDevice.registryID = registryID;
    touchDevice.vendorID = [properties[@"VendorID"] integerValue];
    touchDevice.productID = [properties[@"ProductID"] integerValue];
    touchDevice.name = [self displayNameForHIDProperties:properties];
    touchDevice.connectedDate = [NSDate date];
    touchDevice.assignmentReason = TUCTouchDisplayAssignmentReasonUnknown;
    touchDevice.assignmentConfidence = TUCTouchDisplayAssignmentConfidenceUnknown;
    touchDevice.requiresTCCAuthorization = [properties[@"RequiresTCCAuthorization"] boolValue];

    if (!TUCListenEventAccessGranted()) {
        NSLog(@"[TouchUp] HID: Input Monitoring access %@ — attempting open so macOS can register '%@' (RequiresTCCAuthorization=%@)",
              TUCListenEventAccessDescription(),
              touchDevice.name,
              touchDevice.requiresTCCAuthorization ? @"yes" : @"no");
    }

    IOReturn ret = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    if (ret != kIOReturnSuccess) {
        NSLog(@"[TouchUp] HID: IOHIDDeviceOpen failed: 0x%08x for '%@' (InputMonitoring=%@ RequiresTCCAuthorization=%@)",
              ret,
              touchDevice.name,
              TUCListenEventAccessDescription(),
              touchDevice.requiresTCCAuthorization ? @"yes" : @"no");
        CFRelease(device);
        return;
    }
    touchDevice.hidDeviceRef = device; // owned — caller of IOHIDDeviceCreate holds the only reference

    if (![self configureTouchDevice:touchDevice fromIOHIDDevice:device requiresAbsolutePointer:requiresAbsolutePointer]) {
        NSLog(@"[TouchUp] HID: no usable touch descriptor profile — skipping '%@'", touchDevice.name);
        [touchDevice close];
        return;
    }
    touchDevice.usesRawReportFallback = TUCShouldUseSISRawReportFallback(touchDevice);
    if (touchDevice.usesRawReportFallback) {
        NSLog(@"[TouchUp] HID: raw report fallback enabled source=%ld name='%@'",
              (long)touchDevice.sourceIdentifier,
              touchDevice.name);
    }

    _hidTouchDevicesByRegistryID[registryKey] = touchDevice;
    [self restoreSessionAssignmentForTouchDevice:touchDevice];
    [self recordTouchDeviceForAutomaticPairing:touchDevice];
    [self screenForTouchDevice:touchDevice];
    [self inputSourceStateForIdentifier:touchDevice.sourceIdentifier];

    // 512 bytes covers all USB HID reports (USB full-speed max is 64, but some devices use more)
    NSUInteger bufSize = 512;
    touchDevice.hidReportBuffer = [NSMutableData dataWithLength:bufSize];

    IOHIDDeviceRegisterInputValueCallback(device, hidValueCallback, (__bridge void *)touchDevice);
    IOHIDDeviceRegisterInputReportCallback(device, touchDevice.hidReportBuffer.mutableBytes,
                                           (CFIndex)bufSize, hidReportCallback, (__bridge void *)touchDevice);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), kCFRunLoopCommonModes);

    if (_hidTouchDevicesByRegistryID.count == 1) {
        TouchInputManagerDidConnectTouchscreen((__bridge void *)self);
    }
    NSLog(@"[TouchUp] HID: device opened, source=%ld name='%@' VendorID=%ld ProductID=%ld listening for values",
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

- (void)scheduleProcessHIDValuesForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice {
    if (touchDevice.usesRawReportFallback) return;
    if (touchDevice.hidDispatchPending) return;
    touchDevice.hidDispatchPending = YES;

    __weak TUCTouchInputManager *weakSelf = self;
    __weak TUCUSBHIDTouchDevice *weakTouchDevice = touchDevice;
    dispatch_async(dispatch_get_main_queue(), ^{
        TUCTouchInputManager *strongSelf = weakSelf;
        TUCUSBHIDTouchDevice *strongTouchDevice = weakTouchDevice;
        if (!strongSelf || !strongTouchDevice || !strongTouchDevice.hidDeviceRef) return;

        strongTouchDevice.hidDispatchPending = NO;
        [strongSelf processHIDValuesForTouchDevice:strongTouchDevice];
    });
}

- (void)processHIDValuesForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice {
    TUCScreen *screen = [self screenForTouchDevice:touchDevice];
    for (TUCUSBHIDTouchContact *contact in touchDevice.hidContacts) {
        if (!contact.enabled) continue;

        [self refreshHIDContact:contact touchDevice:touchDevice];
        if (!touchDevice.loggedFirstHIDContactState) {
            touchDevice.loggedFirstHIDContactState = YES;
            NSLog(@"[TouchUp] HID: first contact state source=%ld contact=%ld enabled=%@ hasX=%@ hasY=%@ x=%.4f y=%.4f supportsSurface=%@ surface=%@ supportsValidity=%@ valid=%@",
                  (long)touchDevice.sourceIdentifier,
                  (long)(contact.contactIDWasReported ? contact.contactID : contact.fallbackContactID),
                  contact.enabled ? @"yes" : @"no",
                  contact.hasCurrentX ? @"yes" : @"no",
                  contact.hasCurrentY ? @"yes" : @"no",
                  contact.x,
                  contact.y,
                  contact.supportsSurfaceState ? @"yes" : @"no",
                  contact.isOnSurface ? @"yes" : @"no",
                  contact.supportsValidityState ? @"yes" : @"no",
                  contact.isValid ? @"yes" : @"no");
        }
        if (!contact.hasCurrentX || !contact.hasCurrentY) {
            if (!touchDevice.loggedMissingHIDPosition) {
                touchDevice.loggedMissingHIDPosition = YES;
                NSLog(@"[TouchUp] HID: report without readable position source=%ld name='%@'",
                      (long)touchDevice.sourceIdentifier,
                      touchDevice.name);
            }
            continue;
        }

        BOOL onSurface = contact.supportsSurfaceState ?
                         (contact.isOnSurface || (contact.supportsValidityState && contact.isValid)) :
                         YES;
        if (!onSurface && !contact.wasDispatchedOnSurface) continue;

        NSInteger contactID = contact.contactIDWasReported ? contact.contactID : contact.fallbackContactID;
        CGFloat x = MAX(0.0, MIN(1.0, contact.x));
        CGFloat y = MAX(0.0, MIN(1.0, contact.y));

        if (!touchDevice.loggedFirstTouchDispatch && onSurface) {
            touchDevice.loggedFirstTouchDispatch = YES;
            NSLog(@"[TouchUp] HID: first touch dispatch source=%ld contact=%ld x=%.4f y=%.4f displayID=%lu display='%@'",
                  (long)touchDevice.sourceIdentifier,
                  (long)contactID,
                  x,
                  y,
                  (unsigned long)screen.id,
                  screen.name);
        }

        [self updateTouch:contactID
             withLocation:CGPointMake(x, y)
                onSurface:(Boolean)onSurface
        tooLargeForFinger:(Boolean)contact.isValid
                   screen:screen
         sourceIdentifier:touchDevice.sourceIdentifier];

        contact.wasDispatchedOnSurface = onSurface;
    }

    [self didProcessReportForSourceIdentifier:touchDevice.sourceIdentifier];
}

- (nullable TUCUSBHIDTouchContact *)primaryEnabledContactForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice {
    for (TUCUSBHIDTouchContact *contact in touchDevice.hidContacts) {
        if (contact.enabled) {
            return contact;
        }
    }

    return nil;
}

- (BOOL)processRawHIDReportForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice
                                  reportID:(uint32_t)reportID
                                    report:(uint8_t *)report
                                    length:(CFIndex)len {
    if (!touchDevice.usesRawReportFallback) {
        return NO;
    }

    NSInteger statusIndex = NSNotFound;
    NSInteger xIndex = NSNotFound;
    NSInteger yIndex = NSNotFound;

    if (len >= 6 && report[0] == (uint8_t)reportID) {
        statusIndex = 1;
        xIndex = 2;
        yIndex = 4;
    } else if (len >= 5) {
        statusIndex = 0;
        xIndex = 1;
        yIndex = 3;
    }

    if (xIndex == NSNotFound || yIndex == NSNotFound || yIndex + 1 >= len) {
        return YES;
    }

    uint8_t status = report[statusIndex];
    uint16_t rawX = (uint16_t)report[xIndex] | ((uint16_t)report[xIndex + 1] << 8);
    uint16_t rawY = (uint16_t)report[yIndex] | ((uint16_t)report[yIndex + 1] << 8);
    BOOL onSurface = rawX != 0 || rawY != 0;

    touchDevice.rawReportDispatchGeneration += 1;
    if (!onSurface && !touchDevice.rawReportContactActive) {
        return YES;
    }

    TUCUSBHIDTouchContact *contact = [self primaryEnabledContactForTouchDevice:touchDevice];
    NSInteger contactID = 0;
    if (contact) {
        contactID = contact.contactIDWasReported ? contact.contactID : contact.fallbackContactID;
        if (contactID == NSNotFound) {
            contactID = 0;
        }
    }

    CGPoint point = touchDevice.lastRawReportPoint;
    if (onSurface) {
        CGFloat x = TUCNormalizedSISRawCoordinate(rawX, contact.xElement);
        CGFloat y = TUCNormalizedSISRawCoordinate(rawY, contact.yElement);
        point = CGPointMake(x, y);
        touchDevice.lastRawReportPoint = point;
        touchDevice.rawReportContactActive = YES;
    } else {
        touchDevice.rawReportContactActive = NO;
    }

    TUCScreen *screen = [self screenForTouchDevice:touchDevice];
    if (!screen) {
        return YES;
    }

    if (!touchDevice.loggedFirstRawReportDispatch) {
        touchDevice.loggedFirstRawReportDispatch = YES;
        NSLog(@"[TouchUp] HID: raw report fallback decoded source=%ld status=0x%02x rawX=%u rawY=%u x=%.4f y=%.4f onSurface=%@",
              (long)touchDevice.sourceIdentifier,
              status,
              rawX,
              rawY,
              point.x,
              point.y,
              onSurface ? @"yes" : @"no");
    }

    if (!touchDevice.loggedFirstTouchDispatch && onSurface) {
        touchDevice.loggedFirstTouchDispatch = YES;
        NSLog(@"[TouchUp] HID: first touch dispatch source=%ld contact=%ld x=%.4f y=%.4f displayID=%lu display='%@' rawFallback=yes status=0x%02x rawX=%u rawY=%u",
              (long)touchDevice.sourceIdentifier,
              (long)contactID,
              point.x,
              point.y,
              (unsigned long)screen.id,
              screen.name,
              status,
              rawX,
              rawY);
    }

    [self updateTouch:contactID
         withLocation:point
            onSurface:(Boolean)onSurface
    tooLargeForFinger:NO
               screen:screen
     sourceIdentifier:touchDevice.sourceIdentifier];
    [self didProcessReportForSourceIdentifier:touchDevice.sourceIdentifier];

    if (onSurface) {
        [self scheduleRawReportLiftForTouchDevice:touchDevice contactID:contactID screen:screen];
    }

    return YES;
}

- (void)scheduleRawReportLiftForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice
                                  contactID:(NSInteger)contactID
                                     screen:(TUCScreen *)screen {
    NSUInteger generation = touchDevice.rawReportDispatchGeneration;
    __weak TUCTouchInputManager *weakSelf = self;
    __weak TUCUSBHIDTouchDevice *weakTouchDevice = touchDevice;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TUCRawReportLiftTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TUCTouchInputManager *strongSelf = weakSelf;
        TUCUSBHIDTouchDevice *strongTouchDevice = weakTouchDevice;
        if (!strongSelf ||
            !strongTouchDevice ||
            !strongTouchDevice.hidDeviceRef ||
            !strongTouchDevice.rawReportContactActive ||
            strongTouchDevice.rawReportDispatchGeneration != generation) {
            return;
        }

        strongTouchDevice.rawReportContactActive = NO;
        strongTouchDevice.rawReportDispatchGeneration += 1;
        TUCScreen *currentScreen = [strongSelf screenForTouchDevice:strongTouchDevice] ?: screen;
        [strongSelf updateTouch:contactID
                   withLocation:strongTouchDevice.lastRawReportPoint
                      onSurface:NO
              tooLargeForFinger:NO
                         screen:currentScreen
               sourceIdentifier:strongTouchDevice.sourceIdentifier];
        [strongSelf didProcessReportForSourceIdentifier:strongTouchDevice.sourceIdentifier];
    });
}

- (void)refreshHIDContact:(TUCUSBHIDTouchContact *)contact touchDevice:(TUCUSBHIDTouchDevice *)touchDevice {
    if (!touchDevice.hidDeviceRef) {
        return;
    }

    IOHIDValueRef value = NULL;
    if (contact.xElement &&
        IOHIDDeviceGetValue(touchDevice.hidDeviceRef, contact.xElement, &value) == kIOReturnSuccess &&
        value) {
        IOHIDElementRef element = IOHIDValueGetElement(value);
        CFIndex lMin = IOHIDElementGetLogicalMin(element);
        CFIndex lMax = IOHIDElementGetLogicalMax(element);
        if (lMax > lMin) {
            contact.x = (CGFloat)(IOHIDValueGetIntegerValue(value) - lMin) / (CGFloat)(lMax - lMin);
            contact.hasCurrentX = YES;
        }
    }

    value = NULL;
    if (contact.yElement &&
        IOHIDDeviceGetValue(touchDevice.hidDeviceRef, contact.yElement, &value) == kIOReturnSuccess &&
        value) {
        IOHIDElementRef element = IOHIDValueGetElement(value);
        CFIndex lMin = IOHIDElementGetLogicalMin(element);
        CFIndex lMax = IOHIDElementGetLogicalMax(element);
        if (lMax > lMin) {
            contact.y = (CGFloat)(IOHIDValueGetIntegerValue(value) - lMin) / (CGFloat)(lMax - lMin);
            contact.hasCurrentY = YES;
        }
    }

    value = NULL;
    if (contact.surfaceElement &&
        IOHIDDeviceGetValue(touchDevice.hidDeviceRef, contact.surfaceElement, &value) == kIOReturnSuccess &&
        value) {
        contact.isOnSurface = IOHIDValueGetIntegerValue(value) != 0;
    }

    value = NULL;
    if (contact.validityElement &&
        IOHIDDeviceGetValue(touchDevice.hidDeviceRef, contact.validityElement, &value) == kIOReturnSuccess &&
        value) {
        contact.isValid = IOHIDValueGetIntegerValue(value) != 0;
    }

    value = NULL;
    if (contact.contactIDElement &&
        IOHIDDeviceGetValue(touchDevice.hidDeviceRef, contact.contactIDElement, &value) == kIOReturnSuccess &&
        value) {
        contact.contactID = IOHIDValueGetIntegerValue(value);
        contact.contactIDWasReported = YES;
    }
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
    
    ++sourceState.currentFrameID;
    
    [self processTouchesForCursorInputForSourceState:sourceState];
    
}


- (void)stopCurrentGestureForSourceState:(TUCInputSourceState *)sourceState {
    [self resetWindowsGestureForSourceState:sourceState endingButtons:YES];
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
    
    CGPoint rawPoint = [self convertDigitizerPoint:digitizerPoint toRelativeScreenPointOnScreen:touchscreen];
    CGPoint point = [self applyCalibrationToPoint:rawPoint onScreen:touchscreen];
    
    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID sourceIdentifier:sourceIdentifier isNew:&isNewTouch];
    
    [touch setRawLocation:rawPoint];
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
        CGFloat dxMM = fabs(touch.location.x - touch.previousLocation.x) * touchscreen.physicalSize.width;
        CGFloat dyMM = fabs(touch.location.y - touch.previousLocation.y) * touchscreen.physicalSize.height;
        BOOL isStationary = sqrt(dxMM * dxMM + dyMM * dyMM) < 0.1;
        
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

- (NSString *)nameForWindowsGestureKind:(TUCWindowsGestureKind)gesture {
    switch (gesture) {
        case TUCWindowsGestureKindIdle: return @"Idle";
        case TUCWindowsGestureKindOneFingerPending: return @"OneFingerPending";
        case TUCWindowsGestureKindOneFingerMove: return @"OneFingerMove";
        case TUCWindowsGestureKindWindowMove: return @"WindowMove";
        case TUCWindowsGestureKindRightButtonDown: return @"RightButtonDown";
        case TUCWindowsGestureKindTwoFingerPending: return @"TwoFingerPending";
        case TUCWindowsGestureKindTwoFingerScroll: return @"TwoFingerScroll";
        case TUCWindowsGestureKindPinch: return @"Pinch";
        case TUCWindowsGestureKindSuppressUntilAllLifted: return @"SuppressUntilAllLifted";
    }
}

- (void)setWindowsGesture:(TUCWindowsGestureKind)gesture forSourceState:(TUCInputSourceState *)sourceState {
    if (sourceState.activeGesture == gesture) {
        return;
    }

#if DEBUG
    NSLog(@"[TouchUp] Gesture state %@ -> %@ source=%ld",
          [self nameForWindowsGestureKind:sourceState.activeGesture],
          [self nameForWindowsGestureKind:gesture],
          (long)sourceState.sourceIdentifier);
#endif

    sourceState.activeGesture = gesture;
}

- (NSTimeInterval)effectiveHoldDuration {
    return self.holdDuration > 0 ? self.holdDuration : TUCDefaultHoldDuration;
}

- (void)scheduleHoldCheckForSourceState:(TUCInputSourceState *)sourceState {
    NSDate *gestureStartDate = sourceState.gestureStartDate;
    NSInteger sourceIdentifier = sourceState.sourceIdentifier;
    NSTimeInterval delay = [self effectiveHoldDuration];

    __weak TUCTouchInputManager *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TUCTouchInputManager *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        TUCInputSourceState *currentState = [strongSelf inputSourceStateForIdentifier:sourceIdentifier];
        if (currentState.activeGesture == TUCWindowsGestureKindOneFingerPending &&
            currentState.gestureStartDate == gestureStartDate) {
            [strongSelf processTouchesForCursorInputForSourceState:currentState];
        }
    });
}



- (void)processTouchesForCursorInputForSourceState:(TUCInputSourceState *)sourceState {
    if (!self.postMouseEvents) {
        [self resetWindowsGestureForSourceState:sourceState endingButtons:YES];
        return;
    }

    NSArray<TUCTouch *> *activeTouches = [self activeTouchesSortedForSourceIdentifier:sourceState.sourceIdentifier];
    NSArray<TUCTouch *> *endedTouches = [self endedTouchesSortedForSourceIdentifier:sourceState.sourceIdentifier];
    [self advanceWindowsGestureWithActiveTouches:activeTouches endedTouches:endedTouches sourceState:sourceState];
}

- (void)advanceWindowsGestureWithActiveTouches:(NSArray<TUCTouch *> *)activeTouches
                                  endedTouches:(NSArray<TUCTouch *> *)endedTouches
                                   sourceState:(TUCInputSourceState *)sourceState {
    if ([self finishGestureIfNeededWithActiveTouches:activeTouches endedTouches:endedTouches sourceState:sourceState]) {
        return;
    }

    if (sourceState.activeGesture == TUCWindowsGestureKindSuppressUntilAllLifted) {
        if (activeTouches.count == 0) {
            [self resetWindowsGestureForSourceState:sourceState endingButtons:NO];
        }
        return;
    }

    if (activeTouches.count == 0) {
        if (sourceState.activeGesture != TUCWindowsGestureKindIdle) {
            [self resetWindowsGestureForSourceState:sourceState endingButtons:YES];
        }
        return;
    }

    if (activeTouches.count > 2) {
        [self resetWindowsGestureForSourceState:sourceState endingButtons:YES];
        [self setWindowsGesture:TUCWindowsGestureKindSuppressUntilAllLifted forSourceState:sourceState];
        return;
    }

    if (activeTouches.count == 1) {
        [self advanceOneFingerGestureWithTouch:activeTouches.firstObject sourceState:sourceState];
    } else {
        [self advanceTwoFingerGestureWithTouches:activeTouches sourceState:sourceState];
    }
}

- (BOOL)finishGestureIfNeededWithActiveTouches:(NSArray<TUCTouch *> *)activeTouches
                                  endedTouches:(NSArray<TUCTouch *> *)endedTouches
                                   sourceState:(TUCInputSourceState *)sourceState {
    if (sourceState.activeGesture == TUCWindowsGestureKindIdle ||
        sourceState.activeGesture == TUCWindowsGestureKindSuppressUntilAllLifted) {
        return NO;
    }

    TUCTouch *endedPrimary = [self touchWithContactID:sourceState.primaryContactID inTouches:endedTouches];
    TUCTouch *endedSecondary = [self touchWithContactID:sourceState.secondaryContactID inTouches:endedTouches];
    BOOL primaryIsActive = [self touchWithContactID:sourceState.primaryContactID inTouches:activeTouches] != nil;
    BOOL secondaryIsActive = [self touchWithContactID:sourceState.secondaryContactID inTouches:activeTouches] != nil;

    BOOL oneFingerGesture = sourceState.activeGesture == TUCWindowsGestureKindOneFingerPending ||
                            sourceState.activeGesture == TUCWindowsGestureKindOneFingerMove ||
                            sourceState.activeGesture == TUCWindowsGestureKindWindowMove ||
                            sourceState.activeGesture == TUCWindowsGestureKindRightButtonDown;
    if (oneFingerGesture && (endedPrimary != nil || !primaryIsActive)) {
        [self finishOneFingerGestureWithTouch:endedPrimary activeTouches:activeTouches sourceState:sourceState];
        return YES;
    }

    BOOL twoFingerGesture = sourceState.activeGesture == TUCWindowsGestureKindTwoFingerPending ||
                            sourceState.activeGesture == TUCWindowsGestureKindTwoFingerScroll ||
                            sourceState.activeGesture == TUCWindowsGestureKindPinch;
    if (twoFingerGesture && (endedPrimary != nil || endedSecondary != nil || !primaryIsActive || !secondaryIsActive)) {
        [self finishTwoFingerGestureWithActiveTouches:activeTouches endedTouches:endedTouches sourceState:sourceState];
        return YES;
    }

    return NO;
}

- (void)finishOneFingerGestureWithTouch:(nullable TUCTouch *)touch
                           activeTouches:(NSArray<TUCTouch *> *)activeTouches
                            sourceState:(TUCInputSourceState *)sourceState {
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    TUCScreen *screen = touch.screen ?: [self touchscreen];
    CGPoint relativeLocation = touch ? touch.location : sourceState.lastPrimaryLocation;
    CGPoint absoluteLocation = [self convertScreenPointRelativeToAbsolute:relativeLocation onScreen:screen];

    switch (sourceState.activeGesture) {
        case TUCWindowsGestureKindOneFingerPending: {
            CGFloat movement = [self distanceInMMFrom:sourceState.primaryStartLocation to:relativeLocation onScreen:screen];
            if (sourceState.tapCandidate && movement <= TUCTapMaxMovementMM) {
                [utils setDoubleClickTolerance:self.doubleClickTolerance * [screen pixelsPerMM]];
                [utils performClickAt:absoluteLocation];
            }
            break;
        }
        case TUCWindowsGestureKindWindowMove:
            [utils leftMouseUp];
            break;
        case TUCWindowsGestureKindRightButtonDown:
            [utils rightMouseUp];
            sourceState.rightButtonIsDown = NO;
            break;
        case TUCWindowsGestureKindOneFingerMove:
        default:
            break;
    }

    if (activeTouches.count > 0) {
        [self resetWindowsGestureForSourceState:sourceState endingButtons:NO];
        [self setWindowsGesture:TUCWindowsGestureKindSuppressUntilAllLifted forSourceState:sourceState];
    } else {
        [self resetWindowsGestureForSourceState:sourceState endingButtons:NO];
    }
}

- (void)finishTwoFingerGestureWithActiveTouches:(NSArray<TUCTouch *> *)activeTouches
                                   endedTouches:(NSArray<TUCTouch *> *)endedTouches
                                    sourceState:(TUCInputSourceState *)sourceState {
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];

    if (sourceState.activeGesture == TUCWindowsGestureKindTwoFingerPending &&
        self.twoFingerTapSecondaryClickEnabled &&
        [self twoFingerTapStillQualifiesWithActiveTouches:activeTouches endedTouches:endedTouches sourceState:sourceState]) {
        CGPoint location = [self latestTwoFingerCentroidAbsoluteWithActiveTouches:activeTouches endedTouches:endedTouches sourceState:sourceState];
        [utils performSecondaryClickAt:location];
    } else if (sourceState.activeGesture == TUCWindowsGestureKindTwoFingerScroll) {
        [utils scroll:CGPointZero phase:NSTouchPhaseEnded];
    } else if (sourceState.activeGesture == TUCWindowsGestureKindPinch) {
        [utils stopMagnifying];
    }

    if (activeTouches.count > 0) {
        [self resetWindowsGestureForSourceState:sourceState endingButtons:NO];
        [self setWindowsGesture:TUCWindowsGestureKindSuppressUntilAllLifted forSourceState:sourceState];
    } else {
        [self resetWindowsGestureForSourceState:sourceState endingButtons:NO];
    }
}

- (void)advanceOneFingerGestureWithTouch:(TUCTouch *)touch sourceState:(TUCInputSourceState *)sourceState {
    switch (sourceState.activeGesture) {
        case TUCWindowsGestureKindIdle:
            [self beginOneFingerGestureWithTouch:touch sourceState:sourceState];
            break;
        case TUCWindowsGestureKindOneFingerPending:
            [self advanceOneFingerPendingGestureWithTouch:touch sourceState:sourceState];
            break;
        case TUCWindowsGestureKindOneFingerMove:
            [self continueOneFingerMoveWithTouch:touch sourceState:sourceState];
            break;
        case TUCWindowsGestureKindWindowMove:
            [self continueWindowMoveWithTouch:touch sourceState:sourceState];
            break;
        case TUCWindowsGestureKindRightButtonDown:
            [self continueRightButtonGestureWithTouch:touch sourceState:sourceState];
            break;
        default:
            [self resetWindowsGestureForSourceState:sourceState endingButtons:YES];
            [self setWindowsGesture:TUCWindowsGestureKindSuppressUntilAllLifted forSourceState:sourceState];
            break;
    }
}

- (void)beginOneFingerGestureWithTouch:(TUCTouch *)touch sourceState:(TUCInputSourceState *)sourceState {
    TUCScreen *screen = touch.screen ?: [self touchscreen];
    CGPoint absoluteLocation = [self absoluteLocationForTouch:touch];

    sourceState.primaryContactID = touch.contactID;
    sourceState.secondaryContactID = NSNotFound;
    sourceState.gestureStartDate = [NSDate date];
    sourceState.primaryStartLocation = touch.location;
    sourceState.lastPrimaryLocation = touch.location;
    sourceState.tapCandidate = YES;
    sourceState.suppressClickUntilAllLifted = NO;
    sourceState.windowMoveCandidate = self.windowTitleBarDragEnabled && [self isPointInDraggableWindowArea:absoluteLocation onScreen:screen];
    sourceState.windowMoveStartScreenLocation = absoluteLocation;
    sourceState.rightButtonIsDown = NO;

    [self setWindowsGesture:TUCWindowsGestureKindOneFingerPending forSourceState:sourceState];
    [[TUCCursorUtilities sharedInstance] moveCursorTo:absoluteLocation];
    [self scheduleHoldCheckForSourceState:sourceState];
}

- (void)advanceOneFingerPendingGestureWithTouch:(TUCTouch *)touch sourceState:(TUCInputSourceState *)sourceState {
    if (touch.contactID != sourceState.primaryContactID) {
        [self resetWindowsGestureForSourceState:sourceState endingButtons:YES];
        [self setWindowsGesture:TUCWindowsGestureKindSuppressUntilAllLifted forSourceState:sourceState];
        return;
    }

    TUCScreen *screen = touch.screen ?: [self touchscreen];
    CGPoint absoluteLocation = [self absoluteLocationForTouch:touch];
    CGFloat movement = [self distanceInMMFrom:sourceState.primaryStartLocation to:touch.location onScreen:screen];
    NSTimeInterval elapsed = sourceState.gestureStartDate ? [[NSDate date] timeIntervalSinceDate:sourceState.gestureStartDate] : 0;
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];

    sourceState.lastPrimaryLocation = touch.location;

    if (sourceState.windowMoveCandidate && movement > TUCWindowMoveStartThresholdMM) {
        sourceState.tapCandidate = NO;
        [self setWindowsGesture:TUCWindowsGestureKindWindowMove forSourceState:sourceState];
        [utils releaseAllButtons];
        [utils moveCursorTo:sourceState.windowMoveStartScreenLocation];
        [utils leftMouseDownAt:sourceState.windowMoveStartScreenLocation];
        [utils leftMouseDraggedTo:absoluteLocation];
        return;
    }

    if (movement > TUCMoveStartThresholdMM) {
        sourceState.tapCandidate = NO;
        [self setWindowsGesture:TUCWindowsGestureKindOneFingerMove forSourceState:sourceState];
        [utils moveCursorTo:absoluteLocation];
        return;
    }

    if (elapsed >= [self effectiveHoldDuration] && movement <= TUCHoldMaxMovementMM) {
        sourceState.tapCandidate = NO;
        sourceState.rightButtonIsDown = YES;
        [self setWindowsGesture:TUCWindowsGestureKindRightButtonDown forSourceState:sourceState];
        [utils releaseAllButtons];
        [utils moveCursorTo:absoluteLocation];
        [utils rightMouseDownAt:absoluteLocation];
        return;
    }

    [utils moveCursorTo:absoluteLocation];
}

- (void)continueOneFingerMoveWithTouch:(TUCTouch *)touch sourceState:(TUCInputSourceState *)sourceState {
    if (touch.contactID != sourceState.primaryContactID) {
        [self resetWindowsGestureForSourceState:sourceState endingButtons:YES];
        [self setWindowsGesture:TUCWindowsGestureKindSuppressUntilAllLifted forSourceState:sourceState];
        return;
    }

    sourceState.lastPrimaryLocation = touch.location;
    [[TUCCursorUtilities sharedInstance] moveCursorTo:[self absoluteLocationForTouch:touch]];
}

- (void)continueWindowMoveWithTouch:(TUCTouch *)touch sourceState:(TUCInputSourceState *)sourceState {
    if (touch.contactID != sourceState.primaryContactID) {
        [self resetWindowsGestureForSourceState:sourceState endingButtons:YES];
        [self setWindowsGesture:TUCWindowsGestureKindSuppressUntilAllLifted forSourceState:sourceState];
        return;
    }

    sourceState.lastPrimaryLocation = touch.location;
    [[TUCCursorUtilities sharedInstance] leftMouseDraggedTo:[self absoluteLocationForTouch:touch]];
}

- (void)continueRightButtonGestureWithTouch:(TUCTouch *)touch sourceState:(TUCInputSourceState *)sourceState {
    if (touch.contactID != sourceState.primaryContactID) {
        [self resetWindowsGestureForSourceState:sourceState endingButtons:YES];
        [self setWindowsGesture:TUCWindowsGestureKindSuppressUntilAllLifted forSourceState:sourceState];
        return;
    }

    sourceState.lastPrimaryLocation = touch.location;
    [[TUCCursorUtilities sharedInstance] rightMouseDraggedTo:[self absoluteLocationForTouch:touch]];
}

- (void)advanceTwoFingerGestureWithTouches:(NSArray<TUCTouch *> *)touches sourceState:(TUCInputSourceState *)sourceState {
    if (sourceState.activeGesture == TUCWindowsGestureKindWindowMove ||
        sourceState.activeGesture == TUCWindowsGestureKindRightButtonDown) {
        [self resetWindowsGestureForSourceState:sourceState endingButtons:YES];
        [self setWindowsGesture:TUCWindowsGestureKindSuppressUntilAllLifted forSourceState:sourceState];
        return;
    }

    if (sourceState.activeGesture == TUCWindowsGestureKindIdle ||
        sourceState.activeGesture == TUCWindowsGestureKindOneFingerPending ||
        sourceState.activeGesture == TUCWindowsGestureKindOneFingerMove) {
        [self beginTwoFingerGestureWithTouches:touches sourceState:sourceState];
        return;
    }

    TUCTouch *primary = [self touchWithContactID:sourceState.primaryContactID inTouches:touches];
    TUCTouch *secondary = [self touchWithContactID:sourceState.secondaryContactID inTouches:touches];
    if (!primary || !secondary) {
        [self resetWindowsGestureForSourceState:sourceState endingButtons:YES];
        [self setWindowsGesture:TUCWindowsGestureKindSuppressUntilAllLifted forSourceState:sourceState];
        return;
    }

    if (sourceState.activeGesture == TUCWindowsGestureKindTwoFingerPending) {
        [self advanceTwoFingerPendingWithPrimary:primary secondary:secondary sourceState:sourceState];
    } else if (sourceState.activeGesture == TUCWindowsGestureKindTwoFingerScroll) {
        [self continueTwoFingerScrollWithPrimary:primary secondary:secondary sourceState:sourceState];
    } else if (sourceState.activeGesture == TUCWindowsGestureKindPinch) {
        [self continuePinchWithPrimary:primary secondary:secondary sourceState:sourceState];
    }
}

- (void)beginTwoFingerGestureWithTouches:(NSArray<TUCTouch *> *)touches sourceState:(TUCInputSourceState *)sourceState {
    BOOL tapCanStillQualify = sourceState.activeGesture == TUCWindowsGestureKindIdle ||
                              sourceState.activeGesture == TUCWindowsGestureKindOneFingerPending;
    TUCTouch *primary = [self touchWithContactID:sourceState.primaryContactID inTouches:touches] ?: touches.firstObject;
    TUCTouch *secondary = nil;
    for (TUCTouch *touch in touches) {
        if (touch.contactID != primary.contactID) {
            secondary = touch;
            break;
        }
    }

    if (!primary || !secondary) {
        return;
    }

    sourceState.primaryContactID = primary.contactID;
    sourceState.secondaryContactID = secondary.contactID;
    sourceState.gestureStartDate = [NSDate date];
    sourceState.primaryStartLocation = primary.location;
    sourceState.secondaryStartLocation = secondary.location;
    sourceState.lastPrimaryLocation = primary.location;
    sourceState.lastSecondaryLocation = secondary.location;
    sourceState.lastCentroid = [self centroidForTouch:primary otherTouch:secondary];
    sourceState.initialTwoFingerDistance = [self relativeDistanceBetweenTouch:primary otherTouch:secondary];
    sourceState.lastTwoFingerDistance = sourceState.initialTwoFingerDistance;
    sourceState.tapCandidate = tapCanStillQualify;
    sourceState.windowMoveCandidate = NO;
    sourceState.rightButtonIsDown = NO;

    [self setWindowsGesture:TUCWindowsGestureKindTwoFingerPending forSourceState:sourceState];
}

- (void)advanceTwoFingerPendingWithPrimary:(TUCTouch *)primary
                                 secondary:(TUCTouch *)secondary
                               sourceState:(TUCInputSourceState *)sourceState {
    TUCScreen *screen = primary.screen ?: [self touchscreen];
    CGPoint currentCentroid = [self centroidForTouch:primary otherTouch:secondary];
    CGPoint startCentroid = CGPointMake((sourceState.primaryStartLocation.x + sourceState.secondaryStartLocation.x) * 0.5,
                                        (sourceState.primaryStartLocation.y + sourceState.secondaryStartLocation.y) * 0.5);
    CGFloat centroidDelta = [self distanceInMMFrom:startCentroid to:currentCentroid onScreen:screen];
    CGFloat currentDistance = [self relativeDistanceBetweenTouch:primary otherTouch:secondary];
    CGFloat scaleDelta = 0;

    if (sourceState.initialTwoFingerDistance > 0.0001) {
        scaleDelta = (currentDistance / sourceState.initialTwoFingerDistance) - 1.0;
    }

    if (fabs(scaleDelta) >= TUCPinchStartScaleDelta) {
        [self resetWindowsGestureForSourceState:sourceState endingButtons:YES];
        [self setWindowsGesture:TUCWindowsGestureKindSuppressUntilAllLifted forSourceState:sourceState];
        return;
    }

    if (centroidDelta >= TUCScrollStartThresholdMM &&
        fabs(scaleDelta) < TUCScrollPinchSuppressScaleDelta) {
        if (!self.twoFingerScrollEnabled) {
            [self resetWindowsGestureForSourceState:sourceState endingButtons:YES];
            [self setWindowsGesture:TUCWindowsGestureKindSuppressUntilAllLifted forSourceState:sourceState];
            return;
        }

        sourceState.tapCandidate = NO;
        sourceState.lastCentroid = currentCentroid;
        [self setWindowsGesture:TUCWindowsGestureKindTwoFingerScroll forSourceState:sourceState];
        [[TUCCursorUtilities sharedInstance] releaseAllButtons];
        [[TUCCursorUtilities sharedInstance] cancelMomentumScroll];
        return;
    }

    sourceState.lastPrimaryLocation = primary.location;
    sourceState.lastSecondaryLocation = secondary.location;
    sourceState.lastTwoFingerDistance = currentDistance;
}

- (void)continueTwoFingerScrollWithPrimary:(TUCTouch *)primary
                                 secondary:(TUCTouch *)secondary
                               sourceState:(TUCInputSourceState *)sourceState {
    TUCScreen *screen = primary.screen ?: [self touchscreen];
    CGPoint currentCentroid = [self centroidForTouch:primary otherTouch:secondary];
    CGPoint currentAbsolute = [self convertScreenPointRelativeToAbsolute:currentCentroid onScreen:screen];
    CGPoint lastAbsolute = [self convertScreenPointRelativeToAbsolute:sourceState.lastCentroid onScreen:screen];
    CGPoint translation = CGPointMake(currentAbsolute.x - lastAbsolute.x,
                                      currentAbsolute.y - lastAbsolute.y);

    [[TUCCursorUtilities sharedInstance] scroll:translation phase:NSTouchPhaseMoved];

    sourceState.lastCentroid = currentCentroid;
    sourceState.lastPrimaryLocation = primary.location;
    sourceState.lastSecondaryLocation = secondary.location;
    sourceState.lastTwoFingerDistance = [self relativeDistanceBetweenTouch:primary otherTouch:secondary];
}

- (void)continuePinchWithPrimary:(TUCTouch *)primary
                       secondary:(TUCTouch *)secondary
                     sourceState:(TUCInputSourceState *)sourceState {
    CGPoint primaryAbsolute = [self absoluteLocationForTouch:primary];
    CGPoint secondaryAbsolute = [self absoluteLocationForTouch:secondary];

    [[TUCCursorUtilities sharedInstance] magnifyLocationA:primaryAbsolute
                                                locationB:secondaryAbsolute
                                               relativeP1:primary.location
                                                   relP2:secondary.location];

    sourceState.lastPrimaryLocation = primary.location;
    sourceState.lastSecondaryLocation = secondary.location;
    sourceState.lastCentroid = [self centroidForTouch:primary otherTouch:secondary];
    sourceState.lastTwoFingerDistance = [self relativeDistanceBetweenTouch:primary otherTouch:secondary];
}

- (BOOL)twoFingerTapStillQualifiesWithActiveTouches:(NSArray<TUCTouch *> *)activeTouches
                                      endedTouches:(NSArray<TUCTouch *> *)endedTouches
                                       sourceState:(TUCInputSourceState *)sourceState {
    if (!sourceState.tapCandidate) {
        return NO;
    }

    NSMutableArray<TUCTouch *> *touches = [NSMutableArray arrayWithArray:activeTouches];
    [touches addObjectsFromArray:endedTouches];

    TUCTouch *primary = [self touchWithContactID:sourceState.primaryContactID inTouches:touches];
    TUCTouch *secondary = [self touchWithContactID:sourceState.secondaryContactID inTouches:touches];
    if (!primary || !secondary) {
        return NO;
    }

    TUCScreen *screen = primary.screen ?: [self touchscreen];
    CGFloat primaryMovement = [self distanceInMMFrom:sourceState.primaryStartLocation to:primary.location onScreen:screen];
    CGFloat secondaryMovement = [self distanceInMMFrom:sourceState.secondaryStartLocation to:secondary.location onScreen:screen];
    return primaryMovement <= TUCTapMaxMovementMM && secondaryMovement <= TUCTapMaxMovementMM;
}

- (CGPoint)latestTwoFingerCentroidAbsoluteWithActiveTouches:(NSArray<TUCTouch *> *)activeTouches
                                               endedTouches:(NSArray<TUCTouch *> *)endedTouches
                                                sourceState:(TUCInputSourceState *)sourceState {
    NSMutableArray<TUCTouch *> *touches = [NSMutableArray arrayWithArray:activeTouches];
    [touches addObjectsFromArray:endedTouches];

    TUCTouch *primary = [self touchWithContactID:sourceState.primaryContactID inTouches:touches];
    TUCTouch *secondary = [self touchWithContactID:sourceState.secondaryContactID inTouches:touches];

    if (primary && secondary) {
        TUCScreen *screen = primary.screen ?: [self touchscreen];
        return [self convertScreenPointRelativeToAbsolute:[self centroidForTouch:primary otherTouch:secondary] onScreen:screen];
    }

    TUCScreen *screen = primary.screen ?: secondary.screen ?: [self touchscreen];
    return [self convertScreenPointRelativeToAbsolute:sourceState.lastCentroid onScreen:screen];
}

- (void)resetWindowsGestureForSourceState:(TUCInputSourceState *)sourceState endingButtons:(BOOL)endingButtons {
    if (endingButtons) {
        TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
        if (sourceState.activeGesture == TUCWindowsGestureKindTwoFingerScroll) {
            [utils cancelMomentumScroll];
        }
        if (sourceState.activeGesture == TUCWindowsGestureKindPinch) {
            [utils stopMagnifying];
        }
        [utils releaseAllButtons];
    }

    [self setWindowsGesture:TUCWindowsGestureKindIdle forSourceState:sourceState];
    sourceState.primaryContactID = NSNotFound;
    sourceState.secondaryContactID = NSNotFound;
    sourceState.gestureStartDate = nil;
    sourceState.primaryStartLocation = CGPointZero;
    sourceState.secondaryStartLocation = CGPointZero;
    sourceState.lastPrimaryLocation = CGPointZero;
    sourceState.lastSecondaryLocation = CGPointZero;
    sourceState.lastCentroid = CGPointZero;
    sourceState.initialTwoFingerDistance = 0;
    sourceState.lastTwoFingerDistance = 0;
    sourceState.tapCandidate = NO;
    sourceState.windowMoveCandidate = NO;
    sourceState.windowMoveStartScreenLocation = CGPointZero;
    sourceState.windowMoveWindowNumber = NSNotFound;
    sourceState.rightButtonIsDown = NO;
    sourceState.suppressClickUntilAllLifted = NO;
}

- (void)resetAllWindowsGesturesEndingButtons:(BOOL)endingButtons {
    for (TUCInputSourceState *sourceState in [_inputSourceStatesByIdentifier allValues]) {
        [self resetWindowsGestureForSourceState:sourceState endingButtons:endingButtons];
    }
    if (endingButtons) {
        [[TUCCursorUtilities sharedInstance] releaseAllButtons];
        [[TUCCursorUtilities sharedInstance] stopMagnifying];
    }
}

- (NSArray<TUCTouch *> *)activeTouchesSortedForSourceIdentifier:(NSInteger)sourceIdentifier {
    return [[[self activeTouchesForSourceIdentifier:sourceIdentifier] allObjects] sortedArrayUsingSelector:@selector(compareWithAnotherTouch:)];
}

- (NSArray<TUCTouch *> *)endedTouchesSortedForSourceIdentifier:(NSInteger)sourceIdentifier {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(TUCTouch *touch, NSDictionary *bindings) {
        return touch.sourceIdentifier == sourceIdentifier &&
               (touch.phase == NSTouchPhaseEnded || touch.phase == NSTouchPhaseCancelled);
    }];
    return [[[self.touchSet filteredSetUsingPredicate:predicate] allObjects] sortedArrayUsingSelector:@selector(compareWithAnotherTouch:)];
}

- (nullable TUCTouch *)activeTouchWithContactID:(NSInteger)contactID sourceIdentifier:(NSInteger)sourceIdentifier {
    return [self touchWithContactID:contactID inTouches:[self activeTouchesSortedForSourceIdentifier:sourceIdentifier]];
}

- (nullable TUCTouch *)touchWithContactID:(NSInteger)contactID inTouches:(NSArray<TUCTouch *> *)touches {
    if (contactID == NSNotFound) {
        return nil;
    }

    for (TUCTouch *touch in touches) {
        if (touch.contactID == contactID) {
            return touch;
        }
    }
    return nil;
}

- (CGFloat)distanceInMMFrom:(CGPoint)a to:(CGPoint)b onScreen:(TUCScreen *)screen {
    CGFloat dxMM = fabs(a.x - b.x) * screen.physicalSize.width;
    CGFloat dyMM = fabs(a.y - b.y) * screen.physicalSize.height;
    return sqrt(dxMM * dxMM + dyMM * dyMM);
}

- (CGPoint)absoluteLocationForTouch:(TUCTouch *)touch {
    TUCScreen *screen = touch.screen ?: [self touchscreen];
    return [self convertScreenPointRelativeToAbsolute:touch.location onScreen:screen];
}

- (CGPoint)applyCalibrationToPoint:(CGPoint)point onScreen:(TUCScreen *)screen {
    TUCTouchCalibration *calibration = [self calibrationForScreen:screen];
    return [calibration applyToPoint:point];
}

- (TUCTouchCalibration *)calibrationForScreen:(TUCScreen *)screen {
    if (screen.calibrationKey.length == 0) {
        return [TUCTouchCalibration identityCalibration];
    }

    TUCTouchCalibration *calibration = self.calibrationsByMonitorKey[screen.calibrationKey];
    return calibration ?: [TUCTouchCalibration identityCalibration];
}

- (CGPoint)centroidForTouch:(TUCTouch *)a otherTouch:(TUCTouch *)b {
    return CGPointMake((a.location.x + b.location.x) * 0.5,
                       (a.location.y + b.location.y) * 0.5);
}

- (CGFloat)relativeDistanceBetweenTouch:(TUCTouch *)a otherTouch:(TUCTouch *)b {
    CGFloat dx = a.location.x - b.location.x;
    CGFloat dy = a.location.y - b.location.y;
    return sqrt(dx * dx + dy * dy);
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
    TUCInputSourceState *sourceState = [self inputSourceStateForIdentifier:sourceIdentifier];
    [self resetWindowsGestureForSourceState:sourceState endingButtons:YES];

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
    return [self screenForTouchDevice:touchDevice screens:screens];
}

- (TUCScreen *)screenForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice screens:(NSArray<TUCScreen *> *)screens {
    if (screens.count == 0) return nil;
    [self refreshScreenTopologySignalsWithScreens:screens];

    NSArray<TUCTouchDeviceDescriptor *> *deviceDescriptors = [self touchDeviceDescriptorsIncludingTouchDevice:touchDevice];
    TUCTouchDeviceDescriptor *touchDeviceDescriptor = nil;
    for (TUCTouchDeviceDescriptor *descriptor in deviceDescriptors) {
        if (descriptor.sourceIdentifier == touchDevice.sourceIdentifier) {
            touchDeviceDescriptor = descriptor;
            break;
        }
    }

    if (!touchDeviceDescriptor) {
        return screens.firstObject;
    }

    NSDictionary<NSNumber *, NSNumber *> *hotPlugDisplayIDsByRegistryID = [self hotPlugDisplayIDsByRegistryIDForTouchDevice:touchDevice];
    NSArray<TUCScreenDescriptor *> *screenDescriptors = [self screenDescriptorsForScreens:screens];
    TUCTouchDisplayAssignmentResult *result = [self.displayAssignmentResolver assignmentForTouchDevice:touchDeviceDescriptor
                                                                                          touchDevices:deviceDescriptors
                                                                                               screens:screenDescriptors
                                                         learnedDisplayIDsBySourceIdentifier:self.learnedDisplayIDsBySourceIdentifier
                                                         learnedDisplayIDsByStableIdentifier:self.learnedDisplayIDsByStableIdentifier
                                                                 hotPlugDisplayIDsByRegistryID:hotPlugDisplayIDsByRegistryID];
    if (!result) {
        return screens.firstObject;
    }

    TUCScreen *screen = [self screenWithDisplayID:result.displayID screens:screens] ?: screens.firstObject;
    NSUInteger previousDisplayID = touchDevice.assignedDisplayID;
    TUCTouchDisplayAssignmentReason previousReason = touchDevice.assignmentReason;
    TUCTouchDisplayAssignmentConfidence previousConfidence = touchDevice.assignmentConfidence;
    BOOL assignmentChanged = previousDisplayID != 0 && previousDisplayID != screen.id;

    touchDevice.assignedDisplayID = screen.id;
    touchDevice.assignmentReason = result.reason;
    touchDevice.assignmentConfidence = result.confidence;

    NSString *stableIdentifier = [self stableIdentifierForTouchDevice:touchDevice];
    if (stableIdentifier.length > 0) {
        self.sessionDisplayIDsByStableIdentifier[stableIdentifier] = @(screen.id);
        self.sessionAssignmentConfidencesByStableIdentifier[stableIdentifier] = @(result.confidence);
    }

    if (assignmentChanged) {
        [self cancelTouchesForSourceIdentifier:touchDevice.sourceIdentifier];
    }

    if (previousDisplayID != screen.id ||
        previousReason != result.reason ||
        previousConfidence != result.confidence) {
        NSLog(@"[TouchUp] HID: assignment source=%ld name='%@' displayID=%lu display='%@' builtIn=%@ reason=%@ confidence=%@%@",
              (long)touchDevice.sourceIdentifier,
              touchDevice.name,
              (unsigned long)screen.id,
              screen.name,
              CGDisplayIsBuiltin((CGDirectDisplayID)screen.id) ? @"yes" : @"no",
              [result reasonName],
              [result confidenceName],
              assignmentChanged ? @" cancelledActiveTouches=yes" : @"");
    }

    return screen;
}

- (NSArray<TUCTouchDeviceDescriptor *> *)touchDeviceDescriptorsIncludingTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice {
    NSMutableArray<TUCUSBHIDTouchDevice *> *touchDevices = [[_hidTouchDevicesByRegistryID allValues] mutableCopy];
    BOOL containsCurrentDevice = NO;
    for (TUCUSBHIDTouchDevice *device in touchDevices) {
        if (device == touchDevice || device.sourceIdentifier == touchDevice.sourceIdentifier) {
            containsCurrentDevice = YES;
            break;
        }
    }

    if (!containsCurrentDevice) {
        [touchDevices addObject:touchDevice];
    }

    [touchDevices sortUsingComparator:^NSComparisonResult(TUCUSBHIDTouchDevice *a, TUCUSBHIDTouchDevice *b) {
        return [@(a.sourceIdentifier) compare:@(b.sourceIdentifier)];
    }];

    NSMutableArray<TUCTouchDeviceDescriptor *> *descriptors = [NSMutableArray arrayWithCapacity:touchDevices.count];
    for (TUCUSBHIDTouchDevice *device in touchDevices) {
        TUCTouchDeviceDescriptor *descriptor = [TUCTouchDeviceDescriptor new];
        descriptor.sourceIdentifier = device.sourceIdentifier;
        descriptor.registryID = device.registryID;
        descriptor.vendorID = device.vendorID;
        descriptor.productID = device.productID;
        descriptor.name = device.name ?: @"";
        descriptor.stableIdentifier = [self stableIdentifierForTouchDevice:device];
        descriptor.assignedDisplayID = device.assignedDisplayID;
        descriptor.previousAssignmentReason = device.assignmentReason;
        descriptor.previousAssignmentConfidence = device.assignmentConfidence;
        [descriptors addObject:descriptor];
    }

    return descriptors;
}

- (NSArray<TUCScreenDescriptor *> *)screenDescriptorsForScreens:(NSArray<TUCScreen *> *)screens {
    NSMutableArray<TUCScreenDescriptor *> *descriptors = [NSMutableArray arrayWithCapacity:screens.count];
    for (TUCScreen *screen in screens) {
        TUCScreenDescriptor *descriptor = [TUCScreenDescriptor new];
        descriptor.displayID = screen.id;
        descriptor.name = screen.name ?: @"";
        descriptor.calibrationKey = screen.calibrationKey ?: @"";
        descriptor.frame = screen.frame;
        descriptor.physicalSize = screen.physicalSize;
        descriptor.builtIn = CGDisplayIsBuiltin((CGDirectDisplayID)screen.id);
        [descriptors addObject:descriptor];
    }
    return descriptors;
}

- (NSDictionary<NSNumber *, NSNumber *> *)hotPlugDisplayIDsByRegistryIDForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice {
    NSNumber *displayID = self.hotPlugDisplayIDsByRegistryID[@(touchDevice.registryID)];
    if (!displayID) {
        return @{};
    }

    return @{@(touchDevice.registryID): displayID};
}

- (void)restoreSessionAssignmentForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice {
    NSString *stableIdentifier = [self stableIdentifierForTouchDevice:touchDevice];
    if (stableIdentifier.length == 0) {
        return;
    }

    for (TUCUSBHIDTouchDevice *existingDevice in [self.hidTouchDevicesByRegistryID allValues]) {
        if (existingDevice == touchDevice) {
            continue;
        }

        if ([[self stableIdentifierForTouchDevice:existingDevice] isEqualToString:stableIdentifier]) {
            return;
        }
    }

    NSNumber *displayID = self.sessionDisplayIDsByStableIdentifier[stableIdentifier];
    if (!displayID || displayID.unsignedIntegerValue == 0) {
        return;
    }

    NSNumber *confidence = self.sessionAssignmentConfidencesByStableIdentifier[stableIdentifier];
    touchDevice.assignedDisplayID = displayID.unsignedIntegerValue;
    touchDevice.assignmentReason = TUCTouchDisplayAssignmentReasonExistingAssignment;
    touchDevice.assignmentConfidence = confidence ? confidence.integerValue : TUCTouchDisplayAssignmentConfidenceLow;
}

- (void)recordTouchDeviceForAutomaticPairing:(TUCUSBHIDTouchDevice *)touchDevice {
    if (touchDevice.registryID == 0) {
        return;
    }

    NSString *stableIdentifier = [self stableIdentifierForTouchDevice:touchDevice];
    BOOL firstSeenStableIdentifier = ![self.knownTouchStableIdentifiers containsObject:stableIdentifier];
    [self.knownTouchStableIdentifiers addObject:stableIdentifier];

    if (!firstSeenStableIdentifier) {
        if (self.pendingHotPlugDisplayIDs.count > 0) {
            NSLog(@"[TouchUp] HID: automatic pairing skipped known touch controller source=%ld name='%@'",
                  (long)touchDevice.sourceIdentifier,
                  touchDevice.name);
        }
        return;
    }

    NSNumber *registryID = @(touchDevice.registryID);
    if (self.hotPlugDisplayIDsByRegistryID[registryID] ||
        [self.pendingHotPlugTouchRegistryIDs containsObject:registryID]) {
        return;
    }

    [self.pendingHotPlugTouchRegistryIDs addObject:registryID];
    [self pairPendingAutomaticAssignments];
}

- (void)pairPendingAutomaticAssignments {
    [self pruneExpiredAutomaticAssignmentSignals];

    while (self.pendingHotPlugDisplayIDs.count > 0 && self.pendingHotPlugTouchRegistryIDs.count > 0) {
        NSNumber *displayID = self.pendingHotPlugDisplayIDs.firstObject;
        NSNumber *registryID = self.pendingHotPlugTouchRegistryIDs.firstObject;

        [self.pendingHotPlugTouchRegistryIDs removeObjectAtIndex:0];

        TUCUSBHIDTouchDevice *touchDevice = self.hidTouchDevicesByRegistryID[registryID];
        if (!touchDevice || self.hotPlugDisplayIDsByRegistryID[registryID]) {
            continue;
        }

        NSDate *displayDate = self.pendingHotPlugDisplayDatesByID[displayID];
        if (displayDate) {
            NSTimeInterval touchAfterDisplay = [touchDevice.connectedDate timeIntervalSinceDate:displayDate];
            if (touchAfterDisplay < -TUCPreDisplayTouchCorrelationGrace) {
                NSLog(@"[TouchUp] HID: automatic pairing skipped stale touch registryID=%llu source=%ld displayID=%lu ageBeforeDisplay=%.2fs",
                      (unsigned long long)touchDevice.registryID,
                      (long)touchDevice.sourceIdentifier,
                      (unsigned long)displayID.unsignedIntegerValue,
                      fabs(touchAfterDisplay));
                continue;
            }
        }

        [self.pendingHotPlugDisplayIDs removeObjectAtIndex:0];
        [self.pendingHotPlugDisplayDatesByID removeObjectForKey:displayID];

        self.hotPlugDisplayIDsByRegistryID[registryID] = displayID;
        NSLog(@"[TouchUp] HID: automatic pairing registryID=%llu source=%ld displayID=%lu reason=connectionOrder",
              (unsigned long long)touchDevice.registryID,
              (long)touchDevice.sourceIdentifier,
              (unsigned long)displayID.unsignedIntegerValue);
    }
}

- (void)pruneExpiredAutomaticAssignmentSignals {
    NSDate *now = [NSDate date];

    NSMutableArray<NSNumber *> *validDisplayIDs = [NSMutableArray array];
    for (NSNumber *displayID in self.pendingHotPlugDisplayIDs) {
        NSDate *date = self.pendingHotPlugDisplayDatesByID[displayID];
        if (date && [now timeIntervalSinceDate:date] <= TUCDisplayHotPlugCorrelationInterval) {
            [validDisplayIDs addObject:displayID];
        } else {
            [self.pendingHotPlugDisplayDatesByID removeObjectForKey:displayID];
        }
    }
    self.pendingHotPlugDisplayIDs = validDisplayIDs;

    NSMutableArray<NSNumber *> *validRegistryIDs = [NSMutableArray array];
    for (NSNumber *registryID in self.pendingHotPlugTouchRegistryIDs) {
        TUCUSBHIDTouchDevice *touchDevice = self.hidTouchDevicesByRegistryID[registryID];
        if (touchDevice &&
            !self.hotPlugDisplayIDsByRegistryID[registryID] &&
            [now timeIntervalSinceDate:touchDevice.connectedDate] <= TUCDisplayHotPlugCorrelationInterval) {
            [validRegistryIDs addObject:registryID];
        }
    }
    self.pendingHotPlugTouchRegistryIDs = validRegistryIDs;
}

- (NSString *)stableIdentifierForTouchDevice:(TUCUSBHIDTouchDevice *)touchDevice {
    NSString *normalizedName = TUCNormalizedStableIdentifierComponent(touchDevice.name ?: @"");
    if (normalizedName.length == 0) {
        normalizedName = @"usb-hid-touch";
    }

    return [NSString stringWithFormat:@"usb:%ld:%ld:%@",
            (long)touchDevice.vendorID,
            (long)touchDevice.productID,
            normalizedName];
}

- (void)loadLearnedDisplayAssignments {
    NSDictionary *storedAssignments = [[NSUserDefaults standardUserDefaults] dictionaryForKey:TUCLearnedDisplayAssignmentsDefaultsKey];
    self.learnedDisplayIDsByStableIdentifier = [NSMutableDictionary dictionary];

    if (![storedAssignments isKindOfClass:[NSDictionary class]]) {
        return;
    }

    for (id key in storedAssignments) {
        id value = storedAssignments[key];
        if (![key isKindOfClass:[NSString class]] || ![value respondsToSelector:@selector(unsignedIntegerValue)]) {
            continue;
        }

        NSUInteger displayID = [value unsignedIntegerValue];
        if (displayID == 0) {
            continue;
        }

        self.learnedDisplayIDsByStableIdentifier[key] = @(displayID);
    }
}

- (void)persistLearnedDisplayAssignments {
    [[NSUserDefaults standardUserDefaults] setObject:[self.learnedDisplayIDsByStableIdentifier copy]
                                              forKey:TUCLearnedDisplayAssignmentsDefaultsKey];
}

- (void)refreshScreenTopologySignalsWithScreens:(NSArray<TUCScreen *> *)screens {
    NSMutableSet<NSNumber *> *currentDisplayIDs = [NSMutableSet setWithCapacity:screens.count];
    for (TUCScreen *screen in screens) {
        [currentDisplayIDs addObject:@(screen.id)];
    }

    if (!self.knownDisplayIDs) {
        self.knownDisplayIDs = currentDisplayIDs;
        return;
    }

    NSMutableSet<NSNumber *> *addedDisplayIDs = [currentDisplayIDs mutableCopy];
    [addedDisplayIDs minusSet:self.knownDisplayIDs];
    NSMutableSet<NSNumber *> *removedDisplayIDs = [self.knownDisplayIDs mutableCopy];
    [removedDisplayIDs minusSet:currentDisplayIDs];

    if (addedDisplayIDs.count > 0) {
        for (TUCScreen *screen in screens) {
            NSNumber *displayID = @(screen.id);
            if (![addedDisplayIDs containsObject:displayID] ||
                CGDisplayIsBuiltin((CGDirectDisplayID)screen.id)) {
                continue;
            }

            if (![self.pendingHotPlugDisplayIDs containsObject:displayID] &&
                ![[self.hotPlugDisplayIDsByRegistryID allValues] containsObject:displayID]) {
                [self.pendingHotPlugDisplayIDs addObject:displayID];
                self.pendingHotPlugDisplayDatesByID[displayID] = [NSDate date];
                NSLog(@"[TouchUp] HID: automatic pairing pending displayID=%lu display='%@'",
                      (unsigned long)screen.id,
                      screen.name);
            }
        }
    }

    if (removedDisplayIDs.count > 0) {
        for (NSNumber *displayID in removedDisplayIDs) {
            [self.pendingHotPlugDisplayIDs removeObject:displayID];
            [self.pendingHotPlugDisplayDatesByID removeObjectForKey:displayID];

            NSArray<NSNumber *> *registryIDs = [[self.hotPlugDisplayIDsByRegistryID allKeysForObject:displayID] copy];
            for (NSNumber *registryID in registryIDs) {
                [self.hotPlugDisplayIDsByRegistryID removeObjectForKey:registryID];
            }

            NSArray<NSString *> *stableIdentifiers = [[self.sessionDisplayIDsByStableIdentifier allKeysForObject:displayID] copy];
            for (NSString *stableIdentifier in stableIdentifiers) {
                [self.sessionDisplayIDsByStableIdentifier removeObjectForKey:stableIdentifier];
                [self.sessionAssignmentConfidencesByStableIdentifier removeObjectForKey:stableIdentifier];
            }
        }
    }

    self.knownDisplayIDs = currentDisplayIDs;
    [self pairPendingAutomaticAssignments];
}

- (TUCInputSourceState *)inputSourceStateForIdentifier:(NSInteger)sourceIdentifier {
    NSNumber *key = @(sourceIdentifier);
    TUCInputSourceState *sourceState = _inputSourceStatesByIdentifier[key];
    if (!sourceState) {
        sourceState = [TUCInputSourceState new];
        sourceState.sourceIdentifier = sourceIdentifier;
        sourceState.currentFrameID = 0;
        _inputSourceStatesByIdentifier[key] = sourceState;
    }
    return sourceState;
}


- (BOOL)accessibilityElementLooksDraggable:(AXUIElementRef)element {
    AXUIElementRef current = element ? (AXUIElementRef)CFRetain(element) : NULL;
    NSInteger depth = 0;
    BOOL firstElementWasControl = NO;

    while (current && depth < 6) {
        CFTypeRef roleValue = NULL;
        AXError roleError = AXUIElementCopyAttributeValue(current, kAXRoleAttribute, &roleValue);
        NSString *role = roleError == kAXErrorSuccess ? CFBridgingRelease(roleValue) : nil;

        if (depth == 0) {
            NSSet<NSString *> *controlRoles = [NSSet setWithArray:@[
                @"AXButton", @"AXCheckBox", @"AXRadioButton", @"AXPopUpButton",
                @"AXMenuButton", @"AXTextField", @"AXTextArea", @"AXSlider",
                @"AXScrollBar", @"AXComboBox"
            ]];
            firstElementWasControl = [controlRoles containsObject:role];
        }

        if ([role isEqualToString:@"AXTitleBar"]) {
            CFRelease(current);
            return !firstElementWasControl;
        }

        if ([role isEqualToString:@"AXToolbar"] && !firstElementWasControl) {
            CFRelease(current);
            return YES;
        }

        CFTypeRef parentValue = NULL;
        AXError parentError = AXUIElementCopyAttributeValue(current, kAXParentAttribute, &parentValue);
        CFRelease(current);

        if (parentError != kAXErrorSuccess || !parentValue) {
            break;
        }

        current = (AXUIElementRef)parentValue;
        depth++;
    }

    return NO;
}

- (BOOL)isPointInDraggableWindowArea:(CGPoint)screenPoint onScreen:(TUCScreen *)screen {
    if ([self isPointInMenuBar:screenPoint onScreen:screen]) {
        return NO;
    }

    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    AXUIElementRef element = NULL;
    BOOL axHit = NO;
    if (systemWide) {
        AXError error = AXUIElementCopyElementAtPosition(systemWide, screenPoint.x, screenPoint.y, &element);
        if (error == kAXErrorSuccess && element) {
            axHit = [self accessibilityElementLooksDraggable:element];
            CFRelease(element);
        }
        CFRelease(systemWide);
    }

    if (axHit) {
        return YES;
    }

    CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                       kCGNullWindowID);
    if (!windowList) {
        return NO;
    }

    BOOL result = NO;
    for (CFIndex i = 0; i < CFArrayGetCount(windowList); i++) {
        NSDictionary *window = CFBridgingRelease(CFRetain(CFArrayGetValueAtIndex(windowList, i)));
        NSInteger layer = [window[(NSString *)kCGWindowLayer] integerValue];
        if (layer != 0) {
            continue;
        }

        NSString *owner = window[(NSString *)kCGWindowOwnerName];
        if ([owner isEqualToString:@"Dock"] || [owner isEqualToString:@"Window Server"]) {
            continue;
        }

        CGRect bounds = CGRectZero;
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(NSString *)kCGWindowBounds], &bounds);
        if (!CGRectContainsPoint(bounds, screenPoint)) {
            continue;
        }

        result = [self isPointInApproximateTitlebar:screenPoint windowBounds:bounds];
        break;
    }

    CFRelease(windowList);
    return result;
}

- (BOOL)isPointInApproximateTitlebar:(CGPoint)screenPoint windowBounds:(CGRect)windowBounds {
    if (CGRectIsEmpty(windowBounds) || windowBounds.size.height < 80 || windowBounds.size.width < 80) {
        return NO;
    }

    CGFloat titlebarHeight = MIN(44.0, MAX(28.0, windowBounds.size.height * 0.12));
    CGRect titlebar = CGRectMake(windowBounds.origin.x,
                                 windowBounds.origin.y,
                                 windowBounds.size.width,
                                 titlebarHeight);
    return CGRectContainsPoint(titlebar, screenPoint);
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
        self.displayAssignmentResolver = [TUCTouchDisplayAssignmentResolver new];
        self.learnedDisplayIDsBySourceIdentifier = [NSMutableDictionary dictionary];
        self.pendingHotPlugDisplayIDs = [NSMutableArray array];
        self.pendingHotPlugTouchRegistryIDs = [NSMutableArray array];
        self.pendingHotPlugDisplayDatesByID = [NSMutableDictionary dictionary];
        self.hotPlugDisplayIDsByRegistryID = [NSMutableDictionary dictionary];
        self.knownTouchStableIdentifiers = [NSMutableSet set];
        self.sessionDisplayIDsByStableIdentifier = [NSMutableDictionary dictionary];
        self.sessionAssignmentConfidencesByStableIdentifier = [NSMutableDictionary dictionary];
        [self loadLearnedDisplayAssignments];
        self.nextTouchDeviceIdentifier = 1;
        self.calibrationsByMonitorKey = @{};
        
        self.doubleClickTolerance = 5;
        self.holdDuration = TUCDefaultHoldDuration;
        self.windowTitleBarDragEnabled = YES;
        self.twoFingerTapSecondaryClickEnabled = YES;
        self.twoFingerScrollEnabled = YES;
        self.errorResistance = 0;
        
        self.ignoreOriginTouches = NO;
    }
    return self;
}


- (NSString *)debugDescription {
    NSMutableString *str = [[NSString stringWithFormat:@"Touch Set contains %ld touches:{\n", [self.touchSet count]] mutableCopy];
    
    for (TUCTouch *touch in [[self.touchSet allObjects] sortedArrayUsingSelector:@selector(compareWithAnotherTouch:)] ) {
        [str appendString: [NSString stringWithFormat:@"  %@", [touch debugDescription]] ];
        BOOL isPrimaryTouch = NO;
        BOOL isSecondaryTouch = NO;
        for (TUCInputSourceState *sourceState in [_inputSourceStatesByIdentifier allValues]) {
            if (sourceState.sourceIdentifier == touch.sourceIdentifier &&
                sourceState.primaryContactID == touch.contactID) {
                isPrimaryTouch = YES;
            }
            if (sourceState.sourceIdentifier == touch.sourceIdentifier &&
                sourceState.secondaryContactID == touch.contactID) {
                isSecondaryTouch = YES;
            }
        }
        if (isPrimaryTouch) {
            [str appendString: @" <<<PRIMARY>>>\n" ];
        } else if (isSecondaryTouch) {
            [str appendString: @" <<<SECONDARY>>>\n" ];
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
