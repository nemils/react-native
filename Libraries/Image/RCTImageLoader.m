/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "RCTImageLoader.h"

#import <ImageIO/ImageIO.h>

#import <libkern/OSAtomic.h>

#import <objc/runtime.h>

#import "RCTConvert.h"
#import "RCTDefines.h"
#import "RCTImageCache.h"
#import "RCTImageUtils.h"
#import "RCTLog.h"
#import "RCTNetworking.h"
#import "RCTUtils.h"


@implementation UIImage (React)

- (CAKeyframeAnimation *)reactKeyframeAnimation
{
    return objc_getAssociatedObject(self, _cmd);
}

- (void)setReactKeyframeAnimation:(CAKeyframeAnimation *)reactKeyframeAnimation
{
    objc_setAssociatedObject(self, @selector(reactKeyframeAnimation), reactKeyframeAnimation, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

@end

@implementation RCTImageLoader
{
  NSArray<id<RCTImageURLLoader>> *_loaders;
  NSArray<id<RCTImageDataDecoder>> *_decoders;
  NSOperationQueue *_imageDecodeQueue;
  dispatch_queue_t _URLRequestQueue;
  id<RCTImageCache> _imageCache;
  NSMutableArray *_pendingTasks;
  NSInteger _activeTasks;
  NSMutableArray *_pendingDecodes;
  NSInteger _scheduledDecodes;
  NSUInteger _activeBytes;
}

@synthesize bridge = _bridge;

RCT_EXPORT_MODULE()

- (void)setUp
{
  // Set defaults
  _maxConcurrentLoadingTasks = _maxConcurrentLoadingTasks ?: 4;
  _maxConcurrentDecodingTasks = _maxConcurrentDecodingTasks ?: 2;
  _maxConcurrentDecodingBytes = _maxConcurrentDecodingBytes ?: 30 * 1024 * 1024; // 30MB

  _URLRequestQueue = dispatch_queue_create("com.facebook.react.ImageLoaderURLRequestQueue", DISPATCH_QUEUE_SERIAL);
}

- (float)handlerPriority
{
  return 1;
}

- (id<RCTImageCache>)imageCache
{
  if (!_imageCache) {
    //set up with default cache
    _imageCache = [RCTImageCache new];
  }
  return _imageCache;
}

- (void)setImageCache:(id<RCTImageCache>)cache
{
  if (_imageCache) {
    RCTLogWarn(@"RCTImageCache was already set and has now been overriden.");
  }
  _imageCache = cache;
}

- (id<RCTImageURLLoader>)imageURLLoaderForURL:(NSURL *)URL
{
    if (!_maxConcurrentLoadingTasks) {
        [self setUp];
    }
    
    if (!_loaders) {
        // Get loaders, sorted in reverse priority order (highest priority first)
        RCTAssert(_bridge, @"Bridge not set");
        _loaders = [[_bridge modulesConformingToProtocol:@protocol(RCTImageURLLoader)] sortedArrayUsingComparator:^NSComparisonResult(id<RCTImageURLLoader> a, id<RCTImageURLLoader> b) {
            float priorityA = [a respondsToSelector:@selector(loaderPriority)] ? [a loaderPriority] : 0;
            float priorityB = [b respondsToSelector:@selector(loaderPriority)] ? [b loaderPriority] : 0;
            if (priorityA > priorityB) {
                return NSOrderedAscending;
            } else if (priorityA < priorityB) {
                return NSOrderedDescending;
            } else {
                return NSOrderedSame;
            }
        }];
    }
    
    if (RCT_DEBUG) {
        // Check for handler conflicts
        float previousPriority = 0;
        id<RCTImageURLLoader> previousLoader = nil;
        for (id<RCTImageURLLoader> loader in _loaders) {
            float priority = [loader respondsToSelector:@selector(loaderPriority)] ? [loader loaderPriority] : 0;
            if (previousLoader && priority < previousPriority) {
                return previousLoader;
            }
            if ([loader canLoadImageURL:URL]) {
                if (previousLoader) {
                    if (priority == previousPriority) {
                        RCTLogError(@"The RCTImageURLLoaders %@ and %@ both reported that"
                                    " they can load the URL %@, and have equal priority"
                                    " (%g). This could result in non-deterministic behavior.",
                                    loader, previousLoader, URL, priority);
                    }
                } else {
                    previousLoader = loader;
                    previousPriority = priority;
                }
            }
        }
        return previousLoader;
    }
    
    // Normal code path
    for (id<RCTImageURLLoader> loader in _loaders) {
        if ([loader canLoadImageURL:URL]) {
            return loader;
        }
    }
    return nil;
}

- (id<RCTImageDataDecoder>)imageDataDecoderForData:(NSData *)data
{
    if (!_maxConcurrentLoadingTasks) {
        [self setUp];
    }
    
    if (!_decoders) {
        // Get decoders, sorted in reverse priority order (highest priority first)
        RCTAssert(_bridge, @"Bridge not set");
        _decoders = [[_bridge modulesConformingToProtocol:@protocol(RCTImageDataDecoder)] sortedArrayUsingComparator:^NSComparisonResult(id<RCTImageDataDecoder> a, id<RCTImageDataDecoder> b) {
            float priorityA = [a respondsToSelector:@selector(decoderPriority)] ? [a decoderPriority] : 0;
            float priorityB = [b respondsToSelector:@selector(decoderPriority)] ? [b decoderPriority] : 0;
            if (priorityA > priorityB) {
                return NSOrderedAscending;
            } else if (priorityA < priorityB) {
                return NSOrderedDescending;
            } else {
                return NSOrderedSame;
            }
        }];
    }
    
    if (RCT_DEBUG) {
        // Check for handler conflicts
        float previousPriority = 0;
        id<RCTImageDataDecoder> previousDecoder = nil;
        for (id<RCTImageDataDecoder> decoder in _decoders) {
            float priority = [decoder respondsToSelector:@selector(decoderPriority)] ? [decoder decoderPriority] : 0;
            if (previousDecoder && priority < previousPriority) {
                return previousDecoder;
            }
            if ([decoder canDecodeImageData:data]) {
                if (previousDecoder) {
                    if (priority == previousPriority) {
                        RCTLogError(@"The RCTImageDataDecoders %@ and %@ both reported that"
                                    " they can decode the data <NSData %p; %tu bytes>, and"
                                    " have equal priority (%g). This could result in"
                                    " non-deterministic behavior.",
                                    decoder, previousDecoder, data, data.length, priority);
                    }
                } else {
                    previousDecoder = decoder;
                    previousPriority = priority;
                }
            }
        }
        return previousDecoder;
    }
    
    // Normal code path
    for (id<RCTImageDataDecoder> decoder in _decoders) {
        if ([decoder canDecodeImageData:data]) {
            return decoder;
        }
    }
    return nil;
}

static UIImage *RCTResizeImageIfNeeded(UIImage *image,
                                       CGSize size,
                                       CGFloat scale,
                                       RCTResizeMode resizeMode)
{
    if (CGSizeEqualToSize(size, CGSizeZero) ||
        CGSizeEqualToSize(image.size, CGSizeZero) ||
        CGSizeEqualToSize(image.size, size)) {
        return image;
    }
    CAKeyframeAnimation *animation = image.reactKeyframeAnimation;
    CGRect targetSize = RCTTargetRect(image.size, size, scale, resizeMode);
    CGAffineTransform transform = RCTTransformFromTargetRect(image.size, targetSize);
    image = RCTTransformImage(image, size, scale, transform);
    image.reactKeyframeAnimation = animation;
    return image;
}

- (RCTImageLoaderCancellationBlock)loadImageWithURLRequest:(NSURLRequest *)imageURLRequest
                                                  callback:(RCTImageLoaderCompletionBlock)callback
{
    return [self loadImageWithURLRequest:imageURLRequest
                                    size:CGSizeZero
                                   scale:1
                                 clipped:YES
                              resizeMode:RCTResizeModeStretch
                           progressBlock:nil
                         completionBlock:callback];
}

- (void)dequeueTasks
{
  __weak RCTImageLoader *weakSelf = self;
  dispatch_async(_URLRequestQueue, ^{
    __strong RCTImageLoader *strongSelf = weakSelf;
    if (!strongSelf || !strongSelf->_pendingTasks) {
      return;
    }
    // Remove completed tasks
    for (RCTNetworkTask *task in strongSelf->_pendingTasks.reverseObjectEnumerator) {
      switch (task.status) {
        case RCTNetworkTaskFinished:
          [strongSelf->_pendingTasks removeObject:task];
          strongSelf->_activeTasks--;
          break;
        case RCTNetworkTaskPending:
          break;
        case RCTNetworkTaskInProgress:
          // Check task isn't "stuck"
          if (task.requestToken == nil) {
            RCTLogWarn(@"Task orphaned for request %@", task.request);
            [strongSelf->_pendingTasks removeObject:task];
            strongSelf->_activeTasks--;
            [task cancel];
          }
          break;
      }
    }

    // Start queued decode
    NSInteger activeDecodes = strongSelf->_scheduledDecodes - strongSelf->_pendingDecodes.count;
    while (activeDecodes == 0 || (strongSelf->_activeBytes <= strongSelf->_maxConcurrentDecodingBytes &&
                                  activeDecodes <= strongSelf->_maxConcurrentDecodingTasks)) {
      dispatch_block_t decodeBlock = strongSelf->_pendingDecodes.firstObject;
      if (decodeBlock) {
        [strongSelf->_pendingDecodes removeObjectAtIndex:0];
        decodeBlock();
      } else {
        break;
      }
    }

    // Start queued tasks
    for (RCTNetworkTask *task in strongSelf->_pendingTasks) {
      if (MAX(strongSelf->_activeTasks, strongSelf->_scheduledDecodes) >= strongSelf->_maxConcurrentLoadingTasks) {
        break;
      }
      if (task.status == RCTNetworkTaskPending) {
        [task start];
        strongSelf->_activeTasks++;
      }
    }
  });
}

/**
 * This returns either an image, or raw image data, depending on the loading
 * path taken. This is useful if you want to skip decoding, e.g. when preloading
 * the image, or retrieving metadata.
 */
- (RCTImageLoaderCancellationBlock)_loadImageOrDataWithURLRequest:(NSURLRequest *)request
                                                             size:(CGSize)size
                                                            scale:(CGFloat)scale
                                                       resizeMode:(RCTResizeMode)resizeMode
                                                    progressBlock:(RCTImageLoaderProgressBlock)progressHandler
                                                  completionBlock:(void (^)(NSError *error, id imageOrData, BOOL cacheResult, NSString *fetchDate))completionBlock
{
  {
    NSMutableURLRequest *mutableRequest = [request mutableCopy];
    [NSURLProtocol setProperty:@"RCTImageLoader"
                        forKey:@"trackingName"
                     inRequest:mutableRequest];

    // Add missing png extension
    if (request.URL.fileURL && request.URL.pathExtension.length == 0) {
      mutableRequest.URL = [NSURL fileURLWithPath:[request.URL.path stringByAppendingPathExtension:@"png"]];
    }
    request = mutableRequest;
  }

  // Find suitable image URL loader
  id<RCTImageURLLoader> loadHandler = [self imageURLLoaderForURL:request.URL];
  BOOL requiresScheduling = [loadHandler respondsToSelector:@selector(requiresScheduling)] ?
      [loadHandler requiresScheduling] : YES;

  __block volatile uint32_t cancelled = 0;
  __block dispatch_block_t cancelLoad = nil;
  void (^completionHandler)(NSError *, id, NSString *) = ^(NSError *error, id imageOrData, NSString *fetchDate) {
    cancelLoad = nil;

    BOOL cacheResult = [loadHandler respondsToSelector:@selector(shouldCacheLoadedImages)] ?
      [loadHandler shouldCacheLoadedImages] : YES;

    // If we've received an image, we should try to set it synchronously,
    // if it's data, do decoding on a background thread.
    if (RCTIsMainQueue() && ![imageOrData isKindOfClass:[UIImage class]]) {
      // Most loaders do not return on the main thread, so caller is probably not
      // expecting it, and may do expensive post-processing in the callback
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (!cancelled) {
          if (completionBlock) {
            completionBlock(error, imageOrData, cacheResult, fetchDate);
          }
        }
      });
    } else if (!cancelled) {
      if (completionBlock) {
        completionBlock(error, imageOrData, cacheResult, fetchDate);
      }
    }
  };

  // If the loader doesn't require scheduling we call it directly on
  // the main queue.
  if (loadHandler && !requiresScheduling) {
    return [loadHandler loadImageForURL:request.URL
                                   size:size
                                  scale:scale
                             resizeMode:resizeMode
                        progressHandler:progressHandler
                      completionHandler:^(NSError *error, UIImage *image){
                        if (completionHandler) {
                          completionHandler(error, image, nil);
                        }
                      }];
  }

  // All access to URL cache must be serialized
  if (!_URLRequestQueue) {
    [self setUp];
  }

  __weak RCTImageLoader *weakSelf = self;
  dispatch_async(_URLRequestQueue, ^{
    __strong RCTImageLoader *strongSelf = weakSelf;
    if (cancelled || !strongSelf) {
      return;
    }

    if (loadHandler) {
      cancelLoad = [loadHandler loadImageForURL:request.URL
                                           size:size
                                          scale:scale
                                     resizeMode:resizeMode
                                progressHandler:progressHandler
                              completionHandler:^(NSError *error, UIImage *image) {
                                if (completionHandler) {
                                  completionHandler(error, image, nil);
                                }
                              }];
    } else {
      // Use networking module to load image
      cancelLoad = [strongSelf _loadURLRequest:request
                                 progressBlock:progressHandler
                               completionBlock:completionHandler];
    }
  });

  return ^{
    if (cancelLoad) {
      cancelLoad();
      cancelLoad = nil;
    }
    OSAtomicOr32Barrier(1, &cancelled);
  };
}

