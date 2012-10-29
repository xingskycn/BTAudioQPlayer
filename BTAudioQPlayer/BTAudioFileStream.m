//
//  AudioFileStream.m
//

#import "BTAudioFileStream.h"
#import "AudioPlayerUtil.h"
#import "BTDebug.h"
#import "BTAudioPlayer.h"

@implementation BTAudioFileStream

@synthesize delegate = _delegate;
@synthesize asbd = _asbd;
@synthesize fileLength = _fileLength;
@synthesize dataOffset = _dataOffset;
@synthesize packetDuration = _packetDuration;
@synthesize seekTime = _seekTime;
@synthesize seekBtyeOffset = _seekByteOffset;
@synthesize sampleRate = _sampleRate;

// These are declarations for callbacks used by our AudioFileStream.  In both cases,
// they simply forward the call onto the self object that created the file stream.
void propertyCallback(void *clientData, AudioFileStreamID stream, AudioFileStreamPropertyID property, UInt32 *ioFlags);
void packetCallback(void *clientData, UInt32 byteCount, UInt32 packetCount, const void *inputData, AudioStreamPacketDescription *packetDescriptions);

- (id)initFileStreamWithDelegate:(id<BTAudioFileStreamDelegate>)aDelegate {
	self = [super init];
	self.delegate = aDelegate;
	return self;
}

- (void)dealloc {
  _delegate = nil;
  [self close];
	[super dealloc];
}

- (void)close {
  if (_streamID != NULL) {
		OSStatus status = AudioFileStreamClose(_streamID);
    _streamID = NULL;
		VERIFY_STATUS(status);
	}
}

- (OSStatus) open {
	// Open our file stream.  Our callback methods are implemented above.
	// We pass our self as clientData so that our callbacks simply message 
	// us when called, thus providing a simple Objective-C wrapper around
	// the C API.
	// We pass 0 as a fileTypeHint because CoreAudio is pretty good at
	// determining the fileType for us (and may ignore our hint anyway.)
	return AudioFileStreamOpen(self, 
							   propertyCallback, 
							   packetCallback, 
							   kAudioFileMP3Type, 
							   &_streamID);
}

- (OSStatus)parseBytes:(const void*)inData dataSize:(UInt32)inDataSize flags:(UInt32)inFlags {
  _callbackStatus = noErr;
	OSStatus status = AudioFileStreamParseBytes(_streamID, inDataSize, inData, inFlags);
	if (!VERIFY_STATUS(status)) {
		return status;
	}
	return _callbackStatus;
}

- (void)notifyDelegateWithMagicCookie {	
	// This method is called when our propertyCallback is called
	// as a result of parsing bytes.
	
	// First, we need to fine out how big our magic cookie is.
	UInt32 size;
	Boolean writeable;
	_callbackStatus = AudioFileStreamGetPropertyInfo(_streamID, 
													kAudioFileStreamProperty_MagicCookieData, 
													&size, 
													&writeable);
	if (!VERIFY_STATUS(_callbackStatus)) {
		return;
	}
	
	// Now we get the actual magic cookie data and send it to our delegate.
	NSMutableData *data = [NSMutableData dataWithLength:size];
	_callbackStatus = AudioFileStreamGetProperty(_streamID, 
												kAudioFileStreamProperty_MagicCookieData, 
												&size, 
												data.mutableBytes);
	if (!VERIFY_STATUS(_callbackStatus)) {
		return;
	}
	
	[_delegate audioFileStream:self foundMagicCookie:data];
}

