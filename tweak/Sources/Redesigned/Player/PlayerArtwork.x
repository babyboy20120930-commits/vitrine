#import "Core/SGCore.h"
#import "Core/SGMVManager.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Haptics/Haptics.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/Player/PlayerState.h"
#import "Player.h"

static const CGFloat kPausedScale = 0.84;
static const CGFloat kCoverMinWidth = 200;

static char kPlateKey;
static char kMVButtonKey;
static NSHashTable<UIView *> *sg_tilts;
static NSMapTable<UIView *, UIView *> *sg_covers;
static NSTimer *sg_mvSyncTimer;

static CGFloat currentScale(void) {
    SPTPlayerState *state = SGPlayerState();
    if (!state.isPaused) return 1;
    return SGRReduceMotion() ? 1 : kPausedScale;
}

static UIView *coverIn(UIView *tilt) {
    UIView *cover = [sg_covers objectForKey:tilt];
    if (cover.superview == tilt) return cover;
    for (UIView *sub in tilt.subviews) {
        if (![sub isKindOfClass:SGRShadowPlate.class] && CGSizeEqualToSize(sub.bounds.size, tilt.bounds.size)) {
            [sg_covers setObject:sub forKey:tilt];
            return sub;
        }
    }
    return nil;
}

static BOOL inCoverCell(UIView *tilt) {
    static Class cell;
    if (!cell) cell = NSClassFromString(@"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl");
    for (UIView *v = tilt.superview; v; v = v.superview) {
        if ([v isKindOfClass:cell]) return YES;
    }
    return NO;
}

static void scaleCover(UIView *tilt, CGFloat scale) {
    UIView *cover = coverIn(tilt);
    if (!cover) return;
    SGRShadowPlate *plate = SGRShadowPlateIn(tilt, &kPlateKey);
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    cover.transform = transform;
    plate.transform = transform;
}

#pragma mark - where the cover is

static UIView *showingTilt(void) {
    for (UIView *tilt in sg_tilts) {
        if (!tilt.window) continue;
        BOOL hidden = NO;
        for (UIView *v = tilt; v && !hidden; v = v.superview) hidden = v.hidden;
        if (!hidden) return tilt;
    }
    return nil;
}

UIView *SGRPlayerCoverList(void) {
    for (UIView *v = showingTilt(); v; v = v.superview) {
        if ([v isKindOfClass:UICollectionView.class]) return v;
    }
    return nil;
}

CGRect SGRPlayerCoverFrameIn(UIView *host) {
    UIView *tilt = showingTilt();
    UIView *cover = coverIn(tilt);
    return cover && host ? [host convertRect:cover.bounds fromView:cover] : CGRectNull;
}

CGFloat SGRPlayerCoverScale(void) {
    return currentScale();
}

CGRect SGRPlayerArtworkAreaIn(UIView *host) {
    UIView *tilt = showingTilt();
    if (!tilt || !host) return CGRectNull;
    for (UIView *v = tilt.superview; v; v = v.superview) {
        if (v == host) break;
        if (v.bounds.size.width >= host.bounds.size.width - 1) return [host convertRect:v.bounds fromView:v];
    }
    return CGRectNull;
}

static __weak UIView *sg_hiddenCover, *sg_hiddenPlate;

void SGRPlayerSetCoverHidden(BOOL hidden) {
    sg_hiddenCover.alpha = SGRReduceMotion() && SGPlayerState().isPaused ? 0.75 : 1;
    sg_hiddenPlate.alpha = 1;
    sg_hiddenCover = sg_hiddenPlate = nil;
    if (!hidden) return;
    UIView *tilt = showingTilt();
    UIView *cover = coverIn(tilt);
    if (!cover) return;
    UIView *plate = SGRShadowPlateIn(tilt, &kPlateKey);
    cover.alpha = 0;
    plate.alpha = 0;
    sg_hiddenCover = cover;
    sg_hiddenPlate = plate;
}

#pragma mark - the paused shrink

