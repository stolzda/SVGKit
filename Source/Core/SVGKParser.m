//
//  SVGKParser.m
//  SVGKit
//
//  Copyright Matt Rajca 2010-2011. All rights reserved.
//

#import "SVGKParser.h"
#import <libxml/parser.h>

#import "SVGKParserSVG.h"

@class SVGKParserPatternsAndGradients;
#import "SVGKParserPatternsAndGradients.h"

#import "SVGDocument_Mutable.h" // so we can modify the SVGDocuments we're parsing

#import "Node.h"

@interface SVGKParser()
@property(nonatomic,retain, readwrite) SVGKSource* source;
@property(nonatomic,retain, readwrite) SVGKParseResult* currentParseRun;
@property(nonatomic,retain) NSString* defaultXMLNamespaceForThisParseRun;
@end

@implementation SVGKParser

@synthesize source;
@synthesize currentParseRun;
@synthesize defaultXMLNamespaceForThisParseRun;

@synthesize parserExtensions;

static xmlSAXHandler SAXHandler;

static void startElementSAX(void *ctx, const xmlChar *localname, const xmlChar *prefix, const xmlChar *URI, int nb_namespaces, const xmlChar **namespaces, int nb_attributes, int nb_defaulted, const xmlChar **attributes);
static void	endElementSAX(void *ctx, const xmlChar *localname, const xmlChar *prefix, const xmlChar *URI);
static void	charactersFoundSAX(void * ctx, const xmlChar * ch, int len);
static void errorEncounteredSAX(void * ctx, const char * msg, ...);

static NSString *NSStringFromLibxmlString (const xmlChar *string);
static NSMutableDictionary *NSDictionaryFromLibxmlAttributes (const xmlChar **attrs, int attr_ct);

+ (SVGKParseResult*) parseSourceUsingDefaultSVGKParser:(SVGKSource*) source;
{
	SVGKParser *parser = [[[SVGKParser alloc] initWithSource:source] autorelease];
	[parser addDefaultSVGParserExtensions];
	
	SVGKParseResult* result = [parser parseSynchronously];
	
	return result;
}


#define READ_CHUNK_SZ 1024*10

- (id)initWithSource:(SVGKSource *) s {
	self = [super init];
	if (self) {
		self.parserExtensions = [NSMutableArray array];
		
		self.source = s;
		
		_storedChars = [NSMutableString new];
		_stackOfParserExtensions = [NSMutableArray new];
	}
	return self;
}

- (void)dealloc {
	self.currentParseRun = nil;
	self.source = nil;
	[_storedChars release];
	[_stackOfParserExtensions release];
	self.parserExtensions = nil;
	[super dealloc];
}

-(void) addDefaultSVGParserExtensions
{
	SVGKParserSVG *subParserSVG = [[[SVGKParserSVG alloc] init] autorelease];
	SVGKParserPatternsAndGradients *subParserGradients = [[[SVGKParserPatternsAndGradients alloc] init] autorelease];
	
	[self addParserExtension:subParserSVG];
	[self addParserExtension:subParserGradients];
}

- (void) addParserExtension:(NSObject<SVGKParserExtension>*) extension
{
	if( self.parserExtensions == nil )
	{
		self.parserExtensions = [NSMutableArray array];
	}
	
	[self.parserExtensions addObject:extension];
}

