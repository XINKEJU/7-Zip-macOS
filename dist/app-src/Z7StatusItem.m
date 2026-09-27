// Z7StatusItem.m — 见 Z7StatusItem.h 顶部的说明。

#import "Z7StatusItem.h"
#import <objc/runtime.h>
#import <stdlib.h>   // free()：class_copyMethodList 返回的数组要自己释放

static NSString *const kZ7StatusItemKey = @"Z7ShowStatusItem";

BOOL Z7StatusItemWanted(void)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kZ7StatusItemKey] == nil) return YES;
    return [d boolForKey:kZ7StatusItemKey];
}

void Z7SetStatusItemWanted(BOOL on)
{
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kZ7StatusItemKey];
}

void Z7ResetStatusItemPreference(void)
{
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kZ7StatusItemKey];
}

#pragma mark - 拖放代理

/// 为什么需要代理这一层：`statusItem.button` 由系统创建（NSStatusBarButton），既不能
/// 子类化也不能替换，而拖放要求目标对象自己实现 NSDraggingDestination 的方法。这里的
/// 做法是在本进程内给那个类补上几个方法，方法体统一转给本代理。影响面可控：改的是
/// 内存里的类定义，不写磁盘、不影响别的进程，而本进程内只可能有一个状态栏项。
///
/// 之所以不走 `statusItem.view`，是因为那条路自 10.10 起已被弃用，而 NSStatusBarButton
/// 是官方仍在支持的路径。
@interface Z7StatusDragProxy : NSObject
@property (nonatomic, weak, nullable) NSStatusItem *item;
@property (nonatomic, weak, nullable) id<Z7StatusDropReceiver> receiver;
- (NSDragOperation)entered:(nullable id<NSDraggingInfo>)sender;
- (BOOL)perform:(nullable id<NSDraggingInfo>)sender;
- (void)exited:(nullable id<NSDraggingInfo>)sender;
@end

static Z7StatusDragProxy *gStatusDragProxy = nil;

@implementation Z7StatusDragProxy

- (NSDragOperation)entered:(id<NSDraggingInfo>)sender
{
    // 与窗口内的拖放同样的判据：至少含一个文件 URL 才表态。拖一段文本过来时图标
    // 不该高亮——反馈与实际行为必须对得上。
    NSArray *urls = [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls.count) return NSDragOperationNone;
    self.item.button.highlighted = YES;
    return NSDragOperationCopy;
}

- (void)exited:(id<NSDraggingInfo>)sender
{
    self.item.button.highlighted = NO;
}

- (BOOL)perform:(id<NSDraggingInfo>)sender
{
    self.item.button.highlighted = NO;
    NSArray<NSURL *> *urls = [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls.count) return NO;
    [self.receiver statusItemReceivedURLs:urls];
    return YES;
}

@end

#pragma mark - 把代理的方法装到 NSStatusBarButton 上

// class_addMethod 要的是函数指针，所以方法体写成 C 函数，只做一次转发。
//
// 类型编码必须与 C 签名严格对应，写错不会立刻报错，只会在 AppKit 回调时取到垃圾值：
//   NSDragOperation = NSUInteger → Q
//   BOOL                         → B     ← 注意**不是** c
//   void                         → v
// 「BOOL 是 signed char 所以编码 c」是个常见的想当然，本工具链上实测
// @encode(BOOL) == "B"（clang 为同一签名生成的编码是 B24@0:8@16，不是 c24@0:8@16）。
// objc_test 会拿编译器生成的编码当基准逐条比对，不要再凭印象改这几个字面量。
static NSDragOperation Z7SB_entered(id self, SEL _cmd, id<NSDraggingInfo> s)
{ return [gStatusDragProxy entered:s]; }
static NSDragOperation Z7SB_updated(id self, SEL _cmd, id<NSDraggingInfo> s)
{ return [gStatusDragProxy entered:s]; }
static void Z7SB_exited(id self, SEL _cmd, id<NSDraggingInfo> s)
{ [gStatusDragProxy exited:s]; }
static BOOL Z7SB_prepare(id self, SEL _cmd, id<NSDraggingInfo> s)
{ return YES; }
static BOOL Z7SB_perform(id self, SEL _cmd, id<NSDraggingInfo> s)
{ return [gStatusDragProxy perform:s]; }
static void Z7SB_conclude(id self, SEL _cmd, id<NSDraggingInfo> s)
{ [gStatusDragProxy exited:s]; }
static void Z7SB_ended(id self, SEL _cmd, id<NSDraggingInfo> s)
{ [gStatusDragProxy exited:s]; }

/// 只在**本类自己的**方法列表里查找，不看父类。返回的 Method 记得不要 free 它的
/// 内部指针（class_copyMethodList 返回的数组已在函数内释放）。
///
/// 为什么不能用 class_getInstanceMethod 当守卫：它会沿继承链往上查，而 **NSView
/// 自己就声明了 NSDraggingDestination 的那几个方法**（实测 performDragOperation:
/// 的 imp 落在 AppKit 里）。于是「查得到方法」和「我们装过」变成两件事——用前者
/// 当守卫会让 class_addMethod 永不执行，整个拖放装配成为死代码，而界面上只表现为
/// 「拖上去没反应」，不报错、不留日志。这个缺陷正是 objc_test 的装配断言抓出来的。
static Method Z7OwnMethod(Class cls, SEL sel)
{
    unsigned n = 0;
    Method *list = class_copyMethodList(cls, &n);   // 只含本类，不含父类
    Method hit = NULL;
    for (unsigned i = 0; i < n; i++) {
        if (sel_isEqual(method_getName(list[i]), sel)) { hit = list[i]; break; }
    }
    free(list);
    return hit;
}

/// 判据是「装的是**我们的**实现吗」，而不只是「有没有这个方法」——后者会把
/// 系统自带的实现误认成装配成功。同时也让重复调用保持幂等。
static BOOL Z7DraggingIsOurs(void)
{
    Method m = Z7OwnMethod(NSStatusBarButton.class, @selector(performDragOperation:));
    return m != NULL && method_getImplementation(m) == (IMP)Z7SB_perform;
}

BOOL Z7StatusButtonDraggingInstalled(void)
{
    return Z7DraggingIsOurs();
}

void Z7InstallStatusButtonDragging(NSStatusItem *item, id<Z7StatusDropReceiver> receiver)
{
    if (!item.button) return;
    if (!gStatusDragProxy) gStatusDragProxy = [[Z7StatusDragProxy alloc] init];
    gStatusDragProxy.item = item;
    gStatusDragProxy.receiver = receiver;

    Class cls = NSStatusBarButton.class;
    if (!Z7DraggingIsOurs()) {
        class_addMethod(cls, @selector(draggingEntered:),         (IMP)Z7SB_entered, "Q@:@");
        class_addMethod(cls, @selector(draggingUpdated:),         (IMP)Z7SB_updated, "Q@:@");
        class_addMethod(cls, @selector(draggingExited:),          (IMP)Z7SB_exited,  "v@:@");
        class_addMethod(cls, @selector(prepareForDragOperation:), (IMP)Z7SB_prepare, "B@:@");
        class_addMethod(cls, @selector(performDragOperation:),    (IMP)Z7SB_perform, "B@:@");
        class_addMethod(cls, @selector(concludeDragOperation:),   (IMP)Z7SB_conclude,"v@:@");
        class_addMethod(cls, @selector(draggingEnded:),           (IMP)Z7SB_ended,   "v@:@");
    }
    [item.button registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
}
