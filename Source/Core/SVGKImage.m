#import "SVGKImage.h"

#import "SVGDefsElement.h"
#import "SVGDescriptionElement.h"
#import "SVGKParser.h"
#import "SVGTitleElement.h"
#import "SVGPathElement.h"
#import "SVGUseElement.h"

#import "SVGKParserSVG.h"

#ifdef ENABLE_GLOBAL_IMAGE_CACHE_FOR_SVGKIMAGE_IMAGE_NAMED
@interface SVGKImageCacheLine : NSObject
@property(nonatomic) int numberOfInstances;
@property(nonatomic,retain) SVGKImage* mainInstance;
@end
@implementation SVGKImageCacheLine
@synthesize numberOfInstances;
@synthesize mainInstance;
@end
#endif

@interface SVGKImage ()

@property (nonatomic, retain, readwrite) SVGLength* svgWidth;
@property (nonatomic, retain, readwrite) SVGLength* svgHeight;
@property (nonatomic, retain, readwrite) SVGKParseResult* parseErrorsAndWarnings;

@property (nonatomic, retain, readwrite) SVGKSource* source;

@property (nonatomic, retain, readwrite) SVGDocument* DOMDocument;
@property (nonatomic, retain, readwrite) SVGSVGElement* DOMTree; // needs renaming + (possibly) replacing by DOMDocument
@property (nonatomic, retain, readwrite) CALayer* CALayerTree;
#ifdef ENABLE_GLOBAL_IMAGE_CACHE_FOR_SVGKIMAGE_IMAGE_NAMED
@property (nonatomic, retain, readwrite) NSString* nameUsedToInstantiate;
#endif


#pragma mark - UIImage methods cloned and re-implemented as SVG intelligent methods
//NOT DEFINED: what is the scale for a SVGKImage? @property(nonatomic,readwrite) CGFloat            scale __OSX_AVAILABLE_STARTING(__MAC_NA,__IPHONE_4_0);

@end

#pragma mark - main class
@implementation SVGKImage

@synthesize DOMDocument, DOMTree, CALayerTree;

@synthesize svgWidth = _width;
@synthesize svgHeight = _height;
@synthesize source;
@synthesize parseErrorsAndWarnings;

#ifdef ENABLE_GLOBAL_IMAGE_CACHE_FOR_SVGKIMAGE_IMAGE_NAMED
static NSMutableDictionary* globalSVGKImageCache;

#pragma mark - Respond to low-memory warnings by dumping the global static cache
+(void) initialize
{
	if( self == [SVGKImage class]) // Have to protect against subclasses ADDITIONALLY calling this, as a "[super initialize] line
	{
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveMemoryWarningNotification:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
	}
}

+(void) didReceiveMemoryWarningNotification:(NSNotification*) notification
{
	NSLog(@"[%@] Low-mem; purging cache of %i SVGKImage's...", self, [globalSVGKImageCache count] );
	
	[globalSVGKImageCache removeAllObjects]; // once they leave the cache, if they are no longer referred to, they should automatically dealloc
}
#endif

#pragma mark - Convenience initializers
+ (SVGKImage *)imageNamed:(NSString *)name {
	NSParameterAssert(name != nil);
    
#ifdef ENABLE_GLOBAL_IMAGE_CACHE_FOR_SVGKIMAGE_IMAGE_NAMED
    if( globalSVGKImageCache == nil )
    {
        globalSVGKImageCache = [NSMutableDictionary new];
    }
    
    SVGKImageCacheLine* cacheLine = [globalSVGKImageCache valueForKey:name];
    if( cacheLine != nil )
    {
        cacheLine.numberOfInstances ++;
        return cacheLine.mainInstance;
    }
#endif
	
	NSBundle *bundle = [NSBundle mainBundle];
	
	if (!bundle)
		return nil;
	
	NSString *newName = [name stringByDeletingPathExtension];
	NSString *extension = [name pathExtension];
    if ([@"" isEqualToString:extension]) {
        extension = @"svg";
    }
	
	NSString *path = [bundle pathForResource:newName ofType:extension];
	
	if (!path)
	{
		NSLog(@"[%@] MISSING FILE, COULD NOT CREATE DOCUMENT: filename = %@, extension = %@", [self class], newName, extension);
		return nil;
	}
	
	SVGKImage* result = [self imageWithContentsOfFile:path];
    
#ifdef ENABLE_GLOBAL_IMAGE_CACHE_FOR_SVGKIMAGE_IMAGE_NAMED
    result->cameFromGlobalCache = TRUE;
    result.nameUsedToInstantiate = name;
    
    SVGKImageCacheLine* newCacheLine = [[[SVGKImageCacheLine alloc] init] autorelease];
    newCacheLine.mainInstance = result;
    
    [globalSVGKImageCache setValue:newCacheLine forKey:name];
#endif
    
    return result;
}

