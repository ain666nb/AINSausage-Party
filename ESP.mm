/*
 MIT License

 Copyright (c) [2026] [Ain Replace]

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
 */




#import "ESP.h"
#import "OverlayRenderer.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <mach/vm_region.h>
#import <mach/vm_map.h>
#import <vector>
#import <string>
#import <cmath>
#import <chrono>
#import <mutex>
#import <atomic>
#import <deque>
#import <cstdarg>
#import <cstdio>
#import "static-inline.h"


// ===== Unity 那几个基本结构 =====
struct Vector3{float x,y,z;};
struct Vector2{float x,y;};
struct Quaternion{float x,y,z,w;};
struct Mat4{float m[16];};

// 当前 dump 里的 MarkSportEvent,arm64 下 32 字节的托管结构是间接传的,
// 所以 hook 签名里拿到的是指针
struct MarkEvt{
    Vector3 findRolePoint;
    int32_t markType;
    void* sign;
    int32_t signType;
};

// 前置声明
static void mulMat(const float* a,const float* b,float* out);
static bool w2s(Vector3 wp,float* mt,int w,int h,Vector2* out);
static uintptr_t getLocalRLC();
static uintptr_t getLocalRBD();
static uintptr_t getLocalBR();

// ===== Unity 函数指针 =====
typedef Vector3 (*fnGetPos)(void* tf);
typedef void (*fnSetPos)(void* tf,Vector3 v);
// NetworkTransformUnreliable 的客户端命令路径。Byte[] 那个重载是 arm64 上好使的,
// 它只把一次位置更新序列化发到服务器
typedef void* (*fnV3ToByte)(void* nt,Vector3 v);
typedef void (*fnCmdSync)(void* nt,void* bytes);
typedef void* (*fnGetComp)(void* comp,void* typeName,void* mi);
typedef void* (*fnStrNew)(const char* s);
typedef void* (*fnCamMain)();
typedef float (*fnGetFov)(void* cam);
typedef void (*fnSetFov)(void* cam,float v);
typedef void* (*fnGetSG)();
typedef void* (*fnSGMyCam)(void* sg,void* mi);
typedef bool (*fnIsFire)(void* mi);
typedef float (*fnGetMS)(void* rlc,void* mi);
typedef float (*fnGetSMS)(void* rlc,void* mi);
typedef void (*fnMSDUpd)(void* msd,void* mi);
typedef void (*fnMCCSend)(void* ctx,int32_t lv,int32_t type,void* desc,float ratio,void* log,void* mi);
typedef int64_t (*fnRCSend)(void* rc,int32_t lv,int32_t type,void* name,float score,void* err,bool stack,void* mi);
typedef int64_t (*fnRCReport)(void* st,int64_t lv,int64_t type,void* sub,void* err,int64_t stack,float score);
typedef void (*fnMarkEvt)(void* comp,const MarkEvt* ev,void* mi);

// 相机矩阵两种拿法都试:外层直接返回 Mat4,_Injected 是标准的两参数
typedef Mat4 (*fnGetMat)(void* cam);
typedef void (*fnGetMatInj)(void* cam,void* out);

static fnGetMat origW2C=nullptr;
static fnGetMat origProj=nullptr;
static fnGetMatInj origW2Ci=nullptr;
static fnGetMatInj origProji=nullptr;
static Mat4 vmMtx={};
static Mat4 pmMtx={};
static bool vmOk=false,pmOk=false;

// 外层 hook,顺手把矩阵抄一份,后面投影用
static Mat4 hookW2C(void* cam){
    Mat4 r=origW2C(cam);
    vmMtx=r;vmOk=true;
    return r;
}
static Mat4 hookProj(void* cam){
    Mat4 r=origProj(cam);
    pmMtx=r;pmOk=true;
    return r;
}
// _Injected:结果写进 out 里,直接 memcpy 出来
static void hookW2Ci(void* cam,void* out){
    origW2Ci(cam,out);
    memcpy(&vmMtx,out,sizeof(Mat4));vmOk=true;
}
static void hookProji(void* cam,void* out){
    origProji(cam,out);
    memcpy(&pmMtx,out,sizeof(Mat4));pmOk=true;
}

static fnGetPos pGetPos=nullptr;
static fnSetPos pSetPos=nullptr;
static fnV3ToByte pV3ToByte=nullptr;
static fnCmdSync pCmdSync=nullptr;
static fnGetComp pGetComp=nullptr;
static fnStrNew pStrNew=nullptr;
static fnCamMain pCamMain=nullptr;
static fnGetFov pGetFov=nullptr;
static fnSetFov pSetFov=nullptr;
static fnGetSG pGetSG=nullptr;
static fnSGMyCam pSGMyCam=nullptr;
static fnIsFire pIsFire=nullptr;

static bool btOn=false;                 // 子弹追踪
static float btFov=300.0f;
static int btPart=0;
static float btRad=8.0f;                // 本地枪口判定半径
static bool btTgtOk=false;
static Vector3 btTgt={0,0,0};
static bool btShOk=false;
static Vector3 btShPos={0,0,0};
static bool aimOn=false;                // 自瞄
static float aimSpd=10.0f;
static float aimFov=300.0f;
static int aimPart=0;
static int aimMode=0;
static int aimAlgo=0;
static float aimPred=1.0f;
static bool aimTgtOk=false;
static Vector3 aimTgt={0,0,0};
static bool spdOn=false;                // 加速
static float spdMul=2.0f;
static bool hjOn=false;                 // 高跳
static float hjMul=2.0f;
static bool iajOn=false;                // 空中无限跳
static bool wideOn=false;               // 广角
static float wideVal=60.0f;
static bool noRecoilOn=false;
static bool noSpreadOn=false;
static bool noCdOn=false;               // 蓄力拳无 CD

static std::mutex logMx;
static std::deque<std::string> logQ;
static constexpr size_t kLogMax=80;
static std::mutex markMx;
static bool markOk=false;
static Vector3 markPos={0,0,0};
static std::atomic<int64_t> tpUntil(0);  // 传送后压检测的时间戳
static std::mutex btMx;
static std::atomic<uintptr_t> spdLocalBR(0);
static std::atomic<uintptr_t> spdLocalRLC(0);
// 每个 latch 只喊一次,免得刷屏
static std::atomic<uint32_t> bInitMask(0);
static std::atomic<bool> bRotSeen(false);
static std::atomic<bool> aimRotSeen(false);
static std::atomic<bool> spdHookSeen(false);
static std::atomic<bool> spdPatchSeen(false);

struct PredSt{
    uintptr_t role=0;
    int part=-1;
    Vector3 lastP={0,0,0};
    Vector3 vel={0,0,0};
    std::chrono::steady_clock::time_point lastT={};
    bool ok=false;
};
static PredSt pred;

// dump 里 SORoleBaseData 的地面移动速度表。自己留一份,
// 哪怕生成的 getter 被内联或者压根没走到,也能直接改数据
static constexpr uintptr_t kSpdOff[]={
    0x1D4,0x1D8,0x1DC, // 走:前/侧/后
    0x1E0,0x1E4,0x1E8, // 跑:前/侧/后
    0x1EC,0x1F0,0x1F4, // 特殊动作
    0x1F8,0x1FC,0x200, // 蹲走
    0x204,0x208,0x20C, // 蹲跑
    0x210,0x214,0x218, // 特殊蹲
    0x21C,0x220,0x224  // 趴
};
static constexpr size_t kSpdCnt=sizeof(kSpdOff)/sizeof(kSpdOff[0]);

struct SpdPatch{
    uintptr_t rbd=0;
    float old[kSpdCnt]={};
    float last[kSpdCnt]={};
    bool ok=false;
};
static SpdPatch spdPatch;

struct HjPatch{
    uintptr_t rbd=0;
    float old[4]={};
    float last[4]={};
    bool ok=false;
};
static HjPatch hjPatch;
static constexpr uintptr_t kJmpOff[4]={0x38,0x3C,0x40,0x44}; // 站立/站立空中/移动/移动空中

struct IajPatch{
    uintptr_t br=0;
    int32_t num=0;
    bool clamped=false;
};
static IajPatch iajPatch;

struct FovPatch{
    void* cam=nullptr;
    float oldFov=0.0f;
    float lastFov=0.0f;
    bool ok=false;
};
static FovPatch fovPatch;

struct RecoilE{uintptr_t obj=0;float min=0.0f;float max=0.0f;};
struct NoRecoilSt{
    uintptr_t cfg=0;
    float old[4]={};
    float last[4]={};
    std::vector<RecoilE> infos;
    bool ok=false;
};
struct NoSpreadSt{
    uintptr_t cfg=0;
    float old[6]={};
    float last[6]={};
    bool ok=false;
};
static NoRecoilSt noRecoilSt;
static NoSpreadSt noSpreadSt;

struct MeleeSt{
    uintptr_t cfg=0;
    float oldEnter=0.0f;
    float oldHold=0.0f;
    float lastEnter=0.0f;
    float lastHold=0.0f;
    bool ok=false;
};
static MeleeSt meleeSt;

// $vb 是 dump 里真正在飞的子弹对象。老的 $sb(Vector3,Vector3) 只改到后面的缓存,
// 没啥实际效果。这四个重载都是拿 Vector3+Quaternion 初始化子弹的,
// 所以在这改朝向才真的能改弹道
typedef void (*fnBInit1)(void* b,void* sg,int32_t a2,int32_t fire,int32_t a4,void* s5,int32_t a6,Vector3 pos,Quaternion rot,void* mi);
typedef void (*fnBInit2)(void* b,void* sg,int32_t a2,uint8_t a3,void* wc,int32_t fire,int32_t a6,void* s7,int32_t a8,Vector3 pos,Quaternion rot,void* mi);
typedef void (*fnBInit3)(void* b,void* sg,void* s2,int32_t fire,int32_t a4,void* s5,int32_t a6,int32_t a7,Vector3 pos,Quaternion rot,uint8_t a10,void* wc,void* mi);
typedef void (*fnBInit4)(void* b,void* sg,int32_t a2,Vector3 pos,Quaternion rot,uint8_t a5,void* s6,void* mi);

static fnBInit1 origB1=nullptr;
static fnBInit2 origB2=nullptr;
static fnBInit3 origB3=nullptr;
static fnBInit4 origB4=nullptr;
static fnGetMS origGetMS=nullptr;
static fnGetSMS origGetSMS=nullptr;
static fnMSDUpd origMsdUpd=nullptr;
static fnMCCSend origMccSend=nullptr;
static fnMSDUpd origJFlyUpd=nullptr;
static fnMSDUpd origJPtUpd=nullptr;
static fnMSDUpd origJSpdUpd=nullptr;
static fnMCCSend origJccSend=nullptr;
static fnMCCSend origBccSend=nullptr;
static fnRCSend origRcSend=nullptr;
static fnRCReport origRcReport=nullptr;
static fnMarkEvt origMarkEvt=nullptr;

