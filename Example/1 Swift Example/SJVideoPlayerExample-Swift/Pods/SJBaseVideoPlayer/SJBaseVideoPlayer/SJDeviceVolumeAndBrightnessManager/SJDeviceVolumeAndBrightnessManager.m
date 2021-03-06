//
//  SJDeviceVolumeAndBrightnessManager.m
//  SJDeviceVolumeAndBrightnessManager
//
//  Created by BlueDancer on 2017/12/10.
//  Copyright © 2017年 SanJiang. All rights reserved.
//

#import "SJDeviceVolumeAndBrightnessManager.h"
#import "SJDeviceVolumeAndBrightnessManagerResourceLoader.h"
#import "SJDeviceOutputPromptView.h"
#import "SJBaseVideoPlayerConst.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MPVolumeView.h>

#if __has_include(<Masonry/Masonry.h>)
#import <Masonry/Masonry.h>
#else
#import "Masonry.h"
#endif

#if __has_include(<SJUIKit/NSObject+SJObserverHelper.h>)
#import <SJUIKit/NSObject+SJObserverHelper.h>
#else
#import "NSObject+SJObserverHelper.h"
#endif

#if __has_include(<SJUIKit/SJRunLoopTaskQueue.h>)
#import <SJUIKit/SJRunLoopTaskQueue.h>
#else
#import "SJRunLoopTaskQueue.h"
#endif


NS_ASSUME_NONNULL_BEGIN
static NSNotificationName const SJDeviceVolumeDidChangeNotification = @"SJDeviceVolumeDidChangeNotification";
static NSNotificationName const SJDeviceBrightnessDidChangeNotification = @"SJDeviceBrightnessDidChangeNotification";

@interface SJDeviceVolumeAndBrightnessManagerObserver : NSObject<SJDeviceVolumeAndBrightnessManagerObserver>
- (instancetype)initWithMgr:(id<SJDeviceVolumeAndBrightnessManager>)mgr;
@end

@implementation SJDeviceVolumeAndBrightnessManagerObserver {
    id _volumeDidChangeToken;
    id _brightnessDidChangeToken;
}
@synthesize volumeDidChangeExeBlock = _volumeDidChangeExeBlock;
@synthesize brightnessDidChangeExeBlock = _brightnessDidChangeExeBlock;

- (instancetype)initWithMgr:(id<SJDeviceVolumeAndBrightnessManager>)mgr {
    self = [super init];
    if ( !self )
        return nil;
    __weak typeof(self) _self = self;
    _volumeDidChangeToken = [NSNotificationCenter.defaultCenter addObserverForName:SJDeviceVolumeDidChangeNotification object:mgr queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification * _Nonnull note) {
        __strong typeof(_self) self = _self;
        if ( !self ) return ;
        id<SJDeviceVolumeAndBrightnessManager> mgr = note.object;
        if ( self.volumeDidChangeExeBlock ) self.volumeDidChangeExeBlock(mgr, mgr.volume);
    }];
    
    _brightnessDidChangeToken = [NSNotificationCenter.defaultCenter addObserverForName:SJDeviceBrightnessDidChangeNotification object:mgr queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification * _Nonnull note) {
        __strong typeof(_self) self = _self;
        if ( !self ) return ;
        id<SJDeviceVolumeAndBrightnessManager> mgr = note.object;
        if ( self.brightnessDidChangeExeBlock ) self.brightnessDidChangeExeBlock(mgr, mgr.brightness);
    }];
    return self;
}

- (void)dealloc {
    if ( _volumeDidChangeToken ) [NSNotificationCenter.defaultCenter removeObserver:_volumeDidChangeToken];
    if ( _brightnessDidChangeToken ) [NSNotificationCenter.defaultCenter removeObserver:_brightnessDidChangeToken];
}
@end


#pragma mark -

@interface SJDeviceVolumeAndBrightnessManager ()
@property (nonatomic, strong, readonly) SJRunLoopTaskQueue *taskQueue;

@property (nonatomic, strong, readonly) SJDeviceOutputPromptView *brightnessView;
@property (nonatomic, strong, readonly) SJDeviceOutputPromptViewModel *brightnessViewModel;

@property (nonatomic, strong, readonly) MPVolumeView *sysVolumeView;
@property (nonatomic, strong, readonly) UISlider *sysVolumeSlider;
@property (nonatomic, strong, readonly) SJDeviceOutputPromptView *volumeView;
@property (nonatomic, strong, readonly) SJDeviceOutputPromptViewModel *volumeViewModel;
@end

@implementation SJDeviceVolumeAndBrightnessManager
@synthesize sysVolumeSlider = _sysVolumeSlider;
@synthesize volumeTracking = _volumeTracking;
@synthesize brightnessTracking = _brightnessTracking;

+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self shared];
    });
}

