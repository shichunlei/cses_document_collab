import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:metalink/metalink.dart';

/// Loads metadata for an original HTTP(S) [url] without rendering remote HTML.
/// The returned future completes with partial data or structured failures; thrown
/// errors are caught by the preview. The caller retains ownership of the loader.
typedef CollabLinkPreviewLoader = Future<ExtractionResult<LinkMetadata>> Function(String url);

/// Fetches metadata for [url] with a 12-second total deadline and oEmbed lookup.
/// Returns structured extraction failures; MetaLink disposes its HTTP client when
/// the future completes. No cookies or editor state are supplied to the request.
Future<ExtractionResult<LinkMetadata>> _extractPreview(String url) => MetaLink.extract(
  url,
  options: const MetaLinkClientOptions(
    fetch: FetchOptions(totalTimeout: Duration(seconds: 12)),
    extract: ExtractOptions(enableOEmbed: true),
  ),
);

/// Displays native MetaLink metadata with text left and a thumbnail right.
/// The thumbnail scales to the available width; absent or failed images leave
/// the full width for text. No page or oEmbed HTML is executed.
/// Owns the extraction future, keeps results local, and ignores outdated results
/// after URL replacement or disposal. Failed loads retain saved fields and offer
/// retry; opening the URL is delegated to the host.
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_link_preview.dart';
/// import 'package:cses_document_collab/src/model/collab_resource.dart';
/// import 'package:flutter/material.dart';
///
/// Widget preview(VoidCallback openLink) => CollabLinkPreview(
///   url: 'https://example.com',
///   props: const CollabResource(),
///   onOpen: openLink,
/// );
/// ```
class CollabLinkPreview extends StatefulWidget {
  /// Creates a preview identified by optional [key].
  /// [url] must be a validated absolute HTTP(S) URL; [props] supplies borrowed
  /// saved fields that take precedence over fetched metadata. [onOpen] runs on
  /// card taps and owns navigation. Null [loadPreview] selects MetaLink; injected
  /// loaders remain caller-owned. Construction performs no network work.
  const CollabLinkPreview({super.key, required this.url, required this.props, required this.onOpen, this.loadPreview});

  /// Required original HTTP(S) URL; changing it restarts metadata extraction.
  final String url;

  /// Required immutable saved fields; displayed without modifying shared state.
  final CollabResource props;

  /// Required host callback invoked when the user taps the preview content.
  final VoidCallback onOpen;

  /// Optional caller-owned loader; null uses the one-off MetaLink extractor.
  final CollabLinkPreviewLoader? loadPreview;

  /// Returns a fresh state that owns requests and local loading/error display.
  @override
  State<CollabLinkPreview> createState() => _CollabLinkPreviewState();
}

/// Maintains a single preview future and isolates obsolete async completions.
class _CollabLinkPreviewState extends State<CollabLinkPreview> {
  late Future<ExtractionResult<LinkMetadata>> _preview;

  /// Replaces the local future during initialization, URL changes, or retries.
  /// Synchronous loader errors become failed futures for the fallback UI; no
  /// shared properties are written and the loader is not disposed by this state.
  void _load() {
    // Future.sync also turns synchronous loader failures into a preview fallback.
    _preview = Future.sync(() => (widget.loadPreview ?? _extractPreview)(widget.url));
  }

  /// Starts one metadata request when Flutter mounts the preview state.
  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Compares borrowed [oldWidget] inputs after Flutter updates the widget.
  /// URL or loader changes restart extraction; saved-field changes reuse the
  /// current request and are reflected immediately without collaboration writes.
  @override
  void didUpdateWidget(covariant CollabLinkPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.loadPreview != widget.loadPreview) {
      _load();
    }
  }

  /// Returns native text/image/loading controls using inherited [context].
  /// Failed images collapse, failed requests offer retry, and FutureBuilder
  /// prevents disposed or replaced requests from refreshing the current card.
  @override
  Widget build(BuildContext context) => FutureBuilder<ExtractionResult<LinkMetadata>>(
    // Discard the previous URL's data immediately, including while loading.
    key: ValueKey(_preview),
    future: _preview,
    builder: (context, snapshot) {
      final result = snapshot.data;
      final metadata = result?.metadata;
      final loading = snapshot.connectionState != ConnectionState.done;
      final failed = snapshot.hasError || result?.isFailure == true;
      final host = Uri.parse(widget.url).host;
      final savedTitle = widget.props.string('title').trim();
      final title = savedTitle.isNotEmpty && savedTitle != host && savedTitle != widget.url
          ? savedTitle
          : metadata?.title?.trim();
      final savedDescription = widget.props.string('description').trim();
      final description = savedDescription.isNotEmpty ? savedDescription : metadata?.description?.trim() ?? '';
      final image = [
        widget.props.string('image'),
        ...?metadata?.images.map((image) => image.url.toString()),
      ].where((url) => isCollabResourceUrl('bookmark', url)).firstOrNull;

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (loading) const LinearProgressIndicator(minHeight: 2),
          InkWell(
            onTap: widget.onOpen,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final thumbnailSize = (constraints.maxWidth * 0.28).clamp(0.0, 112.0);
                  return Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title?.isNotEmpty == true ? title! : host,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                            if (description.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                description,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                              ),
                            ],
                            const SizedBox(height: 6),
                            Text(
                              widget.url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11, color: Color(0xFF87909E)),
                            ),
                          ],
                        ),
                      ),
                      if (image != null)
                        Image.network(
                          image,
                          width: thumbnailSize,
                          height: thumbnailSize,
                          fit: BoxFit.cover,
                          frameBuilder: (_, child, _, _) => Padding(
                            padding: const EdgeInsets.only(left: 12),
                            child: ClipRRect(borderRadius: BorderRadius.circular(6), child: child),
                          ),
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
          if (failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('预览暂时无法加载', style: TextStyle(fontSize: 12)),
                  TextButton(onPressed: () => setState(_load), child: const Text('重试')),
                ],
              ),
            ),
        ],
      );
    },
  );
}
