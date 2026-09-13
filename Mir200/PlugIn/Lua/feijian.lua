-- feijian.lua : 飞剑服务端 - 权威伤害/防刷包/解锁状态下发
-- 上行: 客户端 swordfx.lua 每把剑命中时发专用封包 Ident=9501 (Recog=目标)
-- 下行: SendClientMsg(64001, 0, 解锁0/1, 数量, 数量) -> 客户端 on_recv_packet
--
-- 数据模型(单变量): U变量 599
--   0    = 未学习飞剑
--   1..5 = 已学习, 数值即飞剑最大数量上限(服务端权威)
--   注意: U变量随人物存档持久化, 但下标必须 <600(SYS_VAR_COUNT_U),
--         否则 GetVarU/SetVarU 静默失效(读恒0/写无效), 剑数存不进存档。
--
-- 防刷设计(服务端权威, 客户端任何报文不能提升频率):
--   频率上限 = 剑数 决定, 单闸(滑动窗口配额):
--     每 BASE_CD 周期内最多命中 剑数 次 (总量限制)。
--   超限 -> 丢弃+违规计数, 连续违规踢线。
--   多目标模式: N 把剑可在同一帧并发命中 N 个不同目标, 这是合法突发,
--   窗口配额恰好容纳 N 次并发。故不再设"最小包间隔"闸(否则同帧命中
--   只有第一个生效, 其余被误判突发丢弃 -> 5 把剑只有 1 个掉血)。

-- ==== 配置区(热重载生效) ====
local MSG_FEIJIAN  = 64001  -- 双端约定消息号
local SWORD_VAR    = 599    -- U变量: 0=未学, 1..5=已学且=最大剑数(下标须<600)
local DMG_VAR      = 597    -- U变量: 伤害倍率百分比，默认100
local SPEED_VAR    = 598    -- U变量: 飞行/环绕速度百分比，默认100
local CD_VAR       = 596    -- U变量: 攻击冷却倍率百分比，默认100
local MAX_SWORDS   = 5      -- 剑数硬上限(变量被误设过大也不放行)
local BASE_CD      = 1600   -- ms, 单剑基准冷却(客户端2000ms, 留400ms网络余量)
local KICK_VIOLATE = 10     -- 连续违规达到此数踢下线
local DEFAULT_DMG  = 100    -- 新角色默认伤害百分比
local DEFAULT_SPEED = 100   -- 新角色默认速度百分比
local DEFAULT_CD   = 100    -- 新角色默认攻击冷却百分比
                            -- 属性按职业: 0战士=DC 1法师=MC 2道士=SC

local st = {}   -- [角色名] = { win0=窗口起点, wn=窗口内命中数, bad=违规数 }

local function clamp_count(n)
    n = math.floor(tonumber(n) or 0)
    if n < 0 then n = 0 end
    if n > MAX_SWORDS then n = MAX_SWORDS end
    return n
end

-- 读服务端权威剑数(未学=0, 学了 1..MAX_SWORDS)
local function sword_count(player)
    return clamp_count(Engine.GetVarU(player, SWORD_VAR))
end

local function percent_var(player, index, default, max)
    local n = math.floor(tonumber(Engine.GetVarU(player, index)) or 0)
    if n <= 0 then n = default end
    if n < 25 then n = 25 end
    if n > (max or 1000) then n = max or 1000 end
    return n
end

local function cooldown_ms(player)
    local rate = percent_var(player, CD_VAR, DEFAULT_CD, 500)
    return math.max(200, math.floor(BASE_CD / (rate / 100)))
end

-- 下发飞剑状态(登录/学习/收回时调用; 未学也发, 显式关闭客户端残留)
-- param=解锁0/1, tag=数量, series=数量(客户端用 series 作上限)
local function push_state(player)
    local n = sword_count(player)
    local unlock = 0
    if n >= 1 then unlock = 1 end
    Engine.SendClientMsg(player, MSG_FEIJIAN, 0, unlock, n, n)
    Engine.SendClientMsg(player, MSG_FEIJIAN + 1,
        percent_var(player, SPEED_VAR, DEFAULT_SPEED, 500),
        percent_var(player, DMG_VAR, DEFAULT_DMG, 1000),
        percent_var(player, CD_VAR, DEFAULT_CD, 500), 0)
end

-- 给传统 NPC 的 LUACALL/LUAINT 使用。调用时建议显式写模块名 feijian.*。
function FeijianGetLevel(player)
    return sword_count(player)
end

