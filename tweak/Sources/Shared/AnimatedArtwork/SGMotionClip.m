#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import "Shared/AdBlock/Protobuf.h"
#import "SGMotionClip.h"

static NSString *const kCanvas = @"canvas";

CGSize SGMotionClipCut(CGSize shown, CGFloat ratio) {
    if (shown.width <= 0 || shown.height <= 0 || ratio <= 0) return CGSizeZero;
    CGSize cut = shown.width / shown.height > ratio ? CGSizeMake(shown.height * ratio, shown.height)
                                                    : CGSizeMake(shown.width, shown.width / ratio);
    return CGSizeMake(floor(cut.width / 2) * 2, floor(cut.height / 2) * 2);
}

BOOL SGMotionClipShape(NSURL *file, CGFloat ratio, NSURL *out) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:nil];
    __block AVAssetTrack *track = nil;
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
        track = tracks.firstObject;
        dispatch_semaphore_signal(loaded);
    }];
    dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
    if (!track) return NO;

    CGAffineTransform turn = track.preferredTransform;
    BOOL sideways = fabs(turn.b) > 0.5;
    CGSize stored = track.naturalSize, shown = sideways ? CGSizeMake(stored.height, stored.width) : stored;
    CGSize cut = SGMotionClipCut(shown, ratio);
    if (cut.width < 2 || cut.height < 2) return NO;

    // Upscale factor: boost low-res Canvas crops (e.g., 720x400) up to ~1440px wide for crisp iPad/iPhone Lock Screen display
    CGFloat maxDim = MAX(cut.width, cut.height);
    CGFloat upscale = maxDim < 1280.0 ? MIN(2.2, 1440.0 / maxDim) : 1.0;
    CGSize outShown = CGSizeMake(floor((cut.width * upscale) / 2) * 2, floor((cut.height * upscale) / 2) * 2);
    CGSize outEncoded = sideways ? CGSizeMake(outShown.height, outShown.width) : outShown;

    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    AVAssetReaderTrackOutput *frames = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    }];
    if (!reader || ![reader canAddOutput:frames]) return NO;
    [reader addOutput:frames];

    NSURL *partial = [out URLByAppendingPathExtension:@"partial"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];

    // High-bitrate H.264 encoding (3.3x higher than stock) to prevent re-compression blur
    NSInteger targetBitrate = MAX(6000000, (NSInteger)(outEncoded.width * outEncoded.height * 10));
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(outEncoded.width),
        AVVideoHeightKey: @(outEncoded.height),
        AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(targetBitrate),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        },
    }];
    input.transform = turn;

    NSDictionary *pbAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(outEncoded.width),
        (id)kCVPixelBufferHeightKey: @(outEncoded.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:pbAttrs];

    if (!writer || ![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![reader startReading] || ![writer startWriting]) {
        [reader cancelReading];
        return NO;
    }

    // Hardware-accelerated CoreImage pipeline: Denoise + Lanczos Upscale + Unsharp Mask
    CIContext *ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    CIFilter *denoise = [CIFilter filterWithName:@"CINoiseReduction"];
    [denoise setValue:@(0.02) forKey:@"inputNoiseLevel"];
    [denoise setValue:@(0.45) forKey:@"inputSharpness"];

    CIFilter *lanczos = [CIFilter filterWithName:@"CILanczosScaleTransform"];
    [lanczos setValue:@(upscale) forKey:kCIInputScaleKey];
    [lanczos setValue:@(1.0) forKey:kCIInputAspectRatioKey];

    CIFilter *sharpen = [CIFilter filterWithName:@"CIUnsharpMask"];
    [sharpen setValue:@(1.6) forKey:kCIInputRadiusKey];
    [sharpen setValue:@(0.55) forKey:kCIInputIntensityKey];

    CGSize rawCut = sideways ? CGSizeMake(cut.height, cut.width) : cut;
    CGRect cropRect = CGRectMake(floor((stored.width - rawCut.width) / 2.0),
                                 floor((stored.height - rawCut.height) / 2.0),
                                 rawCut.width,
                                 rawCut.height);

    BOOL ok = YES, started = NO;
    while (ok) {
        @autoreleasepool {
            CMSampleBufferRef sample = [frames copyNextSampleBuffer];
            if (!sample) break;
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
            if (!started) {
                [writer startSessionAtSourceTime:pts];
                started = YES;
            }

            CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sample);
            CIImage *img = [CIImage imageWithCVImageBuffer:imageBuffer];
            img = [img imageByCroppingToRect:cropRect];
            img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-cropRect.origin.x, -cropRect.origin.y)];

            // 1. Reduce compression block artifacts
            [denoise setValue:img forKey:kCIInputImageKey];
            img = denoise.outputImage ?: img;

            // 2. Super-resolution Lanczos upscale
            if (upscale > 1.01) {
                [lanczos setValue:img forKey:kCIInputImageKey];
                img = lanczos.outputImage ?: img;
            }

            // 3. Crisp edge sharpening
            [sharpen setValue:img forKey:kCIInputImageKey];
            img = sharpen.outputImage ?: img;

            CVPixelBufferRef outBuffer = NULL;
            if (adaptor.pixelBufferPool) {
                CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &outBuffer);
            }
            if (outBuffer) {
                [ciContext render:img toCVPixelBuffer:outBuffer bounds:CGRectMake(0, 0, outEncoded.width, outEncoded.height) colorSpace:CGColorSpaceCreateDeviceRGB()];
                while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) [NSThread sleepForTimeInterval:0.002];
                ok = writer.status == AVAssetWriterStatusWriting && [adaptor appendPixelBuffer:outBuffer withPresentationTime:pts];
                CVPixelBufferRelease(outBuffer);
            }
            CFRelease(sample);
        }
    }

    if (!ok || !started || reader.status != AVAssetReaderStatusCompleted) {
        [reader cancelReading];
        [writer cancelWriting];
        return NO;
    }
    [input markAsFinished];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) return NO;
    [NSFileManager.defaultManager removeItemAtURL:out error:nil];
    return [NSFileManager.defaultManager moveItemAtURL:partial toURL:out error:nil];
}

NSData *SGMotionCanvasAsk(NSString *uri) {
    if (!uri.length) return nil;
    return SGPBSerialize(@[SGPBBytes(1, SGPBSerialize(@[SGPBString(1, uri)]))]);
}

NSString *SGMotionCanvasInReply(NSData *reply) {
    for (SGPBField *field in SGPBParse(reply)) {
        if (field.number != 1 || field.wire != 2) continue;
        NSArray<SGPBField *> *canvas = SGPBParse(field.payload);
        SGPBField *type = SGPBFirst(canvas, 4);
        NSString *address = SGPBText(SGPBFirst(canvas, 2));
        if (type.wire == 0 && type.varint >= 1 && type.varint <= 3 && address.length) return address;
    }
    return nil;
}

BOOL SGMotionCanvasOutranks(NSArray<NSString *> *order, NSString *source) {
    NSUInteger canvas = [order indexOfObject:kCanvas];
    if (canvas == NSNotFound) return NO;
    if (!source) return YES;
    NSUInteger shown = [order indexOfObject:source];
    return shown != NSNotFound && shown > canvas;
}