static void scaleEveryCover(BOOL animated) {
    CGFloat scale = currentScale();
    NSArray<UIView *> *tilts = sg_tilts.allObjects;
    void (^apply)(void) = ^{
        for (UIView *tilt in tilts) {
            scaleCover(tilt, scale);
            UIView *cover = coverIn(tilt);
            if (cover != sg_hiddenCover) cover.alpha = SGRReduceMotion() && SGPlayerState().isPaused ? 0.75 : 1;
        }
    };
    if (animated) SGRAnimate(SGRReduceMotion() ? SGRMotionRespond : SGRMotionLayout, apply, nil);
    else apply();
}

#pragma mark - External MV Toggle & Overlay

static void updateMVButtonAppearance(UIButton *btn) {
    BOOL isOn = [SGMVManager sharedManager].isVideoModeEnabled;
    btn.tintColor = isOn ? [UIColor systemGreenColor] : [UIColor whiteColor];
    btn.backgroundColor = isOn ? [[UIColor blackColor] colorWithAlphaComponent:0.75] : [[UIColor blackColor] colorWithAlphaComponent:0.45];
}

@interface SGRMVButtonHandler : NSObject
+ (instancetype)shared;
- (void)didTapMVButton:(UIButton *)sender;
@end

@implementation SGRMVButtonHandler
+ (instancetype)shared {
    static SGRMVButtonHandler *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [SGRMVButtonHandler new]; });
    return h;
}
- (void)didTapMVButton:(UIButton *)sender {
    [[SGMVManager sharedManager] toggleVideoMode];
    updateMVButtonAppearance(sender);
    SGPlayFeedback(SGFeedbackGrab);
}
@end

static void setupMVOverlayOn(UIView *tilt, UIView *cover) {
    // Attach MV video layer onto the active cover
    if (tilt == showingTilt() || showingTilt() == nil) {
        [[SGMVManager sharedManager] attachToContainerView:cover];
        [SGMVManager sharedManager].playerLayer.frame = cover.bounds;
        [SGMVManager sharedManager].playerLayer.cornerRadius = SGRRadiusArtwork;
    }

    // Create floating glass-style "MV" toggle button at top-right of cover
    UIButton *mvBtn = objc_getAssociatedObject(cover, &kMVButtonKey);
    if (!mvBtn) {
        mvBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
        [mvBtn setImage:[UIImage systemImageNamed:@"video.fill" withConfiguration:cfg] forState:UIControlStateNormal];
        [mvBtn setTitle:@" MV" forState:UIControlStateNormal];
        mvBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        mvBtn.layer.cornerRadius = 15;
        mvBtn.clipsToBounds = YES;
        [mvBtn addTarget:[SGRMVButtonHandler shared] action:@selector(didTapMVButton:) forControlEvents:UIControlEventTouchUpInside];
        [cover addSubview:mvBtn];
        objc_setAssociatedObject(cover, &kMVButtonKey, mvBtn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    mvBtn.frame = CGRectMake(cover.bounds.size.width - 74, 12, 62, 30);
    [cover bringSubviewToFront:mvBtn];
    updateMVButtonAppearance(mvBtn);
}

#pragma mark - hold to play faster

static const double kHoldSpeed = 2;
static char kHoldKey, kBadgeGlassKey;

@interface SGRCoverHold : UILongPressGestureRecognizer
@end

@implementation SGRCoverHold {
    double _before;
    UIView *_badge;
    UILabel *_badgeLabel;
    BOOL _badgeShown;
}

- (void)sgr_held {
    UIView *cover = self.view;
    if (self.state == UIGestureRecognizerStateBegan) {
        CGFloat x = [self locationInView:cover].x, third = cover.bounds.size.width / 3;
        if ((x > third && x < 2 * third) || !SGPlayerSpeedAllowed()) {
            self.enabled = NO;
            self.enabled = YES;
            return;
        }
        _before = SGPlayerSpeed();
        SGSetPlayerSpeed(kHoldSpeed);
        SGPlayFeedback(SGFeedbackGrab);
        [self showBadge:YES on:cover];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"Playing at 2 times speed");
    } else if (self.state == UIGestureRecognizerStateEnded || self.state == UIGestureRecognizerStateCancelled
               || self.state == UIGestureRecognizerStateFailed) {
        if (_before > 0) SGSetPlayerSpeed(_before);
        _before = 0;
        [self showBadge:NO on:cover];
    }
}

- (void)showBadge:(BOOL)shown on:(UIView *)cover {
    if (shown && !_badge) {
        _badgeLabel = [UILabel new];
        UIFont *font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        NSTextAttachment *arrows = [NSTextAttachment textAttachmentWithImage:[[UIImage systemImageNamed:@"forward.fill"
            withConfiguration:[UIImageSymbolConfiguration configurationWithFont:font]] imageWithTintColor:UIColor.whiteColor
            renderingMode:UIImageRenderingModeAlwaysOriginal]];
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:@"2×  "
            attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.whiteColor}];
        [text appendAttributedString:[NSAttributedString attributedStringWithAttachment:arrows]];
        _badgeLabel.attributedText = text;
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 92, 34)];
        _badge.userInteractionEnabled = NO;
        _badgeLabel.frame = _badge.bounds;
        _badgeLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_badge addSubview:_badgeLabel];
    }
    if (!_badge) return;
    _badgeShown = shown;
    UIView *badge = _badge, *label = _badgeLabel;
    UIView *shape = SGRGlassCapsuleInside(badge, &kBadgeGlassKey, badge.bounds.size, NO);
    void (^state)(BOOL) = ^(BOOL on) {
        SGRShowGlass(shape, on);
        label.alpha = on ? 1 : 0;
    };
    if (shown) {
        if (badge.superview != cover) {
            badge.center = CGPointMake(CGRectGetMidX(cover.bounds), 30);
            state(NO);
            badge.transform = SGRReduceMotion() ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.9, 0.9);
            [cover addSubview:badge];
        }
        SGRAnimate(SGRReduceMotion() ? SGRMotionFade : SGRMotionPress, ^{
            state(YES);
            badge.transform = CGAffineTransformIdentity;
        }, nil);
    } else {
        SGRAnimate(SGRMotionExit, ^{ state(NO); }, ^(BOOL finished) {
            if (finished && !self->_badgeShown) [badge removeFromSuperview];
        });
    }
}