+ (instancetype)shared {
    static id _instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [self new];
    });
    return _instance;
}

- (instancetype)init {
    self = [super init];
    if ( !self ) return nil;
    _taskQueue = SJRunLoopTaskQueue.queue(@"SJDeviceVolumeAndBrightnessManagerTaskQueue").update(CFRunLoopGetMain(), kCFRunLoopCommonModes).delay(5);
    
    __weak typeof(self) _self = self;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        sjkvo_observe(UIScreen.mainScreen, @"brightness", ^(id  _Nonnull target, NSDictionary<NSKeyValueChangeKey,id> * _Nullable change) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(_self) self = _self;
                if ( !self ) return ;
                [self handleBrightnessDidChangeNotification];
            });
        });
        
        sjkvo_observe(AVAudioSession.sharedInstance, @"outputVolume", ^(id  _Nonnull target, NSDictionary<NSKeyValueChangeKey,id> * _Nullable change) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(_self) self = _self;
                if ( !self ) return ;
                [self handleVolumeDidChangeEvent];
            });
        });
    });
    
    SJRunLoopTaskQueue.main.enqueue(^{
        for ( UIView *subview in self.sysVolumeView.subviews ) {
            if ( [subview.class.description isEqualToString:@"MPVolumeSlider"] ) {
                self->_sysVolumeSlider = (UISlider *)subview;
                break;
            }
        }
    });

    return self;
}

- (id<SJDeviceVolumeAndBrightnessManagerObserver>)getObserver {
    return [[SJDeviceVolumeAndBrightnessManagerObserver alloc] initWithMgr:self];
}

#pragma mark - target view

- (void)prepare {
    [self _addOrRemoveSysVolumeView:[self targetView].window];
}

- (nullable UIView *)targetView {
    return [UIApplication.sharedApplication.keyWindow viewWithTag:SJBaseVideoPlayerPresentViewTag];
}

- (void)_addOrRemoveSysVolumeView:(nullable UIWindow *)newWindow {
    if ( newWindow != nil ) {
        if ( self.sysVolumeView.superview != newWindow )
            [newWindow addSubview:self.sysVolumeView];
    }
    else {
        [self.sysVolumeView removeFromSuperview];
    }
}

#pragma mark - volume

- (void)_volumeDidChange {
    [self _refreshDataForVolumeView];
    [self _showVolumeViewIfNeeded];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_hiddenVolumeView) object:nil];
    [self performSelector:@selector(_hiddenVolumeView)
               withObject:nil
               afterDelay:1
                  inModes:@[NSRunLoopCommonModes]];
}

@synthesize volume = _volume;
- (void)setVolume:(float)volume {
    if ( isnan(volume) )
        return;

    if ( volume < 0 )
        volume = 0;
    else if ( volume > 1 )
        volume = 1;
    _volume = volume;
    _taskQueue.empty().enqueue(^{
        [self.sysVolumeSlider setValue:volume animated:NO];
    });
    
    [self _volumeDidChange];
}

- (void)_syncVolume {
    _volume = [AVAudioSession sharedInstance].outputVolume;
}

@synthesize sysVolumeView = _sysVolumeView;
- (MPVolumeView *)sysVolumeView {
    if ( _sysVolumeView == nil ) {
        CGFloat maxOffset = MAX(CGRectGetWidth(UIScreen.mainScreen.bounds),
                                CGRectGetHeight(UIScreen.mainScreen.bounds)) + 100;
        _sysVolumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-maxOffset, -maxOffset, 0, 0)];
    }
    return _sysVolumeView;
}

@synthesize volumeView = _volumeView;
- (SJDeviceOutputPromptView *)volumeView {
    if ( _volumeView == nil ) {
        _volumeView = [SJDeviceOutputPromptView new];
        _volumeView.dataSource = self.volumeViewModel;
    }
    return _volumeView;
}

@synthesize volumeViewModel = _volumeViewModel;
- (SJDeviceOutputPromptViewModel *)volumeViewModel {
    if ( _volumeViewModel == nil ) {
        _volumeViewModel = [SJDeviceOutputPromptViewModel new];
        _volumeViewModel.trackColor = self.trackColor;
        _volumeViewModel.traceColor = self.traceColor;
    }
    return _volumeViewModel;
}
 
static UIImage *_muteImage = nil;
static UIImage *_volumeImage = nil;
- (void)_refreshDataForVolumeView {
    float volume = self.volume;
    
    self.volumeViewModel.progress = volume;
    self.volumeViewModel.image = (self.volume > 0) ? _volumeImage : _muteImage;
    [self.volumeView refreshData];
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            UIImage *muteImage = [SJDeviceVolumeAndBrightnessManagerResourceLoader imageNamed:@"mute"];
            UIImage *volumeImage = [SJDeviceVolumeAndBrightnessManagerResourceLoader imageNamed:@"volume"];
            dispatch_async(dispatch_get_main_queue(), ^{
                _muteImage = muteImage;
                _volumeImage = volumeImage;
                self.volumeViewModel.image = (self.volume > 0) ? _volumeImage : _muteImage;
                [self.volumeView refreshData];
            });
        });
    });
}

