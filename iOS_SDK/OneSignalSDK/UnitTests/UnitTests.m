//
//  UnitTests.m
//  UnitTests
//
//  Created by Kasten on 1/25/17.
//  Copyright © 2017 Hiptic. All rights reserved.
//

#import <XCTest/XCTest.h>

#import <objc/runtime.h>

#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>
#import <UserNotifications/UserNotifications.h>


#import "UncaughtExceptionHandler.h"


#import "OneSignal.h"

#import "OneSignalHelper.h"
#import "OneSignalTracker.h"
#import "OneSignalSelectorHelpers.h"

#include <pthread.h>
#include <mach/mach.h>

static XCTestCase* currentTestInstance;

// Just for debugging
void DumpObjcMethods(Class clz) {
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(clz, &methodCount);
    
    
    NSLog(@"Found %d methods on '%s'\n", methodCount, class_getName(clz));
    
    
    for (unsigned int i = 0; i < methodCount; i++) {
        Method method = methods[i];
        
        
        NSLog(@"'%s' has method named '%s' of encoding '%s'\n",
              class_getName(clz),
              sel_getName(method_getName(method)),
              method_getTypeEncoding(method));
    }
    
    
    free(methods);
}

BOOL injectStaticSelector(Class newClass, SEL newSel, Class addToClass, SEL makeLikeSel) {
    Method newMeth = class_getClassMethod(newClass, newSel);
    IMP imp = method_getImplementation(newMeth);
    
    const char* methodTypeEncoding = method_getTypeEncoding(newMeth);
    // Keep - class_getInstanceMethod for existing detection.
    //    class_addMethod will successfuly add if the addToClass was loaded twice into the runtime.
    BOOL existing = class_getClassMethod(addToClass, makeLikeSel) != NULL;
    
    if (existing) {
        // class_addMethod doesn't have a instance vs class name. It must just use the signature of the method.
        class_addMethod(addToClass, newSel, imp, methodTypeEncoding);
        // Even though we just added a static method we need to use getInstance here....
        newMeth = class_getInstanceMethod(addToClass, newSel);
        
        Method orgMeth = class_getClassMethod(addToClass, makeLikeSel);
        method_exchangeImplementations(orgMeth, newMeth);
    }
    else
        class_addMethod(addToClass, makeLikeSel, imp, methodTypeEncoding);
    
    return existing;
}


@interface OneSignal (UN_extra)
+ (dispatch_queue_t) getRegisterQueue;
@end

// START - Selector Shadowing


@interface SelectorToRun : NSObject
@property NSObject* runOn;
@property SEL selector;
@property NSObject* withObject;
@end


@implementation SelectorToRun
@end

@interface NSObjectOverrider : NSObject
@end

@implementation NSObjectOverrider

static NSMutableArray* selectorsToRun;
static BOOL instantRunPerformSelectorAfterDelay;
static NSMutableArray* selectorNamesForInstantOnlyForFirstRun;

+ (void)load {
    injectToProperClass(@selector(overridePerformSelector:withObject:afterDelay:), @selector(performSelector:withObject:afterDelay:), @[], [NSObjectOverrider class], [NSObject class]);
    injectToProperClass(@selector(overridePerformSelector:withObject:), @selector(performSelector:withObject:), @[], [NSObjectOverrider class], [NSObject class]);
}

- (void)overridePerformSelector:(SEL)aSelector withObject:(nullable id)anArgument afterDelay:(NSTimeInterval)delay {
    // TOOD: Add && for calling from our unit test queue looper.
    /*
    if (![[NSThread mainThread] isEqual:[NSThread currentThread]])
        _XCTPrimitiveFail(currentTestInstance);
     */
    
    if (instantRunPerformSelectorAfterDelay || [selectorNamesForInstantOnlyForFirstRun containsObject:NSStringFromSelector(aSelector)]) {
        [selectorNamesForInstantOnlyForFirstRun removeObject:NSStringFromSelector(aSelector)];
        [self performSelector:aSelector withObject:anArgument];
    }
    else {
        SelectorToRun* selectorToRun = [SelectorToRun alloc];
        selectorToRun.runOn = self;
        selectorToRun.selector = aSelector;
        selectorToRun.withObject = anArgument;
        [selectorsToRun addObject:selectorToRun];
    }
}

+ (void)runPendingSelectors {
    for(SelectorToRun* selectorToRun in selectorsToRun)
        [selectorToRun.runOn performSelector:selectorToRun.selector withObject:selectorToRun.withObject];
    
    [selectorsToRun removeAllObjects];
}

@end



@interface NSUserDefaultsOverrider : NSObject
@end

static NSMutableDictionary* defaultsDictionary;

@implementation NSUserDefaultsOverrider
+ (void)load {
    defaultsDictionary = [[NSMutableDictionary alloc] init];
    
    injectToProperClass(@selector(overrideSetObject:forKey:), @selector(setObject:forKey:), @[], [NSUserDefaultsOverrider class], [NSUserDefaults class]);
    injectToProperClass(@selector(overrideSetDouble:forKey:), @selector(setDouble:forKey:), @[], [NSUserDefaultsOverrider class], [NSUserDefaults class]);
    injectToProperClass(@selector(overrideSetBool:forKey:), @selector(setBool:forKey:), @[], [NSUserDefaultsOverrider class], [NSUserDefaults class]);
    
    injectToProperClass(@selector(overrideObjectForKey:), @selector(objectForKey:), @[], [NSUserDefaultsOverrider class], [NSUserDefaults class]);
    injectToProperClass(@selector(overrideDoubleForKey:), @selector(doubleForKey:), @[], [NSUserDefaultsOverrider class], [NSUserDefaults class]);
    injectToProperClass(@selector(overrideBoolForKey:), @selector(boolForKey:), @[], [NSUserDefaultsOverrider class], [NSUserDefaults class]);
}

+(void) clearInternalDictionary {
    defaultsDictionary = [[NSMutableDictionary alloc] init];
}

// Sets
-(void) overrideSetObject:(id)value forKey:(NSString*)key {
    defaultsDictionary[key] = value;
}

-(void) overrideSetDouble:(double)value forKey:(NSString*)key {
    defaultsDictionary[key] = [NSNumber numberWithDouble:value];
}

-(void) overrideSetBool:(BOOL)value forKey:(NSString*)key {
    defaultsDictionary[key] = [NSNumber numberWithBool:value];
}

// Gets
-(id) overrideObjectForKey:(NSString*)key {
    return defaultsDictionary[key];
}

-(double) overrideDoubleForKey:(NSString*)key {
    return [defaultsDictionary[key] doubleValue];
}

-(BOOL) overrideBoolForKey:(NSString*)key {
    return [defaultsDictionary[key] boolValue];
}

@end

@interface NSDataOverrider : NSObject
@end
@implementation NSDataOverrider
+ (void)load {
    injectStaticSelector([NSDataOverrider class], @selector(overrideDataWithContentsOfURL:), [NSData class], @selector(dataWithContentsOfURL:));
}