- (void)notifyDelegateWithASBD {
	// For AAC-PLUS, the returned audio may actually have multiple supported formats, support for which may
	// vary based on the device.  Therefore we need to do some juggling here to figure out what we support.
	
	// We want to get a list of formats this audio stream supports.
	// Before we can that, we need to find the size of data we're trying to get.
	UInt32 formatListSize;
	Boolean b;
	AudioFileStreamGetPropertyInfo(_streamID, 
								   kAudioFileStreamProperty_FormatList, 
								   &formatListSize, 
								   &b);
  
  
	
	// now get the format data
	NSMutableData *listData = [NSMutableData dataWithLength:formatListSize];
	OSStatus status = AudioFileStreamGetProperty(_streamID, 
												 kAudioFileStreamProperty_FormatList, 
												 &formatListSize, 
												 [listData mutableBytes]);
	AudioFormatListItem *formatList = [listData mutableBytes];
	
	// The formatList property isn't always supported, so an error isn't unexpected here.
	// Therefore, we won't call VERIFY_STATUS on this status code.
	if (status == noErr) {
		// now see which format this device supports best
		UInt32 chosen;
		UInt32 chosenSize = sizeof(UInt32);
		int formatCount = formatListSize/sizeof(AudioFormatListItem);
		status = AudioFormatGetProperty ('fpfl', 
										 formatListSize, 
										 formatList, 
										 &chosenSize, 
										 &chosen);
		if (VERIFY_STATUS(status)) {
			_asbd = formatList[chosen].mASBD;
		} else {
			// the docs tell us to grab the last in the list because it's most compatible
			_asbd = formatList[formatCount - 1].mASBD;
		}
	} else {
		// fall back to the stream's DataFormat
		UInt32 descriptionSize = sizeof(AudioStreamBasicDescription);
		_callbackStatus = AudioFileStreamGetProperty(_streamID, 
													kAudioFileStreamProperty_DataFormat, 
													&descriptionSize, 
													&_asbd);
		if (!VERIFY_STATUS(_callbackStatus)) {
			return;
		}
	}
	_sampleRate = _asbd.mSampleRate;
  _packetDuration = (float)_asbd.mFramesPerPacket / _sampleRate;
  _isFormatVBR = (_asbd.mBytesPerPacket == 0 || _asbd.mFramesPerPacket == 0);
  NSString *fileFormat = [self getFileFormat];
  UInt64 audioDataByteCount = [self getAudioDataByteCount];
  UInt64 audioDataPacketCount = [self getAudioDataPacketCount];
  UInt32 maxPacketSize = [self getMaxPacketSize];
  _dataOffset = [self getDataOffset];
  UInt32 packetSizeUpperBound = [self getPacketSizeUpperBound];
  UInt64 averageBytesPerPacket = [self getAverageBytesPerPacket];
  _bitRate = [self getBitRate];
  CILog(BTDFLAG_FILE_STREAM, @"isFormatVBR           = %d", _isFormatVBR);
  CILog(BTDFLAG_FILE_STREAM, @"fileFormat            = %@", fileFormat);
  CILog(BTDFLAG_FILE_STREAM, @"audioDataByteCount    = %lld", audioDataByteCount);
  CILog(BTDFLAG_FILE_STREAM, @"audioDataPacketCount  = %lld", audioDataPacketCount);
  CILog(BTDFLAG_FILE_STREAM, @"maxPacketSize         = %ld", maxPacketSize);
  CILog(BTDFLAG_FILE_STREAM, @"dataOffset            = %lld", _dataOffset);
  CILog(BTDFLAG_FILE_STREAM, @"packetSizeUpperBound  = %ld", packetSizeUpperBound);
  CILog(BTDFLAG_FILE_STREAM, @"averageBytesPerPacket = %lld", averageBytesPerPacket);
  CILog(BTDFLAG_FILE_STREAM, @"bitRate               = %ld", _bitRate);
  
  
	[_delegate audioFileStream:self isReadyToProducePacketsWithASBD:_asbd];
}

- (void)propertyDidChange:(AudioFileStreamPropertyID)property {
	if (_callbackStatus != noErr) {
		// We had a previous error during the current parse.  We should
		// stop processing this parse.
		return;
	}
	
	// This method is called by our propertyCallback
	switch (property) {
		case kAudioFileStreamProperty_MagicCookieData:
			// Our stream contains a "magic cookie".  Magic cookies contain special
			// metadata about the stream that is specific to the audio format in
			// a non-generalizable way.  AudioQueue requires the magic cookie
			// for some audio formats to work correctly.
			[self notifyDelegateWithMagicCookie];
			break;
		case kAudioFileStreamProperty_ReadyToProducePackets:
			// Enough data has been read from our stream to know the audio format
			// and begin sending audio data to an audio queue.  Notify our delegate
			// of the AudioStreamBasicDescriptor of this stream so that our delegate
			// can create and stream to an AudioQueue.
			[self notifyDelegateWithASBD];
			break;
		default:
			break;
	}
}

