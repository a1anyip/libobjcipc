//
//  libobjcipc
//  IPC.m
//
//  Created by Alan Yip on 6 Feb 2014
//  Copyright 2014 Alan Yip. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <xpc/xpc.h>
#import "dlfcn.h"
#import "substrate.h"
#import "interface.h"
#import "IPC.h"
#import "pid.h"
#import "Connection.h"
#import "Message.h"

// to enable process assertions in SpringBoard
static BOOL (*orignal_XPCConnectionHasEntitlement)(xpc_connection_t connection, NSString *entitlement);
static inline BOOL replaced_XPCConnectionHasEntitlement(xpc_connection_t connection, NSString *entitlement) {
	
	IPCLOG(@"_XPCConnectionHasEntitlement <entitlement: %@>", entitlement);
	
	if ([entitlement isEqualToString:@"com.apple.multitasking.unlimitedassertions"]) {
		
		// override the original result
		if (xpc_connection_get_pid(connection) == pidForProcess(@"SpringBoard"))
			return YES;
	}
	
	return orignal_XPCConnectionHasEntitlement(connection, entitlement);
}

static inline void socketServerCallback(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
	
	if (type == kCFSocketAcceptCallBack) {
		
		// cast data to socket native handle
		CFSocketNativeHandle nativeSocketHandle = *(CFSocketNativeHandle *)data;
		
		// create pair with incoming socket handle
		[[OBJCIPC sharedInstance] _createPairWithAppSocket:nativeSocketHandle];
	}
}

static OBJCIPC *sharedInstance = nil;

@implementation OBJCIPC

+ (void)load {
	
	if ([self isBackBoard]) {
		
		// load the library
		dlopen(XPCObjects, RTLD_LAZY);
		// replace the function
		MSHookFunction(((int *)MSFindSymbol(NULL, "_XPCConnectionHasEntitlement")), (int *)replaced_XPCConnectionHasEntitlement, (void **)&orignal_XPCConnectionHasEntitlement);
		
	} else if ([self isSpringBoard]) {
		
		// activate OBJCIPC automatically in SpringBoard
		[self activate];
		
	} else if ([self isApp]) {
		
		// the notification sent from SpringBoard will activate OBJCIPC in the running
		// and active app with the specified bundle identifier automatically
		[self _setupAppActivationListener];
		
		// the notification sent from SpringBoard will deactivate OBJCIPC in the running
		// and active app with the specified bundle identifier automatically
		[self _setupAppDeactivationListener];
	} else {
		// Daemon or other process with no bundle identifier.
	}
}

+ (BOOL)isSpringBoard {
	
	static BOOL queried = NO;
	static BOOL result = NO;
	
	if (!queried) {
		queried = YES;
		result = objc_getClass("SpringBoard") != nil;
	}
	
	return result;
}

+ (BOOL)isBackBoard {
	
	static BOOL queried = NO;
	static BOOL result = NO;
	
	if (!queried) {
		queried = YES;
		result = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.backboardd"];
	}
	
	return result;
}

+ (BOOL)isApp {
	return ![self isSpringBoard] && ![self isBackBoard] && [[NSBundle mainBundle] bundleIdentifier];
}

+ (instancetype)sharedInstance {
	
	@synchronized(self) {
		if (sharedInstance == nil)
			[self new];
	}
	
	return sharedInstance;
}

+ (id)allocWithZone:(NSZone *)zone {
	
	@synchronized(self) {
		if (sharedInstance == nil) {
			sharedInstance = [super allocWithZone:zone];
			return sharedInstance;
		}
	}
	
	return nil;
}