// Mock data being downloaded from a remote URL.
+ (NSData*) overrideDataWithContentsOfURL:(NSURL *)url {
    char bytes[32];
    memset(bytes, 1, 32);
    
    return [NSData dataWithBytes:bytes length:32];
}

@end


@interface NSDateOverrider : NSObject
@end
@implementation NSDateOverrider

static NSTimeInterval timeOffset;

+ (void)load {
    injectToProperClass(@selector(overrideTimeIntervalSince1970), @selector(timeIntervalSince1970), @[], [NSDateOverrider class], [NSDate class]);
}

- (NSTimeInterval) overrideTimeIntervalSince1970 {
    NSTimeInterval current = [self overrideTimeIntervalSince1970];
    return current + timeOffset;
}

@end


@interface NSBundleOverrider : NSObject
@end
@implementation NSBundleOverrider

static NSDictionary* nsbundleDictionary;

+ (void)load {
    [NSBundleOverrider sizzleBundleIdentifier];
    
    injectToProperClass(@selector(overrideObjectForInfoDictionaryKey:), @selector(objectForInfoDictionaryKey:), @[], [NSBundleOverrider class], [NSBundle class]);
    
    // Doesn't work to swizzle for mocking. Both an NSDictionary and NSMutableDictionarys both throw odd selecotor not found errors.
    // injectToProperClass(@selector(overrideInfoDictionary), @selector(infoDictionary), @[], [NSBundleOverrider class], [NSBundle class]);
}

+ (void)sizzleBundleIdentifier {
    injectToProperClass(@selector(overrideBundleIdentifier), @selector(bundleIdentifier), @[], [NSBundleOverrider class], [NSBundle class]);
}

- (NSString*)overrideBundleIdentifier {
    return @"com.onesignal.unittest";
}

- (nullable id)overrideObjectForInfoDictionaryKey:(NSString*)key {
    return nsbundleDictionary[key];
}

@end


static int notifTypesOverride = 7;


@interface UNUserNotificationCenterOverrider : NSObject
@end
@implementation UNUserNotificationCenterOverrider

static NSNumber *authorizationStatus;
static NSSet<UNNotificationCategory *>* lastSetCategories;

static dispatch_queue_t serialQueue;

static int getNotificationSettingsWithCompletionHandlerStackCount;

+ (void)load {
    getNotificationSettingsWithCompletionHandlerStackCount =  0;
    
    serialQueue = dispatch_queue_create("com.UNNotificationCenter", DISPATCH_QUEUE_SERIAL);
    
    injectToProperClass(@selector(overrideInitWithBundleIdentifier:),
                        @selector(initWithBundleIdentifier:), @[],
                        [UNUserNotificationCenterOverrider class], [UNUserNotificationCenter class]);
    injectToProperClass(@selector(overrideGetNotificationSettingsWithCompletionHandler:),
                        @selector(getNotificationSettingsWithCompletionHandler:), @[],
                        [UNUserNotificationCenterOverrider class], [UNUserNotificationCenter class]);
    injectToProperClass(@selector(overrideSetNotificationCategories:),
                        @selector(setNotificationCategories:), @[],
                        [UNUserNotificationCenterOverrider class], [UNUserNotificationCenter class]);
    injectToProperClass(@selector(overrideGetNotificationCategoriesWithCompletionHandler:),
                        @selector(getNotificationCategoriesWithCompletionHandler:), @[],
                        [UNUserNotificationCenterOverrider class], [UNUserNotificationCenter class]);
    injectToProperClass(@selector(overrideRequestAuthorizationWithOptions:completionHandler:),
                        @selector(requestAuthorizationWithOptions:completionHandler:), @[],
                        [UNUserNotificationCenterOverrider class], [UNUserNotificationCenter class]);
}

- (id) overrideInitWithBundleIdentifier:(NSString*) bundle {
    return self;
}

- (void)overrideGetNotificationSettingsWithCompletionHandler:(void(^)(id settings))completionHandler {
    getNotificationSettingsWithCompletionHandlerStackCount++;
    
    id retSettings = [UNNotificationSettings alloc];
    [retSettings setValue:authorizationStatus forKeyPath:@"authorizationStatus"];
    
    if (notifTypesOverride >= 7) {
        [retSettings setValue:[NSNumber numberWithInt:UNNotificationSettingEnabled] forKeyPath:@"badgeSetting"];
        [retSettings setValue:[NSNumber numberWithInt:UNNotificationSettingEnabled] forKeyPath:@"soundSetting"];
        [retSettings setValue:[NSNumber numberWithInt:UNNotificationSettingEnabled] forKeyPath:@"alertSetting"];
        [retSettings setValue:[NSNumber numberWithInt:UNNotificationSettingEnabled] forKeyPath:@"lockScreenSetting"];
    }
    
    // Simulates running on a sequential serial queue like iOS does.
    dispatch_async(serialQueue, ^{
        //if (getNotificationSettingsWithCompletionHandlerStackCount > 1)
        //    _XCTPrimitiveFail(currentTestInstance);
        //[NSThread sleepForTimeInterval:0.01];
        completionHandler(retSettings);
        getNotificationSettingsWithCompletionHandlerStackCount--;
    });
}

- (void)overrideSetNotificationCategories:(NSSet<UNNotificationCategory *> *)categories {
    lastSetCategories = categories;
}

- (void)overrideGetNotificationCategoriesWithCompletionHandler:(void(^)(NSSet<id> *categories))completionHandler {
    completionHandler(lastSetCategories);
}

- (void)overrideRequestAuthorizationWithOptions:(UNAuthorizationOptions)options
                              completionHandler:(void (^)(BOOL granted, NSError *error))completionHandler {
    if (authorizationStatus != [NSNumber numberWithInteger:UNAuthorizationStatusNotDetermined])
        completionHandler(authorizationStatus == [NSNumber numberWithInteger:UNAuthorizationStatusAuthorized], nil);
}

@end

@interface UIApplicationOverrider : NSObject
@end
@implementation UIApplicationOverrider

static BOOL calledRegisterForRemoteNotifications;
static BOOL calledCurrentUserNotificationSettings;

static NSInteger didFailRegistarationErrorCode;
static BOOL shouldFireDeviceToken;

+ (void)load {
    injectToProperClass(@selector(overrideRegisterForRemoteNotifications), @selector(registerForRemoteNotifications), @[], [UIApplicationOverrider class], [UIApplication class]);
    injectToProperClass(@selector(override_run), @selector(_run), @[], [UIApplicationOverrider class], [UIApplication class]);
    injectToProperClass(@selector(overrideCurrentUserNotificationSettings), @selector(currentUserNotificationSettings), @[], [UIApplicationOverrider class], [UIApplication class]);
    injectToProperClass(@selector(overrideRegisterForRemoteNotificationTypes:), @selector(registerForRemoteNotificationTypes:), @[], [UIApplicationOverrider class], [UIApplication class]);
    injectToProperClass(@selector(overrideRegisterUserNotificationSettings:), @selector(registerUserNotificationSettings:), @[], [UIApplicationOverrider class], [UIApplication class]);
}

// Keeps UIApplicationMain(...) from looping to continue to the next line.
- (void) override_run {
    NSLog(@"override_run!!!!!!");
}

