#import "ElementRangeable.h"
#import "TemplateWindowController.h"

@implementation ElementRangeable

- (void)configureView:(NSView *)view
{
    if (!self.isRanged) {
        [super configureView:view];
        return;
    }
    if (!self.currentCase)
        [self loadValue];
    // Only show the select menu if there are multiple options
    if (self.cases.count > 1) {
        NSRect orig = view.frame;
        NSRect frame = view.frame;
        frame.size.width = self.width-1;
        NSPopUpButton *select = [[NSPopUpButton alloc] initWithFrame:frame];
        select.target = self;
        select.action = @selector(caseChanged:);
        [select bind:@"content" toObject:self withKeyPath:@"cases" options:nil];
        [select bind:@"selectedObject" toObject:self withKeyPath:@"currentCase" options:nil];
        [view addSubview:select];
        frame.origin.x += self.width;
        view.frame = frame;
        [self.currentCase configureView:view];
        view.frame = orig;
    } else {
        [self.currentCase configureView:view];
    }
}

- (IBAction)caseChanged:(id)sender
{
    if (self.displayValue < self.currentCase.min) {
        self.displayValue = self.currentCase.min;
    } else if (self.displayValue > self.currentCase.max) {
        self.displayValue = self.currentCase.max;
    } else {
        self.displayValue = self.displayValue; // Still need to trigger the transformer
    }
    NSOutlineView *outlineView = self.parentList.controller.dataList;
    // Item isn't necessarily self
    [outlineView reloadItem:[outlineView itemAtRow:[outlineView rowForView:sender]]];
    [self.parentList.controller itemValueUpdated:sender];
}

- (void)configure
{
    // Read CASR elements
    ElementCASR *element = [self.parentList peek:1];
    if (element.class == ElementCASR.class) {
        CGFloat width = 240;
        self.isRanged = YES;
        self.cases = [NSMutableArray new];
        while (element.class == ElementCASR.class) {
            [self.cases addObject:[self.parentList pop]];
            element.parentList = self.parentList; // Required for the element to trigger itemValueUpdated
            element.parentElement = self;
            element.width = self.width;
            if (element.min != element.max)
                width = 180; // Shrink pop-up menu if any CASR needs a field
            element = [self.parentList peek:1];
        }
        self.width = width;
    } else {
        [super configure];
    }
}

- (void)loadValue
{
    NSNumber *value = [self valueForKey:@"value"];
    for (ElementCASR *element in self.cases) {
        if ([element matchesValue:value]) {
            self.currentCase = element;
            break;
        }
    }
    if (self.currentCase) {
        self.displayValue = [[self.currentCase normalise:value] intValue];
    } else {
        // Force value to min of first case
        self.currentCase = self.cases[0];
        self.displayValue = self.currentCase.min;
        [self setValue:[self.currentCase deNormalise:@(self.displayValue)] forKey:@"value"];
    }
    [self bind:@"value" toObject:self withKeyPath:@"displayValue" options:@{NSValueTransformerBindingOption:self}];
    
}

- (id)transformedValue:(id)value
{
    if (!self.isRanged)
        return [super transformedValue:value];
    return [self.currentCase deNormalise:value];
}

- (id)reverseTransformedValue:(id)value
{
    if (!self.isRanged)
        return [super reverseTransformedValue:value];
    return [self.currentCase normalise:value];
}

@end