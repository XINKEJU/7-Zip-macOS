//
//  Z7OutlineView.h — 归档列表视图（键盘入口 + 右键菜单入口）
//
//  单独成文件的理由与其他 Z7* 抽出件一致：**最容易被静默破坏的东西要能被测**。
//  本机合成鼠标事件无效（见 BUILD.md），右键菜单在界面上根本没法自动复现；
//  留在 main.m 里，objc-test 就完全够不着它。抽出来后可以断言：
//    * menuForEvent: / keyDown: 确实被重写了 —— 防止日后有人删掉重写，
//      右键静默退回 AppKit 的默认菜单（不报错、功能却没了）；
//    * 空格与 Delete 键的分发确实到达 delegate。
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 列表的事件出口。控制器实现它来接收键盘与右键。
@protocol Z7OutlineKeyDelegate <NSObject>
- (void)outlineDidPressSpace;
- (void)outlineDidPressDelete;
/// 提供右键菜单；row 为 -1 表示点在空白处。返回 nil 则由 AppKit 走默认行为。
@optional
- (NSMenu *)outline:(NSOutlineView *)outline menuForRow:(NSInteger)row;
@end

@interface Z7OutlineView : NSOutlineView
@property (nonatomic, weak, nullable) id<Z7OutlineKeyDelegate> keyDelegate;
@end

NS_ASSUME_NONNULL_END
