local schema_name = "万象虎"
local software_name = rime_api.get_distribution_code_name() or ""
local software_version = rime_api.get_distribution_version() or ""
-- 合并平台名称和版本信息
local platform_info = software_name
if software_version ~= "" then
    platform_info = platform_info .. " " .. software_version
end

-- 初始化统计表
input_stats = input_stats or {
    daily = {count = 0, length = 0, fastest = 0, ts = 0},
    weekly = {count = 0, length = 0, fastest = 0, ts = 0},
    monthly = {count = 0, length = 0, fastest = 0, ts = 0},
    yearly = {count = 0, length = 0, fastest = 0, ts = 0},
    lengths = {},
    daily_max = 0,
    recent = {}
}

-- 时间计算函数
local function get_time_ts(unit, now)
    if unit == "day" then
        return os.time{year=now.year, month=now.month, day=now.day, hour=0}
    elseif unit == "week" then
        local d = now.wday == 1 and 6 or (now.wday - 2)
        return os.time{year=now.year, month=now.month, day=now.day - d, hour=0}
    elseif unit == "month" then
        return os.time{year=now.year, month=now.month, day=1, hour=0}
    else -- year
        return os.time{year=now.year, month=1, day=1, hour=0}
    end
end

-- 判断统计命令
local function is_summary_command(text)
    return text == "/rtj" or text == "/ztj" or text == "/ytj" or text == "/ntj" 
        or text == "/tj" or text == "/tjql" or text == "/st" or text == "/en"
end

-- 更新统计数据
local function update_stats(input_length)
    local now = os.date("*t")
    local now_ts = os.time(now)

    -- 一次性计算所有时间戳
    local time_ts = {
        day = get_time_ts("day", now),
        week = get_time_ts("week", now),
        month = get_time_ts("month", now),
        year = get_time_ts("year", now)
    }

    -- 使用局部变量减少表查找
    local daily = input_stats.daily
    local weekly = input_stats.weekly
    local monthly = input_stats.monthly
    local yearly = input_stats.yearly

    if daily.ts ~= time_ts.day then
        daily.count, daily.length, daily.fastest = 0, 0, 0
        daily.ts = time_ts.day
        input_stats.daily_max = 0
        input_stats.recent = {}
    end
    if weekly.ts ~= time_ts.week then
        weekly.count, weekly.length, weekly.fastest = 0, 0, 0
        weekly.ts = time_ts.week
    end
    if monthly.ts ~= time_ts.month then
        monthly.count, monthly.length, monthly.fastest = 0, 0, 0
        monthly.ts = time_ts.month
    end
    if yearly.ts ~= time_ts.year then
        yearly.count, yearly.length, yearly.fastest = 0, 0, 0
        yearly.ts = time_ts.year
    end

    -- 更新统计记录
    daily.count = daily.count + 1
    daily.length = daily.length + input_length
    weekly.count = weekly.count + 1
    weekly.length = weekly.length + input_length
    monthly.count = monthly.count + 1
    monthly.length = monthly.length + input_length
    yearly.count = yearly.count + 1
    yearly.length = yearly.length + input_length

    if input_length > input_stats.daily_max then
        input_stats.daily_max = input_length
    end

    input_stats.lengths[input_length] = (input_stats.lengths[input_length] or 0) + 1

    -- 最近一分钟统计
    local ts = os.time()
    local recent = input_stats.recent
    table.insert(recent, {ts = ts, len = input_length})
    
    local threshold = ts - 60
    local total = 0
    local i = 1
    
    while i <= #recent do
        if recent[i].ts >= threshold then
            total = total + recent[i].len
            i = i + 1
        else
            table.remove(recent, i)
        end
    end
    
    -- 更新最快记录
    if total > daily.fastest then daily.fastest = total end
    if total > weekly.fastest then weekly.fastest = total end
    if total > monthly.fastest then monthly.fastest = total end
    if total > yearly.fastest then yearly.fastest = total end
end

-- 表序列化工具
table.serialize = function(tbl)
    local lines = {"{"}
    for k, v in pairs(tbl) do
        local key = (type(k) == "string") and ("[\"" .. k .. "\"]") or ("[" .. k .. "]")
        local val
        if type(v) == "table" then
            val = table.serialize(v)
        elseif type(v) == "string" then
            val = '"' .. v .. '"'
        else
            val = tostring(v)
        end
        table.insert(lines, string.format("    %s = %s,", key, val))
    end
    table.insert(lines, "}")
    return table.concat(lines, "\n")
