#import <Cocoa/Cocoa.h>

#import "CGFrameBuffer.h"

#import "AVMvidFileWriter.h"

#import "AVMvidFrameDecoder.h"

#include "maxvid_encode.h"

CGSize _movieDimensions;

NSString *movie_prefix;

CGFrameBuffer *prevFrameBuffer = nil;

#define EMIT_DELTA

#ifdef EMIT_DELTA
NSString *delta_directory = nil;
#endif

static
BOOL write_delta_pixels_as_delta_frame(AVMvidFileWriter *mvidWriter,
                                       NSArray *deltaPixels,
                                       NSUInteger frameBufferNumPixels,
                                       uint32_t adler);

static
void process_pixel_run(NSMutableData *mvidWordCodes,
                       NSMutableArray *mPixelRun,
                       int prevPixelOffset,
                       int nextPixelOffset);

// ------------------------------------------------------------------------
//
// mvidmoviemaker
// 
// To create a .mvid video file from a series of PNG images
// with a 15 FPS framerate and 32BPP "Millions+" (24 BPP plus alpha channel)
//
// mvidmoviemaker movie.mvid FRAMES/Frame001.png 15 32
//
// To extract the contents of an .mvid movie to PNG images:
//
// mvidmoviemaker -extract out.mvid ?FILEPREFIX?"
//
// The optional FILEPREFIX should be specified as "DumpFile" to get
// frames files named "DumpFile0001.png" and "DumpFile0002.png" and so on.
// ------------------------------------------------------------------------

#define USAGE \
"usage: mvidmoviemaker FILE.mvid FIRSTFRAME.png FRAMERATE BITSPERPIXEL ?KEYFRAME?" "\n" \
"or   : mvidmoviemaker -extract FILE.mvid ?FILEPREFIX?" "\n"


// This method is invoked with a path that contains the frame
// data and the offset into the frame array that this specific
// frame data is found at.
//
// filenameStr : Name of .png file that contains the frame data
// frameIndex  : Frame index (starts at zero)
// bppNum      : 16, 24, or 32 BPP
// isKeyframe  : TRUE if this specific frame should be stored as a keyframe (as opposed to a delta frame)

