#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a Swift closure inside an Objective-C @try/@catch so that
/// NSExceptions raised by AVFoundation (e.g. audio node access on a
/// broken engine) cannot crash a keyboard extension process.
@interface ObjCExceptionCatcher : NSObject

/// Returns YES if `block` completed without raising; NO otherwise.
/// When NO, `outExceptionReason` (if non-nil) is set to the exception's
/// reason string.
+ (BOOL)catchException:(void (NS_NOESCAPE ^)(void))block
   outExceptionReason:(NSString * _Nullable * _Nullable)outExceptionReason;

@end

NS_ASSUME_NONNULL_END
