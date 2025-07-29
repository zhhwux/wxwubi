code_table = require("wubi86_code_table")

-- 全局历史记录结构
global_commit_history = {}             -- 历史记录队列（FIFO）
global_commit_dict = {}                 -- 文本到编码映射 {文本: 编码}
global_seq_words_dict = {}              -- 编码到文本列表映射 {编码: {文本1, 文本2}}

-- 文件简词存储
file_user_words = {}                   -- 文件简词：{词组 => 编码}
file_seq_words_dict = {}               -- 文件简词反转表：{编码 => [词组1, 词组2]}

-- 配置参数
global_max_history_size = 100           -- 历史记录最大容量

-- 检测iOS设备（适配跨平台路径）
local function is_ios_device()
    return os.getenv("HOME") and os.getenv("HOME"):find("/var/mobile/") ~= nil
end

-- 动态获取用户数据目录（兼容iOS与标准系统）
local function get_user_data_dir()
    return is_ios_device() and os.getenv("HOME").."/Documents/" 
                           or rime_api.get_user_data_dir().."/"
end

-- 去除临时简词末尾的无效符号（code_table中不存在的字符）
local function trim_trailing_invalid_chars(text)
    local len = utf8.len(text)
    if len == 0 then return text end
    
    -- 从后往前查找最后一个有效字符的位置
    local last_valid_index = len
    for i = len, 1, -1 do
        local char = utf8_sub(text, i, i)
        if code_table[char] then
            last_valid_index = i
            break
        end
    end
    
    -- 截取到最后一个有效字符
    return utf8_sub(text, 1, last_valid_index)
end

-- 加载永久自造词表（支持新旧格式兼容）
function load_permanent_user_words()
    local base_dir = get_user_data_dir()
    -- iOS使用独立文件名，其他平台保留路径结构
    local filename = base_dir .. (is_ios_device() and "rime_user_words.lua" or "lua/user_words.lua")
    
    local f, err = loadfile(filename)
    if f then
        local loaded = f() or {}
        local converted = {}
        local need_update = false
        
        -- 检查并转换旧格式
        for word, data in pairs(loaded) do
            if type(data) == "string" then
                -- 旧格式转换：添加时间戳0
                converted[word] = {code = data, time = 0}
                need_update = true
            else
                -- 新格式直接使用
                converted[word] = data
            end
        end
        
        -- 需要更新文件格式
        if need_update then
            local serialize_str = ""
            for w, d in pairs(converted) do
                serialize_str = serialize_str .. string.format('    ["%s"] = {code = "%s", time = %d},\n', w, d.code, d.time)
            end
            
            local record = "local user_words = {\n" .. serialize_str .. "}\nreturn user_words"
            local fd = io.open(filename, "w")
            if fd then
                fd:setvbuf("line")
                fd:write(record)
                fd:close()
                log.info("[tiger_user_words] Converted old format to new format.")
            else
                log.error("[tiger_user_words] Failed to update file to new format.")
            end
        end
        
        return converted
    else
        -- 文件不存在时创建初始空文件
        local record = "local user_words = {\n}\nreturn user_words"
        local fd = io.open(filename, "w")
        if fd then
            fd:setvbuf("line")
            fd:write(record)
            fd:close()
            log.info("[tiger_user_words] Created initial user_words.lua")
        else
            log.error("[tiger_user_words] Failed to create user_words.lua: " .. (err or "unknown error"))
        end
        return {}
    end
end

-- 反转词表：{词 => 码} 转换为 {码 => [{word=词, time=时间}]}
function reverse_seq_words(user_words)
    local new_dict = {}
    for word, data in pairs(user_words) do
        -- 兼容文件简词和永久简词两种数据结构
        local code = (type(data) == "string") and data or data.code
        
        if not new_dict[code] then
            new_dict[code] = {}
        end
        
        -- 文件简词无时间戳，使用0代替
        local timestamp = (type(data) == "table") and data.time or 0
        table.insert(new_dict[code], {word = word, time = timestamp})
    end
    return new_dict
end