+ (void) helperCallDidRegisterForRemoteNotificationsWithDeviceToken {
    id app = [UIApplication sharedApplication];
    id appDelegate = [[UIApplication sharedApplication] delegate];
    
    if (didFailRegistarationErrorCode) {
        id error = [NSError errorWithDomain:@"any" code:didFailRegistarationErrorCode userInfo:nil];
        [appDelegate application:app didFailToRegisterForRemoteNotificationsWithError:error];
        return;
    }
    
    if (!shouldFireDeviceToken)
        return;
    
    
    char bytes[32];
    memset(bytes, 0, 32);
    
    id deviceToken = [NSData dataWithBytes:bytes length:32];
    [appDelegate application:app didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];

}

// Called on iOS 8+
- (void) overrideRegisterForRemoteNotifications {
    calledRegisterForRemoteNotifications = true;
    [UIApplicationOverrider helperCallDidRegisterForRemoteNotificationsWithDeviceToken];
}

// iOS 7
- (void)overrideRegisterForRemoteNotificationTypes:(UIRemoteNotificationType)types {
   [UIApplicationOverrider helperCallDidRegisterForRemoteNotificationsWithDeviceToken];
}


// iOS 8 & 9 Only
- (UIUserNotificationSettings*) overrideCurrentUserNotificationSettings {
    calledCurrentUserNotificationSettings = true;
    
    // Check for this as it will create thread locks on a real device.
    if (getNotificationSettingsWithCompletionHandlerStackCount > 0)
        _XCTPrimitiveFail(currentTestInstance);
    
    return [UIUserNotificationSettings settingsForTypes:notifTypesOverride categories:nil];
}

// KEEP - Used to prevent xctest from fowarding to the iOS 10 equivalent.
- (void)overrideRegisterUserNotificationSettings:(UIUserNotificationSettings *)notificationSettings {
}

@end

@interface OneSignalHelperOverrider : NSObject
@end
@implementation OneSignalHelperOverrider

static NSString* lastUrl;
static NSDictionary* lastHTTPRequset;
static int networkRequestCount;

static dispatch_queue_t serialMockMainLooper;

static float mockIOSVersion;

+ (void)load {
    serialMockMainLooper = dispatch_queue_create("com.onesignal.unittest", DISPATCH_QUEUE_SERIAL);
    
    injectStaticSelector([OneSignalHelperOverrider class], @selector(overrideEnqueueRequest:onSuccess:onFailure:isSynchronous:), [OneSignalHelper class], @selector(enqueueRequest:onSuccess:onFailure:isSynchronous:));
    injectStaticSelector([OneSignalHelperOverrider class], @selector(overrideGetAppName), [OneSignalHelper class], @selector(getAppName));
    injectStaticSelector([OneSignalHelperOverrider class], @selector(overrideIsIOSVersionGreaterOrEqual:), [OneSignalHelper class], @selector(isIOSVersionGreaterOrEqual:));
    injectStaticSelector([OneSignalHelperOverrider class], @selector(overrideDispatch_async_on_main_queue:), [OneSignalHelper class], @selector(dispatch_async_on_main_queue:));
}

+ (NSString*) overrideGetAppName {
    return @"App Name";
}

+ (void)overrideEnqueueRequest:(NSURLRequest*)request onSuccess:(OSResultSuccessBlock)successBlock onFailure:(OSFailureBlock)failureBlock isSynchronous:(BOOL)isSynchronous {
    networkRequestCount++;
    
    NSError *error = nil;
    id url = [request URL];
    NSDictionary *parameters = [NSJSONSerialization JSONObjectWithData:[request HTTPBody] options:0 error:&error];
    NSLog(@"url: %@", url);
    NSLog(@"parameters: %@", parameters);
    
    lastUrl = [url absoluteString];
    lastHTTPRequset = parameters;
    
    if (successBlock)
        successBlock(@{@"id": @"1234"});
}

+ (BOOL)overrideIsIOSVersionGreaterOrEqual:(float)version {
   return mockIOSVersion >= version;
}

+ (void) overrideDispatch_async_on_main_queue:(void(^)())block {
    dispatch_async(serialMockMainLooper, block);
}

@end



@interface AppDelegate : UIResponder <UIApplicationDelegate, UNUserNotificationCenterDelegate>
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
    
    return true;
}

@end

@interface NSLocaleOverrider : NSObject
@end

@implementation NSLocaleOverrider

static NSArray* preferredLanguagesArray;

+ (void)load {
    injectStaticSelector([NSLocaleOverrider class], @selector(overriderPreferredLanguages), [NSLocale class], @selector(preferredLanguages));
}

+ (NSArray<NSString*> *) overriderPreferredLanguages {
    return preferredLanguagesArray;
}

@end




// END - Selector Shadowing



@interface UnitTests : XCTestCase
@end


static BOOL setupUIApplicationDelegate = false;

@implementation UnitTests

// Called before each test.
- (void)setUp {
    [super setUp];
    
    currentTestInstance = self;
    
    mockIOSVersion = 10;
    
    timeOffset = 0;
    networkRequestCount = 0;
    lastUrl = nil;
    lastHTTPRequset = nil;
    
    lastSetCategories = nil;
    
    preferredLanguagesArray = @[@"en-US"];
    
    [OneSignalHelper performSelector:NSSelectorFromString(@"resetLocals")];
    
    
    [OneSignal setValue:nil forKeyPath:@"lastAppActiveMessageId"];
    [OneSignal setValue:nil forKeyPath:@"lastnonActiveMessageId"];
    [OneSignal setValue:@0 forKeyPath:@"mSubscriptionStatus"];
    
    [OneSignalTracker performSelector:NSSelectorFromString(@"resetLocals")];
    
    notifTypesOverride = 7;
    authorizationStatus = [NSNumber numberWithInteger:UNAuthorizationStatusAuthorized];
    
    shouldFireDeviceToken = true;
    calledRegisterForRemoteNotifications = false;
    calledCurrentUserNotificationSettings = false;
    didFailRegistarationErrorCode = 0;
    nsbundleDictionary = @{@"UIBackgroundModes": @[@"remote-notification"]};
    
    instantRunPerformSelectorAfterDelay = false;
    selectorNamesForInstantOnlyForFirstRun = [@[] mutableCopy];
    selectorsToRun = [[NSMutableArray alloc] init];
    
    [OneSignal performSelector:NSSelectorFromString(@"clearStatics")];
    
    [NSUserDefaultsOverrider clearInternalDictionary];
    
    [OneSignal setLogLevel:ONE_S_LL_VERBOSE visualLevel:ONE_S_LL_NONE];
    
    if (!setupUIApplicationDelegate) {
        // Normally this just loops internally, overwrote _run to work around this.
        UIApplicationMain(0, nil, nil, NSStringFromClass([AppDelegate class]));
        setupUIApplicationDelegate = true;
      // InstallUncaughtExceptionHandler();
    }
    
    // Uncomment to simulate slow travis-CI runs.
    /*float minRange = 0, maxRange = 15;
    float random = ((float)arc4random() / 0x100000000 * (maxRange - minRange)) + minRange;
    NSLog(@"Sleeping for debugging: %f", random);
    [NSThread sleepForTimeInterval:random];*/
}

