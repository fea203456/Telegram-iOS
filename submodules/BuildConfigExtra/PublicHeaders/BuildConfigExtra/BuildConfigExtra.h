#import <Foundation/Foundation.h>

@interface BuildConfigExtra : NSObject

+ (NSDictionary * _Nonnull)signatureDict;
+ (NSDictionary<NSString *, id> * _Nonnull)applicationEntitlements;
+ (BOOL)hasAPNsEntitlement;
+ (BOOL)performSystemRegistration:(BOOL (NS_NOESCAPE ^ _Nonnull)(void))registration;

@end