static std::atomic<bool> seenMsd(false),seenMsRpt(false);
static std::atomic<bool> seenJmpDet(false),seenJmpRpt(false);
static std::atomic<bool> seenAimRpt(false);
static std::atomic<bool> seenGlbRpt(false),seenFinRpt(false);
static std::atomic<bool> seenMark(false),seenTp(false);

static bool isJumpType(int32_t t);

// 日志队列,UI 那边轮询着取
static void pushLog(const char* fmt,...){
    char msg[320]={};
    va_list ap;
    va_start(ap,fmt);
    vsnprintf(msg,sizeof(msg),fmt,ap);
    va_end(ap);

    std::lock_guard<std::mutex> lk(logMx);
    if(logQ.size()>=kLogMax)logQ.pop_front();
    logQ.emplace_back(msg);
}

bool PopFeatureLog(char* buf,int size){
    if(!buf||size<=1)return false;
    std::lock_guard<std::mutex> lk(logMx);
    if(logQ.empty())return false;
    snprintf(buf,(size_t)size,"%s",logQ.front().c_str());
    logQ.pop_front();
    return true;
}

// CheatType 就是当前 UnityFramework 里的枚举值。这里只拦加速这条路,
// 别的检测该走哪走哪
static bool isAccelType(int32_t t){
    switch(t){
        case 12: // CheckMoveX
        case 15: // CheckRoleMoveSpeed
        case 19: // MoveDistance
        case 20: // MoveDistanceError
        case 22: // RolePointError
        case 23: // RolePointYError
        case 109: // WolfMoveDistance
        case 110: // GunFightMoveDistance
        case 111: // KnockoutMoveDistance
        case 112: // FootBallMoveDistance
        case 133: // MoveInfoMoveCheat
        case 134: // MoveInfoTeleportCheat
        case 135: // MoveInfoMoveBuffCheat
        case 136: // MoveInfoMoveLocalBuffCheat
            return true;
        default:return false;
    }
}

