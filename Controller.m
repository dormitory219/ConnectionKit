#import "Controller.h"
#import "ProgressCell.h"
#import "InputDialog.h"
#import "PermissionsController.h"
#import "FileTransfer.h"
#import <Connection/Connection.h>

static NSString *AutoSelect = @"Auto Select";

NSString *TransferTypeKey = @"Type";
NSString *TransferLocalFileKey = @"LocalFile";
NSString *TransferRemoteFileKey = @"RemoteFile";
NSString *TransferControllerKey = @"Controller";
NSString *TransferProgressKey = @"Progress";

int TransferTypeDown = 0;
int TransferTypeUp = 1;

NSString *cxRemoteFilePBoardType = @"cxRemoteFilePBoardType";
NSString *cxLocalFilePBoardType = @"cxLocalFilePBoardType";


//Storing to NSUser Defaults
NSString *HostsKey = @"Hosts";
NSString *HostKey = @"Host";
NSString *PortKey = @"Port";
NSString *UsernameKey = @"Username";
NSString *ConnectionTypeKey = @"Connection";
NSString *URLKey = @"URL";
NSString *InitialDirectoryKey = @"InitialDirectory";
NSString *ProtocolKey = @"Protocol";

@interface Controller(PRivate)
- (void)refreshLocal;
+ (BOOL) keychainSetPassword:(NSString *)inPassword forServer:(NSString *)aServer account:(NSString *)anAccount;
+ (NSString *)keychainPasswordForServer:(NSString *)aServerName account:(NSString *)anAccountName;
- (void)refreshHosts;
- (void)downloadFile:(NSString *)remote toFolder:(NSString *)local;
- (void)uploadFile:(NSString *)local to:(NSString *)remote;
@end
@interface NSString (FileSizeFormatting)

+ (NSString *)formattedFileSizeWithBytes:(NSNumber *)filesize;
@end

@implementation NSString (FileSizeFormatting)

+ (NSString *)formattedFileSizeWithBytes:(NSNumber *)filesize
{
	static NSString *suffix[] = {
		@"B", @"KB", @"MB", @"GB", @"TB", @"PB", @"EB"
	};
	int i, c = 7;
	long size = [filesize longValue];
	
	for (i = 0; i < c && size >= 1024; i++) {
		size = size / 1024;
	}
	return [NSString stringWithFormat:@"%ld %@", size, suffix[i]];
}

@end

@implementation Controller

- (void)awakeFromNib
{
	NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
	NSString *savedWindowRect = [ud objectForKey:[window frameAutosaveName]];
	if (savedWindowRect)
		[window setFrame:NSRectFromString(savedWindowRect) display:YES];
	BOOL showLog = [ud boolForKey:@"showLog"];
	if (showLog) {
		[logDrawer open:self];
	}
	
	remoteFiles = [[NSMutableArray array] retain];
	localFiles = [[NSMutableArray array] retain];
	transfers = [[NSMutableArray array] retain];
	
	NSArray *conTypes = [AbstractConnection registeredConnectionTypes];
	[cTypePopup removeAllItems];
	[cTypePopup addItemWithTitle:AutoSelect];
	[[cTypePopup menu] addItem:[NSMenuItem separatorItem]];
	[cTypePopup addItemsWithTitles:conTypes];
	
	[localTable setDataSource:self];
	[remoteTable setDataSource:self];
	[transferTable setDataSource:self];
	
	NSTableColumn *col = [transferTable tableColumnWithIdentifier:@"progress"];
	ProgressCell *cell = [[ProgressCell alloc] initTextCell:@""];
	[col setDataCell:cell];
	[cell release];
	
	currentLocalPath = [[NSString stringWithFormat:@"%@", NSHomeDirectory()] copy];
	[self refreshLocal];
	[remotePopup removeAllItems];
	
	[remoteTable setDoubleAction:@selector(remoteDoubleClick:)];
	[localTable setDoubleAction:@selector(localDoubleClick:)];
	
	//drag and drop
	[localTable registerForDraggedTypes:[NSArray arrayWithObject:cxRemoteFilePBoardType]]; //
	[remoteTable registerForDraggedTypes:[NSArray arrayWithObjects:cxLocalFilePBoardType, NSFilenamesPboardType, nil]]; //
	
	[remoteTable setHidden:YES];
	
	[cUser setStringValue:NSUserName()];
	
	//Get saved hosts
	_savedHosts = [[NSMutableArray array] retain];
	
	[_savedHosts addObject:[[[CKBonjourCategory alloc] init] autorelease]];
	
	id hosts = [ud objectForKey:HostsKey];
	if (hosts)
	{
		if ([hosts isKindOfClass:[NSArray class]])
		{
			CKHostCategory *cat = [[CKHostCategory alloc] initWithName:NSLocalizedString(@"Saved Hosts", @"category name")];
			NSEnumerator *e = [hosts objectEnumerator];
			NSDictionary *cur;
			CKHost *h;
			
			while ((cur = [e nextObject]))
			{
				h = [[CKHost alloc] init];
				[h setHost:[cur objectForKey:HostKey]];
				[h setPort:[cur objectForKey:PortKey]];
				[h setUsername:[cur objectForKey:UsernameKey]];
				[h setInitialPath:[cur objectForKey:InitialDirectoryKey]];
				if ([cur objectForKey:URLKey] && ![[cur objectForKey:URLKey] isEqualToString:@""])
				{
					[h setURL:[NSURL URLWithString:[cur objectForKey:URLKey]]];
				}
				[h setConnectionType:[cur objectForKey:ProtocolKey]];
				[cat addHost:h];
				[h release];
			}
			[[ConnectionRegistry sharedRegistry] addCategory:cat];
			[_savedHosts addObject:cat];
			[cat release];
		}
	}
	[ud removeObjectForKey:HostsKey];
	[savedHosts setDataSource:self];
	[savedHosts setDelegate:self];
	
	[self refreshHosts];
	
	//have a timer to remove completed transfers
	[NSTimer scheduledTimerWithTimeInterval:10
									 target:self
								   selector:@selector(cleanTransferTable:)
								   userInfo:nil
									repeats:YES];
	
	[[NSNotificationCenter defaultCenter] addObserver:self 
											 selector:@selector(registryChanged:) 
												 name:CKRegistryChangedNotification 
											   object:nil];
	//[self runAutomatedScript];
}

