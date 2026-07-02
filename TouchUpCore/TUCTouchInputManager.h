//
//  TUCTouchInputManager.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import <AppKit/AppKit.h>
#import "TUCTouchInputManager-C.h"
#import "TUCTouchDelegate.h"
#import "TUCTouch.h"

NS_ASSUME_NONNULL_BEGIN


@interface TUCTouchCalibration : NSObject

@property BOOL enabled;
@property CGFloat xOffset;
@property CGFloat yOffset;
@property CGFloat xScale;
@property CGFloat yScale;
@property CGFloat xSkew;
@property CGFloat ySkew;

- (CGPoint)applyToPoint:(CGPoint)point;
+ (instancetype)identityCalibration;

@end


@interface TUCTouchInputManager : NSObject

@property (weak, nonatomic) id<TUCTouchDelegate> delegate;

@property (strong, atomic) NSMutableSet<TUCTouch *> *touchSet;

@property (copy, nonatomic) NSDictionary<NSString *, TUCTouchCalibration *> *calibrationsByMonitorKey;

/**
 Allows to deactiate that the framework processes touches to post them as mouse events.
 The default value is YES.
 */
@property (nonatomic) BOOL postMouseEvents;


/**
 The maximal distance in mm that two taps may be apart from each other to count as double click
 */
@property CGFloat doubleClickTolerance;

/**
 How long the user has to press and hold before a right mouse button gesture starts.
 */
@property NSTimeInterval holdDuration;

/**
 Enables moving windows by dragging from a recognized title bar or window chrome area.
 */
@property BOOL windowTitleBarDragEnabled;

/**
 Enables optional two-finger tap secondary clicks.
 */
@property BOOL twoFingerTapSecondaryClickEnabled;

/**
 Enables two-finger scroll events.
 */
@property BOOL twoFingerScrollEnabled;

/**
 If a touch is no longer reported by the screen, wait for this number of incoming reports bevore deleting it from the touch set.
 */
@property NSInteger errorResistance;


/**
 If a touchscreen sometimes sends invalid touch data at location (0,0), activate this option to ignore them
 */
@property BOOL ignoreOriginTouches;


@property (nonatomic, readonly) BOOL isHIDListenEventAccessGranted;


- (BOOL)checkHIDListenEventAccessGranted;

- (BOOL)requestHIDListenEventAccess;


- (void)start;

- (void)stop;


- (void)assignAllTouchDevicesToDisplayID:(NSUInteger)displayID;


- (CGPoint)convertScreenPointRelativeToAbsolute:(CGPoint)relativePoint;


- (void)triggerSystemAccessibilityAccessAlert;

@end

NS_ASSUME_NONNULL_END
