import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'package:flixquest/flixquest_main.dart';
import '../models/translation.dart';
import '../provider/app_dependency_provider.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
// import 'package:media_kit/media_kit.dart';
import 'constants/app_constants.dart';
import 'functions/function.dart';
import 'provider/bookmark_provider.dart';
import 'provider/recently_watched_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'provider/settings_provider.dart';
import 'provider/wellness_provider.dart';
import 'services/bookmark_sync_service.dart';
import 'services/recently_watched_sync_service.dart';
import 'services/media_link_navigation_service.dart';
import 'services/start_io_ads_service.dart';
import 'services/home_widget_navigation_service.dart';
import 'singleton/sharedpreferences_singleton.dart';
import 'tv/platform/device_presentation.dart';
import 'tv/platform/device_presentation_detector.dart';

@pragma('vm:entry-point')
Future<void> _messageHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {}
}

bool isTablet(BuildContext context) {
  double screenWidth = MediaQuery.of(context).size.width;
  double threshold = 1000.0;
  return screenWidth > threshold;
}

SettingsProvider settingsProvider = SettingsProvider();
RecentProvider recentProvider = RecentProvider();
BookmarkProvider bookmarkProvider = BookmarkProvider();
AppDependencyProvider appDependencyProvider = AppDependencyProvider();
// WellnessProvider moved to local to avoid top-level Firebase access.
bool _firebaseReady = false;
Future<void> _initFirebase() async {
  try {
    // Timeout after 5 seconds — if Firebase hangs (no network/play services),
    // don't block app startup.
    await Firebase.initializeApp().timeout(const Duration(seconds: 5));
    _firebaseReady = true;
  } catch (e) {
    // Try with dummy options so FirebaseAuth.instance etc. don't throw
    // during widget creation. The app won't use Firebase features.
    try {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: 'dummy',
          appId: 'dummy',
          messagingSenderId: 'dummy',
          projectId: 'dummy',
        ),
      ).timeout(const Duration(seconds: 5));
    } catch (e2) {
    }
  }
}

bool _isRecoverableImageError(FlutterErrorDetails details) {
  final context = details.context?.toString() ?? '';
  final stack = details.stack?.toString() ?? '';

  // cached_network_image reports failed downloads and evicted cache files
  // through Flutter's image error channel. These are expected per-image
  // failures and widgets already provide their own fallback content.
  return context.contains('resolving an image codec') ||
      context.contains('loading an image') ||
      stack.contains('MultiImageStreamCompleter');
}

