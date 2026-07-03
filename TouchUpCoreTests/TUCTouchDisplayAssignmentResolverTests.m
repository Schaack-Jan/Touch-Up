//
//  TUCTouchDisplayAssignmentResolverTests.m
//  TouchUpCoreTests
//

@import XCTest;
@import TouchUpCore;

@interface TUCTouchInputManager (TouchUpCoreTests)

@property (strong) id<TUCTouchInputBackend> inputBackend;

- (void)updateTouch:(NSInteger)contactID
       withLocation:(CGPoint)digitizerPoint
          onSurface:(BOOL)isOnSurface
  tooLargeForFinger:(BOOL)confidenceFlag
             screen:(nullable TUCScreen *)screen
   sourceIdentifier:(NSInteger)sourceIdentifier;
- (CGPoint)absoluteLocationForTouch:(TUCTouch *)touch;
- (void)cancelTouchesForSourceIdentifier:(NSInteger)sourceIdentifier;
- (TUCScreen *)touchscreen;

@end

@interface TUCTestTouchInputManager : TUCTouchInputManager

@property (strong) TUCScreen *testScreen;

@end

@implementation TUCTestTouchInputManager

- (TUCScreen *)screenForTouchDevice:(TUCTouchBackendDevice *)touchDevice {
    return self.testScreen ?: [super touchscreen];
}

@end

@interface TUCFakeTouchInputBackend : NSObject <TUCTouchInputBackend>

@property (weak, nonatomic, nullable) id<TUCTouchInputBackendDelegate> delegate;
@property (strong, nonatomic, readonly) TUCTouchBackendAccessState *accessState;
@property BOOL started;
@property BOOL stopped;
@property (strong) NSMutableArray<TUCTouchBackendDevice *> *devices;

- (TUCTouchBackendDevice *)connectDeviceWithSourceIdentifier:(NSInteger)sourceIdentifier;
- (void)disconnectDevice:(TUCTouchBackendDevice *)device;
- (void)sendContactID:(NSInteger)contactID
             location:(CGPoint)location
            onSurface:(BOOL)onSurface
                device:(TUCTouchBackendDevice *)device;

@end

@implementation TUCFakeTouchInputBackend

- (instancetype)init {
    if (self = [super init]) {
        _devices = [NSMutableArray array];
        _accessState = [TUCTouchBackendAccessState stateWithGranted:YES statusDescription:@"fake=granted"];
    }
    return self;
}

- (void)start {
    self.started = YES;
    self.stopped = NO;
}

- (void)stop {
    self.stopped = YES;
}

- (NSArray<TUCTouchBackendDevice *> *)connectedDevices {
    return [self.devices copy];
}

- (BOOL)requestAccess {
    return YES;
}

- (TUCTouchBackendDevice *)connectDeviceWithSourceIdentifier:(NSInteger)sourceIdentifier {
    TUCTouchBackendDevice *device = [TUCTouchBackendDevice new];
    device.sourceIdentifier = sourceIdentifier;
    device.registryID = (uint64_t)(1000 + sourceIdentifier);
    device.vendorID = 1234;
    device.productID = 5678;
    device.name = [NSString stringWithFormat:@"Fake Touch %ld", (long)sourceIdentifier];
    device.connectedDate = [NSDate date];
    [self.devices addObject:device];
    [self.delegate touchInputBackend:self deviceDidConnect:device];
    return device;
}

- (void)disconnectDevice:(TUCTouchBackendDevice *)device {
    [self.delegate touchInputBackend:self deviceDidDisconnect:device];
    [self.devices removeObject:device];
}

- (void)sendContactID:(NSInteger)contactID
             location:(CGPoint)location
            onSurface:(BOOL)onSurface
                device:(TUCTouchBackendDevice *)device {
    TUCTouchBackendContact *contact = [TUCTouchBackendContact new];
    contact.contactID = contactID;
    contact.location = location;
    contact.onSurface = onSurface;
    contact.valid = YES;

    TUCTouchBackendFrame *frame = [TUCTouchBackendFrame new];
    frame.device = device;
    frame.contacts = @[contact];
    frame.sequenceNumber = 1;
    frame.timestamp = [NSDate timeIntervalSinceReferenceDate];
    [self.delegate touchInputBackend:self didReceiveTouchFrame:frame];
}