+ (void)activate {
	
	OBJCIPC *ipc = [self sharedInstance];
	if (ipc.activated) return; // only activate once
	
	IPCLOG(@"Activating OBJCIPC");
	
	if ([self isSpringBoard]) {
	
		// create socket server in SpringBoard
		ipc.serverPort = [ipc _createSocketServer];
		
		// write the server port to preference file
		NSMutableDictionary *pref = [NSMutableDictionary dictionaryWithContentsOfFile:PrefPath];
		if (pref == nil) pref = [NSMutableDictionary dictionary];
		pref[@"serverPort"] = @(ipc.serverPort);
		[pref writeToFile:PrefPath atomically:YES];
		
	} else if ([self isApp]) {
		
		// register event handlers
		[[NSNotificationCenter defaultCenter] addObserver:ipc selector:@selector(_deactivateApp) name:UIApplicationWillTerminateNotification object:nil]; // close connection whenever the app is terminated (to notify SpringBoard)
		
		// get the port number of socket server in SpringBoard
		NSDictionary *pref = [NSDictionary dictionaryWithContentsOfFile:PrefPath];
		NSNumber *port = pref[@"serverPort"];
		
		if (port == nil) {
			IPCLOG(@"Unable to retrieve server port from preference file");
			return;
		}
		
		ipc.serverPort = [port unsignedIntegerValue];
		
		IPCLOG(@"Retrieved SpringBoard server port: %u", (unsigned int)ipc.serverPort);
		
		// make a persistent connection to SpringBoard
		[ipc _connectToSpringBoard];
	}
	
	// update the activated flag
	ipc.activated = YES;
}

+ (void)deactivate {
	
	if (![self isApp]) {
		IPCLOG(@"You can only deactivate OBJCIPC in app");
		return;
	}
	
	OBJCIPC *ipc = [self sharedInstance];
	if (!ipc.activated) return; // not activated yet
	
	IPCLOG(@"Deactivating OBJCIPC");
	
	// close all connections (normally only with SpringBoard)
	for (OBJCIPCConnection *connection in ipc.pendingConnections) {
		[connection closeConnection];
	}
	
	NSMutableDictionary *activeConnections = ipc.activeConnections;
	for (NSString *identifier in activeConnections) {
		OBJCIPCConnection *connection = [activeConnections objectForKey:identifier];
		[connection closeConnection];
	}
	
	// release all pending and active connections
	ipc.pendingConnections = nil;
	ipc.activeConnections = nil;
	
	// reset all other instance variables
	ipc.serverPort = 0;
	ipc.outgoingMessageQueue = nil;
	
	// update the activated flag
	ipc.activated = NO;
	
	// remove all event handlers
	[[NSNotificationCenter defaultCenter] removeObserver:ipc];
}

+ (void)deactivateAppWithIdentifier:(NSString *)identifier {
	[self _sendDeactivationNotificationToAppWithIdentifier:identifier];
}

+ (BOOL)launchAppWithIdentifier:(NSString *)identifier stayInBackground:(BOOL)stayInBackground {
	
	if (![self isSpringBoard]) {
		IPCLOG(@"You can only launch app in SpringBoard");
		return NO;
	}
	
	IPCLOG(@"Launch app with identifier <%@>", identifier);
	
	// launch the app
	SpringBoard *app = (SpringBoard *)[UIApplication sharedApplication];
	
	SBApplicationController *controller = [objc_getClass("SBApplicationController") sharedInstance];
	SBApplication *application = [controller applicationWithDisplayIdentifier:identifier];
	
	if (application == nil) {
		IPCLOG(@"App with identifier <%@> cannot be found", identifier);
		return NO;
	}
	
	if ([application suspendingUnsupported]) {
		IPCLOG(@"App with identifier <%@> does not support suspending", identifier);
		return NO;
	}
	
	if (![application isRunning]) {
	
		__block BOOL launchSuccess;
		dispatch_block_t block = ^{
			launchSuccess = [app launchApplicationWithIdentifier:identifier suspended:YES];
		};
		
		// ensure the app is launched in main thread (or an exception will be rasied)
		if (![NSThread isMainThread]) {
			dispatch_sync(dispatch_get_main_queue(), block);
		} else {
			block();
		}
		
		if (!launchSuccess) {
			IPCLOG(@"Launching app with identifier <%@> fails", identifier);
			return NO;
		}
	}
	
	// make it stay in background
	BOOL assertionSuccess = [self setAppWithIdentifier:identifier inBackground:stayInBackground];
	if (!assertionSuccess) return NO;
	
	return YES;
}