- (void)hostnameChanged:(id)sender
{
	[[savedHosts itemAtRow:[savedHosts selectedRow]] setHost:[sender stringValue]];
}

- (void)portChanged:(id)sender
{
	[[savedHosts itemAtRow:[savedHosts selectedRow]] setPort:[sender stringValue]];
}

- (void)usernameChanged:(id)sender
{
	[[savedHosts itemAtRow:[savedHosts selectedRow]] setUsername:[sender stringValue]];
}

- (void)passwordChanged:(id)sender
{
	[[savedHosts itemAtRow:[savedHosts selectedRow]] setPassword:[sender stringValue]];
}

- (void)initialDirectoryChanged:(id)sender
{
	[[savedHosts itemAtRow:[savedHosts selectedRow]] setInitialPath:[sender stringValue]];
}

- (void)urlChanged:(id)sender
{
	[[savedHosts itemAtRow:[savedHosts selectedRow]] setURL:[NSURL URLWithString:[sender stringValue]]];
}

- (void)registryChanged:(NSNotification *)n
{
	[savedHosts reloadData];
}

- (void)newCategory:(id)sender
{
	id parent = [savedHosts itemAtRow:[savedHosts selectedRow]];
	if ([parent isKindOfClass:[CKHost class]])
	{
		parent = [parent category];
	}

	CKHostCategory *cat = [[CKHostCategory alloc] initWithName:NSLocalizedString(@"New Category", @"new cat name")];
	if (parent)
	{
		[parent addChildCategory:cat];
	}
	else
	{
		[[ConnectionRegistry sharedRegistry] addCategory:cat];
	}
	[cat release];
}

- (void)newHost:(id)sender
{
	id parent = [savedHosts itemAtRow:[savedHosts selectedRow]];
	if ([parent isKindOfClass:[CKHost class]])
	{
		parent = [parent category];
	}
	
	CKHost *h = [[CKHost alloc] init];
	if (parent)
	{
		[parent addHost:h];
	}
	else
	{
		[[ConnectionRegistry sharedRegistry] addHost:h];
	}
	[h release];
}

- (void)checkForFile:(id)sender
{
	if (!check)
	{
		check = [[InputDialog alloc] init];
		[check setDialogTitle:@"Find File"];
	}
	[check beginSheetModalForWindow:window delegate:self selector:@selector(fileCheck:receivedValue:)];
}

- (void)fileCheck:(InputDialog *)input receivedValue:(NSString *)val
{
	if (val)
	{
		[con checkExistenceOfPath:val];
	}
}

- (void)connectionTypeChanged:(id)sender
{
	[[savedHosts itemAtRow:[savedHosts selectedRow]] setConnectionType:[sender titleOfSelectedItem]];
}

- (void)cleanTransferTable:(NSTimer *)timer
{
	NSMutableArray *completed = [NSMutableArray array];
	NSEnumerator *e = [transfers objectEnumerator];
	FileTransfer *cur;
	
	while (cur = [e nextObject]) {
		if ([cur isCompleted]) 
			[completed addObject:cur];
	}
	[transfers removeObjectsInArray:completed];
	[transferTable reloadData];
}

- (void)disconnect:(id)sender
{
	[con disconnect];
}

- (void)refreshHosts
{
	[savedHosts reloadData];
}

- (void)savedHostsChanged:(id)sender
{
	id selected = [savedHosts itemAtRow:[savedHosts selectedRow]];
	
	if ([selected isKindOfClass:[CKHost class]])
	{
		CKHost *host = selected;
		
		[host createDropletAtPath:NSHomeDirectory()];
		
		[cHost setStringValue:[host host]];
		[cUser setStringValue:[host username]];
		[cPort setStringValue:[host port]];
		if ([host initialPath])
			[initialDirectory setStringValue:[host initialPath]];
		else
			[initialDirectory setStringValue:@""];
		
		if ([host connectionType])
			[cTypePopup selectItemWithTitle:[host connectionType]];
		
		NSString *pass = [host password];
		if (pass)
			[cPass setStringValue:pass];
		else
			[cPass setStringValue:@""];
		
		[connectWindow makeFirstResponder:cPass];
	}
	
}

- (void)saveHost:(id)sender
{
	NSMutableDictionary *d = [NSMutableDictionary dictionary];
	NSString *h = [cHost stringValue];
	NSString *u = [cUser stringValue];
	NSString *pass = [cPass stringValue];
	NSString *p = [cPort stringValue];
	NSString *url = [cURL stringValue];
	NSString *dir = [initialDirectory stringValue];
	NSString *protocol = [cTypePopup titleOfSelectedItem];
	
	if (h && u)
	{
		[d setObject:h forKey:HostKey];
		[d setObject:u forKey:UsernameKey];
		if (p)
			[d setObject:p forKey:PortKey];
		if (url)
			[d setObject:url forKey:URLKey];
		if (pass)
			[Controller keychainSetPassword:pass forServer:h account:u];
		if (dir)
			[d setObject:dir forKey:InitialDirectoryKey];
		if (![protocol isEqualToString:@"Auto Select"])
			[d setObject:protocol forKey:ProtocolKey];
		
		[_savedHosts addObject:d];
		[[NSUserDefaults standardUserDefaults] setObject:_savedHosts forKey:HostsKey];
		[[NSUserDefaults standardUserDefaults] synchronize];
		[self refreshHosts];
	}
}

- (IBAction)cancelConnect:(id)sender
{
	[connectWindow orderOut:self];
	[NSApp endSheet:connectWindow];
}

- (void)runAutomatedScript
{
	NSError *err = nil;
	con = [[AbstractConnection connectionWithName:@"FTP"
											 host:@"localhost"
											 port:@"21"
										 username:@"ghulands"
										 password:[Controller keychainPasswordForServer:@"localhost" account:@"ghulands"]
											error:&err] retain];
	if (!con)
	{
		if (err)
		{
			[NSApp presentError:err];
		}
		return;
	}
	
	[con connect];
	[con changeToDirectory:@"Sites/sandvox"];
	NSString *path = @"/Users/ghulands/Desktop/StockPhotos/";
	NSFileManager *fm = [NSFileManager defaultManager];
	NSEnumerator *e = [[fm directoryContentsAtPath:path] objectEnumerator];
	NSString *cur;
	while (cur = [e nextObject]) {
		NSString *file = [NSString stringWithFormat:@"%@%@", path, cur];
		BOOL isDir;
		if ([fm fileExistsAtPath:file isDirectory:&isDir] && !isDir) {
			[con uploadFile:file];
			[self uploadFile:file to:[NSString stringWithFormat:@"%@", [cur lastPathComponent]]];
			[transferTable reloadData];
		}
	}
}

