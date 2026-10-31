local M = {}

local function names(value)
    local result = {}
    for name in (value or ""):gsub("^%[", ""):gsub("%]$", ""):gmatch("[^,%s]+") do
        result[#result + 1] = name
    end
    return #result > 0 and result or nil
end

function M.discover(scope)
    local found = {}
    for _, file in ipairs(uji.config.files("agents", { project = scope ~= "user" })) do
        if file.project or scope ~= "project" then
            local base = file.name:match("^(.+)%.md$")
            if base then
                local head, body = file.text:match("^%-%-%-%s*\n(.-)\n%-%-%-[^\n]*\n?(.*)$")
                local fields = {}
                for line in (head or ""):gmatch("[^\n]+") do
                    local key, value = line:match("^([%w_%-]+):%s*(.-)%s*$")
                    if key then fields[key] = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value end
                end
                if fields.description then
                    local name = fields.name or base
                    found[name] = {
                        name = name,
                        description = fields.description,
                        tools = names(fields.tools),
                        model = fields.model,
                        effort = fields.effort,
                        prompt = (body or ""):gsub("^%s+", ""):gsub("%s+$", ""),
                        source = file.project and "project" or "user",
                        path = file.path
                    }
                end
            end
        end
    end
    return found
end

function M.list(found)
    local agents = {}
    for _, agent in pairs(found) do agents[#agents + 1] = agent end
    table.sort(agents, function(a, b) return a.name < b.name end)
    return agents
end

function M.resolve(args, opts)
    local scope = args.scope or opts.scope
    if scope ~= "user" and scope ~= "project" and scope ~= "both" then return nil, "invalid agent scope" end
    local found, mode, items = M.discover(scope)
    if type(args.chain) == "table" and #args.chain > 0 then
        mode, items = "chain", args.chain
    elseif type(args.tasks) == "table" and #args.tasks > 0 then
        mode, items = "parallel", args.tasks
    elseif type(args.agent) == "string" and type(args.task) == "string" then
        mode, items = "single", { { agent = args.agent, task = args.task, cwd = args.cwd } }
    else
        return nil, "give agent and task, tasks, or chain"
    end
    if #items > opts.max_tasks then return nil, "at most " .. opts.max_tasks .. " tasks per launch" end
    local resolved, from = {}, {}
    for _, item in ipairs(items) do
        if type(item) ~= "table" or type(item.task) ~= "string" or not item.task:find("%S") then
            return nil, "every task must contain nonblank text"
        end
        if #item.task > 131072 then return nil, "task exceeds 128 KiB" end
        if item.cwd ~= nil and (type(item.cwd) ~= "string" or item.cwd == "") then return nil,
                "invalid working directory" end
        local agent = found[item.agent]
        if not agent then return nil, "there is no agent `" .. tostring(item.agent) .. "`" end
        resolved[#resolved + 1] = { found = agent, task = item.task, cwd = item.cwd }
        if agent.source == "project" then from[#from + 1] = agent.path end
    end
    if opts.confirm_project and #from > 0 then
        local choice = uji.ui.select({
            title = "Run agents from this project? " .. table.concat(from, ", "),
            items = { "Run them", "Cancel" }
        })
        if choice ~= "Run them" then return nil, "project agents were not approved" end
    end
    return resolved, mode
end

return M
