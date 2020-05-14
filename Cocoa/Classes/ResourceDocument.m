#import "ResourceDocument.h"
#import "ResourceDataSource.h"
#import "ResourceNameCell.h"
#import "Resource.h"
#import "ApplicationDelegate.h"
#import "OpenPanelDelegate.h"
#import "OutlineViewDelegate.h"
#import "InfoWindowController.h"
#import "PrefsController.h"
#import "CreateResourceSheetController.h"
#import "../Categories/NGSCategories.h"
#import "../Categories/NSOutlineView-SelectedItems.h"
#import <Carbon/Carbon.h>

#import "../Plug-Ins/ResKnifePluginProtocol.h"
#import "RKEditorRegistry.h"


NSString *DocumentInfoWillChangeNotification = @"DocumentInfoWillChangeNotification";
NSString *DocumentInfoDidChangeNotification = @"DocumentInfoDidChangeNotification";
extern NSString *RKResourcePboardType;

@implementation ResourceDocument
@synthesize creator;
@synthesize type;

- (instancetype)init
{
	if (self = [super init]) {
		creator = 'ResK';
		type = 'rsrc';
	}
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark -
#pragma mark File Management

/*!
@method			readFromFile:ofType:
@abstract		Open the specified file and read its resources.
@description	Open the specified file and read its resources. This first tries to load the resources from the res fork, and failing that tries the data fork.
@author			Nicholas Shanks
@updated		2003-11-08 NGS:	Now handles opening user-selected forks.
*/

- (BOOL)readFromURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError **)outError
{
	BOOL			succeeded = NO;
	OSStatus		error = noErr;
	FSRef			*fileRef = (FSRef *) NewPtrClear(sizeof(FSRef));
	ResFileRefNum	fileRefNum = 0;
	OpenPanelDelegate *openPanelDelegate = [(ApplicationDelegate *)[NSApp delegate] openPanelDelegate];
	
	error = FSPathMakeRef((const UInt8 *)[url fileSystemRepresentation], fileRef, nil);
    if (error) {
        *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:error userInfo:nil];
        return NO;
    }
    
    SetResLoad(false); // don't load "preload" resources
	// find out which fork to parse
    NSMutableArray *forks = [ForkInfo forksForFile:fileRef];
    ForkInfo *selectedFork = [openPanelDelegate getSelectedFork];
    if (selectedFork) {
        // If fork was selected from open panel, try this fork only
        error = FSOpenResourceFile(fileRef, selectedFork.uniName.length, (UniChar *)selectedFork.uniName.unicode, fsRdPerm, &fileRefNum);
        if (!error && fileRefNum) {
        } else if (!selectedFork.physicalSize) {
            _createFork = YES;
        } else {
            selectedFork = nil;
        }
    } else {
        // Try to open another fork
        for (ForkInfo *forkInfo in forks) {
            error = FSOpenResourceFile(fileRef, forkInfo.uniName.length, (UniChar *)forkInfo.uniName.unicode, fsRdPerm, &fileRefNum);
            if (!error && fileRefNum) {
                selectedFork = forkInfo;
                break;
            }
        }
        if (!selectedFork) {
            // Try to find an empty fork
            for (ForkInfo *forkInfo in forks) {
                if (!forkInfo.physicalSize) {
                    selectedFork = forkInfo;
                    _createFork = YES;
                    break;
                }
            }
        }
    }
    SetResLoad(true); // restore resource loading as soon as is possible
    
    if (!selectedFork) {
        *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
        return NO;
    }
    
    fork = selectedFork.uniName;
	if (!_createFork) {
		// disable undos during resource creation and setting of the creator and type
		[self.undoManager disableUndoRegistration];
		
		// then read resources from the selected fork
		resources = [ResourceDocument readResourceMap:fileRefNum];
        if (resources) {
            succeeded = YES;
            for (Resource* resource in resources) {
                [resource setDocument:self];
            }
        } else {
            succeeded = NO;
        }
		
		// get creator and type
		FSCatalogInfo info;
		error = FSGetCatalogInfo(fileRef, kFSCatInfoFinderInfo, &info, NULL, NULL, NULL);
		if (!error) {
			type = ((FileInfo *)info.finderInfo)->fileType;
			creator = ((FileInfo *)info.finderInfo)->fileCreator;
		}
		
		// restore undos
		[self.undoManager enableUndoRegistration];
    } else {
        resources = [NSMutableArray new];
        succeeded = YES;
    }
	
	// now read all other forks as streams
    for (ForkInfo *forkInfo in forks) {
        if (![forkInfo.name isEqualToString:selectedFork.name])
            [self readFork:forkInfo asStreamFromFile:fileRef];
    }
	
	// tidy up loose ends
	if (fileRefNum)
		FSCloseFork(fileRefNum);
	//DisposePtr((Ptr) fileRef);
	return succeeded;
}

/*!
@method			readFork:asStreamFromFile:
@author			Nicholas Shanks
@updated		2003-11-08 NGS:	Now handles opening user-selected forks.
@description	Note: there is a 2 GB limit to the size of forks that can be read in due to <tt>FSReaadFork()</tt> taking a 32-bit buffer length value.
*/