@end

@interface TUCTouchDisplayAssignmentResolverTests : XCTestCase
@end

@implementation TUCTouchDisplayAssignmentResolverTests

- (void)testExistingValidDisplayIDIsReused {
    TUCTouchDeviceDescriptor *device = [self deviceWithSource:1 registryID:101 name:@"USB Touch" assignedDisplayID:20];
    device.previousAssignmentConfidence = TUCTouchDisplayAssignmentConfidenceHigh;

    TUCTouchDisplayAssignmentResult *result = [self resolveDevice:device
                                                          devices:@[device]
                                                          screens:@[[self screenWithID:10 name:@"Built-in"], [self screenWithID:20 name:@"Touch Display"]]
                                                          learned:@{}
                                                          hotPlug:@{}];

    XCTAssertEqual(result.displayID, 20);
    XCTAssertEqual(result.reason, TUCTouchDisplayAssignmentReasonExistingAssignment);
}

- (void)testStaleDisplayIDFallsBackToAvailableScreen {
    TUCTouchDeviceDescriptor *device = [self deviceWithSource:1 registryID:101 name:@"USB Touch" assignedDisplayID:99];
    device.previousAssignmentConfidence = TUCTouchDisplayAssignmentConfidenceHigh;

    TUCTouchDisplayAssignmentResult *result = [self resolveDevice:device
                                                          devices:@[device]
                                                          screens:@[[self screenWithID:10 name:@"Built-in"]]
                                                          learned:@{}
                                                          hotPlug:@{}];

    XCTAssertEqual(result.displayID, 10);
    XCTAssertEqual(result.reason, TUCTouchDisplayAssignmentReasonSingleScreen);
}

- (void)testExactNameMatchSelectsMatchingScreen {
    TUCTouchDeviceDescriptor *device = [self deviceWithSource:1 registryID:101 name:@"Dell P2418HT" assignedDisplayID:0];

    TUCTouchDisplayAssignmentResult *result = [self resolveDevice:device
                                                          devices:@[device]
                                                          screens:@[[self screenWithID:10 name:@"Built-in"], [self screenWithID:20 name:@"DELL P2418HT"]]
                                                          learned:@{}
                                                          hotPlug:@{}];

    XCTAssertEqual(result.displayID, 20);
    XCTAssertEqual(result.reason, TUCTouchDisplayAssignmentReasonNameMatch);
    XCTAssertEqual(result.confidence, TUCTouchDisplayAssignmentConfidenceHigh);
}

- (void)testSubstringAndTokenNameMatchesAreStable {
    TUCTouchDeviceDescriptor *substringDevice = [self deviceWithSource:1 registryID:101 name:@"iiyama ProLite T2336MSC Touch" assignedDisplayID:0];
    TUCTouchDisplayAssignmentResult *substringResult = [self resolveDevice:substringDevice
                                                                   devices:@[substringDevice]
                                                                   screens:@[[self screenWithID:10 name:@"Built-in"], [self screenWithID:20 name:@"ProLite T2336MSC-B2"]]
                                                                   learned:@{}
                                                                   hotPlug:@{}];

    XCTAssertEqual(substringResult.displayID, 20);
    XCTAssertEqual(substringResult.reason, TUCTouchDisplayAssignmentReasonNameMatch);

    TUCTouchDeviceDescriptor *tokenDevice = [self deviceWithSource:2 registryID:102 name:@"Vendor C4667PW Touch Device" assignedDisplayID:0];
    TUCTouchDisplayAssignmentResult *tokenResult = [self resolveDevice:tokenDevice
                                                               devices:@[tokenDevice]
                                                               screens:@[[self screenWithID:10 name:@"Built-in"], [self screenWithID:30 name:@"3M MicroTouch C4667PW"]]
                                                               learned:@{}
                                                               hotPlug:@{}];

    XCTAssertEqual(tokenResult.displayID, 30);
    XCTAssertEqual(tokenResult.reason, TUCTouchDisplayAssignmentReasonNameMatch);
}

