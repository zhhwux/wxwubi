code_table = require("wubi86_code_table")

-- 全局历史记录结构（FIFO队列）
global_commit_history = {}             -- 存储用户提交的文本历史（先进先出）
global_commit_dict = {}                -- 文本到编码映射：{文本: 编码}
global_seq_words_dict = {}             -- 编码到文本列表映射：{编码: {文本1, 文本2}}

-- 配置参数
global_max_history_size = 100          -- 历史记录最大容量
local punctuation = {                  -- 需过滤的标点符号（提升编码准确性）
    ["，"] = true, ["。"] = true, ["、"] = true,
    ["？"] = true, ["："] = true, ["！"] = true
}

-- 计算表大小的辅助函数
function table_size(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- 检测iOS设备（适配跨平台路径）
local function is_ios_device()
    return os.getenv("HOME") and os.getenv("HOME"):find("/var/mobile/") ~= nil
end

-- 动态获取用户数据目录（兼容iOS与标准系统）
local function get_user_data_dir()
    return is_ios_device() and os.getenv("HOME").."/Documents/" 
                           or rime_api.get_user_data_dir().."/"
end

-- iOS专用：获取非iOS路径（用于导入导出）
local function get_non_ios_path()
    return rime_api.get_user_data_dir().."/lua/user_words.lua"
end

-- iOS专用：导入非iOS路径的词表文件（增量合并）
local function import_from_non_ios_path(env)
    if not is_ios_device() then 
        log.info("[自造简词] 非iOS设备无需导入")
        return false
    end
    
    local non_ios_file = get_non_ios_path()
    local ios_file = get_user_data_dir().."rime_user_words.lua"
    
    -- 加载非iOS词表
    local non_ios_words = {}
    local non_ios_f = loadfile(non_ios_file)
    if non_ios_f then
        non_ios_words = non_ios_f() or {}
    else
        log.warning("[自造简词] 导入失败：无法加载非iOS词表")
        return false
    end
    
    -- 加载当前iOS词表
    local ios_words = {}
    local ios_f = loadfile(ios_file)
    if ios_f then
        ios_words = ios_f() or {}
    else
        -- 文件不存在时创建初始文件
        local fd = io.open(ios_file, "w")
        if fd then
            fd:write("local user_words = {\n}\nreturn user_words")
            fd:close()
            ios_words = {}
        else
            log.warning("[自造简词] 导入失败：无法创建iOS词表文件")
            return false
        end
    end
    
    -- 记录合并前的词条数
    local before_count = table_size(ios_words)
    
    -- 增量合并：保留原有词表，添加新词条
    local merged_count = 0
    for word, code in pairs(non_ios_words) do
        -- 只添加不存在于当前词表的新词
        if not ios_words[word] then
            ios_words[word] = code
            merged_count = merged_count + 1
        end
    end
    
    -- 记录合并后的词条数
    local after_count = table_size(ios_words)
    
    -- 验证合并结果
    if after_count == before_count then
        log.info("[自造简词] 增量合并完成：没有新词条需要导入")
    elseif after_count < before_count + merged_count then
        log.warning(string.format("[自造简词] 合并异常：预期%d新增，实际%d新增", 
            merged_count, after_count - before_count))
        merged_count = after_count - before_count
    end
    
    -- 序列化合并后的词表
    local serialize_str = ""
    for w, c in pairs(ios_words) do
        serialize_str = serialize_str .. string.format('    ["%s"] = "%s",\n', w, c)
    end
    
    local record = "local user_words = {\n" .. serialize_str .. "}\nreturn user_words"
    local fd = io.open(ios_file, "w")
    if not fd then
        log.warning("[自造简词] 导入失败：无法写入iOS文件")
        return false
    end
    
    fd:write(record)
    fd:close()
    log.info(string.format("[自造简词] 增量合并完成：新增%d词条，总词条%d", 
        merged_count, after_count))
    return true, merged_count, after_count
end

-- iOS专用：导出到非iOS路径
local function export_to_non_ios_path()
    if not is_ios_device() then 
        log.info("[自造简词] 非iOS设备无需导出")
        return false
    end
    
    local ios_file = get_user_data_dir().."rime_user_words.lua"
    local non_ios_file = get_non_ios_path()
    
    local f = io.open(ios_file, "r")
    if not f then
        log.warning("[自造简词] 导出失败：iOS词表文件不存在")
        return false
    end
    
    local content = f:read("*a")
    f:close()
    
    -- 确保目标目录存在
    local dir = rime_api.get_user_data_dir().."/lua/"
    if not os.rename(dir, dir) then
        os.execute("mkdir -p "..dir)
    end
    
    local fd = io.open(non_ios_file, "w")
    if not fd then
        log.warning("[自造简词] 导出失败：无法写入非iOS路径")
        return false
    end
    
    fd:write(content)
    fd:close()
    log.info("[自造简词] 已导出永久词表到非iOS路径")
    return true
end

-- 加载永久自造词表（跨平台路径兼容）
function load_permanent_user_words()
    local base_dir = get_user_data_dir()
    -- iOS使用独立文件名，其他平台保留路径结构
    local filename = base_dir .. (is_ios_device() and "rime_user_words.lua" or "lua/user_words.lua")
    
    local f = loadfile(filename)
    if f then
        return f() or {}  -- 成功加载返回词表，否则返回空表
    else
        -- 文件不存在时创建初始空文件
        local record = "local user_words = {\n}\nreturn user_words"
        local fd = io.open(filename, "w")
        if fd then
            fd:setvbuf("line")  -- 行缓冲写入
            fd:write(record)
            fd:close()
        end
        return {}  -- 返回空词表
    end
end

-- 清空永久词表和临时词表（处理/jcql指令）
local function clear_permanent_and_temporary_words(env)
    -- 清空永久词表
    env.permanent_user_words = {}
    env.permanent_seq_words_dict = {}
    
    local base_dir = get_user_data_dir()
    local filename = base_dir .. (is_ios_device() and "rime_user_words.lua" or "lua/user_words.lua")
    
    -- 写入空词表文件
    local record = "local user_words = {\n}\nreturn user_words"
    local fd = io.open(filename, "w")
    if fd then
        fd:setvbuf("line")
        fd:write(record)
        fd:close()
    end
    
    -- 清空临时词表
    global_commit_history = {}
    global_commit_dict = {}
    global_seq_words_dict = {}
    
    return true
end

-- 反转词表：{词 => 码} 转换为 {码 => [词1, 词2]}（优化检索效率）
function reverse_seq_words(user_words)
    local new_dict = {}
    for word, code in pairs(user_words) do
        if not new_dict[code] then
            new_dict[code] = {word}  -- 新建编码条目
        else
            table.insert(new_dict[code], word)  -- 追加同码词
        end
    end
    return new_dict
end

-- 标点过滤函数（确保编码生成不受标点干扰）
local function filter_punctuation(text)
    local result = ""
    for i = 1, utf8.len(text) do
        local char = utf8_sub(text, i, i)
        if not punctuation[char] then
            result = result .. char  -- 保留非标点字符
        end
    end
    return result
end

-- UTF8安全切片（避免截断多字节字符）
function utf8_sub(str, start_char, end_char)
    local start_byte = utf8.offset(str, start_char)
    local end_byte = utf8.offset(str, end_char + 1) or #str + 1
    return string.sub(str, start_byte, end_byte - 1)  -- 计算字节偏移
end

-- 生成虎码编码（核心算法）
function get_tiger_code(word)
    word = filter_punctuation(word)  -- 预处理文本
    local len = utf8.len(word)
    if len < 3 then return "" end    -- 仅处理3字及以上词语

    -- 3字词取首字首码+次字首码+末字首两码
    if len == 3 then
        local code1 = code_table[utf8_sub(word, 1, 1)] or ""
        local code2 = code_table[utf8_sub(word, 2, 2)] or ""
        local code3 = code_table[utf8_sub(word, 3, 3)] or ""
        return string.sub(code1, 1, 1) .. string.sub(code2, 1, 1) .. string.sub(code3, 1, 2)
    -- 4字及以上取首三字首码+末字首码
    else
        local code1 = code_table[utf8_sub(word, 1, 1)] or ""
        local code2 = code_table[utf8_sub(word, 2, 2)] or ""
        local code3 = code_table[utf8_sub(word, 3, 3)] or ""
        local code_last = code_table[utf8_sub(word, len, len)] or ""
        return string.sub(code1, 1, 1) .. string.sub(code2, 1, 1) .. string.sub(code3, 1, 1) .. string.sub(code_last, 1, 1)
    end
end

-- 写入永久自造词到文件（含跨平台路径处理）
function write_permanent_word_to_file(env, word, code)
    env.permanent_user_words[word] = code  -- 更新内存表
    local base_dir = get_user_data_dir()
    local filename = base_dir .. (is_ios_device() and "rime_user_words.lua" or "lua/user_words.lua")
    
    -- 序列化词表为Lua格式
    local serialize_str = ""
    for w, c in pairs(env.permanent_user_words) do
        serialize_str = serialize_str .. string.format('    ["%s"] = "%s",\n', w, c)
    end
    
    local record = "local user_words = {\n" .. serialize_str .. "}\nreturn user_words"
    local fd = io.open(filename, "w")
    if fd then  -- 防护性写入（避免iOS权限问题崩溃）
        fd:setvbuf("line")
        fd:write(record)
        fd:close()
    end
    -- 更新反转表以实时生效
    env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)