- (RCTImageLoaderCancellationBlock)_loadURLRequest:(NSURLRequest *)request
                                     progressBlock:(RCTImageLoaderProgressBlock)progressHandler
                                   completionBlock:(void (^)(NSError *error, id imageOrData, NSString *fetchDate))completionHandler
{
  // Check if networking module is available
  if (RCT_DEBUG && ![_bridge respondsToSelector:@selector(networking)]) {
    RCTLogError(@"No suitable image URL loader found for %@. You may need to "
                " import the RCTNetwork library in order to load images.",
                request.URL.absoluteString);
    return NULL;
  }

  RCTNetworking *networking = [_bridge networking];

  // Check if networking module can load image
  if (RCT_DEBUG && ![networking canHandleRequest:request]) {
    RCTLogError(@"No suitable image URL loader found for %@", request.URL.absoluteString);
    return NULL;
  }

  // Use networking module to load image
  RCTURLRequestCompletionBlock processResponse = ^(NSURLResponse *response, NSData *data, NSError *error) {
    // Check for system errors
    if (!completionHandler) {
      return;
    } else if (error) {
      completionHandler(error, nil, nil);
      return;
    } else if (!response) {
      completionHandler(RCTErrorWithMessage(@"Response metadata error"), nil, nil);
      return;
    } else if (!data) {
      completionHandler(RCTErrorWithMessage(@"Unknown image download error"), nil, nil);
      return;
    }

    // Check for http errors
    NSString *responseDate;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
      NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
      if (statusCode != 200) {
        completionHandler([[NSError alloc] initWithDomain:NSURLErrorDomain
                                                     code:statusCode
                                                 userInfo:nil], nil, nil);
        return;
      }

      responseDate = ((NSHTTPURLResponse *)response).allHeaderFields[@"Date"];
    }

    // Call handler
    completionHandler(nil, data, responseDate);
  };

  // Download image
  __weak __typeof(self) weakSelf = self;
  RCTNetworkTask *task = [networking networkTaskWithRequest:request completionBlock:^(NSURLResponse *response, NSData *data, NSError *error) {
    __strong RCTImageLoader *strongSelf = weakSelf;
    if (!strongSelf || !completionHandler) {
      return;
    }

    if (error || !response || !data) {
      NSError *someError = nil;
      if (error) {
        someError = error;
      } else if (!response) {
        someError = RCTErrorWithMessage(@"Response metadata error");
      } else {
        someError = RCTErrorWithMessage(@"Unknown image download error");
      }
      completionHandler(someError, nil, nil);
      [strongSelf dequeueTasks];
      return;
    }

    dispatch_async(strongSelf->_URLRequestQueue, ^{
      // Process image data
      processResponse(response, data, nil);

      // Prepare for next task
      [strongSelf dequeueTasks];
    });
  }];

  task.downloadProgressBlock = progressHandler;

  if (task) {
    if (!_pendingTasks) {
      _pendingTasks = [NSMutableArray new];
    }
    [_pendingTasks addObject:task];
    [self dequeueTasks];
  }

  return ^{
    if (task) {
      [task cancel];
    }
    if (weakSelf) {
      [weakSelf dequeueTasks];
    }
  };
}