end

-- 保存统计到文件
local function save_stats()
    local path = rime_api.get_user_data_dir() .. "/lua/input_stats.lua"
    local file = io.open(path, "w")
    if not file then return end
    file:write("input_stats = " .. table.serialize(input_stats) .. "\n")
    file:close()
end

-- 通用的统计格式化函数
local function format_summary(period, stats, extra)
    if stats.count == 0 then 
        return string.format("※ %s没有任何记录。", period)
    end
    
    local lines = {
        string.format("◉ %s", period),
        string.format("共上屏[%d]次", stats.count),
        string.format("共输入[%d]字", stats.length),
        string.format("最快一分钟输入了[%d]字", stats.fastest)
    }
    
    if extra then
        table.insert(lines, extra)
    end
    
    return table.concat(lines, "\n")
end

-- 日统计报告
local function format_daily_summary()
    return format_summary("今天", input_stats.daily)
end

-- 周统计报告
local function format_weekly_summary()
    local extra = string.format("周内单日最多一次输入[%d]字", input_stats.daily_max)
    return format_summary("本周", input_stats.weekly, extra)
end

-- 月统计报告
local function format_monthly_summary()
    return format_summary("本月", input_stats.monthly)
end

-- 年统计报告
local function format_yearly_summary()
    if input_stats.yearly.count == 0 then 
        return "※ 本年没有任何记录。"
    end
    
    local length_counts = {}
    for length, count in pairs(input_stats.lengths) do
        table.insert(length_counts, {length = length, count = count})
    end
    table.sort(length_counts, function(a, b) return a.count > b.count end)
    local fav = length_counts[1] and length_counts[1].length or 0
    
    local extra = string.format("您最常输入长度为[%d]的词组", fav)
    return format_summary("本年", input_stats.yearly, extra)
end

-- 临时统计报告
local function format_custom_summary(temp_stats)
    local end_ts = temp_stats.last_slash_time or os.time()
    local duration_sec = end_ts - temp_stats.start_time
    local minutes = duration_sec / 60
    
    local speed = 0
    if minutes > 0 then
        speed = math.floor((temp_stats.length / minutes) * 100) / 100
    end
    
    return string.format(
        "\n%s\n"..
        "◉ 开始时间：%s\n"..
        "◉ 结束时间：%s\n"..
        "◉ 统计时长：%d分 %d秒\n"..
        "◉ 输入条数：%d条\n"..
        "◉ 总字数：%d字\n"..
        "◉ 平均速度：%.2f 字/分钟\n"..
        "◉ 最快一分钟输入：%d字\n"..
        "%s\n",
        string.rep("─", 14),
        os.date("%Y-%m-%d %H:%M:%S", temp_stats.start_time),
        os.date("%Y-%m-%d %H:%M:%S", end_ts),
        math.floor(minutes), math.floor(duration_sec % 60),
        temp_stats.count,
        temp_stats.length,
        speed,
        temp_stats.fastest,
        string.rep("─", 14)
    )
end

