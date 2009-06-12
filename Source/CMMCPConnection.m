//
//  $Id$
//
//  CMMCPConnection.m
//  sequel-pro
//
//  Created by lorenz textor (lorenz@textor.ch) on Wed Sept 21 2005.
//  Copyright (c) 2002-2003 Lorenz Textor. All rights reserved.
//
//  This program is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 2 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program; if not, write to the Free Software
//  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
//
//  More info at <http://code.google.com/p/sequel-pro/>

#import "CMMCPConnection.h"
#include <unistd.h>
#include <setjmp.h>

static jmp_buf pingTimeoutJumpLocation;
static void forcePingTimeout(int signalNumber);

@interface CMMCPConnection(hidden)
- (void)getServerVersionString;
@end

@implementation CMMCPConnection(hidden)
- (void)getServerVersionString
{
	if( mConnected ) {
		CMMCPResult *theResult;
		theResult = [self queryString:@"SHOW VARIABLES WHERE Variable_name = 'version'"];
		if ([theResult numOfRows]) {
			[theResult dataSeek:0];
			serverVersionString = [[NSString stringWithString:[[theResult fetchRowAsArray] objectAtIndex:1]] retain];
		}
	}
}
@end


@implementation CMMCPConnection

/*
 * Override the normal init methods, extending them to also init additional details,
 * and to store details of the initialised connection to allow reconnection as method.
 * Note this also behaves differently from the standard MCPKit connection methods -
 * passwords are passed separately, and connections are not automatically made on init.
 */
- (id) init
{
	[self initSPExtensions];
	self = [super init];
	serverVersionString = nil;
	return self;
}
- (id) initToHost:(NSString *) host withLogin:(NSString *) login usingPort:(int) port
{
	[self initSPExtensions];

	self = [super init];
	mEncoding = NSISOLatin1StringEncoding;	
	mConnection = mysql_init(mConnection);
	mConnected = NO;
	if (mConnection == NULL) {
		[self autorelease];
		return nil;
	}

	mConnectionFlags = kMCPConnectionDefaultOption;
	
	connectionHost = [[NSString alloc] initWithString:host];
	connectionLogin = [[NSString alloc] initWithString:login];
	connectionPort = port;
	connectionSocket = nil;

	return self;
}
- (id) initToSocket:(NSString *) socket withLogin:(NSString *) login
{
	[self initSPExtensions];
	self = [super init];
	mEncoding = NSISOLatin1StringEncoding;	
	mConnection = mysql_init(mConnection);
	mConnected = NO;
	if (mConnection == NULL) {
		[self autorelease];
		return nil;
	}
	
	mConnectionFlags = kMCPConnectionDefaultOption;
	
	connectionHost = nil;
	connectionLogin = [[NSString alloc] initWithString:login];
	connectionSocket = [[NSString alloc] initWithString:socket];
	connectionPort = 0;

	return self;
}


/*
 * Instantiate extra variables and load the connection error dialog for potential use.
 */
- (void) initSPExtensions
{
	parentWindow = nil;
	connectionPassword = nil;
	connectionKeychainName = nil;
	connectionKeychainAccount = nil;
	keepAliveTimer = nil;
	connectionTunnel = nil;
	connectionTimeout = [[[NSUserDefaults standardUserDefaults] objectForKey:@"ConnectionTimeout"] intValue];
	if (!connectionTimeout) connectionTimeout = 10;
	useKeepAlive = [[[NSUserDefaults standardUserDefaults] objectForKey:@"UseKeepAlive"] doubleValue];
	keepAliveInterval = [[[NSUserDefaults standardUserDefaults] objectForKey:@"KeepAliveInterval"] doubleValue];
	if (!keepAliveInterval) keepAliveInterval = 0;
	lastKeepAliveSuccess = nil;
	lastQueryExecutionTime = 0;
	if (![NSBundle loadNibNamed:@"ConnectionErrorDialog" owner:self]) {
		NSLog(@"Connection error dialog could not be loaded; connection failure handling will not function correctly.");
	}
}

/*
 * Sets the password to be stored locally.
 * Providing a keychain name is much more secure.
 */
- (BOOL) setPassword:(NSString *)thePassword
{
	if (connectionPassword) [connectionPassword release], connectionPassword = nil;
	if (connectionKeychainName) [connectionKeychainName release], connectionKeychainName = nil;
	if (connectionKeychainAccount) [connectionKeychainAccount release], connectionKeychainAccount = nil;

	connectionPassword = [[NSString alloc] initWithString:thePassword];
	
	return YES;
}

/*
 * Sets the keychain name to use to retrieve the password.  This is the recommended and
 * secure way of supplying a password to the SSH tunnel.
 */