+ (SVGKImage*) imageWithContentsOfURL:(NSURL *)url {
	NSParameterAssert(url != nil);
	
	return [[[[self class] alloc] initWithContentsOfURL:url] autorelease];
}

+ (SVGKImage*) imageWithContentsOfFile:(NSString *)aPath {
	return [[[[self class] alloc] initWithContentsOfFile:aPath] autorelease];
}

/**
 Designated Initializer
 */
- (id)initWithParsedSVG:(SVGKParseResult *)parseResult {
	self = [super init];
	if (self) {
		self.svgWidth = [SVGLength svgLengthZero];
		self.svgHeight = [SVGLength svgLengthZero];
		
		self.parseErrorsAndWarnings = parseResult;
		
		if( parseErrorsAndWarnings.parsedDocument != nil )
		{
			self.DOMDocument = parseErrorsAndWarnings.parsedDocument;
			self.DOMTree = DOMDocument.rootElement;
		}
		else
		{
			self.DOMDocument = nil;
			self.DOMTree = nil;
		}
		
		if ( self.DOMDocument == nil )
		{
			NSLog(@"[%@] ERROR: failed to init SVGKImage with source = %@, returning nil from init methods", [self class], source );
			self = nil;
		}
		else
		{
			self.svgWidth = self.DOMTree.width;
			self.svgHeight = self.DOMTree.height;
		}
	}
    return self;
}

- (id)initWithSource:(SVGKSource *)newSource {
	NSAssert( newSource != nil, @"Attempted to init an SVGKImage using a nil SVGKSource");
	
	self = [self initWithParsedSVG:[SVGKParser parseSourceUsingDefaultSVGKParser:newSource]];
	if (self) {
		self.source = newSource;
	}
	return self;
}

- (id)initWithContentsOfFile:(NSString *)aPath {
	NSParameterAssert(aPath != nil);
	
	return [self initWithSource:[SVGKSource sourceFromFilename:aPath]];
}

- (id)initWithContentsOfURL:(NSURL *)url {
	NSParameterAssert(url != nil);
	
	return [self initWithSource:[SVGKSource sourceFromURL:url]];
}

- (void)dealloc
{
#ifdef ENABLE_GLOBAL_IMAGE_CACHE_FOR_SVGKIMAGE_IMAGE_NAMED
    if( self->cameFromGlobalCache )
    {
        SVGKImageCacheLine* cacheLine = [globalSVGKImageCache valueForKey:self.nameUsedToInstantiate];
        cacheLine.numberOfInstances --;
        
        if( cacheLine.numberOfInstances < 1 )
        {
            [globalSVGKImageCache removeObjectForKey:self.nameUsedToInstantiate];
        }
    }
#endif

    self.svgWidth = nil;
    self.svgHeight = nil;
    self.source = nil;
    self.parseErrorsAndWarnings = nil;
    
    self.DOMDocument = nil;
	self.DOMTree = nil;
	self.CALayerTree = nil;
#ifdef ENABLE_GLOBAL_IMAGE_CACHE_FOR_SVGKIMAGE_IMAGE_NAMED
    self.nameUsedToInstantiate = nil;
#endif
        
	[super dealloc];
}

//TODO mac alternatives to UIKit functions

#if TARGET_OS_IPHONE
+ (UIImage *)imageWithData:(NSData *)data
{
	NSAssert( FALSE, @"Method unsupported / not yet implemented by SVGKit" );
	return nil;
}
#endif

- (id)initWithData:(NSData *)data
{
	NSAssert( FALSE, @"Method unsupported / not yet implemented by SVGKit" );
	return nil;
}

#pragma mark - UIImage methods we reproduce to make it act like a UIImage

-(CGSize)size
{
	return CGSizeMake( [self.svgWidth pixelsValue], [self.svgHeight pixelsValue] );
}

