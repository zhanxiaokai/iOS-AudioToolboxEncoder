//
//  AudioToolboxEncoder.m
//  AudioTooboxEncoder
//
//  Created by apple on 16/11/3.
//  Copyright © 2016年 xiaokai.zhan. All rights reserved.
//

#import "AudioToolboxEncoder.h"
@interface AudioToolboxEncoder()

@property(nonatomic) AudioConverterRef      audioConverter;
@property(nonatomic) uint8_t*               aacBuffer;
@property(nonatomic) UInt32                 aacBufferSize;
@property(nonatomic) uint8_t*               pcmBuffer;
@property(nonatomic) size_t                 pcmBufferSize;

@property(nonatomic) UInt32                 channels;
@property(nonatomic) NSInteger              inputSampleRate;

@property(nonatomic) BOOL                   isCompletion;
@property(nonatomic) BOOL                   withADTSHeader;

@property(nonatomic) int64_t                presentationTimeMills;

@property (readwrite, copy) id<FillDataDelegate> fillAudioDataDelegate;
@end

@implementation AudioToolboxEncoder

- (id) initWithSampleRate:(NSInteger) inputSampleRate channels:(int) channels bitRate:(int) bitRate withADTSHeader:(BOOL) withADTSHeader filleDataDelegate:(id<FillDataDelegate>) fillAudioDataDelegate {
    if(self = [super init]) {
        _audioConverter = NULL;
        _inputSampleRate = inputSampleRate;
        _pcmBuffer = NULL;
        _pcmBufferSize = 0;
        _presentationTimeMills = 0;
        _isCompletion = NO;
        _aacBuffer = NULL;
        _channels = channels;
        _withADTSHeader = withADTSHeader;
        _fillAudioDataDelegate = fillAudioDataDelegate;
        [self setupEncoderWithSampleRate:inputSampleRate channels:channels bitRate:bitRate];
        dispatch_queue_t encoderQueue = dispatch_queue_create("AAC Encoder Queue", DISPATCH_QUEUE_SERIAL);
        dispatch_async(encoderQueue, ^{
            [self encoder];
        });
    }
    return self;
}

- (void) setupEncoderWithSampleRate:(NSInteger) inputSampleRate channels:(int) channels bitRate:(UInt32) bitRate {
    //构建InputABSD
    AudioStreamBasicDescription inAudioStreamBasicDescription = {0};
    UInt32 bytesPerSample = sizeof (SInt16);
    inAudioStreamBasicDescription.mFormatID = kAudioFormatLinearPCM;
    inAudioStreamBasicDescription.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    inAudioStreamBasicDescription.mBytesPerPacket = bytesPerSample * channels;
    inAudioStreamBasicDescription.mBytesPerFrame = bytesPerSample * channels;
    inAudioStreamBasicDescription.mChannelsPerFrame = channels;
    inAudioStreamBasicDescription.mFramesPerPacket = 1;
    inAudioStreamBasicDescription.mBitsPerChannel = 8 * channels;
    inAudioStreamBasicDescription.mSampleRate = inputSampleRate;
    inAudioStreamBasicDescription.mReserved = 0;
    //构造OutputABSD
    AudioStreamBasicDescription outAudioStreamBasicDescription = {0};
    outAudioStreamBasicDescription.mSampleRate = inAudioStreamBasicDescription.mSampleRate;
    outAudioStreamBasicDescription.mFormatID = kAudioFormatMPEG4AAC; // 设置编码格式
    outAudioStreamBasicDescription.mFormatFlags = kMPEG4Object_AAC_LC; // 无损编码 ，0表示没有
    outAudioStreamBasicDescription.mBytesPerPacket = 0;
    outAudioStreamBasicDescription.mFramesPerPacket = 1024;
    outAudioStreamBasicDescription.mBytesPerFrame = 0;
    outAudioStreamBasicDescription.mChannelsPerFrame = inAudioStreamBasicDescription.mChannelsPerFrame;
    outAudioStreamBasicDescription.mBitsPerChannel = 0;
    outAudioStreamBasicDescription.mReserved = 0;
    //构造编码器类的描述
    AudioClassDescription *description = [self
                                          getAudioClassDescriptionWithType:kAudioFormatMPEG4AAC
                                          fromManufacturer:kAppleSoftwareAudioCodecManufacturer]; //软编
    //构建AudioConverter
    OSStatus status = AudioConverterNewSpecific(&inAudioStreamBasicDescription, &outAudioStreamBasicDescription, 1, description, &_audioConverter);
    if (status != 0) {
        NSLog(@"setup converter: %d", (int)status);
    }
    UInt32 ulSize = sizeof(bitRate);
    status = AudioConverterSetProperty(_audioConverter, kAudioConverterEncodeBitRate, ulSize, &bitRate);
    UInt32 size = sizeof(_aacBufferSize);
    AudioConverterGetProperty(_audioConverter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &_aacBufferSize);
    NSLog(@"Expected BitRate is %@, Output PacketSize is %d", @(bitRate), _aacBufferSize);
//    _aacBufferSize = 1024;
    _aacBuffer = malloc(_aacBufferSize * sizeof(uint8_t));
    memset(_aacBuffer, 0, _aacBufferSize);
}

