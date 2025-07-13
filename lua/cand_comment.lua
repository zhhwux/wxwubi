--@amzxyz https://github.com/amzxyz/rime_wanxiang
local wanxiang = require('wanxiang')
local patterns = {
    fuzhu = "[^;];(.+)$",
    tone = "([^;]*);",
    moqi = "[^;]*;([^;]*);",
    flypy = "[^;]*;[^;]*;([^;]*);",
    zrm = "[^;]*;[^;]*;[^;]*;([^;]*);",
    jdh = "[^;]*;[^;]*;[^;]*;[^;]*;([^;]*);",
    tiger = "[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;([^;]*);",
    wubi = "[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;([^;]*);",
    hanxin = "[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;([^;]*)"
}

-- #########################
-- # 带调全拼注释模块 (zhuyin)
-- 新模块：处理单字多音和词句首音
-- #########################
local ZY = {}

function ZY.init(env)
    env.zhuyin_dict = ReverseLookup("wanxiang_pro")
end

function ZY.fini(env)
    env.zhuyin_dict = nil
    collectgarbage()
end

local function process_existing_comment(comment)
    if not comment or comment == "" then return comment end
    -- 删除分号与单引号/空格间内容
    local processed = comment:gsub(";[^' ]*[' ]", " ")
    -- 删除末尾分号内容
    local last_semicolon = processed:find(";[^;]*$")
    if last_semicolon then processed = processed:sub(1, last_semicolon - 1) end
    -- 清理多余空格
    return processed:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
end

local function process_annotation(raw, is_single_char)
    if not raw or raw == "" then return raw end
    if is_single_char then
        return raw:gsub(";[^%s]*", "")  -- 单字保留多音
    end
    return raw:match("^([^;]*)") or raw  -- 多字取首音
end

function ZY.run(cand, env)
    local dict = env.zhuyin_dict
    if not dict or #cand.text == 0 then return nil end
    
    local char_count = select(2, cand.text:gsub("[^\128-\193]", ""))
    
    -- 1. 拼音候选词：原生注释处理（优先）
    if cand.comment and cand.comment ~= "" then
        return process_existing_comment(cand.comment)
    
    -- 2. 形码等自定义词典：无注释单字（显示所有发音）
    elseif char_count == 1 then
        local raw = dict:lookup(cand.text)
        return process_annotation(raw, true)
    
    -- 3. 形码等自定义词典：无注释多字（每字取首音，不准）
    elseif char_count > 1 then
        local parts, has_annotation = {}, false
        for char in cand.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            local raw = dict:lookup(char)
            local part = process_annotation(raw, false) or char
            table.insert(parts, part)
            if part ~= char then has_annotation = true end
        end
        return has_annotation and table.concat(parts, " ") or nil
    end
    return nil
end

-- #########################
-- # 辅助码拆分提示模块 (chaifen)
-- PRO 专用
-- #########################
local CF = {}
function CF.init(env)
    if wanxiang.is_pro_scheme(env) then
        CF.get_dict(env)
    end
end

function CF.fini(env)
    env.chaifen_dict = nil
    collectgarbage()
end

function CF.get_dict(env)
    if env.chaifen_dict == nil then
        env.chaifen_dict = ReverseLookup("wanxiang_lookup")
    end
    return env.chaifen_dict
end

function CF.get_comment(cand, env)
    local dict = CF.get_dict(env)
    if not dict then return "" end

    local raw = dict:lookup(cand.text)
    if raw == "" then return "" end
    
    -- 辅助码类型 → 圈字映射
    local mark_map = {
        hanxin = "Ⓐ",
        jdh    = "Ⓑ",
        tiger  = "Ⓒ",
        flypy  = "Ⓓ",
        moqi   = "Ⓔ",
        zrm    = "Ⓕ",
        wubi   = "Ⓖ"
    }
    local fuzhu_type = env.settings.fuzhu_type or ""
    local mark = mark_map[fuzhu_type]
    if not mark then return raw end

    -- 拆分查找含圈字的片段
    for segment in raw:gmatch("[^%s]+") do
        if segment:find(mark, 1, true) then
            return segment:gsub(mark, "", 1)
        end
    end
    return raw
end

-- #########################
-- # 错音错字提示模块 (Corrector)
-- #########################
local CR = {}
local corrections_cache = nil

function CR.init(env)
    CR.style = env.settings.corrector_type or '{comment}'
    local path = wanxiang.is_pro_scheme(env) and 
                 "zh_dicts_pro/corrections.dict.yaml" or 
                 "zh_dicts/corrections.dict.yaml"
    
    corrections_cache = {}
    local file, close_file = wanxiang.load_file_with_fallback(path)
    if not file then return end
    
    for line in file:lines() do
        if not line:match("^#") then
            local text, code, _, comment = line:match("^(.-)\t(.-)\t(.-)\t(.-)$")
            if text and code then
                corrections_cache[code:gsub("%s+", env.settings.auto_delimiter)] = {
                    text = text:match("^%s*(.-)%s*$"),
                    comment = comment and comment:gsub("%s+", env.settings.auto_delimiter) or ""
                }
            end
        end
    end
    close_file()
end

function CR.get_comment(cand)
    if not corrections_cache then return nil end
    local correction = corrections_cache[cand.comment]
    if correction and cand.text == correction.text then
        return CR.style:gsub("{comment}", correction.comment)
    end
    return nil
