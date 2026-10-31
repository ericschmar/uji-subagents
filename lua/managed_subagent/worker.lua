local protocol = require("managed_subagent.protocol")
local M = {}

function M.check()
    local version = require("uji.version")
    assert(version == "0.2.3", "managed_subagent supports uji 0.2.3; found " .. tostring(version))
    local Agent = require("uji.core.agent")
    assert(type(Agent.steer) == "function" and type(Agent.submit) == "function", "uji agent steering API is unavailable")
end

function M.run(store, parsed)
    M.check()
    local sys = require("uji.sys")
    local app = require("uji.core.app")
    local model = require("uji.core.model")
    local event = require("uji.core.event")
    local task = require("uji.core.task")
    local Session = require("uji.core.store.session")
    local flags = parsed.flags
    local token, id = sys.os.env("UJI_MANAGED_TOKEN"), sys.os.env("UJI_MANAGED_ID")
    assert(token and id and flags.parent and store:session(flags.parent), "invalid managed worker launch")
    local provider, name = (flags.model or ""):match("^([^/]+)/(.+)$")
    model.resolve({ provider = provider, model = name, effort = flags.effort })
    model.load()
    assert(not model.current.provider.loop, "managed steering requires uji's default provider loop")
    local session = store:create_session(flags.title or "Managed agent", flags.parent)
    local agent = app.attach(session)
    agent.confirm = function() return true end
    if flags.tools then
        agent.tools = {}
        for tool in flags.tools:gmatch("[^,%s]+") do agent.tools[#agent.tools + 1] = tool end
    end
    if flags["append-prompt"] then
        event.on("before_turn", function(turn) return turn.system .. "\n\n" .. flags["append-prompt"] end,
            { name = "managed.worker.prompt", priority = 1000 })
    end
    local sequence, stopped, finished = 0, false, false
    local function emit(kind, payload, message)
        sequence = sequence + 1
        payload = payload or {}
        payload.version, payload.type, payload.seq, payload.task_id = protocol.version, kind, sequence, id
        local line = sys.json.encode(payload)
        if message then line = line:sub(1, -2) .. ',"message":' .. Session.encode(message) .. '}' end
        io.stdout:write(line, "\n")
        io.stdout:flush()
    end
    local pending, seen = {}, {}
    local steer = agent.steer
    agent.steer = function(self)
        local message = steer(self)
        if message then
            local control = table.remove(pending, 1)
            if control then emit("steering", { id = control.id, status = "consumed" }) end
        end
        return message
    end
    local server, problem = uji.net.listen(0)
    assert(server, problem)
    event.on("message_appended", function()
        local entries = session:entries()
        emit("message", nil, entries[#entries].message)
    end, { name = "managed.worker.message" })
    event.on("stream_delta", function(value) emit("delta", { kind = value.kind, text = value.text }) end,
        { name = "managed.worker.delta" })
    event.on("stream_cleared", function() emit("clear") end, { name = "managed.worker.clear" })
    event.on("tool_progress", function(value)
        emit("progress", { tool = value.name, line = value.line })
    end, { name = "managed.worker.progress" })
    event.on("tool_started", function(value) emit("progress", { tool = value.name }) end,
        { name = "managed.worker.tool" })
    event.on("notice", function(value) emit("notice", { text = value.text }) end,
        { name = "managed.worker.notice" })
    event.on("turn_finished", function()
        if finished then return end
        finished = true
        server:close()
        local entries = session:entries()
        local last = entries[#entries].message
        local status = stopped and "cancelled" or (last.type == "error" and "failed" or "completed")
        for _, control in ipairs(pending) do emit("steering", { id = control.id, status = "not_consumed" }) end
        emit("done", { status = status, text = last.text or "", usage = session.tally.usage })
        sys.os.exit(status == "failed" and 1 or 0)
    end, { name = "managed.worker.done", priority = 1000 })
    local function control(command)
        if finished then return { error = "agent has finished" } end
        if seen[command.id] then return seen[command.id] end
        local response = { id = command.id, status = "queued" }
        seen[command.id] = response
        if command.action == "stop" then
            return response, function()
                stopped = true
                agent:interrupt()
            end
        end
        if #pending >= 64 then
            seen[command.id] = { error = "steering queue is full" }
            return seen[command.id]
        end
        pending[#pending + 1] = command
        agent:enqueue(command.text)
        emit("steering", { id = command.id, status = "queued" })
        return response
    end
    task.spawn(function()
        while not finished do
            local conn = server:accept()
            if not conn then break end
            task.spawn(function()
                local ok, err = pcall(function()
                    task.timeout(5, function() protocol.serve(conn, token, control) end)
                end)
                pcall(conn.close, conn)
                if not ok then emit("notice", { text = "Control connection: " .. sys.message(err) }) end
            end)
        end
    end)
    emit("ready", { session_id = session.id, port = server.port })
    event.emit("session_created", { session_id = session.id })
    task.release()
    agent:submit(table.concat(parsed.positional or {}, " "))
end

function M.install()
    M.check()
    package.loaded["uji.core.run"] = M.run
end

return M