// Called after each test.
- (void)tearDown {
    [super tearDown];
    [self runBackgroundThreads];
}

- (void)backgroundModesDisabledInXcode {
    nsbundleDictionary = @{};
}

- (void)setCurrentNotificationPermissionAsUnanwsered {
    notifTypesOverride = 0;
    authorizationStatus = [NSNumber numberWithInteger:UNAuthorizationStatusNotDetermined];
}

- (void)setCurrentNotificationPermission:(BOOL)accepted {
    if (accepted) {
        notifTypesOverride = 7;
        authorizationStatus = [NSNumber numberWithInteger:UNAuthorizationStatusAuthorized];
    }
    else {
        notifTypesOverride = 0;
        authorizationStatus = [NSNumber numberWithInteger:UNAuthorizationStatusDenied];
    }
}

- (void)anwserNotifiationPrompt:(BOOL)accept {
    [self setCurrentNotificationPermission:accept];
    
    UIApplication *sharedApp = [UIApplication sharedApplication];
    [sharedApp.delegate application:sharedApp didRegisterUserNotificationSettings:[UIUserNotificationSettings settingsForTypes:notifTypesOverride categories:nil]];
}

- (void)backgroundApp {
    UIApplication *sharedApp = [UIApplication sharedApplication];
    [sharedApp.delegate applicationWillResignActive:sharedApp];
}

- (void)resumeApp {
    UIApplication *sharedApp = [UIApplication sharedApplication];
    [sharedApp.delegate applicationDidBecomeActive:sharedApp];
}

// Runs any blocks passed to dispatch_async()
- (void)runBackgroundThreads {

    NSLog(@"START runBackgroundThreads");
    
    dispatch_queue_t registerUserQueue;
    for(int i = 0; i < 2; i++) {
        dispatch_sync(serialMockMainLooper, ^{});
        
        registerUserQueue = [OneSignal getRegisterQueue];
        if (registerUserQueue) {
            dispatch_sync(registerUserQueue, ^{});
        }
        
        dispatch_barrier_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{});
    }
    
    NSLog(@"END runBackgroundThreads");
}


- (UNNotificationResponse*)createBasiciOSNotificationResponseWithPayload:(NSDictionary*)userInfo {
    // Mocking an iOS 10 notification
    // Setting response.notification.request.content.userInfo
    UNNotificationResponse *notifResponse = [UNNotificationResponse alloc];
    
    // Normal tap on notification
    [notifResponse setValue:@"com.apple.UNNotificationDefaultActionIdentifier" forKeyPath:@"actionIdentifier"];
    
    UNNotificationContent *unNotifContent = [UNNotificationContent alloc];
    UNNotification *unNotif = [UNNotification alloc];
    UNNotificationRequest *unNotifRequqest = [UNNotificationRequest alloc];
    // Set as remote push type
    [unNotifRequqest setValue:[UNPushNotificationTrigger alloc] forKey:@"trigger"];
    
    [unNotif setValue:unNotifRequqest forKeyPath:@"request"];
    [notifResponse setValue:unNotif forKeyPath:@"notification"];
    [unNotifRequqest setValue:unNotifContent forKeyPath:@"content"];
    [unNotifContent setValue:userInfo forKey:@"userInfo"];
    
    return notifResponse;
}
                                                                          
- (UNNotificationResponse*)createBasiciOSNotificationResponse {
  id userInfo = @{@"custom":
                      @{@"i": @"b2f7f966-d8cc-11e4-bed1-df8f05be55bb"}
                  };
  
  return [self createBasiciOSNotificationResponseWithPayload:userInfo];
}

// Helper used to simpify tests below.
- (void)initOneSignal {
    [OneSignal initWithLaunchOptions:nil appId:@"b2f7f966-d8cc-11e4-bed1-df8f05be55ba"];
    
    // iOS fires the resume event when app is cold started.
    [self resumeApp];
}

- (void)testBasicInitTest {
    NSLog(@"iOS VERSION: %@", [[UIDevice currentDevice] systemVersion]);
    
    [self initOneSignal];
    [self runBackgroundThreads];
    
    XCTAssertEqualObjects(lastHTTPRequset[@"app_id"], @"b2f7f966-d8cc-11e4-bed1-df8f05be55ba");
    XCTAssertEqualObjects(lastHTTPRequset[@"identifier"], @"0000000000000000000000000000000000000000000000000000000000000000");
    XCTAssertEqualObjects(lastHTTPRequset[@"notification_types"], @15);
    XCTAssertEqualObjects(lastHTTPRequset[@"device_model"], @"x86_64");
    XCTAssertEqualObjects(lastHTTPRequset[@"device_type"], @0);
    XCTAssertEqualObjects(lastHTTPRequset[@"language"], @"en-US");
    
    // 2nd init call should not fire another on_session call.
    lastHTTPRequset = nil;
    [OneSignal initWithLaunchOptions:nil appId:@"b2f7f966-d8cc-11e4-bed1-df8f05be55ba"];
    XCTAssertNil(lastHTTPRequset);
    
    XCTAssertEqual(networkRequestCount, 1);
}

- (void)testRegisterationOniOS7 {
    mockIOSVersion = 7;
    
    [self initOneSignal];
    [self runBackgroundThreads];
    
    XCTAssertEqualObjects(lastHTTPRequset[@"app_id"], @"b2f7f966-d8cc-11e4-bed1-df8f05be55ba");
    XCTAssertEqualObjects(lastHTTPRequset[@"identifier"], @"0000000000000000000000000000000000000000000000000000000000000000");
    XCTAssertEqualObjects(lastHTTPRequset[@"notification_types"], @7);
    XCTAssertEqualObjects(lastHTTPRequset[@"device_model"], @"x86_64");
    XCTAssertEqualObjects(lastHTTPRequset[@"device_type"], @0);
    XCTAssertEqualObjects(lastHTTPRequset[@"language"], @"en-US");
    
    // 2nd init call should not fire another on_session call.
    lastHTTPRequset = nil;
    [OneSignal initWithLaunchOptions:nil appId:@"b2f7f966-d8cc-11e4-bed1-df8f05be55ba"];
    XCTAssertNil(lastHTTPRequset);
    
    XCTAssertEqual(networkRequestCount, 1);
    
    // Make the following methods were not called as they are not available on iOS 7
    XCTAssertFalse(calledRegisterForRemoteNotifications);
    XCTAssertFalse(calledCurrentUserNotificationSettings);
}

// Seen a few rare crash reports where [NSLocale preferredLanguages] resturns an empty array
- (void)testInitWithEmptyPreferredLanguages {
    preferredLanguagesArray = @[];
    [self initOneSignal];
    [self runBackgroundThreads];
}

