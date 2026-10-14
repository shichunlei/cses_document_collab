/// Portable BlockCraft collaboration editor and host integration contracts.
///
/// Hosts create a controller with their storage path and gateway, await
/// initialize, present CollaborativeEditorPage(collab: controller), then await
/// close before opening another document. Physical connections remain host-owned.
library;

export 'src/controller/collab_controller.dart'
    show CollabController, ConnectionStatus;
export 'src/editor/collaborative_editor_page.dart' show CollaborativeEditorPage;
export 'src/model/collab_document_config.dart';
export 'src/model/collab_host_services.dart';
export 'src/model/editor_media_upload.dart';
export 'src/sync/cses_collab_gateway.dart';
export 'src/sync/cses_doc_collaboration_session.dart' show CsesCollabState;

export 'src/model/document_metadata.dart';
export 'src/controller/document_metadata_controller.dart';
