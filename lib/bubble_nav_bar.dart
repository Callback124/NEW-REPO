import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class BubbleNavItem {
  const BubbleNavItem({required this.icon, required this.selectedIcon, required this.label});
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// Bottom bar where the active tab lifts out of the bar into a circle.
class BubbleNavBar extends StatelessWidget {
  const BubbleNavBar({
    super.key,
    required this.index,
    required this.onChanged,
    required this.items,
  });

  final int index;
  final ValueChanged<int> onChanged;
  final List<BubbleNavItem> items;

  static const Color accent = Color(0xFF4A5AF0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final barColor = dark ? const Color(0xFF16181E) : Colors.white;
    return Material(
      color: barColor,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant, width: .5)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: _BubbleItem(
                      item: items[i],
                      selected: i == index,
                      ring: theme.scaffoldBackgroundColor,
                      onTap: () {
                        if (i != index) HapticFeedback.selectionClick();
                        onChanged(i);
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BubbleItem extends StatelessWidget {
  const _BubbleItem({
    required this.item,
    required this.selected,
    required this.ring,
    required this.onTap,
  });

  final BubbleNavItem item;
  final bool selected;
  final Color ring;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 8,
              child: AnimatedOpacity(
                opacity: selected ? 1 : 0,
                duration: const Duration(milliseconds: 220),
                child: Text(
                  item.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: BubbleNavBar.accent,
                  ),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeOutBack,
              left: 0,
              right: 0,
              top: selected ? -22 : 10,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? BubbleNavBar.accent : Colors.transparent,
                    border: Border.all(
                      color: selected ? ring : Colors.transparent,
                      width: 4,
                    ),
                  ),
                  child: Icon(
                    selected ? item.selectedIcon : item.icon,
                    size: 22,
                    color: selected ? Colors.white : muted,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