+ (BOOL)setAppWithIdentifier:(NSString *)identifier inBackground:(BOOL)inBackground {
	
	if (![self isSpringBoard]) {
		IPCLOG(@"You can only set app in background in SpringBoard");
		return NO;
	}
	
	if (identifier == nil) {
		IPCLOG(@"App identifier cannot be nil when setting app in background");
		return NO;
	}
	
	IPCLOG(@"Set app with identifier <%@> in background <%@>", identifier, (inBackground ? @"YES" : @"NO"));
	
	OBJCIPC *ipc = [self sharedInstance];
	
	if (ipc.processAssertions == nil) {
		ipc.processAssertions = [NSMutableDictionary dictionary];
	}
	
	NSMutableDictionary *processAssertions = ipc.processAssertions;
	
	// setup process assertion
	if (inBackground) {
		
		BKSProcessAssertion *currentAssertion = processAssertions[identifier];
		if (currentAssertion != nil && currentAssertion.valid) return YES;
		
		// remove the previous assertion (maybe it is now invalid)
		[processAssertions removeObjectForKey:identifier];
		
		// set the flags
		ProcessAssertionFlags flags = ProcessAssertionFlagPreventSuspend | ProcessAssertionFlagPreventThrottleDownCPU | ProcessAssertionFlagAllowIdleSleep | ProcessAssertionFlagWantsForegroundResourcePriority;
		
		// create a new process assertion
		BKSProcessAssertion *processAssertion = [[objc_getClass("BKSProcessAssertion") alloc] initWithBundleIdentifier:identifier flags:flags reason:kProcessAssertionReasonBackgroundUI name:identifier withHandler:^(BOOL valid) {
			
			if (!valid) {
				
				// unable to create process assertion
				// one of the reasons is that the app with specified bundle identifier does not exist
				IPCLOG(@"Process assertion is invalid");
				
				// remove active connection, if any
				OBJCIPCConnection *activeConnection = [ipc activeConnectionWithAppWithIdentifier:identifier];
				if (activeConnection != nil) {
					[ipc removeConnection:activeConnection];
				}
				
				// send nil replies to all handler
				NSArray *queuedMessages = ipc.outgoingMessageQueue[identifier];
				if (queuedMessages != nil) {
					for (OBJCIPCMessage *message in queuedMessages) {
						OBJCIPCReplyHandler handler = message.replyHandler;
						if (handler != nil) {
							// ensure the handler is executed on main thread
							if (![NSThread isMainThread]) {
								dispatch_sync(dispatch_get_main_queue(), ^{
									handler(nil);
								});
							} else {
								handler(nil);
							}
						}
					}
				}
				
				// to make sure its process assertion is invalidated and removed
				[self setAppWithIdentifier:identifier inBackground:NO];
			}
		}];
		processAssertions[identifier] = processAssertion;
		[processAssertion release];
		
		IPCLOG(@"objcipc: Created process assertion: %@", processAssertion);
		
	} else {
		
		// keep a copy before the connection is released
		NSString *appIdentifier = [identifier copy];
		
		// close connection with the app
		OBJCIPCConnection *connection = ipc.activeConnections[identifier];
		if (connection != nil) {
			[ipc removeConnection:connection];
		}
		
		BKSProcessAssertion *processAssertion = processAssertions[appIdentifier];
		
		if (processAssertion != nil) {
			IPCLOG(@"objcipc: Invalidate process assertion: %@", processAssertion);
			// invalidate the assertion
			[processAssertion invalidate];
			// remove the current process assertion
			[processAssertions removeObjectForKey:appIdentifier];
		}
		
		[appIdentifier release];
	}
	
	return YES;
}