- (void)callBackWithByteCount:(UInt32)byteCount packetCount:(UInt32)packetCount data:(const void *)inputData packetDescs:(AudioStreamPacketDescription *)packetDescs {
  CVLog(BTDFLAG_FILE_STREAM, @"");
  if (packetDescs) {
		for (int i = 0; i < packetCount; ++i) {
			UInt64 packetSize   = packetDescs[i].mDataByteSize;
      _processedPacketsSizeTotal += packetSize;
      _processedPacketsCount += 1;
    }
  }
  [_delegate audioFileStream:self
           callBackWithByteCount:byteCount packetCount:packetCount data:inputData packetDescs:packetDescs];
}

void propertyCallback(void *clientData, AudioFileStreamID stream, AudioFileStreamPropertyID property, UInt32 *ioFlags) {
  if (clientData != NULL && [(id)clientData isKindOfClass:[BTAudioFileStream class]]) {
	// forward the call onto the self object that created the file stream
    BTAudioFileStream *self = (BTAudioFileStream *)clientData;
    [self propertyDidChange:property];
  }
}

void packetCallback(void *clientData, UInt32 byteCount, UInt32 packetCount, const void *inputData, AudioStreamPacketDescription *packetDescriptions) {
  if (clientData != NULL && [(id)clientData isKindOfClass:[BTAudioFileStream class]]) {
	// forward the call onto the self object that created the file stream
    BTAudioFileStream *self = (BTAudioFileStream *)clientData;
    [self callBackWithByteCount:byteCount 
        packetCount:packetCount 
             data:inputData
           packetDescs:packetDescriptions];
  }
}

- (UInt32)getPacketBufferSize {
  UInt32 size = 0;
  if (_isFormatVBR) {
    size = [self getPacketSizeUpperBound];
    if (size == 0) {
      size = [self getMaxPacketSize];
    }
  }
  if (size == 0) {
    size = kAQDefaultBufSize;
  }
  return size;
}

- (NSString*)getFileFormat {
  UInt32 value = [self getUInt32ValueByProperty:kAudioFileStreamProperty_FileFormat];
  NSString *strValue = [self convertUInt32ValueToString:value];
  return strValue;
}

- (UInt64)getAudioDataByteCount {
  UInt64 value = [self getUInt64ValueByProperty:kAudioFileStreamProperty_AudioDataByteCount];
  return value;
}

- (UInt64)getAudioDataPacketCount {
  UInt64 value = [self getUInt64ValueByProperty:kAudioFileStreamProperty_AudioDataPacketCount];
  return value;
}

- (UInt32)getMaxPacketSize {
  UInt32 value = [self getUInt32ValueByProperty:kAudioFileStreamProperty_MaximumPacketSize];
  return value;
}

- (UInt64)getDataOffset {
  UInt64 value = [self getUInt64ValueByProperty:kAudioFileStreamProperty_DataOffset];
  return value;
}

- (UInt32)getPacketSizeUpperBound {
  UInt32 value = [self getUInt32ValueByProperty:kAudioFileStreamProperty_PacketSizeUpperBound];
  return value;
}

- (UInt64)getAverageBytesPerPacket {
  UInt64 value = [self getUInt64ValueByProperty:kAudioFileStreamProperty_AverageBytesPerPacket];
  return value;
}

- (UInt32)getBitRate {
  UInt32 value = [self getUInt32ValueByProperty:kAudioFileStreamProperty_BitRate];
  return value;
}

- (UInt32)getUInt32ValueByProperty:(AudioFileStreamPropertyID)propertyID {
  UInt32 value = 0;
  UInt32 sizeOfValue = sizeof(value);
  OSStatus status = AudioFileStreamGetProperty(_streamID, propertyID, &sizeOfValue, &value);
  VERIFY_STATUS(status);
  return value;
}

- (NSString*)convertUInt32ValueToString:(UInt32)value {
  char *s = (char *)&value;
  NSString *strValue = [NSString stringWithFormat:@"%c%c%c%c",s[3], s[2], s[1], s[0]];
  return strValue;
}

- (UInt64)getUInt64ValueByProperty:(AudioFileStreamPropertyID)propertyID {
  UInt64 value = 0;
  UInt32 sizeOfValue = sizeof(value);
  OSStatus status = AudioFileStreamGetProperty(_streamID, propertyID, &sizeOfValue, &value);
  VERIFY_STATUS(status);
  return value;
}