int process_frame_file(AVMvidFileWriter *mvidWriter, NSString *filenameStr, int frameIndex, int bppNum, BOOL isKeyframe) {
	// Push pool after creating global resources

  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	//BOOL success;
  
  if (FALSE) {
    filenameStr = @"TestOpaque.png";
  }

  if (FALSE) {
    filenameStr = @"TestAlpha.png";
  }
  
	NSData *image_data = [NSData dataWithContentsOfFile:filenameStr];
	if (image_data == nil) {
		fprintf(stderr, "can't read image data from file \"%s\"\n", [filenameStr UTF8String]);
		exit(1);
	}

	// Create image object from src image data. If the image is the
	// exact size of the iPhone display in portrait mode (320x480) then
	// render into a view of that exact size. If the image is the
	// exact size of landscape mode (480x320) then render with a
	// 90 degree clockwise rotation so that the rendered result
	// can be displayed with no transformation applied to the
	// UIView. If the image dimensions are smaller than the
	// width and height in portrait mode, render at the exact size
	// of the image. Otherwise, the image is larger than the
	// display size in portrait mode, so scale it down to the
	// largest dimensions that can be displayed in portrait mode.

	NSImage *img = [[[NSImage alloc] initWithData:image_data] autorelease];

	CGSize imageSize = NSSizeToCGSize(img.size);
	int imageWidth = imageSize.width;
	int imageHeight = imageSize.height;

	assert(imageWidth > 0);
	assert(imageHeight > 0);
  
  // If this is the first frame, set the movie size based on the size of the first frame
  
  if (frameIndex == 0) {
    mvidWriter.movieSize = imageSize;
    _movieDimensions = imageSize;
  } else if (CGSizeEqualToSize(imageSize, _movieDimensions) == FALSE) {
    // Size of next frame must exactly match the size of the previous one
    
    fprintf(stderr, "error: frame file \"%s\" size %d x %d does not match initial frame size %d x %d",
            [filenameStr UTF8String],
            (int)imageSize.width, (int)imageSize.height,
            (int)_movieDimensions.width, (int)_movieDimensions.height);
    exit(2);
  }

  // Render into pixmap of known layout, this might change the BPP if a different value was specified
  // in the command line options. For example, 32BPP could be downsamples to 16BPP with no alpha.

	NSRect viewRect;
	viewRect.origin.x = 0.0;
	viewRect.origin.y = 0.0;
	viewRect.size.width = imageWidth;
	viewRect.size.height = imageHeight;

	// Render NSImageView into core graphics buffer that is limited
	// to the max size of the iPhone frame buffer. Only scaling
	// is handled in this render operation, no rotation issues
	// are handled here.

	NSImageView *imageView = [[[NSImageView alloc] initWithFrame:viewRect] autorelease];
	imageView.image = img;

	CGFrameBuffer *cgBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:imageWidth height:imageHeight];
  
	BOOL worked = [cgBuffer renderView:imageView];
  assert(worked);

  /*
	// RLE encode the RAW data and save to the RLE directory.

	NSString *rleFilename = [NSString stringWithFormat:@"%@%@%@",
							 @"F",
							 format_frame_number(frameIndex+1),
							 @".rle"];
	NSString *rlePath = [rle_directory stringByAppendingPathComponent:rleFilename];

	NSData *rleData = [cgBuffer runLengthEncode];

	success = [rleData writeToFile:rlePath atomically:FALSE];
	assert(success);

	[rle_filenames addObject:rlePath];
   */
    
  // Copy the pixels from the cgBuffer into a NSImage
  
  if (FALSE) {
    NSString *dumpFilename = [NSString stringWithFormat:@"DumpFrame%0.4d.png", frameIndex+1];

    NSData *pngData = [cgBuffer formatAsPNG];
    
    [pngData writeToFile:dumpFilename atomically:NO];
    
    NSLog(@"wrote %@", dumpFilename);
  }
  
  // The CGFrameBuffer now contains the rendered pixels in the expected output format. Write to MVID frame.

  if (isKeyframe) {
    // Emit Keyframe
    
    char *buffer = cgBuffer.pixels;
    int numBytesInBuffer = cgBuffer.numBytes;
    
    worked = [mvidWriter writeKeyframe:buffer bufferSize:numBytesInBuffer];
    
    if (worked == FALSE) {
      fprintf(stderr, "can't write keyframe data to mvid file \"%s\"\n", [filenameStr UTF8String]);
      exit(1);
    }
  } else {
    // Calculate delta pixels by comparing the previous frame to the current frame.
    // Once we know specific delta pixels, then only those pixels that actually changed
    // can be stored in a delta frame.
    
    assert(prevFrameBuffer);
    
    NSArray *deltaPixels = [prevFrameBuffer calculateDeltaPixels:cgBuffer];
    if ([deltaPixels count] == 0) {
      // The two frames are pixel identical, this is a no-op delta frame
      
      [mvidWriter writeNopFrame];
      worked = TRUE;
    } else {
      NSUInteger frameBufferNumPixels = mvidWriter.movieSize.width * mvidWriter.movieSize.height;
      
      // Calculate adler32 on the original frame data
      
      uint32_t adler = 0;
      adler = maxvid_adler32(0, (unsigned char *)cgBuffer.pixels, cgBuffer.numBytes);
      assert(adler != 0);
      
      worked = write_delta_pixels_as_delta_frame(mvidWriter, deltaPixels, frameBufferNumPixels, adler);
    }
    
    if (worked == FALSE) {
      fprintf(stderr, "can't write deltaframe data to mvid file \"%s\"\n", [filenameStr UTF8String]);
      exit(1);
    }
  }

  if (TRUE) {
    if (prevFrameBuffer) {
      [prevFrameBuffer release];
    }
    prevFrameBuffer = cgBuffer;
    [prevFrameBuffer retain];
  }
  
	// free up resources
  
  [pool drain];
	
	return 0;
}

// Query open file size, then rewind to start

static
int fpsize(FILE *fp, uint32_t *filesize) {
  int retcode;
  retcode = fseek(fp, 0, SEEK_END);
  assert(retcode == 0);
  uint32_t size = ftell(fp);
  *filesize = size;
  fseek(fp, 0, SEEK_SET);
  return 0;
}

// Given an array of delta pixel values, generate maxvid codes that describe
// the delta pixels and encode the information as a delta frame in the
// mvid file.

