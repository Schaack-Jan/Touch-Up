//
//  TUCIOHIDTouchInputBackend.h
//  TouchUpCore
//

#import <Foundation/Foundation.h>
#import "TUCTouchInputBackend.h"

NS_ASSUME_NONNULL_BEGIN

@interface TUCIOHIDTouchInputBackend : NSObject <TUCTouchInputBackend> {
    __weak id<TUCTouchInputBackendDelegate> _delegate;
}
@end

NS_ASSUME_NONNULL_END