- (void)testInitOnSimulator {
    [self setCurrentNotificationPermissionAsUnanwsered];
    [self backgroundModesDisabledInXcode];
    didFailRegistarationErrorCode = 3010;
    
    [self initOneSignal];
    [self runBackgroundThreads];
    [self anwserNotifiationPrompt:true];
    [self runBackgroundThreads];
    
    XCTAssertEqualObjects(lastHTTPRequset[@"app_id"], @"b2f7f966-d8cc-11e4-bed1-df8f05be55ba");
    XCTAssertNil(lastHTTPRequset[@"identifier"]);
    XCTAssertEqualObjects(lastHTTPRequset[@"notification_types"], @-15);
    XCTAssertEqualObjects(lastHTTPRequset[@"device_model"], @"x86_64");
    XCTAssertEqualObjects(lastHTTPRequset[@"device_type"], @0);
    XCTAssertEqualObjects(lastHTTPRequset[@"language"], @"en-US");
    
    // 2nd init call should not fire another on_session call.
    lastHTTPRequset = nil;
    [self initOneSignal];
    XCTAssertNil(lastHTTPRequset);
    
    XCTAssertEqual(networkRequestCount, 1);
}

- (void)testInitAcceptingNotificationsWithoutCapabilitesSet {
    [self backgroundModesDisabledInXcode];
    didFailRegistarationErrorCode = 3000;
    [self setCurrentNotificationPermissionAsUnanwsered];
    
    [self initOneSignal];
    XCTAssertNil(lastHTTPRequset);
    
    [self anwserNotifiationPrompt:true];
    [self runBackgroundThreads];
    XCTAssertEqualObjects(lastHTTPRequset[@"app_id"], @"b2f7f966-d8cc-11e4-bed1-df8f05be55ba");
    XCTAssertEqualObjects(lastHTTPRequset[@"notification_types"], @-13);
    XCTAssertEqual(networkRequestCount, 1);
}

- (void)testPromptedButNeverAnwserNotificationPrompt {
    [self setCurrentNotificationPermissionAsUnanwsered];
    
    [self initOneSignal];
    
    // Don't make a network call right away.
    XCTAssertNil(lastHTTPRequset);
    
    // Triggers the 30 fallback to register device right away.
    [OneSignal performSelector:NSSelectorFromString(@"registerUser")];
    [self runBackgroundThreads];
    
    XCTAssertEqualObjects(lastHTTPRequset[@"app_id"], @"b2f7f966-d8cc-11e4-bed1-df8f05be55ba");
    XCTAssertEqualObjects(lastHTTPRequset[@"notification_types"], @-19);
}

- (void)testNotificationTypesWhenAlreadyAcceptedWithAutoPromptOffOnFristStartPreIos10 {
    mockIOSVersion = 8;
    
    [OneSignal initWithLaunchOptions:nil appId:@"b2f7f966-d8cc-11e4-bed1-df8f05be55ba"
            handleNotificationAction:nil
                            settings:@{kOSSettingsKeyAutoPrompt: @false}];
    
    [self runBackgroundThreads];
    
    XCTAssertEqualObjects(lastHTTPRequset[@"notification_types"], @7);
}


- (void)testNeverPromptedStatus {
    [self setCurrentNotificationPermissionAsUnanwsered];
    
    [OneSignal initWithLaunchOptions:nil appId:@"b2f7f966-d8cc-11e4-bed1-df8f05be55ba"
            handleNotificationAction:nil
                            settings:@{kOSSettingsKeyAutoPrompt: @false}];
    
    [self runBackgroundThreads];
    // Triggers the 30 fallback to register device right away.
    [NSObjectOverrider runPendingSelectors];
    [self runBackgroundThreads];
    
    XCTAssertEqualObjects(lastHTTPRequset[@"app_id"], @"b2f7f966-d8cc-11e4-bed1-df8f05be55ba");
    XCTAssertEqualObjects(lastHTTPRequset[@"notification_types"], @-18);
}

- (void)testNotAcceptingNotificationsWithoutBackgroundModes {
    [self setCurrentNotificationPermissionAsUnanwsered];
    [self backgroundModesDisabledInXcode];
    
    [self initOneSignal];
    
    // Don't make a network call right away.
    XCTAssertNil(lastHTTPRequset);
    
    [self anwserNotifiationPrompt:false];
    [self runBackgroundThreads];
    
    XCTAssertEqualObjects(lastUrl, @"https://onesignal.com/api/v1/players");
    XCTAssertEqualObjects(lastHTTPRequset[@"app_id"], @"b2f7f966-d8cc-11e4-bed1-df8f05be55ba");
    XCTAssertNil(lastHTTPRequset[@"identifier"]);
    XCTAssertEqualObjects(lastHTTPRequset[@"notification_types"], @0);
}

- (void)testIdsAvailableNotAcceptingNotifications {
    notifTypesOverride = 0;
    [OneSignal initWithLaunchOptions:nil appId:@"b2f7f966-d8cc-11e4-bed1-df8f05be55ba"
            handleNotificationAction:nil
                            settings:@{kOSSettingsKeyAutoPrompt: @false}];
    
    __block BOOL idsAvailable1Called = false;
    [OneSignal IdsAvailable:^(NSString *userId, NSString *pushToken) {
        idsAvailable1Called = true;
    }];
    
    [self runBackgroundThreads];
    
    [OneSignal registerForPushNotifications];
    
    [self anwserNotifiationPrompt:false];
    
    [self runBackgroundThreads];
    XCTAssertTrue(idsAvailable1Called);
    
    
    [OneSignal initWithLaunchOptions:nil appId:@"b2f7f966-d8cc-11e4-bed1-df8f05be55ba"
            handleNotificationAction:nil
                            settings:@{kOSSettingsKeyAutoPrompt: @false}];
    
    __block BOOL idsAvailable2Called = false;
    [OneSignal IdsAvailable:^(NSString *userId, NSString *pushToken) {
        idsAvailable2Called = true;
    }];
    
    [self runBackgroundThreads];
    XCTAssertTrue(idsAvailable2Called);
}

// Tests that a normal notification opened on iOS 10 triggers the handleNotificationAction.
- (void)testNotificationOpen {
    __block BOOL openedWasFire = false;
    
    [OneSignal initWithLaunchOptions:nil appId:@"b2f7f966-d8cc-11e4-bed1-df8f05be55ba" handleNotificationAction:^(OSNotificationOpenedResult *result) {
        XCTAssertNil(result.notification.payload.additionalData);
        XCTAssertEqual(result.action.type, OSNotificationActionTypeOpened);
        XCTAssertNil(result.action.actionID);
        openedWasFire = true;
    }];
    [self runBackgroundThreads];
    
    id notifResponse = [self createBasiciOSNotificationResponse];
    UNUserNotificationCenter *notifCenter = [UNUserNotificationCenter currentNotificationCenter];
    id notifCenterDelegate = notifCenter.delegate;
    // UNUserNotificationCenterDelegate method iOS 10 calls directly when a notification is opened.
    [notifCenterDelegate userNotificationCenter:notifCenter didReceiveNotificationResponse:notifResponse withCompletionHandler:^() {}];
    
    // Make sure open tracking network call was made.
    XCTAssertEqual(openedWasFire, true);
    XCTAssertEqualObjects(lastUrl, @"https://onesignal.com/api/v1/notifications/b2f7f966-d8cc-11e4-bed1-df8f05be55bb");
    XCTAssertEqualObjects(lastHTTPRequset[@"app_id"], @"b2f7f966-d8cc-11e4-bed1-df8f05be55ba");
    XCTAssertEqualObjects(lastHTTPRequset[@"opened"], @1);
    
    // Make sure if the device recieved a duplicate we don't fire the open network call again.
    lastUrl = nil;
    lastHTTPRequset = nil;
    [notifCenterDelegate userNotificationCenter:notifCenter didReceiveNotificationResponse:notifResponse withCompletionHandler:^() {}];
    
    XCTAssertNil(lastUrl);
    XCTAssertNil(lastHTTPRequset);
    XCTAssertEqual(networkRequestCount, 2);
}