- (BOOL)readFork:(ForkInfo *)forkInfo asStreamFromFile:(FSRef *)fileRef
{
	if (!fileRef) return NO;
	
	/* NTFS Note: When running SFM (Services for Macintosh) a Windows NT-based system (including 2000 & XP) serving NTFS-formatted drives stores Mac resource forks in a stream named "AFP_Resource". The finder info/attributes are stored in a stream called "AFP_AfpInfo". The default data fork stream is called "$DATA" and any of these can be accessed thus: "c:\filename.txt:forkname". Finder comments are stored in a stream called "Comments".
	As a result, ResKnife prohibits creation of forks with the following names:	"" (empty string, Mac data fork name),
																				"$DATA" (NTFS data fork name),
																				"AFP_Resource", "AFP_AfpInfo" and "Comments".
	It is perfectly legal in ResKnife to read in forks of these names when accessing a shared NTFS drive via SMB. The server does not need to be running SFM since the file requests will appear to be coming from a PC. If the files are accessed via AFP on a server running SFM, SFM will automatically convert the files (and truncate the name to 31 chars). */
	
	// get fork length and create empty buffer, bug: only sizeof(size_t) bytes long
	ByteCount forkLength = (ByteCount)forkInfo.size;
	void *buffer = malloc(forkLength);
	if (!buffer) return NO;
	
	// read fork contents into buffer, bug: assumes no errors
	FSIORefNum forkRefNum;
	OSErr error = FSOpenFork(fileRef, forkInfo.uniName.length, forkInfo.uniName.unicode, fsRdPerm, &forkRefNum);
    if (error) return NO;
	FSReadFork(forkRefNum, fsFromStart, 0, forkLength, buffer, &forkLength);
	FSCloseFork(forkRefNum);
	
	// create data
	NSData *data = [NSData dataWithBytesNoCopy:buffer length:forkLength freeWhenDone:YES];
	if (!data) return NO;
	
	// create resource
	Resource *resource = [Resource resourceOfType:0 andID:0 withName:forkInfo.description andAttributes:0 data:data];
	if (!resource) return NO;
	
	[resource setRepresentedFork:forkInfo.name];
	[resources addObject:resource];
	
	return YES;
}

+(NSMutableArray *)readResourceMap:(ResFileRefNum)fileRefNum
{
	OSStatus error = noErr;
    NSMutableArray* resources = [[NSMutableArray alloc] init];
	ResFileRefNum oldResFile = CurResFile();
	UseResFile(fileRefNum);
	
	for (ResourceCount i = 1; i <= Count1Types(); i++) {
		ResType resTypeCode;
		Get1IndType(&resTypeCode, i);
		unsigned short n = Count1Resources(resTypeCode);
		for (unsigned short j = 1; j <= n; j++) {
			Handle resourceHandle = Get1IndResource(resTypeCode, j);
			error = ResError();
			if(error != noErr)
			{
				NSLog(@"Error %d reading resource map...", (int)error);
				UseResFile(oldResFile);
				return nil;
			}
			
			Str255 nameStr;
			ResID resIDShort;
			GetResInfo(resourceHandle, &resIDShort, &resTypeCode, nameStr);
			long sizeLong = GetResourceSizeOnDisk(resourceHandle), badSize = 0;
			if (sizeLong < 0 || sizeLong > 16777215)	// the max size of resource manager file is ~12 MB; I am rounding up to three bytes
			{
				// this only happens when opening ResEdit using the x86 binary (not under Rosetta, for example)
				badSize = sizeLong;
				sizeLong = EndianS32_BtoL(sizeLong);
			}
			short attrsShort = GetResAttrs(resourceHandle);
			HLockHi(resourceHandle);
#if __LITTLE_ENDIAN__
			CoreEndianFlipData(kCoreEndianResourceManagerDomain, resTypeCode, resIDShort, *resourceHandle, sizeLong, true);
#endif
			
			// cool: "The advantage of obtaining a method�s implementation and calling it as a function is that you can invoke the implementation multiple times within a loop, or similar C construct, without the overhead of Objective-C messaging."
			
			// create the resource & add it to the array
			NSString	*name = CFBridgingRelease(CFStringCreateWithPascalString(kCFAllocatorDefault, nameStr, kCFStringEncodingMacRoman));
			NSString	*resType	= GetNSStringFromOSType(resTypeCode);
			NSNumber	*resID		= @(resIDShort);
			NSData		*data		= [NSData dataWithBytes:*resourceHandle length:sizeLong];
			Resource	*resource	= [Resource resourceOfType:resTypeCode andID:resIDShort withName:name andAttributes:attrsShort data:data];
			[resources addObject:resource];		// array retains resource
			if (badSize != 0)
				NSLog(@"GetResourceSizeOnDisk() reported incorrect size for %@ resource %@: %li should be %li", resType, resID, badSize, sizeLong);
			
			HUnlock(resourceHandle);
			ReleaseResource(resourceHandle);
		}
	}
	
	// save resource map and clean up
	UseResFile(oldResFile);
	return resources;
}

/*!
@pending	Uli has changed this routine - see what I had and unify the two
*/