BOOL write_delta_pixels_as_delta_frame(AVMvidFileWriter *mvidWriter,
                                       NSArray *deltaPixels,
                                       NSUInteger frameBufferNumPixels,
                                       uint32_t adler)
{
  int retcode;
  
  NSMutableData *mvidWordCodes = [NSMutableData data];
  
  int bpp = mvidWriter.bpp;
  
  // Create MVID word codes in a buffer

  adler = 0;
  
  // FIXME: assumes 32 bit

  /*
  
  {    
    uint32_t skipCode = maxvid32_code(SKIP, frameBufferNumPixels);
    
    NSData *wordCode = [NSData dataWithBytes:&skipCode length:sizeof(uint32_t)];
    
    [mvidWordCodes appendData:wordCode];    
  }
   
  */

  /*
  
  Use CASES
   
  // 0 (add to pixel run)
  // 1 (add)
  // 3 (process last pixel run, SKIP to current, add to run)
  
  */
  
  int prevPixelOffset = 0;
  BOOL isFirstPixel = TRUE;
  
  NSMutableArray *mPixelRun = [NSMutableArray array];
  
  for (DeltaPixel *deltaPixel in deltaPixels) {
    int nextPixelOffset = deltaPixel->offset;
    
    if ((isFirstPixel == FALSE) && (nextPixelOffset == (prevPixelOffset + 1))) {
      // Processing a pixel other than the first one, and this pixel appears
      // directly after the last pixel. This means that the modified pixel is
      // the next pixel in a pixel run.
      
      [mPixelRun addObject:deltaPixel];
    } else {
      // This is the first pixel in a new pixel run. It might be the first pixel
      // and in that case the existing run is of zero length. Otherwise, emit
      // the previous run of pixels so that we can start a new run.
      
      process_pixel_run(mvidWordCodes, mPixelRun, prevPixelOffset, nextPixelOffset);
      
      [mPixelRun addObject:deltaPixel];
    }

    isFirstPixel = FALSE;    
    prevPixelOffset = nextPixelOffset;
  }
  
  // At the end of the delta pixels, we could have a run of pixels that still need to
  // be processed. In addition, we might need to SKIP to the end of the framebuffer.
  
  process_pixel_run(mvidWordCodes, mPixelRun, prevPixelOffset, frameBufferNumPixels);
  
  /*
  if (prevPixelOffset < frameBufferNumPixels) {
    // Emit one trailing SKIP operation to cover the unchanged pixels from the end of the
    // delta pixels to the end of the whole framebuffer
    
    int numToSkip = frameBufferNumPixels - prevPixelOffset;
    
    uint32_t skipCode = maxvid32_code(SKIP, numToSkip);
    
    NSData *wordCode = [NSData dataWithBytes:&skipCode length:sizeof(uint32_t)];
    
    [mvidWordCodes appendData:wordCode];
  }
  */

  // Emit DONE code to indicate that all codes have been emitted
  {    
    uint32_t doneCode = maxvid32_code(DONE, 0);
    
    NSData *wordCode = [NSData dataWithBytes:&doneCode length:sizeof(uint32_t)];
    
    [mvidWordCodes appendData:wordCode];    
  }
  
  // Convert the generic maxvid codes to the optimized c4 encoding and append to the output file
  
  FILE *tmpfp = tmpfile();
  if (tmpfp == NULL) {
    assert(0);
  }
  
  uint32_t *maxvidCodeBuffer = (uint32_t*)mvidWordCodes.bytes;
  uint32_t numMaxvidCodeWords = mvidWordCodes.length / sizeof(uint32_t);
  
  if (bpp == 16) {
    retcode = maxvid_encode_c4_sample16(maxvidCodeBuffer, numMaxvidCodeWords, frameBufferNumPixels, NULL, tmpfp, 0);
  } else if (bpp == 24 || bpp == 32) {
    retcode = maxvid_encode_c4_sample32(maxvidCodeBuffer, numMaxvidCodeWords, frameBufferNumPixels, NULL, tmpfp, 0);
  }
  
  // Read tmp file contents into buffer.
  
  if (retcode == 0) {
    // Read file contents into a buffer, then write that buffer into .mvid file
    
    uint32_t filesize;
    
    fpsize(tmpfp, &filesize);
    
    assert(filesize > 0);
    
    char *buffer = malloc(filesize);
    
    if (buffer == NULL) {
      // Malloc failed
      
      retcode = MV_ERROR_CODE_WRITE_FAILED;
    } else {
      size_t result = fread(buffer, filesize, 1, tmpfp);
      
      if (result != 1) {
        retcode = MV_ERROR_CODE_READ_FAILED;
      } else {        
        // Write codes to mvid file
        
        BOOL worked = [mvidWriter writeDeltaframe:buffer bufferSize:filesize adler:adler];
        
        if (worked == FALSE) {
          retcode = MV_ERROR_CODE_WRITE_FAILED;
        }
      }
      
      free(buffer);
    }
  }
  
  if (tmpfp != NULL) {
    fclose(tmpfp);
  }
  
  if (retcode == 0) {
    return TRUE;
  } else {
    return FALSE;
  }
}

