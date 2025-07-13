-- 更可靠的 iOS 检测
local function is_ios_device()
    return os.getenv("HOME") and os.getenv("HOME"):find("/var/mobile/") ~= nil
end

-- 模块级局部变量（用于非iOS设备）
local commit_history = {}
local history_index = 1
local history_count = 0

local function init(env)
    local config = env.engine.schema.config
    -- 静态配置读取
    local quick_text_pattern = config:get_string("recognizer/patterns/quick_text")
    env.double_symbol_trigger = quick_text_pattern 
                               and string.sub(quick_text_pattern, 2, 2) 
                               or "'"
    
    -- 预计算双符号触发字符串
    env.double_trigger_string = env.double_symbol_trigger .. env.double_symbol_trigger
    env.double_more_trigger = "'`"
    
    -- iOS设备：使用文件持久化保存
    if is_ios_device() then
        -- 初始化历史记录
        env.commit_history = {}
        env.history_index = 1
        env.history_count = 0
        
        -- 持久化文件路径 (iOS专用)
        env.persistence_file = os.getenv("HOME") .. "/Documents/rime_history.txt"
        
        -- 从文件加载历史记录
        local function load_history()
            local file = io.open(env.persistence_file, "r")
            if not file then return end
            
            local data = file:read("*a")
            file:close()
            
            if #data > 0 then
                local saved = {}
                for entry in string.gmatch(data, "[^\n]+") do
                    table.insert(saved, entry)
                end
                
                local count = #saved
                if count > 100 then count = 100 end
                
                for i = 1, 100 do
                    local pos = (i <= count) and (i) or nil
                    env.commit_history[i] = saved[pos] or false
                end
                
                env.history_count = count
                env.history_index = (count % 100) + 1
            end
        end
        
        -- 保存历史记录到文件
        env.save_history = function()
            local content = {}
            for i = 1, math.min(env.history_count, 100) do
                local idx = (env.history_index - env.history_count - 1 + i) % 100
                if idx <= 0 then idx = idx + 100 end
                if env.commit_history[idx] then
                    table.insert(content, env.commit_history[idx])
                end
            end
            
            local file = io.open(env.persistence_file, "w")
            if file then
                file:write(table.concat(content, "\n"))
                file:close()
            end
        end
        
        -- 加载历史记录
        load_history()
        
        -- 提交通知器 (iOS专用)
        env.commit_notifier = env.engine.context.commit_notifier:connect(function(ctx)
            local text = ctx:get_commit_text()
            if text == "" then return end
            
            env.commit_history[env.history_index] = text
            env.history_index = env.history_index % 100 + 1
            env.history_count = math.min(env.history_count + 1, 100)
            
            -- iOS: 每次提交后立即保存
            env.save_history()
        end)
    else
        -- 非iOS设备: 使用模块闭包变量
        -- 直接创建填充好的循环缓冲区
        if #commit_history == 0 then  -- 首次初始化
            for i = 1, 100 do 
                commit_history[i] = false  -- 使用false标记空槽位
            end
            history_index = 1
            history_count = 0
        end
        
        -- 将模块变量引用到env中
        env.commit_history = commit_history
        env.history_index = history_index
        env.history_count = history_count
        
        -- 提交通知器 (非iOS专用)
        env.commit_notifier = env.engine.context.commit_notifier:connect(function(ctx)
            local text = ctx:get_commit_text()
            if text == "" then return end
            
            env.commit_history[env.history_index] = text
            env.history_index = env.history_index % 100 + 1
            env.history_count = math.min(env.history_count + 1, 100)
        end)
    end
    
    -- 更新通知器（iOS和非iOS共用）
    env.update_notifier = env.engine.context.update_notifier:connect(function(ctx)
        local input = ctx.input
        
        -- 新增：处理清除历史记录命令
        if input == "/spql" then
            -- 清除所有历史记录
            for i = 1, 100 do
                env.commit_history[i] = false
            end
            env.history_index = 1
            env.history_count = 0
            
            -- iOS设备：更新持久化文件
            if is_ios_device() and env.save_history then
                env.save_history()
            end
            
            -- 显示清除成功提示
            env.engine:commit_text("历史记录已清除")
            ctx:clear()
            return
        end
        
        -- 原逻辑：处理长度为2的输入
        if #input ~= 2 then return end
        
        -- 1. 最新记录
        if input == env.double_trigger_string then
            -- 使用模运算定位最新记录
            local last_index = (env.history_index - 2) % 100 + 1
            if env.commit_history[last_index] then
                env.engine:commit_text(env.commit_history[last_index])
                ctx:clear()
            end
        
        -- 2. 历史记录
        elseif input == env.double_more_trigger and env.history_count > 0 then
            -- 避免中间table创建
            local output = {}
            local start_idx = env.history_index - env.history_count
            if start_idx < 1 then start_idx = start_idx + 100 end
            
            for i = 1, env.history_count do
                local idx = (start_idx + i - 2) % 100 + 1
                output[i] = env.commit_history[idx]
            end
            
            env.engine:commit_text(table.concat(output))
            ctx:clear()
        end
    end)
end

local function fini(env)
    -- iOS设备：保存历史记录
    if is_ios_device() and env.save_history then
        env.save_history()
    end
    
    -- 断开事件监听
    if env.update_notifier then 
        env.update_notifier:disconnect() 
    end
    if env.commit_notifier then 
        env.commit_notifier:disconnect() 
    end
    
    -- 非iOS设备：保留历史记录在闭包中（下次初始化时仍可用）
end

-- 处理器
local function processor(key_event, env)
    return #env.engine.context.input == 2
end

return { init = init, fini = fini, func = processor }