#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface SGMVManager : NSObject

@property (nonatomic, strong, readonly) AVPlayer *player;
@property (nonatomic, strong, readonly) AVPlayerLayer *playerLayer;
@property (nonatomic, assign) BOOL isVideoModeEnabled;
@property (nonatomic, assign) NSTimeInterval timeOffset;

+ (instancetype)sharedManager;
- (void)fetchMVForTrack:(NSString *)trackName artist:(NSString *)artistName completion:(void (^)(BOOL hasVideo))completion;
- (void)attachToContainerView:(UIView *)containerView;
- (void)syncWithPlaybackPosition:(NSTimeInterval)seconds isPlaying:(BOOL)isPlaying;
- (void)toggleVideoMode;

@end
