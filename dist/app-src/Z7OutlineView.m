#import "Z7OutlineView.h"

@implementation Z7OutlineView

/// 空格预览、Delete 删除这两个键在列表里是既定操作，但它们不属于 NSOutlineView
/// 的内建行为，必须在 keyDown: 里自己拦。拦不到时事件会继续往下传（打字的响声），
/// 所以这里只处理这两个键、其余一律交给 super。
- (void)keyDown:(NSEvent *)e
{
    NSString *chars = e.charactersIgnoringModifiers;
    if ([chars isEqualToString:@" "]) {
        [self.keyDelegate outlineDidPressSpace];
        return;
    }
    unichar c = chars.length ? [chars characterAtIndex:0] : 0;
    if (c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteFunctionKey) {
        [self.keyDelegate outlineDidPressDelete];
        return;
    }
    [super keyDown:e];
}

/// 右键菜单。行选中在这里一并处理，而不是留给菜单动作——这是列表控件的既定契约：
/// 菜单内容取决于「右键的那一刻选中了什么」。
- (NSMenu *)menuForEvent:(NSEvent *)e
{
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:p];

    if (row >= 0) {
        // 右键落在未选中的行上：先把选中换成它。若不换，用户右键 A 却在菜单上
        // 看到「删除」并点下去，被删掉的是上一次选中的 B —— 这是最典型的误操作。
        if (![self.selectedRowIndexes containsIndex:(NSUInteger)row]) {
            [self selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
              byExtendingSelection:NO];
        }
    } else {
        // 空白处：清掉选中，菜单随之退化成整档命令（全选 / 测试 / 在访达中显示）。
        [self deselectAll:nil];
    }

    if ([self.keyDelegate respondsToSelector:@selector(outline:menuForRow:)]) {
        NSMenu *m = [self.keyDelegate outline:self menuForRow:row];
        if (m) return m;
    }
    return [super menuForEvent:e];
}

@end
