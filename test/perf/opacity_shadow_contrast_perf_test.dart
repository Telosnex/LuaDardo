// ignore_for_file: avoid_print
//
// Reduced version of the Lua workload recovered from step
// 019f4eb5-ebb9-77d5-bd2f-4f9d4bee9264 in the exported conversation.
//
// Run/profile:
//   dart run --enable-vm-service test/perf/opacity_shadow_contrast_perf_test.dart

import 'package:lua_dardo_plus/lua.dart';
import 'package:lua_dardo_plus/src/state/arithmetic.dart';
import 'package:lua_dardo_plus/src/state/lua_state_impl.dart';
import 'package:lua_dardo_plus/src/vm/instructions.dart';

import 'perf_tester.dart';

// This is deliberately the benchmark's sole input. The exported tool call was
// truncated at `local yt=alg`; the final trial/summary section below restores
// the clear intent described by its label: compare envelope pruning with the
// uncapped frontier solver for size and exactness.
const _workload = r'''
math.randomseed(11)
local function lin(c) local s=c/255 if s<=0.04045 then return s/12.92 end return ((s+0.055)/1.055)^2.4 end
local function wcagY(p) return 0.2126*lin(p[1])+0.7152*lin(p[2])+0.0722*lin(p[3]) end
local function apcaYf(p) return 0.2126729*(p[1]/255)^2.4+0.7151522*(p[2]/255)^2.4+0.0721750*(p[3]/255)^2.4 end
local function blend(bg,h,a) return {(1-a)*bg[1]+a*h[1],(1-a)*bg[2]+a*h[2],(1-a)*bg[3]+a*h[3]} end
local function wcagC(yt,yb) local hi=math.max(yt,yb) local lo=math.min(yt,yb) return (hi+0.05)/(lo+0.05) end
local function scl(y) if y<0.022 then return y+(0.022-y)^1.414 end return y end
local function apcaC(yt0,yb0)
  local yt,yb=scl(yt0),scl(yb0)
  if math.abs(yb-yt)<0.0005 then return 0 end
  if yb>yt then local s=(yb^0.56-yt^0.57)*1.14 if s<0.1 then return 0 end return (s-0.027)*100 end
  local s=(yb^0.65-yt^0.62)*1.14 if s>-0.1 then return 0 end return math.abs((s+0.027)*100)
end
local ALGOS={
  wcag={yOf=wcagY, c=function(a,b) return wcagC(a,b) end, targets={3,4.5,7}},
  apca={yOf=apcaYf, c=function(a,b) return math.abs(apcaC(a,b)) end, targets={45,60,75}},
}
local function band(algo,yt,target)
  local N=2048 local lo,hi
  for i=0,N do local y=i/N if algo.c(yt,y)<target then if not lo then lo=y end hi=y end end
  if not lo then return nil end
  return {lo=lo-1/N,hi=hi+1/N}
end
local function frontier(pix,sign) -- uncapped
  local function dom(q,p) for i=1,3 do if sign*q[i]<sign*p[i] then return false end end return true end
  local F={}
  for _,p in ipairs(pix) do
    local d=false
    for _,q in ipairs(F) do if dom(q,p) then d=true break end end
    if not d then
      local F2={}
      for _,q in ipairs(F) do if not dom(p,q) then F2[#F2+1]=q end end
      F2[#F2+1]={p[1],p[2],p[3]} F=F2
    end
  end
  return F
end
-- envelope pruning: keep members that are argmax (sign=+1) / argmin (-1) at some grid alpha, either halo, either algo
local HALOS={{0,0,0},{255,255,255}}
local function envelope(F,sign)
  local keep={}
  for _,algo in pairs({ALGOS.wcag,ALGOS.apca}) do
    for _,H in ipairs(HALOS) do
      for ai=0,255 do local a=ai/255
        local best,bi=nil,nil
        for i,p in ipairs(F) do
          local y=algo.yOf(blend(p,H,a))
          if best==nil or sign*y>sign*best then best=y bi=i end
        end
        keep[bi]=true
      end
    end
  end
  local E={}
  for i,p in ipairs(F) do if keep[i] then E[#E+1]=p end end
  return E
end
local function R() return math.random(0,255) end
local gens={
  uniform=function() local t={} for i=1,200 do t[i]={R(),R(),R()} end return t end,
  gradient=function() local a,b={R(),R(),R()},{R(),R(),R()} local t={}
    for i=1,200 do local p={} local f=(i-1)/199
      for k=1,3 do p[k]=math.floor(a[k]+(b[k]-a[k])*f+0.5) end t[i]=p end
    return t end,
  huesweep=function() local t={} -- adversarial anti-chain: frontier = everything
    local ks={1,2,3} local i1=ks[math.random(3)] local i2=(i1%3)+1
    for i=1,200 do local p={0,0,0} local r=math.floor(255*(i-1)/199+0.5)
      p[i1]=r p[i2]=255-r t[i]=p end
    return t end,
}
local fsz,esz={},{ }
local diffs,worse=0,0
local nt=0
-- Original: 0..899. Twelve trials retain both algorithms and give each
-- algorithm/generator pairing two samples without making profiling unwieldy.
for t=0,11 do
  local names={"uniform","gradient","huesweep"}
  local gname=names[(t%3)+1]
  local algo=(t%2==1) and ALGOS.apca or ALGOS.wcag
  local pix=gens[gname]()
  local text=({{255,255,255},{0,0,0},{R(),R(),R()}})[(t%3)+1]
  local yt=algo.yOf(text)
  local H=(yt>0.3) and HALOS[1] or HALOS[2]
  local target=algo.targets[math.random(1,3)]
  if algo.c(yt,algo.yOf(H))>=target then
    nt=nt+1
    local bd=band(algo,yt,target)
    local function solve(Flo,Fhi)
      for ai=0,255 do local a=ai/255
        local yLo,yHi=math.huge,-math.huge
        for _,p in ipairs(Flo) do yLo=math.min(yLo,algo.yOf(blend(p,H,a))) end
        for _,p in ipairs(Fhi) do yHi=math.max(yHi,algo.yOf(blend(p,H,a))) end
        if bd==nil or yHi<bd.lo or yLo>bd.hi then return ai end
      end
      return nil
    end
    local Fhi,Flo=frontier(pix,1),frontier(pix,-1)
    local Ehi,Elo=envelope(Fhi,1),envelope(Flo,-1)
    fsz[#fsz+1]=#Fhi+#Flo
    esz[#esz+1]=#Ehi+#Elo
    local af,ae=solve(Flo,Fhi),solve(Elo,Ehi)
    if af~=ae then
      diffs=diffs+1
      if af~=nil and (ae==nil or ae>af) then worse=worse+1 end
    end
  end
end
local function mean(t) local s=0 for _,v in ipairs(t) do s=s+v end return #t==0 and 0 or s/#t end
return string.format("trials=%d frontier=%.2f envelope=%.2f diffs=%d worse=%d",nt,mean(fsz),mean(esz),diffs,worse)
''';

