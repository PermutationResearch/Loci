#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <objc/runtime.h>

static NSString *const kOutputPath = @"/Users/cno/Documents/Codex/2026-06-16/create-a-new-project-built-a/dist/video/loci-real-capture.mp4";
static NSString *const kStatusPath = @"/private/tmp/loci-real-capture-status.txt";
static NSString *const kLociPath = @"/Users/cno/Applications/Loci.app";
static NSString *const kLociBundleID = @"com.codex.loci";

static void WriteStatus(NSString *message) {
  [message writeToFile:kStatusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSString *ErrorText(NSError *error) {
  if (error == nil) {
    return @"unknown";
  }
  NSString *description = error.localizedDescription ?: @"unknown";
  NSString *reason = error.localizedFailureReason;
  if (reason.length > 0) {
    return [NSString stringWithFormat:@"%@ / %@", description, reason];
  }
  return description;
}

static void ActivateLoci(void) {
  NSURL *url = [NSURL fileURLWithPath:kLociPath];
  [[NSWorkspace sharedWorkspace] launchApplicationAtURL:url
                                                options:NSWorkspaceLaunchDefault
                                          configuration:@{}
                                                  error:nil];

  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4.0];
  while ([deadline timeIntervalSinceNow] > 0) {
    NSArray<NSRunningApplication *> *apps =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:kLociBundleID];
    if (apps.count > 0) {
      for (NSRunningApplication *app in apps) {
        [app activateWithOptions:NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps];
      }
      return;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
}

@interface InjectedRecorder : NSObject <SCRecordingOutputDelegate, SCStreamDelegate>
@property(nonatomic, strong) SCStream *stream;
@property(nonatomic, strong) SCRecordingOutput *recordingOutput;
@property(nonatomic, assign) BOOL finished;
@end

@implementation InjectedRecorder

- (void)start {
  WriteStatus(@"injected-starting");
  ActivateLoci();

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self startScreenCapture];
  });
}

- (void)startScreenCapture {
  WriteStatus(@"injected-requesting-screen-content");

  if (!CGPreflightScreenCaptureAccess()) {
    CGRequestScreenCaptureAccess();
  }

  [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                             onScreenWindowsOnly:YES
                                               completionHandler:^(SCShareableContent *_Nullable content, NSError *_Nullable error) {
    if (error != nil || content == nil) {
      WriteStatus([NSString stringWithFormat:@"shareable-content-error:%@", ErrorText(error)]);
      [self finishApp];
      return;
    }

    SCDisplay *display = content.displays.firstObject;
    if (display == nil) {
      WriteStatus(@"shareable-content-error:no-display");
      [self finishApp];
      return;
    }

    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
    filter.includeMenuBar = YES;

    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.width = 1920;
    config.height = 1080;
    config.minimumFrameInterval = CMTimeMake(1, 30);
    config.pixelFormat = 'BGRA';
    config.showsCursor = YES;
    config.showMouseClicks = YES;
    config.queueDepth = 8;
    config.scalesToFit = YES;
    config.preservesAspectRatio = YES;
    config.capturesAudio = NO;
    config.captureMicrophone = NO;
    config.captureDynamicRange = SCCaptureDynamicRangeSDR;

    self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];

    [[NSFileManager defaultManager] removeItemAtPath:kOutputPath error:nil];
    SCRecordingOutputConfiguration *recordingConfig = [[SCRecordingOutputConfiguration alloc] init];
    recordingConfig.outputURL = [NSURL fileURLWithPath:kOutputPath];
    recordingConfig.outputFileType = AVFileTypeMPEG4;
    recordingConfig.videoCodecType = AVVideoCodecTypeH264;
    self.recordingOutput = [[SCRecordingOutput alloc] initWithConfiguration:recordingConfig delegate:self];

    NSError *recordingError = nil;
    if (![self.stream addRecordingOutput:self.recordingOutput error:&recordingError]) {
      WriteStatus([NSString stringWithFormat:@"add-recording-error:%@", ErrorText(recordingError)]);
      [self finishApp];
      return;
    }

    [self.stream startCaptureWithCompletionHandler:^(NSError *_Nullable startError) {
      if (startError != nil) {
        WriteStatus([NSString stringWithFormat:@"start-capture-error:%@", ErrorText(startError)]);
        [self finishApp];
        return;
      }

      WriteStatus(@"recording");
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self stopRecording];
      });
    }];
  }];
}

- (void)stopRecording {
  if (self.finished) {
    return;
  }

  WriteStatus(@"stopping");
  NSError *removeError = nil;
  if (self.recordingOutput != nil && ![self.stream removeRecordingOutput:self.recordingOutput error:&removeError]) {
    WriteStatus([NSString stringWithFormat:@"remove-recording-error:%@", ErrorText(removeError)]);
  }

  [self.stream stopCaptureWithCompletionHandler:^(NSError *_Nullable stopError) {
    if (stopError != nil) {
      WriteStatus([NSString stringWithFormat:@"stop-capture-error:%@", ErrorText(stopError)]);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (!self.finished) {
        [self finishWithStatus];
      }
    });
  }];
}

- (void)finishWithStatus {
  if (self.finished) {
    return;
  }
  self.finished = YES;

  NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:kOutputPath error:nil];
  unsigned long long size = [attributes fileSize];
  if (size > 0) {
    WriteStatus([NSString stringWithFormat:@"finished:%llu:%@", size, kOutputPath]);
  } else {
    WriteStatus(@"finish-error:empty-output");
  }
  [self finishApp];
}

- (void)finishApp {
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSApp terminate:nil];
  });
}

- (void)recordingOutputDidStartRecording:(SCRecordingOutput *)recordingOutput {
  (void)recordingOutput;
  WriteStatus(@"recording-started");
}

- (void)recordingOutput:(SCRecordingOutput *)recordingOutput didFailWithError:(NSError *)error {
  (void)recordingOutput;
  if (!self.finished) {
    self.finished = YES;
    WriteStatus([NSString stringWithFormat:@"recording-failed:%@", ErrorText(error)]);
    [self finishApp];
  }
}

- (void)recordingOutputDidFinishRecording:(SCRecordingOutput *)recordingOutput {
  (void)recordingOutput;
  [self finishWithStatus];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  (void)stream;
  if (!self.finished && error != nil) {
    self.finished = YES;
    WriteStatus([NSString stringWithFormat:@"stream-stopped-error:%@", ErrorText(error)]);
    [self finishApp];
  }
}

@end

static InjectedRecorder *gRecorder = nil;

static void ReplacementDidFinishLaunching(id self, SEL _cmd, NSNotification *notification) {
  (void)self;
  (void)_cmd;
  (void)notification;
  gRecorder = [[InjectedRecorder alloc] init];
  [gRecorder start];
}

__attribute__((constructor))
static void InstallRecorder(void) {
  Class permissionDelegate = objc_getClass("PermissionDelegate");
  if (permissionDelegate == Nil) {
    WriteStatus(@"inject-error:no-permission-delegate-class");
    return;
  }

  SEL selector = @selector(applicationDidFinishLaunching:);
  Method method = class_getInstanceMethod(permissionDelegate, selector);
  if (method == NULL) {
    WriteStatus(@"inject-error:no-launch-method");
    return;
  }

  method_setImplementation(method, (IMP)ReplacementDidFinishLaunching);
}
