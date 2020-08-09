/* =============================================================================
	PROJECT:	ResKnife
	FILE:		TemplateWindowController.h
	
	PURPOSE:	This is the main class of our template editor. Every
				resource editor's main class implements the
				ResKnifePlugin. Every editor should implement
				initWithResource:. Only implement initWithResources:if you feel
				like writing a template editor.
				
				Note that your plugin is responsible for committing suicide
				after its window has been closed. If you subclass it from
				NSWindowController, the controller will take care of that
				for you, according to a guy named Doug.
	
	AUTHORS:	M. Uli Kusterer, witness(at)zathras.de, (c) 2003.
	
	REVISIONS:
		2003-07-31  UK  Created.
   ========================================================================== */

#import <Cocoa/Cocoa.h>
#import "ElementList.h"
#import "RKSupport/RKSupport-Swift.h"

@interface TemplateWindowController : NSWindowController <ResKnifeTemplatePlugin, NSOutlineViewDataSource, NSOutlineViewDelegate>
{
	ElementList *resourceStructure;		// Parsed form of our resource.
}
@property IBOutlet NSOutlineView *dataList; // Data display.
@property (nonatomic) Resource *resource;   // The resource we operate on.
@property Resource *tmpl;       // The template resource.

- (IBAction)itemValueUpdated:(id)sender;

@end

@interface NTOutlineView : NSOutlineView
@end

@interface NTFocusView : NSTableCellView
@end