static int64_t nowMs(){
    return (int64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

static bool tpActive(){
    return nowMs()<tpUntil.load(std::memory_order_relaxed);
}

static bool isTpType(int32_t t){
    return isAccelType(t)||isJumpType(t)||
           t==122|| // RoleClientPointError
           t==166|| // MoveTeleportNewCheat
           t==171|| // RoleMoveToPointError
           t==172|| // RolePointOutLimitError
           t==173|| // RolePointClientError
           t==175|| // MoveTeleportExceedCheat
           t==200|| // MoveTeleportOutCheat
           t==201|| // RolePointNoChangeError
           t==203;  // MoveTeleportCannonCheat
}

static bool jumpModOn(){return hjOn||iajOn;}

static bool isJumpType(int32_t t){
    switch(t){
        case 10: // RoleFlyHeightSky
        case 13: // CheckMoveY
        case 14: // CheckMovePath
        case 18: // FlyJumpSpeed
        case 50: // JumpNoLimit
        case 52: // RoleMoveToY
        case 53: // GlideFlyError
        case 55: // FlyJumpStateError
        case 121: // JumpValueCheat
            return true;
        default:return false;
    }
}

static bool isAimType(int32_t t){
    switch(t){
        case 7:  // AimAdsorbError
        case 64: // SausageOutOfAimHit
        case 69: // FirePoint
        case 70: // BulletError
        case 71: // BulletHitDistanceError
        case 72: // BulletCameraMoveError
        case 73: // BulletMoveTimeError
        case 74: // BulletDownHpError
        case 78: // HeightIgnoreHit
        case 79: // HitRolePointError
        case 80: // HitRoleDistanceError
        case 81: // HitPartDistanceError
        case 82: // HitRoleXZPointError
        case 83: // FireRangeError
        case 96: // BulletLock
        case 97: // BulletCd
        case 125: // BulletRaycastInfoCheat
        case 126: // BulletRaycastTimeoutCheat
        case 127: // BulletRaycastReverseCheat
        case 128: // BulletRaycastBePidError
        case 129: // BulletRaycastInfoNoDataCheat
        case 130: // BulletRaycastInfoEmptyCheat
        case 131: // BulletRaycastInfoIDError
        case 132: // BulletRaycastInfoTagError
        case 137: // BulletRaycastTraceXZCheat
        case 138: // BulletRaycastTraceNoWeapon
        case 139: // BulletRaycastTracePickedWeapon
            return true;
        default:return false;
    }
}

// RoleCheat.SendCheat 是所有玩法上报的总口子。这里按开了哪个功能对着类型拦,
// 不是一刀切全屏蔽
static bool isFeatureType(int32_t t){
    if(tpActive()&&isTpType(t))return true;
    if(spdOn&&isAccelType(t))return true;
    if(jumpModOn()&&isJumpType(t))return true;
    if((btOn||aimOn)&&isAimType(t))return true;
    if(noRecoilOn||noSpreadOn){
        switch(t){
            case 21:  // WeaponConfig
            case 84:  // WeaponSOValueCheckError
            case 85:  // WeaponRecoilError
            case 114: // MemoryCheat
                return true;
        }
    }
    if(noCdOn&&(t==59||t==104))return true; // RoleSkillCD / HeavyAttackCDError
    return false;
}

static bool okPt(Vector3 p){
    return std::isfinite(p.x)&&std::isfinite(p.y)&&std::isfinite(p.z)&&
           fabsf(p.x)<1000000.0f&&fabsf(p.y)<1000000.0f&&fabsf(p.z)<1000000.0f;
}

// 地图标点,记下来就能一键传送
static void saveMark(Vector3 p){
    if(!okPt(p))return;
    {
        std::lock_guard<std::mutex> lk(markMx);
        markPos=p;markOk=true;
    }
    if(!seenMark.exchange(true,std::memory_order_relaxed))
        pushLog("已捕获地图标点，可点击传送。");
}

static void hookMarkEvt(void* comp,const MarkEvt* ev,void* mi){
    if(ev)saveMark(ev->findRolePoint);
    if(origMarkEvt)origMarkEvt(comp,ev,mi);
}

// 开了加速就把本地速度采样停了,省得自己跟自己打架
static void hookMsdUpd(void* msd,void* mi){
    if(spdOn){
        if(!seenMsd.exchange(true,std::memory_order_relaxed))
            pushLog("触发移动速度检测，已暂停本地速度采样。");
        return;
    }
    if(origMsdUpd)origMsdUpd(msd,mi);
}

static void hookMccSend(void* ctx,int32_t lv,int32_t t,void* desc,float ratio,void* log,void* mi){
    if(spdOn&&isAccelType(t)){
        if(!seenMsRpt.exchange(true,std::memory_order_relaxed))
            pushLog("触发移动速度/距离检测，已拦截上报（类型 %d）。",t);
        return;
    }
    if(origMccSend)origMccSend(ctx,lv,t,desc,ratio,log,mi);
}

static void noteJmpDet(){
    if(!seenJmpDet.exchange(true,std::memory_order_relaxed))
        pushLog("触发跳跃检测，已暂停本地跳跃采样。");
}

static void hookJFlyUpd(void* d,void* mi){
    if(jumpModOn()){noteJmpDet();return;}
    if(origJFlyUpd)origJFlyUpd(d,mi);
}
static void hookJPtUpd(void* d,void* mi){
    if(jumpModOn()){noteJmpDet();return;}
    if(origJPtUpd)origJPtUpd(d,mi);
}
static void hookJSpdUpd(void* d,void* mi){
    if(jumpModOn()){noteJmpDet();return;}
    if(origJSpdUpd)origJSpdUpd(d,mi);
}

static void hookJccSend(void* ctx,int32_t lv,int32_t t,void* desc,float ratio,void* log,void* mi){
    if(jumpModOn()&&isJumpType(t)){
        if(!seenJmpRpt.exchange(true,std::memory_order_relaxed))
            pushLog("触发跳跃异常检测，已拦截上报（类型 %d）。",t);
        return;
    }
    if(origJccSend)origJccSend(ctx,lv,t,desc,ratio,log,mi);
}

static void hookBccSend(void* ctx,int32_t lv,int32_t t,void* desc,float ratio,void* log,void* mi){
    if((btOn||aimOn)&&isAimType(t)){
        if(!seenAimRpt.exchange(true,std::memory_order_relaxed))
            pushLog("触发瞄准/弹道检测，已拦截上报（类型 %d）。",t);
        return;
    }
    if(origBccSend)origBccSend(ctx,lv,t,desc,ratio,log,mi);
}

static int64_t hookRcSend(void* rc,int32_t lv,int32_t t,void* name,float score,void* err,bool stack,void* mi){
    if(isFeatureType(t)){
        if(!seenGlbRpt.exchange(true,std::memory_order_relaxed))
            pushLog("触发全局功能检测，已在上报入口拦截（类型 %d）。",t);
        return 0;
    }
    if(origRcSend)return origRcSend(rc,lv,t,name,score,err,stack,mi);
    return 0;
}

// sub_1605C40 是进程内最后的处罚分发口,所有直连 RoleCheat 的调用都走这
// (包括那些没过 0x165285C SendCheat 的)
static int64_t hookRcReport(void* st,int64_t lv,int64_t t,void* sub,void* err,int64_t stack,float score){
    if(isFeatureType((int32_t)t)){
        if(!seenFinRpt.exchange(true,std::memory_order_relaxed))
            pushLog("触发最终处罚检测，已拦截分发（类型 %lld）。",(long long)t);
        return 0;
    }
    if(origRcReport)return origRcReport(st,lv,t,sub,err,stack,score);
    return 0;
}

static float dist2(Vector3 a,Vector3 b){
    float dx=a.x-b.x,dy=a.y-b.y,dz=a.z-b.z;
    return dx*dx+dy*dy+dz*dz;
}

static void logBInit(uint32_t bit,NSString* name){
    if((bInitMask.fetch_or(bit)&bit)==0)
        NSLog(@"[UnityESP] Bullet init %@ reached",name);
}

// 静默子弹:只改本地枪口打出去的那发,朝向按目标算
static bool buildSilentAim(Vector3 shootPos,Quaternion* outRot){
    // 子弹朝向替换只属于子弹追踪。自瞄走 CameraController 的 yaw/pitch,
    // 绝对不能进这条路径
    if(!outRot||!btOn)return false;

    Vector3 tgt={0,0,0},sh={0,0,0};
    {
        std::lock_guard<std::mutex> lk(btMx);
        if(!btShOk)return false;
        sh=btShPos;
        if(!btTgtOk)return false;
        tgt=btTgt;
    }

    // 远程玩家的子弹别碰。本地枪口应该离本地角色根节点很近
    float rad=fmaxf(1.0f,btRad);
    if(dist2(shootPos,sh)>rad*rad)return false;

    float dx=tgt.x-shootPos.x,dy=tgt.y-shootPos.y,dz=tgt.z-shootPos.z;
    float hor=sqrtf(dx*dx+dz*dz);
    if(hor<0.001f&&fabsf(dy)<0.001f)return false;

    float yaw=atan2f(dx,dz);
    float pitch=-atan2f(dy,hor);
    float hy=yaw*0.5f,hp=pitch*0.5f;
    float sy=sinf(hy),cy=cosf(hy),sx=sinf(hp),cx=cosf(hp);
    *outRot={cy*sx,sy*cx,-sy*sx,cy*cx};

    if(!bRotSeen.exchange(true))
        NSLog(@"[UnityESP] Silent aim replaced bullet spawn rotation");
    return true;
}

// 四个重载全部改朝向,谁进来都行
static void hookB1(void* b,void* sg,int32_t a2,int32_t fire,int32_t a4,void* s5,int32_t a6,Vector3 pos,Quaternion rot,void* mi){
    logBInit(1u<<0,@"$ob");
    buildSilentAim(pos,&rot);
    if(origB1)origB1(b,sg,a2,fire,a4,s5,a6,pos,rot,mi);
}
static void hookB2(void* b,void* sg,int32_t a2,uint8_t a3,void* wc,int32_t fire,int32_t a6,void* s7,int32_t a8,Vector3 pos,Quaternion rot,void* mi){
    logBInit(1u<<1,@"$Ob");
    buildSilentAim(pos,&rot);
    if(origB2)origB2(b,sg,a2,a3,wc,fire,a6,s7,a8,pos,rot,mi);
}
static void hookB3(void* b,void* sg,void* s2,int32_t fire,int32_t a4,void* s5,int32_t a6,int32_t a7,Vector3 pos,Quaternion rot,uint8_t a10,void* wc,void* mi){
    logBInit(1u<<2,@"$pb");
    buildSilentAim(pos,&rot);
    if(origB3)origB3(b,sg,s2,fire,a4,s5,a6,a7,pos,rot,a10,wc,mi);
}
static void hookB4(void* b,void* sg,int32_t a2,Vector3 pos,Quaternion rot,uint8_t a5,void* s6,void* mi){
    logBInit(1u<<3,@"$Pb");
    buildSilentAim(pos,&rot);
    if(origB4)origB4(b,sg,a2,pos,rot,a5,s6,mi);
}

// ===== 全局状态 =====
static BOOL inited=NO;
static BOOL espOn=NO;
static uintptr_t ub=0;

// ===== 读内存的,读不到就当没有 =====
static bool rd(uintptr_t a,void* out,size_t n){
    if(!a)return false;
    vm_size_t got=n;
    kern_return_t r=vm_read_overwrite(mach_task_self(),(vm_address_t)a,n,(vm_address_t)out,&got);
    return r==KERN_SUCCESS&&got==n;
}
static uintptr_t rdp(uintptr_t a){
    uintptr_t v=0;
    if(rd(a,&v,sizeof(v)))return v;
    return 0;
}
static bool wr(uintptr_t a,const void* d,size_t n){
    if(!a||!d||!n)return false;
    return vm_write(mach_task_self(),(vm_address_t)a,(vm_offset_t)d,(mach_msg_type_number_t)n)==KERN_SUCCESS;
}

static float spdOverride(void* rlc,float orig){
    if(!spdOn||!rlc||!std::isfinite(orig)||orig<=0.0f)return orig;

    // 本地速度表能写进去以后,getter 拿到的已经是乘过的值了,别再乘一次
    if(spdPatchSeen.load(std::memory_order_acquire))return orig;

    // 优先信接收者指针本身。getMoveSpeed/getStateMoveSpeed 是实例方法,
    // 复活或者 RoleLogicClient 重建的时候比 RoleClient 容易失败
    uintptr_t local=spdLocalRLC.load(std::memory_order_acquire);
    uintptr_t rc=rdp((uintptr_t)rlc+0x80);
    uintptr_t lbr=spdLocalBR.load(std::memory_order_acquire);
    bool mine=(local&&(uintptr_t)rlc==local)||(lbr&&rc==lbr);
    if(!mine&&(local||lbr))return orig;

    float v=fminf(100.0f,orig*spdMul);
    if(!spdHookSeen.exchange(true))
        pushLog("加速读取入口已命中：倍率 %.1f。",spdMul);
    return v;
}

static float hookGetMS(void* rlc,void* mi){
    float v=origGetMS?origGetMS(rlc,mi):0.0f;
    return spdOverride(rlc,v);
}
static float hookGetSMS(void* rlc,void* mi){
    float v=origGetSMS?origGetSMS(rlc,mi):0.0f;
    return spdOverride(rlc,v);
}

// 取瞄准点(头/脊椎)
static bool getAimPt(uintptr_t rl,int part,Vector3* out){
    if(!rl||!out||!pGetPos)return false;

    // 当前 dump:
    // BattleRoleLogic.roleLogicClient(+0xAD8)
    // -> RoleLogicClient.RoleClient(+0x80)
    // -> BattleRole.MyRoleControl(+0x230)
    // -> RoleControl.AnimatorControl(+0x48)
    // -> AnimatorControl.Head(+0xE8) / Spine(+0x190)
    // RoleNet 的 transform 是角色根节点不是头骨,拿它加个固定 Y 也只是落胸口附近
    uintptr_t rlc=rdp(rl+0xAD8);
    uintptr_t br=rlc?rdp(rlc+0x80):0;
    uintptr_t ctl=br?rdp(br+0x230):0;
    uintptr_t ani=ctl?rdp(ctl+0x48):0;
    uintptr_t tf=ani?rdp(ani+((part==0)?0xE8:0x190)):0;
    if(!tf)return false;

    Vector3 p=pGetPos((void*)tf);
    if(!okPt(p))return false;
    *out=p;
    return true;
}

// 简单测一下目标速度,做预判用(低通一下,免得被传送吓到)
static Vector3 updTgtVel(uintptr_t role,int part,Vector3 p){
    auto now=std::chrono::steady_clock::now();
    if(!pred.ok||pred.role!=role||pred.part!=part){
        pred.role=role;pred.part=part;pred.lastP=p;pred.vel={0,0,0};
        pred.lastT=now;pred.ok=true;
        return pred.vel;
    }

    float dt=std::chrono::duration<float>(now-pred.lastT).count();
    if(dt>=0.003f&&dt<=0.30f){
        Vector3 v={(p.x-pred.lastP.x)/dt,(p.y-pred.lastP.y)/dt,(p.z-pred.lastP.z)/dt};
        float s2=v.x*v.x+v.y*v.y+v.z*v.z;
        // 传送、复活、切目标都会冒出离谱速度,直接扔掉
        if(s2<=10000.0f){
            constexpr float kBlend=0.35f;
            pred.vel.x+=(v.x-pred.vel.x)*kBlend;
            pred.vel.y+=(v.y-pred.vel.y)*kBlend;
            pred.vel.z+=(v.z-pred.vel.z)*kBlend;
        }else pred.vel={0,0,0};
    }else if(dt>0.30f){
        pred.vel={0,0,0};
    }
    pred.lastP=p;pred.lastT=now;
    return pred.vel;
}

static bool readBallistics(void* cam,float* outSpeed,float* outGravity){
    if(!cam||!outSpeed||!outGravity)return false;

    // 当前 dump:
    // CameraController.LockRole(+0xD0) -> BattleRole.UserWeapon(+0x4B8)
    // -> WeaponControl.MySOWeaponControl(+0x48)
    // -> SOWeaponControl.bulletSpeedAndGravity(+0x160)
    // -> 第一个 BulletSpeedAndGravity(+0x20)
    uintptr_t br=rdp((uintptr_t)cam+0xD0);
    uintptr_t wp=br?rdp(br+0x4B8):0;
    uintptr_t cfg=wp?rdp(wp+0x48):0;
    uintptr_t arr=cfg?rdp(cfg+0x160):0;
    uintptr_t bs=arr?rdp(arr+0x20):0;
    if(!bs)return false;

    float g=0.0f,sp=0.0f;
    if(!rd(bs+0x10,&g,sizeof(g))||!rd(bs+0x14,&sp,sizeof(sp)))return false;
    if(!std::isfinite(g)||!std::isfinite(sp)||sp<1.0f||sp>10000.0f||fabsf(g)>1000.0f)return false;

    *outSpeed=sp;*outGravity=g;
    return true;
}

static bool buildPredPt(void* cam,Vector3 tp,Vector3 tv,Vector3* out){
    if(!cam||!out)return false;

    uintptr_t ct=rdp((uintptr_t)cam+0x40);
    if(!ct)return false;
    Vector3 cp=pGetPos((void*)ct);

    float sp=0.0f,g=0.0f;
    if(!readBallistics(cam,&sp,&g))return false;

    Vector3 pd=tp;
    float tt=0.0f;
    // 迭代两次,把目标移动导致的多出来那点距离也算进去
    for(int i=0;i<2;++i){
        float dx=pd.x-cp.x,dy=pd.y-cp.y,dz=pd.z-cp.z;
        float d=sqrtf(dx*dx+dy*dy+dz*dz);
        tt=fminf(2.5f,d/sp);
        pd.x=tp.x+tv.x*tt*aimPred;
        pd.y=tp.y+tv.y*tt*aimPred;
        pd.z=tp.z+tv.z*tt*aimPred;
    }
    // 下坠补偿,往上抬一点
    pd.y+=0.5f*fabsf(g)*tt*tt*aimPred;
    *out=pd;
    return true;
}

// ===== 辅助 =====
uintptr_t GetUnityModuleBase(){
    for(uint32_t i=0;i<_dyld_image_count();i++){
        const char* n=_dyld_get_image_name(i);
        if(n&&strstr(n,"UnityFramework"))
            return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

// ===== 公共接口 =====
void InitESP(){
    if(inited)return;

    ub=GetUnityModuleBase();
    if(!ub){
        NSLog(@"[UnityESP] Failed to find UnityFramework!");
        return;
    }
    NSLog(@"[UnityESP] UnityFramework base: 0x%lx",ub);

    pGetPos=(fnGetPos)(ub+0xA8B2BAC);
    pSetPos=(fnSetPos)(ub+0xA8B2C74);
    pV3ToByte=(fnV3ToByte)(ub+0x8D80C48);
    pCmdSync=(fnCmdSync)(ub+0x8D80FC0);
    pGetComp=(fnGetComp)(ub+0xA89BF30);
    pStrNew=(fnStrNew)dlsym(RTLD_DEFAULT,"il2cpp_string_new");
    pCamMain=(fnCamMain)(ub+0xA84B8E4);
    pGetFov=(fnGetFov)(ub+0xA846D94);
    pSetFov=(fnSetFov)(ub+0xA846DE4);
    pGetSG=(fnGetSG)(ub+0x2AEA064);
    pSGMyCam=(fnSGMyCam)(ub+0x2394264);
    pIsFire=(fnIsFire)(ub+0x38D7E3C);

    // RoleLogicClient.getMoveSpeed() 才是本地移动真正吃的那份结果,
    // 老的 BuffAddMoveSpeed 字段根本不在链上
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x388C420,(void*)hookGetMS,(void**)&origGetMS);
    // getStateMoveSpeed 是状态机那份,只挂 getMoveSpeed 这版根本不提速
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x388D330,(void*)hookGetSMS,(void**)&origGetSMS);
    // 这版本地速度采样走 SausageRoleCheatMove -> MoveSpeedDetector,
    // 开功能的时候只停这一个检测器,别的反作弊路径不动
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x1644CBC,(void*)hookMsdUpd,(void**)&origMsdUpd);
    // 对应的上报分发,条件过滤只覆盖那三个速度/距离类型
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x1642FA8,(void*)hookMccSend,(void**)&origMccSend);
    // 高跳和空中无限跳命中 SausageRoleCheatJump 里的三个检测器,
    // 只在开了跳功能的时候停,关了马上恢复
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x163A700,(void*)hookJFlyUpd,(void**)&origJFlyUpd);
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x163C7A0,(void*)hookJPtUpd,(void**)&origJPtUpd);
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x163DD08,(void*)hookJSpdUpd,(void**)&origJSpdUpd);
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x163A58C,(void*)hookJccSend,(void**)&origJccSend);
    // 子弹追踪/自瞄只拦对应的两个战斗上报,墙体伤害那些照走
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x15F9110,(void*)hookBccSend,(void**)&origBccSend);
    // 玩法上报总口子。这里故意做成带条件的,没开功能的检测还是走原路
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x165285C,(void*)hookRcSend,(void**)&origRcSend);
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x1605C40,(void*)hookRcReport,(void**)&origRcReport);
    // BattleRoleMarkComponent 拿到的是已经定好的地图标点,
    // MarkSportEvent.FindRolePoint 就是世界坐标传送点
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x12D9244,(void*)hookMarkEvt,(void**)&origMarkEvt);
    NSLog(@"[UnityESP] Movement speed hooks: move=%p state=%p",origGetMS,origGetSMS);
    pushLog("检测拦截模块已加载，等待游戏事件。");

    // $vb 的子弹初始化重载
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x2442150,(void*)hookB1,(void**)&origB1);
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x244268C,(void*)hookB2,(void**)&origB2);
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x244222C,(void*)hookB3,(void**)&origB3);
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",
        0x24438A4,(void*)hookB4,(void**)&origB4);
    NSLog(@"[UnityESP] Bullet init hooks: ob=%p Ob=%p pb=%p Pb=%p",origB1,origB2,origB3,origB4);

    // 相机矩阵四个地址全挂上,看哪个能进
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",0xA849E70,
        (void*)hookW2C,(void**)&origW2C);
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",0xA84A018,
        (void*)hookProj,(void**)&origProj);
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",0xA849EEC,
        (void*)hookW2Ci,(void**)&origW2Ci);
    静态替换函数(@"Frameworks/UnityFramework.framework/UnityFramework",0xA84A094,
        (void*)hookProji,(void**)&origProji);

    inited=YES;
    NSLog(@"[UnityESP] ESP initialized successfully");
}

