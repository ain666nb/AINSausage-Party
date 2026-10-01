#include "dobby.h"

typedef struct {
  uint64_t hook_vaddr;
  uint64_t hook_size;
  uint64_t code_vaddr;
  uint64_t code_size;

  uint64_t patched_vaddr;
  uint64_t original_vaddr;
  uint64_t instrument_vaddr;

  uint64_t patch_size;
  uint64_t patch_hash;

  void *target_replace;
  void *instrument_handler;
} StaticInlineHookBlock;

int dobby_create_instrument_bridge(void *targetData);

bool dobby_static_inline_hook(StaticInlineHookBlock *hookBlock, StaticInlineHookBlock *hookBlockRVA, uint64_t funcRVA,
                              void *funcData, uint64_t targetRVA, void *targetData, uint64_t InstrumentBridgeRVA,
                              void *patchBytes, int patchSize);


BOOL ActiveCodePatch(char* machoPath, uint64_t vaddr, char* patch);
BOOL DeactiveCodePatch(char* machoPath, uint64_t vaddr, char* patch);
NSString* StaticInlineHookPatch(char* machoPath, uint64_t vaddr, char* patch);
// Read-only profile check used by Sequoia's offline re-patch coordinator.
// It checks both the loaded image and Documents/static-inline-hook output;
// it never changes the host image or the patch file.
BOOL StaticInlineHookHasBlock(char* machoPath, uint64_t vaddr);
// File-only counterpart for the offline coordinator.  A live pre-patched
// image must not make the coordinator skip creating its Documents artifact.
BOOL StaticInlineHookHasBlockInFile(char* machoPath, uint64_t vaddr);
void* StaticInlineHookFunction(char* machoPath, uint64_t vaddr, void* replace);
BOOL StaticInlineHookInstrument(char* machoPath, uint64_t vaddr, void(*callback)(RegisterContext*));




//免越狱启用代码补丁
BOOL 启用代码补丁(NSString *路径, uint64_t 地址, NSString *补丁);
//使用方式
//启用代码补丁(@"pvz", 0x0056AC40, @"29A10011");




//免越狱禁用代码补丁
BOOL 禁用代码补丁(NSString *路径, uint64_t 地址, NSString *补丁);
//使用方式
//禁用代码补丁(@"pvz", 0x0056AC40, @"29A10011");




//免越狱静态替换函数
void 静态替换函数(NSString *路径, uint64_t 地址, void* 自定义函数地址, void** 原始函数地址);

 // ========== 联动Hook（跨插件回调链） ==========
 // type_id 用于确保回调函数签名一致；不一致将不会触发回调。
 // 目前只内置部分常用签名，后续可继续扩展。
 typedef NS_ENUM(uint32_t, MsHookTypeId) {
     MsHookTypeId_Invalid = 0,
     MsHookTypeId_I64_I64 = 1,                // int64_t f(int64_t)
     MsHookTypeId_Void_I64_I64_I64_U64P = 2,  // void f(int64_t,int64_t,int64_t,uint64_t*)
 };

 typedef struct {
     int64_t a1;
     bool call_orig;
     bool has_ret;
     int64_t ret;
 } MsHookCtx_I64_I64;

 typedef struct {
     int64_t a1;
     int64_t a2;
     int64_t a3;
     uint64_t *a4;
     bool call_orig;
 } MsHookCtx_Void_I64_I64_I64_U64P;

 typedef void (*MsHookListener_I64_I64)(MsHookCtx_I64_I64 *ctx);
 typedef void (*MsHookListener_Void_I64_I64_I64_U64P)(MsHookCtx_Void_I64_I64_I64_U64P *ctx);

 // takeover:
 //  - YES: 本插件声明接管该地址。若无接管者，将成为接管者并安装hook；若已有其他接管者，则视为冲突并降级为普通静态替换。
 //  - NO : 本插件声明听从。若存在接管者，则仅注册回调不安装hook；否则降级为普通静态替换。
 // 返回值:
 //  - true : 已进入联动模式（听从方仅注册回调；接管方已安装可分发hook）
 //  - false: 未联动（走普通静态替换逻辑）
 bool 静态替换函数_可联动(NSString *路径, uint64_t 地址, void* 自定义函数地址, void** 原始函数地址, bool takeover, MsHookTypeId type_id);

 extern "C" bool MsHookHost_RegisterListener(const char *machoPath, uint64_t vaddr, MsHookTypeId type_id, void *listener);
 extern "C" bool MsHookHost_IsActive(void);

 extern "C" bool MsHook_Dispatch_I64_I64(NSString *路径, uint64_t 地址, MsHookListener_I64_I64 selfListener, MsHookCtx_I64_I64 *ctx);
 extern "C" bool MsHook_Dispatch_Void_I64_I64_I64_U64P(NSString *路径, uint64_t 地址, MsHookListener_Void_I64_I64_I64_U64P selfListener, MsHookCtx_Void_I64_I64_I64_U64P *ctx);
//使用方式
/*
typedef int64_t (*原函数类型)(int64_t 参数1, int 参数2);
原函数类型 原函数 = NULL; // 保存原始函数地址

// 自定义 Hook 函数
int64_t 自定义函数(int64_t 参数1, int 参数2) {
    int64_t 原函数返回值 = 原函数(参数1, 参数2);
    return 原函数返回值;
}

 静态替换函数(@"pvz", 0x0014B154, (void *)自定义函数, (void**)&原函数);
*/





//越狱动态替换函数
void 动态替换函数(NSString *模块名, uint64_t 地址, void* 自定义函数地址, void** 原始函数地址);
/*
typedef int64_t (*原函数类型)(int64_t 参数1, int 参数2);
原函数类型 原函数 = NULL; // 保存原始函数地址

// 自定义 Hook 函数
int64_t 自定义函数(int64_t 参数1, int 参数2) {
    int64_t 原函数返回值 = 原函数(参数1, 参数2);
    return 原函数返回值;
}

动态替换函数(@"pvz", 0x0014B154, (void *)自定义函数, (void**)&原函数);
*/







//免越狱调用模块函数
/*
long 模块基地址 = 获取模块起始地址(@"pvz");
void (*HOOK弹窗)(NSString *简介) = (void (*)(NSString *))(模块基地址 + 0x7A70); // 假设地址为 0x7A70
HOOK弹窗(@"卧槽成功勾住了！！！");
*/


uint64_t 获取模块起始地址(NSString *模块名称);


void 显示弹窗(NSString *显示的内容);


// NOP函数声明
// 用于禁用指定地址的指令，将其替换为NOP指令
void nopBytes(uint64_t target, size_t patch_size);

// NOP函数的便捷版本 - 使用模块名和偏移
void nopBytesWithModule(NSString *模块名, uint64_t 偏移地址, size_t patch_size);
