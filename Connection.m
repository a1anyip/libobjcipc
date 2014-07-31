//
//  libobjcipc
//  Connection.m
//
//  Created by Alan Yip on 6 Feb 2014
//  Copyright 2014 Alan Yip. All rights reserved.
//

#import <objc/runtime.h>
#import "Connection.h"
#import "IPC.h"
#import "Message.h"

// ticks every 10 seconds; then auto disconnect after 6 ticks (1 minute)
// ticks could be reset when there is any activity in socket connection
// (e.g. receive new messages, either end closes connection)
#define OBJCIPC_AUTODISCONNECT_TICKTIME 10.0
#define OBJCIPC_AUTODISCONNECT_TICKS 6

// ensure the handler is executed on main thread
static inline void executeOnMainThread(void (^block)(void)) {
	if (![NSThread isMainThread]) {
		dispatch_sync(dispatch_get_main_queue(), block);
	} else {
		block();
	}
}

static char pendingIncomingMessageNameKey;
static char pendingIncomingMessageIdentifierKey;

@implementation OBJCIPCConnection

- (instancetype)initWithInputStream:(NSInputStream *)inputStream outputStream:(NSOutputStream *)outputStream {
	
	if ((self = [super init])) {
		
		// set delegate
		inputStream.delegate = self;
		outputStream.delegate = self;
		
		// scheudle in run loop
		[inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
		[outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
		
		// open streams
		[inputStream open];
		[outputStream open];
		
		// keep references
		_inputStream = [inputStream retain];
		_outputStream = [outputStream retain];
	}
	
	return self;
}

- (void)sendMessage:(OBJCIPCMessage *)message {
	
	if (_closedConnection) return;
	
	// auto assign the next message identifier
	if (message.messageIdentifier == nil) {
		message.messageIdentifier = [self nextMessageIdentifier];
	}
	
	#if LOG_MESSAGE_BODY
		IPCLOG(@"<Connection> Send message to app with identifier <%@>", self.appIdentifier);
	#else
		IPCLOG(@"<Connection> Send message to app with identifier <%@> <message: %@>", self.appIdentifier, message);
	#endif
	
	OBJCIPCReplyHandler replyHandler = message.replyHandler;
	NSString *messageIdentifier = message.messageIdentifier;
	NSData *data = [message messageData];
	
	if (data == nil) {
		IPCLOG(@"<Connection> Unable to retrieve the message data");
		return;
	}
	
	// set reply handler
	if (replyHandler != nil) {
		if (_replyHandlers == nil) _replyHandlers = [NSMutableDictionary new];
		_replyHandlers[messageIdentifier] = replyHandler;
	}
	
	// append outgoing message data
	if (_outgoingMessageData == nil) _outgoingMessageData = [NSMutableData new];
	[_outgoingMessageData appendData:data];
	
	// write data to the output stream
	[self _writeOutgoingMessageData];
}

- (void)closeConnection {
	
	if (_closedConnection) return;
	_closedConnection = YES;
	
	IPCLOG(@"<Connection> Close connection <%@>", self);
	
	// invalidate the timer
	[self _invalidateAutoDisconnectTimer];
	
	// reset all receiving message state
	[self _resetReceivingMessageState];
	
	// clear delegate
	_inputStream.delegate = nil;
	_outputStream.delegate = nil;
	
	// remove streams from run loop
	[_inputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
	[_inputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
	
	// close streams
	[_inputStream close];
	[_outputStream close];
	
	// release streams
	[_inputStream release], _inputStream = nil;
	[_outputStream release], _outputStream = nil;
	
	// reply nil messages to all reply listener
	if (_replyHandlers != nil && [_replyHandlers count] > 0) {
		for (NSString *key in _replyHandlers) {
			OBJCIPCReplyHandler handler = _replyHandlers[key];
			if (handler != nil) {
				executeOnMainThread(^{
					handler(nil);
				});
			}
		}
	}
	
	[_replyHandlers release], _replyHandlers = nil;
	[_outgoingMessageData release], _outgoingMessageData = nil;
	[_incomingMessageHandlers release], _incomingMessageHandlers = nil;
	[_pendingIncomingMessages release], _pendingIncomingMessages = nil;
	
	// notify the main instance
	[[OBJCIPC sharedInstance] notifyConnectionIsClosed:self];
}

- (void)setIncomingMessageHandler:(OBJCIPCIncomingMessageHandler)handler forMessageName:(NSString *)messageName {
	
	if (messageName == nil) {
		IPCLOG(@"<Connection> Message name cannot be nil when setting incoming message handler");
		return;
	}
	
	if (handler == nil) {
		[_incomingMessageHandlers removeObjectForKey:messageName];
	} else {
		if (_incomingMessageHandlers == nil) _incomingMessageHandlers = [NSMutableDictionary new];
		_incomingMessageHandlers[messageName] = handler;
	}
}

- (OBJCIPCIncomingMessageHandler)incomingMessageHandlerForMessageName:(NSString *)messageName {
	OBJCIPCIncomingMessageHandler appHandler = _incomingMessageHandlers[messageName];
	if (appHandler == nil) {
		return [OBJCIPC sharedInstance].globalIncomingMessageHandlers[messageName];
	} else {
		return appHandler;
	}
}

- (NSString *)nextMessageIdentifier {
	
	if (++_nextMessageIdentifier == 9999) {
		_nextMessageIdentifier = 0; // reset identifier
	}
	
	return [NSString stringWithFormat:@"%04d", (int)_nextMessageIdentifier];
}

- (void)_handshakeWithSpringBoard {
	
	if (_closedConnection) return;
	
	// retrieve the identifier of the current app
	NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];
	
	// prepare a dictionary containing the bundle identifier
	NSDictionary *dict = @{ @"appIdentifier": identifier };
	OBJCIPCMessage *message = [OBJCIPCMessage handshakeMessageWithDictionary:dict];
	
	IPCLOG(@"<Connection> Send handshake message to SpringBoard <app identifier: %@>", identifier);
	
	[self sendMessage:message];
}

- (void)_handshakeWithSpringBoardComplete:(NSDictionary *)dict {
	
	if (_closedConnection) return;
	
	BOOL success = [dict[@"success"] boolValue];
	if (success) {
		
		IPCLOG(@"<Connection> Handshake with SpringBoard succeeded");
		
		// update flag
		_handshakeFinished = YES;
		
		// update app identifier
		self.appIdentifier = SpringBoardIdentifier;
		[[OBJCIPC sharedInstance] notifyConnectionBecomesActive:self];
		
		// dispatch all pending incoming messages to handler
		for (NSDictionary *dictionary in _pendingIncomingMessages) {
			#if LOG_MESSAGE_BODY
				IPCLOG(@"Dispatch a pending incoming message to handler <message: %@>", dictionary);
			#else
				IPCLOG(@"Dispatch a pending incoming message to handler");
			#endif
			[self _dispatchIncomingMessage:dictionary];
		}
		
		[_pendingIncomingMessages release], _pendingIncomingMessages = nil;
		
		// setup auto-disconnect timer
		[self _createAutoDisconnectTimer];
		
	} else {
		IPCLOG(@"<Connection> Handshake with SpringBoard failed");
		// close connection if the handshake fails
		[self closeConnection];
	}
}

- (NSDictionary *)_handshakeWithApp:(NSDictionary *)dict {
	
	if (_closedConnection) return nil;
	
	NSString *appIdentifier = dict[@"appIdentifier"];
	if (appIdentifier == nil || [appIdentifier length] == 0) {
		IPCLOG(@"<Connection> Handshake with app failed (empty app identifier)");
		[self closeConnection];
		return @{ @"success": @(NO) };
	}
	
	IPCLOG(@"<Connection> Handshake with app succeeded <app identifier: %@>", appIdentifier);
	
	// update flag
	_handshakeFinished = YES;
	
	// make the app stay in background
	[OBJCIPC setAppWithIdentifier:appIdentifier inBackground:YES];
	
	// update app identifier
	self.appIdentifier = appIdentifier;
	[[OBJCIPC sharedInstance] notifyConnectionBecomesActive:self];
	
	return @{ @"success": @(YES) };
}

/**
 *  Read incoming message data with the format specified below
 *
 *  [ Header ]
 *  PW (magic number)
 *  0/1 (reply flag)
 *  0000\0 (message identifier, for its reply)
 *  message length (in bytes)
 *
 *  [ Body ]
 *  message data
 */
- (void)_readIncomingMessageData {
	
	if (_closedConnection) return;
	
	if (![_inputStream hasBytesAvailable]) {
		IPCLOG(@"<Connection> Input stream has no bytes available");
		return;
	}
	
	if (!_receivedHeader) {
		
		int headerSize = sizeof(OBJCIPCMessageHeader);
		NSUInteger readLen = MAX(0, headerSize - _receivedHeaderLength);
		uint8_t header[readLen];
		int headerLen = [_inputStream read:header maxLength:readLen];
		_receivedHeaderLength += headerLen;

		// prevent unexpected error when reading from input stream
		if (headerLen <= 0) {
			[self closeConnection];
			return;
		}

		if (_receivedHeaderData == nil) _receivedHeaderData = [NSMutableData new];
		[_receivedHeaderData appendBytes:(const void *)header length:headerLen];
		
		if (_receivedHeaderLength == headerSize) {
			
			// complete header
			OBJCIPCMessageHeader header;
			[_receivedHeaderData getBytes:&header length:sizeof(OBJCIPCMessageHeader)];
			
			char *magicNumber = header.magicNumber;
			if (!(magicNumber[0] == 'P' && magicNumber[1] == 'W')) {
				// unknown message
				[self closeConnection];
				return;
			}
			
			// reply flag
			BOOL isReply = header.replyFlag;
			
			// message name
			NSString *messageName = [[[NSString alloc] initWithCString:header.messageName encoding:NSASCIIStringEncoding] autorelease];
			
			// message identifier
			NSString *messageIdentifier = [[[NSString alloc] initWithCString:header.messageIdentifier encoding:NSASCIIStringEncoding] autorelease];
			
			BOOL isHandshake = NO;
			if ([messageIdentifier isEqualToString:@"00HS"]) { // fixed
				// this is a handshake message
				isHandshake = YES;
			}
			
			// message content length
			int contentLength = header.contentLength;
			
			// header
			_receivedHeader = YES;
			_receivedHeaderLength = 0;
			_isHandshake = isHandshake;
			_isReply = isReply;
			_messageName = [messageName copy];
			_messageIdentifier = [messageIdentifier copy];
			[_receivedHeaderData release], _receivedHeaderData = nil;
			
			// content
			_contentLength = contentLength;
			_receivedContentLength = 0;
			_receivedContentData = [NSMutableData new];
			
			IPCLOG(@"<Connection> Received message header <reply: %@> <identifier: %@> <message name: %@> <%d bytes>", (isReply ? @"YES" : @"NO"), messageIdentifier, messageName, contentLength);
			
		} else {
			// incomplete header
			_receivedHeader = NO;
			return;
		}
	}
	
	// message content
	if (_contentLength > 0) {
		NSUInteger len = MAX(MIN(1024, _contentLength - _receivedContentLength), 0);
		uint8_t buffer[len];
		int receivedLen = [_inputStream read:buffer maxLength:len];
		if (receivedLen > 0) {
			[_receivedContentData appendBytes:(const void *)buffer length:receivedLen];
			_receivedContentLength += receivedLen;
			if (_receivedContentLength == _contentLength) {
				// finish receiving the message
				[self _dispatchReceivedMessage];
			}
		}
	} else {
		// no data to receive because content length is 0 (most likely it is a empty reply)
		[self _dispatchReceivedMessage];
	}
}

- (void)_writeOutgoingMessageData {
	
	if (_closedConnection) return;
	
	NSUInteger length = [_outgoingMessageData length];
	
	if (_outgoingMessageData != nil && length > 0 && [_outputStream hasSpaceAvailable]) {
		
		NSUInteger len = MAX(MIN(1024, length), 0);
		
		// copy the message data to buffer
		uint8_t buf[len];
		memcpy(buf, _outgoingMessageData.bytes, len);
		
		// write to output stream
		NSInteger writtenLen = [_outputStream write:(const uint8_t *)buf maxLength:len];
		
		// error occurs
		if (writtenLen == -1) {
			// close connection
			[self closeConnection];
			return;
		}
		
		if (writtenLen > 0) {
			if ((length - writtenLen) > 0) {
				// trim the data
				NSRange range = NSMakeRange(writtenLen, length - writtenLen);
				NSMutableData *trimmedData = [[_outgoingMessageData subdataWithRange:range] mutableCopy];
				// update buffered outgoing message data
				[_outgoingMessageData release];
				_outgoingMessageData = trimmedData;
			} else {
				// finish writing buffer
				[_outgoingMessageData release], _outgoingMessageData = nil;
			}
		}
	}
}

- (void)_dispatchReceivedMessage {
	
	if (_closedConnection) return;
	
	// flags
	BOOL isHandshake = _isHandshake;
	BOOL isReply = _isReply;
	
	// message name
	NSString *name = _messageName;
	
	// message identifier
	NSString *identifier = _messageIdentifier;
	
	// content length
	int length = _contentLength;
	
	// received data
	NSData *data = _receivedContentData;
	
	// a simple check
	if ([data length] != length) {
		IPCLOG(@"<Connection> Mismatch received data length");
		[self closeConnection];
		return;
	}
	
	// convert the data back to NSDictionary
	NSDictionary *dictionary = (NSDictionary *)[NSKeyedUnarchiver unarchiveObjectWithData:data];
	
	[self retain]; // to prevent self from being released during callback (e.g. deactivateApp)
	
	if (isHandshake) {
		
		#if LOG_MESSAGE_BODY
			IPCLOG(@"<Connection> Handling incoming handshake message <%@>", dictionary);
		#else
			IPCLOG(@"<Connection> Handling incoming handshake message");
		#endif
		
		// pass to internal handler
		if ([OBJCIPC isSpringBoard]) {
			NSDictionary *reply = [self _handshakeWithApp:dictionary];
			if (reply != nil) {
				// send a handshake completion message to app
				OBJCIPCMessage *message = [OBJCIPCMessage handshakeMessageWithDictionary:reply];
				[self sendMessage:message];
			}
		} else {
			[self _handshakeWithSpringBoardComplete:dictionary];
		}
		
	} else if (isReply) {
		
		#if LOG_MESSAGE_BODY
			IPCLOG(@"<Connection> Handling reply message <%@>", dictionary);
		#else
			IPCLOG(@"<Connection> Handling reply message");
		#endif
		
		// find the message reply handler
		OBJCIPCReplyHandler handler = _replyHandlers[identifier];
		if (handler != nil) {
			
			IPCLOG(@"<Connection> Passed the received dictionary to reply handler");
			
			executeOnMainThread(^{
				handler(dictionary);
			});
			
			// release the reply handler
			[_replyHandlers removeObjectForKey:identifier];
		}
		
	} else {
		
		#if LOG_MESSAGE_BODY
			IPCLOG(@"<Connection> Handling incoming message <%@>", dictionary);
		#else
			IPCLOG(@"<Connection> Handling incoming message");
		#endif
		
		// set associated object (message name and identifier)
		objc_setAssociatedObject(dictionary, &pendingIncomingMessageNameKey, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
		objc_setAssociatedObject(dictionary, &pendingIncomingMessageIdentifierKey, identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
		
		if (!_handshakeFinished) {
			// put the incoming message into pending incoming message list
			if (_pendingIncomingMessages == nil) _pendingIncomingMessages = [NSMutableArray new];
			// put it into the list
			[_pendingIncomingMessages addObject:dictionary];
		} else {
			// pass the dictionary to incoming message handler
			// and wait for its reply
			[self _dispatchIncomingMessage:dictionary];
		}
	}
	
	[self _resetReceivingMessageState];
	[self release];
}

- (void)_dispatchIncomingMessage:(NSDictionary *)dictionary {
	
	// get back the name
	NSString *name = objc_getAssociatedObject(dictionary, &pendingIncomingMessageNameKey);
	
	// get back the identifier
	NSString *identifier = objc_getAssociatedObject(dictionary, &pendingIncomingMessageIdentifierKey);
	
	// the reply dictionary
	__block NSDictionary *reply = nil;
	
	// handler
	OBJCIPCIncomingMessageHandler handler = [self incomingMessageHandlerForMessageName:name];
	
	if (handler != nil) {
		IPCLOG(@"<Connection> Pass the received dictionary to incoming message handler");
		executeOnMainThread(^{
			reply = handler(dictionary);
		});
	} else {
		IPCLOG(@"<Connection> No incoming message handler found");
	}
	
	if (!_closedConnection) {
		// send reply as a new message
		OBJCIPCMessage *message = [OBJCIPCMessage outgoingMessageWithMessageName:name dictionary:reply messageIdentifier:identifier isReply:YES replyHandler:nil];
		[self sendMessage:message];
	}
}

- (void)_resetReceivingMessageState {
	
	// header
	_receivedHeader = NO;
	_receivedHeaderLength = 0;
	_isHandshake = NO;
	_isReply = NO;
	[_messageName release], _messageName = nil;
	[_messageIdentifier release], _messageIdentifier = nil;
	[_receivedHeaderData release], _receivedHeaderData = nil;
	
	// content
	_contentLength = 0;
	_receivedContentLength = 0;
	[_receivedContentData release], _receivedContentData = nil;
}

- (void)_createAutoDisconnectTimer {
	if (_autoDisconnectTimer == nil) {
		// ticks every minute
		_autoDisconnectTimer = [[NSTimer scheduledTimerWithTimeInterval:OBJCIPC_AUTODISCONNECT_TICKTIME target:self selector:@selector(_autoDisconnectTimerTicks) userInfo:nil repeats:YES] retain];
	}
}

- (void)_autoDisconnectTimerTicks {
	@synchronized(self) {
		_autoDisconnectTimerTicks++;
		IPCLOG(@"<Connection> Auto disconnect timer ticks (%d)", (int)_autoDisconnectTimerTicks);
		if (_autoDisconnectTimerTicks == OBJCIPC_AUTODISCONNECT_TICKS) {
			[self _triggerAutoDisconnect];
		}
	}
}

- (void)_resetAutoDisconnectTimer {
	IPCLOG(@"<Connection> Reset auto disconnect timer");
	@synchronized(self) {
		_autoDisconnectTimerTicks = 0;
	}
}

- (void)_triggerAutoDisconnect {
	IPCLOG(@"<Connection> Trigger auto disconnect");
	[OBJCIPC deactivate];
}

- (void)_invalidateAutoDisconnectTimer {
	if (_autoDisconnectTimer != nil) {
		[_autoDisconnectTimer invalidate];
		[_autoDisconnectTimer release];
		_autoDisconnectTimer = nil;
		IPCLOG(@"<Connection> Auto disconnect timer is invalidated");
	}
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
	
	// reset auto disconnect timer whenever there's a socket event
	[self _resetAutoDisconnectTimer];
	
	switch(event) {
			
		case NSStreamEventNone:
		case NSStreamEventOpenCompleted:
			break;
			
		case NSStreamEventHasSpaceAvailable:
			IPCLOG(@"<Connection> NSStreamEventHasSpaceAvailable: %@", stream);
			if (stream == _outputStream) {
				// write queued messages
				[self _writeOutgoingMessageData];
			}
			break;
			
		case NSStreamEventHasBytesAvailable:
			IPCLOG(@"<Connection> NSStreamEventHasBytesAvailable: %@", stream);
			if (stream == _inputStream) {
				// read incoming messages
				[self _readIncomingMessageData];
			}
			break;
			
		case NSStreamEventErrorOccurred:
			IPCLOG(@"<Connection> NSStreamEventErrorOccurred: %@", stream);
			[self closeConnection];
			break;
			
		case NSStreamEventEndEncountered:
			IPCLOG(@"<Connection> NSStreamEventEndEncountered: %@", stream);
			[self closeConnection];
			break;
	}
}

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@ %p> <App identifier: %@> <Reply handlers: %d>", [self class], self, _appIdentifier, (int)[_replyHandlers count]];
}

- (void)dealloc {
	
	// just in case the connection is not closed yet
	// normally, a connection instance gets released only when its connection was closed
	[self closeConnection];
	
	// this is for OBJCIPC to identify this connection
	// so release it only when the connection gets released
	[_appIdentifier release], _appIdentifier = nil;
	
	[super dealloc];
}

@end