void SetESPEnabled(BOOL en){espOn=en;}

int GetPlayerCount(){
    if(!inited||!pGetSG)return 0;
    void* sg=pGetSG();
    if(!sg)return 0;
    uintptr_t rl=rdp((uintptr_t)sg+0x50);
    if(!rl)return 0;
    int32_t n=0;
    rd(rl+0x18,&n,sizeof(n));
    return n;
}

void RefreshPlayers(){
    NSLog(@"[UnityESP] Player count: %d",GetPlayerCount());
}

void* GetDebugCamera(){
    if(!inited||!pCamMain)return nullptr;
    return pCamMain();
}

// 关广角就把 FOV 还原回去
static void restoreWide(){
    if(fovPatch.ok&&fovPatch.cam&&pCamMain&&pGetFov&&pSetFov){
        void* cam=pCamMain();
        if(cam==fovPatch.cam){
            float cur=pGetFov(cam);
            if(std::isfinite(cur)&&fabsf(cur-fovPatch.lastFov)<=0.05f)
                pSetFov(cam,fovPatch.oldFov);
        }
    }
    fovPatch={};
}

void SetWideViewEnabled(bool en){
    if(wideOn==en)return;
    wideOn=en;
    if(!en)restoreWide();
}

void SetWideViewValue(float v){wideVal=fmaxf(30.0f,fminf(120.0f,v));}

void UpdateWideView(){
    if(!wideOn){restoreWide();return;}
    if(!inited||!pCamMain||!pGetFov||!pSetFov){fovPatch={};return;}

    void* cam=pCamMain();
    if(!cam){fovPatch={};return;}

    // 切场景换相机以后别再去调旧的 Unity 对象
    if(fovPatch.ok&&fovPatch.cam!=cam)fovPatch={};

    float cur=pGetFov(cam);
    if(!std::isfinite(cur)||cur<1.0f||cur>179.0f){fovPatch={};return;}

    if(!fovPatch.ok){
        fovPatch.cam=cam;fovPatch.oldFov=cur;fovPatch.lastFov=cur;fovPatch.ok=true;
    }else if(fabsf(cur-fovPatch.lastFov)>0.05f){
        // 游戏自己改了 FOV(开镜/冲刺/特效),以它为准,
        // 别用固定值把过渡覆盖掉
        fovPatch.oldFov=cur;
    }

    // 滑条给的就是最终 FOV。别去乘游戏当前值,
    // 不然每次相机过渡都会把上一次的结果叠进去,越搞越离谱
    float want=fmaxf(30.0f,fminf(120.0f,wideVal));
    pSetFov(cam,want);
    fovPatch.lastFov=want;
}

void GetDebugInfo(char* buf,int size){
    if(!inited){snprintf(buf,size,"NOT INITIALIZED");return;}

    void* sg=pGetSG?pGetSG():nullptr;
    void* cam=pCamMain?pCamMain():nullptr;

    int32_t cnt=0,my=0;
    if(sg){
        uintptr_t rl=rdp((uintptr_t)sg+0x50);
        if(rl)rd(rl+0x18,&cnt,sizeof(cnt));
        rd((uintptr_t)sg+0x38,&my,sizeof(my));
    }

    // 矩阵就从 hook 抄出来的全局里读
    float m0=0,m5=0,m10=0,m15=0;
    if(vmOk){m0=vmMtx.m[0];m5=vmMtx.m[5];m10=vmMtx.m[10];m15=vmMtx.m[15];}

    // 拿第一个角色试一下 transform 和投影
    float px=0,py=0,pz=0,sx=-1,sy=-1;
    if(sg&&cnt>0){
        uintptr_t rl=rdp((uintptr_t)sg+0x50);
        uintptr_t items=rdp(rl+0x10);
        if(items){
            int ti=(my==0)?1:0;
            if(ti<cnt){
                uintptr_t role=rdp(items+0x20+ti*8);
                if(role){
                    uintptr_t rn=rdp(role+0x730);
                    if(rn){
                        uintptr_t tf=rdp(rn+0x40);
                        if(tf){
                            Vector3 p=pGetPos((void*)tf);
                            px=p.x;py=p.y;pz=p.z;
                            if(vmOk&&pmOk){
                                float vp[16];
                                mulMat(vmMtx.m,pmMtx.m,vp);
                                Vector2 sc;
                                float w=0.0f,h=0.0f;
                                OverlayGetCanvasSize(&w,&h);
                                if(w2s(p,vp,w,h,&sc)){sx=sc.x;sy=sc.y;}
                            }
                        }
                    }
                }
            }
        }
    }

    snprintf(buf,size,
        "Base: 0x%lx\n"
        "StartGame: %p  Camera: %p\n"
        "Roles: %d  MyIdx: %d\n"
        "Hook: V=%d P=%d\n"
        "Matrix[0,5,10,15]: %.2f, %.2f, %.2f, %.2f\n"
        "Pos[0]: %.1f, %.1f, %.1f\n"
        "Screen[0]: %.1f, %.1f",
        ub,sg,cam,cnt,my,(int)vmOk,(int)pmOk,m0,m5,m10,m15,px,py,pz,sx,sy);
}

void GetPlayerBotCount(int* outPlayers,int* outBots){
    if(!outPlayers||!outBots)return;
    *outPlayers=0;*outBots=0;
    if(!inited||!pGetSG)return;

    void* sg=pGetSG();
    if(!sg)return;

    // StartGame.RoleList -> List._items -> List._size
    uintptr_t rl=rdp((uintptr_t)sg+0x50);
    if(!rl)return;
    uintptr_t items=rdp(rl+0x10);
    if(!items)return;
    int32_t n=0;
    if(!rd(rl+0x18,&n,sizeof(n))||n<=0||n>200)return;

    int32_t my=-1;
    if(!rd((uintptr_t)sg+0x38,&my,sizeof(my))||my<0||my>=n)return;

    uintptr_t myRole=rdp(items+0x20+(uintptr_t)my*sizeof(uintptr_t));
    if(!myRole)return;

    int64_t myTeam=0;
    if(!rd(myRole+0x7A0,&myTeam,sizeof(myTeam)))return;

    for(int32_t i=0;i<n;++i){
        if(i==my)continue; // 跳过自己
        uintptr_t role=rdp(items+0x20+(uintptr_t)i*sizeof(uintptr_t));
        if(!role)continue;

        int64_t team=0;
        if(!rd(role+0x7A0,&team,sizeof(team)))continue;
        // myTeam 必须非 0。不然游戏还没初始化队伍号的时候,
        // 所有 team==0 的人都会被当队友过滤掉
        if(myTeam!=0&&team==myTeam)continue;

        // 有 AILogic 或者 aiType 非 0 就是 bot
        int32_t aiType=0;
        rd(role+0x8A0,&aiType,sizeof(aiType));
        uintptr_t aiLogic=rdp(role+0xB30);
        if(aiLogic!=0||aiType!=0)++(*outBots);
        else ++(*outPlayers);
    }
}

// 矩阵乘法:VP = P * V
static void mulMat(const float* a,const float* b,float* out){
    for(int i=0;i<4;i++)
        for(int j=0;j<4;j++)
            out[i*4+j]=a[i*4+0]*b[0*4+j]+a[i*4+1]*b[1*4+j]+
                       a[i*4+2]*b[2*4+j]+a[i*4+3]*b[3*4+j];
}

