import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/features/crowdsourcing/widgets/suggestion_comments.dart';

/// Neighbour comments on a shop suggestion, with names and replies.
void main() {
  test('a comment reads its author, verdict and replies', () {
    final comment = SuggestionComment.fromJson({
      'id': 'c1',
      'author_name': 'Kamal Perera',
      'confirms': true,
      'comment': 'Opens at 7 every morning.',
      'created_at': '2026-10-20T08:30:00Z',
      'replies': [
        {
          'id': 'r1',
          'author_name': 'Nimali Silva',
          'text': 'Closed on Poya days though.',
          'created_at': '2026-10-20T09:00:00Z',
        },
      ],
    });
    expect(comment.authorName, 'Kamal Perera');
    expect(comment.confirms, isTrue);
    expect(comment.text, 'Opens at 7 every morning.');
    expect(comment.replies.single.authorName, 'Nimali Silva');
    expect(comment.replies.single.text, 'Closed on Poya days though.');
  });

  test('an open comment has no "is it there?" verdict', () {
    final comment = SuggestionComment.fromJson({
      'id': 'g1',
      'kind': 'comment',
      'author_name': 'Ruwan Silva',
      'confirms': null,
      'comment': 'Great tea here!',
      'replies': const [],
    });
    expect(comment.confirms, isNull);
    expect(comment.text, 'Great tea here!');
  });

  test('a missing name falls back to a neutral label', () {
    final comment = SuggestionComment.fromJson({'id': 'c1', 'comment': 'Hi'});
    expect(comment.authorName, 'MicroLink user');
    expect(comment.replies, isEmpty);
  });

  test('times read naturally', () {
    final now = DateTime(2026, 10, 25, 12);
    expect(commentTimeAgo(now.subtract(const Duration(seconds: 20)), now: now), 'just now');
    expect(commentTimeAgo(now.subtract(const Duration(minutes: 5)), now: now), '5 min ago');
    expect(commentTimeAgo(now.subtract(const Duration(hours: 3)), now: now), '3 h ago');
    expect(commentTimeAgo(now.subtract(const Duration(days: 1)), now: now), '1 day ago');
    expect(commentTimeAgo(DateTime(2026, 9, 1), now: now), '1/9/2026');
    expect(commentTimeAgo(null), '');
  });
}