- (BOOL)writeToURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError **)outError
{
	OSStatus error = noErr;
	ResFileRefNum fileRefNum = 0;
	FSRef parentRef = {{0}};
	FSRef fileRef = {{0}};
	
	// create and open file for writing
    HFSUniStr255 uniname = {0};
    error = FSGetHFSUniStrFromString((__bridge CFStringRef)(url.lastPathComponent), &uniname);
    if (!error)
        error = FSPathMakeRef((const UInt8 *)[[url URLByDeletingLastPathComponent] fileSystemRepresentation], &parentRef, nil);
    if (!error)
        error = FSCreateResourceFile(&parentRef, uniname.length, uniname.unicode, kFSCatInfoNone, NULL, fork.length, fork.unicode, &fileRef, NULL);
    
    // write any data streams to file
    if (!error)
        error = [self writeForkStreamsToURL:url];
    
    // set creator & type
    // bug: doesn't set the cat info to the same as the old file
    if (!error) {
        FSCatalogInfo info;
        error = FSGetCatalogInfo(&fileRef, kFSCatInfoFinderInfo, &info, NULL, NULL, NULL);
        if (!error) {
            FInfo *finderInfo = (FInfo *)(info.finderInfo);
            finderInfo->fdType = self.type;
            finderInfo->fdCreator = self.creator;
            FSSetCatalogInfo(&fileRef, kFSCatInfoFinderInfo, &info);
        }
    }
    
    // write resources to file
    if (!error)
        error = FSOpenResourceFile(&fileRef, fork.length, (UniChar *)fork.unicode, fsWrPerm, &fileRefNum);
    if (!error)
        error = [self writeResourceMap:fileRefNum];
    
    if (error) {
        *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:error userInfo:nil];
        return NO;
    }
	
	// tidy up loose ends
	if (fileRefNum)
        FSCloseFork(fileRefNum);
	
	// update info window
	[[InfoWindowController sharedInfoWindowController] updateInfoWindow];
	
	return YES;
}

- (OSStatus)writeForkStreamsToURL:(NSURL *)url
{
	// try and get an FSRef
	OSStatus error = noErr;
	FSRef fileRef;
    error = FSPathMakeRef((const UInt8 *)url.fileSystemRepresentation, &fileRef, nil);
    if (error != noErr) return error;
	
	for (Resource *resource in resources) {
		// if the resource object represents an actual resource, skip it
		if (!resource.representedFork || !resource.data.length) continue;
        HFSUniStr255 uniname = {0};
        FSIORefNum forkRefNum = 0;
        error = FSGetHFSUniStrFromString((__bridge CFStringRef)(resource.representedFork), &uniname);
        if (error != noErr) return error;
         
		error = FSOpenFork(&fileRef, uniname.length, uniname.unicode, fsWrPerm, &forkRefNum);
        if (error != noErr) return error;
		
        error = FSWriteFork(forkRefNum, fsFromStart, 0, resource.data.length, resource.data.bytes, NULL);
        if (error != noErr) return error;
		
        FSCloseFork(forkRefNum);
	}
	return noErr;
}

/*!
@method		writeResourceMap:
@abstract   Writes all resources (except the ones representing other forks of the file) to the specified resource file.
*/

- (OSStatus)writeResourceMap:(ResFileRefNum)fileRefNum
{
	// make the resource file current
	OSStatus error = noErr;
	UseResFile(fileRefNum);
	
	// loop over all our resources
    for (Resource* resource in [dataSource resources]) {
		Str255	nameStr;
		ResType	resTypeCode;
		short	resIDShort;
		short	attrsShort;
		long	sizeLong;
		Handle	resourceHandle;

		// if the resource represents another fork in the file, skip it
		if (resource.representedFork) continue;
		
		sizeLong = [[resource data] length];
        resTypeCode = [resource type];
		resIDShort	= [resource resID];
		attrsShort	= [resource attributes];
		resourceHandle = NewHandleClear(sizeLong);
		
		// convert unicode name to pascal string
        CFStringGetPascalString((__bridge CFStringRef)(resource.name), (StringPtr)&nameStr, sizeof(nameStr), kCFStringEncodingMacRoman);
		
		// convert NSData to resource handle
		HLockHi(resourceHandle);
		[[resource data] getBytes:*resourceHandle];
#if __LITTLE_ENDIAN__
        // the resource manager performs automatic flipping of standard resource types but we want the raw data so need to flip it back
        // (alternatively could install dummy flippers for each type to override the automatic flipping)
		CoreEndianFlipData(kCoreEndianResourceManagerDomain, resTypeCode, resIDShort, *resourceHandle, sizeLong, false);
#endif
		HUnlock(resourceHandle);
		
		// now that everything's converted, tell the resource manager we want to create this resource
		AddResource(resourceHandle, resTypeCode, resIDShort, nameStr);
        error = ResError();
		if (error) {
			NSLog(@"*Saving failed*; could not add resource ID %hd of type %@ to file.", [resource resID], GetNSStringFromOSType([resource type]));
			DisposeHandle(resourceHandle);
            return error;
		}
        
        SetResAttrs(resourceHandle, attrsShort);
        ChangedResource(resourceHandle);
        // the resourceHandle memory is disposed of when calling CloseResFile() for the file to which the resource has been added
	}
	
	// update the file on disk
	UpdateResFile(fileRefNum);
	return error;
}

#pragma mark -
#pragma mark Export to File

/*!
@method		exportResources:
@author		Nicholas Shanks
@created	24 October 2003
*/

- (IBAction)exportResources:(id)sender
{
	if ([outlineView numberOfSelectedRows] > 1)
	{
		NSOpenPanel *panel = [NSOpenPanel openPanel];
		[panel setAllowsMultipleSelection:NO];
		[panel setCanChooseDirectories:YES];
		[panel setCanChooseFiles:NO];
		//[panel beginSheetForDirectory:nil file:nil modalForWindow:mainWindow modalDelegate:self didEndSelector:@selector(folderChoosePanelDidEnd:returnCode:contextInfo:) contextInfo:nil];
		[panel beginSheetModalForWindow:mainWindow completionHandler:^(NSInteger result) {
			[self folderChoosePanelDidEnd:panel returnCode:result contextInfo:nil];
		}];
	}
	else
	{
		[self exportResource:[outlineView selectedItem]];
	}
}

