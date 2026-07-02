//
//  TUCScreen.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 21.03.23.
//

#import "TUCScreen.h"

@implementation TUCScreen

+ (NSString *)normalizedCalibrationKeyComponent:(NSString *)string {
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

    return normalized.length > 0 ? normalized : @"display";
}

+ (NSString *)calibrationKeyForDisplayID:(CGDirectDisplayID)displayID name:(NSString *)name physicalSize:(CGSize)physicalSize {
    uint32_t vendorID = CGDisplayVendorNumber(displayID);
    uint32_t productID = CGDisplayModelNumber(displayID);
    uint32_t serialNumber = CGDisplaySerialNumber(displayID);

    if (vendorID != 0 && productID != 0) {
        return [NSString stringWithFormat:@"edid:%u-%u-%u", vendorID, productID, serialNumber];
    }

    if (name.length > 0 && physicalSize.width > 0 && physicalSize.height > 0) {
        NSString *normalizedName = [self normalizedCalibrationKeyComponent:name];
        return [NSString stringWithFormat:@"screen:%@-%.0f-%.0f", normalizedName, physicalSize.width, physicalSize.height];
    }

    return [NSString stringWithFormat:@"display-id:%u", displayID];
}

- (instancetype)initWithScreen:(NSScreen *)screen frameOfFirstScreen:(CGRect)firstFrame {
    if (self = [super init]) {
        NSNumber *number = [[screen deviceDescription] valueForKey:@"NSScreenNumber"];
        CGDirectDisplayID displayID = [number unsignedIntValue];
        
        self.id = displayID;
        
        self.rotation = CGDisplayRotation(displayID);
        
        
        self.physicalSize = CGDisplayScreenSize(displayID);
        
        
        CGRect thisFrame = screen.frame;
        // need to flip coordinate system
        self.frame = CGRectMake(thisFrame.origin.x,
                                thisFrame.origin.y + thisFrame.size.height - firstFrame.size.height,
                                thisFrame.size.width,
                                thisFrame.size.height);
        
        
        if (@available(macOS 10.15, *)) {
            self.name = [screen localizedName];
        } else {
            // Fallback on earlier versions
            self.name =  [NSString stringWithFormat: @"Display %u", displayID];
        }

        self.calibrationKey = [TUCScreen calibrationKeyForDisplayID:displayID
                                                               name:self.name
                                                       physicalSize:self.physicalSize];
        
    }
    
    return self;
}

- (nullable NSScreen *)systemScreen {
    NSArray *screens = [NSScreen screens];
    
    for (NSScreen *screen in screens) {
        NSNumber *number = [[screen deviceDescription] valueForKey:@"NSScreenNumber"];
        CGDirectDisplayID displayID = [number unsignedIntValue];
        if (displayID == self.id) {
            return screen;
        }
    }
    return nil;
}


- (CGFloat)pixelsPerMM {
    return self.frame.size.width / self.physicalSize.width;
}

- (CGPoint)convertPointRelativeToAbsolute:(CGPoint)relativePoint {
    CGPoint screenOrigin = self.frame.origin;
    CGSize screenSize = self.frame.size;
    
    
    CGPoint absLoc = CGPointMake(relativePoint.x * screenSize.width + screenOrigin.x,
                                 relativePoint.y * screenSize.height - screenOrigin.y);
    
    return absLoc;
}



- (NSString *)debugDescription {
    return [NSString stringWithFormat:@"<[TUFScreen ID %ld] Frame: %@, Name: %@, CalibrationKey: %@>", self.id, NSStringFromRect(self.frame), self.name, self.calibrationKey];
}

+ (NSArray *)allScreens {
    NSMutableArray<TUCScreen *> *myScreens = [NSMutableArray array];
    
    NSArray *nsScreens = [NSScreen screens];
    
    CGRect firstFrame = CGRectZero;
    if ([nsScreens count] > 0) {
        NSScreen  *firstScreen = [nsScreens objectAtIndex:0];
        firstFrame = firstScreen.frame;
    }
    
    for (NSScreen *screen in nsScreens) {
        TUCScreen *e = [[TUCScreen alloc] initWithScreen:screen
                                      frameOfFirstScreen:firstFrame];
        [myScreens addObject:e];
        NSLog(@"[TouchUp] allScreens: id=%u name='%@' NSframe={{%.0f,%.0f},{%.0f,%.0f}} CG_frame={{%.0f,%.0f},{%.0f,%.0f}}",
              e.id, e.name,
              screen.frame.origin.x, screen.frame.origin.y,
              screen.frame.size.width, screen.frame.size.height,
              e.frame.origin.x, e.frame.origin.y,
              e.frame.size.width, e.frame.size.height);
    }

    return myScreens;
}

@end
