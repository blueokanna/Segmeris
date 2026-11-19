import 'package:material_ui/material_ui.dart';

import 'app_update.dart';

/// Optional persistent MD3 update surface. The controller owns all side effects.
class AppUpdateCard extends StatelessWidget {
  const AppUpdateCard({
    super.key,
    required this.controller,
    this.alwaysVisible = false,
  });
  final AppUpdateController controller;
  final bool alwaysVisible;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      // Automatic checks stay quiet when offline or already current.
      if (!alwaysVisible && !controller.hasUpdate) {
        return const SizedBox.shrink();
      }
      final zh = Localizations.localeOf(context).languageCode == 'zh';
      final release = controller.release;
      return Card.filled(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.system_update_alt),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      release != null
                          ? '${zh ? '发现新版本' : 'Update available'} ${release.tag}'
                          : (zh ? '应用更新' : 'App updates'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (controller.checking)
                    const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (controller.error != null)
                Text(
                  zh
                      ? (controller.error!.contains('rate limit')
                            ? 'GitHub 请求已限流，请在 ${controller.service.retryAt?.toLocal()} 后重试。'
                            : '暂时无法检查更新或打开浏览器，请检查网络后重试。')
                      : controller.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              else if (release != null) ...[
                Text(
                  zh ? '由你决定何时更新。查看发行说明后，从官方页面下载安装。' : 'Choose when to update. Review the release notes and download from the official release.',
                ),
                if (release.notes.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    release.notes,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ] else
                Text(
                  controller.result == null
                      ? (zh
                            ? '从官方 GitHub Releases 检查更新。'
                            : 'Check the official GitHub Releases for updates.')
                      : (zh
                            ? '当前已是最新稳定版本。'
                            : 'You have the latest stable version.'),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (release != null) ...[
                    if (release.asset != null)
                      FilledButton.icon(
                        onPressed: controller.opening
                            ? null
                            : () => controller.openRelease(downloadAsset: true),
                        icon: const Icon(Icons.download_outlined),
                        label: Text(zh ? '下载安装包' : 'Download update'),
                      ),
                    FilledButton.tonalIcon(
                      onPressed: controller.opening
                          ? null
                          : () => controller.openRelease(),
                      icon: const Icon(Icons.open_in_new),
                      label: Text(zh ? '查看更新' : 'View update'),
                    ),
                    TextButton(
                      onPressed: controller.dismiss,
                      child: Text(zh ? '稍后' : 'Later'),
                    ),
                  ],
                  TextButton.icon(
                    onPressed: controller.checking
                        ? null
                        : () => controller.check(manual: true),
                    icon: const Icon(Icons.refresh),
                    label: Text(
                      controller.error != null
                          ? (zh ? '重试' : 'Retry')
                          : (zh ? '检查更新' : 'Check for updates'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Call [show] after a successful check, once the host has a mounted context.
/// Release notes are plain text: remote Markdown/HTML cannot execute or link.
class AppUpdatePrompt extends StatelessWidget {
  const AppUpdatePrompt({super.key, required this.controller});
  final AppUpdateController controller;

  static Future<void> show(
    BuildContext context,
    AppUpdateController controller,
  ) async {
    if (!context.mounted || !controller.hasUpdate) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AppUpdatePrompt(controller: controller),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final zh = Localizations.localeOf(context).languageCode == 'zh';
      final release = controller.release;
      return AlertDialog(
        icon: const Icon(Icons.system_update_alt),
        title: Text(
          '${zh ? '发现新版本' : 'Update available'} ${release?.tag ?? ''}',
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  zh ? '更新由你确认，不会自动下载或安装。' : 'Updates require your confirmation. Nothing is downloaded or installed automatically.',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  release?.notes.isNotEmpty == true
                      ? release!.notes
                      : (zh ? '请查看官方发行说明。' : 'See the official release notes.'),
                ),
                if (controller.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    zh ? '无法打开浏览器，请重试。' : controller.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              controller.dismiss();
              Navigator.of(context).pop();
            },
            child: Text(zh ? '稍后' : 'Later'),
          ),
          if (release?.asset != null)
            FilledButton.icon(
              onPressed: controller.opening
                  ? null
                  : () => controller.openRelease(downloadAsset: true),
              icon: const Icon(Icons.download_outlined),
              label: Text(zh ? '下载安装包' : 'Download update'),
            ),
          FilledButton.tonalIcon(
            onPressed: controller.opening
                ? null
                : () => controller.openRelease(),
            icon: const Icon(Icons.open_in_new),
            label: Text(zh ? '查看更新' : 'View update'),
          ),
        ],
      );
    },
  );
}
