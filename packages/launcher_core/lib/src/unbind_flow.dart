import 'binding_store.dart';
import 'config_refresh.dart';
import 'handoff.dart';
import 'preferences.dart';
import 'server.dart';

/// 解除绑定（Unbind）编排：保留运行，归还入口，清除启动器侧全部状态。
///
/// 顺序契约：先尽力向在线受管会话发送 setEntryManaged(false)（短超时，
/// 失败不阻塞——应用/SDK 侧心跳归还是兜底），再关闭会话；然后清除配置刷新
/// 残留与登录启动偏好，最后移除绑定记录。绑定记录最后移除，保证清理期间
/// 握手侧仍视项目为已知；移除之后，应用重连走既有 unknown-project 拒绝
/// 路径（SDK 侧轻量重试）。
///
/// 竞态处理：SDK 可能在「关闭会话 → 移除绑定」的窗口内重连成功，留下一个
/// 不再受管的活跃会话；因此移除绑定后再关一次会话。绑定已移除，此后的
/// 握手一律被拒，最后一关是收敛点。
///
/// 任何一步都不回收应用的运行业务（ADR 0001）；应用不在线时照样完成。
class UnbindFlow {
  // 命名参数不能以下划线开头，lint 建议的初始化形式在此不可用，
  // 保持显式赋值（公开构造签名即团队协作契约）。
  // ignore_for_file: prefer_initializing_formals
  UnbindFlow({
    required BindingStore bindings,
    required PreferenceStore preferences,
    required ConfigRefresher refresher,
    required EntryHandoffCoordinator handoff,
    required LauncherServer server,
  }) : _bindings = bindings,
       _preferences = preferences,
       _refresher = refresher,
       _handoff = handoff,
       _server = server;

  final BindingStore _bindings;
  final PreferenceStore _preferences;
  final ConfigRefresher _refresher;
  final EntryHandoffCoordinator _handoff;
  final LauncherServer _server;

  /// 解除 [projectId] 的绑定。项目未绑定（无任何记录）时抛 [StateError]。
  Future<void> unbind(String projectId) async {
    // 1. 归还原菜单栏入口：尽力向在线受管会话发送 setEntryManaged(false)。
    await _handoff.release(projectId);
    // 2. 关闭受管会话；应用不在线时跳过。
    await _server.sessionFor(projectId)?.close();
    // 3. 清除配置刷新残留（invalid/retained）与登录启动偏好。
    await _refresher.purge(projectId);
    await _preferences.removeProject(projectId);
    // 4. 最后移除绑定记录；未绑定的项目在此抛 StateError。
    await _bindings.remove(projectId);
    // 5. 再关一次会话：收掉第 2 步之后、第 4 步之前重连进来的会话。
    //    绑定已移除，后续握手全部被拒，这里之后该项目不再有活跃会话。
    await _server.sessionFor(projectId)?.close();
  }
}
