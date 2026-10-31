local ito = require("ito")

local active
local screen_default

local function task_label(task)
    local name = task.agent and task.agent.name or "agent"
    local status = task.status or "unknown"
    local unread = active and active.unread[task.id] and " •" or ""
    return name .. " · " .. status .. unread
end

local function make_scroll(id)
    local scroll = ito.ScrollState({ follow = true })
    active.scrolls[id] = scroll
    return scroll
end

local function task_messages(task)
    local rows = {}
    for _, message in ipairs(task.messages or {}) do
        local role = message.type or "message"
        local text = message.content or message.text or ""
        rows[#rows + 1] = ito.Text(role .. (message.name and " · " .. message.name or "")):bold()
        if text ~= "" then rows[#rows + 1] = uji.ui.Markdown({ text = tostring(text) }) end
        for _, call in ipairs(message.tool_calls or {}) do
            rows[#rows + 1] = ito.Text(call.name .. " " .. tostring(call.arguments)):wrap():dim()
        end
    end
    if task.partial and task.partial ~= "" then
        rows[#rows + 1] = ito.Text(tostring(task.partial)):wrap()
    end
    if task.reasoning and task.reasoning ~= "" then
        rows[#rows + 1] = ito.Text(tostring(task.reasoning)):wrap():dim()
    end
    for _, steering in ipairs(task.steering or {}) do
        rows[#rows + 1] = ito.Text("Steering · " .. steering.status .. " · " .. steering.text):wrap():dim()
    end
    if task.error then
        rows[#rows + 1] = ito.Text(tostring(task.error)):wrap():foreground(ito.Color.red)
    end
    return rows
end

local function select_task(id)
    if not active then return end
    active.selected = id
    active.editor = nil
    active.unread[id or "main"] = nil
    active.revision.value = active.revision.value + 1
end

local function sidebar(tasks)
    local rows = { ito.Text("Agents  /agents"):bold() }
    rows[#rows + 1] = ito.Text("Main conversation" .. (active.unread.main and " •" or ""))
        :on_tap(function() select_task(nil) end)
    for _, task in ipairs(tasks) do
        local id = task.id
        local label = ito.Text(task_label(task))
        if active.selected == id then label = label:reverse() end
        rows[#rows + 1] = label:on_tap(function() select_task(id) end)
        rows[#rows + 1] = ito.Text(task.id .. " · " .. task.task:match("[^\n]*")):dim()
        if task.latest then rows[#rows + 1] = ito.Text(task.latest):dim() end
    end
    return ito.ScrollView(ito.VStack(rows)):width(30):border(ito.theme().borders.plain)
end

local function main_screen(screen, tasks, width)
    local content = ito.VStack({
        screen.greeting(), screen.transcript():grow(), screen.activity():padding({ vertical = 1 }),
        screen.modals(), ito.ToolbarItems(ito.ToolbarPlacement.keyboard),
        screen.composer():border(ito.theme().borders.plain, { edges = ito.Edges.horizontal }),
        ito.ToolbarItems(ito.ToolbarPlacement.bottom_bar),
    }):grow()
    return ito.HStack({ content, width >= 100 and sidebar(tasks) or false }):grow()
end

local function build_screen(screen, width)
    local state = active
    if not state then return screen_default(screen) end
    local revision = state.revision.value
    local tasks = state.manager:list() or {}
    local function chrome(content)
        local placement = ito.ToolbarPlacement
        return ito.VStack({
            ito.HStack({ ito.ToolbarItems(placement.top_bar_leading, ito.HStack), ito.Spacer(),
                ito.ToolbarItems(placement.top_bar_trailing, ito.HStack) }),
            content:grow(),
        }):opaque():background(ito.theme().styles.screen)
    end
    if require("uji.core.ui"):mode() == "confirm" then
        return chrome(main_screen(screen, tasks, width))
    end
    local selected
    for _, task in ipairs(tasks) do
        if task.id == state.selected then
            selected = task
            break
        end
    end
    local side = width >= 100 and sidebar(tasks) or false
    if not selected then return chrome(main_screen(screen, tasks, width)) end
    local draft = state.drafts[selected.id]
    local transcript = ito.VStack(task_messages(selected))
    local composer = ito.TextField(draft):id("managed-steering", selected.id)
        :placeholder("Steer " .. (selected.agent and selected.agent.name or "agent") .. "…"):focused()
        :on_submit(function(text)
            if text == "" then return end
            if text == "/agent-main" or text == "/agents" or text == "/agent-stop" then
                draft.value = ""
                uji.task.spawn(function()
                    if text == "/agent-main" then
                        select_task(nil)
                    elseif text == "/agents" then
                        active.commands.agents()
                    else
                        uji.notify(state.manager:stop(selected.id))
                    end
                end)
                return
            end
            uji.task.spawn(function()
                local ok, result = pcall(function() return state.manager:steer(selected.id, text, "ui") end)
                if not ok or (type(result) == "string" and result:match("^error:")) then
                    uji.notify(tostring(result))
                elseif draft.value == text then
                    draft.value = ""
                end
            end)
        end)
    state.editor = composer
    return chrome(ito.HStack({
        ito.VStack({
            ito.Text("← Main thread (Alt-M)"):on_tap(function() select_task(nil) end),
            ito.Text(selected.id .. " · " .. selected.agent.name .. " · " .. selected.status):bold(),
            ito.ScrollView(transcript):state(state.scrolls[selected.id] or make_scroll(selected.id)):grow(),
            screen.modals(),
            ito.Text("Steer this agent · /agent-stop to cancel"):dim(),
            composer,
            ito.ToolbarItems(ito.ToolbarPlacement.keyboard), ito.ToolbarItems(ito.ToolbarPlacement.bottom_bar),
        }):grow(),
        side,
    }))
end

local M = {}

function M.setup(manager, opts)
    opts = opts or {}
    if opts.skip == true then return end
    active = { manager = manager, selected = nil, revision = ito.state(0), drafts = {}, scrolls = {}, unread = {}, commands = {} }
    local function synchronize(task)
        local present = {}
        for _, item in ipairs(manager:list()) do
            present[item.id] = true
            if not active.drafts[item.id] then active.drafts[item.id] = ito.state("") end
        end
        for _, collection in ipairs({ active.drafts, active.scrolls, active.unread }) do
            for id in pairs(collection) do
                if id ~= "main" and not present[id] then collection[id] = nil end
            end
        end
        if active.selected and not present[active.selected] then select_task(nil) end
        if task and active.selected ~= task.id then active.unread[task.id] = true end
        active.revision.value = active.revision.value + 1
    end
    synchronize()
    manager:subscribe(synchronize)
    require("managed_subagent.input").install(function() return active end, function() select_task(nil) end)
    uji.on("message_appended", function()
        if active and active.selected then
            active.unread.main = true
            active.revision.value = active.revision.value + 1
        end
    end)
    local function picker()
        local items = manager:list() or {}
        table.insert(items, 1, { id = false, agent = { name = "Main conversation" }, status = "main" })
        uji.ui.select({ title = "Agents", items = items, label = task_label }, function(task)
            if task then select_task(task.id or nil) end
        end)
    end
    active.commands.agents = picker
    uji.command.add("agents", { desc = "choose a managed agent", handler = picker })
    uji.command.add("agent-main", { desc = "return to the main conversation", handler = function() select_task(nil) end })
    uji.command.add("agent-stop", {
        desc = "stop a managed agent",
        handler = function(args)
            local id = args and args:match("%S+")
            if not id then return picker() end
            local ok, result = pcall(function() return manager:stop(id) end)
            if not ok or (type(result) == "string" and result:match("^error:")) then uji.notify(tostring(result)) end
        end
    })
    uji.keymap.add("normal", "<A-a>", picker)
    uji.keymap.add("normal", "<A-m>", function() select_task(nil) end)
end

function M.wrap_theme(theme)
    local wrapped = {}
    for key, value in pairs(theme) do wrapped[key] = value end
    wrapped.views = {}
    for key, value in pairs(theme.views or {}) do wrapped.views[key] = value end
    screen_default = theme.views and theme.views[uji.ui.Screen]
    wrapped.views[uji.ui.Screen] = function(screen)
        return ito.SubcomposeLayout(function(room) return build_screen(screen, room.width) end)
    end
    return wrapped
end

return M
