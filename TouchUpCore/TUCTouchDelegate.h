//
//  TUCTouchDelegate.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import "TUCTouch.h"
#import "TUCScreen.h"

NS_ASSUME_NONNULL_BEGIN

@protocol TUCTouchDelegate <NSObject>

#pragma mark - Touch Data
/**
 
 This method is called every time after the `touchSet` was updated
 */
- (void)touchesDidChange;



#pragma mark - Lifecycle

- (void)touchscreenDidConnect;
- (void)touchscreenDidDisconnect;



#pragma mark - Mouse Control

/**
 Specifies which screen corresponds to the touch screen.
 */
- (nullable TUCScreen *)touchscreen;

@optional

/**
 Legacy hook used by the previous gesture pipeline to customize mouse events.
 The Windows gesture profile is handled internally by TUCTouchInputManager.
 */
- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture;

@end

NS_ASSUME_NONNULL_END