-(CGFloat)scale
{
	NSAssert( FALSE, @"image.scale is currently UNDEFINED for an SVGKImage (nothing implemented by SVGKit)" );
	return 0.0;
}

#if TARGET_OS_IPHONE
-(UIImage *)UIImage
{
	NSAssert( FALSE, @"Auto-converting SVGKImage to a rasterized UIImage is not yet implemented by SVGKit" );
	return nil;
}
#endif

// the these draw the image 'right side up' in the usual coordinate system with 'point' being the top-left.

- (void)drawAtPoint:(CGPoint)point                                                        // mode = kCGBlendModeNormal, alpha = 1.0
{
	NSAssert( FALSE, @"Method unsupported / not yet implemented by SVGKit" );
}

#pragma mark - unsupported / unimplemented UIImage methods (should add as a feature)
- (void)drawAtPoint:(CGPoint)point blendMode:(CGBlendMode)blendMode alpha:(CGFloat)alpha
{
NSAssert( FALSE, @"Method unsupported / not yet implemented by SVGKit" );
}
- (void)drawInRect:(CGRect)rect                                                           // mode = kCGBlendModeNormal, alpha = 1.0
{
	NSAssert( FALSE, @"Method unsupported / not yet implemented by SVGKit" );
}
 - (void)drawInRect:(CGRect)rect blendMode:(CGBlendMode)blendMode alpha:(CGFloat)alpha
{
	NSAssert( FALSE, @"Method unsupported / not yet implemented by SVGKit" );
}

- (void)drawAsPatternInRect:(CGRect)rect // draws the image as a CGPattern
// animated images. When set as UIImageView.image, animation will play in an infinite loop until removed. Drawing will render the first image
{
	NSAssert( FALSE, @"Method unsupported / not yet implemented by SVGKit" );
}

#if TARGET_OS_IPHONE
+ (UIImage *)animatedImageNamed:(NSString *)name duration:(NSTimeInterval)duration  // read sequnce of files with suffix starting at 0 or 1
{
	NSAssert( FALSE, @"Method unsupported / not yet implemented by SVGKit" );
	return nil;
}
+ (UIImage *)animatedResizableImageNamed:(NSString *)name capInsets:(UIEdgeInsets)capInsets duration:(NSTimeInterval)duration // squence of files
{
	NSAssert( FALSE, @"Method unsupported / not yet implemented by SVGKit" );
	return nil;
}
+ (UIImage *)animatedImageWithImages:(NSArray *)images duration:(NSTimeInterval)duration
{
	NSAssert( FALSE, @"Method unsupported / not yet implemented by SVGKit" );
	return nil;
}
#endif

#pragma mark - CALayer methods: generate the CALayerTree

- (CALayer *)layerWithIdentifier:(NSString *)identifier
{
	return [self layerWithIdentifier:identifier layer:self.CALayerTree];
}

- (CALayer *)layerWithIdentifier:(NSString *)identifier layer:(CALayer *)layer {
	
	if ([[layer valueForKey:kSVGElementIdentifier] isEqualToString:identifier]) {
		return layer;
	}
	
	for (CALayer *child in layer.sublayers) {
		CALayer *resultingLayer = [self layerWithIdentifier:identifier layer:child];
		
		if (resultingLayer)
			return resultingLayer;
	}
	
	return nil;
}

-(CALayer*) newCopyPositionedAbsoluteLayerWithIdentifier:(NSString *)identifier
{
	CALayer* originalLayer = [self layerWithIdentifier:identifier];
	CALayer* clonedLayer = [[[originalLayer class] alloc] init];
	
	clonedLayer.frame = originalLayer.frame;
	if( [originalLayer isKindOfClass:[CAShapeLayer class]] )
	{
		((CAShapeLayer*)clonedLayer).path = ((CAShapeLayer*)originalLayer).path;
		((CAShapeLayer*)clonedLayer).lineCap = ((CAShapeLayer*)originalLayer).lineCap;
		((CAShapeLayer*)clonedLayer).lineWidth = ((CAShapeLayer*)originalLayer).lineWidth;
		((CAShapeLayer*)clonedLayer).strokeColor = ((CAShapeLayer*)originalLayer).strokeColor;
		((CAShapeLayer*)clonedLayer).fillColor = ((CAShapeLayer*)originalLayer).fillColor;
	}
	
	if( clonedLayer == nil )
		return nil;
	else
	{		
		CGRect lFrame = clonedLayer.frame;
		CGFloat xOffset = 0.0;
		CGFloat yOffset = 0.0;
		CALayer* currentLayer = originalLayer;
		
		if( currentLayer.superlayer == nil )
		{
			NSLog(@"AWOOGA: layer %@ has no superlayer!", originalLayer );
		}
		
		while( currentLayer.superlayer != nil )
		{
			//NSLog(@"shifting (%2.2f, %2.2f) to accomodate offset of layer = %@ inside superlayer = %@", currentLayer.superlayer.frame.origin.x, currentLayer.superlayer.frame.origin.y, currentLayer, currentLayer.superlayer );
			
			currentLayer = currentLayer.superlayer;
			xOffset += currentLayer.frame.origin.x;
			yOffset += currentLayer.frame.origin.y;
		}
		
		lFrame.origin = CGPointMake( lFrame.origin.x + xOffset, lFrame.origin.y + yOffset );
		clonedLayer.frame = lFrame;
		
		
		return clonedLayer;
	}
}