+ (BOOL)sendMessageToAppWithIdentifier:(NSString *)identifier messageName:(NSString *)messageName dictionary:(NSDictionary *)dictionary replyHandler:(OBJCIPCReplyHandler)handler {
	
	IPCLOG(@"Current thread: %@ <is main thread: %d>", [NSThread currentThread], (int)[NSThread isMainThread]);
	
	if (![NSThread isMainThread]) {
		IPCLOG(@"You must send messages on main thread <current thread: %@>", [NSThread currentThread]);
		return NO;
	}
	
	if (![self isSpringBoard] && ![identifier isEqualToString:SpringBoardIdentifier]) {
		IPCLOG(@"You must send messages to app <%@> in SpringBoard", identifier);
		return NO;
	}
	
	if (identifier == nil) {
		IPCLOG(@"App identifier cannot be nil");
		return NO;
	}
	
	if (messageName == nil) {
		IPCLOG(@"Message name cannot be nil");
		return NO;
	}
	
	if ([self isSpringBoard]) {
		
		// launch the app if needed
		// and make sure the app stay in background
		BOOL success = [self launchAppWithIdentifier:identifier stayInBackground:YES];
		if (!success) return NO;
		
		// send an activation notification to the app
		// this is for the situation that the app closed the connection manually with SpringBoard server
		// and SpringBoard wants to connect with it again
		// (as socket connection is unavailable so use notification to activate the connection again)
		[self _sendActivationNotificationToAppWithIdentifier:identifier];
		
	} else {
		
		// activate OBJCIPC in app
		// OBJCIPC will be activated in app automatically when a message is sent from the app to SpringBoard
		[self activate];
	}
	
	IPCLOG(@"Ready to send message to app with identifier <%@> <message name: %@> <dictionary: %@>", identifier, messageName, dictionary);
	
	OBJCIPC *ipc = [self sharedInstance];
	
	// construct an outgoing message
	// message identifier will be assigned in OBJCIPCConnection
	OBJCIPCMessage *message = [OBJCIPCMessage outgoingMessageWithMessageName:messageName dictionary:dictionary messageIdentifier:nil isReply:NO replyHandler:handler];
	[ipc queueOutgoingMessage:message forAppWithIdentifier:identifier];
	
	return YES;
}

+ (BOOL)sendMessageToSpringBoardWithMessageName:(NSString *)messageName dictionary:(NSDictionary *)dictionary replyHandler:(OBJCIPCReplyHandler)replyHandler {
	
	if (![self isApp]) {
		IPCLOG(@"You must send messages to SpringBoard in app");
		return NO;
	}
	
	return [self sendMessageToAppWithIdentifier:SpringBoardIdentifier messageName:messageName dictionary:dictionary replyHandler:replyHandler];
}

+ (NSDictionary *)sendMessageToAppWithIdentifier:(NSString *)identifier messageName:(NSString *)messageName dictionary:(NSDictionary *)dictionary {
	
	__block BOOL received = NO;
	__block NSDictionary *reply = nil;
	
	BOOL success = [self sendMessageToAppWithIdentifier:identifier messageName:messageName dictionary:dictionary replyHandler:^(NSDictionary *dictionary) {
		received = YES;
		reply = [dictionary copy]; // must keep a copy in stack
	}];
	
	if (!success) return nil;
	
	// this loop is to wait until the reply arrives or the connection is closed (reply with nil value)
	while (!received) {
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, YES); // 1000 ms
	}
	
	return [reply autorelease];
}

+ (NSDictionary *)sendMessageToSpringBoardWithMessageName:(NSString *)messageName dictionary:(NSDictionary *)dictionary {
	
	if (![self isApp]) {
		IPCLOG(@"You must send messages to SpringBoard in app");
		return nil;
	}
	
	return [self sendMessageToAppWithIdentifier:SpringBoardIdentifier messageName:messageName dictionary:dictionary];
}

+ (void)registerIncomingMessageFromAppHandlerForMessageName:(NSString *)messageName handler:(OBJCIPCIncomingMessageHandler)handler {
	[self registerIncomingMessageHandlerForAppWithIdentifier:nil andMessageName:messageName handler:handler];
}

+ (void)unregisterIncomingMessageFromAppHandlerForMessageName:(NSString *)messageName {
	[self unregisterIncomingMessageHandlerForAppWithIdentifier:nil andMessageName:messageName];
}

