//
//  StreamFrameViewController.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Connection.h"
#import "StreamView.h"

#import <UIKit/UIKit.h>

#if TARGET_OS_TV
@import GameController;

@interface StreamFrameViewController : GCEventViewController <ConnectionCallbacks, ControllerSupportDelegate, UserInteractionDelegate, UIScrollViewDelegate>
#else
@interface StreamFrameViewController : UIViewController <ConnectionCallbacks, ControllerSupportDelegate, UserInteractionDelegate, UIScrollViewDelegate>
#endif
@property (nonatomic, strong) StreamConfiguration* streamConfig;

typedef void (^noargCallbackType)(void);
@property (nonatomic, strong) noargCallbackType connectedCallback;
@property (nonatomic, strong) noargCallbackType disconnectedCallback;
#if TARGET_OS_VISION
@property (nonatomic, assign) BOOL fpsMouseCaptureEnabled;
// On visionOS a StreamSession owns the StreamManager and ControllerSupport. It calls this before
// each connection attempt; the returned block creates the renderer for that attempt.
- (id<AnyVideoDecoderRenderer> (^)(void))prepareStreamAttemptWithControllerSupport:(ControllerSupport*)controllerSupport callbacks:(id<ConnectionCallbacks>)callbacks;
@property (nonatomic, copy) NSString* (^statsTextProvider)(void);
#endif

-(void)updatePreferredDisplayMode:(BOOL)streamActive;
- (void)stopStream;
- (void)startStream;
- (void)toggleKeyboard;
- (void)setAbsoluteTouchMode:(BOOL)enabled;

@end