- (RCTImageLoaderCancellationBlock)loadImageWithURLRequest:(NSURLRequest *)imageURLRequest
                                                      size:(CGSize)size
                                                     scale:(CGFloat)scale
                                                   clipped:(BOOL)clipped
                                                resizeMode:(RCTResizeMode)resizeMode
                                             progressBlock:(RCTImageLoaderProgressBlock)progressBlock
                                           completionBlock:(RCTImageLoaderCompletionBlock)completionBlock
{
<<<<<<< HEAD
  __block volatile uint32_t cancelled = 0;
  __block dispatch_block_t cancelLoad = nil;
  dispatch_block_t cancellationBlock = ^{
    if (cancelLoad) {
      cancelLoad();
    }
    OSAtomicOr32Barrier(1, &cancelled);
  };

  __weak RCTImageLoader *weakSelf = self;
  void (^completionHandler)(NSError *, id, BOOL, NSString *) = ^(NSError *error, id imageOrData, BOOL cacheResult, NSString *fetchDate) {
    __strong RCTImageLoader *strongSelf = weakSelf;
    if (cancelled || !strongSelf) {
      return;
    }

    if (!imageOrData || [imageOrData isKindOfClass:[UIImage class]]) {
      cancelLoad = nil;
      if (completionBlock) {
        completionBlock(error, imageOrData);
      }
      return;
    }

    // Check decoded image cache
    if (cacheResult) {
      UIImage *image = [[strongSelf imageCache] imageForUrl:imageURLRequest.URL.absoluteString
                                                       size:size
                                                      scale:scale
                                                 resizeMode:resizeMode
                                               responseDate:fetchDate];
      if (image) {
        cancelLoad = nil;
        if (completionBlock) {
          completionBlock(nil, imageOrData);
        }
        return;
      }
    }

    __weak RCTImageLoader *innerWeakSelf = strongSelf;
    RCTImageLoaderCompletionBlock decodeCompletionHandler = ^(NSError *error_, UIImage *image) {
      __strong RCTImageLoader *innerStrongSelf = innerWeakSelf;
      if (!innerStrongSelf) {
        return;
      }
      if (cacheResult && image) {
        // Store decoded image in cache
        [[innerStrongSelf imageCache] addImageToCache:image
                                             URL:imageURLRequest.URL.absoluteString
                                            size:size
                                           scale:scale
                                      resizeMode:resizeMode
                                    responseDate:fetchDate];
      }

      cancelLoad = nil;
      completionBlock(error_, image);
    };

    cancelLoad = [weakSelf decodeImageData:imageOrData
                                      size:size
                                     scale:scale
                                   clipped:clipped
                                resizeMode:resizeMode
                           completionBlock:decodeCompletionHandler];
  };

  cancelLoad = [self _loadImageOrDataWithURLRequest:imageURLRequest
                                               size:size
                                              scale:scale
                                         resizeMode:resizeMode
                                      progressBlock:progressBlock
                                    completionBlock:completionHandler];
  return cancellationBlock;
}