- (void)testAmbiguousNameMatchesUseDeterministicFallback {
    TUCTouchDeviceDescriptor *device = [self deviceWithSource:1 registryID:101 name:@"ProLite Touch" assignedDisplayID:0];

    TUCTouchDisplayAssignmentResult *result = [self resolveDevice:device
                                                          devices:@[device]
                                                          screens:@[[self screenWithID:10 name:@"ProLite Left"], [self screenWithID:20 name:@"ProLite Right"]]
                                                          learned:@{}
                                                          hotPlug:@{}];

    XCTAssertEqual(result.displayID, 10);
    XCTAssertEqual(result.reason, TUCTouchDisplayAssignmentReasonNextUnassigned);
}

- (void)testUnrelatedControllerAndDisplayNamesDoNotUseVendorAliases {
    TUCTouchDeviceDescriptor *device = [self deviceWithSource:1 registryID:101 name:@"Siliconworks SiW HID Touch Controller" assignedDisplayID:0];

    TUCTouchDisplayAssignmentResult *result = [self resolveDevice:device
                                                          devices:@[device]
                                                          screens:@[[self screenWithID:1 name:@"Built-in Retina Display" builtIn:YES],
                                                                    [self screenWithID:2 name:@"Display" builtIn:NO],
                                                                    [self screenWithID:3 name:@"DELL P2424HT" builtIn:NO]]
                                                          learned:@{}
                                                          hotPlug:@{}];

    XCTAssertEqual(result.displayID, 2);
    XCTAssertEqual(result.reason, TUCTouchDisplayAssignmentReasonNextUnassigned);
    XCTAssertEqual(result.confidence, TUCTouchDisplayAssignmentConfidenceLow);
}

- (void)testSingleDeviceSingleScreenUsesSingleScreenReason {
    TUCTouchDeviceDescriptor *device = [self deviceWithSource:1 registryID:101 name:@"USB Touch" assignedDisplayID:0];

    TUCTouchDisplayAssignmentResult *result = [self resolveDevice:device
                                                          devices:@[device]
                                                          screens:@[[self screenWithID:10 name:@"Only Screen"]]
                                                          learned:@{}
                                                          hotPlug:@{}];

    XCTAssertEqual(result.displayID, 10);
    XCTAssertEqual(result.reason, TUCTouchDisplayAssignmentReasonSingleScreen);
}

- (void)testUnassignedFallbackPrefersExternalScreensBeforeBuiltInDisplay {
    TUCTouchDeviceDescriptor *device = [self deviceWithSource:1 registryID:101 name:@"USB Touch" assignedDisplayID:0];

    TUCTouchDisplayAssignmentResult *result = [self resolveDevice:device
                                                          devices:@[device]
                                                          screens:@[[self screenWithID:1 name:@"Built-in Retina Display" builtIn:YES],
                                                                    [self screenWithID:2 name:@"External Touch" builtIn:NO]]
                                                          learned:@{}
                                                          hotPlug:@{}];

    XCTAssertEqual(result.displayID, 2);
    XCTAssertEqual(result.reason, TUCTouchDisplayAssignmentReasonNextUnassigned);
}

- (void)testMultipleDevicesPreferUniqueUnassignedScreens {
    TUCTouchDeviceDescriptor *deviceA = [self deviceWithSource:1 registryID:101 name:@"USB Touch A" assignedDisplayID:10];
    deviceA.previousAssignmentConfidence = TUCTouchDisplayAssignmentConfidenceLow;
    TUCTouchDeviceDescriptor *deviceB = [self deviceWithSource:2 registryID:102 name:@"USB Touch B" assignedDisplayID:0];

    TUCTouchDisplayAssignmentResult *result = [self resolveDevice:deviceB
                                                          devices:@[deviceA, deviceB]
                                                          screens:@[[self screenWithID:10 name:@"Left"], [self screenWithID:20 name:@"Right"]]
                                                          learned:@{}
                                                          hotPlug:@{}];

    XCTAssertEqual(result.displayID, 20);
    XCTAssertEqual(result.reason, TUCTouchDisplayAssignmentReasonNextUnassigned);
}

