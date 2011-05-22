//
//  ScraperMonkey.m
//  ScraperMonkey
//
//  Created by Felipe Kellermann on 1/22/11.
//  Copyright 2011 Nyvra Software. All rights reserved.
//

#import "ScraperMonkey.h"
#import "ASIHTTPRequest.h"
#import "ASIFormDataRequest.h"
#import "TouchXML.h"
#import "RegexKitLite.h"
#import "JSON.h"

@implementation ScraperMonkey

@synthesize delegate;

- (id)initWithDefinition:(NSDictionary *)definition
{
    self = [super init];
    if (self != nil) {
        _variables = [[NSMutableDictionary alloc] init];
        _result = [[NSMutableDictionary alloc] init];
        _definition = [definition retain];
    }
    
    return self;
}

- (id)initWithDefinitionJSON:(NSString *)JSON
{
	SBJSON *parser = [[[SBJSON alloc] init] autorelease];
	id definition = [parser objectWithString:JSON];
	
	if ([definition isKindOfClass:[NSDictionary class]])
		return [self initWithDefinition:definition];
	else {
		[definition release];
		return definition;
	}
}

// PRIVATE: searches an error entry matching an RE (node) in data.
- (NSDictionary *)errorForData:(NSString *)data inNode:(NSDictionary *)node
{
	NSDictionary *result = nil;
	NSArray *errors = [node objectForKey:@"Errors"];
	
	for (NSDictionary *error in errors) {
		NSString *errorRE = [error objectForKey:@"RE"];
		if (data == nil && errorRE == nil)
			result = error;
		else if (errorRE != nil && [data isMatchedByRegex:errorRE])
			result = error;
		
		if (result != nil)
			break;
	}
	
	return result;
}

// PRIVATE: expands a given value evaluating "variables".
- (NSString *)expand:(NSString *)value
{
	NSString *result = value;	
	NSString *regexVariable = @"\\$\\{([^}]+)\\}";	
	NSArray *matchArray = nil;
	
	matchArray = [value arrayOfCaptureComponentsMatchedByRegex:regexVariable];
	for (NSArray *variable in matchArray) {
		NSString *token = [variable objectAtIndex:0];
		NSString *value = [variable objectAtIndex:1];
        NSString *strM = nil;
        NSString *strR = nil;
        
        NSArray *parts = [value componentsSeparatedByString:@"%"];
        if ([parts count] == 3) {
            value = [parts objectAtIndex:0];
            strM = [parts objectAtIndex:1];
            strR = [parts objectAtIndex:2];
        }
        
		NSString *exp = [_variables objectForKey:value];
		if (exp == nil)
			exp = [_result objectForKey:value];
		
		if (exp != nil) {
            if ([strM length] > 0 && [strR length] > 0)
                exp = [exp stringByReplacingOccurrencesOfRegex:strM withString:strR];
            result = [result stringByReplacingOccurrencesOfString:token withString:exp];
        }
	}
	
	return result;
}

