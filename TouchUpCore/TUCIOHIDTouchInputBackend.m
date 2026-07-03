//
//  TUCIOHIDTouchInputBackend.m
//  TouchUpCore
//

#import "TUCIOHIDTouchInputBackend.h"

#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hid/IOHIDElement.h>
#import <IOKit/hidsystem/IOHIDLib.h>

@class TUCIOHIDTouchInputBackend;

@interface TUCIOHIDTouchContact : NSObject

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

@implementation TUCIOHIDTouchContact

- (instancetype)init {
    if (self = [super init]) {
        _fallbackContactID = NSNotFound;
        _contactID = NSNotFound;
        _isValid = YES;
    }
    return self;
}

@end

@interface TUCIOHIDTouchDevice : TUCTouchBackendDevice

@property (weak, nullable) TUCIOHIDTouchInputBackend *backend;
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
@property uint64_t nextFrameSequence;
@property (strong) NSMutableDictionary<NSValue *, TUCIOHIDTouchContact *> *hidContactsByCollection;
@property (strong) NSMutableArray<TUCIOHIDTouchContact *> *hidContacts;

- (void)close;

@end

@implementation TUCIOHIDTouchDevice

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

@interface TUCIOHIDTouchInputBackend ()

@property IONotificationPortRef usbNotificationPort;
@property io_iterator_t usbAppearedIterator;
@property io_iterator_t usbRemovedIterator;
@property (strong) NSMutableDictionary<NSNumber *, TUCIOHIDTouchDevice *> *hidTouchDevicesByRegistryID;
@property NSInteger nextTouchDeviceIdentifier;

- (void)handleUSBIterator:(io_iterator_t)iterator appeared:(BOOL)appeared;
- (void)considerHIDDevice:(io_service_t)hidDevice;
- (void)openIOHIDDevice:(io_service_t)hidService properties:(NSDictionary *)properties requiresAbsolutePointer:(BOOL)requiresAbsolutePointer;
- (BOOL)configureTouchDevice:(TUCIOHIDTouchDevice *)touchDevice
             fromIOHIDDevice:(IOHIDDeviceRef)device
     requiresAbsolutePointer:(BOOL)requiresTouchButton;
- (nullable TUCIOHIDTouchContact *)contactForHIDElement:(IOHIDElementRef)element
                                            touchDevice:(TUCIOHIDTouchDevice *)touchDevice
                                                 create:(BOOL)create;
- (void)scheduleProcessHIDValuesForTouchDevice:(TUCIOHIDTouchDevice *)touchDevice;
- (void)processHIDValuesForTouchDevice:(TUCIOHIDTouchDevice *)touchDevice;
- (nullable TUCIOHIDTouchContact *)primaryEnabledContactForTouchDevice:(TUCIOHIDTouchDevice *)touchDevice;
- (BOOL)processRawHIDReportForTouchDevice:(TUCIOHIDTouchDevice *)touchDevice
                                  reportID:(uint32_t)reportID
                                    report:(uint8_t *)report
                                    length:(CFIndex)len;
- (void)scheduleRawReportLiftForTouchDevice:(TUCIOHIDTouchDevice *)touchDevice
                                  contactID:(NSInteger)contactID;
- (void)refreshHIDContact:(TUCIOHIDTouchContact *)contact touchDevice:(TUCIOHIDTouchDevice *)touchDevice;
- (void)dispatchContacts:(NSArray<TUCTouchBackendContact *> *)contacts
          forTouchDevice:(TUCIOHIDTouchDevice *)touchDevice;

@end

static void hidValueCallback(void *ctx, IOReturn result, void *sender, IOHIDValueRef value);
static void hidReportCallback(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                              uint32_t reportID, uint8_t *report, CFIndex len);
static void usbAppearedCallback(void *refcon, io_iterator_t iterator);
static void usbRemovedCallback(void *refcon, io_iterator_t iterator);

@implementation TUCIOHIDTouchInputBackend

@synthesize delegate = _delegate;

static const uint32_t TUC_HID_USAGE_DIG_FINGER = 0x22;
static const uint32_t TUC_HID_USAGE_DIG_TOUCHSCREEN = 0x04;
static const NSTimeInterval TUCRawReportLiftTimeout = 0.20;

