import 'package:appflowy_editor/appflowy_editor.dart';

/// The mobile action that toggles inline code on the current selection.
final codeMobileToolbarItem = MobileToolbarItem.action(
  itemIconBuilder: (context, _, _) => AFMobileIcon(
    afMobileIcons: AFMobileIcons.code,
    color: MobileToolbarTheme.of(context).iconColor,
  ),
  actionHandler: (_, editorState) => editorState.toggleAttribute(
    AppFlowyRichTextKeys.code,
  ),
);
