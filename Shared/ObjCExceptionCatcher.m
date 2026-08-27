#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)catchException:(void (NS_NOESCAPE ^)(void))block
   outExceptionReason:(NSString * _Nullable * _Nullable)outExceptionReason {
    if (outExceptionReason != NULL) {
        *outExceptionReason = nil;
    }
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (outExceptionReason != NULL) {
            *outExceptionReason = exception.reason;
        }
        return NO;
    }
}

@end
