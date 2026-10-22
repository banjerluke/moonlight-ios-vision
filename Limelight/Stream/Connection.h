//
//  Connection.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "AnyVideoDecoderRenderer.h"
// Will be handled from Swift
@class StreamConfiguration;

#define CONN_TEST_SERVER "ios.conntest.moonlight-stream.org"

typedef struct {
    CFTimeInterval startTime;
    CFTimeInterval endTime;
    int totalFrames;
    int receivedFrames;
    int networkDroppedFrames;
    int totalHostProcessingLatency;
    int framesWithHostProcessingLatency;
    int maxHostProcessingLatency;
    int minHostProcessingLatency;
} video_stats_t;

extern volatile int volume;
void setVolume(int newVol);

int DrSubmitDecodeUnit(PDECODE_UNIT decodeUnit);

@interface Connection : NSOperation <NSStreamDelegate>

-(id) initWithConfig:(StreamConfiguration*)config renderer:(id<AnyVideoDecoderRenderer> __strong)myRenderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks;
-(void) terminate;
-(void) terminateWithCompletion:(void (^)(void))completion;
// `completion` runs on main once the UI may move on: when the stop finishes, or earlier if waiting
// for initLock or LiStopConnection times out. `stopped` runs on main only after LiStopConnection has
// really returned and initLock is released, so the next connection can start.
-(void) terminateWithCompletion:(void (^)(void))completion stopped:(void (^)(void))stopped;
-(void) main;
-(BOOL) getVideoStats:(video_stats_t*)stats;
-(NSString*) getActiveCodecName;

@end
