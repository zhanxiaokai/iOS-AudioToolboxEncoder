//
//  AudioToolboxEncoder.h
//  AudioTooboxEncoder
//
//  Created by apple on 16/11/3.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

@protocol FillDataDelegate <NSObject>

- (UInt32) fillAudioData:(uint8_t*) sampleBuffer bufferSize:(UInt32) bufferSize;

- (void) outputAACPakcet:(NSData*) data presentationTimeMills:(int64_t)presentationTimeMills error:(NSError*) error;

- (void) onCompletion;

@end

@interface AudioToolboxEncoder : NSObject

- (id) initWithSampleRate:(NSInteger) inputSampleRate channels:(int) channels bitRate:(int) bitRate withADTSHeader:(BOOL) withADTSHeader filleDataDelegate:(id<FillDataDelegate>) fillAudioDataDelegate;

@end
