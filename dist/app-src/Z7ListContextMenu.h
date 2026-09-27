//
//  Z7ListContextMenu.h — 归档列表的右键菜单内容
//
//  为什么单独成文件：菜单项指向的动作在本文件里只能写成字符串（本文件不该
//  #import main.m），拿不到 @selector 的编译期拼写检查。而拼错的表现是「右键点了
//  没反应」—— 本机合成鼠标事件无效，连手动复现都做不到。抽出来之后：
//    * objc-test 能逐项断言菜单结构（标题、动作名、target 归属、分隔线位置）；
//    * build_app.sh 有一道构建期一致性检查，断言这些动作名在 main.m 里确有实现。
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 菜单项的动作名。集中在此，测试与构建期检查引用同一份，避免两边各写一套。
extern NSString * const Z7ListSelPreview;
extern NSString * const Z7ListSelExtractSelected;
extern NSString * const Z7ListSelCopyPath;
extern NSString * const Z7ListSelDelete;
extern NSString * const Z7ListSelAddFiles;
extern NSString * const Z7ListSelTestArchive;
extern NSString * const Z7ListSelRevealInFinder;
extern NSString * const Z7ListSelReload;
/// 「全选」走响应链交给 NSOutlineView，其 target **必须**留空，见实现处注释。
extern NSString * const Z7ListSelSelectAll;

/// 构建右键菜单。
///
/// 各动作的**可用性不在这里判断**：非「全选」项的 target 由调用方给出，AppKit 在
/// 弹出前会逐项调用它的 validateMenuItem:。判据只有那一处，不会两处漂移。
///
/// @param hasRow 右键是否落在某一行上——决定给条目级动作还是整档动作
/// @param target 非「全选」项的 target（通常就是列表控制器）
NSMenu *Z7BuildListContextMenu(BOOL hasRow, id target);

NS_ASSUME_NONNULL_END