- (IBAction)connect:(id)sender
{
	NSError *err = nil;
	if ([[cTypePopup titleOfSelectedItem] isEqualToString:AutoSelect])
	{
		if ([[cURL stringValue] length] > 0)
			con = [[AbstractConnection connectionWithURL:[NSURL URLWithString:[cURL stringValue]] error:&err] retain];
		else
			con = [[AbstractConnection connectionToHost:[cHost stringValue]
												   port:[cPort stringValue]
											   username:[cUser stringValue]
											   password:[cPass stringValue]
												  error:&err] retain];
	}
	else
	{
		con = [[AbstractConnection connectionWithName:[cTypePopup titleOfSelectedItem]
												 host:[cHost stringValue]
												 port:[cPort stringValue]
											 username:[cUser stringValue]
											 password:[cPass stringValue]
												error:&err] retain];
	}
	
	if (!con)
	{
		if (err)
		{
			[NSApp presentError:err];
		}
		return;
	}
	
	NSTextStorage *textStorage = [log textStorage];
	[textStorage setDelegate:self];		// get notified when text changes
	[con setTranscript:textStorage];
	[[fileCheckLog textStorage] setDelegate:self];
	[con setProperty:[fileCheckLog textStorage] forKey:@"RecursiveDirectoryDeletionTranscript"];
	[con setProperty:[fileCheckLog textStorage] forKey:@"FileCheckingTranscript"];
	
	[con setDelegate:self];
	[self cancelConnect:sender];
	
	if ([btnBrowseHost state] == NSOnState)
	{
		ConnectionOpenPanel *browse = [ConnectionOpenPanel connectionOpenPanel:con];
		[browse setCanCreateDirectories:YES];
		[browse setCanChooseDirectories:YES];
		[browse setCanChooseFiles:YES];
		[browse setAllowsMultipleSelection:YES];
		
		[browse beginSheetForDirectory:[initialDirectory stringValue]
								  file:nil
						modalForWindow:window
						 modalDelegate:self
						didEndSelector:@selector(browse:returnCode:contextInfo:)
						   contextInfo:nil];
		[con release];
    con = nil;  //we are not responsible for it, the open connection panel will release it.
	}
	else
	{
		[status setStringValue:[NSString stringWithFormat:@"Connecting to: %@", [cHost stringValue]]];
		[con connect];
	}
}

- (void)browse:(ConnectionOpenPanel *)panel returnCode:(int)returnCode contextInfo:(id)ui
{
	if (returnCode == NSOKButton)
	{
		NSRunAlertPanel (@"Files Selected", [[panel filenames] description], @"OK", nil, nil);
	}
	else
	{
		NSRunAlertPanel(@"Open Panel Cancelled",@"The panel was cancelled by the user",@"OK",nil,nil);
	}
}

- (IBAction)deleteFile:(id)sender
{
	int row = [remoteTable selectedRow];
	
	NSDictionary *d = [remoteFiles objectAtIndex:row];
	if ([[d objectForKey:NSFileType] isEqualToString:NSFileTypeRegular] ||
		[[d objectForKey:NSFileType] isEqualToString:NSFileTypeSymbolicLink])
	{
		NSString *file = [[con currentDirectory] stringByAppendingPathComponent:[d objectForKey:cxFilenameKey]];
		[con deleteFile:file];
	}
	else
	{
		if (NSRunAlertPanel(@"Delete Directory?",@"Would you like to recursively delete the directory?",@"Recursive",@"Normal",nil) == NSOKButton)
		{
			[con recursivelyDeleteDirectory:[[con currentDirectory] stringByAppendingPathComponent:[d objectForKey:cxFilenameKey]]];
		}
		else
		{
			[con deleteDirectory:[[con currentDirectory] stringByAppendingPathComponent:[d objectForKey:cxFilenameKey]]];
		}
	}
}

- (IBAction)localFileSelected:(id)sender
{
}

- (void)localDoubleClick:(id)sender
{
	int row = [sender selectedRow];
	
	if (row >= 0 && row < [localFiles count])
	{
		BOOL isDir;
		if ([[NSFileManager defaultManager] fileExistsAtPath:[localFiles objectAtIndex:row] 
												 isDirectory:&isDir] && isDir)
		{
			[currentLocalPath autorelease];
			currentLocalPath = [[localFiles objectAtIndex:row] copy];
			[self refreshLocal];
		}
		else
		{
			NSString *file = [localFiles objectAtIndex:row];
			[self uploadFile:file to:[[con currentDirectory] stringByAppendingPathComponent:[file lastPathComponent]]];
			[transferTable reloadData];
		}
	}
}

- (IBAction)localPopupChanged:(id)sender
{
	NSString *str = [[sender selectedItem] representedObject];
	[currentLocalPath autorelease];
	if ([str length] > 1)
		currentLocalPath = [[str substringToIndex:[str length] - 1] copy];
	else
		currentLocalPath = [str copy];
	[self refreshLocal];
}

- (IBAction)newFolder:(id)sender
{
	InputDialog *input = [[InputDialog alloc] init];
	[input setDialogTitle:@"Enter New Folder Name"];
	[input beginSheetModalForWindow:window delegate:self selector:@selector(newFolderValue:)];
}

- (IBAction)logConfig:(id)sender
{
	[KTLogger configure:self];
}

- (void)newFolderValue:(NSString *)val
{
	if (val)
	{
		NSString *dir = [[con currentDirectory] stringByAppendingPathComponent:val];
		[con createDirectory:dir];
		[con contentsOfDirectory:[con currentDirectory]];
	}
}

- (IBAction)permissions:(id)sender
{
	NSMutableDictionary *file = [remoteFiles objectAtIndex:[remoteTable selectedRow]];
	[[PermissionsController sharedPermissions] displayFile:file
													 sheet:window
												connection:con];
}

- (IBAction)refresh:(id)sender
{
	[con contentsOfDirectory:[con currentDirectory]];
}