-- UTF8安全切片
function utf8_sub(str, start_char, end_char)
    local start_byte = utf8.offset(str, start_char)
    local end_byte = utf8.offset(str, end_char + 1) or #str + 1
    return string.sub(str, start_byte, end_byte - 1)
end

-- 统一编码生成函数（支持2字及以上词语）
function get_tiger_code(word)
    local valid_chars = {}  -- 存储有效汉字（在编码表中的字符）
    local len = utf8.len(word)
    
    -- 收集有效汉字
    for i = 1, len do
        local char = utf8_sub(word, i, i)
        if code_table[char] then
            table.insert(valid_chars, char)
        end
    end
    
    local valid_count = #valid_chars
    -- 2字词：取每个字的前2码（共4码）
    if valid_count == 2 then
        local code1 = code_table[valid_chars[1]] or ""
        local code2 = code_table[valid_chars[2]] or ""
        return string.sub(code1, 1, 2) .. string.sub(code2, 1, 2)
    -- 3字词：取第1字首码、第2字首码、第3字前两码（共4码）
    elseif valid_count == 3 then
        local code1 = code_table[valid_chars[1]] or ""
        local code2 = code_table[valid_chars[2]] or ""
        local code3 = code_table[valid_chars[3]] or ""
        return string.sub(code1, 1, 1) .. string.sub(code2, 1, 1) .. string.sub(code3, 1, 2)
    -- 4字及以上：取第1字首码、第2字首码、第3字首码、最后一字首码（共4码）
    elseif valid_count >= 4 then
        local code1 = code_table[valid_chars[1]] or ""
        local code2 = code_table[valid_chars[2]] or ""
        local code3 = code_table[valid_chars[3]] or ""
        local code_last = code_table[valid_chars[valid_count]] or ""
        return string.sub(code1, 1, 1) .. string.sub(code2, 1, 1) .. string.sub(code3, 1, 1) .. string.sub(code_last, 1, 1)
    else
        return ""  -- 少于2个有效汉字，不生成编码
    end
end

-- 写入永久自造词到文件（增强版：支持时间戳更新）
function write_permanent_word_to_file(env, word, code, timestamp)
    -- 添加/更新内存表（支持自定义时间戳）
    local new_time = timestamp or os.time()
    env.permanent_user_words[word] = {code = code, time = new_time}
    
    -- 序列化并写入文件
    local base_dir = get_user_data_dir()
    local filename = base_dir .. (is_ios_device() and "rime_user_words.lua" or "lua/user_words.lua")
    
    local serialize_str = ""
    for w, d in pairs(env.permanent_user_words) do
        serialize_str = serialize_str .. string.format('    ["%s"] = {code = "%s", time = %d},\n', w, d.code, d.time)
    end
    
    local record = "local user_words = {\n" .. serialize_str .. "}\nreturn user_words"
    local fd = io.open(filename, "w")
    if fd then
        fd:setvbuf("line")
        fd:write(record)
        fd:close()
        log.info("[永久简词] 已更新词条: "..word.." (时间戳:"..new_time..")")
    else
        log.error("[永久简词] 文件写入失败: "..filename)
    end
    
    -- 更新反转表
    env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)
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

-- iOS专用：导入非iOS路径的词表文件（增量合并）
local function import_from_non_ios_path(env)
    if not is_ios_device() then 
        log.info("[自造简词] 非iOS设备无需导入")
        return false
    end
    
    local non_ios_file = rime_api.get_user_data_dir().."/lua/user_words.lua"
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
    local before_count = 0
    for _ in pairs(ios_words) do before_count = before_count + 1 end
    
    -- 增量合并：保留原有词表，添加新词条
    local merged_count = 0
    for word, data in pairs(non_ios_words) do
        -- 只添加不存在于当前词表的新词
        if not ios_words[word] then
            -- 兼容旧格式数据
            if type(data) == "string" then
                ios_words[word] = {code = data, time = 0}  -- 旧格式转换
            else
                ios_words[word] = data
            end
            merged_count = merged_count + 1
        end
    end
    
    -- 记录合并后的词条数
    local after_count = 0
    for _ in pairs(ios_words) do after_count = after_count + 1 end
    
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
    for w, d in pairs(ios_words) do
        if type(d) == "string" then
            serialize_str = serialize_str .. string.format('    ["%s"] = "%s",\n', w, d)
        else
            serialize_str = serialize_str .. string.format('    ["%s"] = {code = "%s", time = %d},\n', w, d.code, d.time)
        end
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
    local non_ios_file = rime_api.get_user_data_dir().."/lua/user_words.lua"
    
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

