#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised as an NSError, or nil. Some Apple
/// APIs (AVAudioEngine's installTap, for one) report bad input by raising an exception, which Swift
/// can't catch and which would otherwise end the app.
NSError *_Nullable DFCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