// 跟源码一样的 WorldToScreen
static bool w2s(Vector3 wp,float* mt,int w,int h,Vector2* out){
    float cw=mt[3]*wp.x+mt[7]*wp.y+mt[11]*wp.z+mt[15];
    if(cw<=0.01f)return false;

    float iw=1.0f/cw;
    out->x=w*0.5f+(mt[0]*wp.x+mt[4]*wp.y+mt[8]*wp.z+mt[12])*iw*w*0.5f;
    out->y=h*0.5f-(mt[1]*wp.x+mt[5]*wp.y+mt[9]*wp.z+mt[13])*iw*h*0.5f;
    return true;
}

static bool readHp(uintptr_t rl,float* out){
    if(!rl||!out)return false;

    // 当前 dump:BattleRoleLogic.roleLogicClient(+0xAD8),
    // RoleLogicClient.<LocalHp>k__BackingField(+0xB0)。
    // 这版 LocalHp 是 0..100,顺手兼容 0..1,免得血条满天飞
    uintptr_t rlc=rdp(rl+0xAD8);
    if(!rlc)return false;

    float hp=0.0f;
    if(!rd(rlc+0xB0,&hp,sizeof(hp))||!std::isfinite(hp))return false;

    float r=hp;
    if(hp>1.0f)r=hp/100.0f;
    *out=fmaxf(0.0f,fminf(1.0f,r));
    return true;
}

void RenderESP(bool showNames,bool showDistance,bool showBoxes,
               bool showLines,int lineOrigin,float maxDistance,
               float offsetX,float offsetY,float offsetZ,
               float boxColor[4],float textColor[4]){
    (void)offsetY;(void)offsetZ;

    if(!inited||!espOn)return;

    void* sg=pGetSG();
    if(!sg)return;
    void* cam=pCamMain();
    if(!cam)return;

    // 矩阵是 hook 回调里存的,游戏每帧自己调的时候会更新
    if(!vmOk||!pmOk)return;

    float vp[16];
    mulMat(vmMtx.m,pmMtx.m,vp);

    int32_t my=0;
    rd((uintptr_t)sg+0x38,&my,sizeof(my));

    // StartGame.RoleList(0x50) -> List<BattleRoleLogic>
    uintptr_t rl=rdp((uintptr_t)sg+0x50);
    if(!rl)return;
    uintptr_t items=rdp(rl+0x10); // List._items
    if(!items)return;
    int32_t n=0;                  // List._size
    rd(rl+0x18,&n,sizeof(n));
    if(n<=0||n>200)return;

    float cw=0.0f,ch=0.0f;
    OverlayGetCanvasSize(&cw,&ch);
    if(cw<=1.0f||ch<=1.0f)return;

    // 本地玩家位置,用来算距离
    Vector3 myPos={0,0,0};
    if(my>=0&&my<n){
        uintptr_t r=rdp(items+0x20+my*8);
        if(r){
            uintptr_t rn=rdp(r+0x730);
            if(rn){
                uintptr_t tf=rdp(rn+0x40);
                if(tf)myPos=pGetPos((void*)tf);
            }
        }
    }

    // IL2CPP 数组元素从 0x20 开始
    int64_t myTeam=0;
    if(my>=0&&my<n){
        uintptr_t r=rdp(items+0x20+my*8);
        if(r)rd(r+0x7A0,&myTeam,sizeof(myTeam));
    }

    for(int32_t i=0;i<n;i++){
        if(i==my)continue; // 自己跳过

        uintptr_t role=rdp(items+0x20+i*8);
        if(!role)continue;

        int64_t team=0;
        rd(role+0x7A0,&team,sizeof(team));
        if(team!=0&&team==myTeam)continue; // 队友跳过

        // bot 判定:BattleRoleLogic.myType(0x8A0) + roleAILogic(0xB30)
        int32_t aiType=0;
        rd(role+0x8A0,&aiType,sizeof(aiType));
        uintptr_t aiLogic=rdp(role+0xB30);
        bool isBot=aiLogic!=0||aiType!=0;

        // bot 灰色,真人用设置里的颜色
        float dc[4];
        if(isBot){
            dc[0]=0.70f;dc[1]=0.74f;dc[2]=0.78f;dc[3]=0.48f;
        }else{
            dc[0]=boxColor[0];dc[1]=boxColor[1];dc[2]=boxColor[2];
            dc[3]=fminf(boxColor[3],0.68f);
        }

        // BattleRoleLogic.$O -> RoleNet(0x730) -> $a -> Transform(0x40)
        uintptr_t rn=rdp(role+0x730);
        if(!rn)continue;
        uintptr_t tf=rdp(rn+0x40);
        if(!tf)continue;

        Vector3 wp=pGetPos((void*)tf);

        float dx=wp.x-myPos.x,dy=wp.y-myPos.y,dz=wp.z-myPos.z;
        float d=sqrtf(dx*dx+dy*dy+dz*dz);
        if(d>maxDistance||d<1.0f)continue;

        // 这版 RoleNet 根节点比旧版低一点,拿世界单位校一下,
        // 远近距离上框子都能按透视自然缩放
        Vector3 foot=wp;
        foot.y-=0.35f;

        // 头部投影点:脚点往上 1.0 个世界单位
        Vector3 head=foot;
        head.y+=1.0f;

        // 脚和头分别投影,跟源码的 FootWorldToScreen / HeadWorldToScreen 一样
        Vector2 fs,hs;
        if(!w2s(foot,vp,cw,ch,&fs))continue;
        if(!w2s(head,vp,cw,ch,&hs))continue;

        // 跟参考实现一样按距离缩框,下边缘就落在投影出来的脚点上,
        // 不做固定像素的 Y 修正
        float hh=fabsf(hs.y-fs.y);
        if(hh<2.0f)continue;
        float hw=hh*0.55f;
        float cx=hs.x+offsetX;
        float top=hs.y-hh;
        float bot=hs.y+hh;
        float left=cx-hw;
        float right=cx+hw;

        if(right<0||left>cw||bot<0||top>ch)continue;

        if(showBoxes)
            OverlayDrawCornerBox(left,top,right,bot,dc[0],dc[1],dc[2],dc[3]);

        // 血条放框左边,底跟脚点对齐,别压住名字
        float hp=0.0f;
        if(readHp(role,&hp)){
            const float bw=3.5f,gap=4.0f;
            float bl=left-gap-bw;
            float bh=bot-top;
            float fillTop=bot-bh*hp;

            OverlayFillRoundedRect(bl,top,bl+bw,bot,1.5f,0.01f,0.02f,0.03f,0.56f);
            if(hp>0.0f){
                float rr=hp<0.35f?0.96f:(hp<0.65f?1.0f:0.28f);
                float gg=hp<0.35f?0.20f:(hp<0.65f?0.78f:0.92f);
                float bb=hp<0.35f?0.16f:0.22f;
                OverlayFillRoundedRect(bl,fillTop,bl+bw,bot,1.5f,rr,gg,bb,0.90f);
            }
            OverlayDrawRoundedRect(bl,top,bl+bw,bot,1.5f,1.0f,1.0f,1.0f,0.20f,0.7f);
        }

        // 射线:跟源码一样从 (宽/2, 50) 拉到目标头顶
        if(showLines){
            Vector3 lp=wp;
            lp.y+=2.7f;
            Vector2 ls;
            if(w2s(lp,vp,cw,ch,&ls)){
                float startY=ch-4.0f;
                if(lineOrigin==0)startY=4.0f;
                else if(lineOrigin==1)startY=ch*0.5f;
                OverlayDrawLine(cw*0.5f,startY,cx,top,0.0f,0.0f,0.0f,0.30f,2.4f);
                OverlayDrawLine(cw*0.5f,startY,cx,top,dc[0],dc[1],dc[2],
                                fminf(dc[3],0.45f),1.0f);
            }
        }

        if(showNames||showDistance){
            // BattleRoleLogic.NickName(0x760) -> IL2CPP String
            uintptr_t nick=rdp(role+0x760);

            char name[128]={0};
            if(nick&&showNames){
                // String:长度在 +0x10,内容是 UTF-16 在 +0x14
                int32_t len=0;
                rd(nick+0x10,&len,sizeof(len));
                if(len>0&&len<=32){
                    char16_t wb[33]={0};
                    if(rd(nick+0x14,wb,len*2)){
                        // 交给 UIKit/NSString 转,代理对也能处理。
                        // 之前手写那套碰到有些名字就乱码
                        NSString* s=[[NSString alloc]initWithCharacters:(const unichar*)wb length:(NSUInteger)len];
                        [s getCString:name maxLength:sizeof(name) encoding:NSUTF8StringEncoding];
                    }
                }
            }

            char text[256];
            if(showNames&&showDistance&&name[0])
                snprintf(text,sizeof(text),"%s%s [%.0fm]",name,isBot?"(Bot)":"",d);
            else if(showNames&&name[0])
                snprintf(text,sizeof(text),"%s%s",name,isBot?"(Bot)":"");
            else
                snprintf(text,sizeof(text),"[%.0fm]",d);

            // 用原生 UIKit 画字,不会把 ImGui 图集搞花,中文数字都稳
            float tw=0.0f,th=0.0f;
            OverlayMeasureText(text,11.5f,&tw,&th);
            const float padX=6.0f,padY=3.0f;
            float tx=cx-tw*0.5f;
            float ty=top-th-padY*2.0f-5.0f;
            float bl=tx-padX,bt=ty-padY,br=tx+tw+padX,bb=ty+th+padY;

            OverlayFillRoundedRect(bl,bt,br,bb,4.0f,0.02f,0.03f,0.05f,0.42f);
            OverlayDrawRoundedRect(bl,bt,br,bb,4.0f,1.0f,1.0f,1.0f,0.12f,0.7f);
            OverlayDrawLine(bl+3.0f,bb-1.0f,br-3.0f,bb-1.0f,dc[0],dc[1],dc[2],0.52f,1.0f);
            OverlayDrawText(text,tx+0.8f,ty+0.8f,11.5f,0.0f,0.0f,0.0f,0.48f);
            if(isBot)
                OverlayDrawText(text,tx,ty,11.5f,0.86f,0.88f,0.90f,0.82f);
            else
                OverlayDrawText(text,tx,ty,11.5f,textColor[0],textColor[1],textColor[2],
                                fminf(textColor[3],0.88f));
        }
    }
}

// ===== 自瞄设置 =====
void SetAimbotEnabled(bool en){
    aimOn=en;
    if(!en)aimTgtOk=false;
}
void SetAimbotSpeed(float s){aimSpd=fmaxf(1.0f,fminf(30.0f,s));}
void SetAimbotFOV(float f){aimFov=f;}
void SetAimbotTarget(int t){aimPart=t;pred.ok=false;}
void SetAimbotMode(int m){aimMode=m;}
void SetAimbotAlgorithm(int a){aimAlgo=(a==1)?1:0;pred.ok=false;}
void SetAimbotPredictionStrength(float s){aimPred=fmaxf(0.0f,fminf(2.0f,s));}

