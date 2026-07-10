#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

static NSString *const kOutputPath = @"/Users/cno/Documents/Codex/2026-06-16/create-a-new-project-built-a/dist/video/loci-demo-app-capture.mp4";
static NSString *const kStatusPath = @"/private/tmp/loci-real-capture-status.txt";

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

static CGRect AspectFitRect(CGSize sourceSize, CGSize outputSize) {
  CGFloat sourceAspect = sourceSize.width / sourceSize.height;
  CGFloat outputAspect = outputSize.width / outputSize.height;
  CGFloat width = outputSize.width;
  CGFloat height = outputSize.height;

  if (sourceAspect > outputAspect) {
    height = width / sourceAspect;
  } else {
    width = height * sourceAspect;
  }

  return CGRectMake((outputSize.width - width) * 0.5,
                    (outputSize.height - height) * 0.5,
                    width,
                    height);
}

static NSWindow *BestVisibleWindow(void) {
  NSWindow *keyWindow = NSApp.keyWindow;
  if (keyWindow.visible && keyWindow.contentView != nil) {
    return keyWindow;
  }

  NSWindow *bestWindow = nil;
  CGFloat bestArea = 0;
  for (NSWindow *window in NSApp.windows) {
    if (!window.visible || window.contentView == nil) {
      continue;
    }
    NSRect frame = window.frame;
    CGFloat area = frame.size.width * frame.size.height;
    if (area > bestArea && frame.size.width > 200 && frame.size.height > 200) {
      bestWindow = window;
      bestArea = area;
    }
  }
  return bestWindow;
}

static CGImageRef CaptureWindowContent(void) {
  __block CGImageRef capturedImage = NULL;

  dispatch_sync(dispatch_get_main_queue(), ^{
    NSWindow *window = BestVisibleWindow();
    NSView *view = window.contentView;
    if (view == nil) {
      return;
    }

    [window makeKeyAndOrderFront:nil];
    [view displayIfNeeded];

    NSRect bounds = view.bounds;
    if (bounds.size.width <= 1 || bounds.size.height <= 1) {
      return;
    }

    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:bounds];
    if (rep == nil) {
      return;
    }
    rep.size = bounds.size;
    [view cacheDisplayInRect:bounds toBitmapImageRep:rep];

    CGImageRef image = rep.CGImage;
    if (image != NULL) {
      capturedImage = CGImageRetain(image);
    }
  });

  return capturedImage;
}

static BOOL AppendFrame(AVAssetWriterInputPixelBufferAdaptor *adaptor,
                        CGImageRef image,
                        CGSize outputSize,
                        CMTime time) {
  CVPixelBufferRef buffer = NULL;
  NSDictionary *attributes = @{
    (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
    (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
  };

  CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                        (size_t)outputSize.width,
                                        (size_t)outputSize.height,
                                        kCVPixelFormatType_32BGRA,
                                        (__bridge CFDictionaryRef)attributes,
                                        &buffer);
  if (result != kCVReturnSuccess || buffer == NULL) {
    return NO;
  }

  CVPixelBufferLockBaseAddress(buffer, 0);
  void *data = CVPixelBufferGetBaseAddress(buffer);
  size_t bytesPerRow = CVPixelBufferGetBytesPerRow(buffer);
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(data,
                                               (size_t)outputSize.width,
                                               (size_t)outputSize.height,
                                               8,
                                               bytesPerRow,
                                               colorSpace,
                                               kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
  if (context == NULL) {
    CGColorSpaceRelease(colorSpace);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    CVPixelBufferRelease(buffer);
    return NO;
  }

  CGContextSetFillColorWithColor(context, NSColor.blackColor.CGColor);
  CGContextFillRect(context, CGRectMake(0, 0, outputSize.width, outputSize.height));

  CGSize sourceSize = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));
  CGRect drawRect = AspectFitRect(sourceSize, outputSize);
  CGContextDrawImage(context, drawRect, image);

  BOOL appended = [adaptor appendPixelBuffer:buffer withPresentationTime:time];
  CGContextRelease(context);
  CGColorSpaceRelease(colorSpace);
  CVPixelBufferUnlockBaseAddress(buffer, 0);
  CVPixelBufferRelease(buffer);
  return appended;
}

static NSString *DemoStepForFrame(int frame) {
  switch (frame) {
    case 4:
      return @"reset";
    case 32:
      return @"select";
    case 58:
      return @"focus";
    case 106:
      return @"close";
    case 128:
      return @"canvas";
    case 198:
      return @"infinity";
    case 270:
      return @"xsearch";
    default:
      return nil;
  }
}

static void PostDemoStep(NSString *step) {
  dispatch_sync(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LociDemoStep"
                                                        object:nil
                                                      userInfo:@{@"step": step}];
  });
  [NSThread sleepForTimeInterval:0.35];
}

@interface LociSelfRecorder : NSObject
@end

@implementation LociSelfRecorder

- (void)start {
  WriteStatus(@"loci-window-recorder-starting");
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      [self recordWindow];
    }
  });
}