- (RCTImageLoaderCancellationBlock)decodeImageData:(NSData *)data
                                              size:(CGSize)size
                                             scale:(CGFloat)scale
                                           clipped:(BOOL)clipped
                                        resizeMode:(RCTResizeMode)resizeMode
                                   completionBlock:(RCTImageLoaderCompletionBlock)completionBlock
{
    if (data.length == 0) {
        if (completionBlock) {
          completionBlock(RCTErrorWithMessage(@"No image data"), nil);
        }
        return ^{};
    }

  id<RCTImageDataDecoder> imageDecoder = [self imageDataDecoderForData:data];
  if (imageDecoder) {
    return [imageDecoder decodeImageData:data
                                    size:size
                                   scale:scale
                              resizeMode:resizeMode
                       completionHandler:completionHandler] ?: ^{};
  } else {
    __weak RCTImageLoader *weakSelf = self;
    dispatch_block_t decodeBlock = ^{
      __strong RCTImageLoader *strongSelf = weakSelf;
      if (!strongSelf) {
        return;
      }
      // Calculate the size, in bytes, that the decompressed image will require
      NSInteger decodedImageBytes = (size.width * scale) * (size.height * scale) * 4;

      // Mark these bytes as in-use
      strongSelf->_activeBytes += decodedImageBytes;

      // Do actual decompression on a concurrent background queue
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (!cancelled) {

          // Decompress the image data (this may be CPU and memory intensive)
          UIImage *image = RCTDecodeImageWithData(data, size, scale, resizeMode);

#if RCT_DEV
          CGSize imagePixelSize = RCTSizeInPixels(image.size, image.scale);
          CGSize screenPixelSize = RCTSizeInPixels(RCTScreenSize(), RCTScreenScale());
          if (imagePixelSize.width * imagePixelSize.height >
              screenPixelSize.width * screenPixelSize.height) {
            RCTLogInfo(@"[PERF ASSETS] Loading image at size %@, which is larger "
                       "than the screen size %@", NSStringFromCGSize(imagePixelSize),
                       NSStringFromCGSize(screenPixelSize));
          }
#endif

          if (image) {
            completionHandler(nil, image);
          } else {
            NSString *errorMessage = [NSString stringWithFormat:@"Error decoding image data <NSData %p; %tu bytes>", data, data.length];
            NSError *finalError = RCTErrorWithMessage(errorMessage);
            completionHandler(finalError, nil);
          }
        }

        // We're no longer retaining the uncompressed data, so now we'll mark
        // the decoding as complete so that the loading task queue can resume.
        __strong RCTImageLoader *innerStrongSelf = weakSelf;
        if (innerStrongSelf) {
          dispatch_async(innerStrongSelf->_URLRequestQueue, ^{
            innerStrongSelf->_scheduledDecodes--;
            innerStrongSelf->_activeBytes -= decodedImageBytes;
            [innerStrongSelf dequeueTasks];
          });
        }
      });
    };

    if (!_URLRequestQueue) {
      [self setUp];
    }
    dispatch_async(_URLRequestQueue, ^{
      __strong RCTImageLoader *strongSelf = weakSelf;
      if (!strongSelf) {
        return;
      }

      // The decode operation retains the compressed image data until it's
      // complete, so we'll mark it as having started, in order to block
      // further image loads from happening until we're done with the data.
      strongSelf->_scheduledDecodes++;

      if (!strongSelf->_pendingDecodes) {
        strongSelf->_pendingDecodes = [NSMutableArray new];
      }
      NSInteger activeDecodes = strongSelf->_scheduledDecodes - strongSelf->_pendingDecodes.count - 1;
      if (activeDecodes == 0 || (strongSelf->_activeBytes <= strongSelf->_maxConcurrentDecodingBytes &&
                                 activeDecodes <= strongSelf->_maxConcurrentDecodingTasks)) {
        decodeBlock();
      } else {
        [strongSelf->_pendingDecodes addObject:decodeBlock];
      }
    });

    return ^{
      OSAtomicOr32Barrier(1, &cancelled);
    };
  }
}

