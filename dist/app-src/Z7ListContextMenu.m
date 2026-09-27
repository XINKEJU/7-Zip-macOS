#import "Z7ListContextMenu.h"

// 与 main.m 同款：键就是中文原文（开发区域是 zh-Hans），漏配翻译时回退成中文。
#define L(s) NSLocalizedString(s, nil)

NSString * const Z7ListSelPreview         = @"doPreview:";
NSString * const Z7ListSelExtractSelected = @"doExtractSelection:";
NSString * const Z7ListSelCopyPath        = @"copy:";
NSString * const Z7ListSelDelete          = @"doDelete:";
NSString * const Z7ListSelAddFiles        = @"doAdd:";
NSString * const Z7ListSelTestArchive     = @"doTest:";
NSString * const Z7ListSelRevealInFinder  = @"revealArchiveInFinder:";
NSString * const Z7ListSelReload          = @"reloadArchive:";
NSString * const Z7ListSelSelectAll       = @"selectAll:";

static NSMenuItem *Z7AddItem(NSMenu *m, NSString *title, NSString *selName, id target)
{
    NSMenuItem *it = [m addItemWithTitle:title
                                  action:NSSelectorFromString(selName)
                           keyEquivalent:@""];
    it.target = target;
    return it;
}

NSMenu *Z7BuildListContextMenu(BOOL hasRow, id target)
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];

    if (hasRow) {
        // 条目级。顺序按「先看后取再破坏」：预览 → 解压 → 拷贝 → 删除。
        Z7AddItem(m, L(@"预览"),        Z7ListSelPreview,         target);
        Z7AddItem(m, L(@"解压所选…"),   Z7ListSelExtractSelected, target);
        Z7AddItem(m, L(@"拷贝路径"),    Z7ListSelCopyPath,        target);
        [m addItem:[NSMenuItem separatorItem]];
        // 破坏性动作单独一段、放最下，与 Finder 的「移到废纸篓」同位置：
        // 手滑点到底部也不会误触。
        Z7AddItem(m, L(@"删除所选"),    Z7ListSelDelete,          target);
        [m addItem:[NSMenuItem separatorItem]];
    } else {
        // 空白处：整档命令。这里不给条目级动作——空白处点右键时选中已被清空，
        // 留着「解压所选…」只会得到一次莫名其妙的空操作。
        Z7AddItem(m, L(@"添加文件…"),   Z7ListSelAddFiles,        target);
        Z7AddItem(m, L(@"测试归档"),    Z7ListSelTestArchive,     target);
        Z7AddItem(m, L(@"在访达中显示"), Z7ListSelRevealInFinder,  target);
        Z7AddItem(m, L(@"重新载入"),    Z7ListSelReload,          target);
        [m addItem:[NSMenuItem separatorItem]];
    }

    // 「全选」target 留空、走响应链：selectAll: 是 NSOutlineView 的既有实现，
    // 控制器上并没有这个方法，target 指向控制器会变成 unrecognized selector。
    Z7AddItem(m, L(@"全选"), Z7ListSelSelectAll, nil);
    return m;
}