end

-- ################################
-- 部件组字返回的注释（radical_pinyin）
-- ################################
local function get_az_comment(_, env, initial_comment)
    if not initial_comment or initial_comment == "" then return "" end
    local auto_delimiter = env.settings.auto_delimiter or " "
    
    local segments = {}
    for segment in initial_comment:gmatch("[^"..auto_delimiter.."]+") do
        table.insert(segments, segment)
    end
    if #segments == 0 then return "" end

    local semicolon_count = select(2, segments[1]:gsub(";", ""))
    local pinyins, fuzhu = {}, nil
    
    for _, segment in ipairs(segments) do
        local pinyin = segment:match("^[^;]+")
        if pinyin then table.insert(pinyins, pinyin) end
        
        if semicolon_count > 0 then
            local pattern = patterns[env.settings.fuzhu_type]
            fuzhu = pattern and segment:match(pattern) or fuzhu
        end
    end

    if #pinyins > 0 then
        local pinyin_str = table.concat(pinyins, ",")
        return fuzhu and string.format("〔音%s 辅%s〕", pinyin_str, fuzhu)
                      or string.format("〔音%s〕", pinyin_str)
    end
    return ""
end

-- #########################
-- # 辅助码提示模块 (Fuzhu)
-- #########################
local function get_fz_comment(cand, env, initial_comment)
    local length = utf8.len(cand.text)
    if length > env.settings.candidate_length then return "" end
    
    local auto_delimiter = env.settings.auto_delimiter or " "
    local segments = {}
    for segment in initial_comment:gmatch("[^"..auto_delimiter.."]+") do
        table.insert(segments, segment)
    end
    if #segments == 0 then return "" end

    local first_segment = segments[1]
    local semicolon_count = select(2, first_segment:gsub(";", ""))
    if semicolon_count == 0 then
        return initial_comment:gsub(auto_delimiter, " ")
    end

    local fuzhu_comments = {}
    local pattern = patterns[env.settings.fuzhu_type]
    if not pattern then return "" end

    for _, segment in ipairs(segments) do
        local match = segment:match(pattern)
        if match then table.insert(fuzhu_comments, match) end
    end

    return #fuzhu_comments > 0 and table.concat(fuzhu_comments, "/") or ""
end

-- #########################
-- 主函数：模块化处理流程
-- #########################
local ZH = {}
function ZH.init(env)
    local config = env.engine.schema.config
    local delimiter = config:get_string('speller/delimiter') or " '"
    env.settings = {
        delimiter = delimiter,
        auto_delimiter = delimiter:sub(1, 1),
        corrector_enabled = config:get_bool("super_comment/corrector") or true,
        corrector_type = config:get_string("super_comment/corrector_type") or "{comment}",
        candidate_length = tonumber(config:get_string("super_comment/candidate_length")) or 1,
        fuzhu_type = config:get_string("super_comment/fuzhu_type") or ""
    }
    
    -- 初始化所有模块
    ZY.init(env)
    CR.init(env)
    CF.init(env)
end

function ZH.fini(env)
    -- 清理所有模块资源
    ZY.fini(env)
    CF.fini(env)
    CR.fini(env)
end

function ZH.func(input, env)
    local is_radical_mode = wanxiang.is_in_radical_mode(env)
    local should_skip = env.engine.context.input:match("^[VRNU/]")
    local is_comment_hint = env.engine.context:get_option("fuzhu_hint")
    local is_tone_comment = env.engine.context:get_option("pinyin")
    local is_chaifen_enabled = env.engine.context:get_option("chaifen_switch")
    local corrector_enabled = env.settings.corrector_enabled

    for cand in input:iter() do
        if should_skip then
            yield(cand)
            goto continue
        end

        local initial_comment = cand.comment
        local final_comment = initial_comment
        local comment_handled = false  -- 新增：标记注释是否被处理

        -- 1. 带调全拼注释（最高优先级，覆盖原始注释）
        if is_tone_comment then
            local zy_comment = ZY.run(cand, env)
            if zy_comment then
                final_comment = zy_comment
                comment_handled = true  -- 标记已处理
            end
        end

        -- 2. 辅助码提示（次优先级）
        if is_comment_hint and not comment_handled then
            local fz_comment = get_fz_comment(cand, env, initial_comment)
            if fz_comment ~= "" then
                final_comment = fz_comment
                comment_handled = true
            end
        end

        -- 3. 拆分注释
        if is_chaifen_enabled and not comment_handled then
            local cf_comment = CF.get_comment(cand, env)
            if cf_comment ~= "" then
                final_comment = cf_comment
                comment_handled = true
            end
        end

        -- 4. 错音错字提示
        if corrector_enabled and not comment_handled then
            local cr_comment = CR.get_comment(cand)
            if cr_comment then
                final_comment = cr_comment
                comment_handled = true
            end
        end

        -- 5. 部件组字模式
        if is_radical_mode and not comment_handled then
            local az_comment = get_az_comment(cand, env, initial_comment)
            if az_comment ~= "" then
                final_comment = az_comment
                comment_handled = true
            end
        end

        -- 未启用任何功能时清空注释
        if not comment_handled then
            final_comment = ""
        end

        -- 应用最终注释
        if final_comment ~= initial_comment then
            cand:get_genuine().comment = final_comment
        end

        yield(cand)
        ::continue::
    end
end

return ZH