- (BOOL) setPasswordKeychainName:(NSString *)theName account:(NSString *)theAccount
{
	if (connectionPassword) [connectionPassword release], connectionPassword = nil;
	if (connectionKeychainName) [connectionKeychainName release], connectionKeychainName = nil;
	if (connectionKeychainAccount) [connectionKeychainAccount release], connectionKeychainAccount = nil;

	connectionKeychainName = [[NSString alloc] initWithString:theName];
	connectionKeychainAccount = [[NSString alloc] initWithString:theAccount];

	return YES;
}


/*
 * Set a SSH tunnel object to connect through.  This object will be retained locally,
 * and will be automatically connected/connection checked/reconnected/disconnected
 * together with the main connection.
 */
- (BOOL) setSSHTunnel:(SPSSHTunnel *)theTunnel
{
	connectionTunnel = theTunnel;
	[connectionTunnel retain];

	currentSSHTunnelState = [connectionTunnel state];
	[connectionTunnel setConnectionStateChangeSelector:@selector(sshTunnelStateChange:) delegate:self];

	return YES;
}

/*
 * Add a new connection method, intended for use with the init methods above.
 * Uses the stored details to instantiate a connection to the specified server,
 * including custom timeouts - used for pings, not for long-running commands.
 */
- (BOOL) connect
{
	const char	*theLogin = [self cStringFromString:connectionLogin];
	const char	*theHost;
	const char	*thePass;
	const char	*theSocket;
	void		*theRet;

	// Ensure that a password method has been provided
	if (connectionKeychainName == nil && connectionPassword == nil) return NO;
	
	// Start the keepalive timer
	[self startKeepAliveTimerResettingState:YES];

	// Disconnect if a connection is already active
	if (mConnected) {
		[self disconnect];
		mConnection = mysql_init(NULL);
		if (mConnection == NULL) return NO;
	}

	// Ensure the custom timeout option is set
	if (mConnection != NULL) {
		mysql_options(mConnection, MYSQL_OPT_CONNECT_TIMEOUT, (const void *)&connectionTimeout);
	}
	
	// Set the host as appropriate
	if (!connectionHost || ![connectionHost length]) {
		theHost = NULL;
	} else {
		theHost = [self cStringFromString:connectionHost];
	}
	
	// Use the default socket if none is set, or set appropriately
	if (connectionSocket == nil || ![connectionSocket length]) {
		theSocket = kMCPConnectionDefaultSocket;
	} else {
		theSocket = [self cStringFromString:connectionSocket];
	}
	
	// Select the password from the provided method
	if (connectionKeychainName) {
		KeyChain *keychain;
		keychain = [[KeyChain alloc] init];
		thePass = [self cStringFromString:[keychain getPasswordForName:connectionKeychainName account:connectionKeychainAccount]];
		[keychain release];
	} else {
		thePass = [self cStringFromString:connectionPassword];
	}

	// Connect
	theRet = mysql_real_connect(mConnection, theHost, theLogin, thePass, NULL, connectionPort, theSocket, mConnectionFlags);
	thePass = NULL;
	if (theRet != mConnection) {
		if (connectionTunnel) [connectionTunnel disconnect];
		return mConnected = NO;
	}

	mConnected = YES;
	mEncoding = [MCPConnection encodingForMySQLEncoding:mysql_character_set_name(mConnection)];
	[self timeZone]; // Getting the timezone used by the server.
	
	isMaxAllowedPacketEditable = [self isMaxAllowedPacketEditable];
	
	return mConnected;
}


/*
 * Override the stored disconnection method to ensure that disconnecting clears stored timers.
 */
- (void) disconnect
{
	[super disconnect];
	
	if (connectionTunnel) [connectionTunnel disconnect];
	
	if( serverVersionString != nil ) {
		[serverVersionString release];
		serverVersionString = nil;
	}

	[self stopKeepAliveTimer];
}

/*
 * return the server major version or -1 on fail
 */
- (int)serverMajorVersion
{

	if( mConnected ) {
		if( serverVersionString == nil ) {
			[self getServerVersionString];
		}
		if( serverVersionString != nil ) {
			return [[[serverVersionString componentsSeparatedByString:@"."] objectAtIndex:0] intValue];
		} 
	} 
	return -1;
}

/*
 * return the server minor version or -1 on fail
 */
- (int)serverMinorVersion
{
	
	if( mConnected ) {
		if( serverVersionString == nil ) {
			[self getServerVersionString];
		}
		if( serverVersionString != nil ) {
			return [[[serverVersionString componentsSeparatedByString:@"."] objectAtIndex:1] intValue];
		}
	}
	return -1;
}

