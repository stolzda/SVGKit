/*
 SVG DOM, cf:
 
 http://www.w3.org/TR/SVG11/struct.html#InterfaceSVGDocument
 
 interface SVGDocument : Document,
 DocumentEvent {
 readonly attribute DOMString title;
 readonly attribute DOMString referrer;
 readonly attribute DOMString domain;
 readonly attribute DOMString URL;
 readonly attribute SVGSVGElement rootElement;
 };
 */

#import <Foundation/Foundation.h>

#import "Document.h"
#import "SVGSVGElement.h"

@interface SVGDocument : Document

@property (nonatomic, retain, readonly) NSString* title;
@property (nonatomic, retain, readonly) NSString* referrer;
@property (nonatomic, retain, readonly) NSString* domain;
@property (nonatomic, retain, readonly) NSString* URL;
@property (nonatomic, retain, readonly) SVGSVGElement* rootElement;

@end
