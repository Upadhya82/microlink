import 'package:flutter/material.dart';

import '../network/profile_photo_service.dart';

/// The signed-in user's avatar: their photo if they have uploaded one, and
/// the person icon if they have not.
///
/// Listens to [ProfilePhotoService], so every avatar in the app changes the
/// moment a new photo is uploaded -- there is no need to pass the image down
/// or rebuild the screen that owns it.
class ProfileAvatar extends StatelessWidget {
  final double radius;

  /// Behind the fallback icon. Defaults to the theme's primary container.
  final Color? backgroundColor;

  /// The fallback icon, and the person icon's colour.
  final Color? foregroundColor;

  const ProfileAvatar({
    super.key,
    this.radius = 22,
    this.backgroundColor,
    this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = backgroundColor ?? colorScheme.primaryContainer;
    final foreground = foregroundColor ?? colorScheme.primary;

    return AnimatedBuilder(
      animation: ProfilePhotoService.instance,
      builder: (context, _) {
        final bytes = ProfilePhotoService.instance.bytes;
        return CircleAvatar(
          radius: radius,
          backgroundColor: background,
          // backgroundImage rather than a child Image: it is already clipped
          // to the circle and scaled to cover, so a photo of any aspect ratio
          // fills the avatar without being squashed.
          backgroundImage: bytes == null ? null : MemoryImage(bytes),
          child: bytes == null
              ? Icon(Icons.person_outline, color: foreground, size: radius)
              : null,
        );
      },
    );
  }
}