/*
 * return the server release version or -1 on fail
 */
- (int)serverReleaseVersion
{
	if( mConnected ) {
		if( serverVersionString == nil ) {
			[self getServerVersionString];
		}
		if( serverVersionString != nil ) {
			NSString *s = [[serverVersionString componentsSeparatedByString:@"."] objectAtIndex:2];
			return [[[s componentsSeparatedByString:@"-"] objectAtIndex:0] intValue];
		}
	}
	return -1;
}


/*
 * Reconnect to the currently "active" - but possibly disconnected - connection, using the
 * stored details.
 * Error checks extensively - if this method fails, it will ask how to proceed and loop depending
 * on the status, not returning control until either a connection has been established or
 * the connection and document have been closed.
 */
- (BOOL) reconnect
{
	NSString *currentEncoding = nil;
	BOOL currentEncodingUsesLatin1Transport = NO;
	NSString *currentDatabase = nil;

	// Store the current database and encoding so they can be re-set if reconnection was successful
	if (delegate && [delegate valueForKey:@"selectedDatabase"]) {
		currentDatabase = [NSString stringWithString:[delegate valueForKey:@"selectedDatabase"]];
	}
	if (delegate && [delegate valueForKey:@"_encoding"]) {
		currentEncoding = [NSString stringWithString:[delegate valueForKey:@"_encoding"]];
	}
	if (delegate && [delegate respondsToSelector:@selector(connectionEncodingViaLatin1)]) {
		currentEncodingUsesLatin1Transport = [delegate connectionEncodingViaLatin1];
	}

	// Close the connection if it exists.
	if (mConnected) {
		mysql_close(mConnection);
		mConnection = NULL;
	}
	mConnected = NO;
	
	// If there is a tunnel, ensure it's disconnected and attempt to reconnect it in blocking fashion
	if (connectionTunnel) {
		[connectionTunnel setConnectionStateChangeSelector:nil delegate:nil];
		if ([connectionTunnel state] != SPSSH_STATE_IDLE) [connectionTunnel disconnect];
		[connectionTunnel connect];
		NSDate *tunnelStartDate = [NSDate date], *interfaceInteractionTimer;
		
		// Allow the tunnel to attempt to connect in a loop
		while (1) {
			if ([connectionTunnel state] == SPSSH_STATE_CONNECTED) {
				connectionPort = [connectionTunnel localPort];
				break;
			}
			if ([[NSDate date] timeIntervalSinceDate:tunnelStartDate] > (connectionTimeout + 1)) {
				[connectionTunnel disconnect];
				break;
			}
			
			// Process events for a short time, allowing dialogs to be shown but waiting for the tunnel
			interfaceInteractionTimer = [NSDate date];
			[[NSRunLoop currentRunLoop] runMode:NSModalPanelRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
			tunnelStartDate = [tunnelStartDate addTimeInterval:([[NSDate date] timeIntervalSinceDate:interfaceInteractionTimer] - 0.25)];
		}
		currentSSHTunnelState = [connectionTunnel state];
		[connectionTunnel setConnectionStateChangeSelector:@selector(sshTunnelStateChange:) delegate:self];
	}

	if (!connectionTunnel || [connectionTunnel state] == SPSSH_STATE_CONNECTED) {

		// Attempt to reinitialise the connection - if this fails, it will still be set to NULL.
		if (mConnection == NULL) {
			mConnection = mysql_init(NULL);
		}

		if (mConnection != NULL) {

			// Set a connection timeout for the new connection
			mysql_options(mConnection, MYSQL_OPT_CONNECT_TIMEOUT, (const void *)&connectionTimeout);

			// Attempt to reestablish the connection
			[self connect];
		}
	}

	// If the connection was successfully established, reselect the old database and encoding if appropriate.
	if (mConnected) {
		if (currentDatabase) {
			[self selectDB:currentDatabase];
		}
		if (currentEncoding) {
			[self queryString:[NSString stringWithFormat:@"/*!40101 SET NAMES '%@' */", currentEncoding]];
			[self setEncoding:[CMMCPConnection encodingForMySQLEncoding:[currentEncoding UTF8String]]];
			if (currentEncodingUsesLatin1Transport) {
				[self queryString:@"/*!40101 SET CHARACTER_SET_RESULTS=latin1 */"];			
			}
		}
	} else if (parentWindow) {

		// If the connection was not successfully established, ask how to proceed.
		[NSApp beginSheet:connectionErrorDialog modalForWindow:parentWindow modalDelegate:self didEndSelector:nil contextInfo:nil];
		int connectionErrorCode = [NSApp runModalForWindow:connectionErrorDialog];
		[NSApp endSheet:connectionErrorDialog];
		[connectionErrorDialog orderOut:nil];

		switch (connectionErrorCode) {

				// Should disconnect
				case 2:
					[parentWindow close];
					return NO;

				// Should retry
				default:
					return [self reconnect];
		}
	}

	return mConnected;
}


/*
 * Set the parent window of the connection for use with dialogs.
 */
- (void)setParentWindow:(NSWindow *)theWindow
{
	parentWindow = theWindow;
}

/*
 * Handle any state changes in the associated SSH Tunnel
 */
- (void)sshTunnelStateChange:(SPSSHTunnel *)theTunnel
{
	int newState = [theTunnel state];

	// Restart the tunnel if it dies
	if (mConnected && newState == SPSSH_STATE_IDLE && currentSSHTunnelState == SPSSH_STATE_CONNECTED) {
		currentSSHTunnelState = newState;
		[connectionTunnel setConnectionStateChangeSelector:nil delegate:nil];
		[self reconnect];
		return;
	}

	currentSSHTunnelState = newState;
}


/*
 * Ends and existing modal session
 */
- (IBAction) closeSheet:(id)sender
{
	[NSApp stopModalWithCode:[sender tag]];
}

/*
 * Determines whether a supplied error number can be classed as a connection
 * error.
 */
+ (BOOL) isErrorNumberConnectionError:(int)theErrorNumber
{

	switch (theErrorNumber) {
		case 2001: // CR_SOCKET_CREATE_ERROR
		case 2002: // CR_CONNECTION_ERROR
		case 2003: // CR_CONN_HOST_ERROR
		case 2004: // CR_IPSOCK_ERROR
		case 2005: // CR_UNKNOWN_HOST
		case 2006: // CR_SERVER_GONE_ERROR
		case 2007: // CR_VERSION_ERROR
		case 2009: // CR_WRONG_HOST_INFO
		case 2012: // CR_SERVER_HANDSHAKE_ERR
		case 2013: // CR_SERVER_LOST
		case 2027: // CR_MALFORMED_PACKET
		case 2032: // CR_DATA_TRUNCATED
		case 2047: // CR_CONN_UNKNOW_PROTOCOL
		case 2048: // CR_INVALID_CONN_HANDLE
		case 2050: // CR_FETCH_CANCELED
		case 2055: // CR_SERVER_LOST_EXTENDED
			return YES;
	}
	
	return NO;
}

/*
 * Gets a proper NSStringEncoding according to the given MySQL charset.
 *
 * MySQL 4.0 offers this charsets:
 * big5 cp1251 cp1257 croat czech danish dec8 dos estonia euc_kr gb2312 gbk german1
 * greek hebrew hp8 hungarian koi8_ru koi8_ukr latin1 latin1_de latin2 latin5 sjis
 * swe7 tis620 ujis usa7 win1250 win1251ukr
 *
 * WARNING : incomplete implementation. Please, send your fixes.
 */
+ (NSStringEncoding) encodingForMySQLEncoding:(const char *) mysqlEncoding
{
	// Unicode encodings:
	if (!strncmp(mysqlEncoding, "utf8", 4)) {
		return NSUTF8StringEncoding;
	}
	if (!strncmp(mysqlEncoding, "ucs2", 4)) {
		return NSUnicodeStringEncoding;
	}

	// Roman alphabet encodings:
	if (!strncmp(mysqlEncoding, "ascii", 5)) {
		return NSASCIIStringEncoding;
	}
	if (!strncmp(mysqlEncoding, "latin1", 6)) {
		return NSISOLatin1StringEncoding;
	}
	if (!strncmp(mysqlEncoding, "macroman", 8)) {
		return NSMacOSRomanStringEncoding;
	}

	// Roman alphabet with central/east european additions:
	if (!strncmp(mysqlEncoding, "latin2", 6)) {
		return NSISOLatin2StringEncoding;
	}
	if (!strncmp(mysqlEncoding, "cp1250", 6)) {
		return NSWindowsCP1250StringEncoding;
	}
	if (!strncmp(mysqlEncoding, "win1250", 7)) {
		return NSWindowsCP1250StringEncoding;
	}
	if (!strncmp(mysqlEncoding, "cp1257", 6)) {
		return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingWindowsBalticRim);
	}

	// Additions for Turkish:
	if (!strncmp(mysqlEncoding, "latin5", 6)) {
		return NSWindowsCP1254StringEncoding;
	}

	// Greek:
	if (!strncmp(mysqlEncoding, "greek", 5)) {
		return NSWindowsCP1253StringEncoding;
	}

	// Cyrillic:	
	if (!strncmp(mysqlEncoding, "win1251ukr", 6)) {
		return NSWindowsCP1251StringEncoding;
	}
	if (!strncmp(mysqlEncoding, "cp1251", 6)) {
		return NSWindowsCP1251StringEncoding;
	}
	if (!strncmp(mysqlEncoding, "koi8_ru", 6)) {
		return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingKOI8_R);
	}
	if (!strncmp(mysqlEncoding, "koi8_ukr", 6)) {
		return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingKOI8_R);
	}
	 
	// Arabic:
	if (!strncmp(mysqlEncoding, "cp1256", 6)) {
		return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingWindowsArabic);
	}

	// Hebrew:
	if (!strncmp(mysqlEncoding, "hebrew", 6)) {
		CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingISOLatinHebrew);
	}

	// Asian:
	if (!strncmp(mysqlEncoding, "ujis", 4)) {
		return NSJapaneseEUCStringEncoding;
	}
	if (!strncmp(mysqlEncoding, "sjis", 4)) {
		return  NSShiftJISStringEncoding;
	}
	if (!strncmp(mysqlEncoding, "big5", 4)) {
		return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingBig5);
	}
	if (!strncmp(mysqlEncoding, "euc_kr", 6)) {
		return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingEUC_KR);
	}
	if (!strncmp(mysqlEncoding, "euckr", 5)) {
		return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingEUC_KR);
	}
	
	// Default to iso latin 1, even if it is not exact (throw an exception?)    
	NSLog(@"WARNING : unknown name for MySQL encoding '%s'!\n\t\tFalling back to iso-latin1.", mysqlEncoding);
	return NSISOLatin1StringEncoding;
}