+ (void)registerIncomingMessageHandlerForAppWithIdentifier:(NSString *)identifier andMessageName:(NSString *)messageName handler:(OBJCIPCIncomingMessageHandler)handler {
	
	if (messageName == nil) {
		IPCLOG(@"Message name cannot be nil when setting incoming message handler");
		return;
	}
	
	// activate OBJCIPC
	// OBJCIPC will be activated in app automatically when the app registers an incoming message handler
	[self activate];
	
	IPCLOG(@"Register incoming message handler for app with identifier <%@> and message name <%@>", identifier, messageName);
	
	OBJCIPC *ipc = [self sharedInstance];
	OBJCIPCConnection *connection = [ipc activeConnectionWithAppWithIdentifier:identifier];
	
	if (ipc.incomingMessageHandlers == nil) {
		ipc.incomingMessageHandlers = [NSMutableDictionary dictionary];
	}
	
	if (ipc.globalIncomingMessageHandlers == nil) {
		ipc.globalIncomingMessageHandlers = [NSMutableDictionary dictionary];
	}
	
	NSMutableDictionary *incomingMessageHandlers = ipc.incomingMessageHandlers;
	NSMutableDictionary *globalIncomingMessageHandlers = ipc.globalIncomingMessageHandlers;
	
	// copy the handler block
	handler = [[handler copy] autorelease];
	
	// save the handler
	if (identifier == nil) {
		
		if (handler != nil) {
			globalIncomingMessageHandlers[messageName] = handler;
		} else {
			[globalIncomingMessageHandlers removeObjectForKey:messageName];
		}
		
	} else {
		
		if (handler != nil) {
			
			if (incomingMessageHandlers[identifier] == nil) {
				incomingMessageHandlers[identifier] = [NSMutableDictionary dictionary];
			}
			
			NSMutableDictionary *incomingMessageHandlersForApp = incomingMessageHandlers[identifier];
			incomingMessageHandlersForApp[messageName] = handler;
			
		} else {
			// remove handler for a specific app identifier and message name
			NSMutableDictionary *incomingMessageHandlersForApp = incomingMessageHandlers[identifier];
			[incomingMessageHandlersForApp removeObjectForKey:messageName];
		}
		
		if (connection != nil) {
			// update handler in the active connection
			[connection setIncomingMessageHandler:handler forMessageName:messageName];
		}
	}
}

+ (void)unregisterIncomingMessageHandlerForAppWithIdentifier:(NSString *)identifier andMessageName:(NSString *)messageName {
	[self registerIncomingMessageHandlerForAppWithIdentifier:identifier andMessageName:messageName handler:nil];
}

+ (void)registerIncomingMessageFromSpringBoardHandlerForMessageName:(NSString *)messageName handler:(OBJCIPCIncomingMessageHandler)handler {
	[self registerIncomingMessageHandlerForAppWithIdentifier:SpringBoardIdentifier andMessageName:messageName handler:handler];
}

+ (void)unregisterIncomingMessageFromSpringBoardHandlerForMessageName:(NSString *)messageName {
	[self registerIncomingMessageFromSpringBoardHandlerForMessageName:messageName handler:nil];
}

#define TEST_MESSAGE_NAME @"test.message.name"

+ (void)registerTestIncomingMessageHandlerForAppWithIdentifier:(NSString *)identifier {
	OBJCIPCIncomingMessageHandler handler = ^NSDictionary *(NSDictionary *dictionary) {
		//[self deactivate];
		IPCLOG(@"Received test incoming message <%@>", dictionary);
		return @{ @"testReplyKey": @"testReplyValue" };
	};
	[self registerIncomingMessageHandlerForAppWithIdentifier:identifier andMessageName:TEST_MESSAGE_NAME handler:handler];
}

+ (void)registerTestIncomingMessageHandlerForSpringBoard {
	[self registerTestIncomingMessageHandlerForAppWithIdentifier:SpringBoardIdentifier];
}

