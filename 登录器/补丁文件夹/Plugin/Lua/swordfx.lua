-- 飞剑特效 —— 完整版：椭圆巡航 + 索敌攻击（贝塞尔曲线）+ 人物上下分层绘制
-- ============================================================================
-- 巡航（绕行）部分为已校准的现有实现，勿改：
--   * 切线公式：tangentX = -RX*sin(θ), tangentY = +RY*cos(θ)
--     （HGE 屏幕坐标 Y 向下，与 cocos 版不同，Y 分量【不】取反）
--   * BASE_ANGLE = -45 度（贴图基准角，实测校准值）
--   * OFF_Y = -20（椭圆中心相对人物的抬高）
--   * 分层：飞剑 y < 人物 y 画在人物下层（后面），否则画在上层（前面）
--
-- 攻击逻辑移植自 _swordfx_utf8.lua.bak / 参考版 FeiJianSkill.lua：
--   Idle 巡航 -> 周期索敌 -> Attack 贝塞尔冲过目标再大弧折回命中 -> 命中闪光
--   -> CoolFly 飞回轨道 -> CoolWait 等冷却 -> Idle；无怪时 Back 收剑。
--
-- 拖尾：星光粒子（移植参考版 particle/tail.plist），不再画飞剑贴图残影。
--   星星贴图 res/star.png + 加法混合 + 按剑 id 染色（需引擎
--   DrawTexRotate 第8参 color 支持；旧 exe 忽略该参数则粒子为白色）。
--
-- 热键：F6 开/关    F7 剑数量 1/3/5
-- 文件须存为 GBK/ANSI（由本 utf8 母本 iconv 转码部署，改功能请改母本）。
-- ============================================================================

local C_GREEN  = 0x00FF00
local C_YELLOW = 0x00FFFF
local C_RED    = 0x0000FF
local C_BLUE   = 0xFF0000

-- ---- 配置 ----
local SWORD_FILES = {
  "Plugin/Lua/res/jian_1.png",
  "Plugin/Lua/res/jian_2.png",
  "Plugin/Lua/res/jian_3.png",
  "Plugin/Lua/res/jian_4.png",
  "Plugin/Lua/res/jian_99.png",
}
local RX, RY      = 70, 32         -- 巡航椭圆半径（Y 压扁做透视）
local SPEED       = math.pi / 1.5  -- 巡航角速度 rad/s
local SCALE       = 0.15           -- 巡航基准缩放
local BASE_ANGLE  = math.rad(0)  -- 贴图基准角度-45度（实测校准值）
local OFF_Y       = -20            -- 椭圆中心相对人物的抬高
local ATK_MIN, ATK_RND = 0.85, 0.35 -- 攻击飞行时长 0.85+rand*0.35 s（大弧路径长）
local BACK_DUR    = 0.9            -- 飞回时长 s
local ATK_CD      = 2.0            -- 每把剑攻击冷却 s
local SEEK_RANGE  = 8              -- 索敌半径（地图格）
local CTRL_LEN    = 200            -- 贝塞尔控制点前伸像素（飞回轨道用）
local ATK_CTRL    = 320            -- 攻击出手控制点前伸（越大出剑弧越张）
local ATK_SWAY    = 120            -- 出手控制点的侧向分量（去程也带弯）
local OVER_LEN    = 340            -- 攻击冲过目标的纵深（沿出剑方向越过目标）
local OVER_SIDE   = 320            -- 折回弧的侧向张开（越大回勾角度越大）
local HIT_FLASH   = 0.25           -- 命中闪光时长 s
-- 星光粒子拖尾（移植参考版 tail.plist：星星贴图 + 加法混合 + 按剑染色）
local STAR_PNG    = "Plugin/Lua/res/star.png"
local PART_LIFE   = 0.6            -- 粒子存活 s（plist particleLifespan）
local PART_MAX    = 300            -- 粒子总量上限（防堆积）
local PART_S0     = 0.10           -- 起始缩放（plist 25px / 贴图256px）
local PART_S1     = 0.02           -- 结束缩放（plist 5px）
-- 每把剑的粒子颜色 0xRRGGBB（参考版 allSwordInfo 配色：橙/绿/蓝/红）
local PART_COLORS = { 0xD08400, 0x1DB100, 0x0092CF, 0xD61200 }
local BLEND_ADD   = 102            -- Blend_SrcAlphaAdd：加法混合（plist 770/1）
-- 服务端伤害（配套 M2 端 PlugIn\Lua\feijian.lua）：命中帧发专用封包
--   Ident=CM_FEIJIAN(9501)  Recog=目标 recog（引擎未占用的 CM 号段 9500..19999）
-- 每把剑独立节流 2000ms（= ATK_CD）> 服务端单剑基准 1600ms，正常客户端不触发违规。
-- 服务端按 U599 剑数放行频率（窗口配额闸），客户端谎报剑数无效。
local CM_FEIJIAN = 9501
local HIT_SEND_INTERVAL = 2000     -- ms，单把剑命中包最小间隔
-- 回程通道：服务端登录/学习时下发解锁状态
--   Ident=64001  Param=是否解锁(0/1)  Tag=飞剑等级
local MSG_FEIJIAN = 64001
local MSG_FEIJIAN_CFG = 64002