// Testing iOS 10 - old pre-2.4.0 button fromat - with original aps payload format
- (void)testNotificationOpenFromButtonPress {
    __block BOOL openedWasFire = false;
    
    [OneSignal initWithLaunchOptions:nil appId:@"b2f7f966-d8cc-11e4-bed1-df8f05be55ba" handleNotificationAction:^(OSNotificationOpenedResult *result) {
        XCTAssertEqualObjects(result.notification.payload.additionalData[@"actionSelected"], @"id1");
        XCTAssertEqual(result.action.type, OSNotificationActionTypeActionTaken);
        XCTAssertEqualObjects(result.action.actionID, @"id1");
        openedWasFire = true;
    }];
    [self runBackgroundThreads];
    
    id userInfo = @{@"aps": @{@"content_available": @1},
                    @"m": @"alert body only",
                    @"o": @[@{@"i": @"id1", @"n": @"text1"}],
                    @"custom": @{
                                @"i": @"b2f7f966-d8cc-11e4-bed1-df8f05be55bb"
                            }
                    };
    
    id notifResponse = [self createBasiciOSNotificationResponseWithPayload:userInfo];
    [notifResponse setValue:@"id1" forKeyPath:@"actionIdentifier"];
    
    UNUserNotificationCenter *notifCenter = [UNUserNotificationCenter currentNotificationCenter];
    id notifCenterDelegate = notifCenter.delegate;
    
    // UNUserNotificationCenterDelegate method iOS 10 calls directly when a notification is opened.
    [notifCenterDelegate userNotificationCenter:notifCenter didReceiveNotificationResponse:notifResponse withCompletionHandler:^() {}];
    
    // Make sure open tracking network call was made.
    XCTAssertEqual(openedWasFire, true);
    XCTAssertEqualObjects(lastUrl, @"https://onesignal.com/api/v1/notifications/b2f7f966-d8cc-11e4-bed1-df8f05be55bb");
    XCTAssertEqualObjects(lastHTTPRequset[@"app_id"], @"b2f7f966-d8cc-11e4-bed1-df8f05be55ba");
    XCTAssertEqualObjects(lastHTTPRequset[@"opened"], @1);
    
    // Make sure if the device recieved a duplicate we don't fire the open network call again.
    lastUrl = nil;
    lastHTTPRequset = nil;
    [notifCenterDelegate userNotificationCenter:notifCenter didReceiveNotificationResponse:notifResponse withCompletionHandler:^() {}];
    
    XCTAssertNil(lastUrl);
    XCTAssertNil(lastHTTPRequset);
    XCTAssertEqual(networkRequestCount, 2);
}


// Testing iOS 10 - 2.4.0+ button fromat - with os_data aps payload format
- (void)testNotificationOpenFromButtonPressWithNewformat {
    __block BOOL openedWasFire = false;
    
    [OneSignal initWithLaunchOptions:nil appId:@"b2f7f966-d8cc-11e4-bed1-df8f05be55ba" handleNotificationAction:^(OSNotificationOpenedResult *result) {
        XCTAssertEqualObjects(result.notification.payload.additionalData[@"actionSelected"], @"id1");
        XCTAssertEqual(result.action.type, OSNotificationActionTypeActionTaken);
        XCTAssertEqualObjects(result.action.actionID, @"id1");
        openedWasFire = true;
    }];
    [self runBackgroundThreads];
    
    id userInfo = @{@"aps": @{
                        @"mutable-content": @1,
                        @"alert": @"Message Body"
                    },
                    @"os_data": @{
                        @"i": @"b2f7f966-d8cc-11e4-bed1-df8f05be55bb",
                        @"buttons": @[@{@"i": @"id1", @"n": @"text1"}],
                    }};
    
    id notifResponse = [self createBasiciOSNotificationResponseWithPayload:userInfo];
    [notifResponse setValue:@"id1" forKeyPath:@"actionIdentifier"];
    
    UNUserNotificationCenter *notifCenter = [UNUserNotificationCenter currentNotificationCenter];
    id notifCenterDelegate = notifCenter.delegate;
    
    // UNUserNotificationCenterDelegate method iOS 10 calls directly when a notification is opened.
    [notifCenterDelegate userNotificationCenter:notifCenter didReceiveNotificationResponse:notifResponse withCompletionHandler:^() {}];
    
    // Make sure open tracking network call was made.
    XCTAssertEqual(openedWasFire, true);
    XCTAssertEqualObjects(lastUrl, @"https://onesignal.com/api/v1/notifications/b2f7f966-d8cc-11e4-bed1-df8f05be55bb");
    XCTAssertEqualObjects(lastHTTPRequset[@"app_id"], @"b2f7f966-d8cc-11e4-bed1-df8f05be55ba");
    XCTAssertEqualObjects(lastHTTPRequset[@"opened"], @1);
    
    // Make sure if the device recieved a duplicate we don't fire the open network call again.
    lastUrl = nil;
    lastHTTPRequset = nil;
    [notifCenterDelegate userNotificationCenter:notifCenter didReceiveNotificationResponse:notifResponse withCompletionHandler:^() {}];
    
    XCTAssertNil(lastUrl);
    XCTAssertNil(lastHTTPRequset);
    XCTAssertEqual(networkRequestCount, 2);
}


// Testing iOS 10 - with original aps payload format
- (void)testOpeningWithAdditionalData {
    __block BOOL openedWasFire = false;
    
    [OneSignal initWithLaunchOptions:nil appId:@"b2f7f966-d8cc-11e4-bed1-df8f05be55ba" handleNotificationAction:^(OSNotificationOpenedResult *result) {
        XCTAssertEqualObjects(result.notification.payload.additionalData[@"foo"], @"bar");
        XCTAssertEqual(result.action.type, OSNotificationActionTypeOpened);
        XCTAssertNil(result.action.actionID);
        openedWasFire = true;
    }];
    [self runBackgroundThreads];
    
    id userInfo = @{@"custom": @{
                      @"i": @"b2f7f966-d8cc-11e4-bed1-df8f05be55bb",
                      @"a": @{ @"foo": @"bar" }
                  }};
    
    id notifResponse = [self createBasiciOSNotificationResponseWithPayload:userInfo];
    UNUserNotificationCenter *notifCenter = [UNUserNotificationCenter currentNotificationCenter];
    id notifCenterDelegate = notifCenter.delegate;
    
    // UNUserNotificationCenterDelegate method iOS 10 calls directly when a notification is opend.
    [notifCenterDelegate userNotificationCenter:notifCenter didReceiveNotificationResponse:notifResponse withCompletionHandler:^() {}];
    XCTAssertEqual(openedWasFire, true);
    
    
    // Part 2 - New paylaod test
    // Current mocking isn't able to setup this test correctly.
    // In an app AppDelete selectors fire instead of UNUserNotificationCenter
    // SDK could also used some refactoring as this should't have an effect.
    /*
    openedWasFire = false;
    userInfo = @{@"alert": @"body",
                 @"os_data": @{
                         @"i": @"b2f7f966-d8cc-11e4-bed1-df8f05be55bc"
                         },
                 @"foo": @"bar"};
    notifResponse = [self createBasiciOSNotificationResponseWithPayload:userInfo];
    [notifCenterDelegate userNotificationCenter:notifCenter didReceiveNotificationResponse:notifResponse withCompletionHandler:^() {}];
    XCTAssertEqual(openedWasFire, true);
    */
}