static BOOL TUCShouldUseSISRawReportFallback(TUCIOHIDTouchDevice *touchDevice) {
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

- (instancetype)init {
    if (self = [super init]) {
        _hidTouchDevicesByRegistryID = [NSMutableDictionary dictionary];
        _nextTouchDeviceIdentifier = 1;
    }
    return self;
}

- (TUCTouchBackendAccessState *)accessState {
    return [TUCTouchBackendAccessState stateWithGranted:TUCHIDListenEventAccessGranted()
                                      statusDescription:TUCListenEventAccessDescription()];
}

- (BOOL)requestAccess {
    if (@available(macOS 10.15, *)) {
        BOOL hidGranted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        BOOL granted = hidGranted || TUCHIDListenEventAccessGranted();
        NSLog(@"[TouchUp] HID: requested Input Monitoring access (%@)", TUCListenEventAccessDescription());
        [self.delegate touchInputBackend:self accessStateDidChange:self.accessState];
        return granted;
    }
    return YES;
}

- (NSArray<TUCTouchBackendDevice *> *)connectedDevices {
    return [[self.hidTouchDevicesByRegistryID allValues] sortedArrayUsingComparator:^NSComparisonResult(TUCIOHIDTouchDevice *a, TUCIOHIDTouchDevice *b) {
        return [@(a.sourceIdentifier) compare:@(b.sourceIdentifier)];
    }];
}

- (void)start {
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

- (void)stop {
    for (TUCIOHIDTouchDevice *touchDevice in [_hidTouchDevicesByRegistryID allValues]) {
        [touchDevice close];
    }
    [_hidTouchDevicesByRegistryID removeAllObjects];

    if (_usbAppearedIterator) { IOObjectRelease(_usbAppearedIterator); _usbAppearedIterator = 0; }
    if (_usbRemovedIterator)  { IOObjectRelease(_usbRemovedIterator);  _usbRemovedIterator  = 0; }
    if (_usbNotificationPort) { IONotificationPortDestroy(_usbNotificationPort); _usbNotificationPort = nil; }
}

static void hidValueCallback(void *ctx, IOReturn result, void *sender, IOHIDValueRef value) {
    if (result != kIOReturnSuccess) return;
    TUCIOHIDTouchDevice *touchDevice = (__bridge TUCIOHIDTouchDevice *)ctx;
    IOHIDElementRef elem = IOHIDValueGetElement(value);
    uint32_t up   = IOHIDElementGetUsagePage(elem);
    uint32_t u    = IOHIDElementGetUsage(elem);
    CFIndex  val  = IOHIDValueGetIntegerValue(value);
    CFIndex  lMin = IOHIDElementGetLogicalMin(elem);
    CFIndex  lMax = IOHIDElementGetLogicalMax(elem);
    if (lMax <= lMin) return;

    if (!TUCIsTouchValueUsage(up, u)) return;

    TUCIOHIDTouchContact *contact = [touchDevice.backend contactForHIDElement:elem touchDevice:touchDevice create:NO];
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

    [touchDevice.backend scheduleProcessHIDValuesForTouchDevice:touchDevice];
}

static void hidReportCallback(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                              uint32_t reportID, uint8_t *report, CFIndex len) {
    if (result != kIOReturnSuccess || len <= 0) return;
    if (type != kIOHIDReportTypeInput) return;

    TUCIOHIDTouchDevice *touchDevice = (__bridge TUCIOHIDTouchDevice *)ctx;
    if (!touchDevice.loggedFirstHIDReport) {
        touchDevice.loggedFirstHIDReport = YES;
        NSLog(@"[TouchUp] HID: first input report source=%ld reportID=%u length=%ld bytes=%@",
              (long)touchDevice.sourceIdentifier,
              reportID,
              (long)len,
              TUCHexStringForHIDReport(report, len));
    }

    if ([touchDevice.backend processRawHIDReportForTouchDevice:touchDevice
                                                      reportID:reportID
                                                        report:report
                                                        length:len]) {
        return;
    }

    [touchDevice.backend scheduleProcessHIDValuesForTouchDevice:touchDevice];
}

static void usbAppearedCallback(void *refcon, io_iterator_t iterator) {
    [(__bridge TUCIOHIDTouchInputBackend *)refcon handleUSBIterator:iterator appeared:YES];
}
static void usbRemovedCallback(void *refcon, io_iterator_t iterator) {
    [(__bridge TUCIOHIDTouchInputBackend *)refcon handleUSBIterator:iterator appeared:NO];
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

- (BOOL)configureTouchDevice:(TUCIOHIDTouchDevice *)touchDevice
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

        TUCIOHIDTouchContact *contact = [self contactForHIDElement:element touchDevice:touchDevice create:YES];
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
    for (TUCIOHIDTouchContact *contact in touchDevice.hidContacts) {
        if (contact.isDigitizerContact &&
            contact.supportsX &&
            contact.supportsY &&
            (contact.supportsSurfaceState || contact.supportsValidityState)) {
            hasDigitizerContact = YES;
            break;
        }
    }

    NSMutableArray<TUCIOHIDTouchContact *> *enabledContacts = [NSMutableArray array];
    NSInteger validityContacts = 0;
    for (TUCIOHIDTouchContact *contact in touchDevice.hidContacts) {
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

- (TUCIOHIDTouchContact *)contactForHIDElement:(IOHIDElementRef)element
                                   touchDevice:(TUCIOHIDTouchDevice *)touchDevice
                                        create:(BOOL)create {
    BOOL isDigitizerContact = NO;
    IOHIDElementRef collection = TUCContactCollectionForElement(element, &isDigitizerContact);
    if (!collection) return nil;

    NSValue *key = [NSValue valueWithPointer:collection];
    TUCIOHIDTouchContact *contact = touchDevice.hidContactsByCollection[key];
    if (!contact && create) {
        contact = [TUCIOHIDTouchContact new];
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

- (void)openIOHIDDevice:(io_service_t)hidService properties:(NSDictionary *)properties requiresAbsolutePointer:(BOOL)requiresAbsolutePointer {
    uint64_t registryID = [self registryIDForService:hidService];
    NSNumber *registryKey = @(registryID);
    if (registryID != 0 && _hidTouchDevicesByRegistryID[registryKey] != nil) return;

    IOHIDDeviceRef device = IOHIDDeviceCreate(kCFAllocatorDefault, hidService);
    if (!device) {
        NSLog(@"[TouchUp] HID: IOHIDDeviceCreate failed");
        return;
    }

    TUCIOHIDTouchDevice *touchDevice = [TUCIOHIDTouchDevice new];
    touchDevice.backend = self;
    touchDevice.sourceIdentifier = self.nextTouchDeviceIdentifier++;
    touchDevice.registryID = registryID;
    touchDevice.vendorID = [properties[@"VendorID"] integerValue];
    touchDevice.productID = [properties[@"ProductID"] integerValue];
    touchDevice.name = [self displayNameForHIDProperties:properties];
    touchDevice.connectedDate = [NSDate date];
    touchDevice.requiresTCCAuthorization = [properties[@"RequiresTCCAuthorization"] boolValue];

    if (!TUCHIDListenEventAccessGranted()) {
        NSLog(@"[TouchUp] HID: Input Monitoring access %@ - attempting open so macOS can register '%@' (RequiresTCCAuthorization=%@)",
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
    touchDevice.hidDeviceRef = device;

    if (![self configureTouchDevice:touchDevice fromIOHIDDevice:device requiresAbsolutePointer:requiresAbsolutePointer]) {
        NSLog(@"[TouchUp] HID: no usable touch descriptor profile - skipping '%@'", touchDevice.name);
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
    [self.delegate touchInputBackend:self deviceDidConnect:touchDevice];

    NSUInteger bufSize = 512;
    touchDevice.hidReportBuffer = [NSMutableData dataWithLength:bufSize];

    IOHIDDeviceRegisterInputValueCallback(device, hidValueCallback, (__bridge void *)touchDevice);
    IOHIDDeviceRegisterInputReportCallback(device, touchDevice.hidReportBuffer.mutableBytes,
                                           (CFIndex)bufSize, hidReportCallback, (__bridge void *)touchDevice);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), kCFRunLoopCommonModes);

    NSLog(@"[TouchUp] HID: device opened, source=%ld name='%@' VendorID=%ld ProductID=%ld listening for values",
          (long)touchDevice.sourceIdentifier,
          touchDevice.name,
          (long)touchDevice.vendorID,
          (long)touchDevice.productID);
}

- (void)removeHIDDeviceForService:(io_service_t)hidService {
    NSNumber *matchedKey = nil;
    TUCIOHIDTouchDevice *matchedDevice = nil;
    for (NSNumber *key in _hidTouchDevicesByRegistryID) {
        TUCIOHIDTouchDevice *touchDevice = _hidTouchDevicesByRegistryID[key];
        if (touchDevice.hidDeviceRef && IOObjectIsEqualTo(IOHIDDeviceGetService(touchDevice.hidDeviceRef), hidService)) {
            matchedKey = key;
            matchedDevice = touchDevice;
            break;
        }
    }

    if (!matchedDevice) return;

    [self.delegate touchInputBackend:self deviceDidDisconnect:matchedDevice];
    [matchedDevice close];
    [_hidTouchDevicesByRegistryID removeObjectForKey:matchedKey];

    NSLog(@"[TouchUp] HID: device removed, source=%ld name='%@'",
          (long)matchedDevice.sourceIdentifier,
          matchedDevice.name);
}

- (void)scheduleProcessHIDValuesForTouchDevice:(TUCIOHIDTouchDevice *)touchDevice {
    if (touchDevice.usesRawReportFallback) return;
    if (touchDevice.hidDispatchPending) return;
    touchDevice.hidDispatchPending = YES;

    __weak TUCIOHIDTouchInputBackend *weakSelf = self;
    __weak TUCIOHIDTouchDevice *weakTouchDevice = touchDevice;
    dispatch_async(dispatch_get_main_queue(), ^{
        TUCIOHIDTouchInputBackend *strongSelf = weakSelf;
        TUCIOHIDTouchDevice *strongTouchDevice = weakTouchDevice;
        if (!strongSelf || !strongTouchDevice || !strongTouchDevice.hidDeviceRef) return;

        strongTouchDevice.hidDispatchPending = NO;
        [strongSelf processHIDValuesForTouchDevice:strongTouchDevice];
    });
}

- (void)processHIDValuesForTouchDevice:(TUCIOHIDTouchDevice *)touchDevice {
    NSMutableArray<TUCTouchBackendContact *> *backendContacts = [NSMutableArray array];

    for (TUCIOHIDTouchContact *contact in touchDevice.hidContacts) {
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
            NSLog(@"[TouchUp] HID: first touch frame source=%ld contact=%ld x=%.4f y=%.4f",
                  (long)touchDevice.sourceIdentifier,
                  (long)contactID,
                  x,
                  y);
        }

        TUCTouchBackendContact *backendContact = [TUCTouchBackendContact new];
        backendContact.contactID = contactID;
        backendContact.location = CGPointMake(x, y);
        backendContact.onSurface = onSurface;
        backendContact.valid = contact.isValid;
        [backendContacts addObject:backendContact];

        contact.wasDispatchedOnSurface = onSurface;
    }

    [self dispatchContacts:backendContacts forTouchDevice:touchDevice];
}

- (nullable TUCIOHIDTouchContact *)primaryEnabledContactForTouchDevice:(TUCIOHIDTouchDevice *)touchDevice {
    for (TUCIOHIDTouchContact *contact in touchDevice.hidContacts) {
        if (contact.enabled) {
            return contact;
        }
    }

    return nil;
}

- (BOOL)processRawHIDReportForTouchDevice:(TUCIOHIDTouchDevice *)touchDevice
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

    TUCIOHIDTouchContact *contact = [self primaryEnabledContactForTouchDevice:touchDevice];
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
        NSLog(@"[TouchUp] HID: first touch frame source=%ld contact=%ld x=%.4f y=%.4f rawFallback=yes status=0x%02x rawX=%u rawY=%u",
              (long)touchDevice.sourceIdentifier,
              (long)contactID,
              point.x,
              point.y,
              status,
              rawX,
              rawY);
    }

    TUCTouchBackendContact *backendContact = [TUCTouchBackendContact new];
    backendContact.contactID = contactID;
    backendContact.location = point;
    backendContact.onSurface = onSurface;
    backendContact.valid = YES;
    [self dispatchContacts:@[backendContact] forTouchDevice:touchDevice];

    if (onSurface) {
        [self scheduleRawReportLiftForTouchDevice:touchDevice contactID:contactID];
    }

    return YES;
}

- (void)scheduleRawReportLiftForTouchDevice:(TUCIOHIDTouchDevice *)touchDevice
                                  contactID:(NSInteger)contactID {
    NSUInteger generation = touchDevice.rawReportDispatchGeneration;
    __weak TUCIOHIDTouchInputBackend *weakSelf = self;
    __weak TUCIOHIDTouchDevice *weakTouchDevice = touchDevice;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TUCRawReportLiftTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TUCIOHIDTouchInputBackend *strongSelf = weakSelf;
        TUCIOHIDTouchDevice *strongTouchDevice = weakTouchDevice;
        if (!strongSelf ||
            !strongTouchDevice ||
            !strongTouchDevice.hidDeviceRef ||
            !strongTouchDevice.rawReportContactActive ||
            strongTouchDevice.rawReportDispatchGeneration != generation) {
            return;
        }

        strongTouchDevice.rawReportContactActive = NO;
        strongTouchDevice.rawReportDispatchGeneration += 1;

        TUCTouchBackendContact *backendContact = [TUCTouchBackendContact new];
        backendContact.contactID = contactID;
        backendContact.location = strongTouchDevice.lastRawReportPoint;
        backendContact.onSurface = NO;
        backendContact.valid = YES;
        [strongSelf dispatchContacts:@[backendContact] forTouchDevice:strongTouchDevice];
    });
}

- (void)refreshHIDContact:(TUCIOHIDTouchContact *)contact touchDevice:(TUCIOHIDTouchDevice *)touchDevice {
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

- (void)dispatchContacts:(NSArray<TUCTouchBackendContact *> *)contacts
          forTouchDevice:(TUCIOHIDTouchDevice *)touchDevice {
    TUCTouchBackendFrame *frame = [TUCTouchBackendFrame new];
    frame.device = touchDevice;
    frame.contacts = contacts;
    frame.sequenceNumber = touchDevice.nextFrameSequence++;
    frame.timestamp = [NSDate timeIntervalSinceReferenceDate];
    [self.delegate touchInputBackend:self didReceiveTouchFrame:frame];
}

@end
