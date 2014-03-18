//
//  libobjcipc
//  Message.m
//
//  Created by Alan Yip on 6 Feb 2014
//  Copyright 2014 Alan Yip. All rights reserved.
//

#import "Message.h"

@implementation OBJCIPCMessage

+ (instancetype)handshakeMessageWithDictionary:(NSDictionary *)dictionary {
	
	OBJCIPCMessage *message = [self new];
	message.isReply = NO; // fixed
	message.messageName = @"OBJCIPC.HANDSHAKE";
	message.messageIdentifier = @"00HS"; // fixed
	message.replyHandler = nil;
	message.dictionary = dictionary;
	
	return [message autorelease];
}

+ (instancetype)outgoingMessageWithMessageName:(NSString *)messageName dictionary:(NSDictionary *)dictionary messageIdentifier:(NSString *)messageIdentifier isReply:(BOOL)isReply replyHandler:(OBJCIPCReplyHandler)handler {
	
	OBJCIPCMessage *message = [self new];
	message.isReply = isReply;
	message.messageName = messageName;
	message.messageIdentifier = messageIdentifier;
	message.replyHandler = handler;
	message.dictionary = dictionary;
	
	return [message autorelease];
}

- (NSData *)messageData {
	
	if (_messageName == nil)
		_messageName = @"";
	
	if (_messageIdentifier == nil)
		_messageIdentifier = @"";
	
	const char *messageName = [_messageName cStringUsingEncoding:NSASCIIStringEncoding];
	const char *messageIdentifier = [_messageIdentifier cStringUsingEncoding:NSASCIIStringEncoding];
	
	// check message identifier
	if (strlen(messageIdentifier) != 4) {
		IPCLOG(@"<Message> Message identifier must be 4 characters");
		return nil;
	}
	
	// check message identifier
	if (strlen(messageName) > 255) {
		IPCLOG(@"<Message> Length of message name must be shorter or equal to 255.");
		return nil;
	}
	
	NSMutableData *data = [NSMutableData data];
	
	// convert NSDictionary to NSData
	NSData *content = [NSKeyedArchiver archivedDataWithRootObject:_dictionary];
	if (content == nil) content = [NSData data];
	
	// construct message header
	OBJCIPCMessageHeader header;
	strncpy(header.magicNumber, [@"PW" cStringUsingEncoding:NSASCIIStringEncoding], 3);
	header.replyFlag = _isReply;
	strncpy(header.messageName, messageName, 256);
	strncpy(header.messageIdentifier, messageIdentifier, 5);
	header.contentLength = (int)[content length];
	
	// append message header
	NSData *headerData = [NSData dataWithBytes:&header length:sizeof(OBJCIPCMessageHeader)];
	[data appendData:headerData];
	
	// append message content
	[data appendData:content];
	
	return data;
}

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@ %p> <Message name: %@> <Message identifier: %@> <Reply: %@> <Dictionary: %@>", [self class], self, _messageName, _messageIdentifier, (_isReply ? @"YES" : @"NO"), _dictionary];
}

- (void)dealloc {
	[_messageIdentifier release], _messageIdentifier = nil;
	[_replyHandler release], _replyHandler = nil;
	[_messageName release], _messageName = nil;
	[_dictionary release], _dictionary = nil;
	[super dealloc];
}

@end