- (AudioClassDescription *)getAudioClassDescriptionWithType:(UInt32)type
                                           fromManufacturer:(UInt32)manufacturer
{
    static AudioClassDescription desc;
    
    UInt32 encoderSpecifier = type;
    OSStatus st;
    
    UInt32 size;
    st = AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders,
                                    sizeof(encoderSpecifier),
                                    &encoderSpecifier,
                                    &size);
    if (st) {
        NSLog(@"error getting audio format propery info: %d", (int)(st));
        return nil;
    }
    
    unsigned int count = size / sizeof(AudioClassDescription);
    AudioClassDescription descriptions[count];
    st = AudioFormatGetProperty(kAudioFormatProperty_Encoders,
                                sizeof(encoderSpecifier),
                                &encoderSpecifier,
                                &size,
                                descriptions);
    if (st) {
        NSLog(@"error getting audio format propery: %d", (int)(st));
        return nil;
    }
    
    for (unsigned int i = 0; i < count; i++) {
        if ((type == descriptions[i].mSubType) &&
            (manufacturer == descriptions[i].mManufacturer)) {
            memcpy(&desc, &(descriptions[i]), sizeof(desc));
            return &desc;
        }
    }
    
    return nil;
}

- (void) encoder {
    while (!_isCompletion) {
        NSData* outputData = nil;
        if (_audioConverter) {
            NSError *error = nil;
            AudioBufferList outAudioBufferList = {0};
            outAudioBufferList.mNumberBuffers = 1;
            outAudioBufferList.mBuffers[0].mNumberChannels = _channels;
            outAudioBufferList.mBuffers[0].mDataByteSize = (int)_aacBufferSize;
            outAudioBufferList.mBuffers[0].mData = _aacBuffer;
            AudioStreamPacketDescription *outPacketDescription = NULL;
            UInt32 ioOutputDataPacketSize = 1;
            // Converts data supplied by an input callback function, supporting non-interleaved and packetized formats.
            // Produces a buffer list of output data from an AudioConverter. The supplied input callback function is called whenever necessary.
            OSStatus status = AudioConverterFillComplexBuffer(_audioConverter, inInputDataProc, (__bridge void *)(self), &ioOutputDataPacketSize, &outAudioBufferList, outPacketDescription);
            if (status == 0) {
                NSData *rawAAC = [NSData dataWithBytes:outAudioBufferList.mBuffers[0].mData length:outAudioBufferList.mBuffers[0].mDataByteSize];
                if(_withADTSHeader) {
                    NSData *adtsHeader = [self adtsDataForPacketLength:rawAAC.length];
                    NSMutableData *fullData = [NSMutableData dataWithData:adtsHeader];
                    [fullData appendData:rawAAC];
                    outputData = fullData;
                } else {
                    outputData = rawAAC;
                }
            } else {
                error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
            }
            if (_fillAudioDataDelegate  && [_fillAudioDataDelegate respondsToSelector:@selector(outputAACPakcet:presentationTimeMills:error:)]) {
                [_fillAudioDataDelegate outputAACPakcet:outputData presentationTimeMills:_presentationTimeMills error:error];
            }
        } else {
            NSLog(@"Audio Converter Init Failed...");
            break;
        }
    }
    if(_fillAudioDataDelegate && [_fillAudioDataDelegate respondsToSelector:@selector(onCompletion)]) {
        [_fillAudioDataDelegate onCompletion];
    }
}