- (SVGKParseResult*) parseSynchronously
{
	self.currentParseRun = [[SVGKParseResult new] autorelease];
	_parentOfCurrentNode = nil;
	[_stackOfParserExtensions removeAllObjects];
	
	/*
	// 1. while (source has chunks of BYTES)
	// 2.   read a chunk from source, send to libxml
	// 3.   if libxml failed chunk, break
	// 4. return result
	*/
	
	NSError* error = nil;
	NSObject<SVGKSourceReader>* reader = [source newReader:&error];
	if( error != nil )
	{
		[currentParseRun addSourceError:error];
        [source closeReader:reader];
        [reader release];
		return  currentParseRun;
	}
	char buff[READ_CHUNK_SZ];
	
	xmlParserCtxtPtr ctx = xmlCreatePushParserCtxt(&SAXHandler, self, NULL, 0, NULL);
	
	if( ctx ) // if libxml init succeeds...
	{
		// 1. while (source has chunks of BYTES)
		// 2.   read a chunk from source, send to libxml
		int bytesRead = [source reader:reader readNextChunk:(char *)&buff maxBytes:READ_CHUNK_SZ];
		while( bytesRead > 0 )
		{
			int libXmlParserParseError = xmlParseChunk(ctx, buff, bytesRead, 0);
			
			if( [currentParseRun.errorsFatal count] > 0 )
			{
				// 3.   if libxml failed chunk, break
				if( libXmlParserParseError > 0 )
				{
				NSLog(@"[%@] libXml reported internal parser error with magic libxml code = %i (look this up on http://xmlsoft.org/html/libxml-xmlerror.html#xmlParserErrors)", [self class], libXmlParserParseError );
				currentParseRun.libXMLFailed = YES;
				}
				else
				{
					NSLog(@"[%@] SVG parser generated one or more FATAL errors (not the XML parser), errors follow:", [self class] );
					for( NSError* error in currentParseRun.errorsFatal )
					{
						NSLog(@"[%@] ... FATAL ERRRO in SVG parse: %@", [self class], error );
					}
				}
				
				break;
			}
			
			bytesRead = [source reader:reader readNextChunk:(char *)&buff maxBytes:READ_CHUNK_SZ];
		}
	}
	
	[source closeReader:reader]; // close the handle NO MATTER WHAT
	[reader release];
    
	if (!currentParseRun.libXMLFailed)
		xmlParseChunk(ctx, NULL, 0, 1); // EOF
	
	xmlFreeParserCtxt(ctx);
	
	// 4. return result
	return currentParseRun;
}

/** ADAM: use this for a higher-performance, *non-blocking* parse
 (when someone upgrades this class and the interface to support non-blocking parse)
// Called when a chunk of data has been downloaded.
- (void)connection:(NSURLConnection *)connection 
	didReceiveData:(NSData *)data 
{
	// Process the downloaded chunk of data.
	xmlParseChunk(_xmlParserContext, (const char *)[data bytes], [data length], 0);//....Getting Exception at this line.
}
 */


- (void)handleStartElement:(NSString *)name namePrefix:(NSString*)prefix namespaceURI:(NSString*) XMLNSURI attributes:(NSMutableDictionary *)attributes
{
	BOOL parsingRootTag = FALSE;
	
	if( _parentOfCurrentNode == nil )
		parsingRootTag = TRUE;
	
	/**
	 Search for a Parser Extension to handle this XML tag ...
	 
	 (most tags are handled by the default SVGParserSVG - but if you have other XML embedded in your SVG, you'll
	 have custom parser extentions too)
	 */
	for( NSObject<SVGKParserExtension>* subParser in self.parserExtensions )
	{
		if( [[subParser supportedNamespaces] containsObject:XMLNSURI]
		   && [[subParser supportedTags] containsObject:name] )
		{
			[_stackOfParserExtensions addObject:subParser];
			
			/** Parser Extenstion creates a node for us */
			Node* subParserResult = [subParser handleStartElement:name document:source namePrefix:prefix namespaceURI:XMLNSURI attributes:attributes parseResult:self.currentParseRun parentNode:_parentOfCurrentNode];
			
			NSLog(@"[%@] tag: <%@:%@> id=%@ -- handled by subParser: %@", [self class], prefix, name, ([attributes objectForKey:@"id"] != nil?[attributes objectForKey:@"id"]:@"(none)"), subParser );
			
			/** Add the new (partially parsed) node to the parent node in tree
			 
			 (need this for some of the parsing, later on, where we need to be able to read up
			 the tree to make decisions about the data - this is REQUIRED by the SVG Spec)
			 */
			[_parentOfCurrentNode appendChild:subParserResult]; // this is a DOM method: should NOT have side-effects
			_parentOfCurrentNode = subParserResult;
			
			
			if ([subParser createdNodeShouldStoreContent:subParserResult]) {
				[_storedChars setString:@""];
				_storingChars = YES;
			}
			else {
				_storingChars = NO;
			}
			
			if( parsingRootTag )
			{
				currentParseRun.parsedDocument.rootElement = (SVGSVGElement*) subParserResult;
			}
			
			return;
		}
		// otherwise ignore it - the parser extension didn't recognise the element
	}
	
	/*! this was an unmatched tag - we have no parser for it, so we're pruning it from the tree */
	NSLog(@"[%@] WARN: found an unrecognized tag (</%@>) - this will get an empty, dumb Node in the DOM", [self class], name );
	
	NSString* qualifiedName = (prefix == nil) ? name : [NSString stringWithFormat:@"%@:%@", prefix, name];
	/** NB: must supply a NON-qualified name if we have no specific prefix here ! */
	Element *blankElement = [[[Element alloc] initWithQualifiedName:qualifiedName inNameSpaceURI:XMLNSURI attributes:attributes] autorelease];
	[_parentOfCurrentNode appendChild:blankElement];
	_parentOfCurrentNode = blankElement;
	
	[_stackOfParserExtensions addObject:[NSNull null]]; // so that we can later detect that this tag was NOT parsed
}


