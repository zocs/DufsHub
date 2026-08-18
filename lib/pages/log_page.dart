import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/server_config.dart';
import '../models/transfer_log.dart';
import '../services/dufs_service.dart';

class LogPage extends StatelessWidget {
  final ServerConfig config;
  const LogPage({super.key, required this.config});

  AppLocalizations get l10n => AppLocalizations(config.language);

  @override
  Widget build(BuildContext context) {
    final service = context.watch<DufsService>();
    final logs = service.transferLogs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Icon(
                Icons.history,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.t('log.title'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const Spacer(),
              if (logs.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: l10n.t('log.clear'),
                  onPressed: () => service.clearLogs(),
                ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Stats summary
        if (logs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _buildStats(context, logs),
          ),

        // Log list
        Expanded(
          child: logs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.inbox_outlined,
                        size: 48,
                        color: Theme.of(
                          context,
                        ).colorScheme.outline.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        l10n.t('log.empty'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: logs.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) => _buildLogEntry(context, logs[i]),
                ),
        ),
      ],
    );
  }

  Widget _buildStats(BuildContext context, List<TransferLog> logs) {
    final downloads = logs.where((l) => l.isDownload && l.isSuccess).length;
    final uploads = logs.where((l) => l.isUpload && l.isSuccess).length;
    final errors = logs.where((l) => !l.isSuccess).length;
    final totalSize = logs
        .where((l) => l.size != null)
        .fold<int>(0, (s, l) => s + l.size!);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _statChip(context, Icons.download, '$downloads', Colors.green),
          _statChip(context, Icons.upload, '$uploads', Colors.blue),
          if (errors > 0)
            _statChip(context, Icons.error_outline, '$errors', Colors.red),
          _statChip(
            context,
            Icons.data_usage,
            _formatSize(totalSize),
            Colors.orange,
          ),
        ],
      ),
    );
  }

  Widget _statChip(
    BuildContext context,
    IconData icon,
    String value,
    Color color,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buildLogEntry(BuildContext context, TransferLog entry) {
    final icon = entry.isDownload
        ? Icons.download
        : entry.isUpload
        ? Icons.upload
        : entry.isDelete
        ? Icons.delete_outline
        : Icons.http;

    final iconColor = !entry.isSuccess
        ? Colors.red
        : entry.isDownload
        ? Colors.green
        : entry.isUpload
        ? Colors.blue
        : null;

    final timeStr =
        '${entry.time.hour.toString().padLeft(2, '0')}:'
        '${entry.time.minute.toString().padLeft(2, '0')}:'
        '${entry.time.second.toString().padLeft(2, '0')}';

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, size: 20, color: iconColor),
      title: Row(
        children: [
          Expanded(
            child: Text(
              _displayName(entry.path),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (entry.ip != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                entry.ip!,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
      subtitle: Row(
        children: [
          Text(
            entry.method,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: iconColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: entry.isSuccess
                  ? Colors.green.withValues(alpha: 0.1)
                  : Colors.red.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${entry.status}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: entry.isSuccess ? Colors.green : Colors.red,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (entry.size != null) ...[
            const SizedBox(width: 8),
            Text(
              _formatSize(entry.size!),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ],
      ),
      trailing: Text(
        timeStr,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
      onTap: () => _openEntry(context, entry),
      onLongPress: () {
        // Copy path to clipboard
        Clipboard.setData(ClipboardData(text: entry.path));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l10n.t('log.copyPath')}: ${entry.path}')),
        );
      },
    );
  }

  /// 点击记录 → 用系统关联程序打开对应的本地文件
  Future<void> _openEntry(BuildContext context, TransferLog entry) async {
    final messenger = ScaffoldMessenger.of(context);
    final target = _resolveTarget(entry.path);
    if (target == null) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.t('log.fileGone'))));
      return;
    }
    final result = await OpenFilex.open(target);
    if (result.type != ResultType.done) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('${l10n.t('log.openFailed')}: ${result.message}'),
        ),
      );
    }
  }

  /// 把日志里的请求路径映射回磁盘绝对路径。
  /// 单文件分享时所有请求都指向被分享的那个文件；目录分享时按候选
  /// （原样 → 去 query → URL 解码）取第一个真实存在的路径。
  String? _resolveTarget(String reqPath) {
    final root = config.path;
    if (root.isEmpty) return null;
    if (FileSystemEntity.typeSync(root) == FileSystemEntityType.file) {
      return root;
    }
    final candidates = <String>{reqPath};
    final q = reqPath.indexOf('?');
    if (q >= 0) candidates.add(reqPath.substring(0, q));
    for (final c in candidates.toList()) {
      try {
        candidates.add(Uri.decodeComponent(c));
      } catch (_) {}
    }
    final rootPrefix = Directory(root).absolute.uri.toString();
    for (final c in candidates) {
      final rel = c.startsWith('/') ? c.substring(1) : c;
      final full = File('$root/$rel').absolute;
      // 防 ../ 逃出分享根
      if (!full.uri.toString().startsWith(rootPrefix)) continue;
      if (FileSystemEntity.typeSync(full.path) !=
          FileSystemEntityType.notFound) {
        return full.path;
      }
    }
    return null;
  }

  /// 只显示文件名，不显示完整路径
  String _displayName(String path) {
    if (path == '/') return '/';
    final parts = path.split('/');
    return parts.isNotEmpty ? parts.last : path;
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }
}
