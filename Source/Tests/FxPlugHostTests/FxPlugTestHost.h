#import <FxPlug/FxPlugSDK.h>
#import "CorridorKeyShaderTypes.h"

NS_ASSUME_NONNULL_BEGIN
/// Supplies local host transactions to Apple's real FxRemoteParameterHandler.
/// No Final Cut Pro process, project or UI is opened by this harness.
@interface FxPlugTestHost : NSObject <PROAPIAccessing, FxTimingAPI_v4, FxOnScreenControlAPI_v4>
@property(nonatomic, strong, nullable) id plugin;
@property(nonatomic, copy) NSData *archive;
@property(nonatomic) BOOL useAlphaHint;
@property(nonatomic) int hintMode;
@property(nonatomic, readonly) NSUInteger writeCount;
@end
NS_ASSUME_NONNULL_END