- (CALayer *)newLayerWithElement:(SVGElement <SVGLayeredElement> *)element
{
	CALayer *layer = [element newLayer];
	
	NSLog(@"[%@] DEBUG: converted SVG element (class:%@) to CALayer (class:%@ frame:%@ pointer:%@) for id = %@", [self class], NSStringFromClass([element class]), NSStringFromClass([layer class]), NSStringFromCGRect( layer.frame ), layer, element.identifier);
	
	NodeList* childNodes = element.childNodes;
	
	/**
	 Special handling for <use> tags - they have to masquerade invisibly as the node they are referring to
	 */
	if( [element isKindOfClass:[SVGUseElement class]] )
	{
		SVGUseElement* useElement = (SVGUseElement*) element;
		childNodes = useElement.instanceRoot.correspondingElement.childNodes;
	}
	
	if ( childNodes.length < 1 ) {
		return layer;
	}
	
	for (SVGElement *child in childNodes )
	{
		if ([child conformsToProtocol:@protocol(SVGLayeredElement)]) {
			CALayer *sublayer = [self newLayerWithElement:(id<SVGLayeredElement>)child];
			
			if (!sublayer) {
				continue;
            }
			
			[layer addSublayer:sublayer];
		}
	}
	
	[element layoutLayer:layer];
	
    [layer setNeedsDisplay];
	
	return layer;
}

-(CALayer *)newCALayerTree
{
	if( self.DOMTree == nil )
		return nil;
	else
	{
		return [self newLayerWithElement:self.DOMTree];
	}
}

-(CALayer *)CALayerTree
{
	if( CALayerTree == nil )
	{
		NSLog(@"[%@] WARNING: no CALayer tree found, creating a new one (will cache it once generated)", [self class] );
		self.CALayerTree = [[self newCALayerTree] autorelease];
	}
	
	return CALayerTree;
}


- (void) addSVGLayerTree:(CALayer*) layer withIdentifier:(NSString*) layerID toDictionary:(NSMutableDictionary*) layersByID
{
	// TODO: consider removing this method: it caches the lookup of individual items in the CALayerTree. It's a performance boost, but is it enough to be worthwhile?
	[layersByID setValue:layer forKey:layerID];
	
	if ( [layer.sublayers count] < 1 )
	{
		return;
	}
	
	for (CALayer *subLayer in layer.sublayers)
	{
		NSString* subLayerID = [subLayer valueForKey:kSVGElementIdentifier];
		
		if( subLayerID != nil )
		{
			NSLog(@"[%@] element id: %@ => layer: %@", [self class], subLayerID, subLayer);
			
			[self addSVGLayerTree:subLayer withIdentifier:subLayerID toDictionary:layersByID];
			
		}
	}
}

- (NSDictionary*) dictionaryOfLayers
{
	// TODO: consider removing this method: it caches the lookup of individual items in the CALayerTree. It's a performance boost, but is it enough to be worthwhile?
	NSMutableDictionary* layersByElementId = [NSMutableDictionary dictionary];
	
	CALayer* rootLayer = self.CALayerTree;
	
	[self addSVGLayerTree:rootLayer withIdentifier:self.DOMTree.identifier toDictionary:layersByElementId];
	
	NSLog(@"[%@] ROOT element id: %@ => layer: %@", [self class], self.DOMTree.identifier, rootLayer);
	
    return layersByElementId;
}

@end