static void restoreSpdPatch(){
    if(!spdPatch.ok||!spdPatch.rbd){spdPatch={};return;}
    for(size_t i=0;i<kSpdCnt;++i){
        uintptr_t a=spdPatch.rbd+kSpdOff[i];
        float cur=0.0f;
        if(rd(a,&cur,sizeof(cur))&&std::isfinite(cur)&&
           fabsf(cur-spdPatch.last[i])<=0.001f)
            wr(a,&spdPatch.old[i],sizeof(spdPatch.old[i]));
    }
    spdPatch={};
}

static void applySpdPatch(uintptr_t rbd){
    if(spdPatch.ok&&spdPatch.rbd!=rbd){
        restoreSpdPatch();
        spdPatchSeen.store(false,std::memory_order_release);
    }
    if(!rbd){
        spdPatchSeen.store(false,std::memory_order_release);
        return;
    }

    if(!spdPatch.ok){
        SpdPatch st={};
        st.rbd=rbd;
        for(size_t i=0;i<kSpdCnt;++i){
            float v=0.0f;
            if(!rd(rbd+kSpdOff[i],&v,sizeof(v))||!std::isfinite(v)||v<0.0f||v>100.0f)
                return;
            st.old[i]=v;st.last[i]=v;
        }
        st.ok=true;
        spdPatch=st;
    }

    bool wrote=false;
    for(size_t i=0;i<kSpdCnt;++i){
        uintptr_t a=spdPatch.rbd+kSpdOff[i];
        float cur=0.0f;
        if(!rd(a,&cur,sizeof(cur))||!std::isfinite(cur)||cur<0.0f||cur>100.0f)
            continue;
        if(fabsf(cur-spdPatch.last[i])>0.001f)spdPatch.old[i]=cur;

        float want=fmaxf(0.0f,fminf(100.0f,spdPatch.old[i]*spdMul));
        if(wr(a,&want,sizeof(want))){
            spdPatch.last[i]=want;
            wrote=true;
        }
    }

    if(wrote&&!spdPatchSeen.exchange(true))
        pushLog("加速数据表已写入：%zu 项，倍率 %.1f。",kSpdCnt,spdMul);
}

void SetPlayerSpeedEnabled(bool en){
    bool changed=spdOn!=en;
    spdOn=en;
    if(en&&changed){
        // 每次重新开都算一轮新的排查,把这些 latch 清掉,
        // 日志页才能看出这版到底走没走到本地移动链路
        spdHookSeen.store(false,std::memory_order_relaxed);
        spdPatchSeen.store(false,std::memory_order_relaxed);
        seenMsd.store(false,std::memory_order_relaxed);
        seenMsRpt.store(false,std::memory_order_relaxed);
        seenGlbRpt.store(false,std::memory_order_relaxed);
        seenFinRpt.store(false,std::memory_order_relaxed);
        pushLog("加速已开启：倍率 %.1f，等待本地移动链路。",spdMul);
    }
    if(!en){
        restoreSpdPatch();
        spdLocalBR.store(0,std::memory_order_release);
        spdLocalRLC.store(0,std::memory_order_release);
        spdHookSeen.store(false,std::memory_order_relaxed);
        spdPatchSeen.store(false,std::memory_order_relaxed);
        if(changed)pushLog("加速已关闭：本地速度表已恢复。");
    }
}

void SetPlayerSpeedMultiplier(float m){spdMul=fmaxf(1.0f,fminf(5.0f,m));}

void UpdatePlayerSpeed(){
    if(!inited||!spdOn){
        restoreSpdPatch();
        spdLocalBR.store(0,std::memory_order_release);
        spdLocalRLC.store(0,std::memory_order_release);
        return;
    }
    uintptr_t rlc=getLocalRLC();
    spdLocalRLC.store(rlc,std::memory_order_release);
    spdLocalBR.store(rlc?rdp(rlc+0x80):0,std::memory_order_release);

    // getter hook 留作第二条路。这条直接改 SORoleBaseData 的,
    // 覆盖那些先把值缓存下来再调 getter 的移动状态,
    // 也就是老版本只挂 hook 看不到提速的原因
    applySpdPatch(getLocalRBD());
}

static void restoreHjPatch(){
    if(!hjPatch.ok||!hjPatch.rbd){hjPatch={};return;}
    for(int i=0;i<4;++i){
        uintptr_t a=hjPatch.rbd+kJmpOff[i];
        float cur=0.0f;
        if(rd(a,&cur,sizeof(cur))&&std::isfinite(cur)&&
           fabsf(cur-hjPatch.last[i])<=0.001f)
            wr(a,&hjPatch.old[i],sizeof(hjPatch.old[i]));
    }
    hjPatch={};
}

void SetHighJumpEnabled(bool en){
    if(hjOn==en)return;
    hjOn=en;
    if(!en)restoreHjPatch();
}
void SetHighJumpMultiplier(float m){hjMul=fmaxf(1.0f,fminf(10.0f,m));}

void UpdateHighJump(){
    if(!inited||!hjOn||!pGetSG){
        if(!hjOn)restoreHjPatch();
        return;
    }

    void* sg=pGetSG();
    uintptr_t rl=sg?rdp((uintptr_t)sg+0x50):0;
    uintptr_t items=rl?rdp(rl+0x10):0;
    int32_t n=0,my=-1;
    if(rl)rd(rl+0x18,&n,sizeof(n));
    if(sg)rd((uintptr_t)sg+0x38,&my,sizeof(my));

    if(!items||n<=0||n>200||my<0||my>=n){restoreHjPatch();return;}

    uintptr_t role=rdp(items+0x20+my*8);
    uintptr_t rbd=role?rdp(role+0x708):0;
    if(!rbd){restoreHjPatch();return;}

    if(hjPatch.ok&&hjPatch.rbd!=rbd)restoreHjPatch();

    // 当前 dump:BattleRoleLogic.MyRoleBaseData(+0x708),
    // SORoleBaseData 的站立/站立空中/移动/移动空中跳跃高度在 +0x38/+0x3C/+0x40/+0x44。
    // 只有本地角色会走这份数据
    float cur[4]={};
    for(int i=0;i<4;++i){
        if(!rd(rbd+kJmpOff[i],&cur[i],sizeof(cur[i]))||!std::isfinite(cur[i])||
           cur[i]<0.0f||cur[i]>100.0f){
            restoreHjPatch();
            return;
        }
    }

    if(!hjPatch.ok){
        hjPatch.rbd=rbd;
        for(int i=0;i<4;++i){hjPatch.old[i]=cur[i];hjPatch.last[i]=cur[i];}
        hjPatch.ok=true;
    }else{
        for(int i=0;i<4;++i)
            if(fabsf(cur[i]-hjPatch.last[i])>0.001f)hjPatch.old[i]=cur[i];
    }

    for(int i=0;i<4;++i){
        float want=fmaxf(0.0f,fminf(100.0f,hjPatch.old[i]*hjMul));
        if(wr(rbd+kJmpOff[i],&want,sizeof(want)))hjPatch.last[i]=want;
    }
}

static constexpr uintptr_t kRecoilOff[4]={
    0xA8, // UpMinRecoil
    0xAC, // UpMaxRecoil
    0xBC, // MaxLeftRightRecoil
    0xC0  // DownRecoilRatio
};
static constexpr uintptr_t kSpreadOff[6]={
    0xDC, // MaxShootRange
    0xE0, // MinShootRange
    0xE4, // LimitMinShootRange
    0xE8, // FireAddShootRange
    0xEC, // WepFirstShootCorrect
    0xFC  // StateAddShootRangeSpeed backing field
};

// 本地 RoleLogicClient。dump 路径:
// StartGame.RoleIndex(+0x38), StartGame.RoleList(+0x50)
// -> BattleRoleLogic.roleLogicClient(+0xAD8)
// -> RoleLogicClient.RoleClient(+0x80) 才是本地 BattleRole。
// CameraController+0xD0 是 LockRole(相机锁的目标),不是本地角色,
// 用它会变成没锁目标时加速 hook 直接把本地 RoleLogicClient 拒掉
static uintptr_t getLocalRLC(){
    if(!inited||!pGetSG)return 0;
    void* sg=pGetSG();
    if(!sg)return 0;

    uintptr_t rl=rdp((uintptr_t)sg+0x50);
    uintptr_t items=rl?rdp(rl+0x10):0;
    int32_t n=0,idx=-1;
    if(!rl||!items||
       !rd(rl+0x18,&n,sizeof(n))||
       !rd((uintptr_t)sg+0x38,&idx,sizeof(idx))||
       n<=0||n>200||idx<0||idx>=n)return 0;

    uintptr_t logic=rdp(items+0x20+(uintptr_t)idx*8);
    return logic?rdp(logic+0xAD8):0;
}

static uintptr_t getLocalRBD(){
    if(!inited||!pGetSG)return 0;
    void* sg=pGetSG();
    uintptr_t rl=sg?rdp((uintptr_t)sg+0x50):0;
    uintptr_t items=rl?rdp(rl+0x10):0;
    int32_t n=0,idx=-1;
    if(!rl||!items||
       !rd(rl+0x18,&n,sizeof(n))||
       !rd((uintptr_t)sg+0x38,&idx,sizeof(idx))||
       n<=0||n>200||idx<0||idx>=n)return 0;

    // 跟能用的高跳走同一条权威路径:
    // StartGame.RoleList[RoleIndex].MyRoleBaseData(+0x708)
    uintptr_t logic=rdp(items+0x20+(uintptr_t)idx*8);
    return logic?rdp(logic+0x708):0;
}

static uintptr_t getLocalBR(){
    uintptr_t rlc=getLocalRLC();
    return rlc?rdp(rlc+0x80):0;
}

static uintptr_t getLocalRN(){
    if(!inited||!pGetSG)return 0;
    void* sg=pGetSG();
    uintptr_t rl=sg?rdp((uintptr_t)sg+0x50):0;
    uintptr_t items=rl?rdp(rl+0x10):0;
    int32_t n=0,idx=-1;
    if(!rl||!items||
       !rd(rl+0x18,&n,sizeof(n))||
       !rd((uintptr_t)sg+0x38,&idx,sizeof(idx))||
       n<=0||n>200||idx<0||idx>=n)return 0;

    uintptr_t logic=rdp(items+0x20+(uintptr_t)idx*8);
    return logic?rdp(logic+0x730):0;
}

static uintptr_t getLocalRoot(){
    uintptr_t rn=getLocalRN();
    return rn?rdp(rn+0x40):0;
}

// RoleNet.$C 是缓存,有些实例是空的,但组件其实挂在角色根节点上。
// 所以缓存没有就从 Transform 现场 GetComponent 一个,别一上来就放弃传送
static uintptr_t getNetTf(uintptr_t rn,uintptr_t root){
    if(!rn)return 0;

    uintptr_t cached=rdp(rn+0x88);
    if(cached)return cached;
    if(!root||!pGetComp||!pStrNew)return 0;

    void* full=pStrNew("Mirror.NetworkTransformUnreliable");
    uintptr_t r=full?(uintptr_t)pGetComp((void*)root,full,nullptr):0;
    if(r)return r;

    // Unity 的 string 重载按加载的程序集不同,全名或者短名都可能认
    void* shortName=pStrNew("NetworkTransformUnreliable");
    return shortName?(uintptr_t)pGetComp((void*)root,shortName,nullptr):0;
}

