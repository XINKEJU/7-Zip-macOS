//
//  Z7CompressionPrefs.h — 「压缩选项」面板的持久化键、出厂值与级别映射
//
//  单独成文件的理由：这些都是纯数据，不依赖 AppKit，因此 objc-test 可以直接链接
//  并逐条断言。而持久化的失败模式全都是**静默**的：
//    * 少登记一个键 → 那个控件永远回默认值，界面上看不出任何异常；
//    * 默认值与控件初值不一致 → 首次启动与恢复后表现不同，很难归因；
//    * 键写不进应用域 → 本次会话正常、重启即丢，正是用户抱怨的那种现象。
//  放进 main.m 里这些都没法测（objc_test 不链接 main.m，会有 main 符号冲突）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 键名一律带 Z7Opt 前缀，与应用其它持久化项（Z7RecentArchives 等）在同一命名空间里区分开。
extern NSString * const kZ7OptFormatKey;
extern NSString * const kZ7OptLevelKey;
extern NSString * const kZ7OptMethodKey;
extern NSString * const kZ7OptDictKey;
extern NSString * const kZ7OptWordKey;
extern NSString * const kZ7OptFastBytesKey;
extern NSString * const kZ7OptMatchKey;
extern NSString * const kZ7OptSolidKey;
extern NSString * const kZ7OptSolidBlockKey;
extern NSString * const kZ7OptAutoThreadsKey;
extern NSString * const kZ7OptThreadsKey;
extern NSString * const kZ7OptVolumeKey;
extern NSString * const kZ7OptEncMethKey;
extern NSString * const kZ7OptEncHeaderKey;
extern NSString * const kZ7OptCompHeaderKey;
extern NSString * const kZ7OptFullPathsKey;
extern NSString * const kZ7OptExcludeJunkKey;
extern NSString * const kZ7OptVerifyKey;
extern NSString * const kZ7OptSeparateKey;
extern NSString * const kZ7OptUpdateModeKey;
extern NSString * const kZ7OptAdvancedKey;

/// 各键的出厂值，直接交给 registerDefaults: 使用。
///
/// 走注册域而不是在读取处手写 if 兜底：注册域的值**不会**被写进 plist，只在
/// 「用户没设过」时参与读取，语义正好是「默认值」；integerForKey: / boolForKey:
/// 也能直接拿到正确类型，不必区分「键不存在」与「值为 0」。
NSDictionary *Z7CompressionPrefsDefaults(void);

/// 面板滑杆的 6 个档位对应的 7-Zip -mx 值（0/1/3/5/7/9）。
extern const NSInteger kZ7LevelTickValues[6];
NSInteger LevelForTick(NSInteger tick);
NSInteger TickForLevel(NSInteger level);
NSString *LevelNameForTick(NSInteger tick);

NS_ASSUME_NONNULL_END