- (IBAction)remoteFileSelected:(id)sender
{
	int idx = [sender selectedRow];
	
	if (idx >= 0 && idx < [remoteFiles count])
	{
		[btnDelete setEnabled:YES];
		[btnPermissions setEnabled:YES];
		
	}
	else
	{
		[btnDelete setEnabled:NO];
		[btnPermissions setEnabled:NO];
		
	}
}

- (void)remoteDoubleClick:(id)sender
{
	int row = [sender selectedRow];
	
	if (row >= 0 && row < [remoteFiles count])
	{
		NSDictionary *attribs = [remoteFiles objectAtIndex:row];
		
		if ([[attribs objectForKey:NSFileType] isEqualToString:NSFileTypeDirectory])
		{
			NSString *path = [[con currentDirectory] stringByAppendingPathComponent:[attribs objectForKey:cxFilenameKey]];
			[con changeToDirectory:path];
			[con contentsOfDirectory:path];
			//[remoteFiles removeAllObjects];
			return;
		}
		else if ([[attribs objectForKey:NSFileType] isEqualToString:NSFileTypeSymbolicLink])
		{
			NSString *target = [attribs objectForKey:cxSymbolicLinkTargetKey];
			if ([target characterAtIndex:[target length] - 1] == '/' || [target characterAtIndex:[target length] - 1] == '\\')
			{
				[con changeToDirectory:[attribs objectForKey:cxFilenameKey]];
				[con contentsOfDirectory:[attribs objectForKey:cxFilenameKey]];
				return;
			}
		}
		
		if ([[attribs objectForKey:NSFileType] isEqualToString:NSFileTypeRegular]) {
			[self downloadFile:[[con currentDirectory] stringByAppendingPathComponent:[attribs objectForKey:cxFilenameKey]]
							toFolder:currentLocalPath];
		}
		else if ([[attribs objectForKey:NSFileType] isEqualToString:NSFileTypeSymbolicLink])
		{
			NSString *target = [attribs objectForKey:cxSymbolicLinkTargetKey];
			if ([target characterAtIndex:[target length] - 1] != '/'  && [target characterAtIndex:[target length] - 1] != '\\')
				[self downloadFile:[[con currentDirectory] stringByAppendingPathComponent:[attribs objectForKey:cxFilenameKey]]
								toFolder: currentLocalPath];
		}
		
		[transferTable reloadData];
	}
}

- (IBAction)remotePopupChanged:(id)sender
{
	NSString *path = [[sender selectedItem] representedObject];
	[con changeToDirectory:path];
	[con contentsOfDirectory:path];
}

- (IBAction)showConnect:(id)sender
{
	//[self savedHostsChanged:savedHosts];
	[NSApp beginSheet:connectWindow
	   modalForWindow:window
		modalDelegate:nil
	   didEndSelector:nil
		  contextInfo:nil];
}

- (IBAction)stopTransfer:(id)sender
{
	[con cancelTransfer];
}

- (IBAction)transferSelected:(id)sender
{
	int idx = [sender selectedRow];
	
	if (idx >= 0 && idx < [transfers count])
	{
		[btnStop setEnabled:YES];
	}
	else
	{
		[btnStop setEnabled:NO];
	}
}

static NSImage *_folder = nil;

- (void)refreshRemoteUI
{
	//create popup menu
	NSString *dir = [con currentDirectory];
	NSArray *folders = [dir componentsSeparatedByString:@"/"];
	if ([dir isEqualToString:@"/"])
		folders = [folders subarrayWithRange:NSMakeRange(1, [folders count] - 1)];
	NSEnumerator *e = [folders objectEnumerator];
	NSMutableString *buildup = [NSMutableString string];
	NSString *cur;
	
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@"remote"];
	
	if (!_folder)
	{
		_folder = [[[NSWorkspace sharedWorkspace] iconForFile:@"/tmp"] retain];
		[_folder setSize:NSMakeSize(16,16)];
	}
	
	
	while (cur = [e nextObject])
	{
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:cur
													  action:nil
											   keyEquivalent:@""];
		[buildup appendFormat:@"/%@", cur];
		[item setRepresentedObject:[[buildup copy] autorelease]];
		[item setImage:_folder];
		[menu addItem:item];
	}
	
	[remotePopup setMenu:menu];
	[menu release];
	[remotePopup selectItem:[remotePopup lastItem]];
	
	[remoteTable reloadData];
}

- (void)refreshLocal
{
	[localPopup removeAllItems];
	
	//refresh file list
	NSArray *dir = [[NSFileManager defaultManager] directoryContentsAtPath:currentLocalPath];
	[localFiles removeAllObjects];
	NSEnumerator *e = [dir objectEnumerator];
	NSString *cur;
	
	while (cur = [e nextObject])
	{
		if ([cur characterAtIndex:0] != '.') //filter hidden files
			[localFiles addObject:[NSString stringWithFormat:@"%@/%@", currentLocalPath, cur]];
	}
	
	NSArray *pathComponents = [currentLocalPath componentsSeparatedByString:@"/"];
	
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@"local"];
	
	e = [pathComponents objectEnumerator];
	NSWorkspace *ws = [NSWorkspace sharedWorkspace];
	
	NSMutableString *buildup = [NSMutableString string];
	NSMenuItem *item;
	
	if ([pathComponents count] > 1)
	{
		while (cur = [e nextObject])
		{
			item = [[NSMenuItem alloc] initWithTitle:cur
											  action:nil
									   keyEquivalent:@""];
			[buildup appendFormat:@"%@/", cur];
			[item setRepresentedObject:[[buildup copy] autorelease]];
			NSImage *img = [ws iconForFile:buildup];
			[img setSize:NSMakeSize(16,16)];
			[item setImage:img];
			[menu addItem:item];
			[item release];
		}		
	}
	
	[localPopup setMenu:menu];
	[menu release];
	[localPopup selectItem:[localPopup lastItem]];
	[localTable reloadData];
}

- (void)printQueueDescription:(id)sender
{
	if ([con isKindOfClass:[AbstractQueueConnection class]]) {
		NSLog(@"Queue Description:\n%@", [(AbstractQueueConnection *)con queueDescription]);
	}
}

#pragma mark -
#pragma mark Outline View Data Source