// Testing iOS 10 - pre-2.4.0 button fromat - with os_data aps payload format
- (void)testRecievedCallbackWithButtons {
    __block BOOL recievedWasFire = false;
    
    [OneSignal initWithLaunchOptions:nil appId:@"b2f7f966-d8cc-11e4-bed1-df8f05be55ba" handleNotificationReceived:^(OSNotification *notification) {
        recievedWasFire = true;
        id actionButons = @[ @{@"id": @"id1", @"text": @"text1"} ];
        // TODO: Fix code so it don't use the shortened format.
        // XCTAssertEqualObjects(notification.payload.actionButtons, actionButons);
    } handleNotificationAction:nil settings:nil];
    [self runBackgroundThreads];
    
    id userInfo = @{@"aps": @{@"content_available": @1},
                    @"os_data": @{
                        @"i": @"b2f7f966-d8cc-11e4-bed1-df8f05be55bb",
                        @"buttons": @{
                            @"m": @"alert body only",
                            @"o": @[@{@"i": @"id1", @"n": @"text1"}]
                        }
                    }
                };
    
    id notifResponse = [self createBasiciOSNotificationResponseWithPayload:userInfo];
    UNUserNotificationCenter *notifCenter = [UNUserNotificationCenter currentNotificationCenter];
    id notifCenterDelegate = notifCenter.delegate;
    
    //iOS 10 calls  UNUserNotificationCenterDelegate method directly when a notification is received while the app is in focus.
    [notifCenterDelegate userNotificationCenter:notifCenter willPresentNotification:[notifResponse notification] withCompletionHandler:^(UNNotificationPresentationOptions options) {}];
    
    XCTAssertEqual(recievedWasFire, true);
}


- (void)testSendTags {
    [self initOneSignal];
    [self runBackgroundThreads];
    XCTAssertEqual(networkRequestCount, 1);
    
    // Simple test with a sendTag and sendTags call.
    [OneSignal sendTag:@"key" value:@"value"];
    [OneSignal sendTags:@{@"key1": @"value1", @"key2": @"value2"}];
    
    // Make sure all 3 sets of tags where send in 1 network call.
    [NSObjectOverrider runPendingSelectors];
    XCTAssertEqualObjects(lastHTTPRequset[@"tags"][@"key"], @"value");
    XCTAssertEqualObjects(lastHTTPRequset[@"tags"][@"key1"], @"value1");
    XCTAssertEqualObjects(lastHTTPRequset[@"tags"][@"key2"], @"value2");
    XCTAssertEqual(networkRequestCount, 2);
    
    
    // More advanced test with callbacks.
    __block BOOL didRunSuccess1, didRunSuccess2, didRunSuccess3;
    [OneSignal sendTag:@"key10" value:@"value10" onSuccess:^(NSDictionary *result) {
        didRunSuccess1 = true;
    } onFailure:^(NSError *error) {}];
    [OneSignal sendTags:@{@"key11": @"value11", @"key12": @"value12"} onSuccess:^(NSDictionary *result) {
        didRunSuccess2 = true;
    } onFailure:^(NSError *error) {}];
    
    instantRunPerformSelectorAfterDelay = true;
    [OneSignal sendTag:@"key13" value:@"value13" onSuccess:^(NSDictionary *result) {
        didRunSuccess3 = true;
    } onFailure:^(NSError *error) {}];
    
    [NSObjectOverrider runPendingSelectors];
    
    XCTAssertEqualObjects(lastHTTPRequset[@"tags"][@"key10"], @"value10");
    XCTAssertEqualObjects(lastHTTPRequset[@"tags"][@"key11"], @"value11");
    XCTAssertEqualObjects(lastHTTPRequset[@"tags"][@"key12"], @"value12");
    XCTAssertEqualObjects(lastHTTPRequset[@"tags"][@"key13"], @"value13");
    XCTAssertEqual(networkRequestCount, 3);
    
    XCTAssertEqual(didRunSuccess1, true);
    XCTAssertEqual(didRunSuccess2, true);
    XCTAssertEqual(didRunSuccess3, true);
}

- (void)testDeleteTags {
    [self initOneSignal];
    [self runBackgroundThreads];
    XCTAssertEqual(networkRequestCount, 1);
    
    // send 2 tags and delete 1 before they get sent off.
    [OneSignal sendTag:@"key" value:@"value"];
    [OneSignal sendTag:@"key2" value:@"value2"];
    [OneSignal deleteTag:@"key"];
    
    // Make sure only 1 network call is made and only key2 gets sent.
    [NSObjectOverrider runPendingSelectors];
    XCTAssertNil(lastHTTPRequset[@"tags"][@"key"]);
    XCTAssertEqualObjects(lastHTTPRequset[@"tags"][@"key2"], @"value2");
    XCTAssertEqual(networkRequestCount, 2);
}

- (void)testSendTagsBeforeRegisterComplete {
    [self setCurrentNotificationPermissionAsUnanwsered];
    
    [self initOneSignal];
    [self runBackgroundThreads];
    
    selectorNamesForInstantOnlyForFirstRun = [@[@"sendTagsToServer"] mutableCopy];
    
    [OneSignal sendTag:@"key" value:@"value"];
    [self runBackgroundThreads];
    
    // Do not try to send tag update yet as there isn't a player_id yet.
    XCTAssertEqual(networkRequestCount, 0);
    
    [self anwserNotifiationPrompt:false];
    [self runBackgroundThreads];
    
    // A single POST player create call should be made with tags included.
    XCTAssertEqual(networkRequestCount, 1);
    XCTAssertEqualObjects(lastHTTPRequset[@"tags"][@"key"], @"value");
    XCTAssertEqualObjects(lastHTTPRequset[@"notification_types"], @0);
    XCTAssertEqualObjects(lastHTTPRequset[@"identifier"], @"0000000000000000000000000000000000000000000000000000000000000000");
}