/*!
@method		exportResource:
@author		Uli Kusterer
@updated	2003-10-24 NGS: moved IBAction target to exportResources: above, renamed this method
*/

#warning Note to Uli: how about changing the selector that the plug should implement to -(BOOL)dataForFileExport:(NSData **)fileData ofType:(NSString **)fileType. This is basically a concatenation of the two methods you came up with, but can allow the host app to specify a preferred file type (e.g. EPS) to a plug (say the PICT plug) and if the plug can't return data in that format, that's OK, it just returns the fileType of the associated data anyway. I would also recommend adding a plug method called something like availableTypesForFileExport: which returns a dictionary of file extensions and human-readable names (names should be overridden by system default names for that extension if present) that the plug can export data into, useful for say populating a pop-up menu in the export dialog.

- (void)exportResource:(Resource *)resource
{
	Class		editorClass = [[RKEditorRegistry defaultRegistry] editorForType:GetNSStringFromOSType([resource type])];
	NSData		*exportData = [resource data];
	NSString	*extension = [[GetNSStringFromOSType([resource type]) lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	
	// basic overrides for file name extensions (assume no plug-ins installed)
	NSString *newExtension;
	NSDictionary *adjustments = @{@"sfnt": @"ttf"};
	if((newExtension = adjustments[extension]))
		extension = newExtension;
	
	// ask for data
	if([editorClass respondsToSelector:@selector(dataForFileExport:)])
		exportData = [editorClass dataForFileExport:resource];
	
	// ask for file extension
	if([editorClass respondsToSelector:@selector(filenameExtensionForFileExport:)])
		extension = [editorClass filenameExtensionForFileExport:resource];
	
	NSSavePanel *panel = [NSSavePanel savePanel];
	NSString *filename = ([resource name] && ![[resource name] isEqualToString:@""]) ? [resource name] : NSLocalizedString(@"Untitled Resource",nil);
	filename = [filename stringByAppendingPathExtension:extension];
	[panel setNameFieldStringValue:filename];
	//[panel beginSheetForDirectory:nil file:filename modalForWindow:mainWindow modalDelegate:self didEndSelector:@selector(exportPanelDidEnd:returnCode:contextInfo:) contextInfo:[exportData retain]];
	[panel beginSheetModalForWindow:mainWindow completionHandler:^(NSInteger result) {
		if(result == NSOKButton)
			[exportData writeToURL:[panel URL] atomically:YES];
	}];
}

- (void)folderChoosePanelDidEnd:(NSSavePanel *)sheet returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
{
	if(returnCode == NSOKButton)
	{
		unsigned int i = 1;
		NSString *filename, *extension;
		NSDictionary *adjustments = @{@"sfnt": @"ttf", @"PNGf": @"png"};
		for (Resource *resource in [dataSource allResourcesForItems:[outlineView selectedItems]]) {
			NSString *NSResType = GetNSStringFromOSType([resource type]);

			Class editorClass = [[RKEditorRegistry defaultRegistry] editorForType:GetNSStringFromOSType([resource type])];
			NSData *exportData = [resource data];
			extension = [[NSResType lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			
			// basic overrides for file name extensions (assume no plug-ins installed)
			if(adjustments[NSResType])
				extension = adjustments[NSResType];
			
			// ask for data
			if([editorClass respondsToSelector:@selector(dataForFileExport:)])
				exportData = [editorClass dataForFileExport:resource];
			
			// ask for file extension
			if([editorClass respondsToSelector:@selector(filenameExtensionForFileExport:)])
				extension = [editorClass filenameExtensionForFileExport:resource];
			
			filename = [resource name];
			if (!filename || [filename isEqualToString:@""])
			{
				filename = [NSString stringWithFormat:NSLocalizedString(@"Untitled '%@' Resource %d",nil), [resource type], i++];
				filename = [filename stringByAppendingPathExtension:extension];
			}
			else
			{
				unsigned int j = 1;
				NSString *tempname = [filename stringByAppendingPathExtension:extension];
				while ([[NSFileManager defaultManager] fileExistsAtPath:tempname])
				{
					tempname = [filename stringByAppendingFormat:@" (%d)", j++];
					tempname = [tempname stringByAppendingPathExtension:extension];
				}
				filename = tempname;
			}
			NSURL *url = [[sheet URL] URLByAppendingPathComponent:filename];
			[exportData writeToURL:url atomically:YES];
		}
	}
}

#pragma mark -
#pragma mark Window Management

- (NSString *)windowNibName
{
    return @"ResourceDocument";
}

/*	This is not used, just here for reference in case I need it in the future

- (void)makeWindowControllers
{
	ResourceWindowController *resourceController = [[ResourceWindowController allocWithZone:[self zone]] initWithWindowNibName:@"ResourceDocument"];
    [self addWindowController:resourceController];
}*/

- (void)windowControllerDidLoadNib:(NSWindowController *)controller
{
	[super windowControllerDidLoadNib:controller];
	
	{	// set up first column in outline view to display images as well as text
		ResourceNameCell *resourceNameCell = [[ResourceNameCell alloc] init];
		[resourceNameCell setEditable:YES];
		[[outlineView tableColumnWithIdentifier:@"name"] setDataCell:resourceNameCell];
		// NSLog(@"Changed data cell");
	}
	
	[outlineView setVerticalMotionCanBeginDrag:YES];
	[outlineView registerForDraggedTypes:@[RKResourcePboardType, NSStringPboardType, NSFilenamesPboardType]];
	
	// register for resource will change notifications (for undo management)
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resourceNameWillChange:) name:ResourceNameWillChangeNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resourceIDWillChange:) name:ResourceIDWillChangeNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resourceTypeWillChange:) name:ResourceTypeWillChangeNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resourceAttributesWillChange:) name:ResourceAttributesWillChangeNotification object:nil];
	
    [dataSource addResources:resources];
}

