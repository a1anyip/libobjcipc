# libobjcipc
An inter-process communication (between app and SpringBoard) solution for jailbroken iOS. Specifically written for iOS 7 (not tested on previous versions).

It handles the socket connections between SpringBoard and app processes, the automatic set up of process assertions and the auto disconnection after timeout or the process terminates.

You only need to call the static methods in the main class `OBJCIPC`. Messages and replies can be sent synchronously (blocking) or asynchronously.

## Basic Usage

The basic usage of the library is to have an extra MobileSubstrate extension which hooks into a specific app to set up an incoming message handler. Another instance in SpringBoard process sends a message to that app and wait for its reply.

### Usage (Send message)

```objective-c
// Asynchronous message sent from SpringBoard to app (MobileTimer in this case)
[OBJCIPC sendMessageToAppWithIdentifier:@"com.apple.mobiletimer" messageName:@"Custom.Message.Name" dictionary:@{ @"key": @"value" } replyHandler:^(NSDictionary *response) {
	NSLog(@"Received reply from MobileTimer: %@", response);
}];
   
// Asynchronous message sent from app to SpringBoard
[OBJCIPC sendMessageToSpringBoardWithMessageName:@"Custom.Message.Name" dictionary:@{ @"key": @"value" } replyHandler:^(NSDictionary *response) {
	NSLog(@"Received reply from SpringBoard: %@", response);
}];

// Omit replyHandler parameter to send messages synchronously; return value will be the reply (NSDictionary).
```

### Usage (Handle incoming messages)

```objective-c
// Handle messages sent from any app in SpringBoard
[OBJCIPC registerIncomingMessageFromAppHandlerForMessageName:@"Custom.Message.Name"  handler:^NSDictionary *(NSDictionary *message) {
	// return something as reply
	return nil;
}];

// Handle messages sent from the specific app in SpringBoard
[OBJCIPC registerIncomingMessageHandlerForAppWithIdentifier:@"com.apple.mobiletimer" andMessageName:@"Custom.Message.Name" handler:^NSDictionary *(NSDictionary *message) {
	// return something as reply
	return nil;
}];

// Handle messages sent from SpringBoard in app
[OBJCIPC registerIncomingMessageFromSpringBoardHandlerForMessageName:@"Custom.Message.Name" handler:^NSDictionary *(NSDictionary *message) {
	// return something as reply
	return nil;
}];
```