-- 文件简词相关功能主要用于编码生成和词条中转，而不负责生成候选词。
-- 文件简词加载功能（初始化+指令触发）
local function load_file_shortcuts()
    -- 获取文件路径
    local data_dir = rime_api.get_user_data_dir()
    local file_path = data_dir .. "/custom_phrase/user.txt"
    
    -- 清空现有文件简词
    file_user_words = {}
    file_seq_words_dict = {}
    
    -- 检查文件是否存在，不存在则创建空文件
    local f, err = io.open(file_path, "r")
    if not f then
        -- 文件不存在，创建空文件
        log.warning("[文件简词] 文件不存在，创建空文件: " .. file_path)
        local create_fd = io.open(file_path, "w")
        if create_fd then
            create_fd:close()
            log.info("[文件简词] 成功创建空文件: " .. file_path)
        else
            log.error("[文件简词] 创建文件失败: " .. file_path .. " 错误: " .. (err or "未知"))
            return false, "创建文件失败: " .. (err or "未知")
        end
        -- 重新尝试打开创建的空文件
        f, err = io.open(file_path, "r")
        if not f then
            log.error("[文件简词] 无法打开创建的文件: " .. file_path .. " 错误: " .. (err or "未知"))
            return false, "无法打开文件: " .. (err or "未知")
        end
    end
    
    -- 读取文件内容并处理（原有逻辑保持不变）
    local lines = {}
    for line in f:lines() do
        table.insert(lines, line)
    end
    f:close()
    
    local processed_count = 0
    local generated_count = 0
    local skipped_count = 0
    
    -- 处理每一行（原有逻辑保持不变）
    for i, line in ipairs(lines) do
        -- 跳过空行
        if line == "" then
            skipped_count = skipped_count + 1
            goto continue
        end
        
        -- 查找第一个制表符位置
        local tab_pos = string.find(line, "\t")
        local word, rest, code
        
        if tab_pos then
            -- 拆分词组和剩余部分
            word = string.sub(line, 1, tab_pos - 1)
            rest = string.sub(line, tab_pos + 1)
            
            -- 情况1: 行首+文字+制表符+行末 (生成编码)
            if rest == "" then
                code = get_tiger_code(word)
                if code ~= "" then
                    file_user_words[word] = code
                    lines[i] = word .. "\t" .. code
                    processed_count = processed_count + 1
                    generated_count = generated_count + 1
                else
                    skipped_count = skipped_count + 1
                end
                
            -- 情况2: 已有4码编码+制表符+任意内容 (保留原编码)
            elseif string.match(rest, "^%a%a%a%a\t") then
                code = string.sub(rest, 1, 4)
                file_user_words[word] = code
                processed_count = processed_count + 1  -- 保留原行不修改
            
            -- 情况3: 文字+制表符+非4码字母+任意内容 (忽略词条)
            elseif string.match(rest, "^%a+") and #string.match(rest, "^%a+") ~= 4 and #string.match(rest, "^%a+") > 0 then
                skipped_count = skipped_count + 1  -- 统计为无效行
                
            -- 情况4: 文字+制表符+非字母内容 (生成编码插入)
            elseif string.match(rest, "[^%a]") then
                code = get_tiger_code(word)
                if code ~= "" then
                    file_user_words[word] = code
                    lines[i] = word .. "\t" .. code .. "\t" .. rest
                    processed_count = processed_count + 1
                    generated_count = generated_count + 1
                else
                    skipped_count = skipped_count + 1
                end
                
            -- 其他情况 (如已有4码编码无后缀)
            else
                if #rest == 4 and string.match(rest, "^%a%a%a%a$") then
                    file_user_words[word] = rest
                    processed_count = processed_count + 1
                else
                    skipped_count = skipped_count + 1
                end
            end
        else
            -- 没有制表符的情况 (行首+文字+行末)
            word = line
            code = get_tiger_code(word)
            if code ~= "" then
                file_user_words[word] = code
                lines[i] = word .. "\t" .. code
                processed_count = processed_count + 1
                generated_count = generated_count + 1
            else
                skipped_count = skipped_count + 1
            end
        end
        
        ::continue::
    end
    
    -- 更新文件（添加/修改编码）
    local fd, err = io.open(file_path, "w")
    if not fd then
        log.warning("[文件简词] 无法写入文件: " .. file_path .. " 错误: " .. (err or "未知"))
        return false, "写入失败: " .. (err or "未知")
    end
    
    for _, line in ipairs(lines) do
        fd:write(line .. "\n")
    end
    fd:close()
    
    -- 手动构建文件简词反转表
    file_seq_words_dict = {}
    for word, code in pairs(file_user_words) do
        if not file_seq_words_dict[code] then
            file_seq_words_dict[code] = {}
        end
        table.insert(file_seq_words_dict[code], word)
    end
    
    log.info(string.format(
        "[文件简词] 编码生成完成: 处理%d词条 (生成%d编码, 保留%d编码), 跳过%d无效行",
        processed_count, generated_count, processed_count - generated_count, skipped_count
    ))
    
    return true, string.format(
        "※ 文件简词编码生成: %d词条生效 (%d新生成, %d原编码), %d无效行",
        processed_count, generated_count, processed_count - generated_count, skipped_count
    )