- (void)printShowingPrintPanel:(BOOL)flag
{
	NSPrintOperation *printOperation = [NSPrintOperation printOperationWithView:[mainWindow contentView]];
	[printOperation runOperationModalForWindow:mainWindow delegate:self didRunSelector:@selector(printOperationDidRun:success:contextInfo:) contextInfo:NULL];
}

- (void)printOperationDidRun:(NSPrintOperation *)printOperation success:(BOOL)success contextInfo:(void *)contextInfo
{
	if(!success) NSLog(@"Printing Failed!");
}

- (BOOL)keepBackupFile
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:kPreserveBackups];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	NSInteger selectedRows = [outlineView numberOfSelectedRows];
    Resource *resource = nil;
    if ([[outlineView selectedItem] isKindOfClass:[Resource class]]) {
        resource = (Resource *)[outlineView selectedItem];
    }
	
	// file menu
	if([item action] == @selector(saveDocument:))			return [self isDocumentEdited];
	
	// edit menu
	else if([item action] == @selector(delete:))				return selectedRows > 0;
	else if([item action] == @selector(selectAll:))			return [outlineView numberOfRows] > 0;
	else if([item action] == @selector(deselectAll:))		return selectedRows > 0;
	
	// resource menu
	else if([item action] == @selector(openResources:))						return selectedRows > 0;
	else if([item action] == @selector(openResourcesInTemplate:))			return selectedRows > 0;
	else if([item action] == @selector(openResourcesWithOtherTemplate:))	return selectedRows > 0;
	else if([item action] == @selector(openResourcesAsHex:))				return selectedRows > 0;
	else if([item action] == @selector(exportResourceToImageFile:))
	{
		if(selectedRows < 1) return NO;
		Class editorClass = [[RKEditorRegistry defaultRegistry] editorForType:GetNSStringFromOSType([resource type])];
		return [editorClass respondsToSelector:@selector(imageForImageFileExport:)];
	}
	else if([item action] == @selector(playSound:))				return selectedRows == 1 && [resource type] == 'snd ';
	else if([item action] == @selector(revertResourceToSaved:))	return selectedRows == 1 && [resource isDirty];
	else return [super validateMenuItem:item];
}

#pragma mark -
#pragma mark Toolbar Management

static NSString *RKCreateItemIdentifier		= @"com.nickshanks.resknife.toolbar.create";
static NSString *RKDeleteItemIdentifier		= @"com.nickshanks.resknife.toolbar.delete";
static NSString *RKEditItemIdentifier		= @"com.nickshanks.resknife.toolbar.edit";
static NSString *RKEditHexItemIdentifier	= @"com.nickshanks.resknife.toolbar.edithex";
static NSString *RKSaveItemIdentifier		= @"com.nickshanks.resknife.toolbar.save";
static NSString *RKShowInfoItemIdentifier	= @"com.nickshanks.resknife.toolbar.showinfo";
static NSString *RKExportItemIdentifier		= @"com.nickshanks.resknife.toolbar.export";
static NSString *RKViewItemIdentifier		= @"com.nickshanks.resknife.toolbar.view";

- (BOOL)validateToolbarItem:(NSToolbarItem *)item
{
	BOOL valid = NO;
	NSInteger selectedRows = [outlineView numberOfSelectedRows];
	NSString *identifier = [item itemIdentifier];
	
	if([identifier isEqualToString:RKCreateItemIdentifier])
		valid = YES;
	else if([identifier isEqualToString:RKDeleteItemIdentifier])
		valid = selectedRows > 0;
	else if([identifier isEqualToString:RKEditItemIdentifier])
		valid = selectedRows > 0;
	else if([identifier isEqualToString:RKEditHexItemIdentifier])
		valid = selectedRows > 0;
	else if([identifier isEqualToString:RKExportItemIdentifier])
		valid = selectedRows > 0;
	else if([identifier isEqualToString:RKSaveItemIdentifier])
		valid = [self isDocumentEdited];
	else if([identifier isEqualToString:NSToolbarPrintItemIdentifier])
		valid = YES;
	
	return valid;
}

#pragma mark -
#pragma mark Document Management

- (IBAction)showCreateResourceSheet:(id)sender
{
	// bug: ResourceDocument allocs a sheet controller, but it's never disposed of
	
	if (!sheetController)
		sheetController = [[CreateResourceSheetController alloc] initWithWindowNibName:@"CreateResourceSheet"];
	
	[sheetController showCreateResourceSheet:self];
}

- (IBAction)showSelectTemplateSheet:(id)sender
{
	// bug: ResourceDocument allocs a sheet controller, but it's never disposed of
//	SelectTemplateSheetController *sheetController = [[CreateResourceSheetController alloc] initWithWindowNibName:@"SelectTemplateSheet"];
//	[sheetController showSelectTemplateSheet:self];
}