@end

static void watchHold(UIView *tilt) {
    if (objc_getAssociatedObject(tilt, &kHoldKey)) return;
    SGRCoverHold *hold = [[SGRCoverHold alloc] initWithTarget:nil action:nil];
    [hold addTarget:hold action:@selector(sgr_held)];
    hold.minimumPressDuration = 0.35;
    [tilt addGestureRecognizer:hold];
    objc_setAssociatedObject(tilt, &kHoldKey, hold, OBJC_ASSOCIATION_ASSIGN);
}

%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)layoutSubviews {
    UIView *tilt = (UIView *)self;
    BOOL player = inCoverCell(tilt);
    %orig;
    if (tilt.bounds.size.width < kCoverMinWidth || !player) return;
    UIView *cover = coverIn(tilt);
    if (!cover) return;
    [sg_tilts addObject:tilt];
    watchHold(tilt);
    SGRPlayerMotionCoverLaidOut();

    CGRect bounds = tilt.bounds;
    CGPoint middle = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    if (!CGSizeEqualToSize(cover.bounds.size, bounds.size)) cover.bounds = (CGRect){cover.bounds.origin, bounds.size};
    if (!CGPointEqualToPoint(cover.center, middle)) cover.center = middle;
    for (UIView *image in cover.subviews) {
        if (![image isKindOfClass:[UIButton class]] && !CGRectEqualToRect(image.frame, cover.bounds)) {
            image.bounds = image.bounds;
            image.center = image.center;
        }
    }

    cover.layer.cornerRadius = SGRRadiusArtwork;
    cover.layer.cornerCurve = kCACornerCurveContinuous;
    cover.clipsToBounds = YES;
    SGRShadowPlate *plate = SGRShadowPlateIn(tilt, &kPlateKey);
    plate.bounds = cover.bounds;
    plate.center = cover.center;
    scaleCover(tilt, currentScale());

    // Attach external MV layer and toggle button
    setupMVOverlayOn(tilt, cover);
}
%end

