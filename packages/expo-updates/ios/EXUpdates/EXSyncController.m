//  Copyright © 2019 650 Industries. All rights reserved.

#import <EXUpdates/EXSyncController.h>
#import <EXUpdates/EXSyncLauncher.h>
#import <EXUpdates/EXSyncLauncherNoDatabase.h>
#import <EXUpdates/EXSyncLauncherWithDatabase.h>
#import <EXUpdates/EXSyncReaper.h>
#import <EXUpdates/EXSyncSelectionPolicyFilterAware.h>
#import <EXUpdates/EXSyncUtils.h>

NS_ASSUME_NONNULL_BEGIN

static NSString * const EXSyncControllerErrorDomain = @"EXSyncController";

static NSString * const EXSyncConfigPlistName = @"Expo";

static NSString * const EXSyncManifestAvailableEventName = @"updateAvailable";
static NSString * const EXSyncNoManifestAvailableEventName = @"noUpdateAvailable";
static NSString * const EXSyncErrorEventName = @"error";

@interface EXSyncController ()

@property (nonatomic, readwrite, strong) EXSyncConfig *config;
@property (nonatomic, readwrite, strong) id<EXSyncLauncher> launcher;
@property (nonatomic, readwrite, strong) EXSyncDatabase *database;
@property (nonatomic, readwrite, strong) id<EXSyncSelectionPolicy> selectionPolicy;
@property (nonatomic, readwrite, strong) dispatch_queue_t assetFilesQueue;

@property (nonatomic, readwrite, strong) NSURL *updatesDirectory;

@property (nonatomic, strong) id<EXSyncLauncher> candidateLauncher;
@property (nonatomic, assign) BOOL hasLaunched;
@property (nonatomic, strong) dispatch_queue_t controllerQueue;

@property (nonatomic, assign) BOOL isStarted;
@property (nonatomic, assign) BOOL isEmergencyLaunch;

@end

@implementation EXSyncController

+ (instancetype)sharedInstance
{
  static EXSyncController *theController;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    if (!theController) {
      theController = [[EXSyncController alloc] init];
    }
  });
  return theController;
}

- (instancetype)init
{
  if (self = [super init]) {
    _config = [self _loadConfigFromExpoPlist];
    _database = [[EXSyncDatabase alloc] init];
    _selectionPolicy = [[EXSyncSelectionPolicyFilterAware alloc] initWithRuntimeVersion:[EXSyncUtils getRuntimeVersionWithConfig:_config]];
    _assetFilesQueue = dispatch_queue_create("expo.controller.AssetFilesQueue", DISPATCH_QUEUE_SERIAL);
    _controllerQueue = dispatch_queue_create("expo.controller.ControllerQueue", DISPATCH_QUEUE_SERIAL);
    _isStarted = NO;
  }
  return self;
}

- (void)setConfiguration:(NSDictionary *)configuration
{
  if (_updatesDirectory) {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"EXSyncController:setConfiguration should not be called after start"
                                 userInfo:@{}];
  }
  [_config loadConfigFromDictionary:configuration];
  _selectionPolicy = [[EXSyncSelectionPolicyFilterAware alloc] initWithRuntimeVersion:[EXSyncUtils getRuntimeVersionWithConfig:_config]];
}