end

-- 清理文件简词
local function clear_file_shortcuts(env)
    -- 清空内存数据
    file_user_words = {}
    file_seq_words_dict = {}
    
    -- 删除物理文件
    local file_path = rime_api.get_user_data_dir() .. "/custom_phrase/user.txt"
    local fd, err = io.open(file_path, "w")
    if fd then
        fd:close()
        log.info("[文件简词清理] 文件已清空: " .. file_path)
        return true, "※ 文件简词已清空（内存+文件）"
    else
        log.error("[文件简词清理] 文件操作失败: " .. file_path .. " 错误: " .. (err or "未知"))
        return false, "※ 清理失败：无法写入文件"
    end
end

-- 历史记录管理核心函数（关键修改：永久词时间戳实时更新）
local function make_update_history(env)
    return function(commit_text)
        -- 去除临时简词末尾的无效符号
        commit_text = trim_trailing_invalid_chars(commit_text)
        if commit_text == "" then return end
        
        -- 直接生成编码（内部会过滤非编码表字符）
        local code = get_tiger_code(commit_text)
        if code == "" then return end  -- 二字词在此被过滤

        -- 获取当前输入编码及其长度
        local context = env.engine.context
        local input_code = context.input
        local input_len = #input_code

        -- 4码输入时的特殊处理（优化：移除commit调用）
        if input_len == 4 then
            local in_temp_dict = global_commit_dict[commit_text] ~= nil
            local in_permanent_dict = env.permanent_user_words[commit_text] ~= nil
            
            -- 原生简词不记录
            if not (in_temp_dict or in_permanent_dict) then
                return
            end
        end

        -- 检测是否存在重复记录
        local is_repeated = (global_commit_dict[commit_text] ~= nil)
        local is_shortcut = (input_len == 4)  -- 简码输入标识

        -- 永久化逻辑（在历史记录更新前）
        if is_shortcut and (is_repeated or env.permanent_user_words[commit_text]) then
            -- 存在则更新时间戳，不存在则新建
            if env.permanent_user_words[commit_text] then
                -- 更新时间戳并写入文件（使用当前时间）
                write_permanent_word_to_file(env, commit_text, code)
            else
                write_permanent_word_to_file(env, commit_text, code)
            end
        end
        
        -- 删除已有记录
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
                    global_seq_words_dict[old_code] = nil
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
        
        -- 添加新记录（保存原始文本）
        table.insert(global_commit_history, commit_text)
        global_commit_dict[commit_text] = code
        
        if not global_seq_words_dict[code] then
            global_seq_words_dict[code] = {}
        end
        table.insert(global_seq_words_dict[code], commit_text)
        
        -- 清理最早记录
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
    -- 加载永久自造词表
    env.permanent_user_words = load_permanent_user_words()
    env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)
    
    -- 初始化文件简词（部署时自动加载）
    local success, msg = load_file_shortcuts()
    if success then
        log.info("[文件简词] 初始化成功: " .. msg)
    else
        log.warning("[文件简词] 初始化失败: " .. msg)
    end
    
    -- 创建带env闭包的历史更新函数
    env.update_history = make_update_history(env)
    
    env.engine.context.commit_notifier:connect(function(ctx)
        env.update_history(ctx:get_commit_text())
    end)
