local M = {}
local installed = false
local control_edits = {
    a = "home",
    e = "tail",
    b = "left",
    f = "right",
    h = "backspace",
    d = "delete_forward",
    w = "delete_word_back",
    u = "delete_to_start",
    k = "delete_to_end",
    y = "yank",
    t = "transpose"
}
local alt_edits = { b = "word_left", f = "word_right", d = "delete_word_forward", backspace = "delete_word_back" }

function M.install(current, select_main)
    if installed then return end
    installed = true
    local ui = require("uji.core.ui")
    local handle, key = ui.handle, ui.key
    local function child()
        local state = current()
        return state and state.selected and state.manager:get(state.selected) and ui:mode() == "normal" and state or nil
    end
    ui.handle = function(self, incoming)
        if child() and incoming.type == "paste" then
            if self.window then self.window:key({ type = "paste", text = incoming.text }) end
            self:invalidate()
            return
        end
        return handle(self, incoming)
    end
    ui.key = function(self, chord)
        local state = child()
        if state then
            if chord.key == "esc" then
                select_main()
                return
            end
            if chord.key == "up" or chord.key == "down" or chord.key == "pageup" or chord.key == "pagedown"
                or (chord.ctrl and (chord.key == "p" or chord.key == "n")) then
                local scroll = state.scrolls[state.selected]
                if scroll then
                    local amount = (chord.key == "up" or chord.key == "pageup" or chord.key == "p") and -1 or 1
                    if chord.key == "pageup" or chord.key == "pagedown" then amount = amount * math.max(scroll.page, 1) end
                    scroll:scroll(amount)
                end
                self:invalidate()
                return
            end
            local edit = chord.ctrl and control_edits[chord.key] or chord.alt and alt_edits[chord.key]
            if edit and state.editor then
                local line = state.editor:field()
                line[edit](line)
                state.drafts[state.selected].value = line.text
                self:invalidate()
                return
            end
            if chord.ctrl or chord.alt or chord.key == "tab" or chord.key == "backtab" then
                if not (chord.ctrl and chord.key == "c") and not (chord.alt and (chord.key == "a" or chord.key == "m")) then
                    return
                end
            end
        end
        return key(self, chord)
    end
end

return M
