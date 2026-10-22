/// Portable BlockCraft collaboration editor and host integration contracts.
///
/// Hosts create a controller with their storage path and gateway, await
/// initialize, present CollaborativeEditorPage(collab: controller), then await
/// close before opening another document. Physical connections remain host-owned.
/// Offline local editing uses showCollabImageComposer without opening a
/// native document, database or collaboration session.
library;

export 'src/controller/collab_controller.dart' show CollabController, ConnectionStatus;
export 'src/controller/document_bootstrapper.dart';
export 'src/controller/document_feedback_controller.dart' show DocumentFeedbackController;
export 'src/controller/document_metadata_controller.dart';
export 'src/editor/collaborative_editor_page.dart' show CollaborativeEditorPage;
export 'src/editor/core/document_editor_controller.dart';
export 'src/editor/core/editor_command_context.dart' show EditorCommandContext;
export 'src/editor/core/editor_configuration.dart'
    show EditorConfiguration, EditorBlock, EditorInlineFormat, EditorKeyboardToolbarItem;
export 'src/editor/document_editor_view.dart';
export 'src/editor/document_editor_commands.dart' show handleDocumentParagraphEnter, applyDocumentBlockShortcut;
export 'src/editor/editor_interaction_shell.dart' show EditorInteractionShell;
export 'src/editor/local_editor_controller.dart' show LocalEditorController;
export 'src/image_composer/show_image_composer.dart' show showCollabImageComposer;
export 'src/model/collab_block_lock.dart' show CollabBlockLockState, CollabBlockUnlockContext;
export 'src/model/collab_document_config.dart';
export 'src/model/collab_document_feedback.dart';
export 'src/model/collab_host_services.dart';
export 'src/model/collab_image_template.dart' show CollabImageTemplate, collabImageTemplates;
export 'src/model/collab_kr.dart' show CollabKrItem, CollabKrTopic, CollabKrService;
export 'src/model/collab_meeting_card_data.dart'
    show CollabMeetingCardState, CollabMeetingCardData, CollabMeetingCardLoader;
export 'src/model/collab_meeting_reference.dart';
export 'src/model/collab_mention_tap.dart' show CollabMentionType, CollabMentionTap, CollabMentionTapCallback;
export 'src/model/collab_mention_ui.dart' show CollabMentionAvatarBuilder, CollabMentionUserPicker;
export 'src/model/collab_task_card_data.dart'
    show CollabTaskCardData, CollabTaskCardTag, CollabTaskCardPath, CollabTaskCardLoader;
export 'src/model/collab_user_mention.dart' show CollabMentionUser, CollabMentionDirectory;
export 'src/model/document_metadata.dart';
export 'src/model/editor_media_upload.dart';
export 'src/model/prepared_document.dart';
export 'src/sync/cses_collab_gateway.dart';
export 'src/sync/cses_doc_collaboration_session.dart' show CsesCollabState;