/*
 * Modified version of selectDB to be used in Sequel Pro.
 * Checks the connection exists, and handles keepalive, otherwise calling the parent implementation.
 */
- (BOOL) selectDB:(NSString *) dbName
{
	if (!mConnected) return NO;
	[self stopKeepAliveTimer];
	if (![self checkConnection]) return NO;
	if ([super selectDB:dbName]) {
		[self startKeepAliveTimerResettingState:YES];
		return YES;
	}
	if (connectionTunnel) [connectionTunnel disconnect];
	return NO;
}


/*
 * Override the standard queryString: method to default to the connection encoding, as before,
 * before pssing on to queryString: usingEncoding:.
 */
- (CMMCPResult *)queryString:(NSString *) query
{
	return [self queryString:query usingEncoding:mEncoding];
}


/*
 * Modified version of queryString to be used in Sequel Pro.
 * Error checks connection extensively - if this method fails due to a connection error, it will ask how to
 * proceed and loop depending on the status, not returning control until either the query has been executed
 * and the result can be returned or the connection and document have been closed.
 */
- (CMMCPResult *)queryString:(NSString *) query usingEncoding:(NSStringEncoding) encoding
{
	CMMCPResult	*theResult;
	NSDate		*queryStartDate;
	const char	*theCQuery;
	int			queryResultCode;	
	int			currentMaxAllowedPacket = -1;

	// If no connection is present, return nil.
	if (!mConnected) return nil;

	[self stopKeepAliveTimer];

	// Inform the delegate about the query
	if (delegate && [delegate respondsToSelector:@selector(willQueryString:)]) {
		[delegate willQueryString:query];
	}

	// Derive the query string in the correct encoding
	theCQuery = [self cStringFromString:query usingEncoding:encoding];

	// Run the query, timing the execution time on the server.  Note that this will include network lag.
	queryStartDate = [NSDate date];
	queryResultCode = mysql_query(mConnection, theCQuery);
	lastQueryExecutionTime = [[NSDate date] timeIntervalSinceDate:queryStartDate];

	// If there was an error, check whether it was a connection-related error
	if (0 != queryResultCode && [CMMCPConnection isErrorNumberConnectionError:[self getLastErrorID]]) {

		// Try to increase max_allowed_packet for error 2006 BEFORE check connection
		if(isMaxAllowedPacketEditable && queryResultCode == 1 && [self getLastErrorID] == 2006) {
			currentMaxAllowedPacket = [self getMaxAllowedPacket];
			[self setMaxAllowedPacketTo:strlen(theCQuery)+1024];
		}

		// Check the connection and see if it can be restored.  This triggers reconnects as necessary, and
		// should only return false if a disconnection has been requested - in which case return nil.
		if (![self checkConnection]) return nil;

		// The connection has been restored - re-run the query
		queryStartDate = [NSDate date];
		queryResultCode = mysql_query(mConnection, theCQuery);
		lastQueryExecutionTime = [[NSDate date] timeIntervalSinceDate:queryStartDate];
	}

	// If max_allowed_packet was changed, reset it to default
	if(currentMaxAllowedPacket > -1)
		[self setMaxAllowedPacketTo:currentMaxAllowedPacket];

	// Retrieve the result or error appropriately.
	if (0 == queryResultCode) {
		if (mysql_field_count(mConnection) != 0) {

			// Use CMMCPResult instead of MCPResult
			theResult = [[CMMCPResult alloc] initWithMySQLPtr:mConnection encoding:mEncoding timeZone:mTimeZone];
		} else {
			return nil;
		}
	} else {

		// Inform the delegate about errors
		if (delegate && [delegate respondsToSelector:@selector(queryGaveError:)]) {
			if(queryResultCode == 1 && [self getLastErrorID] == 2006)
				// very likely that query length > max_allowed_packet 
				[delegate queryGaveError:[NSString stringWithFormat:@"%@ (Please check if query size < max_allowed_packet)", [self getLastErrorMessage]]];
			else
				[delegate queryGaveError:[self getLastErrorMessage]];
		}

		return nil;
	}

	[self startKeepAliveTimerResettingState:YES];

	return [theResult autorelease];
}


