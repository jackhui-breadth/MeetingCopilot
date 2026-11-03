#import "MCAudioTapInstaller.h"

NSErrorDomain const MCAudioSupportErrorDomain =
    @"com.songhui.meetingcopilot.audio-support";

@implementation MCAudioTapInstaller

+ (BOOL)installTapOnNode:(AVAudioNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(AVAudioFormat *)format
                   block:(AVAudioNodeTapBlock)block
                   error:(NSError **)error {
    @try {
        [node installTapOnBus:bus
                   bufferSize:bufferSize
                       format:format
                        block:block];
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: @"未知音频设备格式错误";
            *error = [NSError errorWithDomain:MCAudioSupportErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: reason,
                @"exceptionName": exception.name ?: @"NSException"
            }];
        }
        return NO;
    }
}

+ (BOOL)removeTapFromNode:(AVAudioNode *)node
                      bus:(AVAudioNodeBus)bus
                    error:(NSError **)error {
    @try {
        [node removeTapOnBus:bus];
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: @"无法移除录音输入";
            *error = [NSError errorWithDomain:MCAudioSupportErrorDomain
                                         code:2
                                     userInfo:@{
                NSLocalizedDescriptionKey: reason,
                @"exceptionName": exception.name ?: @"NSException"
            }];
        }
        return NO;
    }
}

@end