- (IBAction)openResources:(id)sender
{
	// ignore double-clicks in table header
	if(sender == outlineView && [outlineView clickedRow] == -1)
		return;
	
	
	NSEvent *event = [NSApp currentEvent];
	if ([event type] == NSLeftMouseUp && (([event modifierFlags] & NSDeviceIndependentModifierFlagsMask) & NSAlternateKeyMask) != 0)
		[self openResourcesAsHex:sender];
	else {
		for (Resource *resource in [outlineView selectedItems]) {
            if( [resource isKindOfClass: [Resource class]] ) {
                [self openResourceUsingEditor:resource];
            } else {
                [outlineView expandItem:resource];
            }
		}
	}
}

- (IBAction)openResourcesInTemplate:(id)sender
{
	// opens the resource in its default template
	for (Resource *resource in [outlineView selectedItems]) {
        if( [resource isKindOfClass: [Resource class]] ) {
            [self openResource:resource usingTemplate:GetNSStringFromOSType([resource type])];
        }
	}
}

- (IBAction)openResourcesAsHex:(id)sender
{
	for (Resource *resource in [outlineView selectedItems]) {
        if( [resource isKindOfClass: [Resource class]] ) {
            [self openResourceAsHex:resource];
        }
	}
}


/* -----------------------------------------------------------------------------
	openResourceUsingEditor:
		Open an editor for the specified Resource instance. This looks up
		the editor to use in the plugin registry and then instantiates an
		editor object, handing it the resource. If there is no editor for this
		type registered, it falls back to the template editor, which in turn
		uses the hex editor as a fallback.
	
	REVISIONS:
		2003-07-31  UK  Changed to use plugin registry instead of file name.
		2012-07-07	NW	Changed to return the used plugin.
   -------------------------------------------------------------------------- */

/* Method name should be changed to:  -(void)openResource:(Resource *)resource usingEditor:(Class)overrideEditor <nil == default editor>   */

- (id <ResKnifePlugin>)openResourceUsingEditor:(Resource *)resource
{
	Class editorClass = [[RKEditorRegistry defaultRegistry] editorForType:GetNSStringFromOSType([resource type])];
	
	// open the resources, passing in the template to use
	if(editorClass)
	{
		// bug: I alloc a plug instance here, but have no idea where I should dealloc it, perhaps the plug ought to call [self autorelease] when it's last window is closed?
		// update: doug says window controllers automatically release themselves when their window is closed. All default plugs have a window controller as their principal class, but 3rd party ones might not
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resourceDataDidChange:) name:ResourceDataDidChangeNotification object:resource];
		id plug = [(id <ResKnifePlugin>)[editorClass alloc] initWithResource:resource];
        if (plug) {
            if ([plug isKindOfClass:[NSWindowController class]])
                [self addWindowController:plug];
			return plug;
        }
	}
	
	// if no editor exists, or the editor is broken, open using template
	return [self openResource:resource usingTemplate:GetNSStringFromOSType([resource type])];
}


/* -----------------------------------------------------------------------------
	openResource:usingTemplate:
		Open a template editor for the specified Resource instance. This looks
		up the template editor in the plugin registry and then instantiates an
		editor object, handing it the resource and the template resource to use.
		If there is no template editor registered, or there is no template for
		this resource type, it falls back to the hex editor.
	
	REVISIONS:
		2003-07-31  UK  Changed to use plugin registry instead of file name.
		2012-07-07	NW	Changed to return the used plugin.
   -------------------------------------------------------------------------- */

- (id <ResKnifePlugin>)openResource:(Resource *)resource usingTemplate:(NSString *)templateName
{
	// opens resource in template using TMPL resource with name templateName
    if (resource.type) {
        Class editorClass = [[RKEditorRegistry defaultRegistry] editorForType:@"Template Editor"];
        
        // TODO: this checks EVERY DOCUMENT for template resources (might not be desired)
        // TODO: it doesn't, however, check the application's resource map for a matching template!
        Resource *tmpl = [Resource resourceOfType:'TMPL' withName:GetNSStringFromOSType([resource type]) inDocument:nil];
        
        // open the resources, passing in the template to use
        if(tmpl && editorClass)
        {
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resourceDataDidChange:) name:ResourceDataDidChangeNotification object:resource];
            id plug = [(id <ResKnifeTemplatePlugin>)[editorClass alloc] initWithResource:resource template:tmpl];
            if (plug) {
                [self addWindowController:plug];
                return plug;
            }
        }
    }
	
	// if no template exists, or template editor is broken, open as hex
	return [self openResourceAsHex:resource];
}

/*!
@method			openResourceAsHex:
@author			Nicholas Shanks
@created		2001
@updated		2003-07-31 UK:	Changed to use plugin registry instead of file name.
				2012-07-07 NW:	Changed to return the used plugin.
@description	Open a hex editor for the specified Resource instance. This looks up the hexadecimal editor in the plugin registry and then instantiates an editor object, handing it the resource.
@param			resource	Resource to edit
*/

- (id <ResKnifePlugin>)openResourceAsHex:(Resource *)resource
{
	Class editorClass = [[RKEditorRegistry defaultRegistry] editorForType: @"Hexadecimal Editor"];
	// bug: I alloc a plug instance here, but have no idea where I should dealloc it, perhaps the plug ought to call [self autorelease] when it's last window is closed?
	// update: doug says window controllers automatically release themselves when their window is closed.
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resourceDataDidChange:) name:ResourceDataDidChangeNotification object:resource];
	id plug = [(id <ResKnifePlugin>)[editorClass alloc] initWithResource:resource];
    [self addWindowController:plug];
	return plug;
}


- (void)saveSoundAsMovie:(NSData *)sndData
{

}