- (void)start
{
  NSAssert(!_updatesDirectory, @"EXSyncController:start should only be called once per instance");

  if (!_config.isEnabled) {
    EXSyncLauncherNoDatabase *launcher = [[EXSyncLauncherNoDatabase alloc] init];
    _launcher = launcher;
    [launcher launchUpdateWithConfig:_config];

    if (_delegate) {
      [_delegate appController:self didStartWithSuccess:self.launchAssetUrl != nil];
    }

    return;
  }

  if (!_config.updateUrl) {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"expo-updates is enabled, but no valid URL is configured under EXSyncURL. If you are making a release build for the first time, make sure you have run `expo publish` at least once."
                                 userInfo:@{}];
  }

  _isStarted = YES;

  NSError *fsError;
  _updatesDirectory = [EXSyncUtils initializeUpdatesDirectoryWithError:&fsError];
  if (fsError) {
    [self _emergencyLaunchWithFatalError:fsError];
    return;
  }

  __block BOOL dbSuccess;
  __block NSError *dbError;
  dispatch_semaphore_t dbSemaphore = dispatch_semaphore_create(0);
  dispatch_async(_database.databaseQueue, ^{
    dbSuccess = [self->_database openDatabaseInDirectory:self->_updatesDirectory withError:&dbError];
    dispatch_semaphore_signal(dbSemaphore);
  });

  dispatch_semaphore_wait(dbSemaphore, DISPATCH_TIME_FOREVER);
  if (!dbSuccess) {
    [self _emergencyLaunchWithFatalError:dbError];
    return;
  }

  EXSyncLoaderTask *loaderTask = [[EXSyncLoaderTask alloc] initWithConfig:_config
                                                                             database:_database
                                                                            directory:_updatesDirectory
                                                                      selectionPolicy:_selectionPolicy
                                                                        delegateQueue:_controllerQueue];
  loaderTask.delegate = self;
  [loaderTask start];
}

- (void)startAndShowLaunchScreen:(UIWindow *)window
{
  NSBundle *mainBundle = [NSBundle mainBundle];
  UIViewController *rootViewController = [UIViewController new];
  NSString *launchScreen = (NSString *)[mainBundle objectForInfoDictionaryKey:@"UILaunchStoryboardName"] ?: @"LaunchScreen";
  
  if ([mainBundle pathForResource:launchScreen ofType:@"nib"] != nil) {
    NSArray *views = [mainBundle loadNibNamed:launchScreen owner:self options:nil];
    rootViewController.view = views.firstObject;
    rootViewController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  } else if ([mainBundle pathForResource:launchScreen ofType:@"storyboard"] != nil ||
             [mainBundle pathForResource:launchScreen ofType:@"storyboardc"] != nil) {
    UIStoryboard *launchScreenStoryboard = [UIStoryboard storyboardWithName:launchScreen bundle:nil];
    rootViewController = [launchScreenStoryboard instantiateInitialViewController];
  } else {
    NSLog(@"Launch screen could not be loaded from a .xib or .storyboard. Unexpected loading behavior may occur.");
    UIView *view = [UIView new];
    view.backgroundColor = [UIColor whiteColor];
    rootViewController.view = view;
  }
  
  window.rootViewController = rootViewController;
  [window makeKeyAndVisible];

  [self start];
}

- (void)requestRelaunchWithCompletion:(EXSyncRelaunchCompletionBlock)completion
{
  if (_bridge) {
    EXSyncLauncherWithDatabase *launcher = [[EXSyncLauncherWithDatabase alloc] initWithConfig:_config database:_database directory:_updatesDirectory completionQueue:_controllerQueue];
    _candidateLauncher = launcher;
    [launcher launchUpdateWithSelectionPolicy:self->_selectionPolicy completion:^(NSError * _Nullable error, BOOL success) {
      if (success) {
        self->_launcher = self->_candidateLauncher;
        completion(YES);
        [self->_bridge reload];
        [self _runReaper];
      } else {
        NSLog(@"Failed to relaunch: %@", error.localizedDescription);
        completion(NO);
      }
    }];
  } else {
    NSLog(@"EXSyncController: Failed to reload because bridge was nil. Did you set the bridge property on the controller singleton?");
    completion(NO);
  }
}

- (nullable EXSyncManifest *)launchedUpdate
{
  return _launcher.launchedUpdate ?: nil;
}

- (nullable NSURL *)launchAssetUrl
{
  return _launcher.launchAssetUrl ?: nil;
}