- (float)duration {
	float calculatedBitRate = [self calculatedBitRate];
	
	if (calculatedBitRate == 0 || _fileLength == 0) {
		return 0.0;
  }
	
	return (_fileLength - _dataOffset) / (calculatedBitRate * 0.125);
}

//
// calculatedBitRate
//
// returns the bit rate, if known. Uses packet duration times running bits per
//   packet if available, otherwise it returns the nominal bitrate. Will return
//   zero if no useful option available.
//
- (float)calculatedBitRate {
  float bitRate = 0.0;
	if (_isFormatVBR) { //packetDuration = asbd.mFramesPerPacket / asbd.mSampleRate
		if (_packetDuration && _processedPacketsCount > 50) {
			float averagePacketByteSize = (float)_processedPacketsSizeTotal / _processedPacketsCount;
      CVLog(BTDFLAG_FILE_STREAM, @"averagePacketByteSize = %.4f",averagePacketByteSize);
      bitRate = 8.0 * averagePacketByteSize / _packetDuration;
    } else if (_bitRate) {
			bitRate = _bitRate;
    }
  } else {
		bitRate = 8.0 * _asbd.mSampleRate * _asbd.mBytesPerPacket * _asbd.mFramesPerPacket;
    _bitRate = bitRate;
  }
  CVLog(BTDFLAG_FILE_STREAM, @"                   bitRate = %.4f",bitRate);
  CVLog(BTDFLAG_FILE_STREAM, @"           _packetDuration = %.4f",_packetDuration);
  CVLog(BTDFLAG_FILE_STREAM, @"    _processedPacketsCount = %d",_processedPacketsCount);
  CVLog(BTDFLAG_FILE_STREAM, @"_processedPacketsSizeTotal = %d",_processedPacketsSizeTotal);
	return bitRate;
}

- (void)setSeekTime:(double)newSeekTime {
	if ([self calculatedBitRate] == 0.0 || _fileLength <= 0) {
		return;
	}
	
	//
	// Calculate the byte offset for seeking
	//
	_seekByteOffset = _dataOffset +
  (newSeekTime / [self duration]) * (_fileLength - _dataOffset);
  
	//
	// Attempt to leave 1 useful packet at the end of the file (although in
	// reality, this may still seek too far if the file has a long trailer).
	//
  UInt32 packetBufferSize = [self getPacketBufferSize];
	if (_seekByteOffset > _fileLength - 2 * packetBufferSize)
	{
		_seekByteOffset = _fileLength - 2 * packetBufferSize;
	}
	
	//
	// Store the old time from the audio queue and the time that we're seeking
	// to so that we'll know the correct time progress after seeking.
	//
	_seekTime = newSeekTime;
	
	//
	// Attempt to align the seek with a packet boundary
	//
	double calculatedBitRate = [self calculatedBitRate];
	if (_packetDuration > 0 &&
      calculatedBitRate > 0)
	{
		UInt32 ioFlags = 0;
		SInt64 packetAlignedByteOffset;
		SInt64 seekPacket = floor(newSeekTime / _packetDuration);
		OSStatus err = AudioFileStreamSeek(_streamID, seekPacket, &packetAlignedByteOffset, &ioFlags);
		if (!err && !(ioFlags & kAudioFileStreamSeekFlag_OffsetIsEstimated))
		{
			_seekTime -= ((_seekByteOffset - _dataOffset) - packetAlignedByteOffset) * 8.0 / calculatedBitRate;
			_seekByteOffset = packetAlignedByteOffset + _dataOffset;
		}
	}
  
	//
	// Close the current read straem
	//
//	[self close];
//  
//	//
//	// Stop the audio queue
//	//
//	self.state = AS_STOPPING;
//	stopReason = AS_STOPPING_TEMPORARILY;
//	err = AudioQueueStop(audioQueue, true);
//	if (err)
//	{
//		[self failWithErrorCode:AS_AUDIO_QUEUE_STOP_FAILED];
//		return;
//	}
  
	//
	// Re-open the file stream. It will request a byte-range starting at
	// seekByteOffset.
	//
	//[self openReadStream];
}


@end