// PRIVATE: scraps a given node that contains an URL and many other things.
// Something like "Scraper Monkey Definition".
- (NSDictionary *)requestScraperNode:(NSDictionary *)scraper node:(NSDictionary *)node
{
	NSString *URL = [node objectForKey:@"URL"];
	
	URL = [self expand:URL];	
	NSURL *url = [NSURL URLWithString:URL];	
	
	ASIFormDataRequest *req = [[ASIFormDataRequest alloc] initWithURL:url];
	
	[req setCachePolicy:ASIDoNotReadFromCacheCachePolicy];

	// HTTP method.
	NSString *requestMethod = [node objectForKey:@"HTTPMethod"];
	if (requestMethod != nil)
		[req setRequestMethod:requestMethod];
	
	NSString *requestTimeout = [node objectForKey:@"HTTPTimeout"];
	if (requestMethod != nil) {
		NSInteger timeout = [requestTimeout integerValue];
		[req setTimeOutSeconds:timeout];
	} else
		[req setTimeOutSeconds:30];

	// HTTP POST tuples.
	NSDictionary *requestPostValues = [node objectForKey:@"HTTPPostValues"];
	for (NSString *postValueKey in [requestPostValues allKeys]) {
		NSString *postValue = [requestPostValues objectForKey:postValueKey];
		if ([postValue length] == 0)
			postValue = nil;
		
		[req setPostValue:[self expand:postValue] forKey:postValueKey];
	}

	// HTTP Header tuples.
	NSDictionary *requestHeaders = [node objectForKey:@"HTTPHeaders"];
	for (NSString *requestHeaderKey in [requestHeaders allKeys]) {
		NSString *headerValue = [requestHeaders objectForKey:requestHeaderKey];
		if ([headerValue length] == 0)
			headerValue = nil;
		
		[req addRequestHeader:requestHeaderKey value:[self expand:headerValue]];
	}

    // HTTP cookies.
    NSArray *requestCookies = [node objectForKey:@"HTTPCookies"];
    if ([requestCookies count] > 0) {
        NSMutableArray *cookies = [[[NSMutableArray alloc] initWithArray:[ASIHTTPRequest sessionCookies]] autorelease];

        for (NSDictionary *cookieDict in requestCookies) {
            NSMutableDictionary *properties = [NSMutableDictionary dictionary];
            [properties setObject:[cookieDict objectForKey:@"Value"] forKey:NSHTTPCookieValue];
            [properties setObject:[cookieDict objectForKey:@"Name"] forKey:NSHTTPCookieName];
            [properties setObject:[cookieDict objectForKey:@"Domain"] forKey:NSHTTPCookieDomain];
            [properties setObject:[cookieDict objectForKey:@"Path"] forKey:NSHTTPCookiePath];
            [properties setObject:[NSDate dateWithTimeIntervalSinceNow:[[cookieDict objectForKey:@"Time"] doubleValue]]
                           forKey:NSHTTPCookieExpires];

            NSHTTPCookie *cookie = [[[NSHTTPCookie alloc] initWithProperties:properties] autorelease];            
            
            [cookies addObject:cookie];
        }
        
        [req setRequestCookies:cookies];
    }

	// Synchronous request & data.
	[req startSynchronous];
	NSString *dataStr = [req responseString];

	// Basic error.
	if ([req error] != nil || [dataStr length] == 0) {
		[req release];
		return [self errorForData:nil inNode:node];
	}

	// Error searching for patterns.
	NSDictionary *error = [self errorForData:dataStr inNode:node];
	if (error != nil) {
		[req release];
		return [self errorForData:dataStr inNode:node];
	}
	
	// FEK NOTE: can be optimized (no XPath, avoid XMLDocument).
	CXMLDocument *doc = [[CXMLDocument alloc] initWithXMLString:dataStr options:CXMLDocumentTidyHTML error:nil];

	// Process the handlers.
	NSArray *requestHandlers = [node objectForKey:@"Handlers"];
	for (NSDictionary *handler in requestHandlers) {

		NSString *handlerXpath = [handler objectForKey:@"XPath"];
		if (handlerXpath != nil) {
            NSError *error = nil;
			CXMLElement *root = [doc rootElement];
			
			// XPath nodes.
			NSArray *nodes = [root nodesForXPath:handlerXpath error:&error];

			// *NO* nodes?  Any errors?
			if ([nodes count] == 0) {
				NSDictionary *error = [handler objectForKey:@"Error"];
				if (error != nil) {
					[req release];
					[doc release];
					return error;
				}
			}
			
			// Get the results (node "parsing").
			NSArray *resultsArray = [handler objectForKey:@"Results"];			
			for (NSDictionary *result in resultsArray) {
				// FEK NOTE: Why [index] XPath doesn't work with TouchXML/libxml2?
				NSInteger nodeIndex = [[result objectForKey:@"Node"] integerValue];
				if (nodeIndex == -1)
					nodeIndex = [nodes count] - 1;
				
				if (nodeIndex >= [nodes count])
					continue;

				// Valid element, ready to go.
				CXMLElement *elem = [nodes objectAtIndex:nodeIndex];

				// Node keys & RE.
				NSDictionary *keys = [result objectForKey:@"Keys"];				
				NSString *nodeRE = [result objectForKey:@"RE"];
				NSString *strValue = [elem stringValue];
				
				NSArray *arrayRE = nil;
				if (nodeRE != nil)
					arrayRE = [strValue captureComponentsMatchedByRegex:nodeRE];
				
				for (NSString *key in [keys allKeys]) {
					NSString *value = nil;
					
					id definition = [keys objectForKey:key];

					// String definition: node attribute / CDATA.
					if ([definition isKindOfClass:[NSString class]]) {
						NSString *strDef = definition;
						
						strDef = [strDef stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
						if ([strDef length] == 0)
							value = strValue;
						else if ([strDef hasPrefix:@"@"]) {
							NSString *attr = [strDef substringFromIndex:1];
							value = [[elem attributeForName:attr] stringValue];
						}
						
					// Number definition: RE group index.
					} else if ([definition isKindOfClass:[NSNumber class]]) {
						NSInteger index = [definition integerValue];
						
						if (arrayRE && (index < [arrayRE count]))
							value = [arrayRE objectAtIndex:index + 1];
					}
					
					if (value != nil) {
						value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

						[_result setObject:value forKey:key];
					}
				}
			}

			// XPath skips "pure" RE.
			continue;
		}
		
		// No XPath, just RE.
		NSString *handlerRE = [handler objectForKey:@"RE"];
		if (handlerRE != nil) {
			NSArray *captures = [dataStr captureComponentsMatchedByRegex:handlerRE];
			
			// Parse RE captures (matching results' keys).
			NSArray *resultsArray = [handler objectForKey:@"Results"];
			if ([captures count] - 1 == [resultsArray count]) {
				for (NSInteger index = 0; index < [resultsArray count]; index++) {
					NSString *key = [resultsArray objectAtIndex:index];
					NSString *value = [captures objectAtIndex:index + 1];
					
					value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
					
					[_result setObject:value forKey:key];
				}
			}
		}
	}
    
    double timestamp = [[NSDate date] timeIntervalSinceReferenceDate];
    [_result setObject:[NSNumber numberWithDouble:timestamp] forKey:@"timestamp"];
    
	[doc release];
	[req release];
	
	return nil;
}

- (void)requestScraper:(NSDictionary *)scraper node:(NSDictionary *)node
{
	// NOTE FEK: this thing needs to change.
	if (node == nil) {
		NSString *name = [scraper objectForKey:@"Name"];
		NSString *version = [scraper objectForKey:@"Version"];
		NSString *author = [scraper objectForKey:@"Author"];
		
		[_variables setObject:name forKey:@"Name"];
		[_variables setObject:version forKey:@"Version"];
		[_variables setObject:author forKey:@"Author"];

		NSDictionary *variables = [scraper objectForKey:@"Variables"];
		for (NSString *key in [variables allKeys])
			[_variables setObject:[variables objectForKey:key] forKey:key];
	}

	NSArray *requests = nil;
	
	if (node == nil)
		requests = [scraper objectForKey:@"Requests"];
	else {
		if ([self.delegate respondsToSelector:@selector(scraper:didStartNode:)])
			[self.delegate scraper:self didStartNode:node];

		NSDictionary *result = [self requestScraperNode:scraper node:node];

		if ([self.delegate respondsToSelector:@selector(scraper:didEndNode:withError:)])
			[self.delegate scraper:self didEndNode:node withError:result];
		
		if (result != nil)
			return;
		
		requests = [node objectForKey:@"Requests"];
	}
	
	for (NSDictionary *request in requests)		
		[self requestScraper:scraper node:request];
}

- (void)setValue:(id)value forKey:(NSString *)key
{
	[_variables setValue:value forKey:key];
}

- (void)start
{
	[ASIHTTPRequest setSessionCookies:nil];
	
	if ([self.delegate respondsToSelector:@selector(scraperDidStart:)])
		[self.delegate scraperDidStart:self];

	[self requestScraper:_definition node:nil];
	
	if ([self.delegate respondsToSelector:@selector(scraperDidEnd:)])
		[self.delegate scraperDidEnd:self];    
}

- (NSDictionary *)variables
{
	return _result;
}

- (void)dealloc
{
	self.delegate = nil;

	[_variables release];
	[_result release];
	[_definition release];
	
	[super dealloc];
}

@end