/*
 * Return the time taken to execute the last query.  This should be close to the time it took
 * the server to run the query, but will include network lag and some client library overhead.
 */
- (float) lastQueryExecutionTime
{
	return lastQueryExecutionTime;
}


/*
 * Modified version of selectDB to be used in Sequel Pro.
 * Checks the connection exists, and handles keepalive, otherwise calling the parent implementation.
 */
- (MCPResult *) listDBsLike:(NSString *) dbsName
{
	if (!mConnected) return NO;
	[self stopKeepAliveTimer];
	if (![self checkConnection]) return [[[MCPResult alloc] init] autorelease];
	[self startKeepAliveTimerResettingState:YES];
	return [super listDBsLike:dbsName];
}


/*
 * Checks whether the connection to the server is still active.  If not, prompts for what approach to take,
 * offering to retry, reconnect or disconnect the connection.
 */
- (BOOL)checkConnection
{
	unsigned long threadid;

	if (!mConnected) return NO;

	BOOL connectionVerified = FALSE;

	// Get the current thread ID for this connection
	threadid = mConnection->thread_id;

	// Check whether the connection is still operational via a wrapped version of MySQL ping.
	connectionVerified = [self pingConnection];

	// If the connection doesn't appear to be responding, show a dialog asking how to proceed
	if (!connectionVerified) {
		[NSApp beginSheet:connectionErrorDialog modalForWindow:parentWindow modalDelegate:self didEndSelector:nil contextInfo:nil];
		int responseCode = [NSApp runModalForWindow:connectionErrorDialog];
		[NSApp endSheet:connectionErrorDialog];
		[connectionErrorDialog orderOut:nil];

		switch (responseCode) {

			// "Reconnect" has been selected.  Request a reconnect, and retry.
			case 1:
				[self reconnect];
				return [self checkConnection];

			// "Disconnect" has been selected.  Close the parent window, which will handle disconnections, and return false.
			case 2:
				[parentWindow close];
				return FALSE;

			// "Retry" has been selected - return a recursive call.
			default:
				return [self checkConnection];
		}

	// If a connection exists, check whether the thread id differs; if so, the connection has
	// probably been reestablished and we need to reset the connection encoding
	} else if (threadid != mConnection->thread_id) {
		if (delegate && [delegate valueForKey:@"_encoding"]) {
			[self queryString:[NSString stringWithFormat:@"/*!40101 SET NAMES '%@' */", [NSString stringWithString:[delegate valueForKey:@"_encoding"]]]];
			if (delegate && [delegate respondsToSelector:@selector(connectionEncodingViaLatin1)]) {
				if ([delegate connectionEncodingViaLatin1]) [self queryString:@"/*!40101 SET CHARACTER_SET_RESULTS=latin1 */"];			
			}
		}
	}

	return connectionVerified;
}