-- 转换器：处理所有统计命令
local function translator(input, seg, env)
    if input:sub(1, 1) ~= "/" then return end
    local summary = ""
    
    -- 开始临时统计
    if input == "/st" then
        env.pending_start = true
        yield(Candidate("info", seg.start, seg._end, "", ""))

    -- 结束临时统计并生成报告
    elseif input == "/en" then
        if env.is_collecting then
            env.is_collecting = false
            local report = format_custom_summary(env.temp_stats)
            yield(Candidate("stat", seg.start, seg._end, report, "input_stats_summary"))
        else
            yield(Candidate("stat", seg.start, seg._end, "※ 当前没有进行中的统计", ""))
        end

    -- 记录斜杠时间
    elseif env.is_collecting and input == "/" then
        env.temp_stats.last_slash_time = os.time()
        yield(Candidate("info", seg.start, seg._end, "", ""))

    -- 其他统计命令
    else
        if input == "/rtj" then
            summary = "\n" .. string.rep("─", 14) .. "\n" .. format_daily_summary() .. "\n" .. string.rep("─", 14)
        elseif input == "/ztj" then
            summary = "\n" .. string.rep("─", 14) .. "\n" .. format_weekly_summary() .. "\n" .. string.rep("─", 14)
        elseif input == "/ytj" then
            summary = "\n" .. string.rep("─", 14) .. "\n" .. format_monthly_summary() .. "\n" .. string.rep("─", 14)
        elseif input == "/ntj" then
            summary = "\n" .. string.rep("─", 14) .. "\n" .. format_yearly_summary() .. "\n" .. string.rep("─", 14)
        elseif input == "/tj" then
            -- 添加方案和平台信息
            local header = string.format(
                "\n◉ 方案：%s\n◉ 平台：%s\n%s\n",
                schema_name, platform_info, string.rep("─", 14))
            
            -- 组合所有统计报告，用横线分隔
            summary = header ..
                format_daily_summary() .. "\n" .. string.rep("─", 14) .. "\n" ..
                format_weekly_summary() .. "\n" .. string.rep("─", 14) .. "\n" ..
                format_monthly_summary() .. "\n" .. string.rep("─", 14) .. "\n" ..
                format_yearly_summary() .. "\n" .. string.rep("─", 14)
        elseif input == "/tjql" then
            input_stats = {
                daily = {count = 0, length = 0, fastest = 0, ts = 0},
                weekly = {count = 0, length = 0, fastest = 0, ts = 0},
                monthly = {count = 0, length = 0, fastest = 0, ts = 0},
                yearly = {count = 0, length = 0, fastest = 0, ts = 0},
                lengths = {},
                daily_max = 0,
                recent = {}
            }
            save_stats()
            summary = "※ 所有统计数据已清空。"
        end

        if summary ~= "" then
            yield(Candidate("stat", seg.start, seg._end, summary, "input_stats_summary"))
        end
    end
end

-- 加载历史统计数据
local function load_stats_from_lua_file()
    local path = rime_api.get_user_data_dir() .. "/lua/input_stats.lua"
    local ok, result = pcall(function()
        local env = {}
        local f = loadfile(path, "t", env)
        if f then f() end
        return env.input_stats
    end)
    if ok and type(result) == "table" then
        input_stats = result
    else
        input_stats = {
            daily = {count = 0, length = 0, fastest = 0, ts = 0},
            weekly = {count = 0, length = 0, fastest = 0, ts = 0},
            monthly = {count = 0, length = 0, fastest = 0, ts = 0},
            yearly = {count = 0, length = 0, fastest = 0, ts = 0},
            lengths = {},
            daily_max = 0,
            recent = {}
        }
    end
end

local function init(env)
    local ctx = env.engine.context

    -- 初始化统计状态
    env.is_collecting = false
    env.pending_start = false
    env.temp_stats = nil

    -- 加载历史数据
    load_stats_from_lua_file()

    -- 注册提交通知回调
    ctx.commit_notifier:connect(function()
        local commit_text = ctx:get_commit_text()
        if not commit_text then return end

        -- 处理等待开始的状态
        if env.pending_start and commit_text == "" then
            env.is_collecting = true
            env.temp_stats = {
                count = 0,
                length = 0,
                fastest = 0,
                recent = {},
                last_slash_time = nil,
                start_time = os.time()
            }
            env.pending_start = false
        end
        
        -- 重置等待状态
        if env.pending_start and commit_text ~= "" then
            env.pending_start = false
        end
        
        -- 排除统计命令和报告内容
        if commit_text == "" or is_summary_command(commit_text) then return end
        local cand = ctx:get_selected_candidate()
        if cand and cand.comment == "input_stats_summary" then return end

        -- 计算输入长度
        local input_length = utf8.len(commit_text) or string.len(commit_text)

        -- 更新全局统计
        update_stats(input_length)
        save_stats()

        -- 更新临时统计
        if env.is_collecting then            
            env.temp_stats.count = env.temp_stats.count + 1
            env.temp_stats.length = env.temp_stats.length + input_length

            -- 更新最近一分钟输入速度
            local ts = os.time()
            table.insert(env.temp_stats.recent, {ts = ts, len = input_length})
            local threshold = ts - 60
            local total = 0
            local i = 1
            while i <= #env.temp_stats.recent do
                if env.temp_stats.recent[i].ts >= threshold then
                    total = total + env.temp_stats.recent[i].len
                    i = i + 1
                else
                    table.remove(env.temp_stats.recent, i)
                end
            end
            if total > env.temp_stats.fastest then
                env.temp_stats.fastest = total
            end
        end
    end)
end

return { init = init, func = translator }