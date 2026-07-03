//
//  TUCTouchInputBackend.h
//  TouchUpCore
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "TUCTouchDisplayAssignmentResolver.h"

NS_ASSUME_NONNULL_BEGIN

@class TUCTouchBackendDevice;
@class TUCTouchBackendFrame;
@class TUCTouchBackendAccessState;
@protocol TUCTouchInputBackend;

@interface TUCTouchBackendAccessState : NSObject

@property (nonatomic, readonly, getter=isGranted) BOOL granted;
@property (copy, nonatomic, readonly) NSString *statusDescription;

+ (instancetype)stateWithGranted:(BOOL)granted statusDescription:(NSString *)statusDescription;

@end

@interface TUCTouchBackendDevice : NSObject

@property NSInteger sourceIdentifier;
@property uint64_t registryID;
@property NSInteger vendorID;
@property NSInteger productID;
@property (copy) NSString *name;
@property (copy) NSString *stableDeviceKey;
@property (strong) NSDate *connectedDate;
@property NSUInteger assignedDisplayID;
@property TUCTouchDisplayAssignmentReason assignmentReason;
@property TUCTouchDisplayAssignmentConfidence assignmentConfidence;

@end

@interface TUCTouchBackendContact : NSObject

@property NSInteger contactID;
@property CGPoint location;
@property BOOL onSurface;
@property BOOL valid;

@end

@interface TUCTouchBackendFrame : NSObject

@property (strong) TUCTouchBackendDevice *device;
@property (copy) NSArray<TUCTouchBackendContact *> *contacts;
@property uint64_t sequenceNumber;
@property NSTimeInterval timestamp;

@end

@protocol TUCTouchInputBackendDelegate <NSObject>

- (void)touchInputBackend:(id<TUCTouchInputBackend>)backend
         deviceDidConnect:(TUCTouchBackendDevice *)device;
- (void)touchInputBackend:(id<TUCTouchInputBackend>)backend
      deviceDidDisconnect:(TUCTouchBackendDevice *)device;
- (void)touchInputBackend:(id<TUCTouchInputBackend>)backend
     didReceiveTouchFrame:(TUCTouchBackendFrame *)frame;
- (void)touchInputBackend:(id<TUCTouchInputBackend>)backend
  accessStateDidChange:(TUCTouchBackendAccessState *)accessState;

@end

@protocol TUCTouchInputBackend <NSObject>

@property (weak, nonatomic, nullable) id<TUCTouchInputBackendDelegate> delegate;
@property (strong, nonatomic, readonly) TUCTouchBackendAccessState *accessState;

- (void)start;
- (void)stop;
- (NSArray<TUCTouchBackendDevice *> *)connectedDevices;
- (BOOL)requestAccess;

@end

NS_ASSUME_NONNULL_END