- (void)recordWindow {
  [NSThread sleepForTimeInterval:1.0];

  CGSize outputSize = CGSizeMake(1920, 1080);
  [[NSFileManager defaultManager] removeItemAtPath:kOutputPath error:nil];
  NSURL *outputURL = [NSURL fileURLWithPath:kOutputPath];
  NSError *writerError = nil;
  AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:outputURL
                                                    fileType:AVFileTypeMPEG4
                                                       error:&writerError];
  if (writer == nil || writerError != nil) {
    WriteStatus([NSString stringWithFormat:@"writer-error:%@", ErrorText(writerError)]);
    [self finishApp];
    return;
  }

  NSDictionary *settings = @{
    AVVideoCodecKey: AVVideoCodecTypeH264,
    AVVideoWidthKey: @(outputSize.width),
    AVVideoHeightKey: @(outputSize.height),
    AVVideoCompressionPropertiesKey: @{
      AVVideoAverageBitRateKey: @(10000000),
      AVVideoExpectedSourceFrameRateKey: @(24),
      AVVideoMaxKeyFrameIntervalKey: @(24)
    }
  };
  AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                 outputSettings:settings];
  input.expectsMediaDataInRealTime = NO;

  NSDictionary *bufferAttributes = @{
    (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    (NSString *)kCVPixelBufferWidthKey: @(outputSize.width),
    (NSString *)kCVPixelBufferHeightKey: @(outputSize.height)
  };
  AVAssetWriterInputPixelBufferAdaptor *adaptor =
      [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                                                         sourcePixelBufferAttributes:bufferAttributes];

  if (![writer canAddInput:input]) {
    WriteStatus(@"writer-cannot-add-input");
    [self finishApp];
    return;
  }
  [writer addInput:input];

  if (![writer startWriting]) {
    WriteStatus([NSString stringWithFormat:@"start-writing-error:%@", ErrorText(writer.error)]);
    [self finishApp];
    return;
  }

  [writer startSessionAtSourceTime:kCMTimeZero];

  int fps = 24;
  int seconds = 14;
  NSString *secondsOverride = NSProcessInfo.processInfo.environment[@"LOCI_DEMO_SECONDS"];
  if (secondsOverride.length > 0 && secondsOverride.intValue > 0) {
    seconds = secondsOverride.intValue;
  }
  int totalFrames = fps * seconds;
  int written = 0;
  NSString *captureFailure = nil;
  CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();

  for (int frame = 0; frame < totalFrames; frame++) {
    @autoreleasepool {
      while (!input.readyForMoreMediaData) {
        [NSThread sleepForTimeInterval:0.002];
      }

      NSString *demoStep = DemoStepForFrame(frame);
      if (demoStep != nil) {
        PostDemoStep(demoStep);
      }

      CGImageRef image = CaptureWindowContent();
      if (image == NULL) {
        captureFailure = [NSString stringWithFormat:@"capture-window-error:%d:no-window-image", frame];
        WriteStatus(captureFailure);
        break;
      }

      if (AppendFrame(adaptor, image, outputSize, CMTimeMake(frame, fps))) {
        written++;
      }
      CGImageRelease(image);

      if (frame % fps == 0) {
        WriteStatus([NSString stringWithFormat:@"recording:%d/%d", frame / fps, seconds]);
      }

      CFAbsoluteTime targetTime = startTime + ((double)(frame + 1) / (double)fps);
      CFAbsoluteTime sleepTime = targetTime - CFAbsoluteTimeGetCurrent();
      if (sleepTime > 0) {
        [NSThread sleepForTimeInterval:sleepTime];
      }
    }
  }

  [input markAsFinished];
  dispatch_semaphore_t finishSemaphore = dispatch_semaphore_create(0);
  [writer finishWritingWithCompletionHandler:^{
    dispatch_semaphore_signal(finishSemaphore);
  }];
  dispatch_semaphore_wait(finishSemaphore, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));

  if (writer.status != AVAssetWriterStatusCompleted) {
    WriteStatus([NSString stringWithFormat:@"finish-error:%@", ErrorText(writer.error)]);
    [self finishApp];
    return;
  }

  NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:kOutputPath error:nil];
  unsigned long long size = [attributes fileSize];
  if (written == 0 || size == 0) {
    WriteStatus(captureFailure ?: @"finish-error:no-frames-written");
    [self finishApp];
    return;
  }

  WriteStatus([NSString stringWithFormat:@"finished:%d:%llu:%@", written, size, kOutputPath]);
  [self finishApp];
}

- (void)finishApp {
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSApp terminate:nil];
  });
}

@end

static LociSelfRecorder *gRecorder = nil;

__attribute__((constructor))
static void InstallLociSelfRecorder(void) {
  WriteStatus(@"loci-window-recorder-injected");
  [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                    object:nil
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(__unused NSNotification *notification) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      gRecorder = [[LociSelfRecorder alloc] init];
      [gRecorder start];
    });
  }];
}
