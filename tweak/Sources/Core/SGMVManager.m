#import "SGMVManager.h"

@interface SGMVManager ()
@property (nonatomic, strong) NSCache<NSString *, NSURL *> *urlCache;
@property (nonatomic, copy) NSString *currentTrackKey;
@end

@implementation SGMVManager

+ (instancetype)sharedManager {
    static SGMVManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _urlCache = [[NSCache alloc] init];
        _player = [[AVPlayer alloc] init];
        _player.muted = YES; // Keep muted so audio comes from Spotify
        _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
        _playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        _playerLayer.hidden = YES;
    }
    return self;
}

- (void)fetchMVForTrack:(NSString *)trackName artist:(NSString *)artistName completion:(void (^)(BOOL hasVideo))completion {
    if (!trackName || trackName.length == 0) return;
    NSString *key = [NSString stringWithFormat:@"%@-%@", trackName, artistName ?: @""];
    if ([self.currentTrackKey isEqualToString:key]) return;
    self.currentTrackKey = key;

    // Release previous video item from memory
    [self.player pause];
    [self.player replaceCurrentItemWithPlayerItem:nil];

    NSURL *cachedURL = [self.urlCache objectForKey:key];
    if (cachedURL) {
        [self loadStreamURL:cachedURL];
        if (completion) completion(YES);
        return;
    }

    // Build search query and call Piped API (YouTube third-party parser)
    NSString *rawQuery = [NSString stringWithFormat:@"%@ %@ Official MV", trackName, artistName ?: @""];
    NSString *query = [rawQuery stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *searchURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@pipedapi.kavin.rocks/search?q=%@&filter=music_videos", @"https://", query]];

    [[[NSURLSession sharedSession] dataTaskWithURL:searchURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(NO); });
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *items = json[@"items"];
        if ([items isKindOfClass:[NSArray class]] && items.count > 0) {
            NSString *videoPath = items.firstObject[@"url"];
            NSString *videoId = [videoPath stringByReplacingOccurrencesOfString:@"/watch?v=" withString:@""];
            [self resolveStreamWithVideoId:videoId cacheKey:key completion:completion];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(NO); });
        }
    }] resume];
}

- (void)resolveStreamWithVideoId:(NSString *)videoId cacheKey:(NSString *)key completion:(void (^)(BOOL hasVideo))completion {
            NSURL *streamInfoURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@pipedapi.kavin.rocks/streams/%@", @"https://", videoId]];
    [[[NSURLSession sharedSession] dataTaskWithURL:streamInfoURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(NO); });
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *videoStreams = json[@"videoStreams"];
        NSURL *bestStreamURL = nil;

        if ([videoStreams isKindOfClass:[NSArray class]]) {
            // Pick H.264 (MPEG_4) 720p video-only stream for fast loading
            for (NSDictionary *stream in videoStreams) {
                if ([stream[@"format"] isEqualToString:@"MPEG_4"] && [stream[@"quality"] isEqualToString:@"720p"]) {
                    bestStreamURL = [NSURL URLWithString:stream[@"url"]];
                    break;
                }
            }
            if (!bestStreamURL && videoStreams.count > 0) {
                bestStreamURL = [NSURL URLWithString:videoStreams.firstObject[@"url"]];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (bestStreamURL) {
                [self.urlCache setObject:bestStreamURL forKey:key];
                [self loadStreamURL:bestStreamURL];
                if (completion) completion(YES);
            } else {
                if (completion) completion(NO);
            }
        });
    }] resume];
}

- (void)loadStreamURL:(NSURL *)url {
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    [self.player replaceCurrentItemWithPlayerItem:item];
    if (self.isVideoModeEnabled) {
        self.playerLayer.hidden = NO;
        [self.player play];
    }
}

- (void)attachToContainerView:(UIView *)containerView {
    if (!containerView) return;
    if (self.playerLayer.superlayer != containerView.layer) {
        [self.playerLayer removeFromSuperlayer];
        self.playerLayer.frame = containerView.bounds;
        self.playerLayer.cornerRadius = containerView.layer.cornerRadius;
        self.playerLayer.masksToBounds = YES;
        [containerView.layer addSublayer:self.playerLayer];
    }
}

- (void)toggleVideoMode {
    self.isVideoModeEnabled = !self.isVideoModeEnabled;
    self.playerLayer.hidden = !self.isVideoModeEnabled;
    if (self.isVideoModeEnabled) {
        [self.player play];
    } else {
        [self.player pause];
    }
}

- (void)syncWithPlaybackPosition:(NSTimeInterval)seconds isPlaying:(BOOL)isPlaying {
    if (!self.isVideoModeEnabled || !self.player.currentItem) return;
    
    NSTimeInterval targetTime = MAX(0, seconds + self.timeOffset);
    NSTimeInterval currentMVTime = CMTimeGetSeconds(self.player.currentTime);
    
    // Force sync if audio-video drift exceeds 0.6 seconds
    if (fabs(targetTime - currentMVTime) > 0.6) {
        [self.player seekToTime:CMTimeMakeWithSeconds(targetTime, NSEC_PER_SEC) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }
    
    if (isPlaying && self.player.rate == 0) {
        [self.player play];
    } else if (!isPlaying && self.player.rate != 0) {
        [self.player pause];
    }
}

@end