// Given a buffer of modified pixels, figure out how to write the pixels
// into mvidWordCodes. Pixels are emitted as COPY unless there is a run
// of 2 or more of the same value. Use a DUP in the case of a run.

static
void process_pixel_run(NSMutableData *mvidWordCodes,
                       NSMutableArray *mPixelRun,
                       int prevPixelOffset,
                       int nextPixelOffset)
{
  if ([mPixelRun count] > 0) {
    // Emit codes for this run of pixels
 
    int runLength = 0;
    int firstPixelOffset = -1;
    int lastPixelOffset = -1;
    
    if (TRUE) {
      // Additional checking of the data run mPixelRun, not required
      
      for (DeltaPixel *deltaPixel in mPixelRun) {
        runLength++;
        if (firstPixelOffset == -1) {
          firstPixelOffset = deltaPixel->offset;
        }
        lastPixelOffset = deltaPixel->offset;
      }
    } else {
      runLength = [mPixelRun count];
      
      firstPixelOffset = ((DeltaPixel*)[mPixelRun objectAtIndex:0])->offset;
      lastPixelOffset = ((DeltaPixel*)[mPixelRun lastObject])->offset;
    }
    
    assert((lastPixelOffset - firstPixelOffset + 1) == runLength);
    
    // FIXME: scan pixel run for DUP pattern
    
    // EMIT COPY code to indicate how many delta pixels to copy
    
    uint32_t copyCode = maxvid32_code(COPY, runLength);
    
    NSData *wordCode = [NSData dataWithBytes:&copyCode length:sizeof(uint32_t)];
    
    [mvidWordCodes appendData:wordCode];

    // Emit a word for each pixel in the COPY
    
    for (DeltaPixel *deltaPixel in mPixelRun) {
      uint32_t value = deltaPixel->newValue;
      
      NSData *pixelData = [NSData dataWithBytes:&value length:sizeof(uint32_t)];
      
      // FIXME: can we just append 4 bytes instead of creating a NSData here?
      
      [mvidWordCodes appendData:pixelData];
    }
    
    // Update prevPixelOffset so that it contains the offset that the pixel run just
    // wrote up to. This is needed to determine if we need to SKIP pixels up to the
    // nextPixelOffset value.
    
    prevPixelOffset = lastPixelOffset;
  }
  
  // Emit SKIP pixels to advance from the last offset written as part of
  // the pixel run up to the index indicated by pixelOffset.
  
  int numToSkip = nextPixelOffset - prevPixelOffset;
  
  // Emit SKIP pixels to advance up to the offset for this pixel
  
  if (numToSkip > 0)
  {
    uint32_t skipCode = maxvid32_code(SKIP, numToSkip);
    
    NSData *wordCode = [NSData dataWithBytes:&skipCode length:sizeof(uint32_t)];
    
    [mvidWordCodes appendData:wordCode];    
  }
    
  [mPixelRun removeAllObjects];
}

// Extract all the frames of movie data from an archive file into
// files indicated by a path prefix.