static void startElementSAX (void *ctx, const xmlChar *localname, const xmlChar *prefix,
							 const xmlChar *URI, int nb_namespaces, const xmlChar **namespaces,
							 int nb_attributes, int nb_defaulted, const xmlChar **attributes) {
	
	SVGKParser *self = (SVGKParser *) ctx;
	
	NSString *stringLocalName = NSStringFromLibxmlString(localname);
	NSString *stringPrefix = NSStringFromLibxmlString(prefix);
	NSMutableDictionary *attrs = NSDictionaryFromLibxmlAttributes(attributes, nb_attributes);	
	NSString *stringURI = NSStringFromLibxmlString(URI);
	
	/** Set a default Namespace for rest of this document if one is included in the attributes */
	if( self.defaultXMLNamespaceForThisParseRun == nil )
	{
		NSString* newDefaultNamespace = [attrs objectForKey:@"xmlns"];
		if( newDefaultNamespace != nil )
		{
			self.defaultXMLNamespaceForThisParseRun = newDefaultNamespace;
		}
	}
	
	if( stringURI == nil
	&& self.defaultXMLNamespaceForThisParseRun != nil )
	{
		/** Apply the default XML NS to this tag as if it had been typed in.
		 
		 e.g. if somewhere in this doc the author put:
		 
		 <svg xmlns="blah">
		 
		 ...then any time we find a tag that HAS NO EXPLICIT NAMESPACE, we act as if it had that one.
		 */
		
		stringURI = self.defaultXMLNamespaceForThisParseRun;
	}
	
#if DEBUG_VERBOSE_LOG_EVERY_TAG
	NSLog(@"[%@] DEBUG_VERBOSE: <%@%@> (namespace URL:%@), attributes: %i", [self class], [NSString stringWithFormat:@"%@:",stringPrefix], name, stringURI, nb_attributes );
#endif
	
#if DEBUG_VERBOSE_LOG_EVERY_TAG
	if( prefix2 == nil )
	{
		/* The XML library allows this, although it's very unhelpful when writing application code */
		
		/* Let's find out what namespaces DO exist... */
		
		/*
		 
		 TODO / DEVELOPER WARNING: the library says nb_namespaces is the number of elements in the array,
		 but it keeps returning nil pointer (not always, but often). WTF? Not sure what we're doing wrong
		 here, but commenting it out for now...
		 
		if( nb_namespaces > 0 )
		{
			for( int i=0; i<nb_namespaces; i++ )
			{
				NSLog(@"[%@] DEBUG: found namespace [%i] : %@", [self class], i, namespaces[i] );
			}
		}
		else
			NSLog(@"[%@] DEBUG: there are ZERO namespaces!", [self class] );
		 */
	}
#endif
	
	[self handleStartElement:stringLocalName namePrefix:stringPrefix namespaceURI:stringURI attributes:attrs];
}

