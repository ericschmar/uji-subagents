local store = ...
local ito = require("ito")
local app = require("uji.core.app")
local ui = require("uji.core.ui")
local keys = require("uji.core.ui.keys")
local plugin = require("managed_subagent.ui")
local child = {
    id = "agent-1",
    agent = { name = "scout" },
    task = "Inspect the test",
    status = "running",
    messages = { { type = "user", text = "CHILD_PROMPT" } },
    partial = "CHILD_LIVE",
    steering = {}
}
local received, listeners = {}, {}
local manager = {}
function manager:list() return { child } end

function manager:get() return child end

function manager:subscribe(fn) listeners[#listeners + 1] = fn end

function manager:steer(id, text, source)
    received[#received + 1] = { id = id, text = text, source = source }
    return "queued"
end

function manager:stop() return "stopped" end

app.attach(store:create_session("UI test"))
plugin.setup(manager, {})
uji.ui.configure({ theme = plugin.wrap_theme(require("uji.themes.default")()) })
ui:open()
ui:listen()
ui:set_input("MAIN_DRAFT")
local function rows()
    ui:paint()
    local diagnostics = require("uji.core.diagnostics").list()
    assert(#diagnostics == 0, uji.json.encode(diagnostics))
    local _, height = ui.screen:size()
    local result = {}
    for row = 0, height - 1 do result[#result + 1] = ui.screen:text(row) end
    return result
end
local last_screen
local function shown(text)
    last_screen = table.concat(rows(), "\n")
    return last_screen:find(text, 1, true)
end
local function click(text)
    uji.sleep(0.5)
    for row, line in ipairs(rows()) do
        local at = line:find(text, 1, true)
        if at then
            local col = ito.text.width and ito.text.width(line:sub(1, at - 1)) or uji.width(line:sub(1, at - 1))
            ui:mouse({ kind = "down", button = "left", row = row - 1, col = col })
            ui:mouse({ kind = "up", button = "left", row = row - 1, col = col })
            return
        end
    end
    error("missing clickable text: " .. text .. "\n" .. table.concat(rows(), "\n"))
end
assert(shown("Main conversation"), "main sidebar entry missing")
assert(shown("MAIN_DRAFT"), "parent draft missing")
click("scout")
assert(shown("CHILD_LIVE"), "child live view did not open")
assert(shown("CHILD_PROMPT"), "saved child messages missing")
for char in ("STEER_FROM_VIEW"):gmatch(".") do ui:key(keys.chord(char)) end
ui:key(keys.chord("enter"))
uji.sleep(0.05)
assert(received[1] and received[1].text == "STEER_FROM_VIEW" and received[1].source == "ui",
    "child input must steer selected agent")
assert(ui.composer:text() == "MAIN_DRAFT", "child input must not mutate the parent draft")
for char in ("CHILD_DRAFT"):gmatch(".") do ui:key(keys.chord(char)) end
assert(shown("CHILD_DRAFT"), "draft missing before switching\n" .. last_screen)
ui:key(keys.parse("<A-m>"))
uji.sleep(0.05)
assert(shown("MAIN_DRAFT"), "main shortcut did not return to parent")
click("scout")
assert(shown("CHILD_DRAFT"), "child draft should survive switching\n" .. last_screen)
ui:handle({ type = "paste", text = " PASTED_TEXT\nSECOND_LINE" })
assert(shown("PASTED_TEXT"), "terminal paste must reach the child composer")
assert(ui.composer:text() == "MAIN_DRAFT", "paste must not change the hidden parent")
ui:key(keys.parse("<C-u>"))
assert(not shown("CHILD_DRAFT"), "editing shortcuts must edit the child composer")
assert(ui.composer:text() == "MAIN_DRAFT", "editing shortcuts must not edit the parent")
ui:key(keys.chord("esc"))
assert(shown("MAIN_DRAFT"), "Escape should return to main rather than interrupt it")
click("scout")
local Confirm = require("uji.core.ui.views.confirm")
local approval = ui:present(Confirm({ title = "PARENT_APPROVAL", body = "Main thread needs approval" }))
assert(shown("PARENT_APPROVAL"), "parent approvals must remain visible from child view")
approval:close(false)
assert(shown("CHILD_LIVE"), "closing approval should restore child view")
ui.screen:clear()
local terminal = ui.screen
local narrow = setmetatable({ size = function() return 70, 32 end }, {
    __index = function(_, key)
        return function(_, ...) return terminal[key](terminal, ...) end
    end
})
ui.screen, ui.window.screen = narrow, narrow
assert(not shown("Main conversation"), "narrow layout should hide the sidebar")
assert(shown("Main thread"), "narrow child view must still offer return to main")
local diagnostics = require("uji.core.diagnostics")
assert(#diagnostics.list() == 0, "rendering must not produce diagnostics")
io.stdout:write(
"\npassed terminal UI: right sidebar, live view, steering input, drafts, return shortcut, approval, narrow layout\n")