end

-- 历史记录管理闭包（绑定env上下文）
local function make_update_history(env)
    return function(commit_text)
        commit_text = filter_punctuation(commit_text)
        if commit_text == "" or utf8.len(commit_text) < 3 then
            return  -- 忽略无效提交
        end

        local context = env.engine.context
        local input_code = context.input
        local input_len = #input_code

        -- 4码输入时仅记录简词（避免原生词重复记录）
        if input_len == 4 then
            local in_temp_dict = global_commit_dict[commit_text] ~= nil
            local in_permanent_dict = env.permanent_user_words[commit_text] ~= nil
            if not (in_temp_dict or in_permanent_dict) then
                return
            end
        end

        -- 生成新编码（忽略无效编码）
        local code = get_tiger_code(commit_text)
        if code == "" then return end

        -- 判断是否重复提交及是否为简码输入
        local is_repeated = (global_commit_dict[commit_text] ~= nil)
        local is_shortcut = (input_len == 4)

        -- 永久化逻辑：重复简词自动转存
        if is_repeated and is_shortcut then
            if not env.permanent_user_words[commit_text] then
                write_permanent_word_to_file(env, commit_text, code)
            end
        end

        -- 删除旧记录（避免重复）
        if global_commit_dict[commit_text] then
            local old_code = global_commit_dict[commit_text]
            -- 从编码映射中移除
            if global_seq_words_dict[old_code] then
                for i, text in ipairs(global_seq_words_dict[old_code]) do
                    if text == commit_text then
                        table.remove(global_seq_words_dict[old_code], i)
                        break
                    end
                end
                if #global_seq_words_dict[old_code] == 0 then
                    global_seq_words_dict[old_code] = nil  -- 清理空表
                end
            end
            -- 从历史队列中移除
            for i, text in ipairs(global_commit_history) do
                if text == commit_text then
                    table.remove(global_commit_history, i)
                    break
                end
            end
            global_commit_dict[commit_text] = nil
        end
        
        -- 添加新记录
        table.insert(global_commit_history, commit_text)
        global_commit_dict[commit_text] = code
        if not global_seq_words_dict[code] then
            global_seq_words_dict[code] = {}  -- 初始化编码条目
        end
        table.insert(global_seq_words_dict[code], commit_text)
        
        -- 清理最早记录（控制内存占用）
        if #global_commit_history > global_max_history_size then
            local removed_text = table.remove(global_commit_history, 1)
            local removed_code = global_commit_dict[removed_text]
            if removed_code and global_seq_words_dict[removed_code] then
                for i, text in ipairs(global_seq_words_dict[removed_code]) do
                    if text == removed_text then
                        table.remove(global_seq_words_dict[removed_code], i)
                        break
                    end
                end
                if #global_seq_words_dict[removed_code] == 0 then
                    global_seq_words_dict[removed_code] = nil
                end
            end
            global_commit_dict[removed_text] = nil
        end
    end