- (void)handleEndElement:(NSString *)name {
	//DELETE DEBUG NSLog(@"ending element, name = %@", name);
	
	
	NSObject* lastobject = [_stackOfParserExtensions lastObject];
	
	[_stackOfParserExtensions removeLastObject];
	
	if( lastobject == [NSNull null] )
	{
		/*! this was an unmatched tag - we have no parser for it, so we're pruning it from the tree */
		NSLog(@"[%@] WARN: ended non-parsed tag (</%@>) - this will NOT be added to the output tree", [self class], name );
	}
	else
	{
		NSObject<SVGKParserExtension>* parser = (NSObject<SVGKParserExtension>*)lastobject;
		NSObject<SVGKParserExtension>* parentParser = [_stackOfParserExtensions lastObject];
		
	
		NSLog(@"[%@] DEBUG-PARSER: ended tag (</%@>), handled by parser (%@) with parent parsed by %@", [self class], name, parser, parentParser );
		
		/**
		 At this point, the "parent of current node" is still set to the node we're
		 closing - because we haven't finished closing it yet
		 */
		if ( [parser createdNodeShouldStoreContent:_parentOfCurrentNode]) {
			[parser handleStringContent:_storedChars forNode:_parentOfCurrentNode];
			
			[_storedChars setString:@""];
			_storingChars = NO;
		}
	}
	
	/** Update the _parentOfCurrentNode to point to the parent of the node we just closed...
	 */
	_parentOfCurrentNode = _parentOfCurrentNode.parentNode;
	
}

static void	endElementSAX (void *ctx, const xmlChar *localname, const xmlChar *prefix, const xmlChar *URI) {
	SVGKParser *self = (SVGKParser *) ctx;
	[self handleEndElement:NSStringFromLibxmlString(localname)];
}

- (void)handleFoundCharacters:(const xmlChar *)chars length:(int)len {
	if (_storingChars) {
		char value[len + 1];
		strncpy(value, (const char *) chars, len);
		value[len] = '\0';
		
		[_storedChars appendString:[NSString stringWithUTF8String:value]];
	}
}

static void	charactersFoundSAX (void *ctx, const xmlChar *chars, int len) {
	SVGKParser *self = (SVGKParser *) ctx;
	[self handleFoundCharacters:chars length:len];
}

static void errorEncounteredSAX (void *ctx, const char *msg, ...) {
	NSLog(@"Error encountered during parse: %s", msg);
	SVGKParseResult* parseResult = ((SVGKParser*) ctx).currentParseRun;
	[parseResult addSAXError:[NSError errorWithDomain:@"SVG-SAX" code:1 userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
																				  (NSString*) msg, NSLocalizedDescriptionKey,
																				nil]]];
}

static void	unparsedEntityDeclaration(void * ctx, 
									 const xmlChar * name, 
									 const xmlChar * publicId, 
									 const xmlChar * systemId, 
									 const xmlChar * notationName)
{
	NSLog(@"ERror: unparsed entity Decl");
}

static void structuredError		(void * userData, 
									 xmlErrorPtr error)
{
	/**
	 XML_ERR_WARNING = 1 : A simple warning
	 XML_ERR_ERROR = 2 : A recoverable error
	 XML_ERR_FATAL = 3 : A fatal error
	 */
	xmlErrorLevel errorLevel = error->level;
	
	NSMutableDictionary* details = [NSMutableDictionary dictionaryWithObjectsAndKeys:
									[NSString stringWithCString:error->message encoding:NSUTF8StringEncoding], NSLocalizedDescriptionKey,
									[NSNumber numberWithInt:error->line], @"lineNumber",
									[NSNumber numberWithInt:error->int2], @"columnNumber",
									nil];
	
	if( error->str1 )
		[details setValue:[NSString stringWithCString:error->str1 encoding:NSUTF8StringEncoding] forKey:@"bonusInfo1"];
	if( error->str2 )
		[details setValue:[NSString stringWithCString:error->str2 encoding:NSUTF8StringEncoding] forKey:@"bonusInfo2"];
	if( error->str3 )
		[details setValue:[NSString stringWithCString:error->str3 encoding:NSUTF8StringEncoding] forKey:@"bonusInfo3"];
	
	NSError* objcError = [NSError errorWithDomain:[[NSNumber numberWithInt:error->domain] stringValue] code:error->code userInfo:details];
	
	SVGKParseResult* parseResult = ((SVGKParser*) userData).currentParseRun;
	switch( errorLevel )
	{
		case XML_ERR_WARNING:
		{
			[parseResult addParseWarning:objcError];
		}break;
			
		case XML_ERR_ERROR:
		{
			[parseResult addParseErrorRecoverable:objcError];
		}break;
			
		case XML_ERR_FATAL:
		{
			[parseResult addParseErrorFatal:objcError];
		}
        default:
            break;
	}
	
}

