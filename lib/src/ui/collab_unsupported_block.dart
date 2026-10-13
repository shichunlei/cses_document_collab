import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

/// An opaque block with no text input, toolbar or child rendering.
class CollabUnsupportedBlockComponentBuilder extends BlockComponentBuilder {
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null && node.children.isEmpty;

  @override
  BlockComponentWidget build(BlockComponentContext context) =>
      _UnsupportedBlock(
        key: context.node.key,
        node: context.node,
        configuration: configuration,
      );
}

class _UnsupportedBlock extends BlockComponentStatelessWidget {
  const _UnsupportedBlock({
    super.key,
    required super.node,
    required super.configuration,
  });

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    child: Semantics(
      readOnly: true,
      child: Container(
        key: ValueKey('unsupported-block-${node.id}'),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFC),
          border: Border.all(color: const Color(0xFFE8EAF0)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFFF0F1F5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.insert_drive_file_outlined,
                size: 20,
                color: Color(0xFF969BAB),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '未适配的块（不可编辑）',
                    style: TextStyle(
                      color: Color(0xFF656B7B),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    '原始内容已保留',
                    style: TextStyle(
                      color: Color(0xFF969BAB),
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