void extractFramesFromMvidMain(char *mvidFilename, char *extractFramesPrefix) {
	BOOL worked;
  
  AVMvidFrameDecoder *frameDecoder = [AVMvidFrameDecoder aVMvidFrameDecoder];

	NSString *mvidPath = [NSString stringWithUTF8String:mvidFilename];
  
  worked = [frameDecoder openForReading:mvidPath];
  
  if (worked == FALSE) {
    fprintf(stderr, "error: cannot open mvid filename \"%s\"", mvidFilename);
    exit(1);
  }
    
  worked = [frameDecoder allocateDecodeResources];
  assert(worked);
  
  NSUInteger numFrames = [frameDecoder numFrames];
  assert(numFrames > 0);

  for (NSUInteger frameIndex = 0; frameIndex < numFrames; frameIndex++) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    AVFrame *frame = [frameDecoder advanceToFrame:frameIndex];
    
    CGFrameBuffer *cgFrameBuffer = frame.cgFrameBuffer;
    assert(cgFrameBuffer);
    
    NSData *pngData = [cgFrameBuffer formatAsPNG];
    assert(pngData);
    
    NSString *pngFilename = [NSString stringWithFormat:@"%s%0.4d%s", extractFramesPrefix, frameIndex+1, ".png"];
    
    [pngData writeToFile:pngFilename atomically:NO];
    
    NSLog(@"wrote %@", pngFilename);
    
    [pool drain];
  }

  [frameDecoder close];
  
	return;
}

// Calculate the standard deviation and the mean

void calc_std_dev(int *sizes, int numFrames, float *std_dev, float *mean, int *maxPtr) {
	int i;

	int sum = 0;
	int max = 0;

	for (i = 0; i < numFrames; i++) {
		sum += sizes[i];

		if (sizes[i] > max)
			max = sizes[i];
	}

	*mean = ((float)sum) / numFrames;

	float sum_of_squares = 0.0;

	for (i = 0; i < numFrames; i++) {
		float diff = (sizes[i] - *mean);
		sum_of_squares += (diff * diff);
	}

	float numerator = sqrt(sum_of_squares);
	float denominator = sqrt(numFrames - 1);

	*std_dev = numerator / denominator;
	*maxPtr = max;
}

// Return TRUE if file exists, FALSE otherwise

BOOL fileExists(NSString *filePath) {
  if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
    return TRUE;
	} else {
    return FALSE;
  }
}

// Entry point for logic that encodes a .mvid from a series of frames.