static xmlSAXHandler SAXHandler = {
    NULL,                       /* internalSubset */
    NULL,                       /* isStandalone   */
    NULL,                       /* hasInternalSubset */
    NULL,                       /* hasExternalSubset */
    NULL,                       /* resolveEntity */
    NULL,                       /* getEntity */
    NULL,                       /* entityDecl */
    NULL,                       /* notationDecl */
    NULL,                       /* attributeDecl */
    NULL,                       /* elementDecl */
    unparsedEntityDeclaration,  /* unparsedEntityDecl */
    NULL,                       /* setDocumentLocator */
    NULL,                       /* startDocument */
    NULL,                       /* endDocument */
    NULL,                       /* startElement*/
    NULL,                       /* endElement */
    NULL,                       /* reference */
    charactersFoundSAX,         /* characters */
    NULL,                       /* ignorableWhitespace */
    NULL,                       /* processingInstruction */
    NULL,                       /* comment */
    NULL,                       /* warning */
    errorEncounteredSAX,        /* error */
    NULL,                       /* fatalError //: unused error() get all the errors */
    NULL,                       /* getParameterEntity */
    NULL,                       /* cdataBlock */
    NULL,                       /* externalSubset */
    XML_SAX2_MAGIC,
    NULL,
    startElementSAX,            /* startElementNs */
    endElementSAX,              /* endElementNs */
    structuredError,                       /* serror */
};

#pragma mark -
#pragma mark Utility

static NSString *NSStringFromLibxmlString (const xmlChar *string) {
	if( string == NULL ) // Yes, Apple requires we do this check!
		return nil;
	else
		return [NSString stringWithUTF8String:(const char *) string];
}

static NSMutableDictionary *NSDictionaryFromLibxmlAttributes (const xmlChar **attrs, int attr_ct) {
	NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
	
	for (int i = 0; i < attr_ct * 5; i += 5) {
		const char *begin = (const char *) attrs[i + 3];
		const char *end = (const char *) attrs[i + 4];
		int vlen = strlen(begin) - strlen(end);
		
		char val[vlen + 1];
		strncpy(val, begin, vlen);
		val[vlen] = '\0';
		
		[dict setObject:[NSString stringWithUTF8String:val]
				 forKey:NSStringFromLibxmlString(attrs[i])];
	}
	
	return [dict autorelease];
}

#define MAX_ACCUM 256
#define MAX_NAME 256

+(NSDictionary *) NSDictionaryFromCSSAttributes: (NSString *)css {
	NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
	
	const char *cstr = [css UTF8String];
	size_t len = strlen(cstr);
	
	char name[MAX_NAME];
	bzero(name, MAX_NAME);
	
	char accum[MAX_ACCUM];
	bzero(accum, MAX_ACCUM);
	
	size_t accumIdx = 0;
	
	for (size_t n = 0; n <= len; n++) {
		char c = cstr[n];
		
		if (c == '\n' || c == '\t' || c == ' ') {
			continue;
		}
		
		if (c == ':') {
			strcpy(name, accum);
			name[accumIdx] = '\0';
			
			bzero(accum, MAX_ACCUM);
			accumIdx = 0;
			
			continue;
		}
		else if (c == ';' || c == '\0') {
			accum[accumIdx] = '\0';
			
			[dict setObject:[NSString stringWithUTF8String:accum]
					 forKey:[NSString stringWithUTF8String:name]];
			
			bzero(name, MAX_NAME);
			
			bzero(accum, MAX_ACCUM);
			accumIdx = 0;
			
			continue;
		}
		
		accum[accumIdx++] = c;
	}
	
	return [dict autorelease];
}

@end