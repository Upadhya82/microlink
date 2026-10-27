import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';

// ---------------------------------------------------------------------------
// Data (crowdsource-service GET /crowdsource/shop-reports/{id}/comments)
// ---------------------------------------------------------------------------

class SuggestionReply {
  final String id;
  final String authorName;
  final String text;
  final DateTime? createdAt;

  const SuggestionReply({
    required this.id,
    required this.authorName,
    required this.text,
    this.createdAt,
  });

  factory SuggestionReply.fromJson(Map<String, dynamic> json) => SuggestionReply(
        id: json['id']?.toString() ?? '',
        authorName: json['author_name']?.toString() ?? 'MicroLink user',
        text: json['text']?.toString() ?? '',
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '')?.toLocal(),
      );
}

class SuggestionComment {
  final String id;
  final String authorName;

  /// True: "yes, the shop is there". False: "no, it isn't". Null for an
  /// open comment that was not an answer to "is it there?".
  final bool? confirms;
  final String text;
  final DateTime? createdAt;
  final List<SuggestionReply> replies;

  const SuggestionComment({
    required this.id,
    required this.authorName,
    required this.confirms,
    required this.text,
    this.createdAt,
    this.replies = const [],
  });

  factory SuggestionComment.fromJson(Map<String, dynamic> json) => SuggestionComment(
        id: json['id']?.toString() ?? '',
        authorName: json['author_name']?.toString() ?? 'MicroLink user',
        confirms: json['confirms'] as bool?,
        text: json['comment']?.toString() ?? '',
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '')?.toLocal(),
        replies: [
          for (final r in (json['replies'] as List? ?? const []))
            SuggestionReply.fromJson(r as Map<String, dynamic>),
        ],
      );
}

/// "just now", "5 min ago", "3 h ago", "2 days ago", or a date.
String commentTimeAgo(DateTime? time, {DateTime? now}) {
  if (time == null) return '';
  final difference = (now ?? DateTime.now()).difference(time);
  if (difference.inMinutes < 1) return 'just now';
  if (difference.inMinutes < 60) return '${difference.inMinutes} min ago';
  if (difference.inHours < 24) return '${difference.inHours} h ago';
  if (difference.inDays < 7) {
    return difference.inDays == 1 ? '1 day ago' : '${difference.inDays} days ago';
  }
  return '${time.day}/${time.month}/${time.year}';
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

/// Opens a suggestion's comments in a bottom sheet.
Future<void> showSuggestionComments(
  BuildContext context, {
  required String reportId,
  required String shopName,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => Padding(
      // Keeps the reply box above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, controller) => SingleChildScrollView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                shopName,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.md),
              SuggestionCommentsSection(reportId: reportId),
            ],
          ),
        ),
      ),
    ),
  );
}

/// What neighbours said about a suggested shop -- each with their full name
/// -- and the replies under each comment. Anyone signed in can reply.
class SuggestionCommentsSection extends StatefulWidget {
  final String reportId;

  const SuggestionCommentsSection({super.key, required this.reportId});

  @override
  State<SuggestionCommentsSection> createState() => _SuggestionCommentsSectionState();
}

class _SuggestionCommentsSectionState extends State<SuggestionCommentsSection> {
  List<SuggestionComment>? _comments;
  String? _error;

  /// The comment whose reply box is open, if any.
  String? _replyingTo;
  final _replyController = TextEditingController();
  bool _sending = false;

  /// The "Add a comment" box anyone signed in can use.
  final _commentController = TextEditingController();
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _replyController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _postComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    setState(() => _posting = true);
    try {
      await ApiClient.instance.post(
        '/crowdsource/shop-reports/${widget.reportId}/comments',
        body: {'text': text},
      );
      if (!mounted) return;
      _commentController.clear();
      FocusScope.of(context).unfocus();
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _load() async {
    try {
      final response = await ApiClient.instance.get(
        '/crowdsource/shop-reports/${widget.reportId}/comments',
      ) as List;
      if (!mounted) return;
      setState(() {
        _comments = [
          for (final item in response)
            SuggestionComment.fromJson(item as Map<String, dynamic>),
        ];
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not load the comments.');
    }
  }

  Future<void> _sendReply(SuggestionComment comment) async {
    final text = _replyController.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await ApiClient.instance.post(
        '/crowdsource/shop-reports/${widget.reportId}/comments/${comment.id}/replies',
        body: {'text': text},
      );
      if (!mounted) return;
      _replyController.clear();
      setState(() => _replyingTo = null);
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final secondary = context.appColors.textSecondary;
    final comments = _comments;

    final header = Text(
      comments == null ? 'What neighbours said' : 'What neighbours said (${comments.length})',
      style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    );

    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Expanded(child: Text(_error!, style: textTheme.bodySmall?.copyWith(color: secondary))),
              TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ],
      );
    }
    if (comments == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const Padding(
            padding: EdgeInsets.all(AppSpacing.md),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const SizedBox(height: AppSpacing.sm),
        if (comments.isEmpty)
          Text(
            'No comments yet. Be the first to say something.',
            style: textTheme.bodySmall?.copyWith(color: secondary),
          ),
        for (final comment in comments) _buildComment(context, comment),
        // Anyone signed in can start a comment here.
        const SizedBox(height: AppSpacing.xs),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _commentController,
                maxLength: 500,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Add a comment…',
                  isDense: true,
                  counterText: '',
                ),
              ),
            ),
            IconButton(
              tooltip: 'Post comment',
              onPressed: _posting ? null : _postComment,
              icon: _posting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildComment(BuildContext context, SuggestionComment comment) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final replying = _replyingTo == comment.id;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Avatar(name: comment.authorName, color: scheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      children: [
                        Text(
                          comment.authorName,
                          style: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (comment.confirms != null)
                          Text(
                            comment.confirms! ? '✓ Says it is there' : '✗ Says it is not there',
                            style: textTheme.labelSmall?.copyWith(
                              color: comment.confirms! ? colors.success : scheme.error,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(comment.text, style: textTheme.bodyMedium),
                    Row(
                      children: [
                        Text(
                          commentTimeAgo(comment.createdAt),
                          style: textTheme.labelSmall?.copyWith(color: colors.textSecondary),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(48, 32),
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () => setState(() {
                            _replyingTo = replying ? null : comment.id;
                            _replyController.clear();
                          }),
                          child: Text(replying ? 'Cancel' : 'Reply'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Replies, indented under the comment.
          if (comment.replies.isNotEmpty || replying)
            Padding(
              padding: const EdgeInsets.only(left: 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final reply in comment.replies)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Avatar(name: reply.authorName, color: scheme.tertiary, radius: 12),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  reply.authorName,
                                  style: textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                Text(reply.text, style: textTheme.bodySmall),
                                Text(
                                  commentTimeAgo(reply.createdAt),
                                  style: textTheme.labelSmall?.copyWith(color: colors.textSecondary),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (replying)
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _replyController,
                            autofocus: true,
                            maxLength: 500,
                            minLines: 1,
                            maxLines: 3,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(
                              hintText: 'Reply to ${comment.authorName}…',
                              isDense: true,
                              counterText: '',
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Send reply',
                          onPressed: _sending ? null : () => _sendReply(comment),
                          icon: _sending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.send_rounded),
                        ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String name;
  final Color color;
  final double radius;

  const _Avatar({required this.name, required this.color, this.radius = 16});

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return CircleAvatar(
      radius: radius,
      backgroundColor: color.withValues(alpha: 0.15),
      child: Text(
        initial,
        style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: radius * 0.85),
      ),
    );
  }
}
