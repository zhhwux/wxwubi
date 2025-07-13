-- # 辅助码拆分提示模块 (chaifen) - 支持词句拆分
local CF = {}
function CF.init(env)
    env.chaifen_dict = ReverseLookup("wubi_lookup")
end

function CF.fini(env)
    env.chaifen_dict = nil
    collectgarbage()
end

-- 处理单个字符的拆分
local function process_single_char(dict, char)
    local result = dict:lookup(char)
    return (result and result ~= "") and result or char
end

-- 处理词句拆分
function CF.run(cand, env)
    local dict = env.chaifen_dict
    if not dict or #cand.text == 0 then return nil end
    
    -- 处理单字候选
    if #cand.text == 1 then
        local append = process_single_char(dict, cand.text)
        return append ~= cand.text and append or nil
    end
    
    -- 处理多字词句
    local parts = {}
    local has_chaifen = false
    
    -- 遍历每个字符（支持UTF-8）
    for char in cand.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local part = process_single_char(dict, char)
        table.insert(parts, part)
        if part ~= char then has_chaifen = true end
    end
    
    return has_chaifen and table.concat(parts, " ") or nil
end

-- 主处理模块
local ZH = {}
function ZH.init(env)
    local config = env.engine.schema.config
    local input_preedit = env.engine.context:get_preedit().text
    local seg = env.engine.context.composition:back()
    env.is_radical_mode = seg and (
        seg:has_tag("add_user_dict")
    ) or false
    env.settings = {
        chaifen_enabled = env.engine.context:get_option("chaifen") or env.is_radical_mode or input_preedit:find("`") or input_preedit:find("*")
    }
end

function ZH.func(input, env)
    ZH.init(env)
    CF.init(env)

    for cand in input:iter() do
        if env.settings.chaifen_enabled then
            local cf_comment = CF.run(cand, env)
            if cf_comment then
                cand:get_genuine().comment = cf_comment
            end
        end
        yield(cand)
    end
    
    CF.fini(env)
end

return {
    CF = CF,
    ZH = ZH,
    func = ZH.func
}