String _runScript(String script) {
  final state = LuaState.newState();
  state.openLibs();
  state.loadString(script);
  state.pCall(0, 1, 0);
  return state.toStr(-1) ?? 'nil';
}

Future<void> main() async {
  final tester = PerfTester<String, String>(
    testName: 'opacity shadow contrast envelope workload',
    testCases: const [_workload],
    implementation1: (script) {
      Instructions.useDirectArithmetic = true;
      Arithmetic.useNumericFastPath = true;
      Instructions.useDirectTableGet = true;
      Instructions.useDirectComparison = true;
      LuaStateImpl.useDirectCallTransfer = true;
      LuaStateImpl.useDirectResultTransfer = true;
      Instructions.useDirectSetList = true;
      Instructions.useDirectTableSet = true;
      LuaStateImpl.useRegisterExecution = true;
      LuaStateImpl.useRegisterCalls = false;
      return _runScript(script);
    },
    implementation2: (script) {
      Instructions.useDirectArithmetic = true;
      Arithmetic.useNumericFastPath = true;
      Instructions.useDirectTableGet = true;
      Instructions.useDirectComparison = true;
      LuaStateImpl.useDirectCallTransfer = true;
      LuaStateImpl.useDirectResultTransfer = true;
      Instructions.useDirectSetList = true;
      Instructions.useDirectTableSet = true;
      LuaStateImpl.useRegisterExecution = true;
      LuaStateImpl.useRegisterCalls = true;
      return _runScript(script);
    },
    impl1Name: 'Register executor',
    impl2Name: 'Register calls',
  );

  await tester.run(
    warmupRuns: 1,
    benchmarkRuns: 2,
    profile: true,
    profileRuns: 1,
    profileTopN: 40,
  );
}
