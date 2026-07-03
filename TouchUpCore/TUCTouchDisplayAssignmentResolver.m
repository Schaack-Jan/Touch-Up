//
//  TUCTouchDisplayAssignmentResolver.m
//  TouchUpCore
//

#import "TUCTouchDisplayAssignmentResolver.h"

@implementation TUCTouchDeviceDescriptor

- (instancetype)init {
    if (self = [super init]) {
        _name = @"";
        _stableIdentifier = @"";
        _previousAssignmentReason = TUCTouchDisplayAssignmentReasonUnknown;
        _previousAssignmentConfidence = TUCTouchDisplayAssignmentConfidenceUnknown;
    }
    return self;
}

@end

@implementation TUCScreenDescriptor

- (instancetype)init {
    if (self = [super init]) {
        _name = @"";
        _calibrationKey = @"";
    }
    return self;
}

@end

@implementation TUCTouchDisplayAssignmentResult

- (NSString *)reasonName {
    switch (self.reason) {
        case TUCTouchDisplayAssignmentReasonExistingAssignment: return @"existingAssignment";
        case TUCTouchDisplayAssignmentReasonNameMatch: return @"nameMatch";
        case TUCTouchDisplayAssignmentReasonHotPlug: return @"hotPlug";
        case TUCTouchDisplayAssignmentReasonCalibrationLearned: return @"calibrationLearned";
        case TUCTouchDisplayAssignmentReasonSingleScreen: return @"singleScreen";
        case TUCTouchDisplayAssignmentReasonNextUnassigned: return @"nextUnassigned";
        case TUCTouchDisplayAssignmentReasonFallback: return @"fallback";
        case TUCTouchDisplayAssignmentReasonUnknown: return @"unknown";
    }
}

- (NSString *)confidenceName {
    switch (self.confidence) {
        case TUCTouchDisplayAssignmentConfidenceLow: return @"low";
        case TUCTouchDisplayAssignmentConfidenceMedium: return @"medium";
        case TUCTouchDisplayAssignmentConfidenceHigh: return @"high";
        case TUCTouchDisplayAssignmentConfidenceUnknown: return @"unknown";
    }
}

@end

@interface TUCNameMatch : NSObject

@property (strong) TUCScreenDescriptor *screen;
@property TUCTouchDisplayAssignmentConfidence confidence;

@end

@implementation TUCNameMatch
@end

@implementation TUCTouchDisplayAssignmentResolver

static NSSet<NSString *> *TUCGenericNameTokens(void) {
    static NSSet<NSString *> *tokens = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tokens = [NSSet setWithArray:@[
            @"touch", @"touchscreen", @"screen", @"display", @"monitor", @"usb",
            @"hid", @"digitizer", @"generic", @"device", @"inc", @"ltd", @"llc"
        ]];
    });
    return tokens;
}