end

function P.func() return 2 end  -- 保留空实现

-- 候选词生成模块（修复版）
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
            local total_count = 0
            for _ in pairs(env.permanent_user_words) do total_count = total_count + 1 end
            yield(Candidate("export", 0, #input_code, 
                string.format("※ 已导出%d词条到非iOS路径", total_count), ""))
        else
            yield(Candidate("export", 0, #input_code, "※ 导出失败，请检查文件权限", ""))
        end
        return
    end
    
    -- 处理文件简词编码生成指令/wjjc
    if input_code == "/wjjc" then
        local success, msg = load_file_shortcuts()
        if success then
            yield(Candidate("file_shortcut", 0, #input_code, msg, ""))
        else
            yield(Candidate("file_shortcut", 0, #input_code, "※ 文件简词编码生成失败: " .. (msg or "未知错误"), ""))
        end
        return
    end
  
    -- 新增指令 /wjql
    if input_code == "/wjql" then
        local success, msg = clear_file_shortcuts(env)
        yield(Candidate("clear_file", 0, #input_code, msg, ""))
        return
    end
   
    -- 新增指令：文件简词转永久简词 /zyj
    if input_code == "/zyj" then
        -- 先执行/wjjc指令确保文件简词已加载
        local success, msg = load_file_shortcuts()
        if not success then
            yield(Candidate("file_to_permanent", 0, #input_code, 
                "※ 转换失败: " .. (msg or "文件简词加载失败"), ""))
            return
        end
        
        local added_count = 0
        local current_time = os.time()
        
        for word, code in pairs(file_user_words) do
            -- 检查词条是否已存在（兼容新旧数据结构）
            local exists = false
            if env.permanent_user_words[word] then
                if type(env.permanent_user_words[word]) == "table" then
                    exists = true
                elseif type(env.permanent_user_words[word]) == "string" then
                    exists = (env.permanent_user_words[word] == code)
                end
            end
            
            if not exists then
                env.permanent_user_words[word] = {code = code, time = current_time}
                added_count = added_count + 1
            end
        end
        
        -- 写入永久词表文件
        local base_dir = get_user_data_dir()
        local filename = base_dir .. (is_ios_device() and "rime_user_words.lua" or "lua/user_words.lua")
        
        local serialize_str = ""
        for w, d in pairs(env.permanent_user_words) do
            if type(d) == "table" then
                serialize_str = serialize_str .. string.format('    ["%s"] = {code = "%s", time = %d},\n', w, d.code, d.time)
            else
                -- 兼容旧格式转换
                serialize_str = serialize_str .. string.format('    ["%s"] = {code = "%s", time = %d},\n', w, d, current_time)
            end
        end
        
        local record = "local user_words = {\n" .. serialize_str .. "}\nreturn user_words"
        local fd = io.open(filename, "w")
        if fd then
            fd:setvbuf("line")
            fd:write(record)
            fd:close()
            -- 更新反转表
            env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)
            yield(Candidate("file_to_permanent", 0, #input_code, 
                string.format("※ 已添加%d个文件简词到永久简词", added_count), ""))
        else
            yield(Candidate("file_to_permanent", 0, #input_code, 
                "※ 转换失败：永久词表文件写入错误", ""))
        end
        return
    end

    -- 新增指令：永久简词转文件简词 /zwj
    if input_code == "/zwj" then
        env.permanent_user_words = load_permanent_user_words()
        env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)

        local file_path = rime_api.get_user_data_dir() .. "/custom_phrase/user.txt"
        local fd, err = io.open(file_path, "a")  -- 追加模式
        if not fd then
            yield(Candidate("permanent_to_file", 0, #input_code, 
                "※ 打开文件失败: " .. file_path .. " 错误: " .. (err or "未知"), ""))
            return
        end
        
        local added_count = 0
        for word, data in pairs(env.permanent_user_words) do
            -- 统一获取编码
            local code = (type(data) == "table") and data.code or data
            
            -- 检查是否已存在
            if not file_user_words[word] then
                -- 写入文件
                fd:write(word .. "\t" .. code .. "\n")
                -- 更新内存
                file_user_words[word] = code
                if not file_seq_words_dict[code] then
                    file_seq_words_dict[code] = {}
                end
                table.insert(file_seq_words_dict[code], word)
                added_count = added_count + 1
            end
        end
        fd:close()
        
        yield(Candidate("permanent_to_file", 0, #input_code, 
            string.format("※ 已添加%d个永久简词到文件", added_count), ""))
        return
    end

    local new_candidates = {}
    local has_original_candidates = false
    local input_len = #input_code  -- 直接获取输入长度

    -- 确保永久词表已初始化
    if env.permanent_seq_words_dict == nil then
        env.permanent_user_words = load_permanent_user_words()
        env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)
    end

    -- 收集原始候选词并获取位置信息
    local start_pos, end_pos
    for cand in input:iter() do
        if not start_pos then  -- 获取第一个候选的位置作为参考
            start_pos = cand.start
            end_pos = cand._end
        end
        table.insert(new_candidates, cand)
        has_original_candidates = true
    end

    -- 设置候选位置（关键修复：当无原生候选时使用完整输入长度）
    local cand_start = start_pos or 0
    local cand_end = end_pos or input_len

    -- 合并临时词与永久词（临时词在前，永久词在后）
    local combined_words = {}
    local combined_count = 0
    
    -- 临时词（标记为*）
    if global_seq_words_dict[input_code] then
        for i = #global_seq_words_dict[input_code], 1, -1 do
            local word = global_seq_words_dict[input_code][i]
            combined_count = combined_count + 1
            combined_words[combined_count] = {text = word, type = "history"}
        end
    end
    
    -- 永久词（标记为⭐），按时间戳倒序
    if env.permanent_seq_words_dict[input_code] then
        -- 获取永久词列表并按时间戳排序
        local permanent_list = {}
        for _, item in ipairs(env.permanent_seq_words_dict[input_code]) do
            table.insert(permanent_list, {
                text = item.word, 
                time = item.time
            })
        end
        
        -- 按时间戳降序排序（最近使用的在前）
        table.sort(permanent_list, function(a, b)
            return a.time > b.time
        end)
        
        for _, item in ipairs(permanent_list) do
            combined_count = combined_count + 1
            combined_words[combined_count] = {text = item.text, type = "permanent"}
        end
    end

    -- 动态插入候选（如有其它候选则从次选开始插入，否则从首选开始插入，逻辑复杂勿改）
    if combined_count > 0 then
        if has_original_candidates then
            -- 从第二位开始插入（保留首位原生候选）
            local insert_position = 2
            for i = 1, combined_count do
                local cand = combined_words[i]
                local comment = 
                    cand.type == "permanent" and "⭐" or "*"
                local new_cand = Candidate(cand.type, 0, input_len, cand.text, comment)
                table.insert(new_candidates, insert_position, new_cand)
                insert_position = insert_position + 1
            end
        else
            for i = 1, combined_count do
                local cand = combined_words[i]
                local comment = 
                    cand.type == "permanent" and "⭐" or "*"
                local new_cand = Candidate(cand.type, 0, input_len, cand.text, comment)
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
