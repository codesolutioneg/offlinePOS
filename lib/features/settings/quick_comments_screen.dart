import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';

/// Manage the kitchen-note quick picks a cashier taps on the line-note dialog
/// (things like "No onions").
///
/// [SettingsStore.quickComments] already falls back to a sensible default list
/// when unset, so this screen never has to invent one; it only ever reads and
/// rewrites whatever list the store currently holds.
class QuickCommentsScreen extends StatefulWidget {
  const QuickCommentsScreen({super.key, required this.settings, required this.onChanged});

  final SettingsStore settings;

  /// Called after every add or remove so the caller can refresh anything it is
  /// holding of the quick-pick list (this screen owns no state the caller can see).
  final VoidCallback onChanged;

  @override
  State<QuickCommentsScreen> createState() => _QuickCommentsScreenState();
}

class _QuickCommentsScreenState extends State<QuickCommentsScreen> {
  late List<String> _comments;
  late final TextEditingController _newComment;

  @override
  void initState() {
    super.initState();
    // Copied rather than aliased, so edits here cannot mutate a list the store
    // handed out before the whole thing is written back in one go.
    _comments = List.of(widget.settings.quickComments);
    _newComment = TextEditingController();
  }

  @override
  void dispose() {
    _newComment.dispose();
    super.dispose();
  }

  void _persist() {
    widget.settings.quickComments = _comments;
    widget.onChanged();
  }

  void _add() {
    final text = _newComment.text.trim();
    if (text.isEmpty) return;
    setState(() => _comments.add(text));
    _newComment.clear();
    _persist();
  }

  void _remove(int index) {
    setState(() => _comments.removeAt(index));
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Quick notes')),
      body: Column(
        children: [
          Expanded(
            child: _comments.isEmpty
                ? const Center(
                    child: Text('No quick notes yet', key: Key('no-comments')),
                  )
                : ListView.builder(
                    itemCount: _comments.length,
                    itemBuilder: (context, index) {
                      return ListTile(
                        key: Key('comment-$index'),
                        title: Text(_comments[index]),
                        trailing: IconButton(
                          key: Key('delete-comment-$index'),
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Remove',
                          onPressed: () => _remove(index),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('new-comment'),
                    controller: _newComment,
                    decoration: const InputDecoration(
                      labelText: 'New quick note',
                      hintText: 'e.g. No onions',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  key: const Key('add-comment'),
                  onPressed: _add,
                  child: const Text('Add'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
