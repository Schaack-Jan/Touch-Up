//
//  TUCTouchInputBackend.m
//  TouchUpCore
//

#import "TUCTouchInputBackend.h"

@implementation TUCTouchBackendAccessState

+ (instancetype)stateWithGranted:(BOOL)granted statusDescription:(NSString *)statusDescription {
    TUCTouchBackendAccessState *state = [TUCTouchBackendAccessState new];
    state->_granted = granted;
    state->_statusDescription = [statusDescription copy];
    return state;
}

@end

@implementation TUCTouchBackendDevice

- (instancetype)init {
    if (self = [super init]) {
        _name = @"";
        _stableDeviceKey = @"";
        _connectedDate = [NSDate date];
        _assignmentReason = TUCTouchDisplayAssignmentReasonUnknown;
        _assignmentConfidence = TUCTouchDisplayAssignmentConfidenceUnknown;
    }
    return self;
}

@end

@implementation TUCTouchBackendContact
@end

@implementation TUCTouchBackendFrame

- (instancetype)init {
    if (self = [super init]) {
        _contacts = @[];
        _timestamp = [NSDate timeIntervalSinceReferenceDate];
    }
    return self;
}

@end