- (void)setDelegate:(id)object
{
	delegate = object;
}

/* Getting the currently used time zone (in communication with the DB server). */
/* fixes mysql 4.1.14 problem, can be deleted as soon as fixed in the framework */
- (NSTimeZone *)timeZone
{
	if ([self checkConnection]) {
		MCPResult	*theSessionTZ = [self queryString:@"SHOW VARIABLES LIKE '%time_zone'"];
		NSArray		*theRow;
		id			theTZName;
		NSTimeZone	*theTZ;

		[theSessionTZ dataSeek:1ULL];
		theRow = [theSessionTZ fetchRowAsArray];
		theTZName = [theRow objectAtIndex:1];

		if ( [theTZName isKindOfClass:[NSData class]] ) {
			// MySQL 4.1.14 returns the mysql variables as NSData
			theTZName = [self stringWithText:theTZName];
		}

		if ([theTZName isEqualToString:@"SYSTEM"]) {
			[theSessionTZ dataSeek:0ULL];
			theRow = [theSessionTZ fetchRowAsArray];
			theTZName = [theRow objectAtIndex:1];

			if ( [theTZName isKindOfClass:[NSData class]] ) {
				// MySQL 4.1.14 returns the mysql variables as NSData
				theTZName = [self stringWithText:theTZName];
			}
		}

		if (theTZName) { // Old versions of the server does not support there own time zone ?
			theTZ = [NSTimeZone timeZoneWithName:theTZName];
		} else {
			// By default set the time zone to the local one..
			// Try to get the name using the previously available variable:
			theSessionTZ = [self queryString:@"SHOW VARIABLES LIKE 'timezone'"];
			[theSessionTZ dataSeek:0ULL];
			theRow = [theSessionTZ fetchRowAsArray];
			theTZName = [theRow objectAtIndex:1];
			if (theTZName) {
				// Finally we found one ...
				theTZ = [NSTimeZone timeZoneWithName:theTZName];
			} else {
				theTZ = [NSTimeZone defaultTimeZone];
				//theTZ = [NSTimeZone systemTimeZone];
				NSLog(@"The time zone is not defined on the server, set it to the default one : %@", theTZ);
			}
		}

		if (theTZ != mTimeZone) {
			[mTimeZone release];
			mTimeZone = [theTZ retain];
		}
	}
	return mTimeZone;
}