+ (void)sendAsynchronousTestMessageToAppWithIdentifier:(NSString *)identifier {
	NSDictionary *dict = @{ @"testKey": @"testValue" };
	NSDate *start = [NSDate date];
	OBJCIPCReplyHandler handler = ^(NSDictionary *dictionary) {
		NSTimeInterval time = [[NSDate date] timeIntervalSinceDate:start];
		IPCLOG(@"Received asynchronous test reply <%@>", dictionary);
		IPCLOG(@"Asynchronous message delivery spent ~%.4f ms", time * 1000);
	};
	[self sendMessageToAppWithIdentifier:identifier messageName:TEST_MESSAGE_NAME dictionary:dict replyHandler:handler];
}

+ (void)sendAsynchronousTestMessageToSpringBoard {
	[self sendAsynchronousTestMessageToAppWithIdentifier:SpringBoardIdentifier];
}

+ (NSDictionary *)sendSynchronousTestMessageToAppWithIdentifier:(NSString *)identifier {
	NSDictionary *dict = @{ @"testKey": @"testValue" };
	NSDate *start = [NSDate date];
	NSDictionary *reply = [self sendMessageToAppWithIdentifier:identifier messageName:TEST_MESSAGE_NAME dictionary:dict];
	NSTimeInterval time = [[NSDate date] timeIntervalSinceDate:start];
	IPCLOG(@"Received synchronous test reply <%@>", reply);
	IPCLOG(@"Synchronous message delivery spent ~%.4f ms", time * 1000);
	return reply;
}

+ (NSDictionary *)sendSynchronousTestMessageToSpringBoard {
	return [self sendSynchronousTestMessageToAppWithIdentifier:SpringBoardIdentifier];
}

- (OBJCIPCConnection *)activeConnectionWithAppWithIdentifier:(NSString *)identifier {
	return _activeConnections[identifier];
}

- (void)addPendingConnection:(OBJCIPCConnection *)connection {
	if (_pendingConnections == nil) _pendingConnections = [NSMutableSet new];
	if (![_pendingConnections containsObject:connection]) {
		[_pendingConnections addObject:connection];
	}
}

- (void)notifyConnectionBecomesActive:(OBJCIPCConnection *)connection {
	
	NSString *appIdentifier = connection.appIdentifier;
	if (appIdentifier == nil) {
		IPCLOG(@"App identifier cannot be nil");
		return;
	}
	
	if (_activeConnections[appIdentifier] != nil) {
		IPCLOG(@"The connection is already active");
		return;
	}
	
	IPCLOG(@"Connection becomes active <%@>", connection);
	
	if (_activeConnections == nil) _activeConnections = [NSMutableDictionary new];
	
	// add it to the active connection list
	_activeConnections[appIdentifier] = connection;
	
	// remove it from the pending connection list
	[_pendingConnections removeObject:connection];
	
	// set its incoming message handler
	NSDictionary *handlers = _incomingMessageHandlers[appIdentifier];
	if (handlers != nil) {
		for (NSString *messageName in handlers) {
			OBJCIPCIncomingMessageHandler handler = handlers[messageName];
			[connection setIncomingMessageHandler:handler forMessageName:messageName];
		}
	}
	
	// pass the queued messages to the active connection
	NSArray *queuedMessages = _outgoingMessageQueue[appIdentifier];
	if (queuedMessages != nil && [queuedMessages count] > 0) {
		
		// pass the queued messages to the connection one by one
		for (OBJCIPCMessage *message in queuedMessages) {
			IPCLOG(@"Pass a queued message to the active connection <message: %@>", message);
			// send the message
			[connection sendMessage:message];
		}
		
		// remove the message queue
		[_outgoingMessageQueue removeObjectForKey:appIdentifier];
	}
}

- (void)notifyConnectionIsClosed:(OBJCIPCConnection *)connection {
	
	IPCLOG(@"Connection is closed <%@>", connection);
	
	NSString *appIdentifier = connection.appIdentifier;
	if (appIdentifier != nil && [self.class isSpringBoard]) {
		// remove the app from background
		// this will also call removeConnection
		[self.class setAppWithIdentifier:appIdentifier inBackground:NO];
	} else {
		// remove connection
		[self removeConnection:connection];
	}
}