/**
 *  A callback function that supplies audio data to convert. This callback is invoked repeatedly as the converter is ready for new input data.
 
 */
OSStatus inInputDataProc(AudioConverterRef inAudioConverter, UInt32 *ioNumberDataPackets, AudioBufferList *ioData, AudioStreamPacketDescription **outDataPacketDescription, void *inUserData)
{
    AudioToolboxEncoder *encoder = (__bridge AudioToolboxEncoder *)(inUserData);
    return [encoder fillAudioRawData:ioData ioNumberDataPackets:ioNumberDataPackets];
}

- (OSStatus) fillAudioRawData:(AudioBufferList *) ioData ioNumberDataPackets:(UInt32 *) ioNumberDataPackets {
    UInt32 requestedPackets = *ioNumberDataPackets;
    uint32_t bufferLength = requestedPackets * _channels * 2;
    uint32_t bufferRead = 0;
    if(NULL == _pcmBuffer) {
        _pcmBuffer = malloc(bufferLength);
    }
    if(_fillAudioDataDelegate && [_fillAudioDataDelegate respondsToSelector:@selector(fillAudioData:bufferSize:)]) {
        bufferRead = [_fillAudioDataDelegate fillAudioData:_pcmBuffer bufferSize:bufferLength];
    }
    if (bufferRead <= 0) {
        *ioNumberDataPackets = 0;
        _isCompletion = YES;
        return -1;
    }
    _presentationTimeMills += (float)requestedPackets * 1000 / (float)_inputSampleRate;
    ioData->mBuffers[0].mData = _pcmBuffer;
    ioData->mBuffers[0].mDataByteSize = bufferRead;
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = _channels;
    *ioNumberDataPackets = 1 ;
    return noErr;
}

/**
 *  Add ADTS header at the beginning of each and every AAC packet.
 *  This is needed as MediaCodec encoder generates a packet of raw
 *  AAC data.
 *
 *  Note the packetLen must count in the ADTS header itself.
 *  See: http://wiki.multimedia.cx/index.php?title=ADTS
 *  Also: http://wiki.multimedia.cx/index.php?title=MPEG-4_Audio#Channel_Configurations
 **/
- (NSData*) adtsDataForPacketLength:(NSUInteger)packetLength {
    int adtsLength = 7;
    char *packet = malloc(sizeof(char) * adtsLength);
    // Variables Recycled by addADTStoPacket
    int profile = 2;  //AAC LC
    //39=MediaCodecInfo.CodecProfileLevel.AACObjectELD;
    int freqIdx = 4;  //44.1KHz
    int chanCfg = _channels;  //MPEG-4 Audio Channel Configuration. 1 Channel front-center
    NSUInteger fullLength = adtsLength + packetLength;
    // fill in ADTS data
    packet[0] = (char)0xFF; // 11111111     = syncword
    packet[1] = (char)0xF9; // 1111 1 00 1  = syncword MPEG-2 Layer CRC
    packet[2] = (char)(((profile-1)<<6) + (freqIdx<<2) +(chanCfg>>2));
    packet[3] = (char)(((chanCfg&3)<<6) + (fullLength>>11));
    packet[4] = (char)((fullLength&0x7FF) >> 3);
    packet[5] = (char)(((fullLength&7)<<5) + 0x1F);
    packet[6] = (char)0xFC;
    NSData *data = [NSData dataWithBytesNoCopy:packet length:adtsLength freeWhenDone:YES];
    return data;
}

- (void) dealloc
{
    if(_pcmBuffer) {
        free(_pcmBuffer);
        _pcmBuffer = NULL;
    }
    if(_aacBuffer) {
        free(_aacBuffer);
        _aacBuffer = NULL;
    }
    AudioConverterDispose(_audioConverter);
}
@end