void encodeMvidFromFramesMain(char *mvidFilenameCstr,
                              char *firstFilenameCstr,
                              char *framerateCstr,
                              char *bppCstr,
                              char *keyframeCstr)
{
  NSString *mvidFilename = [NSString stringWithUTF8String:mvidFilenameCstr];
  
  BOOL isMvid = [mvidFilename hasSuffix:@".mvid"];
  
  if (isMvid == FALSE) {
    fprintf(stderr, USAGE);
    exit(1);
  }
  
  // Given the first frame image filename, build and array of filenames
  // by checking to see if files exist up until we find one that does not.
  // This makes it possible to pass the 25th frame ofa 50 frame animation
  // and generate an animation 25 frames in duration.
  
  NSString *firstFilename = [NSString stringWithUTF8String:firstFilenameCstr];
  
  if (fileExists(firstFilename) == FALSE) {
    fprintf(stderr, "error: first filename \"%s\" does not exist", firstFilenameCstr);
    exit(1);
  }
  
  NSString *firstFilenameExt = [firstFilename pathExtension];
  
  if ([firstFilenameExt isEqualToString:@"png"] == FALSE) {
    fprintf(stderr, "error: first filename \"%s\" must have .png extension", firstFilenameCstr);
    exit(1);
  }
  
  // Find first numerical character in the [0-9] range starting at the end of the filename string.
  // A frame filename like "Frame0001.png" would be an example input. Note that the last frame
  // number must be the last character before the extension.
  
  NSArray *upToLastPathComponent = [firstFilename pathComponents];
  NSRange upToLastPathComponentRange;
  upToLastPathComponentRange.location = 0;
  upToLastPathComponentRange.length = [upToLastPathComponent count] - 1;
  upToLastPathComponent = [upToLastPathComponent subarrayWithRange:upToLastPathComponentRange];
  NSString *upToLastPathComponentPath = [NSString pathWithComponents:upToLastPathComponent];
  
  NSString *firstFilenameTail = [firstFilename lastPathComponent];
  NSString *firstFilenameTailNoExtension = [firstFilenameTail stringByDeletingPathExtension];
  
  int numericStartIndex = -1;
  
  for (int i = [firstFilenameTailNoExtension length] - 1; i > 0; i--) {
    unichar c = [firstFilenameTailNoExtension characterAtIndex:i];
    if (c >= '0' && c <= '9') {
      numericStartIndex = i;
    }
  }
  if (numericStartIndex == -1 || numericStartIndex == 0) {
    fprintf(stderr, "error: could not find frame number in first filename \"%s\"", firstFilenameCstr);
    exit(1);
  }
  
  // Extract the numeric portion of the first frame filename
  
  NSString *namePortion = [firstFilenameTailNoExtension substringToIndex:numericStartIndex];
  NSString *numberPortion = [firstFilenameTailNoExtension substringFromIndex:numericStartIndex];
  
  if ([namePortion length] < 1 || [numberPortion length] == 0) {
    fprintf(stderr, "error: could not find frame number in first filename \"%s\"", firstFilenameCstr);
    exit(1);
  }
  
  // Convert number with leading zeros to a simple integer
  
  NSMutableArray *inFramePaths = [NSMutableArray arrayWithCapacity:1024];
  
  int formatWidth = [numberPortion length];
  int startingFrameNumber = [numberPortion intValue];
  int endingFrameNumber = -1;
  
#define CRAZY_MAX_FRAMES 9999999
#define CRAZY_MAX_DIGITS 7
  
  // Note that we include the first frame in this loop just so that it gets added to inFramePaths.
  
  for (int i = startingFrameNumber; i < CRAZY_MAX_FRAMES; i++) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSMutableString *frameNumberWithLeadingZeros = [NSMutableString string];
    [frameNumberWithLeadingZeros appendFormat:@"%07d", i];
    if ([frameNumberWithLeadingZeros length] > formatWidth) {
      int numToDelete = [frameNumberWithLeadingZeros length] - formatWidth;
      NSRange delRange;
      delRange.location = 0;
      delRange.length = numToDelete;
      [frameNumberWithLeadingZeros deleteCharactersInRange:delRange];
      assert([frameNumberWithLeadingZeros length] == formatWidth);
    }
    [frameNumberWithLeadingZeros appendString:@".png"];
    [frameNumberWithLeadingZeros insertString:namePortion atIndex:0];
    NSString *framePathWithNumber = [upToLastPathComponentPath stringByAppendingPathComponent:frameNumberWithLeadingZeros];
    
    if (fileExists(framePathWithNumber)) {
      // Found frame at indicated path, add it to array of known frame filenames
      
      [inFramePaths addObject:framePathWithNumber];
      endingFrameNumber = i;
    } else {
      // Frame filename with indicated frame number not found, done scanning for frame files
      [pool drain];
      break;
    }
    
    [pool drain];
  }
  
  if ((startingFrameNumber == endingFrameNumber) || (endingFrameNumber == CRAZY_MAX_FRAMES-1)) {
    fprintf(stderr, "error: could not find last frame number");
    exit(1);
  }
  
  // FRAMERATE is a floating point number that indicates the delay between frames.
  // This framerate value is a constant that does not change over the course of the
  // movie, though it is possible that a certain frame could repeat a number of times.
  
  NSString *framerateStr = [NSString stringWithUTF8String:framerateCstr];
  
  if ([framerateStr length] == 0) {
    fprintf(stderr, "error: FRAMERATE is invalid \"%s\"", firstFilenameCstr);
    exit(1);
  }
  
  float framerateNum = [framerateStr floatValue];
  if (framerateNum <= 0.0f || framerateNum >= 90.0f) {
    fprintf(stderr, "error: FRAMERATE is invalid \"%f\"", framerateNum);
    exit(1);
  }
  
  // BITSPERPIXEL : 16, 24, or 32 BPP.
  
  NSString *bppStr = [NSString stringWithUTF8String:bppCstr];
  int bppNum = [bppStr intValue];
  if (bppNum == 16 || bppNum == 24 || bppNum == 32) {
    // Value is valid
  } else {
    fprintf(stderr, "error: BITSPERPIXEL is invalid \"%s\"", bppCstr);
    exit(1);
  }
  
  // KEYFRAME : integer that indicates a keyframe should be emitted every N frames
  
  NSString *keyframeStr = [NSString stringWithUTF8String:keyframeCstr];
  
  if ([keyframeStr length] == 0) {
    fprintf(stderr, "error: KEYFRAME is invalid \"%s\"", keyframeCstr);
    exit(1);
  }
  
  int keyframeNum = [keyframeStr intValue];
  if (keyframeNum == 0) {
    // All frames as stored as keyframes. This takes up more space but the frames can
    // be blitted into graphics memory directly from mapped memory at runtime.
    keyframeNum = 0;
  } else if (keyframeNum < 0) {
    // Just revert to the default
    keyframeNum = 10000;
  }
  
  // FIXME: Open .mvid and pass in the framerate to setup the header.
  
  AVMvidFileWriter *mvidWriter = [AVMvidFileWriter aVMvidFileWriter];
  
  {
    assert(mvidWriter);
    
    mvidWriter.mvidPath = mvidFilename;
    mvidWriter.bpp = bppNum;
    // Note that we don't know the movie size until the first frame is read
    
    mvidWriter.frameDuration = framerateNum;
    mvidWriter.totalNumFrames = [inFramePaths count];
    
    mvidWriter.genAdler = TRUE;
    
    BOOL worked = [mvidWriter open];
    if (worked == FALSE) {
      fprintf(stderr, "error: Could not open .mvid output file \"%s\"", mvidFilenameCstr);        
      exit(1);
    }
  }
  
  // We now know the start and end integer values of the frame filename range.
  
  int frameIndex = 0;
  
  for (NSString *framePath in inFramePaths) {
    fprintf(stdout, "saved %s as frame %d\n", [framePath UTF8String], frameIndex+1);
    fflush(stdout);
    
    BOOL isKeyframe = FALSE;
    if (frameIndex == 0) {
      isKeyframe = TRUE;
    }
    if (keyframeNum == 0) {
      // All frames are key frames
      isKeyframe = TRUE;
    } else if ((keyframeNum > 0) && ((frameIndex % keyframeNum) == 0)) {
      // Keyframe every N frames
      isKeyframe = TRUE;
    }
    
    process_frame_file(mvidWriter, framePath, frameIndex, bppNum, isKeyframe);
    frameIndex++;
  }
  
  // Done writing .mvid file
  
  [mvidWriter rewriteHeader];
  
  [mvidWriter close];
  
  fprintf(stdout, "done writing %d frames to %s\n", frameIndex, mvidFilenameCstr);
  fflush(stdout);
  
  // cleanup
  
  if (prevFrameBuffer) {
    [prevFrameBuffer release];
  }
}

