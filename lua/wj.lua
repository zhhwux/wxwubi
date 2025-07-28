--9.0 功能完整版
local T = {}

T.prefix = "Z"
local regex_enabled = true  -- 默认启用正则模式
local regex_api = {  -- 保留开关接口，供未来扩展
    enable = function() regex_enabled = true end,
    disable = function() regex_enabled = false end,
    is_enabled = function() return regex_enabled end
}

local function startsWith(str, start)
    return str:sub(1, #start) == start
end

-- 文件读取功能
local function readFileContent(path)
    local file = io.open(path, "r")
    if not file then
        return nil, "文件不存在"
    end
    local content = {}
    for line in file:lines() do
        table.insert(content, line)
    end
    file:close()
    return content
end

-- 文件写入功能
local function writeFileContent(path, content)
    local file = io.open(path, "w")
    if not file then
        return false, "无法写入文件"
    end
    for i, line in ipairs(content) do
        file:write(line)
        if i < #content then
            file:write("\n")
        end
    end
    file:close()
    return true
end

-- 获取用户数据目录下的文件列表（带缓存）
local function get_file_cache(env)
    if not env.file_cache then
        env.file_cache = {}
        local user_dir = rime_api.get_user_data_dir()
        
        -- 跨平台文件扫描命令
        local cmd
        if package.config:sub(1,1) == '\\' then  -- Windows
            cmd = string.format('dir /b /s /a-d "%s"', user_dir)
        else  -- Linux/Mac
            cmd = string.format('find "%s" -type f', user_dir)
        end
        
        local handle = io.popen(cmd)
        if handle then
            for path in handle:lines() do
                -- 转换为相对于用户数据目录的路径
                local rel_path = path:gsub(user_dir .. "/", "")
                table.insert(env.file_cache, rel_path)
            end
            handle:close()
        end
    end
    return env.file_cache
end

-- 获取用户数据目录下的文件夹列表（带缓存）
local function get_dir_cache(env)
    if not env.dir_cache then
        env.dir_cache = {}
        local user_dir = rime_api.get_user_data_dir()
        
        -- 跨平台文件夹扫描命令
        local cmd
        if package.config:sub(1,1) == '\\' then  -- Windows
            cmd = string.format('dir /b /s /ad "%s"', user_dir)
        else  -- Linux/Mac
            cmd = string.format('find "%s" -type d', user_dir)
        end
        
        local handle = io.popen(cmd)
        if handle then
            for path in handle:lines() do
                -- 转换为相对于用户数据目录的路径
                local rel_path = path:gsub(user_dir .. "/", "")
                table.insert(env.dir_cache, rel_path)
            end
            handle:close()
        end
    end
    return env.dir_cache
end

-- 模糊文件搜索核心函数
local function fuzzy_search_files(search_terms, files)
    local results = {}
    
    for _, file in ipairs(files) do
        local lower_file = file:lower()
        local match_all = true
        
        -- 检查是否包含所有搜索词
        for _, term in ipairs(search_terms) do
            if not lower_file:find(term, 1, true) then
                match_all = false
                break
            end
        end
        
        if match_all then
            table.insert(results, file)
        end
    end
    
    return results
end

-- 确保目录存在
local function ensure_directory_exists(full_dir_path)
    -- 检查目录是否已存在
    local cmd_check
    if package.config:sub(1,1) == '\\' then  -- Windows
        cmd_check = string.format('if not exist "%s" mkdir "%s"', full_dir_path, full_dir_path)
    else  -- Linux/Mac
        cmd_check = string.format('mkdir -p "%s"', full_dir_path)
    end
    
    return os.execute(cmd_check)
end

-- 文件名模糊搜索（增强版）
local function fuzzy_file_search(input, seg, env)
    -- 匹配 Z关键词 格式
    local total_pattern = input:match("^Z(.*)$")
    if not total_pattern then return false end
    
    local files = get_file_cache(env)
    local search_terms = {}
    local selection_index = nil
    
    -- 从末尾提取数字索引（可能多位）
    local index_str = ""
    for i = #total_pattern, 1, -1 do
        local char = total_pattern:sub(i, i)
        if char:match("%d") then
            index_str = char .. index_str
        else
            -- 找到非数字字符，停止提取
            break
        end
    end
    
    -- 如果提取到了数字且关键词部分不为空，才视为选择索引
    if #index_str > 0 and #total_pattern > #index_str then
        selection_index = tonumber(index_str)
        total_pattern = total_pattern:sub(1, #total_pattern - #index_str)
    end
    
    -- 提取搜索关键词（支持空格分隔）
    for term in total_pattern:gmatch("%S+") do
        if term ~= "" then
            table.insert(search_terms, term:lower())
        end
    end
    
    -- 无搜索词时返回
    if #search_terms == 0 then return false end
    
    -- 模糊匹配所有文件
    local results = fuzzy_search_files(search_terms, files)
    
    -- 显示结果
    if #results > 0 then
        -- 按路径长度排序（越短越可能相关）
        table.sort(results, function(a, b)
            return #a < #b
        end)
        
        -- 处理数字索引选择
        if selection_index and selection_index > 0 and selection_index <= #results then
            -- 显示选定的单个结果
            yield(Candidate(input, seg.start, seg._end, results[selection_index], 
                            "📁 文件 (选择第"..selection_index.."个)"))
            return true
        end
        
        -- 显示所有结果（带索引标记）
        for i, file in ipairs(results) do
            yield(Candidate(input, seg.start, seg._end, file, "📁"..i))
        end
  
        return true
    end
    
    -- 无匹配结果
    yield(Candidate(input, seg.start, seg._end, "未找到匹配文件", ""))
    return true
end

-- 处理转义字符
local function unescape_string(str)
    -- 处理转义序列：将 \n 替换为换行符，\\ 替换为单个 \
    return str:gsub("\\(.)", {
        n = "\n",    -- 换行符
        ["\\"] = "\\", -- 反斜杠自身
        r = "\r",    -- 回车符
        t = "\t"     -- 制表符
    })
end

-- 转义特殊字符用于预览显示
local function escape_for_display(str)
    return str:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
end

-- 处理文件/文件夹创建和删除请求
local function handleFileSystemRequest(input, seg, env)
    -- 匹配删除文件命令（优化版：支持中间阶段的文件检索）
    local del_partial_pattern = "^Zdel\"(.-)\"?$"
    local del_path_part = input:match(del_partial_pattern)
    
    -- 优先处理删除命令的中间阶段
    if del_path_part and not input:match("^Zdel\".+\"$") then
        -- 提取搜索词（支持空格分隔多个关键词）
        local search_terms = {}
        for term in del_path_part:gmatch("%S+") do
            if term ~= "" then
                table.insert(search_terms, term:lower())
            end
        end
        
        -- 无搜索词时显示提示
        if #search_terms == 0 then
            yield(Candidate(input, seg.start, seg._end, "请输入要删除的文件关键词（支持空格分隔）", ""))
            return true
        end
        
        -- 获取文件列表并模糊匹配
        local files = get_file_cache(env)
        local results = fuzzy_search_files(search_terms, files)
        
        -- 按路径长度排序
        table.sort(results, function(a, b) return #a < #b end)
        
        -- 显示匹配结果
        if #results > 0 then
            yield(Candidate(input, seg.start, seg._end, "匹配到 "..#results.." 个文件", "请补全文件名或添加数字索引"))
            for i, file in ipairs(results) do
                yield(Candidate(input, seg.start, seg._end, file, "📁"..i))
            end
            return true
        else
            yield(Candidate(input, seg.start, seg._end, "未找到匹配文件: "..del_path_part, ""))
            return true
        end
    end

    -- 匹配创建文件/文件夹命令
    local create_pattern = "^Znew\"(.*)\"$"
    local create_path = input:match(create_pattern)
    
    -- 匹配删除文件/文件夹命令
    local delete_pattern = "^Zdel\"(.*)\"$"
    local delete_path = input:match(delete_pattern)
    
    -- 没有匹配到任何完整命令
    if not create_path and not delete_path then return false end
    
    local is_create = create_path ~= nil
    local target_path = create_path or delete_path
    
    -- 检查是否是文件夹操作（以/结尾）
    local is_directory = target_path:sub(-1) == "/"
    
    -- 提取选择索引
    local selection_index = nil
    local index_str = ""
    for i = #target_path, 1, -1 do
        local char = target_path:sub(i, i)
        if char:match("%d") then
            index_str = char .. index_str
        else
            break
        end
    end
    
    -- 如果提取到了数字且路径部分不为空，才视为选择索引
    if #index_str > 0 and #target_path > #index_str then
        selection_index = tonumber(index_str)
        target_path = target_path:sub(1, #target_path - #index_str)
    end
    
    -- 获取对应缓存
    local items = is_directory and get_dir_cache(env) or get_file_cache(env)
    local search_terms = {target_path:lower()}
    
    -- 模糊匹配
    local matches = fuzzy_search_files(search_terms, items)
    table.sort(matches, function(a, b) return #a < #b end)
    
    -- 处理索引选择
    if selection_index and selection_index > 0 and selection_index <= #matches then
        matches = {matches[selection_index]}
    end
    
    -- 如果是创建操作
    if is_create then
        -- 如果是文件夹创建
        if is_directory then
            -- 如果没有匹配项，直接创建新文件夹
            if #matches == 0 then
                local user_dir = rime_api.get_user_data_dir()
                local full_path = user_dir .. "/" .. target_path
                
                -- 创建文件夹
                local cmd
                if package.config:sub(1,1) == '\\' then  -- Windows
                    cmd = string.format('mkdir "%s"', full_path)
                else  -- Linux/Mac
                    cmd = string.format('mkdir -p "%s"', full_path)
                end
                
                local result = os.execute(cmd)
                if result then
                    yield(Candidate(input, seg.start, seg._end, "文件夹创建成功: "..target_path, ""))
                    -- 清除缓存以便下次重新加载
                    env.dir_cache = nil
                    return true
                else
                    yield(Candidate(input, seg.start, seg._end, "文件夹创建失败: "..target_path, ""))
                    return true
                end
            else
                -- 显示匹配结果
                if #matches > 1 then
                    yield(Candidate(input, seg.start, seg._end, "匹配到多个文件夹: "..#matches.." 个", "请添加数字索引指定"))
                    for i, dir in ipairs(matches) do
                        yield(Candidate(input, seg.start, seg._end, dir, "📂"..i))
                    end
                    return true
                else
                    yield(Candidate(input, seg.start, seg._end, "文件夹已存在: "..matches[1], ""))
                    return true
                end
            end
        else
            -- 创建文件
            -- 检查并创建父目录
            local dir_path = target_path:match("^(.*)/[^/]*$")
            if dir_path then
                local user_dir = rime_api.get_user_data_dir()
                local full_dir_path = user_dir .. "/" .. dir_path
                if not ensure_directory_exists(full_dir_path) then
                    yield(Candidate(input, seg.start, seg._end, "父目录创建失败: "..dir_path, ""))
                    return true
                end
            end
            
            -- 如果没有匹配项，直接创建新文件
            if #matches == 0 then
                local user_dir = rime_api.get_user_data_dir()
                local full_path = user_dir .. "/" .. target_path
                
                -- 创建文件
                local file = io.open(full_path, "w")
                if file then
                    file:close()
                    yield(Candidate(input, seg.start, seg._end, "文件创建成功: "..target_path, ""))
                    -- 清除缓存以便下次重新加载
                    env.file_cache = nil
                    return true
                else
                    yield(Candidate(input, seg.start, seg._end, "文件创建失败: "..target_path, ""))
                    return true
                end
            else
                -- 显示匹配结果
                if #matches > 1 then
                    yield(Candidate(input, seg.start, seg._end, "匹配到多个文件: "..#matches.." 个", "请添加数字索引指定"))
                    for i, file in ipairs(matches) do
                        yield(Candidate(input, seg.start, seg._end, file, "📁"..i))
                    end
                    return true
                else
                    yield(Candidate(input, seg.start, seg._end, "文件已存在: "..matches[1], ""))
                    return true
                end
            end
        end
    else
        -- 删除操作
        if is_directory then
            -- 删除文件夹
            if #matches == 0 then
                yield(Candidate(input, seg.start, seg._end, "未找到匹配文件夹: "..target_path, ""))
                return true
            elseif #matches > 1 then
                yield(Candidate(input, seg.start, seg._end, "匹配到多个文件夹: "..#matches.." 个", "请添加数字索引指定"))
                for i, dir in ipairs(matches) do
                    yield(Candidate(input, seg.start, seg._end, dir, "📂"..i))
                end
                return true
            else
                local user_dir = rime_api.get_user_data_dir()
                local full_path = user_dir .. "/" .. matches[1]
                
                -- 删除文件夹
                local cmd
                if package.config:sub(1,1) == '\\' then  -- Windows
                    cmd = string.format('rmdir /s /q "%s"', full_path)
                else  -- Linux/Mac
                    cmd = string.format('rm -rf "%s"', full_path)
                end
                
                local result = os.execute(cmd)
                if result then
                    yield(Candidate(input, seg.start, seg._end, "文件夹删除成功: "..matches[1], ""))
                    -- 清除缓存以便下次重新加载
                    env.dir_cache = nil
                    env.file_cache = nil
                    return true
                else
                    yield(Candidate(input, seg.start, seg._end, "文件夹删除失败: "..matches[1], ""))
                    return true
                end
            end
        else
            -- 删除文件
            if #matches == 0 then
                yield(Candidate(input, seg.start, seg._end, "未找到匹配文件: "..target_path, ""))
                return true
            elseif #matches > 1 then
                yield(Candidate(input, seg.start, seg._end, "匹配到多个文件: "..#matches.." 个", "请添加数字索引指定"))
                for i, file in ipairs(matches) do
                    yield(Candidate(input, seg.start, seg._end, file, "📁"..i))
                end
                return true
            else
                local user_dir = rime_api.get_user_data_dir()
                local full_path = user_dir .. "/" .. matches[1]
                
                -- 删除文件
                local success, err = os.remove(full_path)
                if success then
                    yield(Candidate(input, seg.start, seg._end, "文件删除成功: "..matches[1], ""))
                    -- 清除缓存以便下次重新加载
                    env.file_cache = nil
                    return true
                else
                    yield(Candidate(input, seg.start, seg._end, "文件删除失败: "..matches[1].." - "..(err or ""), ""))
                    return true
                end
            end
        end
    end
end

-- 处理文件内容替换请求
local function handleReplaceRequest(input, seg, env)
    -- 统一为整体替换模式，支持所有文件
    local overwrite_pattern = "^Z(.-)@//(.*)/$"
    local file_path, new_content = input:match(overwrite_pattern)
    
    -- 处理整体替换输入中模式
    local overwrite_input_pattern = "^Z(.-)@//(.*)$"
    if not file_path then
        file_path, new_content = input:match(overwrite_input_pattern)
    end
    
    -- 如果匹配到整体替换模式
    if file_path then
        -- 提取文件选择索引
        local file_selection_index = nil
        local file_index_str = ""
        for i = #file_path, 1, -1 do
            local char = file_path:sub(i, i)
            if char:match("%d") then
                file_index_str = char .. file_index_str
            else
                break
            end
        end
        
        if #file_index_str > 0 and #file_path > #file_index_str then
            file_selection_index = tonumber(file_index_str)
            file_path = file_path:sub(1, #file_path - #file_index_str)
        end
        
        -- 文件模糊匹配
        local files = get_file_cache(env)
        local search_terms = {file_path:lower()}
        local fuzzy_matches = fuzzy_search_files(search_terms, files)
        table.sort(fuzzy_matches, function(a, b) return #a < #b end)
        
        -- 处理文件索引选择
        if file_selection_index and file_selection_index > 0 and file_selection_index <= #fuzzy_matches then
            fuzzy_matches = {fuzzy_matches[file_selection_index]}
        end
        
        -- 检查文件匹配结果
        if #fuzzy_matches == 0 then
            yield(Candidate(input, seg.start, seg._end, "未找到匹配文件", ""))
            return true
        elseif #fuzzy_matches ~= 1 then
            yield(Candidate(input, seg.start, seg._end, "匹配到多个文件: "..#fuzzy_matches.." 个", "请添加数字索引指定文件"))
            return true
        end
        
        local resolved_path = fuzzy_matches[1]
        local user_dir = rime_api.get_user_data_dir()
        local full_path = user_dir .. "/" .. resolved_path
        
        -- 读取文件内容以便显示原内容（预览用）
        local content, _ = readFileContent(full_path)
        
        -- 不再检查文件是否为空，任何文件都可以使用此模式
        
        -- 如果还未输入结束的/，显示预览
        if not input:match(overwrite_pattern) then
            -- 处理转义内容显示
            local display_new_content = escape_for_display(new_content)
            
            -- 显示原内容预览（最多显示3行）
            local original_preview = ""
            if content and #content > 0 then
                for i = 1, math.min(3, #content) do
                    if i > 1 then original_preview = original_preview .. " \\n " end
                    original_preview = original_preview .. escape_for_display(content[i])
                end
                if #content > 3 then
                    original_preview = original_preview .. " ...（共"..#content.."行）"
                end
            else
                original_preview = "(空文件)"
            end
            
            yield(Candidate(input, seg.start, seg._end, 
                            "将覆盖为: " .. (display_new_content:gsub("\n", "\\n")), 
                            "原内容: " .. original_preview))
            return true
        end
        
        -- 处理转义字符
        new_content = unescape_string(new_content)
        
        -- 将新内容按行分割
        local new_lines = {}
        for line in new_content:gmatch("[^\n]+") do
            table.insert(new_lines, line)
        end
        
        -- 如果内容为空，则创建一个空文件（一行空字符串）
        if #new_lines == 0 then
            table.insert(new_lines, "")
        end
        
        -- 写回文件
        local success, write_err = writeFileContent(full_path, new_lines)
        if not success then
            yield(Candidate(input, seg.start, seg._end, "写入失败：文件写入错误 - " .. (write_err or "未知原因"), ""))
            return true
        end
        
        -- 显示写入结果
        local result_msg = "整体替换成功: "
        local display_content = escape_for_display(new_content)
        if #display_content > 40 then
            display_content = display_content:sub(1, 37) .. "..."
        end
        
        -- 显示替换的行数信息
        local original_line_count = content and #content or 0
        local new_line_count = #new_lines
        
        yield(Candidate(input, seg.start, seg._end, 
                        result_msg .. display_content, 
                        "原"..original_line_count.."行 → 新"..new_line_count.."行"))
        return true
    end
    
    -- 完整替换格式 Z文件@关键词/被替换内容/替换内容/
    local replace_pattern = "^Z(.-)@([^/]+)/([^/]+)/([^/]*)/$"
    local file_path, keyword, old_str, new_str = input:match(replace_pattern)
    
    -- 部分替换格式（输入中）
    local partial_pattern1 = "^Z(.-)@([^/]+)/([^/]*)$"   -- Z文件@关键词/被替换内容 (输入了第一个/)
    local partial_pattern2 = "^Z(.-)@([^/]+)/([^/]+)/([^/]*)$"  -- Z文件@关键词/被替换内容/替换内容 (输入了第二个/)
    
    -- 匹配空内容替换的特殊模式（结尾双斜杠）
    local empty_replace_pattern = "^Z(.-)@([^/]+)/([^/]+)//$"
    if not (file_path and keyword and old_str and new_str) then
        file_path, keyword, old_str = input:match(empty_replace_pattern)
        if file_path then
            new_str = ""  -- 明确设置为空字符串
        else
            -- 检测其他部分替换格式
            file_path, keyword, old_str = input:match(partial_pattern1)
            if not file_path then
                file_path, keyword, old_str, new_str = input:match(partial_pattern2)
            end
        end
    end
    
    -- 没有匹配到任何替换模式
    if not file_path or not keyword then return false end
    
    -- 先提取文件选择索引
    local file_selection_index = nil
    local file_index_str = ""
    for i = #file_path, 1, -1 do
        local char = file_path:sub(i, i)
        if char:match("%d") then
            file_index_str = char .. file_index_str
        else
            break
        end
    end
    
    if #file_index_str > 0 and #file_path > #file_index_str then
        file_selection_index = tonumber(file_index_str)
        file_path = file_path:sub(1, #file_path - #file_index_str)
    end
    
    -- 从关键词部分提取行索引
    local line_selection_index = nil
    local line_index_str = ""
    for i = #keyword, 1, -1 do
        local char = keyword:sub(i, i)
        if char:match("%d") then
            line_index_str = char .. line_index_str
        else
            break
        end
    end
    
    if #line_index_str > 0 and #keyword > #line_index_str then
        line_selection_index = tonumber(line_index_str)
        keyword = keyword:sub(1, #keyword - #line_index_str)
    end
    
    -- 文件模糊匹配
    local files = get_file_cache(env)
    local search_terms = {file_path:lower()}
    local fuzzy_matches = fuzzy_search_files(search_terms, files)
    table.sort(fuzzy_matches, function(a, b) return #a < #b end)
    
    -- 处理文件索引选择
    if file_selection_index and file_selection_index > 0 and file_selection_index <= #fuzzy_matches then
        fuzzy_matches = {fuzzy_matches[file_selection_index]}
    end
    
    -- 检查文件匹配结果
    if #fuzzy_matches == 0 then
        yield(Candidate(input, seg.start, seg._end, "未找到匹配文件", ""))
        return true
    elseif #fuzzy_matches ~= 1 then
        yield(Candidate(input, seg.start, seg._end, "匹配到多个文件: "..#fuzzy_matches.." 个", "请添加数字索引指定文件"))
        return true
    end
    
    local resolved_path = fuzzy_matches[1]
    local user_dir = rime_api.get_user_data_dir()
    local full_path = user_dir .. "/" .. resolved_path
    
    -- 读取文件内容
    local content, err = readFileContent(full_path)
    if not content then
        yield(Candidate(input, seg.start, seg._end, "文件读取错误: " .. (err or ""), ""))
        return true
    end
    
    -- 查找包含关键词的行
    local matched_lines = {}
    for i, line in ipairs(content) do
        if line:find(keyword, 1, true) then
            table.insert(matched_lines, {line = line, index = i})
        end
    end
    
    -- 检查行匹配结果
    if #matched_lines == 0 then
        yield(Candidate(input, seg.start, seg._end, "文件中未找到匹配关键词的行", "关键词: "..keyword))
        return true
    end
    
    -- 处理行索引选择
    local selected_matched_lines = matched_lines
    if line_selection_index then
        if line_selection_index > 0 and line_selection_index <= #matched_lines then
            selected_matched_lines = {matched_lines[line_selection_index]}
        else
            yield(Candidate(input, seg.start, seg._end, "行索引无效，范围1-"..#matched_lines, ""))
            return true
        end
    end
    
    if #selected_matched_lines ~= 1 then
        yield(Candidate(input, seg.start, seg._end, "找到 "..#selected_matched_lines.." 行匹配，需要唯一行", "请添加数字索引指定行"))
        return true
    end
    
    local matched_line_info = selected_matched_lines[1]
    local matched_line = matched_line_info.line
    local line_number = matched_line_info.index
    
    -- 完整替换处理
    if input:match("^Z[^@]*@[^/]+/[^/]+/[^/]*/$") then
        -- 处理转义字符
        if new_str then
            new_str = unescape_string(new_str)
        end
        
        local new_line, count
        
        -- 明确处理空替换内容（删除操作）
        if new_str == "" then
            -- 明确删除匹配内容
            new_line = matched_line:gsub(old_str, "", 1)
            count = (matched_line ~= new_line) and 1 or 0
        else
            -- 正常替换
            new_line, count = matched_line:gsub(old_str, new_str, 1)
        end
        
        if count == 0 then
            yield(Candidate(input, seg.start, seg._end, "替换失败：行内未找到匹配内容", "使用正则表达式匹配"))
            return true
        end
        
        -- 更新内容
        content[line_number] = new_line
        
        -- 写回文件
        local success, write_err = writeFileContent(full_path, content)
        if not success then
            yield(Candidate(input, seg.start, seg._end, "替换失败：文件写入错误 - " .. (write_err or "未知原因"), ""))
            return true
        end
        
        -- 显示替换结果
        local result_msg = "替换成功: "
        if new_str == "" then
            result_msg = "删除成功: "
        end
        
        -- 处理换行符显示
        local display_line = new_line:gsub("\n", "\\n")
        if #display_line > 40 then
            display_line = display_line:sub(1, 37) .. "..."
        end
        
        yield(Candidate(input, seg.start, seg._end, result_msg .. display_line, 
                       "原内容: " .. matched_line:sub(1, 40)))
        return true
    else
        -- 替换操作输入中状态：显示替换引导
        local status_msg = matched_line
        if old_str and old_str ~= "" then
            -- 处理长行显示
            if #status_msg > 20 then
                status_msg = status_msg:sub(1, 17) .. "..."
            end
            
            status_msg = status_msg .. " → 待替换内容: " .. old_str
            
            -- 在第二个/之后（替换内容输入中）
            if new_str ~= nil then
                -- 处理转义内容显示
                local display_new_str = escape_for_display(new_str)
                
                -- 特殊显示空替换的引导
                if new_str == "" then
                    status_msg = status_msg .. " ➔ 将执行删除（输入/确认）"
                else
                    -- 处理长内容显示
                    if #display_new_str > 20 then
                        display_new_str = display_new_str:sub(1, 17) .. "..."
                    end
                    status_msg = status_msg .. " ➔ 新内容: " .. display_new_str
                end
            else
                -- 第一阶段：待输入替换内容
                status_msg = status_msg .. " ➔ 输入替换内容（空内容输入//删除）"
            end
        else
            -- 第一阶段：还未输入待替换内容
            status_msg = status_msg .. " → 输入待替换内容"
        end
        
        -- 如果有多行匹配且未选择行索引，提示用户选择
        if #matched_lines > 1 and not line_selection_index then
            status_msg = status_msg .. " (有 "..#matched_lines.." 行匹配，请添加行索引)"
        end
        
        -- 显示替换引导
        yield(Candidate(input, seg.start, seg._end, status_msg, "第"..line_number.."行: "))
        return true
    end
end

-- 处理文件读取请求
local function handleFileRequest(input, seg, env)
    -- 首先尝试匹配替换请求
    if handleReplaceRequest(input, seg, env) then
        return true
    end
    
    -- 匹配内容查询格式 Z文件@查询内容
    local query_pattern = "^Z(.-)@([^/]+)/?$"
    local file_path, query = input:match(query_pattern)

    -- 匹配合并模式 Z文件@/$
    local merge_pattern = "^Z(.-)@/$"
    local merge_file_path = input:match(merge_pattern)

    -- 匹配普通文件读取格式 Z文件@
    if not file_path and not merge_file_path then
        file_path = input:match("^Z(.-)@$")
        query = nil
    end

    -- 确定最终文件路径
    local actual_file_path = merge_file_path or file_path
    if not actual_file_path then return false end
    
    local file_selection_index = nil
    
    -- 从末尾提取文件选择数字索引（可能多位）
    local file_index_str = ""
    for i = #actual_file_path, 1, -1 do
        local char = actual_file_path:sub(i, i)
        if char:match("%d") then
            file_index_str = char .. file_index_str
        else
            -- 找到非数字字符，停止提取
            break
        end
    end
    
    -- 如果提取到了数字且文件路径部分不为空，才视为选择索引
    if #file_index_str > 0 and #actual_file_path > #file_index_str then
        file_selection_index = tonumber(file_index_str)
        actual_file_path = actual_file_path:sub(1, #actual_file_path - #file_index_str)
    end
    
    -- 尝试模糊匹配不完整文件名
    local files = get_file_cache(env)
    local search_terms = {}
    -- 分割搜索词（支持空格分隔多个关键词）
    for term in actual_file_path:gmatch("%S+") do
        if term ~= "" then
            table.insert(search_terms, term:lower())
        end
    end
    
    local fuzzy_matches = fuzzy_search_files(search_terms, files)
    table.sort(fuzzy_matches, function(a, b)
        return #a < #b
    end)
    
    -- 处理文件索引选择
    if file_selection_index and file_selection_index > 0 and file_selection_index <= #fuzzy_matches then
        fuzzy_matches = {fuzzy_matches[file_selection_index]}
    end
    
    -- 如果有唯一模糊匹配结果，使用该结果作为实际文件路径
    local resolved_path = actual_file_path
    if #fuzzy_matches == 1 then
        resolved_path = fuzzy_matches[1]
    end

    -- 分割路径和文件名
    local dir, filename = resolved_path:match("^(.*)/([^/]+)$")
    if not dir then
        dir = ""
        filename = resolved_path
    end

    -- 获取完整路径
    local user_dir = rime_api.get_user_data_dir()
    local full_path = user_dir .. "/" .. resolved_path

    -- 读取文件
    local content, err = readFileContent(full_path)
    if not content then
        -- 如果模糊匹配失败，尝试直接使用原始路径
        full_path = user_dir .. "/" .. dir .. "/" .. filename
        content, err = readFileContent(full_path)
        if not content then
            yield(Candidate(input, seg.start, seg._end, "文件读取错误：" .. err, ""))
            return true
        end
    end

    -- 合并模式：将所有内容合并为单一候选词
    if merge_file_path then
        local merged_content = table.concat(content, "\n")
        yield(Candidate(input, seg.start, seg._end, merged_content, "合并后的完整内容"))
        return true
    end

    -- 内容查询模式
    if query and query ~= "" then
        -- 从查询词末尾提取行选择数字索引
        local line_selection_index = nil
        local line_index_str = ""
        for i = #query, 1, -1 do
            local char = query:sub(i, i)
            if char:match("%d") then
                line_index_str = char .. line_index_str
            else
                break
            end
        end
        
        if #line_index_str > 0 and #query > #line_index_str then
            line_selection_index = tonumber(line_index_str)
            query = query:sub(1, #query - #line_index_str)
        end
        
        -- 收集匹配的行
        local matched_lines = {}
        for i, line in ipairs(content) do
            if not line:match("^%s*$") then
                if line:find(query, 1, true) then
                    table.insert(matched_lines, {line = line, number = i})
                end
            end
        end
        
        -- 显示匹配结果
        if #matched_lines > 0 then
            if line_selection_index and line_selection_index > 0 and line_selection_index <= #matched_lines then
                -- 只显示选定的行
                local selected = matched_lines[line_selection_index]
                yield(Candidate(input, seg.start, seg._end,
                    selected.line,
                    "第"..selected.number.."行(选择)"))
            else
                -- 显示所有匹配行并添加索引
                for i, data in ipairs(matched_lines) do
                    yield(Candidate(input, seg.start, seg._end,
                        data.line,
                        string.format("(%d)第%d行: %s", i, data.number, data.line:sub(1, 20))))
                end
            end
        else
            yield(Candidate(input, seg.start, seg._end, "无匹配内容", ""))
        end
        return true
    end
 
    -- 普通文件读取模式 - 显示所有非空行
    for i, line in ipairs(content) do
        if not line:match("^%s*$") then
            yield(Candidate(input, seg.start, seg._end, line, string.format("第%d行", i)))
        end
    end
 
    return true
end

-- 处理文件复制/移动请求（优化版：支持数字选重和新目录创建）
local function handleFileCopyMove(input, seg, env)
    -- 基础命令提示（刚输入Z&或Z+&时）
    if input == "Z&" or input == "Z+&" then
        yield(Candidate(input, seg.start, seg._end, "Z+&原文件&目标路径& 复制文件", "格式：Z+&源&目标&"))
        yield(Candidate(input, seg.start, seg._end, "Z&原文件&目标路径& 移动文件", "格式：Z&源&目标&"))
        return true
    end
    
    -- 阶段1：仅输入Z+&或Z&，等待输入源文件
    if input:match("^Z[%+]?&$") then
        yield(Candidate(input, seg.start, seg._end, "请输入源文件关键词", "例如：Z&note&doc/&"))
        return true
    end
    
    -- 阶段3：完整命令 Z+&原文件&目标路径& 或 Z&原文件&目标路径&
    local stage3_pattern = "^Z[%+]?&(.-)&(.-)&$"
    local is_move = input:sub(1,2) == "Z&"  -- 判断是否为移动而非复制
    local original_path, target_path = input:match(stage3_pattern)
    
    if original_path and target_path then
        -- 获取用户数据目录
        local user_dir = rime_api.get_user_data_dir()
        
        -- 提取源文件索引
        local src_selection_index = nil
        local src_index_str = ""
        for i = #original_path, 1, -1 do
            local char = original_path:sub(i, i)
            if char:match("%d") then
                src_index_str = char .. src_index_str
            else
                break
            end
        end
        
        local term_part = original_path
        if #src_index_str > 0 and #original_path > #src_index_str then
            src_selection_index = tonumber(src_index_str)
            term_part = original_path:sub(1, #original_path - #src_index_str)
        end
        
        -- 源文件模糊匹配
        local files = get_file_cache(env)
        local src_search_terms = {}
        for term in term_part:gmatch("%S+") do
            if term ~= "" then
                table.insert(src_search_terms, term:lower())
            end
        end
        local src_matches = fuzzy_search_files(src_search_terms, files)
        table.sort(src_matches, function(a, b) return #a < #b end)
        
        -- 处理源文件索引选择
        if src_selection_index and src_selection_index > 0 and src_selection_index <= #src_matches then
            src_matches = {src_matches[src_selection_index]}
        end
        
        -- 检查源文件匹配结果
        if #src_matches == 0 then
            yield(Candidate(input, seg.start, seg._end, "未找到匹配源文件: "..term_part, ""))
            return true
        elseif #src_matches ~= 1 then
            yield(Candidate(input, seg.start, seg._end, "匹配到多个源文件: "..#src_matches.." 个", "请添加数字索引指定"))
            for i, file in ipairs(src_matches) do
                yield(Candidate(input, seg.start, seg._end, file, "📄"..i))
            end
            return true
        end
        
        local resolved_src = src_matches[1]
        local full_src_path = user_dir .. "/" .. resolved_src
        
        -- 提取目标目录索引（支持数字选重）
        local target_selection_index = nil
        local target_index_str = ""
        for i = #target_path, 1, -1 do
            local char = target_path:sub(i, i)
            if char:match("%d") then
                target_index_str = char .. target_index_str
            else
                break
            end
        end
        
        local target_term = target_path
        -- 如果提取到了索引数字
        if #target_index_str > 0 and #target_term > #target_index_str then
            target_selection_index = tonumber(target_index_str)
            target_term = target_term:sub(1, #target_term - #target_index_str)
        end
        
        -- 目标目录模糊匹配
        local target_matches = {}
        local dirs = get_dir_cache(env)
        local dir_search_terms = {}
        for term in target_term:gmatch("%S+") do
            if term ~= "" then
                table.insert(dir_search_terms, term:lower())
            end
        end
        target_matches = fuzzy_search_files(dir_search_terms, dirs)
        table.sort(target_matches, function(a, b) return #a < #b end)
        
        -- 处理目标目录索引选择
        if target_selection_index and target_selection_index > 0 and target_selection_index <= #target_matches then
            target_matches = {target_matches[target_selection_index]}
        end
        
        -- 解析源文件的文件名
        local src_filename = resolved_src:match("[^/]+$") or resolved_src
        
        -- 确定最终目标路径和目录
        local full_target_path, target_dir
        local is_new_directory = false
        
        -- 情况1：有有效数字选重，使用现有目录
        if #target_matches == 1 then
            full_target_path = user_dir .. "/" .. target_matches[1] .. "/" .. src_filename
            target_dir = user_dir .. "/" .. target_matches[1]
        -- 情况2：无数字选重，使用输入路径并创建目录
        else
            is_new_directory = true
            -- 处理目标路径格式（确保正确拼接）
            local full_target_dir = user_dir .. "/" .. target_term
            -- 确保目录以/结尾
            if full_target_dir:sub(-1) ~= "/" then
                full_target_dir = full_target_dir .. "/"
            end
            full_target_path = full_target_dir .. src_filename
            target_dir = full_target_dir
        end
        
        -- 无数字选重时创建目录（有选重时无需创建，使用现有目录）
        if is_new_directory then
            if not ensure_directory_exists(target_dir) then
                yield(Candidate(input, seg.start, seg._end, "目标目录创建失败: "..target_dir, ""))
                return true
            end
        end
        
        -- 读取源文件内容
        local content, err = readFileContent(full_src_path)
        if not content then
            yield(Candidate(input, seg.start, seg._end, "源文件读取失败: "..(err or ""), ""))
            return true
        end
        
        -- 执行复制操作
        local success, write_err = writeFileContent(full_target_path, content)
        if not success then
            yield(Candidate(input, seg.start, seg._end, "文件操作失败: "..(write_err or ""), ""))
            return true
        end
        
        -- 移动操作需要删除原文件
        if is_move then
            local delete_success, delete_err = os.remove(full_src_path)
            if not delete_success then
                yield(Candidate(input, seg.start, seg._end, 
                              "文件已复制但原文件删除失败: "..(delete_err or ""), ""))
                return true
            end
            -- 清除文件缓存
            env.file_cache = nil
        end
        
        -- 操作成功提示
        local operation = is_move and "移动" or "复制"
        local target_display = #target_matches == 1 and target_matches[1] or target_term
        local dir_status = is_new_directory and "（已创建新目录）" or ""
        yield(Candidate(input, seg.start, seg._end, 
                      operation.."成功: "..resolved_src.." → "..target_display..dir_status, ""))
        
        -- 清除缓存
        env.file_cache = nil
        env.dir_cache = nil
        return true
    end
    
    -- 阶段2：已输入源文件&，等待输入目标路径
    local stage2_pattern = "^Z[%+]?&(.-)&(.-)$"
    local original, target_prefix = input:match(stage2_pattern)
    if original and target_prefix then
        -- 获取目录缓存并生成候选
        local dirs = get_dir_cache(env)
        local dir_items = {}
        for _, dir in ipairs(dirs) do
            table.insert(dir_items, dir .. "/")  -- 目录标记
        end
        
        -- 模糊搜索目标目录（支持多关键词）
        local search_terms = {}
        for term in target_prefix:gmatch("%S+") do
            if term ~= "" then
                table.insert(search_terms, term:lower())
            end
        end
        
        local target_matches = fuzzy_search_files(search_terms, dir_items)
        table.sort(target_matches, function(a, b) return #a < #b end)
        
        -- 提取目标目录索引
        local target_selection_index = nil
        local target_index_str = ""
        for i = #target_prefix, 1, -1 do
            local char = target_prefix:sub(i, i)
            if char:match("%d") then
                target_index_str = char .. target_index_str
            else
                break
            end
        end
        
        -- 处理索引选择
        if #target_index_str > 0 and #target_prefix > #target_index_str then
            target_selection_index = tonumber(target_index_str)
            local term_part = target_prefix:sub(1, #target_prefix - #target_index_str)
            -- 重新解析搜索词（排除索引部分）
            search_terms = {}
            for term in term_part:gmatch("%S+") do
                if term ~= "" then
                    table.insert(search_terms, term:lower())
                end
            end
            target_matches = fuzzy_search_files(search_terms, dir_items)
            table.sort(target_matches, function(a, b) return #a < #b end)
            
            if target_selection_index and target_selection_index > 0 and target_selection_index <= #target_matches then
                target_matches = {target_matches[target_selection_index]}
            end
        end
        
        -- 显示目标目录候选（确保在第二个&前显示）
        if #target_matches > 0 then
            for i, dir in ipairs(target_matches) do
                yield(Candidate(input, seg.start, seg._end, dir, "📂"..i))
            end
        else
            yield(Candidate(input, seg.start, seg._end, "未找到匹配目录，将创建新目录", "输入路径后按&确认创建"))
        end
        return true
    end
    
    -- 阶段1.5：源文件输入阶段（第一个&后）
    local src_only_pattern = "^Z[%+]?&(.-)$"
    local src_only = input:match(src_only_pattern)
    if src_only then
        -- 源文件阶段：使用标准模糊检索逻辑
        local files = get_file_cache(env)
        local search_terms = {}
        for term in src_only:gmatch("%S+") do
            if term ~= "" then
                table.insert(search_terms, term:lower())
            end
        end
        
        -- 无搜索词时显示提示
        if #search_terms == 0 then
            yield(Candidate(input, seg.start, seg._end, "请输入源文件关键词", ""))
            return true
        end
        
        -- 模糊匹配文件
        local src_matches = fuzzy_search_files(search_terms, files)
        table.sort(src_matches, function(a, b) return #a < #b end)
        
        -- 提取源文件索引
        local src_selection_index = nil
        local src_index_str = ""
        for i = #src_only, 1, -1 do
            local char = src_only:sub(i, i)
            if char:match("%d") then
                src_index_str = char .. src_index_str
            else
                break
            end
        end
        
        -- 处理索引选择
        if #src_index_str > 0 and #src_only > #src_index_str then
            src_selection_index = tonumber(src_index_str)
            local term_part = src_only:sub(1, #src_only - #src_index_str)
            -- 重新解析搜索词（排除索引部分）
            search_terms = {}
            for term in term_part:gmatch("%S+") do
                if term ~= "" then
                    table.insert(search_terms, term:lower())
                end
            end
            src_matches = fuzzy_search_files(search_terms, files)
            table.sort(src_matches, function(a, b) return #a < #b end)
            
            if src_selection_index and src_selection_index > 0 and src_selection_index <= #src_matches then
                src_matches = {src_matches[src_selection_index]}
            end
        end
        
        if #src_matches > 0 then
            for i, file in ipairs(src_matches) do
                yield(Candidate(input, seg.start, seg._end, file, "📄"..i))
            end
        else
            yield(Candidate(input, seg.start, seg._end, "未找到匹配源文件", "请检查关键词或继续输入"))
        end
        return true
    end
    
    -- 其他情况保持静默
    return false
end

function T.func(input, seg, env)
    -- 先获取当前输入片段
    local comp = env.engine.context.composition
    if comp:empty() then return end
    local segment = comp:back()
    
    -- 优先处理文件复制/移动操作
    if handleFileCopyMove(input, seg, env) then
        segment.tags = segment.tags + Set({"calculator"})
        return
    end
    
    -- 处理文件系统操作（创建/删除）
    if handleFileSystemRequest(input, seg, env) then
        segment.tags = segment.tags + Set({"calculator"})
        return
    end

    -- /wjjc等指令优先
    if startsWith(input, T.prefix) then
        local expr = input:sub(#T.prefix + 1)
        -- 先检测/wjjc指令，避免被文件查询逻辑拦截
        if expr:find("/wjjc") then
            env.engine.context.input = "/wjjc"
            return
        end
    end
 
    -- 处理文件内容查询
    if handleFileRequest(input, seg, env) then
        segment.tags = segment.tags + Set({"calculator"})
        return
    end
 
    -- 处理文件名模糊搜索
    if fuzzy_file_search(input, seg, env) then
        segment.tags = segment.tags + Set({"calculator"})
        return
    end
 
    -- 处理其他基础指令和计算器模式
    if not startsWith(input, T.prefix) then return end
 
    local expr = input:sub(#T.prefix + 1)
 
    if expr == "" then
        yield(Candidate(input, 0,     0, "文件名@内容 检索文件内容", " "))
        yield(Candidate(input, 0, 0, "文件名2@内容3/ 选择第2个文件候选项，选择第3个内容候选项", " "))
        yield(Candidate(input, 0, 0, "文件名@/ 合并输出整个文件", " "))
        yield(Candidate(input, 0, 0, "文件名@内容/被替换/替换/ 修改内容（支持\\n换行）", " "))
        yield(Candidate(input, 0, 0, "文件名@//新内容/ 整体替换文件内容（覆盖写入）", " "))
        yield(Candidate(input, 0, 0, "new\"文件夹/文件名\" 创建文件", " "))
        yield(Candidate(input, 0, 0, "del\"文件夹/文件名\" 删除文件", " "))
        yield(Candidate(input, 0, 0, "+&原文件&目标路径& 复制文件", " "))
        yield(Candidate(input, 0, 0, "&原文件&目标路径& 移动文件", " "))
        segment.prompt = "〔指令提示〕"
        return
    end
 
    -- 标记为计算器模式
    segment.tags = segment.tags + Set({"calculator"})
end
 
-- 保留正则开关接口，供未来扩展使用
function T.toggle_regex(enable)
    if enable ~= nil then
        regex_enabled = enable
    end
    return regex_enabled
end
 
return T