-- ---- 状态 ----
local ST_IDLE, ST_ATTACK, ST_COOLFLY, ST_COOLWAIT, ST_BACK = 0, 1, 2, 3, 4

local enabled  = false             -- 须先由服务端下发解锁（MSG_FEIJIAN），再 F6 开启
local swordN   = 3                 -- 当前剑数量（F7 切 1/3/5）
local swords   = {}
local hits     = {}                -- 命中闪光 { x, y, t0 }
local parts    = {}                -- 星光粒子 { x, y, vx, vy, t0, life, color }
local texCache = {}
local starTex  = nil               -- 星星贴图句柄（nil=未加载 0=失败）
local lastTick = nil
local unlocked = false             -- 服务端下发的解锁状态（未学不显示飞剑）
local swordLv  = 0                 -- 服务端下发的飞剑等级
local maxSwordN = 5                -- 服务端下发的剑数上限（F7 不可超过）
local speedRate = 100              -- 服务端下发的速度百分比
local dmgRate = 100                -- 仅记录，伤害由服务端计算
local cdRate = 100                 -- 服务端下发的攻击冷却倍率
local panel = {}
local panelShown = false
local panelLastTick = 0
local panelText = { '', '', '', '' }

-- 帧缓存（每帧只算一次，全剑共享）
local frameTick = -1
local selfSX, selfSY               -- 自己屏幕坐标（含 OFF_Y）
local mobs = {}                    -- 可攻击怪 { recog, sx, sy }

local function tex(id)
  if texCache[id] == nil then
    texCache[id] = Game.LoadTextureFile(SWORD_FILES[id]) or 0
  end
  return texCache[id]
end

local function starTexH()
  if starTex == nil then
    starTex = Game.LoadTextureFile(STAR_PNG) or 0
  end
  return starTex
end