- (RCTImageLoaderCancellationBlock)getImageSizeForURLRequest:(NSURLRequest *)imageURLRequest
                                                       block:(void(^)(NSError *error, CGSize size))callback
{
  void (^completion)(NSError *, id, BOOL, NSString *) = ^(NSError *error, id imageOrData, BOOL cacheResult, NSString *fetchDate) {
    CGSize size;
    if ([imageOrData isKindOfClass:[NSData class]]) {
      NSDictionary *meta = RCTGetImageMetadata(imageOrData);
      size = (CGSize){
        [meta[(id)kCGImagePropertyPixelWidth] doubleValue],
        [meta[(id)kCGImagePropertyPixelHeight] doubleValue],
      };
    } else {
      UIImage *image = imageOrData;
      size = (CGSize){
        image.size.width * image.scale,
        image.size.height * image.scale,
      };
    }
    if (callback) {
      callback(error, size);
    }
  };

  return [self _loadImageOrDataWithURLRequest:imageURLRequest
                                         size:CGSizeZero
                                        scale:1
                                   resizeMode:RCTResizeModeStretch
                                progressBlock:NULL
                              completionBlock:completion];
}

#pragma mark - RCTURLRequestHandler

- (BOOL)canHandleRequest:(NSURLRequest *)request
{
    NSURL *requestURL = request.URL;
    for (id<RCTImageURLLoader> loader in _loaders) {
        // Don't use RCTImageURLLoader protocol for modules that already conform to
        // RCTURLRequestHandler as it's inefficient to decode an image and then
        // convert it back into data
        if (![loader conformsToProtocol:@protocol(RCTURLRequestHandler)] &&
            [loader canLoadImageURL:requestURL]) {
            return YES;
        }
    }
    return NO;
}