/*!
@method			playSound:
@abstract		Plays the selected carbon 'snd ' resource.
@author			Nicholas Shanks
@created		2001
@updated		2003-10-22 NGS: Moved playing into seperate thread to avoid locking up main thread.
@pending		should really be moved to a 'snd ' editor, but first we'd need to extend the plugin protocol to call the class so it can add such menu items. Of course, we could just make the 'snd ' editor have a button in its window that plays the sound.
@description	This method is called from a menu item which is validated against there being only one selected resource (of type 'snd '), so shouldn't have to deal with playing multiple sounds, though this may of course change in future.
@param	sender	ignored
*/
- (IBAction)playSound:(id)sender
{
	// bug: can only cope with one selected item
	NSData *data = [(Resource *)[outlineView itemAtRow:[outlineView selectedRow]] data];
	if(data && [data length] != 0) {
		xpc_connection_t connection = xpc_connection_create("org.derailer.ResKnife.System7SoundPlayer", NULL);
		xpc_object_t dict = xpc_dictionary_create(NULL, NULL, 0);
		xpc_dictionary_set_data(dict, "soundData", [data bytes], [data length]);
		xpc_connection_set_event_handler(connection, ^(xpc_object_t object) {
			if (xpc_get_type(object) == XPC_TYPE_ERROR) {
				if (object == XPC_ERROR_CONNECTION_INVALID)
					NSLog(@"invalid connection");
			}
		});
		xpc_connection_resume(connection);
		xpc_connection_send_message(connection, dict);
	}
	else NSBeep();
}

- (void)resourceNameWillChange:(NSNotification *)notification
{
	// this saves the current resource's name so we can undo the change
	Resource *resource = (Resource *) [notification object];
    if ([resource document] == self) {
        [[self undoManager] registerUndoWithTarget:resource selector:@selector(setName:) object:[[resource name] copy]];
        [[self undoManager] setActionName:NSLocalizedString(@"Name Change", nil)];
    }
}

- (void)resourceIDWillChange:(NSNotification *)notification
{
	// this saves the current resource's ID number so we can undo the change
	Resource *resource = (Resource *) [notification object];
    if ([resource document] == self) {
        [[[self undoManager] prepareWithInvocationTarget:resource] setResID:[resource resID]];
        if([[resource name] length] == 0)
            [[self undoManager] setActionName:NSLocalizedString(@"ID Change", nil)];
        else [[self undoManager] setActionName:[NSString stringWithFormat:NSLocalizedString(@"ID Change for '%@'", nil), [resource name]]];
    }
}

- (void)resourceTypeWillChange:(NSNotification *)notification
{
	// this saves the current resource's type so we can undo the change
	Resource *resource = (Resource *) [notification object];
    if ([resource document] == self) {
        [(Resource*)[[self undoManager] prepareWithInvocationTarget:resource] setType:[resource type]];
        if([[resource name] length] == 0)
            [[self undoManager] setActionName:NSLocalizedString(@"Type Change", nil)];
        else [[self undoManager] setActionName:[NSString stringWithFormat:NSLocalizedString(@"Type Change for '%@'", nil), [resource name]]];
    }
}

- (void)resourceAttributesWillChange:(NSNotification *)notification
{
	// this saves the current state of the resource's attributes so we can undo the change
	Resource *resource = (Resource *) [notification object];
	[[self undoManager] registerUndoWithTarget:resource selector:@selector(setAttributes:) object:[@([resource attributes]) copy]];
	if([[resource name] length] == 0)
		[[self undoManager] setActionName:NSLocalizedString(@"Attributes Change", nil)];
	else [[self undoManager] setActionName:[NSString stringWithFormat:NSLocalizedString(@"Attributes Change for '%@'", nil), [resource name]]];
}

- (void)resourceDataDidChange:(NSNotification *)notification
{
	[self updateChangeCount:NSChangeDone];
}

#pragma mark -
#pragma mark Edit Operations

- (IBAction)cut:(id)sender
{
	[self copy:sender];
	[self delete:sender];
}

- (IBAction)copy:(id)sender
{
	#pragma unused(sender)
	NSArray *selectedItems = [dataSource allResourcesForItems:[outlineView selectedItems]];
	NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSGeneralPboard];
	[pb declareTypes:@[RKResourcePboardType] owner:self];
	[pb setData:[NSKeyedArchiver archivedDataWithRootObject:selectedItems] forType:RKResourcePboardType];
}

- (IBAction)paste:(id)sender
{
	#pragma unused(sender)
	NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSGeneralPboard];
	if([pb availableTypeFromArray:@[RKResourcePboardType]])
		[self pasteResources:[NSKeyedUnarchiver unarchiveObjectWithData:[pb dataForType:RKResourcePboardType]]];
}

- (void)pasteResources:(NSArray *)pastedResources
{
	Resource *resource;
	NSEnumerator *enumerator = [pastedResources objectEnumerator];
	while(resource = (Resource *) [enumerator nextObject])
	{
		// check resource type/ID is available
		if([dataSource resourceOfType:[resource type] andID:[resource resID]] == nil)
		{
			// resource slot is available, paste this one in
			[dataSource addResource:resource];
		}
		else
		{
			// resource slot is ocupied, ask user what to do
			NSArray *remainingResources = [enumerator allObjects];
			NSAlert *alert = [[NSAlert alloc] init];
			alert.messageText = @"Paste Error";
			alert.informativeText = [NSString stringWithFormat:@"There already exists a resource of type %@ with ID %hd. Do you wish to assign the pasted resource a unique ID, overwrite the existing resource, or skip pasting of this resource?", GetNSStringFromOSType([resource type]), [resource resID]];
			[alert addButtonWithTitle:@"Unique ID"];
			[alert addButtonWithTitle:@"Overwrite"];
			[alert addButtonWithTitle:@"Skip"];
			[alert beginSheetModalForWindow:mainWindow completionHandler:^(NSModalResponse returnCode) {
				if(returnCode == NSAlertFirstButtonReturn)	// unique ID
				{
					Resource *newResource = [Resource resourceOfType:[resource type] andID:[dataSource uniqueIDForType:[resource type]] withName:[resource name] andAttributes:[resource attributes] data:[resource data]];
					[dataSource addResource:newResource];
				}
				else if(returnCode == NSAlertSecondButtonReturn)				// overwrite
				{
					[dataSource removeResource:[dataSource resourceOfType:[resource type] andID:[resource resID]]];
					[dataSource addResource:resource];
				}
				//else if(NSAlertAlternateReturn)			// skip
				
				// continue paste
				[self pasteResources:remainingResources];
			}];
		}
	}
}