/*
 * The current versions of MCPKit (and up to and including 3.0.1) use MySQL 4.1.12; this has an issue with
 * mysql_ping where a connection which is terminated will cause mysql_ping never to respond, even when
 * connection timeouts are set.  Full details of this issue are available at http://bugs.mysql.com/bug.php?id=9678 ;
 * this bug was fixed in 4.1.22 and later versions.
 * This issue can be replicated by connecting to a remote host, and then configuring a firewall on that host
 * to drop all packets on the connected port - mysql_ping and so Sequel Pro will hang.
 * Until the client libraries are updated, this provides a drop-in wrapper for mysql_ping, which calls mysql_ping
 * while running a SIGALRM to enforce the specified connection time.  This is low-level but effective.
 * Unlike mysql_ping, this function returns FALSE on failure and TRUE on success.
 */
- (BOOL) pingConnection
{
	struct sigaction timeoutAction;
	NSDate *startDate = [[NSDate alloc] initWithTimeIntervalSinceNow:0];
	BOOL pingSuccess = FALSE;
	
	// Construct the SIGALRM to fire after the connection timeout if it isn't cleared, calling the forcePingTimeout function.
	timeoutAction.sa_handler = forcePingTimeout;
	sigemptyset(&timeoutAction.sa_mask);
	timeoutAction.sa_flags = 0;
	sigaction(SIGALRM, &timeoutAction, NULL);
	alarm(connectionTimeout+1);

	// Set up a "restore point", returning 0; if longjmp is used later with this reference, execution
	// jumps back to this point and returns a nonzero value, so this function evaluates to false when initially
	// set and true if it's called again.
	if (setjmp(pingTimeoutJumpLocation)) {

		// The connection timed out - we want to return false.
		pingSuccess = FALSE;
	
	// On direct execution:
	} else {

		// Run mysql_ping, which returns 0 on success, and otherwise an error.
		pingSuccess = (BOOL)(! mysql_ping(mConnection));

		// If the ping failed within a second, try another one; this is because a terminated-but-then
		// restored connection is at times restored or functional after a ping, but the ping still returns
		// an error.  This additional check ensures the returned status is correct with minimal other effect.
		if (!pingSuccess && ([startDate timeIntervalSinceNow] > -1)) {
			pingSuccess = (BOOL)(! mysql_ping(mConnection));
		}
	}

	// Reset and clear the SIGALRM used to check connection timeouts.
	alarm(0);
	timeoutAction.sa_handler = SIG_IGN;
	sigemptyset(&timeoutAction.sa_mask);
	timeoutAction.sa_flags = 0;
	sigaction(SIGALRM, &timeoutAction, NULL);
	
	[startDate release];
	
	return pingSuccess;
}

/*
 * This function is paired with pingConnection, and provides a method of enforcing the connection
 * timeout when mysql_ping does not respect the specified limits.
 */
static void forcePingTimeout(int signalNumber)
{
	longjmp(pingTimeoutJumpLocation, 1);
}

