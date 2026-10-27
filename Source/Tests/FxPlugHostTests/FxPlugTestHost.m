#import "FxPlugTestHost.h"

// Private SDK entry points are confined to this regression harness. Production
// code uses public FxPlug protocols. The inherited getter/setter execute Apple's
// actual keyed coding and class lookup, which a dictionary-only mock cannot test.
extern NSString *kKey_CustomData;
@interface FxRemoteParameterHandler : NSObject
- (instancetype)initWithAPIManager:(id)manager pluginUUID:(NSString *)uuid;
@end

@interface FxPlugTestParameterHandler : FxRemoteParameterHandler
@property(nonatomic, weak) FxPlugTestHost *host;
@end
@interface FxPlugTestHost ()
@property(nonatomic, strong) FxPlugTestParameterHandler *handler;
@property(nonatomic, readwrite) NSUInteger writeCount;
@end

@implementation FxPlugTestHost
- (instancetype)init {
    if ((self = [super init])) {
        NSKeyedArchiver *encoder = [[NSKeyedArchiver alloc] initRequiringSecureCoding:YES];
        [encoder encodeObject:@{} forKey:kKey_CustomData];
        [encoder finishEncoding];
        _archive = encoder.encodedData;
        _hintMode = 3;
        _handler = [[FxPlugTestParameterHandler alloc] initWithAPIManager:self pluginUUID:@"CorridorKeyTests"];
        _handler.host = self;
    }
    return self;
}
- (id)apiForProtocol:(Protocol *)protocol {
    NSString *name = NSStringFromProtocol(protocol);
    if ([name hasPrefix:@"FxParameter"]) { return self.handler; }
    if ([name isEqualToString:@"FxTimingAPI_v4"] || [name isEqualToString:@"FxOnScreenControlAPI_v4"]) { return self; }
    return nil;
}
- (BOOL)wasPluginRemoved { return NO; }
- (BOOL)isThreadLive { return NO; }
- (id)sessionID { return @"test-session"; }
- (id)threadTransactionID { return @"test-transaction"; }
- (id)getPluginCoordinator { return self; }
- (id)pluginForSession:(id)session withError:(NSError **)error { return self; }
- (id)pluginInstance { return self.plugin; }
- (void)frameDuration:(CMTime *)duration { *duration = CMTimeMake(1, 25); }
- (void)convertPointFromSpace:(FxDrawingCoordinates)fromSpace fromX:(double)x fromY:(double)y
                      toSpace:(FxDrawingCoordinates)toSpace toX:(double *)resultX toY:(double *)resultY {
    double scale = toSpace == kFxDrawingCoordinates_OBJECT ? 0.001 : 1000;
    *resultX = x * scale;
    *resultY = y * scale;
}
@end

@implementation FxPlugTestParameterHandler
- (BOOL)getValue:(void *)value forParam:(UInt32)parameter atTime:(CMTime)time {
    NSCAssert(parameter == 50, @"Unexpected custom parameter");
    *(void **)value = (__bridge void *)self.host.archive;
    return YES;
}
- (BOOL)setValue:(void *)value toParameterTransaction:(id)transaction atTime:(CMTime)time {
    self.host.archive = (__bridge NSData *)(*(void **)value);
    self.host.writeCount += 1;
    return YES;
}
- (BOOL)getBoolValue:(BOOL *)value fromParameter:(UInt32)parameter atTime:(CMTime)time {
    NSCAssert(parameter == 9006, @"Unexpected toggle");
    *value = self.host.useAlphaHint;
    return YES;
}
- (BOOL)getIntValue:(int *)value fromParameter:(UInt32)parameter atTime:(CMTime)time {
    *value = parameter == 1007 ? self.host.hintMode : 0;
    return YES;
}
- (BOOL)setIntValue:(int)value toParameter:(UInt32)parameter atTime:(CMTime)time {
    NSCAssert(parameter == 1007, @"Unexpected popup");
    self.host.hintMode = value;
    return YES;
}
@end