end

-- 输入法处理器模块
local P = {}
function P.init(env)
    -- 初始化永久词表及反转索引
    env.permanent_user_words = load_permanent_user_words()
    env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)
    -- 绑定历史更新函数到提交事件
    env.update_history = make_update_history(env)
    env.engine.context.commit_notifier:connect(function(ctx)
        env.update_history(ctx:get_commit_text())
    end)
end

-- 保留空实现（兼容Rime架构）
function P.func() return 2 end

-- 候选词生成器（动态合并永久词+临时词）
local F = {}
function F.func(input, env)
    local context = env.engine.context
    local input_code = context.input
    
    -- 处理清空指令/jcql
    if input_code == "/jcql" then
        if clear_permanent_and_temporary_words(env) then
            yield(Candidate("clear_db", 0, #input_code, "※ 永久+临时简词已清空", ""))
        else
            yield(Candidate("clear_db", 0, #input_code, "※ 清空失败，请检查文件权限", ""))
        end
        return
    end
    
    -- 处理导入指令/jcdr（增量合并）
    if input_code == "/jcdr" then
        local success, merged_count, total_count = import_from_non_ios_path(env)
        if success then
            -- 重新加载词表
            env.permanent_user_words = load_permanent_user_words()
            env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)
            if merged_count > 0 then
                yield(Candidate("import", 0, #input_code, 
                    string.format("※ 导入完成：新增%d词条，总词条%d", merged_count, total_count), ""))
            else
                yield(Candidate("import", 0, #input_code, 
                    string.format("※ 导入完成：无新词条，总词条%d", total_count), ""))
            end
        else
            yield(Candidate("import", 0, #input_code, "※ 导入失败，请检查文件路径", ""))
        end
        return
    end
    
    -- 处理导出指令/jcdc
    if input_code == "/jcdc" then
        if export_to_non_ios_path() then
            -- 获取当前词条数
            local total_count = table_size(env.permanent_user_words)
            yield(Candidate("export", 0, #input_code, 
                string.format("※ 已导出%d词条到非iOS路径", total_count), ""))
        else
            yield(Candidate("export", 0, #input_code, "※ 导出失败，请检查文件权限", ""))
        end
        return
    end

    local new_candidates = {}
    local has_original_candidates = false
    local input_len = #input_code

    -- 延迟初始化词表（避免启动依赖）
    if env.permanent_seq_words_dict == nil then
        env.permanent_user_words = load_permanent_user_words()
        env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)
    end

    -- 收集原始候选词（保留原始排序）
    local start_pos, end_pos
    for cand in input:iter() do
        if not start_pos then  -- 记录首个候选位置
            start_pos = cand.start
            end_pos = cand._end
        end
        table.insert(new_candidates, cand)
        has_original_candidates = true
    end

    -- 确定候选显示范围（覆盖完整输入）
    local cand_start = start_pos or 0
    local cand_end = end_pos or input_len

    -- 合并永久词与临时词（临时词倒序插入以优先显示最近使用）
    local combined_words = {}
    local combined_count = 0
    
    -- 永久词优先（标记为⭐）
    if env.permanent_seq_words_dict[input_code] then
        for _, word in ipairs(env.permanent_seq_words_dict[input_code]) do
            combined_count = combined_count + 1
            combined_words[combined_count] = {text = word, type = "permanent"}
        end
    end
    
    -- 临时词次之（标记为*）
    if global_seq_words_dict[input_code] then
        for i = #global_seq_words_dict[input_code], 1, -1 do
            local word = global_seq_words_dict[input_code][i]
            combined_count = combined_count + 1
            combined_words[combined_count] = {text = word, type = "history"}
        end
    end

    -- 动态插入候选（避免覆盖原生候选）
    if combined_count > 0 then
        if has_original_candidates then
            -- 从第二位开始插入（保留首位原生候选）
            local insert_position = 2
            for i = 1, combined_count do
                local cand = combined_words[i]
                local comment = (cand.type == "permanent") and "⭐" or "*"
                local new_cand = Candidate(cand.type, cand_start, cand_end, cand.text, comment)
                table.insert(new_candidates, insert_position, new_cand)
                insert_position = insert_position + 1
            end
        else
            -- 无原生候选时直接填充
            for i = 1, combined_count do
                local cand = combined_words[i]
                local comment = (cand.type == "permanent") and "⭐" or "*"
                local new_cand = Candidate(cand.type, cand_start, cand_end, cand.text, comment)
                table.insert(new_candidates, new_cand)
            end
        end
    end

    -- 返回最终候选列表
    for _, cand in ipairs(new_candidates) do
        yield(cand)
    end
end

return { F = F, P = P }