- (void)removeConnection:(OBJCIPCConnection *)connection {
	
	IPCLOG(@"Remove connection <%@>", connection);
	
	if ([_pendingConnections containsObject:connection]) {
		// remove it from the pending connection list
		[_pendingConnections removeObject:connection];
	} else {
		// remove it from the active connection list
		NSString *identifier = connection.appIdentifier;
		if (identifier != nil) {
			IPCLOG(@"objcipc: Remove active connection <key: %@>", identifier);
			[_activeConnections removeObjectForKey:identifier];
		}
	}
}

- (void)queueOutgoingMessage:(OBJCIPCMessage *)message forAppWithIdentifier:(NSString *)identifier {
	
	if (identifier == nil) {
		IPCLOG(@"App identifier cannot be nil");
		return;
	}
	
	OBJCIPCConnection *activeConnection = [self activeConnectionWithAppWithIdentifier:identifier];
	
	if (activeConnection == nil) {
		
		if (_outgoingMessageQueue == nil) {
			_outgoingMessageQueue = [NSMutableDictionary new];
		}
		
		// the connection with the app is not ready yet
		// so queue it up first
		NSMutableArray *existingQueue = _outgoingMessageQueue[identifier];
		
		// create a new queue for the given app identifier if it does not exist
		if (existingQueue == nil) existingQueue = [NSMutableArray array];
		
		// queue up the new outgoing message
		[existingQueue addObject:message];
		
		// update the queue
		_outgoingMessageQueue[identifier] = existingQueue;
		
	} else {
		
		// the connection with the app is ready
		// redirect the message to the active connection
		[activeConnection sendMessage:message];
	}
}

- (NSUInteger)_createSocketServer {
	
	if (![self.class isSpringBoard]) {
		IPCLOG(@"Socket server can only be created in SpringBoard");
		return 0;
	}
	
	// create socket server
	CFSocketRef socket = CFSocketCreate(NULL, AF_INET, SOCK_STREAM, IPPROTO_TCP, kCFSocketAcceptCallBack, &socketServerCallback, NULL);
	
	if (socket == NULL) {
		IPCLOG(@"Fail to create socket server");
		return 0;
	}
	
	int yes = 1;
	setsockopt(CFSocketGetNative(socket), SOL_SOCKET, SO_REUSEADDR, (void *)&yes, sizeof(yes));
	
	// setup socket address
	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_len = sizeof(addr);
	addr.sin_family = AF_INET;
	addr.sin_port = htons(0);
	addr.sin_addr.s_addr = inet_addr("127.0.0.1");
	
	CFDataRef addrData = (__bridge CFDataRef)[NSData dataWithBytes:&addr length:sizeof(addr)];
	if (CFSocketSetAddress(socket, addrData) != kCFSocketSuccess) {
		IPCLOG(@"Fail to bind local address to socket server");
		CFSocketInvalidate(socket);
		CFRelease(socket);
		return 0;
	}
	
	// retrieve port number
	NSUInteger port = ntohs(((const struct sockaddr_in *)CFDataGetBytePtr(CFSocketCopyAddress(socket)))->sin_port);
	
	// configure run loop
	CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(NULL, socket, 0);
	CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
	CFRelease(source);
	
	IPCLOG(@"Created socket server successfully <port: %u>", (unsigned int)port);
	
	return port;
}

- (void)_createPairWithAppSocket:(CFSocketNativeHandle)handle {
	
	IPCLOG(@"Creating pair with incoming socket connection from app");
	
	// setup pair and streams for incoming conneciton
	CFReadStreamRef readStream = NULL;
	CFWriteStreamRef writeStream = NULL;
	
	CFStreamCreatePairWithSocket(kCFAllocatorDefault, handle, &readStream, &writeStream);
	
	if (readStream == NULL || writeStream == NULL) {
		IPCLOG(@"Unable to create read and write streams");
		return;
	}
	
	IPCLOG(@"Created pair with incoming socket connection");
	
	NSInputStream *inputStream = (NSInputStream *)readStream;
	NSOutputStream *outputStream = (NSOutputStream *)writeStream;
	
	// create a new connection instance with the connected socket streams
	OBJCIPCConnection *connection = [[OBJCIPCConnection alloc] initWithInputStream:inputStream outputStream:outputStream];
	
	// it will become active after handshake with SpringBoard
	[self addPendingConnection:connection];
	[connection release];
}