// main() Entry Point

int main (int argc, const char * argv[]) {
  NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

	if ((argc == 3 || argc == 4) && (strcmp(argv[1], "-extract") == 0)) {
		// Extract movie frames from an existing archive

    char *mvidFilename = (char *)argv[2];
    char *framesFilePrefix;
    
    if (argc == 3) {
      framesFilePrefix = "Frame";
    } else {
      framesFilePrefix = (char*)argv[3];
    }
    
		extractFramesFromMvidMain(mvidFilename, framesFilePrefix);
	} else if (argc == 5 || argc == 6) {
    // FILE.mvid : name of output file that will contain all the video frames
    // FIRSTFRAME.png : name of first frame file of input PNG files. All
    //   video frames must exist in the same directory
    // FRAMERATE is a floating point framerate value. Common values
    // include 1.0 FPS, 15 FPS, 29.97 FPS, and 30 FPS.
    // BITSPERPIXEL : 16, 24, or 32 BPP
    // KEYFRAME is the number of frames until the next keyframe in the
    //   resulting movie file. The default of 10,000 ensures that
    //   the resulting movie would only contain the initial keyframe.

    char *mvidFilenameCstr = (char*)argv[1];
    char *firstFilenameCstr = (char*)argv[2];
    char *framerateCstr = (char*)argv[3];
    char *bppCstr = (char*)argv[4];
    char *keyframeCstr = "10000";
    if (argc == 6) {
      keyframeCstr = (char*)argv[5];
    }
    
    encodeMvidFromFramesMain(mvidFilenameCstr,
                            firstFilenameCstr,
                            framerateCstr,
                            bppCstr,
                             keyframeCstr);
    
    if (TRUE) {
      // Extract frames we just encoded into the .mvid file for debug purposes
      
      extractFramesFromMvidMain(mvidFilenameCstr, "ExtractedFrame");
    }
	} else if (argc == 2) {
    fprintf(stderr, USAGE);
    exit(1);
  }
  
  [pool drain];
  return 0;
}

