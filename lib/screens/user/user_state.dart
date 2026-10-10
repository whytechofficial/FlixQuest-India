import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../flixquest_main.dart';
import '../../preferences/app_dependency_preferences.dart';
import '../../provider/app_dependency_provider.dart';
import '../../services/app_update_service.dart';
import '../../services/auth_session_controller.dart';
import '../../tv/app/tv_home_shell.dart';
import '../../tv/platform/device_presentation.dart';
import '../../tv/platform/tv_debug_options.dart';
import '../../tv/screens/tv_landing_screen.dart';
import '../common/landing_screen.dart';
import '../common/update_screen.dart';

class UserState extends StatefulWidget {
  const UserState({
    required this.devicePresentation,
    super.key,
  });

  final DevicePresentation devicePresentation;

  @override
  State<UserState> createState() => _UserStateState();
}

class _UserStateState extends State<UserState> {
  PackageInfo? _packageInfo;
  bool _optionalPromptScheduled = false;
  bool _optionalPromptShown = false;

  @override
  void initState() {
    super.initState();
    if (widget.devicePresentation == DevicePresentation.handheld) {
      _loadPackageInfo();
    }
  }

  Future<void> _loadPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _packageInfo = info);
    }
  }

  /// Shows a dismissible "update available" popup once per released build,
  /// for users whose update is optional (not forced).
  Future<void> _maybeShowOptionalUpdate() async {
    if (_optionalPromptShown) return;
    _optionalPromptShown = true;
    final info = _packageInfo;
    if (info == null || !mounted) return;
    final config = context.read<AppDependencyProvider>();
    final remoteBuild = AppUpdateService.effectiveBuildNumber(
      latestBuildNumber: config.latestBuildNumber,
      minimumBuildNumber: config.minimumBuildNumber,
    );
    if (remoteBuild <= 0) return;
    final prefs = AppDependencies();
    final dismissed = await prefs.getDismissedOptionalUpdateBuild();
    if (dismissed >= remoteBuild || !mounted) return;
    final updateNow = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('update_available')),
        content: Text(tr('update_available_desc')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('later')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('update_now')),
          ),
        ],
      ),
    );
    if (!mounted) return;
    await prefs.setDismissedOptionalUpdateBuild(remoteBuild);
    if (!mounted) return;
    if (updateNow == true) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const UpdateScreen(isForced: false),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final appDependency = context.watch<AppDependencyProvider>();

    if (widget.devicePresentation == DevicePresentation.handheld &&
        _packageInfo != null) {
      final isUpdateAvailable = AppUpdateService.isAvailable(
        packageInfo: _packageInfo!,
        remoteVersion: appDependency.latestAppVersion,
        latestBuildNumber: appDependency.latestBuildNumber,
        minimumBuildNumber: appDependency.minimumBuildNumber,
      );
      if (isUpdateAvailable) {
        final currentBuild =
            int.tryParse(_packageInfo!.buildNumber) ?? 0;
        // Builds below the remotely configured minimum are always forced
        // (e.g. a broken old build), while everyone else follows the
        // optional/forced flag.
        final forceRequired = AppUpdateService.isForceRequired(
          currentBuild: currentBuild,
          minimumBuildNumber: appDependency.minimumBuildNumber,
        );
        if (appDependency.isForcedUpdate || forceRequired) {
          return const UpdateScreen(isForced: true);
        }
        // Optional update: let the app open, then offer a dismissible popup.
        if (!_optionalPromptScheduled) {
          _optionalPromptScheduled = true;
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _maybeShowOptionalUpdate());
        }
      }
    }

    final authSession = AuthSessionController.instance..initialize();
    return AuthStateRouter(
      userIdListenable: authSession.userId,
      builder: (context, isAuthenticated) {
        final previewTvHome =
            widget.devicePresentation == DevicePresentation.television &&
                TvDebugOptions.previewHomeShell;
        // JioFix: Firebase is now wired with a real project, so the auth
        // gate follows the actual session. Signed-out users land on the
        // login screen; guests and signed-in users go straight home.
        return presentationShellFor(
          devicePresentation: widget.devicePresentation,
          isAuthenticated: isAuthenticated,
        );
      },
    );
  }
}

class AuthStateRouter extends StatelessWidget {
  const AuthStateRouter({
    required this.userIdListenable,
    required this.builder,
    super.key,
  });

  final ValueListenable<String?> userIdListenable;
  final Widget Function(BuildContext context, bool isAuthenticated) builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: userIdListenable,
      builder: (context, userId, _) => KeyedSubtree(
        key: ValueKey(userId ?? 'signed-out'),
        child: builder(context, userId != null),
      ),
    );
  }
}

Widget presentationShellFor({
  required DevicePresentation devicePresentation,
  required bool isAuthenticated,
}) {
  return switch ((devicePresentation, isAuthenticated)) {
    (DevicePresentation.television, true) => const TvHomeShell(),
    (DevicePresentation.television, false) => const TvLandingScreen(),
    (DevicePresentation.handheld, true) => const FlixQuestHomePage(),
    (DevicePresentation.handheld, false) => const LandingScreen(),
  };
}