/*
 * Restarts a keepalive to fire in the future.
 */
- (void) startKeepAliveTimerResettingState:(BOOL)resetState
{
	if (keepAliveTimer) [self stopKeepAliveTimer];
	if (!mConnected) return;

	if (resetState && lastKeepAliveSuccess) {
		[lastKeepAliveSuccess release];
		lastKeepAliveSuccess = nil;
	}

	if (useKeepAlive && keepAliveInterval) {
		keepAliveTimer = [NSTimer
							scheduledTimerWithTimeInterval:keepAliveInterval
							target:self
							selector:@selector(keepAlive:)
							userInfo:nil
							repeats:NO];
		[keepAliveTimer retain];
	}
}

/*
 * Stops a keepalive if one is set for the future.
 */
- (void) stopKeepAliveTimer
{
	if (!keepAliveTimer) return;
	[keepAliveTimer invalidate];
	[keepAliveTimer release];
	keepAliveTimer = nil;
}

/*
 * Keeps a connection alive by running a ping.
 */
- (void) keepAlive:(NSTimer *)theTimer
{
	if (!mConnected) return;

	// If there a successful keepalive record exists, and it was more than 5*keepaliveinterval ago,
	// abort.  This prevents endless spawning of threads in a state where the connection has been
	// cut but mysql doesn't pick up on the fact - see comment for pingConnection above.  The same
	// forced-timeout approach cannot be used here on a background thread.
	// When the connection is disconnected in code, these 5 "hanging" threads are automatically cleaned.
	if (lastKeepAliveSuccess && [lastKeepAliveSuccess timeIntervalSinceNow] < -5 * keepAliveInterval) return;

	[NSThread detachNewThreadSelector:@selector(threadedKeepAlive) toTarget:self withObject:nil];
	[self startKeepAliveTimerResettingState:NO];
}

/*
 * A threaded keepalive to avoid blocking the interface
 */
- (void) threadedKeepAlive
{
	if (!mConnected) return;
	mysql_ping(mConnection);
	if (lastKeepAliveSuccess) {
		[lastKeepAliveSuccess release];
		lastKeepAliveSuccess = nil;
	}
	lastKeepAliveSuccess = [[NSDate alloc] initWithTimeIntervalSinceNow:0];
}

/*
 * Modified version of the original to support a supplied encoding.
 * For internal use only. Transforms a NSString to a C type string (ending with \0).
 * Lossy conversions are enabled.
 */
- (const char *) cStringFromString:(NSString *) theString usingEncoding:(NSStringEncoding) encoding
{
	NSMutableData	*theData;
	
	if (! theString) {
		return (const char *)NULL;
	}
	
	theData = [NSMutableData dataWithData:[theString dataUsingEncoding:encoding allowLossyConversion:YES]];
	[theData increaseLengthBy:1];
	return (const char *)[theData bytes];
}

/*
 * Retrieves max_allowed_packet size set as global variable.
 * It returns -1 if it fails.
 */
- (int) getMaxAllowedPacket
{

	if (0 == mysql_query(mConnection, "SELECT @@global.max_allowed_packet")) {
		if (mysql_field_count(mConnection) != 0) {
			CMMCPResult *r = [[CMMCPResult alloc] initWithMySQLPtr:mConnection encoding:mEncoding timeZone:mTimeZone];
			NSArray *a = [r fetchRowAsArray];
			[r autorelease];
			if([a count]) return [[a objectAtIndex:0] intValue];
		}
	}

	NSRunAlertPanel(@"Error", [NSString stringWithFormat:@"An error occured while retrieving max_allowed_packet size:\n\n%@", [self getLastErrorMessage]], @"OK", nil, nil);

	return -1;
}

/*
 * It sets max_allowed_packet size to newSize and it returns
 * max_allowed_packet after setting it to newSize for cross-checking 
 * if the maximal size was reached (e.g. set it to 4GB it'll return 1GB up to now).
 * If something failed it return -1;
 */
- (int) setMaxAllowedPacketTo:(int)newSize
{
	if(![self isMaxAllowedPacketEditable] || newSize < 1024) return [self getMaxAllowedPacket];

	mysql_query(mConnection, [[NSString stringWithFormat:@"SET GLOBAL max_allowed_packet = %d", newSize] UTF8String]);

	return [self getMaxAllowedPacket];
}


/*
 * It returns whether max_allowed_packet is setable for the user.
 */
- (BOOL) isMaxAllowedPacketEditable
{
	return(!mysql_query(mConnection, "SET GLOBAL max_allowed_packet = @@global.max_allowed_packet"));
}


- (void) dealloc
{
	[super dealloc];
}

@end