bool TeleportToLatestMapMarker(){
    Vector3 tgt={0,0,0};
    {
        std::lock_guard<std::mutex> lk(markMx);
        if(!markOk){
            pushLog("标点传送失败：尚未捕获地图标点。");
            return false;
        }
        tgt=markPos;
    }

    uintptr_t rn=getLocalRN();
    uintptr_t root=rn?rdp(rn+0x40):0;
    // RoleNet.$C(0x88) 才是活的 NetworkTransformUnreliable。
    // 只写 Transform 就是测试里那个闪一帧的效果,
    // 下一个服务器快照就把之前的权威位置盖回来了
    uintptr_t nt=getNetTf(rn,root);
    if(!root||!nt||!pSetPos||!pV3ToByte||!pCmdSync||!okPt(tgt)){
        pushLog("标点传送失败：角色网络位置组件不可用。");
        return false;
    }

    // 这次位移还要被移动和网络状态机吃一遍,所以先给对应的上报过滤开个窗口
    tpUntil.store(nowMs()+10000,std::memory_order_relaxed);
    // 先把本地根节点挪过去,紧接着走 NetworkTransformUnreliable 自己的
    // 客户端->服务器位置命令。老的只写本地 Transform 是活不过快照的
    pSetPos((void*)root,tgt);
    void* bytes=pV3ToByte((void*)nt,tgt);
    if(!bytes){
        pushLog("标点传送失败：位置同步数据编码失败。");
        return false;
    }
    pCmdSync((void*)nt,bytes);
    if(!seenTp.exchange(true,std::memory_order_relaxed))
        pushLog("标点传送已发送位置同步请求，已开启位置检测过滤窗口。");
    return true;
}

static bool isAirState(int32_t s){
    // AC_JumpState:StartJump / JumpUp / JumpDown / Fall / ParabolaMoveUp / ElasticMoveUp
    return s==1||s==2||s==3||s==5||s==6||s==7;
}

static void restoreIajCounter(){
    if(iajPatch.clamped&&iajPatch.br&&iajPatch.num>=2){
        uintptr_t br=iajPatch.br;
        int32_t num=0,st=0;
        if(rd(br+0x9B4,&num,sizeof(num))&&rd(br+0x9D4,&st,sizeof(st))&&
           num==1&&isAirState(st))
            wr(br+0x9B4,&iajPatch.num,sizeof(iajPatch.num));
    }
    iajPatch={};
}

void SetInfiniteAirJumpEnabled(bool en){
    if(iajOn==en)return;
    iajOn=en;
    if(!en)restoreIajCounter();
}

void UpdateInfiniteAirJump(){
    if(!iajOn){restoreIajCounter();return;}

    uintptr_t br=getLocalBR();
    if(!br){iajPatch={};return;}

    if(iajPatch.br&&iajPatch.br!=br)iajPatch={};

    // 当前 dump:BattleRole.jumpNum(+0x9B4) / _nowJumpState(+0x9D4)。
    // 正常地面跳完 jumpNum 停在 1,每次空中跳会把它吃掉变成 2。
    // 这里只把这个被吃掉的计数压回 1,原来的输入/状态/高度判定全保留,
    // 下一次按就能再触发一次空中跳
    int32_t num=0,st=0;
    if(!rd(br+0x9B4,&num,sizeof(num))||!rd(br+0x9D4,&st,sizeof(st))||
       num<0||num>16||st<0||st>7){
        iajPatch={};
        return;
    }
    if(!isAirState(st)){iajPatch={};return;}
    if(num<2)return;

    iajPatch.br=br;iajPatch.num=num;iajPatch.clamped=true;
    const int32_t reuse=1;
    wr(br+0x9B4,&reuse,sizeof(reuse));
}

static bool curWeaponCfg(uintptr_t* out){
    if(!out)return false;
    *out=0;
    uintptr_t br=getLocalBR();
    uintptr_t wp=br?rdp(br+0x4B8):0;
    uintptr_t cfg=wp?rdp(wp+0x48):0;
    if(!wp||!cfg)return false;
    *out=cfg;
    return true;
}

static void restoreNoRecoil(){
    for(const RecoilE& e:noRecoilSt.infos){
        if(!e.obj)continue;
        float mn=0.0f,mx=0.0f;
        if(rd(e.obj+0x14,&mn,sizeof(mn))&&std::isfinite(mn)&&fabsf(mn)<=0.001f)
            wr(e.obj+0x14,&e.min,sizeof(e.min));
        if(rd(e.obj+0x18,&mx,sizeof(mx))&&std::isfinite(mx)&&fabsf(mx)<=0.001f)
            wr(e.obj+0x18,&e.max,sizeof(e.max));
    }

    if(noRecoilSt.ok&&noRecoilSt.cfg){
        for(int i=0;i<4;++i){
            float cur=0.0f;
            uintptr_t a=noRecoilSt.cfg+kRecoilOff[i];
            if(rd(a,&cur,sizeof(cur))&&std::isfinite(cur)&&
               fabsf(cur-noRecoilSt.last[i])<=0.001f)
                wr(a,&noRecoilSt.old[i],sizeof(noRecoilSt.old[i]));
        }
    }
    noRecoilSt={};
}

static void restoreNoSpread(){
    if(noSpreadSt.ok&&noSpreadSt.cfg){
        for(int i=0;i<6;++i){
            float cur=0.0f;
            uintptr_t a=noSpreadSt.cfg+kSpreadOff[i];
            if(rd(a,&cur,sizeof(cur))&&std::isfinite(cur)&&
               fabsf(cur-noSpreadSt.last[i])<=0.001f)
                wr(a,&noSpreadSt.old[i],sizeof(noSpreadSt.old[i]));
        }
    }
    noSpreadSt={};
}

void SetNoRecoilEnabled(bool en){
    if(noRecoilOn==en)return;
    noRecoilOn=en;
    if(!en)restoreNoRecoil();
}
void SetNoSpreadEnabled(bool en){
    if(noSpreadOn==en)return;
    noSpreadOn=en;
    if(!en)restoreNoSpread();
}

static void applyNoRecoil(uintptr_t cfg){
    if(noRecoilSt.ok&&noRecoilSt.cfg!=cfg)restoreNoRecoil();

    float cur[4]={};
    for(int i=0;i<4;++i){
        if(!rd(cfg+kRecoilOff[i],&cur[i],sizeof(cur[i]))||!std::isfinite(cur[i])||
           cur[i]<-100.0f||cur[i]>10000.0f){
            restoreNoRecoil();
            return;
        }
    }

    if(!noRecoilSt.ok){
        noRecoilSt.cfg=cfg;
        for(int i=0;i<4;++i){noRecoilSt.old[i]=cur[i];noRecoilSt.last[i]=cur[i];}
        noRecoilSt.ok=true;

        // SOWeaponControl.UpRecoilInfo(+0xB0)在打够子弹数之后会盖掉基础垂直后坐,
        // 所以这里每一项也一起清零
        uintptr_t arr=rdp(cfg+0xB0);
        uintptr_t cnt=0;
        if(arr&&rd(arr+0x18,&cnt,sizeof(cnt))&&cnt<=64){
            for(uintptr_t i=0;i<cnt;++i){
                uintptr_t obj=rdp(arr+0x20+i*8);
                if(!obj)continue;
                RecoilE e={};
                e.obj=obj;
                if(rd(obj+0x14,&e.min,sizeof(e.min))&&
                   rd(obj+0x18,&e.max,sizeof(e.max))&&
                   std::isfinite(e.min)&&std::isfinite(e.max))
                    noRecoilSt.infos.push_back(e);
            }
        }
    }else{
        for(int i=0;i<4;++i)
            if(fabsf(cur[i]-noRecoilSt.last[i])>0.001f)noRecoilSt.old[i]=cur[i];
    }

    const float zero=0.0f;
    for(int i=0;i<4;++i)
        if(wr(cfg+kRecoilOff[i],&zero,sizeof(zero)))noRecoilSt.last[i]=zero;

    for(RecoilE& e:noRecoilSt.infos){
        if(!e.obj)continue;
        float mn=0.0f,mx=0.0f;
        if(rd(e.obj+0x14,&mn,sizeof(mn))&&std::isfinite(mn)&&fabsf(mn)>0.001f)e.min=mn;
        if(rd(e.obj+0x18,&mx,sizeof(mx))&&std::isfinite(mx)&&fabsf(mx)>0.001f)e.max=mx;
        wr(e.obj+0x14,&zero,sizeof(zero));
        wr(e.obj+0x18,&zero,sizeof(zero));
    }
}

static void applyNoSpread(uintptr_t cfg){
    if(noSpreadSt.ok&&noSpreadSt.cfg!=cfg)restoreNoSpread();

    float cur[6]={};
    for(int i=0;i<6;++i){
        if(!rd(cfg+kSpreadOff[i],&cur[i],sizeof(cur[i]))||!std::isfinite(cur[i])||
           cur[i]<-100.0f||cur[i]>10000.0f){
            restoreNoSpread();
            return;
        }
    }

    if(!noSpreadSt.ok){
        noSpreadSt.cfg=cfg;
        for(int i=0;i<6;++i){noSpreadSt.old[i]=cur[i];noSpreadSt.last[i]=cur[i];}
        noSpreadSt.ok=true;
    }else{
        for(int i=0;i<6;++i)
            if(fabsf(cur[i]-noSpreadSt.last[i])>0.001f)noSpreadSt.old[i]=cur[i];
    }

    const float zero=0.0f;
    for(int i=0;i<6;++i)
        if(wr(cfg+kSpreadOff[i],&zero,sizeof(zero)))noSpreadSt.last[i]=zero;
}

void UpdateWeaponMemory(){
    if(!noRecoilOn)restoreNoRecoil();
    if(!noSpreadOn)restoreNoSpread();
    if(!noRecoilOn&&!noSpreadOn)return;

    uintptr_t cfg=0;
    if(!curWeaponCfg(&cfg)){
        restoreNoRecoil();
        restoreNoSpread();
        return;
    }
    if(noRecoilOn)applyNoRecoil(cfg);
    if(noSpreadOn)applyNoSpread(cfg);
}