Future<DevicePresentation> appInitialize({
  DevicePresentationDetector? devicePresentationDetector,
}) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Let Flutter paint behind Android's transparent gesture-navigation area.
  // Individual surfaces remain responsible for applying SafeArea padding to
  // interactive content.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // Firebase-dependent services and providers must not be accessed until the
  // default app has finished initializing. Wrapped so the app still launches
  // if Firebase config is missing/invalid (e.g. custom builds).
  await _initFirebase();

  // Surface uncaught Dart and platform errors to Crashlytics. Installed only
  // after Firebase initialization so the recorder is always ready.
  // Guarded: Crashlytics is only available if Firebase initialized successfully.
  FlutterError.onError = (details) {
    if (_isRecoverableImageError(details)) return;
    if (!_firebaseReady) return;
    try {
      FirebaseCrashlytics.instance.recordFlutterFatalError(details);
    } catch (_) {}
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    if (_firebaseReady) {
      try {
        FirebaseCrashlytics.instance.recordError(error, stackTrace, fatal: true);
      } catch (_) {}
    }
    return true;
  };

  // Skip MethodChannel on startup (may race with native handler registration).
  // Default to handheld; TV mode can be detected later if needed.
  final devicePresentation = DevicePresentation.handheld;

  // Initialize MediaKit for video playback with multiple codec support
  // MediaKit.ensureInitialized();

  // Reset orientation to all orientations on app start
  // This is CRITICAL for handling ungraceful app termination (force-close, system kill)
  // When the app is killed while streaming in landscape mode, this ensures
  // orientation is reset on next app launch since dispose() never gets called
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // ByteData data =
  //     await PlatformAssetBundle().load('assets/ca/lets-encrypt-r3.pem');
  // SecurityContext.defaultContext
  //     .setTrustedCertificatesBytes(data.buffer.asUint8List());
  await dotenv.load(fileName: '.env');
  await EasyLocalization.ensureInitialized();
  // Seed the shared version with the installed build so any synchronous reader
  // matches the binary instead of a hardcoded string that drifts.
  currentAppVersion = (await PackageInfo.fromPlatform()).version;
  sharedPrefsSingleton = await SharedPreferencesSingleton.getInstance();
  StartIoAdsService.instance
      .setTelevision(devicePresentation == DevicePresentation.television);
  try {
    await clearVideoPlaybackCache().timeout(const Duration(seconds: 10));
  } catch (_) {}
  // Guarded: requires Firebase to be initialized.
  if (_firebaseReady) {
    try {
      FirebaseMessaging.onBackgroundMessage(_messageHandler);
    } catch (_) {}
  }
  // Timeout: don't let downloader init hang startup.
  try {
    await FlutterDownloader.initialize(debug: true, ignoreSsl: true)
        .timeout(const Duration(seconds: 10));
  } catch (_) {}

  await settingsProvider.getCurrentThemeMode();
  await settingsProvider.getCurrentMaterial3Mode();
  // Timeout: Mixpanel init does network I/O, don't hang startup.
  try {
    await settingsProvider.initMixpanel().timeout(const Duration(seconds: 10));
  } catch (_) {}
  await settingsProvider.getCurrentAdultMode();
  await settingsProvider.getCurrentDefaultScreen();
  await settingsProvider.getCurrentImageQuality();
  await settingsProvider.getCurrentWatchCountry();
  await settingsProvider.getSeekDuration();
  await settingsProvider.getMaxBufferDuration();
  await settingsProvider.getVideoResolution();
  await settingsProvider.getSubtitleLanguage();
  await settingsProvider.getSubtitleMode();
  await settingsProvider.getViewMode();
  await settingsProvider.getSubtitleSize();
  await settingsProvider.getForegroundSubtitleColor();
  await settingsProvider.getBackgroundSubtitleColor();
  await settingsProvider.getAppLanguage();
  await settingsProvider.getAppColorIndex();
  await settingsProvider.getCustomAppColor();
  await settingsProvider.getStreamProviderOrder();
  await settingsProvider.getPlayerTimeStyle();
  await settingsProvider.getUseProxyMode();
  await settingsProvider.getSubtitleStyle();
  await settingsProvider.getEnableNextEpisodeButton();
  await settingsProvider.getIntroDbSettings();
  await settingsProvider.getPlayerAmbientGlowEnabled();
  await settingsProvider.getAutoLoadSources();
  settingsProvider.completeHydration();
  try {
    await recentProvider.fetchMovies().timeout(const Duration(seconds: 10));
  } catch (_) {}
  try {
    await recentProvider.fetchEpisodes().timeout(const Duration(seconds: 10));
  } catch (_) {}
  try {
    await bookmarkProvider.fetchBookmarks().timeout(const Duration(seconds: 10));
  } catch (_) {}
  try {
    final wp = WellnessProvider.instance;
    await wp.initialize().timeout(const Duration(seconds: 15));
  } catch (_) {}
  await appDependencyProvider.getFlixQuestLogo();
  await appDependencyProvider.getOccasionalTheme();
  await appDependencyProvider.getAmbientMode();
  await appDependencyProvider.getFQUrl();
  await appDependencyProvider.getTmdbProxy();
  await appDependencyProvider.getUpdateConfiguration();

  // Sync services require Firebase. Skip if not available.
  if (_firebaseReady) {
    try {
      await BookmarkSyncService.instance.init().timeout(const Duration(seconds: 10));
    } catch (_) {}
    try {
      await RecentlyWatchedSyncService.instance.init().timeout(const Duration(seconds: 10));
    } catch (_) {}
  } else {
  }

  return devicePresentation;
}

void main() async {
  final devicePresentation = await appInitialize().timeout(
    const Duration(seconds: 30),
    onTimeout: () {
      return DevicePresentation.handheld;
    },
  );
  HttpOverrides.global = MyHttpOverrides();
  HomeWidgetNavigationService.configure(
    source: () => (
      language: settingsProvider.appLanguage,
      useProxy: settingsProvider.enableProxy,
      proxy: appDependencyProvider.tmdbProxy,
    ),
  );
  try {
    await MediaLinkNavigationService.initialize().timeout(
      const Duration(seconds: 10),
    );
  } catch (_) {}
  HttpOverrides.global = MyHttpOverrides();
  HomeWidgetNavigationService.configure(
    source: () => (
      language: settingsProvider.appLanguage,
      useProxy: settingsProvider.enableProxy,
      proxy: appDependencyProvider.tmdbProxy,
    ),
  );
  try {
    await MediaLinkNavigationService.initialize().timeout(
      const Duration(seconds: 10),
    );
  } catch (_) {}
  runApp(EasyLocalization(
    supportedLocales: Translation.all,
    path: 'assets/translations',
    fallbackLocale: Translation.all[0],
    startLocale: Locale(settingsProvider.appLanguage),
    child: FlixQuest(
      settingsProvider: settingsProvider,
      recentProvider: recentProvider,
      bookmarkProvider: bookmarkProvider,
      appDependencyProvider: appDependencyProvider,
      devicePresentation: devicePresentation,
    ),
  ));
}