- (void)_connectToSpringBoard {
	
	IPCLOG(@"Connecting to SpringBoard server at port %u", (unsigned int)_serverPort);
	
	// setup a new connection to socket server in SpringBoard
	CFReadStreamRef readStream = NULL;
	CFWriteStreamRef writeStream = NULL;
	CFStreamCreatePairWithSocketToHost(NULL, CFSTR("127.0.0.1"), _serverPort, &readStream, &writeStream);
	
	if (readStream == NULL || writeStream == NULL) {
		IPCLOG(@"Unable to create read and write streams");
		return;
	}
	
	IPCLOG(@"Connected to SpringBoard server");
	
	NSInputStream *inputStream = (NSInputStream *)readStream;
	NSOutputStream *outputStream = (NSOutputStream *)writeStream;
	
	// create a new connection with SpringBoard
	OBJCIPCConnection *connection = [[OBJCIPCConnection alloc] initWithInputStream:inputStream outputStream:outputStream];
	connection.appIdentifier = SpringBoardIdentifier;
	
	// it will become active after handshake with SpringBoard
	[self addPendingConnection:connection];
	[connection release];
	
	// ask the connection to do handshake with SpringBoard
	[connection _handshakeWithSpringBoard];
}

+ (void)_setupAppActivationListener {
	// Before this notification is sent, a process assertion will be applied to the app
	// so normally the notification could activate OBJCIPC in the app immediately
	NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
	NSString *object = [[NSBundle mainBundle] bundleIdentifier];
	if (object != nil) {
		[center addObserver:self selector:@selector(_appActivationHandler) name:OBJCIPCActivateAppNotification object:object suspensionBehavior:NSNotificationSuspensionBehaviorCoalesce];
	}
}

+ (void)_setupAppDeactivationListener {
	// Before this notification is sent, a process assertion will be applied to the app
	// so normally the notification could activate OBJCIPC in the app immediately
	NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
	NSString *object = [[NSBundle mainBundle] bundleIdentifier];
	if (object != nil) {
		[center addObserver:self selector:@selector(_appDeactivationHandler) name:OBJCIPCDeactivateAppNotification object:object suspensionBehavior:NSNotificationSuspensionBehaviorDrop];
	}
}

+ (void)_sendActivationNotificationToAppWithIdentifier:(NSString *)identifier {
	if (identifier != nil) {
		// Send an activation notification to the app with specified bundle identifier
		// When the app receives it, it will automatically make a connection with
		// SpringBoard server and initiate the bidirectional communication
		NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
		[center postNotificationName:OBJCIPCActivateAppNotification object:identifier userInfo:nil deliverImmediately:YES];
	}
}

+ (void)_sendDeactivationNotificationToAppWithIdentifier:(NSString *)identifier {
	if (identifier != nil) {
		// Send an deactivation notification to the app with specified bundle identifier
		// When the app receives it, it will automatically disconnect with
		// SpringBoard server and clean up everything about the connection
		NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
		[center postNotificationName:OBJCIPCDeactivateAppNotification object:identifier userInfo:nil deliverImmediately:YES];
	}
}

+ (void)_appActivationHandler {
	if ([self isApp]) {
		[self activate];
	}
}

+ (void)_appDeactivationHandler {
	if ([self isApp]) {
		[self deactivate];
	}
}

- (void)_deactivateApp {
	IPCLOG(@"Received UIApplicationWillTerminateNotification");
	[self.class deactivate];
}

//////////////////////////////////////////////////////////////////////

- (id)copyWithZone:(NSZone *)zone { return self; }
- (id)retain { return self; }
- (oneway void)release {}
- (id)autorelease { return self; }
- (NSUInteger)retainCount { return NSUIntegerMax; }

@end