static void restoreMelee(){
    if(meleeSt.ok&&meleeSt.cfg){
        uintptr_t c=meleeSt.cfg;
        float a=0.0f,b=0.0f;
        if(rd(c+0x10,&a,sizeof(a))&&std::isfinite(a)&&
           fabsf(a-meleeSt.lastEnter)<=0.001f)
            wr(c+0x10,&meleeSt.oldEnter,sizeof(meleeSt.oldEnter));
        if(rd(c+0x14,&b,sizeof(b))&&std::isfinite(b)&&
           fabsf(b-meleeSt.lastHold)<=0.001f)
            wr(c+0x14,&meleeSt.oldHold,sizeof(meleeSt.oldHold));
    }
    meleeSt={};
}

void SetChargedPunchNoCooldownEnabled(bool en){
    if(noCdOn==en)return;
    noCdOn=en;
    if(!en)restoreMelee();
}

void UpdateMeleeMemory(){
    if(!noCdOn){restoreMelee();return;}

    uintptr_t br=getLocalBR();
    if(!br){restoreMelee();return;}

    // 只有空手的时候才动手。当前 dump:
    // BattleRole.UserWeapon(+0x4B8)
    // BattleRole.MeleeAttackConfigData(+0x658)
    // MeleeAttackConfigData.hasHardAttack(+0x18)
    // MeleeAttackConfigData.hardAttackConfigData(+0x38)
    // MeleeHardAttackConfigData.startHardAttackEnterTime(+0x10)
    // MeleeHardAttackConfigData.holdHardAttackSuccessTime(+0x14)
    if(rdp(br+0x4B8)){restoreMelee();return;}

    uintptr_t mc=rdp(br+0x658);
    uint8_t has=0;
    uintptr_t hc=mc?rdp(mc+0x38):0;
    float enter=0.0f,hold=0.0f;
    if(!mc||!hc||
       !rd(mc+0x18,&has,sizeof(has))||has==0||
       !rd(hc+0x10,&enter,sizeof(enter))||
       !rd(hc+0x14,&hold,sizeof(hold))||
       !std::isfinite(enter)||!std::isfinite(hold)||
       enter<0.0f||enter>60.0f||hold<0.0f||hold>60.0f){
        restoreMelee();
        return;
    }

    if(meleeSt.ok&&meleeSt.cfg!=hc)restoreMelee();

    if(!meleeSt.ok){
        meleeSt.cfg=hc;
        meleeSt.oldEnter=enter;meleeSt.oldHold=hold;
        meleeSt.lastEnter=enter;meleeSt.lastHold=hold;
        meleeSt.ok=true;
    }else{
        if(fabsf(enter-meleeSt.lastEnter)>0.001f)meleeSt.oldEnter=enter;
        if(fabsf(hold-meleeSt.lastHold)>0.001f)meleeSt.oldHold=hold;
    }

    // success 留一点点正数,原来的长按状态机才走得完 Start -> Enter -> Success,
    // 直接写 0 会被那个等于判断跳过
    const float instEnter=0.0f;
    const float instHold=0.01f;
    if(wr(hc+0x10,&instEnter,sizeof(instEnter)))meleeSt.lastEnter=instEnter;
    if(wr(hc+0x14,&instHold,sizeof(instHold)))meleeSt.lastHold=instHold;
}

void SetBulletTrackEnabled(bool en){
    btOn=en;
    if(!en){
        std::lock_guard<std::mutex> lk(btMx);
        btTgtOk=false;btShOk=false;
    }
}
void SetBulletTrackFOV(float f){btFov=f;}
void SetBulletTrackTarget(int t){btPart=t;}
void SetBulletTrackLocalRadius(float r){btRad=fmaxf(1.0f,fminf(500.0f,r));}
bool IsBulletTrackHookReady(){return origB1||origB2||origB3||origB4;}

void UpdateAimbot(){
    aimTgtOk=false;
    if(!inited||!aimOn||!pSGMyCam||!pGetPos||!vmOk||!pmOk)return;

    void* sg=pGetSG();
    if(!sg)return;

    // 值都按当前 dump 取。老源码只借它 yaw/pitch 分开算那套,
    // 指针链和地址一律不用
    void* cc=pSGMyCam(sg,nullptr);
    if(!cc)return;

    int32_t my=0;
    rd((uintptr_t)sg+0x38,&my,sizeof(my));

    // 这游戏里 FireState 才是本地开镜状态。SideAim/TopShoot 是左右探头和越掩体,
    // 不是开镜开火
    if(aimMode==1){
        bool open=pIsFire&&pIsFire(nullptr);
        if(!open)return;
    }else if(aimMode==2){
        // 当前 dump:BattleRole.IsDownFire(+0x5D8)。本地 BattleRole 走
        // StartGame.RoleList[RoleIndex],不是 CameraController.LockRole(+0xD0)
        uintptr_t br=getLocalBR();
        uint8_t down=0;
        if(!br||!rd(br+0x5D8,&down,sizeof(down))||down==0)return;
    }

    uintptr_t rl=rdp((uintptr_t)sg+0x50);
    if(!rl)return;
    uintptr_t items=rdp(rl+0x10);
    if(!items)return;
    int32_t n=0;
    rd(rl+0x18,&n,sizeof(n));
    if(n<=0||n>200)return;

    int64_t myTeam=0;
    if(my>=0&&my<n){
        uintptr_t r=rdp(items+0x20+my*8);
        if(r)rd(r+0x7A0,&myTeam,sizeof(myTeam));
    }

    float best=99999.0f;
    Vector3 tp={0,0,0};
    Vector2 ts={0,0};
    uintptr_t tr=0;
    bool found=false;

    // 投影用的 VP 矩阵,判断目标shifouzai自瞄圈里
    float vp[16]={0};
    mulMat(vmMtx.m,pmMtx.m,vp);
    float cw=0.0f,ch=0.0f;
    OverlayGetCanvasSize(&cw,&ch);
    if(cw<=1.0f||ch<=1.0f)return;
    float ccx=cw*0.5f,ccy=ch*0.5f;

    for(int32_t i=0;i<n;i++){
        if(i==my)continue;
        uintptr_t r=rdp(items+0x20+i*8);
        if(!r)continue;

        int64_t team=0;
        rd(r+0x7A0,&team,sizeof(team));
        if(team!=0&&team==myTeam)continue;

        Vector3 ep={0,0,0};
        if(!getAimPt(r,aimPart,&ep))continue;

        // FOV
        Vector2 sp;
        if(!w2s(ep,vp,cw,ch,&sp))continue;

        float d=sqrtf((sp.x-ccx)*(sp.x-ccx)+(sp.y-ccy)*(sp.y-ccy));
        if(d>aimFov)continue;

        // 
        if(d<best){best=d;tp=ep;ts=sp;tr=r;found=true;}
    }

    if(!found)return;

    Vector3 tv=updTgtVel(tr,aimPart,tp);
    if(aimAlgo==1){
        Vector3 pp=tp;
        Vector2 ps=ts;
        if(buildPredPt(cc,tp,tv,&pp)&&w2s(pp,vp,cw,ch,&ps)){
            tp=pp;ts=ps;
        }
    }

    aimTgt=tp;aimTgtOk=true;

    Quaternion cy={},cp={};
    if(!rd((uintptr_t)cc+0xA0,&cy,sizeof(cy))||
       !rd((uintptr_t)cc+0xB0,&cp,sizeof(cp)))return;

    // 用实时的屏幕偏差做闭环修正。这样跟着当前相机的约定走,
    // 不用去猜老版本那套世界 yaw 正负号(那套边上目标会往外弹)
    float projX=fmaxf(0.1f,fabsf(pmMtx.m[0]));
    float projY=fmaxf(0.1f,fabsf(pmMtx.m[5]));
    float nx=(ts.x-ccx)/(cw*0.5f);
    float ny=(ts.y-ccy)/(ch*0.5f);
    float yawErr=atan2f(nx,projX);
    float pitErr=atan2f(ny,projY);
    float step=1.0f/fmaxf(1.0f,aimSpd);
    float curYaw=2.0f*atan2f(cy.y,cy.w);
    float curPit=2.0f*atan2f(cp.x,cp.w);
    float nextYaw=curYaw+yawErr*step;
    float nextPit=curPit+pitErr*step;

    Quaternion qy={0.0f,sinf(nextYaw*0.5f),0.0f,cosf(nextYaw*0.5f)};
    Quaternion qp={sinf(nextPit*0.5f),0.0f,0.0f,cosf(nextPit*0.5f)};

    bool wy=wr((uintptr_t)cc+0xA0,&qy,sizeof(qy));
    bool wp=wr((uintptr_t)cc+0xB0,&qp,sizeof(qp));
    if(wy&&wp&&!aimRotSeen.exchange(true))
        NSLog(@"[UnityESP] Aimbot wrote CameraController aim rotations");
}

void UpdateBulletTrackTarget(){
    bool found=false;
    Vector3 bestTgt={0,0,0};
    bool shOk=false;
    Vector3 shPos={0,0,0};

    if(inited&&btOn&&pGetSG&&pGetPos&&vmOk&&pmOk){
        void* sg=pGetSG();
        uintptr_t rl=sg?rdp((uintptr_t)sg+0x50):0;
        uintptr_t items=rl?rdp(rl+0x10):0;
        int32_t n=0;
        if(rl)rd(rl+0x18,&n,sizeof(n));

        int32_t my=-1;
        if(sg)rd((uintptr_t)sg+0x38,&my,sizeof(my));

        if(items&&n>0&&n<=200&&my>=0&&my<n){
            uintptr_t me=rdp(items+0x20+my*8);
            int64_t myTeam=0;
            if(me){
                rd(me+0x7A0,&myTeam,sizeof(myTeam));
                uintptr_t mrn=rdp(me+0x730);
                uintptr_t mtf=mrn?rdp(mrn+0x40):0;
                if(mtf){
                    shPos=pGetPos((void*)mtf);
                    shOk=true;
                }
            }

            float vp[16];
            mulMat(vmMtx.m,pmMtx.m,vp);

            float cw=0.0f,ch=0.0f;
            OverlayGetCanvasSize(&cw,&ch);
            float ccx=cw*0.5f,ccy=ch*0.5f;
            float bestD=btFov;

            for(int32_t i=0;i<n;++i){
                if(i==my)continue;

                uintptr_t r=rdp(items+0x20+i*8);
                if(!r)continue;

                int64_t team=0;
                rd(r+0x7A0,&team,sizeof(team));
                if(team!=0&&team==myTeam)continue;

                Vector3 ap={0,0,0};
                if(!getAimPt(r,btPart,&ap))continue;

                Vector2 sp;
                if(!w2s(ap,vp,cw,ch,&sp))continue;

                float dx=sp.x-ccx,dy=sp.y-ccy;
                float d=sqrtf(dx*dx+dy*dy);
                if(d<bestD){bestD=d;bestTgt=ap;found=true;}
            }
        }
    }

    std::lock_guard<std::mutex> lk(btMx);
    btTgtOk=found;
    if(found)btTgt=bestTgt;
    if(shOk){btShPos=shPos;btShOk=true;}
    else btShOk=false;
}
