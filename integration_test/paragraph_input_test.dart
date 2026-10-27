import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/paragraph_input_test.dart' as paragraph;

/// 真机使用实际移动输入服务验证 0.11.20 段落默认格式和下一段规则，不访问账号或正式文档。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'paragraph defaults and next style on device',
    paragraph.verifyMobileParagraphInput,
  );
}