- (int)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item
{
	if (item == nil)
	{
		return [[[ConnectionRegistry sharedRegistry] connections] count];
	}
	else if ([item isKindOfClass:[CKHostCategory class]])
	{
		return [[item childCategories] count];
	}
	return 0;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(int)index ofItem:(id)item
{
	if (item == nil)
	{
		return [[[ConnectionRegistry sharedRegistry] connections] objectAtIndex:index];
	}
	return [[item childCategories] objectAtIndex:index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item
{
	return [item isKindOfClass:[CKHostCategory class]] && [[item childCategories] count] > 0 ;
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item
{
	if ([item isKindOfClass:[CKHostCategory class]])
	{
		return [item name];
	}
	else
	{
		NSMutableString *str = [NSMutableString stringWithFormat:@"%@://", [AbstractConnection urlSchemeForConnectionName:[item connectionType] port:[item port]]];
		if ([item username] && ![[item username] isEqualToString:@""])
		{
			[str appendFormat:@"%@@", [item username]];
		}
		if ([item host])
		{
			[str appendString:[item host]];
		}
		
		return str;
	}
}

- (NSArray *)outlineView:(NSOutlineView *)outlineView namesOfPromisedFilesDroppedAtDestination:(NSURL *)dropDestination forDraggedItems:(NSArray *)items
{
	NSMutableArray *files = [NSMutableArray array];
	
	NSEnumerator *e = [items objectEnumerator];
	id cur;
	
	[files addObject:@"/tmp/configuration.ckhost"];
	
	return files;
}

#pragma mark -
#pragma mark Connection Helper Methods

+ (NSString *)formattedSpeed:(long) spd
{
	if (spd == 0) return @"0 B/s";
	NSString *suffix[] = {
		@"B", @"KB", @"MB", @"GB", @"TB", @"PB", @"EB"
	};
	
	int i, c = 7;
	long size = spd;
	
	for (i = 0; i < c && size >= 1024; i++) {
		size = size / 1024;
	}
	float rem = 0;
	
	if (i != 0)
		rem = (spd - (i * 1024)) / (i * 1024);
	
	NSString *ext = suffix[i];
	return [NSString stringWithFormat:@"%4.2f %@/s", size+rem, ext];
}

- (FileTransfer *)uploadForLocalFile:(NSString *)file
{
	NSEnumerator *e = [transfers objectEnumerator];
	FileTransfer *cur;
	
	while (cur = [e nextObject])
	{
		if ([[cur localFile] isEqualToString:file] &&
			[cur type] == UploadType )
			return cur;
	}
	return nil;
}

- (FileTransfer *)downloadForLocalFile:(NSString *)file
{
	NSEnumerator *e = [transfers objectEnumerator];
	FileTransfer *cur;
	
	while (cur = [e nextObject])
	{
		if ([[cur localFile] isEqualToString:file] &&
			[cur type] == DownloadType)
			return cur;
	}
	return nil;
}

- (FileTransfer *)uploadForRemoteFile:(NSString *)file
{
	NSEnumerator *e = [transfers objectEnumerator];
	FileTransfer *cur;
	
	while (cur = [e nextObject])
	{
		if ([[cur remoteFile] isEqualToString:file] &&
			[cur type] == UploadType )
			return cur;
	}
	return nil;
}

- (FileTransfer *)downloadForRemoteFile:(NSString *)file
{
	NSEnumerator *e = [transfers objectEnumerator];
	FileTransfer *cur;
	
	while (cur = [e nextObject])
	{
		if ([[cur remoteFile] isEqualToString:file] &&
			[cur type] == DownloadType)
			return cur;
	}
	return nil;
}

- (void)downloadFile:(NSString *)remote toFolder:(NSString *)local
{
	FileTransfer *t = [FileTransfer downloadFile:remote to:local];
	[transfers addObject:t];
	[con downloadFile:remote
		  toDirectory:local
			overwrite:YES];
}

- (void)uploadFile:(NSString *)local to:(NSString *)remote
{
	FileTransfer *t = [FileTransfer uploadFile:local to:remote];
	[transfers addObject:t];
	[con uploadFile:local toFile:remote];
}

- (void)recursivelyUploadContentsAtPath:(NSString *)aFolderPath serverPath:(NSString *)aServerPath
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
    NSEnumerator *directoryEnum = [[fileManager directoryContentsAtPath:aFolderPath] objectEnumerator];
    NSString *nextFile = nil;
	
	[con createDirectory:aServerPath];
	
    while (nextFile = [directoryEnum nextObject])
    {
        NSString *fullLocalPath = [aFolderPath stringByAppendingPathComponent:nextFile];
        NSString *fullServerPath = [aServerPath stringByAppendingPathComponent:nextFile];
        BOOL isDir;
		
        if ([nextFile hasPrefix:@"."])
        {
            continue;
        }
        
        if ([fileManager fileExistsAtPath:fullLocalPath isDirectory:&isDir] && isDir)
        {            
            [self recursivelyUploadContentsAtPath:fullLocalPath serverPath:fullServerPath];
        }
        else
        {
            [self uploadFile:fullLocalPath to:fullServerPath];
        }
    }
}

- (void)uploadFolderContentsAtPath:(NSString *)aFolderPath
{
	NSString *serverCurrentDirectory = [[con currentDirectory] stringByAppendingPathComponent:[aFolderPath lastPathComponent]];
	[self recursivelyUploadContentsAtPath:aFolderPath serverPath:serverCurrentDirectory];
	[transferTable reloadData];
}

#pragma mark -
#pragma mark Connection Delegate Methods

- (BOOL)connection:(id <AbstractConnectionProtocol>)con authorizeConnectionToHost:(NSString *)host message:(NSString *)message;
{
	if (NSRunAlertPanel(@"Authorize Connection?", @"%@\nHost: %@", @"Yes", @"No", nil, message, host) == NSOKButton)
		return YES;
	return NO;
}

- (void)connection:(AbstractConnection *)aConn didConnectToHost:(NSString *)host
{
	isConnected = YES;
	[status setStringValue:[NSString stringWithFormat:@"Connected to: %@", host]];
	[btnRefresh setEnabled:YES];
	[remotePopup setHidden:NO];
	[btnNewFolder setEnabled:YES];
	[remoteTable setHidden:NO];
	[btnDisconnect setEnabled:YES];
	NSString *dir = [[initialDirectory stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (dir && [dir length] > 0)
		[con changeToDirectory:[initialDirectory stringValue]];
	[con contentsOfDirectory:[con currentDirectory]];
}

- (void)connection:(AbstractConnection *)aConn didDisconnectFromHost:(NSString *)host
{
	isConnected = NO;
	[status setStringValue:[NSString stringWithFormat:@"Disconnected from: %@", host]];
	[btnRefresh setEnabled:NO];
	[btnDelete setEnabled:NO];
	[btnNewFolder setEnabled:NO];
	[btnPermissions setEnabled:NO];
	[btnStop setEnabled:NO];
	[btnDisconnect setEnabled:NO];
	[remotePopup setHidden:YES];
	[btnNewFolder setEnabled:NO];
	[remoteTable setHidden:YES];
	
	[con release];
	con = nil;
}

- (void)connection:(AbstractConnection *)aConn didReceiveError:(NSError *)error
{
	NSLog(@"%@: %@", NSStringFromSelector(_cmd), error);
	NSRunAlertPanel(@"Error",@"Connection returned an error: %@",@"OK",nil
					,nil, [error localizedDescription]);
}

- (void)connectionDidSendBadPassword:(AbstractConnection *)aConn
{
	NSRunAlertPanel(@"Bad Password",@"The Password you entered is no good. Please re-enter it and try again.",@"OK",nil, nil);
	[self showConnect:self];
}

- (NSString *)connection:(AbstractConnection *)aConn needsAccountForUsername:(NSString *)username
{
	[status setStringValue:[NSString stringWithFormat:@"Need Account for %@ not implemented", username]];
	return nil;
}

- (void)connection:(AbstractConnection *)aConn didCreateDirectory:(NSString *)dirPath
{
	[status setStringValue:[NSString stringWithFormat:@"Created Directory: %@", dirPath]];
}

- (void)connection:(AbstractConnection *)aConn didSetPermissionsForFile:(NSString *)path
{
	
}

- (void)connection:(AbstractConnection *)aConn didRenameFile:(NSString *)from to:(NSString *)toPath
{
	
}

- (void)connection:(AbstractConnection *)aConn didDeleteFile:(NSString *)path
{
	[con contentsOfDirectory:[con currentDirectory]];
}

- (void)connection:(AbstractConnection *)aConn didDeleteDirectory:(NSString *)path
{
	[con contentsOfDirectory:[con currentDirectory]];
}


- (void)connection:(AbstractConnection *)aConn didReceiveContents:(NSArray *)contents ofDirectory:(NSString *)dirPath
{
	NSLog(@"%@ %@", NSStringFromSelector(_cmd), dirPath);
	[remoteFiles removeAllObjects];
	[remoteFiles addObjectsFromArray:[contents filteredArrayByRemovingHiddenFiles]];
	[self refreshRemoteUI];
}

- (void)connection:(id <AbstractConnectionProtocol>)con uploadDidBegin:(NSString *)upload
{
	[[self uploadForRemoteFile:upload] setPercentTransferred:[NSNumber numberWithInt:0]];
	[transferTable reloadData];
}

- (void)connection:(id <AbstractConnectionProtocol>)conn upload:(NSString *)remotePath progressedTo:(NSNumber *)percent
{
	[[self uploadForRemoteFile:remotePath] setPercentTransferred:percent];
	[transferTable reloadData];
	[status setStringValue:[Controller formattedSpeed:[con transferSpeed]]];
}

- (void)connection:(id <AbstractConnectionProtocol>)conn uploadDidFinish:(NSString *)remotePath
{	
	[[self uploadForRemoteFile:remotePath] setCompleted:YES];
	[con contentsOfDirectory:[con currentDirectory]];
	[transferTable reloadData];
}

- (void)connection:(id <AbstractConnectionProtocol>)con downloadDidBegin:(NSString *)remotePath
{
	downloadCounter = 0;
	[[self downloadForRemoteFile:remotePath] setPercentTransferred:[NSNumber numberWithInt:0]];
	[transferTable reloadData];
}

- (void)connection:(id <AbstractConnectionProtocol>)conn download:(NSString *)path progressedTo:(NSNumber *)percent
{
	[[self downloadForRemoteFile:path] setPercentTransferred:percent];
	[transferTable reloadData];
	[status setStringValue:[Controller formattedSpeed:[con transferSpeed]]];
}

- (void)connection:(id <AbstractConnectionProtocol>)con downloadDidFinish:(NSString *)remotePath
{
	[[self downloadForRemoteFile:remotePath] setCompleted:YES];
	[transferTable reloadData];
	[self refreshRemoteUI];
	[self refreshLocal];
}

- (void)connection:(id <AbstractConnectionProtocol>)con checkedExistenceOfPath:(NSString *)path pathExists:(BOOL)exists
{
	if (exists)
	{
		NSRunAlertPanel(@"File Exists", @"Found path: %@", @"OK", nil, nil, path);
	}
	else
	{
		NSRunAlertPanel(@"File Not Found", @"Could not find path: %@", @"OK", nil, nil, path);
	}
}

#pragma mark -
#pragma mark NSTableView DataSource Methods

- (int)numberOfRowsInTableView:(NSTableView *)aTable
{
	if (aTable == remoteTable)
		return [remoteFiles count];
	else if (aTable == localTable)
		return [localFiles count];
	else if (aTable == transferTable)
		return [transfers count];
	return 0;
}

static NSImage *folder = nil;
static NSImage *upload = nil;
static NSImage *download = nil;
static NSImage *symFolder = nil;
static NSImage *symFile = nil;
NSString *IconKey = @"Icon";

- (id)tableView:(NSTableView *)aTable objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex
{
	NSString *identifier = [aTableColumn identifier];
	
	if (aTable == remoteTable)
	{
		NSMutableDictionary *row = [remoteFiles objectAtIndex:rowIndex];
		
		if ([identifier isEqualToString:@"icon"])
		{
			NSImage *img = [row objectForKey:IconKey];
			if (!img)
			{
				if ([[row objectForKey:NSFileType] isEqualToString:NSFileTypeDirectory])
				{
					if (!folder)
						folder = [[[NSWorkspace sharedWorkspace] iconForFile:@"/tmp"] retain];
					img = folder;
				}
				else if ([[row objectForKey:NSFileType] isEqualToString:NSFileTypeSymbolicLink])
				{
					if (!symFolder || !symFile)
					{
						symFolder = [[NSImage imageNamed:@"symlink_folder.tif"] retain];
						symFile = [[NSImage imageNamed:@"symlink_file.tif"] retain];
					}
					NSString *target = [row objectForKey:cxSymbolicLinkTargetKey];
					if ([target characterAtIndex:[target length] - 1] == '/' || [target characterAtIndex:[target length] - 1] == '\\')
						img = symFolder;
					else
					{
						NSImage *fileType = [[NSWorkspace sharedWorkspace] iconForFileType:[[row objectForKey:cxFilenameKey] pathExtension]];
						NSImage *comp = [[NSImage alloc] initWithSize:NSMakeSize(16,16)];
						[img setScalesWhenResized:YES];
						[img setSize:NSMakeSize(16,16)];
						[comp lockFocus];
						[fileType drawInRect:NSMakeRect(0,0,16,16) fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
						[symFile drawInRect:NSMakeRect(0,0,16,16) fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
						[comp unlockFocus];
						[comp autorelease];
						img = comp;
					}
				}
				else
				{
					img = [[NSWorkspace sharedWorkspace] iconForFileType:[[row objectForKey:cxFilenameKey] pathExtension]];
				}
				[img setSize:NSMakeSize(16,16)];
				[row setObject:img forKey:IconKey];
			}
			
			return img;
		}
		else if ([identifier isEqualToString:@"name"])
		{
			return [row objectForKey:cxFilenameKey];
		}
		else if ([identifier isEqualToString:@"size"])
		{
			//if ([[row objectForKey:NSFileType] isEqualToString:NSFileTypeDirectory])
			//	return nil;
			return [NSString formattedFileSizeWithBytes:[row objectForKey:NSFileSize]];
		}
		else if ([identifier isEqualToString:@"modified"])
		{
			return [row objectForKey:NSFileModificationDate];
		}
	}
	else if (aTable == transferTable)
	{
		FileTransfer *transfer = [transfers objectAtIndex:rowIndex];
		if ([identifier isEqualToString:@"image"])
		{
			if ([transfer type] == DownloadType)
			{
				if (!download)
					download = [[NSImage imageNamed:@"download.tif"] retain];
				return download;
			}
			else
			{
				if (!upload)
					upload = [[NSImage imageNamed:@"upload.tif"] retain];
				return upload;
			}
		}
		else if ([identifier isEqualToString:@"icon"])
		{
			NSImage *img = [[NSWorkspace sharedWorkspace] iconForFileType:[[transfer remoteFile] pathExtension]];
			[img setSize:NSMakeSize(16,16)];
			return img;
		}
		else if ([identifier isEqualToString:@"name"])
			return [transfer remoteFile];
		else if ([identifier isEqualToString:@"progress"])
			return [transfer percentTransferred];
	}
	else if (aTable == localTable)
	{
		NSString *file = [localFiles objectAtIndex:rowIndex];
		NSFileManager *fm = [NSFileManager defaultManager];
		NSDictionary *attribs = [fm fileAttributesAtPath:file traverseLink:YES];
		
		if ([identifier isEqualToString:@"icon"])
		{
			NSImage *img = [[NSWorkspace sharedWorkspace] iconForFile:file];
			[img setSize:NSMakeSize(16,16)];
			return img;
		}
		else if ([identifier isEqualToString:@"name"])
		{
			return [file lastPathComponent];
		}
		else if ([identifier isEqualToString:@"size"])
		{
			BOOL isDir;
			if ([fm fileExistsAtPath:file isDirectory:&isDir] && isDir)
				return nil;
			return [NSString formattedFileSizeWithBytes:[attribs objectForKey:NSFileSize]];
		}
		else if ([identifier isEqualToString:@"modified"])
		{
			return [attribs objectForKey:NSFileModificationDate];
		}
	}
	
	return nil;
}

- (NSView *) tableView:(NSTableView *) tableView viewForRow:(int) row
{
	return [[[transfers objectAtIndex:row] objectForKey:TransferControllerKey] view];
}

- (BOOL)tableView:(NSTableView *)tableView writeRows:(NSArray *)rows toPasteboard:(NSPasteboard *)pboard
{
	if (tableView == localTable)
	{
		NSMutableArray *files = [NSMutableArray array];
		NSEnumerator *e = [rows objectEnumerator];
		NSNumber *cur;
		while (cur = [e nextObject])
		{
			NSString *file = [localFiles objectAtIndex:[cur intValue]];
			[files addObject:file];
		}
		[pboard declareTypes:[NSArray arrayWithObject:cxLocalFilePBoardType] owner:nil];
		[pboard setPropertyList:files forType:cxLocalFilePBoardType]; //
		return YES;
	}
	else if (tableView == remoteTable)
	{
		NSMutableArray *f = [NSMutableArray array];
		NSEnumerator *e = [rows objectEnumerator];
		NSNumber *cur;
		while (cur = [e nextObject])
		{
			NSDictionary *file = [remoteFiles objectAtIndex:[cur intValue]];
			if ([[file objectForKey:NSFileType] isEqualToString:NSFileTypeRegular])
				[f addObject:[file objectForKey:cxFilenameKey]];
			else if ([[file objectForKey:NSFileType] isEqualToString:NSFileTypeSymbolicLink])
			{
				NSString *target = [file objectForKey:cxSymbolicLinkTargetKey];
				if ([target characterAtIndex:[target length] - 1] != '/'  && [target characterAtIndex:[target length] - 1] != '\\')
					[f addObject:[file objectForKey:cxFilenameKey]];
			}
		}
		[pboard declareTypes:[NSArray arrayWithObject:cxRemoteFilePBoardType] owner:nil];
		[pboard setPropertyList:f forType:cxRemoteFilePBoardType];
		return YES;
	}
	return NO;
}

- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id <NSDraggingInfo>)info row:(int)row dropOperation:(NSTableViewDropOperation)operation
{
	NSPasteboard *pb = [info draggingPasteboard];
	if (tableView == localTable) //do a download
	{
		NSArray *files = [pb propertyListForType:cxRemoteFilePBoardType];
		NSEnumerator *e = [files objectEnumerator];
		NSString *cur;
		
		while (cur = [e nextObject])
		{
			[self downloadFile:[[con currentDirectory] stringByAppendingPathComponent:cur]
							toFolder: currentLocalPath];
		}
		[transferTable reloadData];
		return YES;
	}
	else if (tableView == remoteTable) //do an upload
	{
		if ([[pb types] containsObject:cxLocalFilePBoardType])
		{
			NSArray *files = [pb propertyListForType:cxLocalFilePBoardType];
			NSEnumerator *e = [files objectEnumerator];
			NSString *cur;
			
			while (cur = [e nextObject])
			{
				[self uploadFile:cur to:[[con currentDirectory] stringByAppendingPathComponent:[cur lastPathComponent]]];
			}
			[transferTable reloadData];
			
			return YES;
		}
		else if ([[pb types] containsObject:NSFilenamesPboardType])
		{
			NSFileManager *fm = [NSFileManager defaultManager];
			NSArray *files = [pb propertyListForType:NSFilenamesPboardType];
			NSEnumerator *e = [files objectEnumerator];
			NSString *cur;
			BOOL isDir;
			
			NSString *curRemoteDir = [[con currentDirectory] copy];
			
			while (cur = [e nextObject])
			{
				CKTransferRecord *root = [con recursivelyUpload:cur to:[con currentDirectory]];
			}
			[curRemoteDir release];
			[transferTable reloadData];
			return YES;
		}
	}
	return NO;
}

- (NSDragOperation)tableView:(NSTableView *)tableView 
				validateDrop:(id <NSDraggingInfo>)info 
				 proposedRow:(int)row 
	   proposedDropOperation:(NSTableViewDropOperation)operation
{
	if (!isConnected)
		return NSDragOperationNone;
	if (tableView == localTable || tableView == remoteTable)
		return NSDragOperationCopy;
	return NSDragOperationNone;
}

#pragma mark -
#pragma mark NSTextView Delegate Methods
/*!	Called as a delegate of the log's text storage, so we can update the scroll position
*/
- (void)textStorageDidProcessEditing:(NSNotification *)aNotification
{
	if ([aNotification object] == [log textStorage])
		[self performSelector:@selector(scrollToVisible:) withObject:log afterDelay:0.0];
	else
		[self performSelector:@selector(scrollToVisible:) withObject:fileCheckLog afterDelay:0.0];
	// Don't scroll now, do it in a moment. Doing it now causes error messgaes.
}

- (void) scrollToVisible:(id)whichLog
{
	[whichLog scrollRangeToVisible:NSMakeRange([[whichLog textStorage] length], 0)];
}

#pragma mark -
#pragma mark Keychain wrapper utilities

// Courtesy of Dan Wood / Biophony, LLC.

/*!	Get the appropriate keychain password.  Returns null if it couldn't be found or there was some other error
*/
+ (NSString *)keychainPasswordForServer:(NSString *)aServerName account:(NSString *)anAccountName
{
	NSString *result = nil;
	if ([aServerName length] > 255 || [anAccountName length] > 255)
	{
		return result;
	}
		
	Str255 serverPString, accountPString;
	
	c2pstrcpy(serverPString, [aServerName UTF8String]);
	c2pstrcpy(accountPString, [anAccountName UTF8String]);
	
	char passwordBuffer[256];
	UInt32 actualLength;
	OSStatus theStatus;
	
	theStatus = KCFindInternetPassword (
									 serverPString,			// StringPtr serverName,
									 NULL,					// StringPtr securityDomain,
									 accountPString,		// StringPtr accountName,
									 kAnyPort,				// UInt16 port,
									 kAnyProtocol,			// OSType protocol,
									 kAnyAuthType,			// OSType authType,
									 255,					// UInt32 maxLength,
									 passwordBuffer,		// void * passwordData,
									 &actualLength,			// UInt32 * actualLength,
									 nil					// KCItemRef * item
									 );
	if (noErr == theStatus)
	{
		passwordBuffer[actualLength] = 0;		// make it a legal C string by appending 0
		result = [NSString stringWithUTF8String:passwordBuffer];
	}
	return result;
}


/*!	Set the given password.  Returns YES if successful.
*/

+ (BOOL) keychainSetPassword:(NSString *)inPassword forServer:(NSString *)aServer account:(NSString *)anAccount
{
	Str255 serverPString, accountPString;
	
	if ([aServer length] > 255 || [anAccount length] > 255)
	{
		return NO;
	}
	
	c2pstrcpy(serverPString, [aServer UTF8String]);
	c2pstrcpy(accountPString, [anAccount UTF8String]);
	
	const char *passwordUTF8 = [inPassword UTF8String];
	
	char passwordBuffer[256];
	OSStatus theStatus;
	KCItemRef itemRef;
	UInt32 actualLength;
	
	// See if there is already one matching this server/account
	theStatus = KCFindInternetPassword (
									 serverPString,			// StringPtr serverName,
									 NULL,					// StringPtr securityDomain,
									 accountPString,		// StringPtr accountName,
									 kAnyPort,				// UInt16 port,
									 kAnyProtocol,			// OSType protocol,
									 kAnyAuthType,			// OSType authType,
									 255,					// UInt32 maxLength,
									 passwordBuffer,		// void * passwordData,
									 &actualLength,			// UInt32 * actualLength,
									 &itemRef				// KCItemRef * item
									 );
	
	if (noErr == theStatus)            // Found already? If so, delete it!
	{
		theStatus = KCDeleteItem(itemRef);
		theStatus = KCReleaseItem(&itemRef);
	}
	
	// Now add in entry
	theStatus = KCAddInternetPassword (
									serverPString,			// StringPtr serverName,
									nil,					// StringPtr securityDomain,
									accountPString,			// StringPtr accountName,
									kAnyPort,				// UInt16 port,
									kAnyProtocol,			// OSType protocol,
									kAnyAuthType,			// OSType authType,
									strlen(passwordUTF8),	// UInt32 passwordLength,
									passwordUTF8,			// const void * passwordData,
									nil						// KCItemRef * item
									);
	return (noErr == theStatus);
}

#pragma mark -
#pragma mark NSApplication Delegate Methods

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
	if ([con numberOfTransfers] > 0) {
		if (NSRunAlertPanel(@"Transfers in Progress", @"Are you sure you want to quit while there are still file transfers in progress?", @"Yes Quit", @"No", nil) != NSOKButton)
			return NSTerminateCancel;
	}
	NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
	[ud setObject:NSStringFromRect([window frame]) 
		   forKey:[window frameAutosaveName]];
	[ud setBool:[logDrawer state] == NSDrawerOpenState forKey:@"showLog"];
	return NSTerminateNow;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication
{
	return YES;
}

@end