- (nullable NSDictionary *)assetFilesMap
{
  return _launcher.assetFilesMap ?: nil;
}

- (BOOL)isUsingEmbeddedAssets
{
  if (!_launcher) {
    return YES;
  }
  return _launcher.isUsingEmbeddedAssets;
}

# pragma mark - EXSyncLoaderTaskDelegate

- (BOOL)appLoaderTask:(EXSyncLoaderTask *)appLoaderTask didLoadCachedUpdate:(nonnull EXSyncManifest *)update
{
  return YES;
}

- (void)appLoaderTask:(EXSyncLoaderTask *)appLoaderTask didStartLoadingUpdate:(EXSyncManifest *)update
{
  // do nothing here for now
}

- (void)appLoaderTask:(EXSyncLoaderTask *)appLoaderTask didFinishWithLauncher:(id<EXSyncLauncher>)launcher isUpToDate:(BOOL)isUpToDate
{
  _launcher = launcher;
  if (self->_delegate) {
    [EXSyncUtils runBlockOnMainThread:^{
      [self->_delegate appController:self didStartWithSuccess:YES];
    }];
  }
}

- (void)appLoaderTask:(EXSyncLoaderTask *)appLoaderTask didFinishWithError:(NSError *)error
{
  [self _emergencyLaunchWithFatalError:error];
}

- (void)appLoaderTask:(EXSyncLoaderTask *)appLoaderTask didFinishBackgroundUpdateWithStatus:(EXSyncBackgroundManifestStatus)status update:(nullable EXSyncManifest *)update error:(nullable NSError *)error
{
  if (status == EXSyncBackgroundManifestStatusError) {
    NSAssert(error != nil, @"Background update with error status must have a nonnull error object");
    [EXSyncUtils sendEventToBridge:_bridge withType:EXSyncErrorEventName body:@{@"message": error.localizedDescription}];
  } else if (status == EXSyncBackgroundUpdateStatusManifestAvailable) {
    NSAssert(update != nil, @"Background update with error status must have a nonnull update object");
    [EXSyncUtils sendEventToBridge:_bridge withType:EXSyncManifestAvailableEventName body:@{@"manifest": update.rawManifest}];
  } else if (status == EXSyncBackgroundUpdateStatusNoManifestAvailable) {
    [EXSyncUtils sendEventToBridge:_bridge withType:EXSyncNoManifestAvailableEventName body:@{}];
  }
}

# pragma mark - internal

- (EXSyncConfig *)_loadConfigFromExpoPlist
{
  NSString *configPath = [[NSBundle mainBundle] pathForResource:EXSyncConfigPlistName ofType:@"plist"];
  if (!configPath) {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"Cannot load configuration from Expo.plist. Please ensure you've followed the setup and installation instructions for expo-updates to create Expo.plist and add it to your Xcode project."
                                 userInfo:@{}];
  }

  return [EXSyncConfig configWithDictionary:[NSDictionary dictionaryWithContentsOfFile:configPath]];
}

- (void)_runReaper
{
  if (_launcher.launchedUpdate) {
    [EXSyncReaper reapUnusedUpdatesWithConfig:_config
                                        database:_database
                                       directory:_updatesDirectory
                                 selectionPolicy:_selectionPolicy
                                  launchedUpdate:_launcher.launchedUpdate];
  }
}

- (void)_emergencyLaunchWithFatalError:(NSError *)error
{
  _isEmergencyLaunch = YES;

  EXSyncLauncherNoDatabase *launcher = [[EXSyncLauncherNoDatabase alloc] init];
  _launcher = launcher;
  [launcher launchUpdateWithConfig:_config fatalError:error];

  if (_delegate) {
    [EXSyncUtils runBlockOnMainThread:^{
      [self->_delegate appController:self didStartWithSuccess:self.launchAssetUrl != nil];
    }];
  }
}

@end

NS_ASSUME_NONNULL_END
