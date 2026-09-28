#import "ObjCSupport.h"

NSError *_Nullable DFCatchException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: exception.name;
        return [NSError errorWithDomain:@"dev.driftflow.exception"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: reason, @"ExceptionName": exception.name}];
    }
}
