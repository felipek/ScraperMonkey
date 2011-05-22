//
//  ScraperMonkey.h
//  ScraperMonkey
//
//  Created by Felipe Kellermann on 1/22/11.
//  Copyright 2011 Nyvra Software. All rights reserved.
//

#import <Foundation/Foundation.h>

@class ScraperMonkey;

@protocol ScraperMonkeyDelegate <NSObject>
@optional
- (void)scraperDidStart:(ScraperMonkey *)scraper;
- (void)scraper:(ScraperMonkey *)scraper didStartNode:(NSDictionary *)node;
- (void)scraper:(ScraperMonkey *)scraper didEndNode:(NSDictionary *)node withError:(NSDictionary *)error;
- (void)scraperDidEnd:(ScraperMonkey *)scraper;
@end

@interface ScraperMonkey : NSObject
{
	NSMutableDictionary			*_variables;	// Local/internal variables.
	NSMutableDictionary			*_result;		// User-exported variables (results).
	NSDictionary				*_definition;	// Definition "base" pointer.
	id <ScraperMonkeyDelegate>	delegate;		// Delegate.
}

- (id)initWithDefinition:(NSDictionary *)definition;
- (id)initWithDefinitionJSON:(NSString *)JSON;
- (void)setValue:(id)value forKey:(NSString *)key;
- (NSDictionary *)variables;
- (void)start;

@property (nonatomic, assign) id<ScraperMonkeyDelegate> delegate;

@end