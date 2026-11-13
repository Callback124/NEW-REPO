import 'package:flutter/material.dart';

import 'store.dart';
import 'widgets.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => CustomScrollView(
        slivers: [
          const SliverAppBar(floating: true, title: Text('Library')),
          if (app.library.isEmpty)
            const SliverToBoxAdapter(
              child: EmptyState(
                title: 'Your library is empty',
                text: 'Open any title and tap Library to keep it here.',
              ),
            )
          else
            PosterGrid(items: app.library),
        ],
      ),
    );
  }
}
