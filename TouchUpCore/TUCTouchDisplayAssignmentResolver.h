//
//  TUCTouchDisplayAssignmentResolver.h
//  TouchUpCore
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TUCTouchDisplayAssignmentReason) {
    TUCTouchDisplayAssignmentReasonUnknown = 0,
    TUCTouchDisplayAssignmentReasonExistingAssignment,
    TUCTouchDisplayAssignmentReasonNameMatch,
    TUCTouchDisplayAssignmentReasonHotPlug,
    TUCTouchDisplayAssignmentReasonCalibrationLearned,
    TUCTouchDisplayAssignmentReasonSingleScreen,
    TUCTouchDisplayAssignmentReasonNextUnassigned,
    TUCTouchDisplayAssignmentReasonFallback
};

typedef NS_ENUM(NSInteger, TUCTouchDisplayAssignmentConfidence) {
    TUCTouchDisplayAssignmentConfidenceUnknown = 0,
    TUCTouchDisplayAssignmentConfidenceLow,
    TUCTouchDisplayAssignmentConfidenceMedium,
    TUCTouchDisplayAssignmentConfidenceHigh
};

@interface TUCTouchDeviceDescriptor : NSObject

@property NSInteger sourceIdentifier;
@property uint64_t registryID;
@property NSInteger vendorID;
@property NSInteger productID;
@property (copy) NSString *name;
@property (copy) NSString *stableIdentifier;
@property NSUInteger assignedDisplayID;
@property TUCTouchDisplayAssignmentReason previousAssignmentReason;
@property TUCTouchDisplayAssignmentConfidence previousAssignmentConfidence;

@end

@interface TUCScreenDescriptor : NSObject

@property NSUInteger displayID;
@property (copy) NSString *name;
@property (copy) NSString *calibrationKey;
@property CGRect frame;
@property CGSize physicalSize;
@property BOOL builtIn;

@end

@interface TUCTouchDisplayAssignmentResult : NSObject

@property NSUInteger displayID;
@property (copy) NSString *screenName;
@property TUCTouchDisplayAssignmentReason reason;
@property TUCTouchDisplayAssignmentConfidence confidence;

- (NSString *)reasonName;
- (NSString *)confidenceName;

@end

@interface TUCTouchDisplayAssignmentResolver : NSObject

- (nullable TUCTouchDisplayAssignmentResult *)assignmentForTouchDevice:(TUCTouchDeviceDescriptor *)touchDevice
                                                          touchDevices:(NSArray<TUCTouchDeviceDescriptor *> *)touchDevices
                                                               screens:(NSArray<TUCScreenDescriptor *> *)screens
                         learnedDisplayIDsBySourceIdentifier:(NSDictionary<NSNumber *, NSNumber *> *)learnedDisplayIDsBySourceIdentifier
                         learnedDisplayIDsByStableIdentifier:(NSDictionary<NSString *, NSNumber *> *)learnedDisplayIDsByStableIdentifier
                                 hotPlugDisplayIDsByRegistryID:(NSDictionary<NSNumber *, NSNumber *> *)hotPlugDisplayIDsByRegistryID;

@end

NS_ASSUME_NONNULL_END