- (void)testHotPlugSignalWinsAgainstLowConfidenceFallback {
    TUCTouchDeviceDescriptor *device = [self deviceWithSource:1 registryID:101 name:@"USB Touch" assignedDisplayID:10];
    device.previousAssignmentConfidence = TUCTouchDisplayAssignmentConfidenceLow;

    TUCTouchDisplayAssignmentResult *result = [self resolveDevice:device
                                                          devices:@[device]
                                                          screens:@[[self screenWithID:10 name:@"Built-in"], [self screenWithID:20 name:@"New Touch Display"]]
                                                          learned:@{}
                                                          hotPlug:@{@101: @20}];

    XCTAssertEqual(result.displayID, 20);
    XCTAssertEqual(result.reason, TUCTouchDisplayAssignmentReasonHotPlug);
}

- (void)testCalibrationLearnedSignalWinsAgainstLowConfidenceFallback {
    TUCTouchDeviceDescriptor *device = [self deviceWithSource:1 registryID:101 name:@"USB Touch" assignedDisplayID:10];
    device.previousAssignmentConfidence = TUCTouchDisplayAssignmentConfidenceLow;

    TUCTouchDisplayAssignmentResult *result = [self resolveDevice:device
                                                          devices:@[device]
                                                          screens:@[[self screenWithID:10 name:@"Built-in"], [self screenWithID:20 name:@"Calibrated Touch Display"]]
                                                          learned:@{@1: @20}
                                                          hotPlug:@{}];

    XCTAssertEqual(result.displayID, 20);
    XCTAssertEqual(result.reason, TUCTouchDisplayAssignmentReasonCalibrationLearned);
    XCTAssertEqual(result.confidence, TUCTouchDisplayAssignmentConfidenceHigh);
}

- (void)testStableCalibrationLearnedSignalSurvivesSourceIdentifierChange {
    TUCTouchDeviceDescriptor *device = [self deviceWithSource:9 registryID:101 name:@"Silicon Integrated System Co. SiS HID Touch Controller" assignedDisplayID:0];
    device.stableIdentifier = @"usb:1111:2073:silicon-integrated-system-co-sis-hid-touch-controller";

    TUCTouchDisplayAssignmentResult *result = [self resolveDevice:device
                                                          devices:@[device]
                                                          screens:@[[self screenWithID:10 name:@"Fallback Display"],
                                                                    [self screenWithID:20 name:@"Learned Touch Display"]]
                                                          learned:@{}
                                                    stableLearned:@{device.stableIdentifier: @20}
                                                          hotPlug:@{}];

    XCTAssertEqual(result.displayID, 20);
    XCTAssertEqual(result.reason, TUCTouchDisplayAssignmentReasonCalibrationLearned);
    XCTAssertEqual(result.confidence, TUCTouchDisplayAssignmentConfidenceHigh);
}

- (void)testStableCalibrationLearnedSignalOverridesExistingAssignment {
    TUCTouchDeviceDescriptor *device = [self deviceWithSource:9 registryID:101 name:@"USB Touch" assignedDisplayID:10];
    device.stableIdentifier = @"usb:1111:2073:usb-touch";
    device.previousAssignmentConfidence = TUCTouchDisplayAssignmentConfidenceHigh;

    TUCTouchDisplayAssignmentResult *result = [self resolveDevice:device
                                                          devices:@[device]
                                                          screens:@[[self screenWithID:10 name:@"Previously Assigned Display"],
                                                                    [self screenWithID:20 name:@"Manually Mapped Display"]]
                                                          learned:@{}
                                                    stableLearned:@{device.stableIdentifier: @20}
                                                          hotPlug:@{}];

    XCTAssertEqual(result.displayID, 20);
    XCTAssertEqual(result.reason, TUCTouchDisplayAssignmentReasonCalibrationLearned);
    XCTAssertEqual(result.confidence, TUCTouchDisplayAssignmentConfidenceHigh);
}