function FeijianSetLevel(player, level)
    local n = clamp_count(level)
    Engine.SetVarU(player, SWORD_VAR, n)

    local name = Engine.GetName(player)
    if name and n < 1 then st[name] = nil end

    push_state(player)
    return n
end

function FeijianSync(player)
    push_state(player)
    return sword_count(player)
end

function FeijianGetDamage(player)
    return percent_var(player, DMG_VAR, DEFAULT_DMG, 1000)
end

function FeijianGetSpeed(player)
    return percent_var(player, SPEED_VAR, DEFAULT_SPEED, 500)
end

function FeijianSetDamage(player, percent)
    local n = math.floor(tonumber(percent) or DEFAULT_DMG)
    if n < 25 then n = 25 end
    if n > 1000 then n = 1000 end
    Engine.SetVarU(player, DMG_VAR, n)
    push_state(player)
    return n
end

function FeijianSetSpeed(player, percent)
    local n = math.floor(tonumber(percent) or DEFAULT_SPEED)
    if n < 25 then n = 25 end
    if n > 500 then n = 500 end
    Engine.SetVarU(player, SPEED_VAR, n)
    push_state(player)
    return n
end

function FeijianGetCooldown(player)
    return percent_var(player, CD_VAR, DEFAULT_CD, 500)
end

function FeijianSetCooldown(player, percent)
    local n = math.floor(tonumber(percent) or DEFAULT_CD)
    if n < 25 then n = 25 end
    if n > 500 then n = 500 end
    Engine.SetVarU(player, CD_VAR, n)
    push_state(player)
    return n
end

function on_player_login(player)
    push_state(player)
end

local function violate(player, name, s, why)
    s.bad = s.bad + 1
    if s.bad >= KICK_VIOLATE then
        Engine.MainOutMessage('[feijian] kick ' .. name .. ' ' .. why .. ' x' .. s.bad)
        Engine.KickPlayer(player)
        st[name] = nil
    end
end

local CM_FEIJIAN = 9501

function on_client_packet(player, ident, recog, param, tag, series)
    if ident ~= CM_FEIJIAN then return false end
    local name = Engine.GetName(player)
    if not name then return true end

    local n = sword_count(player)

    -- ① 未学习: 静默丢弃
    if n < 1 then return true end

    local now = Engine.GetTick()
    local s = st[name]
    if not s then s = { win0 = now, wn = 0, bad = 0 }; st[name] = s end

    -- ② 闸(唯一): 滑动窗口配额, BASE_CD 周期内最多 n 次 (总量限制)
    --    N 把剑同帧命中 N 个目标属合法突发, 全部计入同一窗口配额。
    if now - s.win0 >= cooldown_ms(player) then
        s.win0 = now
        s.wn = 0
    end
    if s.wn >= n then
        violate(player, name, s, 'quota')
        return true
    end

    s.bad = 0

    -- ③ 服务端计算基础伤害 (完全无视客户端数据; recog 已是数字)
    -- 属性按职业取: 战士=攻击DC 法师=魔法MC 道士=道术SC
    if not recog or recog == 0 then return true end
    local ab = Engine.GetAbility(player)
    if not ab then return true end
    local job = Engine.GetJob(player)
    local a1, a2
    if job == 0 then a1, a2 = ab.DC1, ab.DC2
    elseif job == 2 then a1, a2 = ab.SC1, ab.SC2
    else a1, a2 = ab.MC1, ab.MC2 end
    a2 = math.max(a1, a2)
    local dmgRate = percent_var(player, DMG_VAR, DEFAULT_DMG, 1000)
    local base = math.floor(math.random(a1, a2) * dmgRate / 100)
    if base < 1 then base = 1 end

    -- ④ Pascal 层校验+减防+施加 (战士按物理AC减免, 法/道按魔法MAC减免)
    local dmg = Engine.LuaAttack(player, recog, base, job == 0)
    if dmg then
        s.wn = s.wn + 1           -- 仅有效命中占用窗口配额
    end
    return true
end

function on_player_leave(player)
    local n = Engine.GetName(player)
    if n then st[n] = nil end
end

-- 开发测试入口。正式服可删除此回调，只保留 NPC 对 FeijianSetLevel 的调用。
function on_user_command(player, cmd, param)
    if cmd ~= '学飞剑' then return false end

    local n = FeijianSetLevel(player, tonumber(param) or MAX_SWORDS)
    if n < 1 then
        Engine.SysMsg(player, '飞剑已收回', 1)
    else
        Engine.SysMsg(player, '飞剑已学会! 最大数量 ' .. n .. ' 把', 1)
    end
    return true
end
