require("uji.builtin.defaults")
local root = require("uji.core.paths").config() .. "/../.."
uji.pack.add({ { dir = root } })
uji.provider.add({
    id = "managed-test",
    name = "Model-free test provider",
    api = uji.api.openai(),
    base_url = "http://127.0.0.1:1",
    models = { { id = "fake", context = 100000 } }
})
local model = require("uji.core.model")
model.stream = function(request, reply)
    reply.text("live test output")
    uji.sleep(0.4)
    local last = request.messages[#request.messages]
    local marker = (last.text or ""):match("SHELL_TEST (%S+)")
    if marker then
        return {
            text = "running a cancellable command",
            tool_calls = { {
                id = "shell-test",
                name = "run_command",
                arguments = uji.json.encode({
                    command = "python3 " .. string.format("%q", root .. "/tests/command.py")
                        .. " " .. string.format("%q", marker),
                    timeout = 10
                })
            } }
        }
    end
    return { text = "answer: " .. tostring(last.text or last.content), tool_calls = {} }
end
if uji.os.env("UJI_MANAGED_TOKEN") then
    require("managed_subagent.worker").install()
else
    package.loaded["uji.core.run"] = function(store, parsed)
        require("uji.core.task").release()
        local names = { integration = "integration.lua", ui = "ui.lua" }
        local name = names[parsed.positional[1]] or "run.lua"
        local ok, err = pcall(function() return assert(loadfile(root .. "/tests/" .. name))(store) end)
        if not ok then io.stderr:write(tostring(err), "\n") end
        require("uji.sys").os.exit(ok and 0 or 1)
    end
end