- (void)_showVolumeViewIfNeeded {
    UIView *targetView = self.targetView;
    if ( targetView.window != nil && self.volumeView.superview != targetView ) {
        [targetView addSubview:self.volumeView];
        [self.volumeView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.center.offset(0);
        }];
    }
}

- (void)_hiddenVolumeView {
    [self.volumeView removeFromSuperview];
}

#pragma mark - brightness

- (void)_brightnessDidChange {
    [self _refreshDataForBrightnessView];
    [self _showBrightnessViewIfNeeded];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_hiddenBrightnessView) object:nil];
    [self performSelector:@selector(_hiddenBrightnessView)
               withObject:nil
               afterDelay:1
                  inModes:@[NSRunLoopCommonModes]];
}

- (void)setBrightness:(float)brightness {
    if ( isnan(brightness) )
        return;
    
    if ( brightness < 0 )
        brightness = 0;
    else if ( brightness > 1 )
        brightness = 1;
    
    [UIScreen mainScreen].brightness = brightness;
    [self _brightnessDidChange];
}

- (float)brightness {
    return [UIScreen mainScreen].brightness;
}

@synthesize brightnessView = _brightnessView;
- (SJDeviceOutputPromptView *)brightnessView {
    if ( _brightnessView == nil ) {
        _brightnessView = [SJDeviceOutputPromptView new];
        _brightnessView.dataSource = self.brightnessViewModel;
    }
    return _brightnessView;
}

@synthesize brightnessViewModel = _brightnessViewModel;
- (SJDeviceOutputPromptViewModel *)brightnessViewModel {
    if ( _brightnessViewModel == nil ) {
        _brightnessViewModel = [SJDeviceOutputPromptViewModel new];
        _brightnessViewModel.trackColor = self.trackColor;
        _brightnessViewModel.traceColor = self.traceColor;
    }
    return _brightnessViewModel;
}

- (void)_refreshDataForBrightnessView {
    float brightness = self.brightness;
    
    self.brightnessViewModel.progress = brightness;
    [self.brightnessView refreshData];
    
    if ( self.brightnessViewModel.image == nil ) {
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            UIImage *image = [SJDeviceVolumeAndBrightnessManagerResourceLoader imageNamed:@"brightness"];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.brightnessViewModel.image = image;
                [self.brightnessView refreshData];
            });
        });
    }
}

- (void)_showBrightnessViewIfNeeded {
    UIView *targetView = self.targetView;
    if ( targetView != nil && self.brightnessView.superview != targetView ) {
        [targetView addSubview:self.brightnessView];
        [self.brightnessView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.center.offset(0);
        }];
    }
}

- (void)_hiddenBrightnessView {
    [self.brightnessView removeFromSuperview];
}

#pragma mark - notifies

- (void)handleVolumeDidChangeEvent {
    UIView *targetView = self.targetView;
    [self _addOrRemoveSysVolumeView:targetView.window];
    if ( self.isVolumeTracking == NO ) {
        [self _syncVolume];
        if ( targetView.window != nil ) {
            self.volumeTracking = YES;
            [self _volumeDidChange];
            self.volumeTracking = NO;
        }
    }

    [NSNotificationCenter.defaultCenter postNotificationName:SJDeviceVolumeDidChangeNotification object:self];
}

- (void)handleBrightnessDidChangeNotification {
    if ( !self.isBrightnessTracking )
        [self _refreshDataForBrightnessView];
    [NSNotificationCenter.defaultCenter postNotificationName:SJDeviceBrightnessDidChangeNotification object:self];
}

#pragma mark - colors

@synthesize traceColor = _traceColor;
- (void)setTraceColor:(nullable UIColor *)traceColor {
    _traceColor = traceColor;
    _volumeViewModel.traceColor = _brightnessViewModel.traceColor = self.traceColor;
    [_brightnessView refreshData];
    [_volumeView refreshData];
}

- (UIColor *)traceColor {
    return _traceColor?:UIColor.whiteColor;
}

@synthesize trackColor = _trackColor;
- (void)setTrackColor:(nullable UIColor *)trackColor {
    _trackColor = trackColor;
    _volumeViewModel.trackColor = _brightnessViewModel.trackColor = self.trackColor;
    [_brightnessView refreshData];
    [_volumeView refreshData];
}
- (UIColor *)trackColor {
    return _trackColor?:[UIColor colorWithWhite:0.6 alpha:0.5];
}
@end
NS_ASSUME_NONNULL_END
