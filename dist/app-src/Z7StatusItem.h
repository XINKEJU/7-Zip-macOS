// Z7StatusItem.h
//
// 菜单栏状态图标的拖放装配。
//
// 为什么单独成文件，而不是留在 main.m 里：这段逻辑必须能被单元测试链接。
// 它用 class_addMethod 给「系统创建、无法子类化」的 NSStatusBarButton 补上
// NSDraggingDestination 的方法，类型编码写错、幂等性没处理好，都会让拖放静默失效
// ——界面上表现为「拖过去没反应」，不报错、不留日志，不测就发现不了。
//
// 本文件刻意不依赖 main.m 里的任何东西（不用 L() 宏、不取 SF Symbol），
// 这样测试程序可以只链接它，不必把整个前端一起拖进来。

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 拖放的接收方（由应用委托实现）。
@protocol Z7StatusDropReceiver <NSObject>
- (void)statusItemReceivedURLs:(NSArray<NSURL *> *)urls;
@end

/// 菜单栏图标是否应当显示。默认显示：用户要的就是「把东西丢给它」这种常驻入口。
extern BOOL Z7StatusItemWanted(void);

/// 记住用户的选择。
extern void Z7SetStatusItemWanted(BOOL on);

/// 抹掉这条偏好，回到「从没设置过」的状态（即默认显示）。供测试使用。
extern void Z7ResetStatusItemPreference(void);

/// 让状态栏按钮接受文件拖放，落下来的 URL 转给 receiver。
///
/// 幂等：同一个类只补一次方法，重复调用只更新内部的两份弱引用——所以状态栏图标
/// 被关掉又打开时可以安全地再次调用。
extern void Z7InstallStatusButtonDragging(NSStatusItem *item, id<Z7StatusDropReceiver> receiver);

/// 拖放处理是否已由本模块装上（判据是「装的是我们的实现」，不是「有这个 selector」）。
/// 供门禁断言使用：装配走的是运行期 class_addMethod，装错了没有任何运行时症状，
/// 只有在这里问得出来。
extern BOOL Z7StatusButtonDraggingInstalled(void);

NS_ASSUME_NONNULL_END
