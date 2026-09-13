-- QFunction-0.lua : intercept g_FunctionNPC labels ahead of QFunction-0.txt
-- Define on_<label> (label without '@') to take over that label.
-- return false = fall through to QFunction-0.txt; anything else = handled.

function on_ButtonClick(player)
    Engine.MainOutMessage('[qfunction] ButtonClick by ' .. (Engine.GetName(player) or '?'))
    return false   -- demo: log only, txt still runs
end

-- on_Struck 调试接管已移除，受击时不再显示 [lua]Struck 提示。