- (void)testStableCalibrationLearnedSignalIsIgnoredForDuplicateStableIdentifiers {
    TUCTouchDeviceDescriptor *deviceA = [self deviceWithSource:1 registryID:101 name:@"Duplicated Touch" assignedDisplayID:0];
    TUCTouchDeviceDescriptor *deviceB = [self deviceWithSource:2 registryID:102 name:@"Duplicated Touch" assignedDisplayID:0];
    deviceA.stableIdentifier = @"usb:1234:5678:duplicated-touch";
    deviceB.stableIdentifier = @"usb:1234:5678:duplicated-touch";

    TUCTouchDisplayAssignmentResult *result = [self resolveDevice:deviceA
                                                          devices:@[deviceA, deviceB]
                                                          screens:@[[self screenWithID:10 name:@"Fallback Display"],
                                                                    [self screenWithID:20 name:@"Learned Touch Display"]]
                                                          learned:@{}
                                                    stableLearned:@{deviceA.stableIdentifier: @20}
                                                          hotPlug:@{}];

    XCTAssertEqual(result.displayID, 10);
    XCTAssertEqual(result.reason, TUCTouchDisplayAssignmentReasonNextUnassigned);
}

- (void)testLowConfidenceExistingAssignmentIsStableWithoutBetterSignal {
    TUCTouchDeviceDescriptor *device = [self deviceWithSource:1 registryID:101 name:@"USB Touch" assignedDisplayID:20];
    device.previousAssignmentConfidence = TUCTouchDisplayAssignmentConfidenceLow;

    TUCTouchDisplayAssignmentResult *result = [self resolveDevice:device
                                                          devices:@[device]
                                                          screens:@[[self screenWithID:10 name:@"Built-in"], [self screenWithID:20 name:@"Previous Fallback"]]
                                                          learned:@{}
                                                          hotPlug:@{}];

    XCTAssertEqual(result.displayID, 20);
    XCTAssertEqual(result.reason, TUCTouchDisplayAssignmentReasonExistingAssignment);
    XCTAssertEqual(result.confidence, TUCTouchDisplayAssignmentConfidenceLow);
}

- (void)testUpdateTouchSetsProvidedScreenAndAbsoluteLocationUsesTouchScreen {
    TUCTouchInputManager *manager = [TUCTouchInputManager new];
    TUCScreen *screen = [self touchScreenWithID:20 name:@"Touch Display" frame:CGRectMake(200, 0, 100, 100) rotation:0 calibrationKey:@"touch"];

    [manager updateTouch:7
            withLocation:CGPointMake(0.5, 0.5)
               onSurface:YES
       tooLargeForFinger:YES
                  screen:screen
        sourceIdentifier:42];

    TUCTouch *touch = manager.touchSet.anyObject;
    XCTAssertEqual(touch.sourceIdentifier, 42);
    XCTAssertEqual(touch.screen.id, 20);

    CGPoint absoluteLocation = [manager absoluteLocationForTouch:touch];
    XCTAssertEqualWithAccuracy(absoluteLocation.x, 250, 0.001);
    XCTAssertEqualWithAccuracy(absoluteLocation.y, 50, 0.001);
}

- (void)testRotationIsAppliedBeforeCalibration {
    TUCTouchInputManager *manager = [TUCTouchInputManager new];
    TUCScreen *screen = [self touchScreenWithID:20 name:@"Rotated" frame:CGRectMake(0, 0, 100, 100) rotation:90 calibrationKey:@"rotated"];
    TUCTouchCalibration *calibration = [TUCTouchCalibration identityCalibration];
    calibration.enabled = YES;
    calibration.xOffset = 0.1;
    calibration.yOffset = 0.2;
    manager.calibrationsByMonitorKey = @{@"rotated": calibration};

    [manager updateTouch:7
            withLocation:CGPointMake(0.2, 0.7)
               onSurface:YES
       tooLargeForFinger:YES
                  screen:screen
        sourceIdentifier:42];

    TUCTouch *touch = manager.touchSet.anyObject;
    XCTAssertEqualWithAccuracy(touch.rawLocation.x, 0.3, 0.001);
    XCTAssertEqualWithAccuracy(touch.rawLocation.y, 0.2, 0.001);
    XCTAssertEqualWithAccuracy(touch.location.x, 0.4, 0.001);
    XCTAssertEqualWithAccuracy(touch.location.y, 0.4, 0.001);
}