-- 发射一颗星光粒子（在剑身后方少量散布，带微速度，仿 plist 参数）
local function emitPart(s, now)
  if #parts >= PART_MAX then table.remove(parts, 1) end
  parts[#parts + 1] = {
    x = s.x + (math.random() - 0.5) * 18,   -- sourcePositionVariance 18/4
    y = s.y + (math.random() - 0.5) * 8,
    vx = (math.random() - 0.5) * 10,        -- speedVariance 5
    vy = (math.random() - 0.5) * 10 + 3,    -- gravityy 5：轻微下沉
    t0 = now,
    life = (PART_LIFE + (math.random() - 0.5) * 0.2) * 1000,
    color = PART_COLORS[((s.id - 1) % #PART_COLORS) + 1],
  }
end

-- 更新所有粒子（推进位置、清理过期），每帧一次
local function updateParts(now, dt)
  local i = 1
  while i <= #parts do
    local p = parts[i]
    if now - p.t0 >= p.life then
      table.remove(parts, i)
    else
      p.x = p.x + p.vx * dt
      p.y = p.y + p.vy * dt
      i = i + 1
    end
  end
end

-- 绘制粒子（加法混合，大小/透明度随寿命衰减）
-- layer: 'B'=只画人物后方(y<selfSY)  'F'=只画人物前方(y>=selfSY)
local function drawParts(now, layer)
  local h = starTexH()
  for i = 1, #parts do
    local p = parts[i]
    local behind = p.y < selfSY
    if (layer == 'B') == behind then
      local age = (now - p.t0) / p.life
      local scale = PART_S0 + (PART_S1 - PART_S0) * age
      local alpha = math.floor(255 * (1 - age))
      if h ~= 0 then
        Game.DrawTexRotate(h, p.x, p.y, 0, scale, alpha, BLEND_ADD, p.color)
      else
        -- 无贴图时退化为小方点（颜色转 BGR）
        local c = p.color
        local bgr = math.floor(c / 65536) + (math.floor(c / 256) % 256) * 256
                    + (c % 256) * 65536
        Game.FillRect(p.x - 1, p.y - 1, p.x + 1, p.y + 1, bgr, alpha)
      end
    end
  end
end

-- race 过滤：0=玩家 10=普通NPC 50=和平NPC/商人，这三类不打
local function refreshFrame(me, now)
  if now == frameTick then return end
  frameTick = now
  selfSX, selfSY = nil, nil
  mobs = {}
  local actors = Game.GetActors()
  if actors then
    for i = 1, #actors do
      local a = actors[i]
      if a.self then
        if a.screenx then selfSX, selfSY = a.screenx, a.screeny + OFF_Y end
      elseif a.attackable and not a.hero and a.screenx then
        -- attackable = 引擎级可攻击判定（IsGJAttackTarget：活着/非NPC雕像卫士
        -- 城门采集怪/和平模式玩家排除/法道不打石化怪），与内挂索敌同一标准
        if Game.GetDistance(me.x, me.y, a.x, a.y) <= SEEK_RANGE then
          mobs[#mobs + 1] = { recog = a.recog, sx = a.screenx, sy = a.screeny - 30 }
        end
      end
    end
  end
  if not selfSX then
    local sx, sy = Game.WorldToScreen(me.x, me.y)
    if sx then selfSX, selfSY = sx, sy + OFF_Y end
  end
end

local function findMob(recog)
  for i = 1, #mobs do
    if mobs[i].recog == recog then return mobs[i] end
  end
  return nil
end

local function panelLabel(parent, x, y, text)
  local h = Game.CreateLabel(parent)
  Game.SetControlPos(h, x, y)
  Game.SetControlSize(h, 170, 18)
  Game.SetControlCaption(h, text)
  Game.SetControlVisible(h, true)
  return h
end

local function buildPanel()
  if panel.win then return end
  panel.win = Game.CreateWindow()
  Game.SetControlPos(panel.win, 18, 180)
  Game.SetControlSize(panel.win, 190, 126)
  Game.SetControlTransparent(panel.win, false)
  Game.SetControlBackColor(panel.win, 0x202020)
  Game.SetControlVisible(panel.win, false)

  panel.title = panelLabel(panel.win, 8, 6, '飞剑状态')
  Game.SetTitleBar(panel.win, panel.title)
  panel.close = Game.CreateButton(panel.win)
  Game.SetControlPos(panel.close, 156, 4)
  Game.SetControlSize(panel.close, 26, 20)
  Game.SetControlCaption(panel.close, 'X')
  Game.SetControlVisible(panel.close, true)
  Game.SetOnClick(panel.close, function()
    panelShown = false
    Game.SetControlVisible(panel.win, false)
  end)

  panel.count = panelLabel(panel.win, 8, 34, '')
  panel.speed = panelLabel(panel.win, 8, 56, '')
  panel.damage = panelLabel(panel.win, 8, 78, '')
  panel.cooldown = panelLabel(panel.win, 8, 100, '')
end

local function updatePanel(now)
  if not panelShown or not panel.win then return end
  if now - panelLastTick < 100 then return end
  panelLastTick = now
  panelText[1] = '飞剑数量：' .. swordN .. ' / ' .. maxSwordN
  panelText[2] = '当前速度：' .. speedRate .. '%'
  panelText[3] = '伤害倍率：' .. dmgRate .. '%'
  panelText[4] = '攻击冷却：' .. cdRate .. '%'
end

-- 巡航轨道位置（相对人物）
local function orbitPos(s)
  return selfSX + RX * math.cos(s.angle), selfSY + RY * math.sin(s.angle)
end

-- 三次贝塞尔（4 控制点：起点/起点前伸/终点前伸/终点）
local function makeBezier(x1, y1, dir1, x4, y4)
  return {
    x1, y1,
    x1 + CTRL_LEN * math.cos(dir1), y1 + CTRL_LEN * math.sin(dir1),
    x4 + CTRL_LEN * math.cos(dir1), y4 + CTRL_LEN * math.sin(dir1),
    x4, y4,
  }
end

-- 攻击贝塞尔：飞出时越过目标，折回弧上收剑命中（终点=目标）
--   P2 沿出手方向大幅前伸（出剑角度张开），P3 放在目标"身后 + 侧向"，
--   曲线因此先冲过目标再以大弧度勾回，末端切线从身后指回目标 = 折回时攻击
local function makeAttackBezier(x1, y1, dir1, x4, y4)
  local dx, dy = x4 - x1, y4 - y1
  local d = math.sqrt(dx * dx + dy * dy)
  if d < 1 then d = 1 end
  local ux, uy = dx / d, dy / d
  -- 折回侧按出手方向相对目标的偏转选边，弧线转向连贯不打折
  local side = (math.cos(dir1) * uy - math.sin(dir1) * ux) >= 0 and 1 or -1
  -- 出手控制点：沿出剑方向前伸 + 向折回同侧鼓出，去程就是一条大弯
  return {
    x1, y1,
    x1 + ATK_CTRL * math.cos(dir1) - side * ATK_SWAY * uy,
    y1 + ATK_CTRL * math.sin(dir1) + side * ATK_SWAY * ux,
    x4 + OVER_LEN * ux - side * OVER_SIDE * uy,
    y4 + OVER_LEN * uy + side * OVER_SIDE * ux,
    x4, y4,
  }
end

local function bezierAt(b, t)
  local q = 1 - t
  local a1, a2, a3, a4 = q * q * q, 3 * q * q * t, 3 * q * t * t, t * t * t
  return a1 * b[1] + a2 * b[3] + a3 * b[5] + a4 * b[7],
         a1 * b[2] + a2 * b[4] + a3 * b[6] + a4 * b[8]
end

-- ---- 状态切换 ----
local function startIdle(s)
  s.state = ST_IDLE
  s.target = nil
end

local function startAttack(s, mob, now)
  s.state = ST_ATTACK
  s.target = mob.recog
  s.dur = (ATK_MIN + math.random() * ATK_RND) / (speedRate / 100)
  s.t0 = now
  s.bez = makeAttackBezier(s.x, s.y, s.dir, mob.sx, mob.sy)
  -- 记住越过点相对目标的偏移，目标移动时整体平移（保持冲过头的弧形不变形）
  s.overOX = s.bez[5] - mob.sx
  s.overOY = s.bez[6] - mob.sy
end

local function startReturn(s, newState, dur, now)
  s.state = newState
  s.target = nil
  s.dur = dur
  s.t0 = now
  local ox, oy = orbitPos(s)
  s.bez = makeBezier(s.x, s.y, s.dir, ox, oy)
end

-- ---- 建/清 ----
local function buildSwords()
  swords = {}
  for i = 1, swordN do
    -- 每把剑固定对应一张资源：1/2/3/4/99。
    local id = i
    local angle = math.pi * 2 * i / swordN   -- 均匀分布
    while angle > math.pi do
      angle = angle - 2 * math.pi
    end
    swords[i] = {
      id = id,
      angle = angle,
      state = ST_IDLE, target = nil,
      x = 0, y = 0, dir = 0,
      nextAtk = 0,
      lastHit = 0,                           -- 本剑上次发 @feijian_hit 的 tick
      ti = 0,
    }
  end
  hits = {}
  parts = {}
end

-- ---- 状态推进（每帧一次，在下层回调里做） ----
local function updateSword(s, now, dt)
  -- 轨道角在所有状态下持续推进，保持各剑均匀间距
  s.angle = s.angle + SPEED * (speedRate / 100) * dt
  if s.angle > math.pi then s.angle = s.angle - 2 * math.pi end

  if s.state == ST_IDLE or s.state == ST_COOLWAIT then
    local nx, ny = orbitPos(s)
    -- 朝向 = 椭圆切线方向（现有校准实现，Y 分量不取反）
    local tangentX = -RX * math.sin(s.angle)
    local tangentY =  RY * math.cos(s.angle)
    s.dir = math.atan2(tangentY, tangentX)
    s.x, s.y = nx, ny
    if now >= s.nextAtk and #mobs > 0 then
      -- 索敌：优先挑没被其他剑锁定的怪（多剑散开打，还原参考版多目标手感）
      local free = {}
      for mi = 1, #mobs do
        local taken = false
        for si = 1, #swords do
          if swords[si] ~= s and swords[si].target == mobs[mi].recog then
            taken = true
            break
          end
        end
        if not taken then free[#free + 1] = mobs[mi] end
      end
      local pool = (#free > 0) and free or mobs
      startAttack(s, pool[math.random(#pool)], now)
    end
  else
    -- 贝塞尔飞行段（Attack / CoolFly / Back）
    local t = (now - s.t0) / (s.dur * 1000)
    if s.state ~= ST_ATTACK then
      local ox, oy = orbitPos(s)         -- 飞回终点跟随轨道（人物在走）
      s.bez[7], s.bez[8] = ox, oy
    else
      local mob = findMob(s.target)      -- 攻击终点跟随目标
      if mob then
        s.bez[7], s.bez[8] = mob.sx, mob.sy
        -- 越过点随目标平移，折回弧形态保持不变
        s.bez[5], s.bez[6] = mob.sx + s.overOX, mob.sy + s.overOY
      else
        startReturn(s, ST_BACK, BACK_DUR / (speedRate / 100), now)
        t = 0
      end
    end
    if t >= 1 then
      if s.state == ST_ATTACK then
        hits[#hits + 1] = { x = s.bez[7], y = s.bez[8], t0 = now }
        -- 命中帧：发专用封包报告攻击意图（Recog=目标，伤害由服务端权威计算）
        -- 每把剑独立节流；伤害频率上限由服务端按 U599 剑数把守
        if s.target and now - s.lastHit >= HIT_SEND_INTERVAL / (cdRate / 100) then
          Game.SendClientMessage(CM_FEIJIAN, s.target, 0, 0, 0)
          s.lastHit = now
        end
        s.nextAtk = now + (ATK_CD / (cdRate / 100)) * 1000
        startReturn(s, ST_COOLFLY, BACK_DUR / (speedRate / 100), now)
      else
        startIdle(s)
      end
    else
      local t2 = t * t * (3 - 2 * t)     -- smoothstep
      local nx, ny = bezierAt(s.bez, t2)
      s.dir = math.atan2(ny - s.y, nx - s.x)
      s.x, s.y = nx, ny
    end
  end

  -- 星光粒子发射（隔帧抽样；巡航稀疏、飞行段密集，仿参考版 40/160 粒子量）
  s.ti = s.ti + 1
  if s.state ~= ST_IDLE and s.state ~= ST_COOLWAIT then
    emitPart(s, now)                       -- 飞行段：每帧发射
    if s.ti % 2 == 0 then emitPart(s, now) end
  elseif s.ti % 3 == 0 then
    emitPart(s, now)                       -- 巡航段：每3帧发射一颗
  end
end

-- ---- 绘制单把剑（现有透视缩放实现） ----
local function drawSword(s)
  local h = tex(s.id)
  if h ~= 0 then
    -- 剑体：巡航时按朝向做透视缩放（rotation 归一化到 0~360 度）
    local scale = SCALE
    if s.state == ST_IDLE or s.state == ST_COOLWAIT then
      local dirDeg = math.deg(s.dir)
      if dirDeg < 0 then dirDeg = dirDeg + 360 end
      local diff = math.abs(math.abs(dirDeg - 180) - 90)
      if diff < 60 then
        scale = SCALE * (diff / 60 * 0.5 + 0.5)
      end
    end
    Game.DrawTexRotate(h, s.x, s.y, s.dir + BASE_ANGLE, scale, 255)
  else
    -- 贴图加载失败，用圆圈代替（便于排查）
    local color = 0xFF0000
    if s.id == 2 then color = 0x00FF00
    elseif s.id == 3 then color = 0x0000FF
    elseif s.id == 4 then color = 0xFFFF00
    end
    Game.Circle(s.x, s.y, 10, color)
  end
end

-- ---- 主驱动：人物下层（状态推进 + 画 y < 人物 y 的剑） ----
function on_frame_before_myself()
  updatePanel(Game.GetTick())
  if not enabled then return end
  if not (Game.LoadTextureFile and Game.DrawTexRotate) then return end

  local me = Game.GetMySelf()
  local now = Game.GetTick()
  if not me then lastTick = now return end

  local dt = 0
  if lastTick then dt = (now - lastTick) / 1000 end
  if dt > 0.2 then dt = 0.2 end
  lastTick = now

  refreshFrame(me, now)
  if not selfSX then return end

  if #swords == 0 then buildSwords() end

  for i = 1, #swords do
    updateSword(swords[i], now, dt)
  end
  updateParts(now, dt)

  -- 下层：先画粒子再画剑（粒子垫在剑下）
  drawParts(now, 'B')
  for i = 1, #swords do
    local s = swords[i]
    if s.y < selfSY then drawSword(s) end
  end
end

-- ---- 人物上层（画 y >= 人物 y 的剑 + 命中闪光） ----
function on_frame_after_myself()
  if not enabled then return end
  if not selfSX then return end

  local now = Game.GetTick()

  -- 上层：先画粒子再画剑
  drawParts(now, 'F')
  for i = 1, #swords do
    local s = swords[i]
    if s.y >= selfSY then drawSword(s) end
  end

  -- 命中闪光（扩散圆环 + 亮心，全部画在最上层）
  local k = 1
  while k <= #hits do
    local hi = hits[k]
    local p = (now - hi.t0) / (HIT_FLASH * 1000)
    if p >= 1 then
      table.remove(hits, k)
    else
      local r = math.floor(6 + 26 * p)
      local a = math.floor(200 * (1 - p))
      Game.Circle(hi.x, hi.y, r, C_YELLOW)
      Game.FillRect(hi.x - 3, hi.y - 3, hi.x + 3, hi.y + 3, 0x00FFFF, a)
      k = k + 1
    end
  end
end

-- F8 小面板彩色文字。Label 负责布局，DrawText 负责红黄蓝绿着色。
function on_frame()
  if not panelShown or not panel.win then return end
  local info = Game.GetControlInfo(panel.win)
  if not info or not info.visible then return end
  local x, y = info.left + 8, info.top
  Game.DrawText(x, y + 34, panelText[1], C_RED)
  Game.DrawText(x, y + 56, panelText[2], C_YELLOW)
  Game.DrawText(x, y + 78, panelText[3], C_BLUE)
  Game.DrawText(x, y + 100, panelText[4], C_GREEN)
end

-- ---- 热键 ----
function on_keydown(key, shift)
  if key == 119 then                     -- F8：面板开/关
    buildPanel()
    panelShown = not panelShown
    Game.SetControlVisible(panel.win, panelShown)
    if panelShown then
      Game.BringToFront(panel.win)
      updatePanel(Game.GetTick())
    end
  elseif key == 117 then                 -- F6：开/关
    if not unlocked then
      Game.AddChat("【飞剑】尚未学会，输入 @学飞剑 学习", C_YELLOW)
      return
    end
    enabled = not enabled
    if enabled then
      buildSwords()
      Game.AddChat("【飞剑特效】已开启（" .. swordN .. " 把，F7 切数量）", C_GREEN)
    else
      swords = {}; hits = {}; parts = {}
      Game.AddChat("【飞剑特效】已关闭", C_YELLOW)
    end
  elseif key == 118 and enabled then     -- F7：数量 1/3/5
    if swordN == 1 then swordN = 3
    elseif swordN == 3 then swordN = 5
    else swordN = 1 end
    if swordN > maxSwordN then swordN = 1 end
    buildSwords()
    Game.AddChat("【飞剑特效】剑数量: " .. swordN .. "（上限 " .. maxSwordN .. "）", C_GREEN)
  end
end

-- ---- 服务端回程：解锁状态下发（feijian.lua 登录/学习时推送） ----
-- Ident=64001  Param=解锁(0/1)  Tag=飞剑等级  Series=剑数上限
function on_recv_packet(ident, recog, param, tag, series, body)
  if ident == MSG_FEIJIAN_CFG then
    speedRate = math.max(25, math.min(500, tonumber(recog) or 100))
    dmgRate = math.max(25, math.min(1000, tonumber(param) or 100))
    cdRate = math.max(25, math.min(500, tonumber(tag) or 100))
    return true
  end
  if ident ~= MSG_FEIJIAN then return end
  local was = unlocked
  unlocked = (param == 1)
  swordLv  = tag or 0
  maxSwordN = (series and series > 0) and series or 5
  if swordN > maxSwordN then swordN = maxSwordN end
  if unlocked and not was then
    Game.AddChat("【飞剑】已解锁（等级 " .. swordLv .. "，剑数上限 " .. maxSwordN .. "，F6 开启）", C_GREEN)
  elseif not unlocked then
    if enabled then
      enabled = false
      swords = {}; hits = {}; parts = {}
      Game.AddChat("【飞剑】已被收回", C_YELLOW)
    end
  end
  return true                            -- 自定义消息号，吃掉不进引擎默认处理
end

function on_enter_game()
  buildPanel()
  Game.AddChat("【飞剑特效】已加载（F6 开关 / F7 数量 / F8 面板）", C_GREEN)
end

function on_leave_game()
  swords = {}; hits = {}; parts = {}; texCache = {}
  starTex = nil
  lastTick = nil
  selfSX, selfSY = nil, nil
  enabled = false
  unlocked = false
  swordLv = 0
  maxSwordN = 5
  speedRate = 100
  dmgRate = 100
  cdRate = 100
  panelLastTick = 0
  if panel.win then Game.SetControlVisible(panel.win, false) end
  panelShown = false
end