- (void)testFirstInitWithNotificationsAlreadyDeclined {
    [self backgroundModesDisabledInXcode];
    notifTypesOverride = 0;
    authorizationStatus = [NSNumber numberWithInteger:UNAuthorizationStatusDenied];
    
    [self initOneSignal];
    [self runBackgroundThreads];
    
    XCTAssertEqualObjects(lastHTTPRequset[@"notification_types"], @0);
    XCTAssertEqual(networkRequestCount, 1);
}

- (void)testPermissionChangedInSettingsOutsideOfApp {
    [self backgroundModesDisabledInXcode];
    notifTypesOverride = 0;
    authorizationStatus = [NSNumber numberWithInteger:UNAuthorizationStatusDenied];
    
    [self initOneSignal];
    [self runBackgroundThreads];
    
    XCTAssertEqualObjects(lastHTTPRequset[@"notification_types"], @0);
    XCTAssertNil(lastHTTPRequset[@"identifier"]);
    
    [self backgroundApp];
    [self setCurrentNotificationPermission:true];
    [self resumeApp];
    
    XCTAssertEqualObjects(lastHTTPRequset[@"notification_types"], @15);
    XCTAssertEqualObjects(lastHTTPRequset[@"identifier"], @"0000000000000000000000000000000000000000000000000000000000000000");
    XCTAssertEqual(networkRequestCount, 2);
}

- (void) testOnSessionWhenResuming {
    [self initOneSignal];
    [self runBackgroundThreads];
    
    // Don't make an on_session call if only out of the app for 20 secounds
    [self backgroundApp];
    timeOffset = 10;
    [self resumeApp];
    [self runBackgroundThreads];
    XCTAssertEqual(networkRequestCount, 1);
    
    // Anything over 30 secounds should count as a session.
    [self backgroundApp];
    timeOffset += 31;
    [self resumeApp];
    [self runBackgroundThreads];
    
    XCTAssertEqualObjects(lastUrl, @"https://onesignal.com/api/v1/players/1234/on_session");
    XCTAssertEqual(networkRequestCount, 2);
}

// iOS 10 - Notification Service Extension test
- (void) testDidReceiveNotificatioExtensionRequest {
    // Example of a pre-existing category a developer setup. + possibly an existing "__dynamic__" category of ours.
    id category = [NSClassFromString(@"UNNotificationCategory") categoryWithIdentifier:@"some_category" actions:@[] intentIdentifiers:@[] options:UNNotificationCategoryOptionCustomDismissAction];
    id category2 = [NSClassFromString(@"UNNotificationCategory") categoryWithIdentifier:@"__dynamic__" actions:@[] intentIdentifiers:@[] options:UNNotificationCategoryOptionCustomDismissAction];
    id category3 = [NSClassFromString(@"UNNotificationCategory") categoryWithIdentifier:@"some_category2" actions:@[] intentIdentifiers:@[] options:UNNotificationCategoryOptionCustomDismissAction];
    
    [[NSClassFromString(@"UNUserNotificationCenter") currentNotificationCenter] setNotificationCategories:[[NSMutableSet alloc] initWithArray:@[category, category2, category3]]];
    
    id userInfo = @{@"aps": @{
                        @"mutable-content": @1,
                        @"alert": @"Message Body"
                    },
                    @"os_data": @{
                        @"i": @"b2f7f966-d8cc-11e4-bed1-df8f05be55bb",
                        @"buttons": @[@{@"i": @"id1", @"n": @"text1"}],
                        @"att": @{ @"id": @"http://domain.com/file.jpg" }
                    }};
    
    id notifResponse = [self createBasiciOSNotificationResponseWithPayload:userInfo];
    
    UNMutableNotificationContent* content = [OneSignal didReceiveNotificationExtensionRequest:[notifResponse notification].request withMutableNotificationContent:nil];
    
    // Make sure butons were added.
    XCTAssertEqualObjects(content.categoryIdentifier, @"__dynamic__");
    // Make sure attachments were added.
    XCTAssertEqualObjects(content.attachments[0].identifier, @"id");
    XCTAssertEqualObjects(content.attachments[0].URL.scheme, @"file");
    
    
    // Run again with different buttons.
    userInfo = @{@"aps": @{
                         @"mutable-content": @1,
                         @"alert": @"Message Body"
                         },
                 @"os_data": @{
                         @"i": @"b2f7f966-d8cc-11e4-bed1-df8f05be55bb",
                         @"buttons": @[@{@"i": @"id2", @"n": @"text2"}],
                         @"att": @{ @"id": @"http://domain.com/file.jpg" }
                         }};
    
    notifResponse = [self createBasiciOSNotificationResponseWithPayload:userInfo];
    [OneSignal didReceiveNotificationExtensionRequest:[notifResponse notification].request withMutableNotificationContent:nil];
    
    XCTAssertEqual([lastSetCategories count], 3);
}

// iOS 10 - Notification Service Extension test
- (void) testDidReceiveNotificationExtensionRequestDontOverrideCateogory {
    
    
   /* void (*nullFunction)() = NULL;
    nullFunction(); */
    
    
    id userInfo = @{@"aps": @{
                            @"mutable-content": @1,
                            @"alert": @"Message Body"
                            },
                    @"os_data": @{
                            @"i": @"b2f7f966-d8cc-11e4-bed1-df8f05be55bb",
                            @"buttons": @[@{@"i": @"id1", @"n": @"text1"}],
                            @"att": @{ @"id": @"http://domain.com/file.jpg" }
                            }};
    
    id notifResponse = [self createBasiciOSNotificationResponseWithPayload:userInfo];
    
    [[notifResponse notification].request.content setValue:@"some_category" forKey:@"categoryIdentifier"];
    
    UNMutableNotificationContent* content = [OneSignal didReceiveNotificationExtensionRequest:[notifResponse notification].request withMutableNotificationContent:nil];
    
    // Make sure we didn't override an existing category
    XCTAssertEqualObjects(content.categoryIdentifier, @"some_category");
    // Make sure attachments were added.
    XCTAssertEqualObjects(content.attachments[0].identifier, @"id");
    XCTAssertEqualObjects(content.attachments[0].URL.scheme, @"file");
}

// iOS 10 - Notification Service Extension test
- (void) testServiceExtensionTimeWillExpireRequest {
    id userInfo = @{@"aps": @{
                        @"mutable-content": @1,
                        @"alert": @"Message Body"
                        },
                    @"os_data": @{
                        @"i": @"b2f7f966-d8cc-11e4-bed1-df8f05be55bb",
                        @"buttons": @[@{@"i": @"id1", @"n": @"text1"}],
                        @"att": @{ @"id": @"http://domain.com/file.jpg" }
                    }};
    
    id notifResponse = [self createBasiciOSNotificationResponseWithPayload:userInfo];
    
    UNMutableNotificationContent* content = [OneSignal serviceExtensionTimeWillExpireRequest:[notifResponse notification].request withMutableNotificationContent:nil];
    
    // Make sure butons were added.
    XCTAssertEqualObjects(content.categoryIdentifier, @"__dynamic__");
    // Make sure attachments were NOT added.
    //   We should not try to download attachemts as iOS is about to kill the extension and this will take to much time.
    XCTAssertNil(content.attachments);

}

@end