- (void)testCancelTouchesOnlyCancelsMatchingSourceIdentifier {
    TUCTouchInputManager *manager = [TUCTouchInputManager new];
    TUCScreen *screen = [self touchScreenWithID:20 name:@"Touch Display" frame:CGRectMake(0, 0, 100, 100) rotation:0 calibrationKey:@"touch"];

    [manager updateTouch:1 withLocation:CGPointMake(0.2, 0.2) onSurface:YES tooLargeForFinger:YES screen:screen sourceIdentifier:11];
    [manager updateTouch:2 withLocation:CGPointMake(0.8, 0.8) onSurface:YES tooLargeForFinger:YES screen:screen sourceIdentifier:22];
    [manager cancelTouchesForSourceIdentifier:11];

    XCTAssertEqual(manager.touchSet.count, 1);
    TUCTouch *remainingTouch = manager.touchSet.anyObject;
    XCTAssertEqual(remainingTouch.sourceIdentifier, 22);
    XCTAssertTrue(remainingTouch.isActive);
}

- (void)testFakeBackendFrameCreatesTouchThroughManagerPipeline {
    TUCTestTouchInputManager *manager = [TUCTestTouchInputManager new];
    TUCFakeTouchInputBackend *backend = [TUCFakeTouchInputBackend new];
    manager.inputBackend = backend;
    manager.testScreen = [self touchScreenWithID:20 name:@"Touch Display" frame:CGRectMake(0, 0, 100, 100) rotation:0 calibrationKey:@"touch"];

    [manager start];
    TUCTouchBackendDevice *device = [backend connectDeviceWithSourceIdentifier:42];
    [backend sendContactID:7 location:CGPointMake(0.25, 0.75) onSurface:YES device:device];

    XCTAssertTrue(backend.started);
    XCTAssertEqual(manager.touchSet.count, 1);

    TUCTouch *touch = manager.touchSet.anyObject;
    XCTAssertEqual(touch.contactID, 7);
    XCTAssertEqual(touch.sourceIdentifier, 42);
    XCTAssertEqual(touch.screen.id, 20);
    XCTAssertEqualWithAccuracy(touch.rawLocation.x, 0.25, 0.001);
    XCTAssertEqualWithAccuracy(touch.rawLocation.y, 0.75, 0.001);
}

- (void)testFakeBackendDisconnectCancelsOnlyMatchingSourceIdentifier {
    TUCTestTouchInputManager *manager = [TUCTestTouchInputManager new];
    TUCFakeTouchInputBackend *backend = [TUCFakeTouchInputBackend new];
    manager.inputBackend = backend;
    manager.testScreen = [self touchScreenWithID:20 name:@"Touch Display" frame:CGRectMake(0, 0, 100, 100) rotation:0 calibrationKey:@"touch"];

    [manager start];
    TUCTouchBackendDevice *deviceA = [backend connectDeviceWithSourceIdentifier:11];
    TUCTouchBackendDevice *deviceB = [backend connectDeviceWithSourceIdentifier:22];
    [backend sendContactID:1 location:CGPointMake(0.2, 0.2) onSurface:YES device:deviceA];
    [backend sendContactID:2 location:CGPointMake(0.8, 0.8) onSurface:YES device:deviceB];

    [backend disconnectDevice:deviceA];

    XCTAssertEqual(manager.touchSet.count, 1);
    TUCTouch *remainingTouch = manager.touchSet.anyObject;
    XCTAssertEqual(remainingTouch.sourceIdentifier, 22);
    XCTAssertEqual(remainingTouch.contactID, 2);
}

