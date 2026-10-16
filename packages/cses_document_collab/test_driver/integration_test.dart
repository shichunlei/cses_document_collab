import 'package:integration_test/integration_test_driver.dart';

/// 从Demo宿主驱动包内设备回归，等待并返回真实设备测试结果。
/// 不初始化账号或网络；业务与资源替身由测试应用持有。
Future<void> main() => integrationDriver();