- (IBAction)delete:(id)sender
{
#pragma unused(sender)
	if([[NSUserDefaults standardUserDefaults] boolForKey:kDeleteResourceWarning])
	{
		NSBeginCriticalAlertSheet(@"Delete Resource", @"Delete", @"Cancel", nil, [self mainWindow], self, @selector(deleteResourcesSheetDidEnd:returnCode:contextInfo:), NULL, nil, @"Are you sure you want to delete the selected resources?");
	}
	else [self deleteSelectedResources];
}

- (void)deleteResourcesSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
#pragma unused(contextInfo)
	if(returnCode == NSOKButton)
		[self deleteSelectedResources];
}

- (void)deleteSelectedResources
{
	Resource *resource;
	NSEnumerator *enumerator;
    NSArray *selected = [dataSource allResourcesForItems:[outlineView selectedItems]];
	
	// enumerate through array and delete resources
	[[self undoManager] beginUndoGrouping];
	enumerator = [selected reverseObjectEnumerator];		// reverse so an undo will replace items in original order
	while(resource = [enumerator nextObject])
	{
		[dataSource removeResource:resource];
		if([[resource name] length] == 0)
			[[self undoManager] setActionName:NSLocalizedString(@"Delete Resource", nil)];
		else [[self undoManager] setActionName:[NSString stringWithFormat:NSLocalizedString(@"Delete Resource '%@'", nil), [resource name]]];
	}
	[[self undoManager] endUndoGrouping];
	
	// generalise undo name if more than one was deleted
	if([selected count] > 1)
		[[self undoManager] setActionName:NSLocalizedString(@"Delete Resources", nil)];
	
	// deselect resources (otherwise other resources move into selected rows!)
	[outlineView deselectAll:self];
}

#pragma mark -
#pragma mark Accessors

- (NSWindow *)mainWindow
{
	return mainWindow;
}

- (ResourceDataSource *)dataSource
{
	return dataSource;
}

- (NSOutlineView *)outlineView
{
	return outlineView;
}

- (NSArray *)resources
{
	return [dataSource resources];
}

- (OSType)creator
{
	return creator;
}

- (OSType)type
{
	return type;
}

- (IBAction)creatorChanged:(id)sender
{
	OSType newCreator = GetOSTypeFromNSString([sender stringValue]);
	[self setCreator:newCreator];
}

- (IBAction)typeChanged:(id)sender
{
	OSType newType = GetOSTypeFromNSString([sender stringValue]);
	[self setType:newType];
}

- (void)setCreator:(OSType)newCreator
{
	if (newCreator != creator) {
		NSString *oldCreatorStr = GetNSStringFromOSType(newCreator);
		[[NSNotificationCenter defaultCenter] postNotificationName:DocumentInfoWillChangeNotification object:@{@"NSDocument": self, @"creator": oldCreatorStr}];
		[[self undoManager] registerUndoWithTarget:self selector:@selector(setCreator:) object:GetNSStringFromOSType(creator)];
		[[self undoManager] setActionName:NSLocalizedString(@"Change Creator Code", nil)];
		creator = newCreator;
		[[NSNotificationCenter defaultCenter] postNotificationName:DocumentInfoDidChangeNotification object:@{@"NSDocument": self, @"creator": oldCreatorStr}];
	}
}

- (void)setType:(OSType)newType
{
	if (newType != type) {
		NSString *oldTypeStr = GetNSStringFromOSType(newType);
		[[NSNotificationCenter defaultCenter] postNotificationName:DocumentInfoWillChangeNotification object:@{@"NSDocument": self, @"type": oldTypeStr}];
		[[self undoManager] registerUndoWithTarget:self selector:@selector(setType:) object:GetNSStringFromOSType(type)];
		[[self undoManager] setActionName:NSLocalizedString(@"Change File Type", nil)];
		type = newType;
		[[NSNotificationCenter defaultCenter] postNotificationName:DocumentInfoDidChangeNotification object:@{@"NSDocument": self, @"type": oldTypeStr}];
	}
}

- (BOOL)setCreator:(OSType)newCreator andType:(OSType)newType
{
	BOOL creatorChanged = (creator != newCreator), typeChanged = (type != newType);
	[[self undoManager] beginUndoGrouping];
	[self setCreator:newCreator];
	[self setType:newType];
	[[self undoManager] endUndoGrouping];
	if(creatorChanged && typeChanged)
		[[self undoManager] setActionName:NSLocalizedString(@"Change Creator & Type", nil)];
	return (creatorChanged || typeChanged);
}

- (IBAction)changeView:(id)sender
{
	
}

@end