- (void)testStoppingManagerStopsFakeBackendAndClearsActiveTouches {
    TUCTestTouchInputManager *manager = [TUCTestTouchInputManager new];
    TUCFakeTouchInputBackend *backend = [TUCFakeTouchInputBackend new];
    manager.inputBackend = backend;
    manager.testScreen = [self touchScreenWithID:20 name:@"Touch Display" frame:CGRectMake(0, 0, 100, 100) rotation:0 calibrationKey:@"touch"];

    [manager start];
    TUCTouchBackendDevice *device = [backend connectDeviceWithSourceIdentifier:42];
    [backend sendContactID:7 location:CGPointMake(0.25, 0.75) onSurface:YES device:device];
    [manager stop];

    XCTAssertTrue(backend.stopped);
    XCTAssertEqual(manager.touchSet.count, 0);
}

- (TUCTouchDisplayAssignmentResult *)resolveDevice:(TUCTouchDeviceDescriptor *)device
                                           devices:(NSArray<TUCTouchDeviceDescriptor *> *)devices
                                           screens:(NSArray<TUCScreenDescriptor *> *)screens
                                           learned:(NSDictionary<NSNumber *, NSNumber *> *)learned
                                           hotPlug:(NSDictionary<NSNumber *, NSNumber *> *)hotPlug {
    return [self resolveDevice:device
                       devices:devices
                       screens:screens
                       learned:learned
                 stableLearned:@{}
                       hotPlug:hotPlug];
}

- (TUCTouchDisplayAssignmentResult *)resolveDevice:(TUCTouchDeviceDescriptor *)device
                                           devices:(NSArray<TUCTouchDeviceDescriptor *> *)devices
                                           screens:(NSArray<TUCScreenDescriptor *> *)screens
                                           learned:(NSDictionary<NSNumber *, NSNumber *> *)learned
                                     stableLearned:(NSDictionary<NSString *, NSNumber *> *)stableLearned
                                           hotPlug:(NSDictionary<NSNumber *, NSNumber *> *)hotPlug {
    TUCTouchDisplayAssignmentResolver *resolver = [TUCTouchDisplayAssignmentResolver new];
    return [resolver assignmentForTouchDevice:device
                                 touchDevices:devices
                                      screens:screens
        learnedDisplayIDsBySourceIdentifier:learned
        learnedDisplayIDsByStableIdentifier:stableLearned
                hotPlugDisplayIDsByRegistryID:hotPlug];
}

- (TUCTouchDeviceDescriptor *)deviceWithSource:(NSInteger)source
                                    registryID:(uint64_t)registryID
                                          name:(NSString *)name
                             assignedDisplayID:(NSUInteger)assignedDisplayID {
    TUCTouchDeviceDescriptor *device = [TUCTouchDeviceDescriptor new];
    device.sourceIdentifier = source;
    device.registryID = registryID;
    device.name = name;
    device.assignedDisplayID = assignedDisplayID;
    return device;
}

- (TUCScreenDescriptor *)screenWithID:(NSUInteger)displayID name:(NSString *)name {
    return [self screenWithID:displayID name:name builtIn:NO];
}

- (TUCScreenDescriptor *)screenWithID:(NSUInteger)displayID name:(NSString *)name builtIn:(BOOL)builtIn {
    TUCScreenDescriptor *screen = [TUCScreenDescriptor new];
    screen.displayID = displayID;
    screen.name = name;
    screen.calibrationKey = name;
    screen.frame = CGRectMake(0, 0, 100, 100);
    screen.physicalSize = CGSizeMake(100, 100);
    screen.builtIn = builtIn;
    return screen;
}

- (TUCScreen *)touchScreenWithID:(NSUInteger)displayID
                            name:(NSString *)name
                           frame:(CGRect)frame
                        rotation:(CGFloat)rotation
                  calibrationKey:(NSString *)calibrationKey {
    TUCScreen *screen = [TUCScreen new];
    screen.id = displayID;
    screen.name = name;
    screen.frame = frame;
    screen.rotation = rotation;
    screen.calibrationKey = calibrationKey;
    screen.physicalSize = CGSizeMake(frame.size.width, frame.size.height);
    return screen;
}

@end