- (id)sendRequest:(NSURLRequest *)request withDelegate:(id<RCTURLRequestDelegate>)delegate
{
    __block RCTImageLoaderCancellationBlock requestToken;
    requestToken = [self loadImageWithURLRequest:request callback:^(NSError *error, UIImage *image) {
        if (error) {
          if (delegate) {
            [delegate URLRequest:requestToken didCompleteWithError:error];
          }
            return;
        }
        
        NSString *mimeType = nil;
        NSData *imageData = nil;
        if (RCTImageHasAlpha(image.CGImage)) {
            mimeType = @"image/png";
            imageData = UIImagePNGRepresentation(image);
        } else {
            mimeType = @"image/jpeg";
            imageData = UIImageJPEGRepresentation(image, 1.0);
        }
        
        NSURLResponse *response = [[NSURLResponse alloc] initWithURL:request.URL
                                                            MIMEType:mimeType
                                               expectedContentLength:imageData.length
                                                    textEncodingName:nil];
      if (delegate) {
        [delegate URLRequest:requestToken didReceiveResponse:response];
        [delegate URLRequest:requestToken didReceiveData:imageData];
        [delegate URLRequest:requestToken didCompleteWithError:nil];
      }
    }];
    
    return requestToken;
}

- (void)cancelRequest:(id)requestToken
{
    if (requestToken) {
        ((RCTImageLoaderCancellationBlock)requestToken)();
    }
}

@end


@implementation RCTBridge (RCTImageLoader)

- (RCTImageLoader *)imageLoader
{
    return [self moduleForClass:[RCTImageLoader class]];
}

@end