static NSString *TUCNormalizedDisplayAssignmentString(NSString *string) {
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

static NSArray<NSString *> *TUCMeaningfulDisplayAssignmentTokens(NSString *string) {
    NSArray<NSString *> *rawTokens = [[string lowercaseString] componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    NSSet<NSString *> *genericTokens = TUCGenericNameTokens();

    for (NSString *token in rawTokens) {
        NSString *normalized = TUCNormalizedDisplayAssignmentString(token);
        if (normalized.length < 3 || [genericTokens containsObject:normalized]) {
            continue;
        }
        [tokens addObject:normalized];
    }

    return tokens;
}

- (nullable TUCTouchDisplayAssignmentResult *)assignmentForTouchDevice:(TUCTouchDeviceDescriptor *)touchDevice
                                                          touchDevices:(NSArray<TUCTouchDeviceDescriptor *> *)touchDevices
                                                               screens:(NSArray<TUCScreenDescriptor *> *)screens
                         learnedDisplayIDsBySourceIdentifier:(NSDictionary<NSNumber *, NSNumber *> *)learnedDisplayIDsBySourceIdentifier
                         learnedDisplayIDsByStableIdentifier:(NSDictionary<NSString *, NSNumber *> *)learnedDisplayIDsByStableIdentifier
                                 hotPlugDisplayIDsByRegistryID:(NSDictionary<NSNumber *, NSNumber *> *)hotPlugDisplayIDsByRegistryID {
    if (screens.count == 0) {
        return nil;
    }

    NSSet<NSNumber *> *assignedDisplayIDs = [self assignedDisplayIDsForOtherDevices:touchDevices
                                                                        touchDevice:touchDevice
                                                                            screens:screens];

    if ([self stableIdentifierIsUniqueForTouchDevice:touchDevice touchDevices:touchDevices]) {
        NSNumber *stableLearnedDisplayID = learnedDisplayIDsByStableIdentifier[touchDevice.stableIdentifier];
        TUCScreenDescriptor *stableLearnedScreen = [self screenWithDisplayID:stableLearnedDisplayID.unsignedIntegerValue screens:screens];
        if (stableLearnedScreen) {
            return [self resultWithScreen:stableLearnedScreen
                                   reason:TUCTouchDisplayAssignmentReasonCalibrationLearned
                               confidence:TUCTouchDisplayAssignmentConfidenceHigh];
        }
    }

    NSNumber *learnedDisplayID = learnedDisplayIDsBySourceIdentifier[@(touchDevice.sourceIdentifier)];
    TUCScreenDescriptor *learnedScreen = [self screenWithDisplayID:learnedDisplayID.unsignedIntegerValue screens:screens];
    if (learnedScreen) {
        return [self resultWithScreen:learnedScreen
                               reason:TUCTouchDisplayAssignmentReasonCalibrationLearned
                           confidence:TUCTouchDisplayAssignmentConfidenceHigh];
    }

    TUCScreenDescriptor *existingScreen = [self screenWithDisplayID:touchDevice.assignedDisplayID screens:screens];
    if (existingScreen &&
        touchDevice.previousAssignmentConfidence != TUCTouchDisplayAssignmentConfidenceLow) {
        return [self resultWithScreen:existingScreen
                               reason:TUCTouchDisplayAssignmentReasonExistingAssignment
                           confidence:TUCTouchDisplayAssignmentConfidenceHigh];
    }

    TUCNameMatch *nameMatch = [self screenMatchingTouchDeviceName:touchDevice.name
                                                          screens:screens
                                              excludingDisplayIDs:assignedDisplayIDs];
    if (nameMatch) {
        return [self resultWithScreen:nameMatch.screen
                               reason:TUCTouchDisplayAssignmentReasonNameMatch
                           confidence:nameMatch.confidence];
    }

    NSNumber *hotPlugDisplayID = hotPlugDisplayIDsByRegistryID[@(touchDevice.registryID)];
    TUCScreenDescriptor *hotPlugScreen = [self screenWithDisplayID:hotPlugDisplayID.unsignedIntegerValue screens:screens];
    if (hotPlugScreen) {
        return [self resultWithScreen:hotPlugScreen
                               reason:TUCTouchDisplayAssignmentReasonHotPlug
                           confidence:TUCTouchDisplayAssignmentConfidenceMedium];
    }

    if (existingScreen) {
        return [self resultWithScreen:existingScreen
                               reason:TUCTouchDisplayAssignmentReasonExistingAssignment
                           confidence:touchDevice.previousAssignmentConfidence];
    }

    if (touchDevices.count <= 1 && screens.count == 1) {
        return [self resultWithScreen:screens.firstObject
                               reason:TUCTouchDisplayAssignmentReasonSingleScreen
                           confidence:TUCTouchDisplayAssignmentConfidenceHigh];
    }

    for (TUCScreenDescriptor *screen in [self fallbackOrderedScreens:screens]) {
        if (![assignedDisplayIDs containsObject:@(screen.displayID)]) {
            return [self resultWithScreen:screen
                                   reason:TUCTouchDisplayAssignmentReasonNextUnassigned
                               confidence:TUCTouchDisplayAssignmentConfidenceLow];
        }
    }

    return [self resultWithScreen:[self fallbackOrderedScreens:screens].firstObject ?: screens.firstObject
                           reason:TUCTouchDisplayAssignmentReasonFallback
                       confidence:TUCTouchDisplayAssignmentConfidenceLow];
}

- (NSSet<NSNumber *> *)assignedDisplayIDsForOtherDevices:(NSArray<TUCTouchDeviceDescriptor *> *)touchDevices
                                             touchDevice:(TUCTouchDeviceDescriptor *)touchDevice
                                                 screens:(NSArray<TUCScreenDescriptor *> *)screens {
    NSMutableSet<NSNumber *> *assignedDisplayIDs = [NSMutableSet set];

    for (TUCTouchDeviceDescriptor *otherDevice in touchDevices) {
        if (otherDevice == touchDevice ||
            otherDevice.sourceIdentifier == touchDevice.sourceIdentifier ||
            otherDevice.assignedDisplayID == 0) {
            continue;
        }

        if ([self screenWithDisplayID:otherDevice.assignedDisplayID screens:screens]) {
            [assignedDisplayIDs addObject:@(otherDevice.assignedDisplayID)];
        }
    }

    return assignedDisplayIDs;
}

- (BOOL)stableIdentifierIsUniqueForTouchDevice:(TUCTouchDeviceDescriptor *)touchDevice
                                  touchDevices:(NSArray<TUCTouchDeviceDescriptor *> *)touchDevices {
    if (touchDevice.stableIdentifier.length == 0) {
        return NO;
    }

    NSInteger matchCount = 0;
    for (TUCTouchDeviceDescriptor *otherDevice in touchDevices) {
        if ([otherDevice.stableIdentifier isEqualToString:touchDevice.stableIdentifier]) {
            matchCount++;
        }
    }

    return matchCount == 1;
}

- (nullable TUCNameMatch *)screenMatchingTouchDeviceName:(NSString *)deviceName
                                                 screens:(NSArray<TUCScreenDescriptor *> *)screens
                                     excludingDisplayIDs:(NSSet<NSNumber *> *)excludedDisplayIDs {
    NSString *normalizedDeviceName = TUCNormalizedDisplayAssignmentString(deviceName);
    if (normalizedDeviceName.length < 4) {
        return nil;
    }

    TUCNameMatch *exactMatch = [self uniqueNameMatchForDeviceName:normalizedDeviceName
                                                          screens:screens
                                              excludingDisplayIDs:excludedDisplayIDs
                                                        evaluator:^BOOL(NSString *screenName) {
        return [screenName isEqualToString:normalizedDeviceName];
    }];
    if (exactMatch) {
        exactMatch.confidence = TUCTouchDisplayAssignmentConfidenceHigh;
        return exactMatch;
    }

    TUCNameMatch *substringMatch = [self uniqueNameMatchForDeviceName:normalizedDeviceName
                                                              screens:screens
                                                  excludingDisplayIDs:excludedDisplayIDs
                                                            evaluator:^BOOL(NSString *screenName) {
        return [screenName containsString:normalizedDeviceName] ||
               [normalizedDeviceName containsString:screenName];
    }];
    if (substringMatch) {
        substringMatch.confidence = TUCTouchDisplayAssignmentConfidenceMedium;
        return substringMatch;
    }

    return [self tokenMatchForDeviceName:deviceName
                                 screens:screens
                     excludingDisplayIDs:excludedDisplayIDs];
}

- (nullable TUCNameMatch *)uniqueNameMatchForDeviceName:(NSString *)normalizedDeviceName
                                                screens:(NSArray<TUCScreenDescriptor *> *)screens
                                    excludingDisplayIDs:(NSSet<NSNumber *> *)excludedDisplayIDs
                                              evaluator:(BOOL (^)(NSString *normalizedScreenName))evaluator {
    TUCNameMatch *match = nil;

    for (TUCScreenDescriptor *screen in screens) {
        if ([excludedDisplayIDs containsObject:@(screen.displayID)]) {
            continue;
        }

        NSString *normalizedScreenName = TUCNormalizedDisplayAssignmentString(screen.name);
        if (normalizedScreenName.length < 4 || !evaluator(normalizedScreenName)) {
            continue;
        }

        if (match) {
            return nil;
        }

        match = [TUCNameMatch new];
        match.screen = screen;
    }

    return match;
}

- (nullable TUCNameMatch *)tokenMatchForDeviceName:(NSString *)deviceName
                                          screens:(NSArray<TUCScreenDescriptor *> *)screens
                              excludingDisplayIDs:(NSSet<NSNumber *> *)excludedDisplayIDs {
    NSArray<NSString *> *deviceTokens = TUCMeaningfulDisplayAssignmentTokens(deviceName);
    if (deviceTokens.count == 0) {
        return nil;
    }

    TUCScreenDescriptor *bestScreen = nil;
    NSInteger bestScore = 0;
    BOOL ambiguous = NO;

    for (TUCScreenDescriptor *screen in screens) {
        if ([excludedDisplayIDs containsObject:@(screen.displayID)]) {
            continue;
        }

        NSSet<NSString *> *screenTokens = [NSSet setWithArray:TUCMeaningfulDisplayAssignmentTokens(screen.name)];
        NSInteger score = 0;
        for (NSString *token in deviceTokens) {
            if ([screenTokens containsObject:token] ||
                [TUCNormalizedDisplayAssignmentString(screen.name) containsString:token]) {
                score++;
            }
        }

        if (score == 0) {
            continue;
        }

        if (score > bestScore) {
            bestScore = score;
            bestScreen = screen;
            ambiguous = NO;
        } else if (score == bestScore) {
            ambiguous = YES;
        }
    }

    if (!bestScreen || ambiguous) {
        return nil;
    }

    TUCNameMatch *match = [TUCNameMatch new];
    match.screen = bestScreen;
    match.confidence = TUCTouchDisplayAssignmentConfidenceMedium;
    return match;
}

- (nullable TUCScreenDescriptor *)screenWithDisplayID:(NSUInteger)displayID
                                             screens:(NSArray<TUCScreenDescriptor *> *)screens {
    if (displayID == 0) {
        return nil;
    }

    for (TUCScreenDescriptor *screen in screens) {
        if (screen.displayID == displayID) {
            return screen;
        }
    }

    return nil;
}

- (NSArray<TUCScreenDescriptor *> *)fallbackOrderedScreens:(NSArray<TUCScreenDescriptor *> *)screens {
    return [screens sortedArrayUsingComparator:^NSComparisonResult(TUCScreenDescriptor *a, TUCScreenDescriptor *b) {
        if (a.builtIn != b.builtIn) {
            return a.builtIn ? NSOrderedDescending : NSOrderedAscending;
        }
        return [@(a.displayID) compare:@(b.displayID)];
    }];
}

- (TUCTouchDisplayAssignmentResult *)resultWithScreen:(TUCScreenDescriptor *)screen
                                               reason:(TUCTouchDisplayAssignmentReason)reason
                                           confidence:(TUCTouchDisplayAssignmentConfidence)confidence {
    TUCTouchDisplayAssignmentResult *result = [TUCTouchDisplayAssignmentResult new];
    result.displayID = screen.displayID;
    result.screenName = screen.name ?: @"";
    result.reason = reason;
    result.confidence = confidence;
    return result;
}

@end