static UIView *coverOfImage(UIView *image) {
    UIView *box = image.superview;
    return box && coverIn(box.superview) == box ? box : nil;
}

%hook _TtC22NowPlaying_ElementsKitP33_1D6A1393FEB35D7207F503DA17E7748E14ImageViewProxy
- (void)setFrame:(CGRect)frame {
    UIView *box = coverOfImage((UIView *)self);
    %orig(box ? box.bounds : frame);
}
- (void)setBounds:(CGRect)bounds {
    UIView *box = coverOfImage((UIView *)self);
    %orig(box ? (CGRect){bounds.origin, box.bounds.size} : bounds);
}
- (void)setCenter:(CGPoint)center {
    UIView *box = coverOfImage((UIView *)self);
    %orig(box ? CGPointMake(CGRectGetMidX(box.bounds), CGRectGetMidY(box.bounds)) : center);
}
- (void)layoutSubviews {
    %orig;
    UIView *proxy = (UIView *)self;
    if (!coverOfImage(proxy)) return;
    for (UIView *image in proxy.subviews) {
        if (!CGRectEqualToRect(image.frame, proxy.bounds)) image.frame = proxy.bounds;
    }
}
%end

%hook _TtCE15Encore_MediaKitO16EncoreFoundation6Encore9ImageView
- (void)layoutSubviews {
    %orig;
    UIView *view = (UIView *)self;
    static Class proxyClass;
    if (!proxyClass) proxyClass = NSClassFromString(@"_TtC22NowPlaying_ElementsKitP33_1D6A1393FEB35D7207F503DA17E7748E14ImageViewProxy");
    if (![view.superview isKindOfClass:proxyClass] || !coverOfImage(view.superview)) return;
    for (UIView *part in view.subviews) {
        if (!CGRectEqualToRect(part.frame, view.bounds)) part.frame = view.bounds;
    }
}
%end

@interface SGRPlayerArtworkWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGRPlayerArtworkWatcher {
    NSInteger _paused;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _paused = -1;
    return self;
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSInteger paused = state.isPaused ? 1 : 0;
    if (paused != _paused) {
        _paused = paused;
        scaleEveryCover(YES);
    }

    // Fetch external MV when track changes
    SPTPlayerTrack *track = state.track;
    if (track.trackTitle.length > 0) {
        NSString *artist = [track.artistName isKindOfClass:NSString.class] ? track.artistName : @"";
        [[SGMVManager sharedManager] fetchMVForTrack:track.trackTitle artist:artist completion:^(BOOL hasVideo) {
            UIView *tilt = showingTilt();
            UIView *cover = coverIn(tilt);
            if (cover) {
                [[SGMVManager sharedManager] attachToContainerView:cover];
                UIButton *btn = objc_getAssociatedObject(cover, &kMVButtonKey);
                if (btn) btn.alpha = hasVideo ? 1.0 : 0.45;
            }
        }];
    }
}

@end

static SGRPlayerArtworkWatcher *sg_artworkWatcher;

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    sg_tilts = [NSHashTable weakObjectsHashTable];
    sg_covers = [NSMapTable weakToWeakObjectsMapTable];
    sg_artworkWatcher = [SGRPlayerArtworkWatcher new];
    SGAddPlayerStateObserver(sg_artworkWatcher);

    // Sync MV video timeline with Spotify playback every 0.4 seconds
    sg_mvSyncTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *timer) {
        if (![SGMVManager sharedManager].isVideoModeEnabled) return;
        SPTPlayerState *state = SGPlayerState();
        if (!state) return;
        NSTimeInterval pos = [state respondsToSelector:@selector(position)] ? state.position : 0;
        [[SGMVManager sharedManager] syncWithPlaybackPosition:pos isPlaying:!state.isPaused];
    }];
}

