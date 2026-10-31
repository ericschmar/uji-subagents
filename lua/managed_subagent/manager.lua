local protocol = require("managed_subagent.protocol")
local Manager = {}
Manager.__index = Manager

local function runtime()
    local sys = require("uji.sys")
    local flags = { ["config-dir"] = true, ["data-dir"] = true, db = true }
    return {
        spawn = function(fn) return uji.task.spawn(fn) end,
        token = function() return sys.base64.encode(sys.random(32), { url = true, pad = false }) end,
        request = protocol.request,
        stop = function(task)
            local deadline = uji.os.clock() + 5
            while not task.port and not task.exited and uji.os.clock() < deadline do uji.sleep(0.02) end
            if task.port and not task.exited then
                pcall(protocol.request, task.port, task.token, { id = task.id .. "-stop", action = "stop" })
                deadline = uji.os.clock() + 3
                while not task.exited and uji.os.clock() < deadline do uji.sleep(0.02) end
            end
            if not task.exited and task.proc then task.proc.kill() end
        end,
        start = function(task, on_event, on_exit)
            local args = { uji.os.executable, "run", "--json", "--parent", task.parent,
                "--title", task.agent.name .. ": " .. task.task:match("[^\n]*") }
            local argv, index = uji.os.argv, 2
            while index <= #argv do
                local arg = argv[index]
                local flag = arg:match("^%-%-([%w%-]+)=")
                if flag and flags[flag] then
                    args[#args + 1] = arg
                elseif arg:sub(1, 2) == "--" and flags[arg:sub(3)] and argv[index + 1] then
                    args[#args + 1] = arg
                    index = index + 1
                    args[#args + 1] = argv[index]
                end
                index = index + 1
            end
            local model = task.model
            if model then
                args[#args + 1] = "--model"
                args[#args + 1] = model
            end
            if task.effort then
                args[#args + 1] = "--effort"
                args[#args + 1] = task.effort
            end
            if task.agent.tools then
                args[#args + 1] = "--tools"
                args[#args + 1] = table.concat(task.agent.tools, ",")
            end
            if task.agent.prompt ~= "" then
                args[#args + 1] = "--append-prompt"
                args[#args + 1] = task.agent.prompt
            end
            args[#args + 1] = "Task: " .. task.task
            local proc, err = uji.proc.spawn(args, {
                cwd = task.cwd,
                env = { UJI_MANAGED_TOKEN = task.token, UJI_MANAGED_ID = task.id }
            })
            if not proc then error(err) end
            proc:close()
            uji.task.spawn(function()
                local ok, problem = pcall(function()
                    for line, stream in proc:lines() do
                        if stream == "stdout" then
                            local event = protocol.decode(line)
                            if event then on_event(event) end
                        else
                            task.stderr = ((task.stderr or "") .. "\n" .. line):sub(-8192)
                        end
                    end
                    local exit = proc:wait()
                    on_exit(exit.code or -1)
                end)
                if not ok then
                    proc:kill()
                    on_exit(-1, uji.message(problem))
                end
            end)
            uji.task.spawn(function()
                uji.sleep(20)
                if task.status == "starting" then
                    task.error = "worker did not become ready within 20 seconds"
                    proc:kill()
                end
            end)
            return { kill = function() proc:kill() end }
        end,
        deliver = function(task, text)
            uji.notify(task.id .. " · " .. task.agent.name .. " · " .. task.status)
            uji.session.submit(text)
        end,
    }
end

function Manager.new(opts)
    opts = opts or {}
    return setmetatable({
        opts = opts,
        runtime = opts.runtime or runtime(),
        tasks = {},
        order = {},
        listeners = {},
        serial = 0,
        active = 0,
        closing = false
    }, Manager)
end

function Manager:subscribe(fn)
    self.listeners[#self.listeners + 1] = fn
end

function Manager:changed(task)
    for _, listener in ipairs(self.listeners) do listener(task) end
end

function Manager:get(id) return self.tasks[id] end

function Manager:list()
    local tasks = {}
    for _, id in ipairs(self.order) do tasks[#tasks + 1] = self.tasks[id] end
    return tasks
end

function Manager:launch(items, mode, parent, cwd, choice)
    if self.closing then return nil, "manager is shutting down" end
    local added, previous = {}, nil
    for _, item in ipairs(items) do
        self.serial = self.serial + 1
        local id = "agent-" .. self.serial
        local task = {
            id = id,
            agent = item.found,
            task = item.task,
            parent = parent,
            cwd = item.cwd or cwd,
            status = "queued",
            messages = {},
            steering = {},
            partial = "",
            reasoning = "",
            seq = 0,
            token = self.runtime.token(),
            dependency = mode == "chain" and previous or nil,
            model = item.found.model or choice.model,
            effort = item.found.effort or choice.effort
        }
        self.tasks[id], self.order[#self.order + 1] = task, id
        added[#added + 1], previous = task, id
    end
    self:changed()
    self:pump()
    return added
end

function Manager:complete(task, status, text)
    if protocol.terminal(task.status) then return end
    task.status = status
    task.partial, task.reasoning = "", ""
    task.result = status == "completed" and text or nil
    task.error = status ~= "completed" and text or nil
    for _, steering in ipairs(task.steering) do
        if steering.status ~= "consumed" and steering.status ~= "failed" then steering.status = "not_consumed" end
    end
    self:changed(task)
    if not task.delivered and not self.closing then
        task.delivered = true
        local result = text or ""
        local limit = self.opts.output or 51200
        if #result > limit then result = result:sub(1, limit) ..
            "\n[Result clipped; inspect the child session for full output.]" end
        self.runtime.deliver(task, "Subagent " .. task.id .. " (" .. task.agent.name .. ") " .. status .. ":\n" .. result)
    end
end

function Manager:exited(task, code, problem)
    if task.exited then return end
    task.exited = true
    self.active = self.active - 1
    local done = task.done
    local status = task.cancelled and "cancelled" or (done and done.status or "failed")
    if status == "completed" and code ~= 0 then status = "failed" end
    self:complete(task, status, task.error or (done and done.text)
        or problem or ("worker exited " .. code .. " without a result" .. (task.stderr or "")))
    task.proc = nil
    self:pump()
end

function Manager:pump()
    if self.closing then return end
    for _, id in ipairs(self.order) do
        local task = self.tasks[id]
        if task.status == "queued" then
            local dependency = task.dependency and self.tasks[task.dependency]
            if dependency and protocol.terminal(dependency.status) and dependency.status ~= "completed" then
                self:complete(task, "cancelled",
                    "Previous chain step " .. dependency.id .. " did not complete successfully")
            elseif (not dependency or dependency.status == "completed") and self.active < (self.opts.concurrency or 4) then
                if dependency then task.task = task.task:gsub("{previous}", function() return dependency.result or "" end) end
                task.status, self.active = "starting", self.active + 1
                self:changed(task)
                self.runtime.spawn(function()
                    if task.cancelled or self.closing then return self:exited(task, -1, "cancelled before launch") end
                    local ok, proc = pcall(self.runtime.start, task,
                        function(event) self:event(task, event) end,
                        function(code, problem) self:exited(task, code, problem) end)
                    if not ok then return self:exited(task, -1, tostring(proc)) end
                    task.proc = not task.exited and proc or nil
                    if task.cancelled and task.proc then self:terminate(task) end
                end)
            end
        end
    end
end

function Manager:event(task, event)
    if task.exited or event.task_id ~= task.id or event.seq <= task.seq then return end
    task.seq = event.seq
    if event.type == "ready" then
        if type(event.port) ~= "number" or event.port < 1 or event.port > 65535 or type(event.session_id) ~= "string" then return end
        task.port, task.session_id = event.port, event.session_id
        if not task.cancelled then task.status = "running" end
        self:flush(task)
    elseif event.type == "message" and type(event.message) == "table" then
        local message = event.message
        local kept = {
            type = message.type,
            name = message.name,
            tool_calls = message.tool_calls,
            text = message.text and message.text:sub(1, 262144),
            content = message.content and message.content:sub(1, 262144)
        }
        local size = #uji.json.encode(kept)
        task.messages[#task.messages + 1] = kept
        task.message_sizes = task.message_sizes or {}
        task.message_sizes[#task.message_sizes + 1] = size
        task.message_bytes = (task.message_bytes or 0) + size
        while #task.messages > 1000 or task.message_bytes > 2 * 1024 * 1024 do
            table.remove(task.messages, 1)
            task.message_bytes = task.message_bytes - table.remove(task.message_sizes, 1)
        end
    elseif event.type == "delta" and type(event.text) == "string" then
        local field = event.kind == "reasoning" and "reasoning" or "partial"
        task[field] = (task[field] .. event.text):sub(-262144)
    elseif event.type == "clear" then
        task.partial, task.reasoning = "", ""
    elseif event.type == "progress" then
        task.latest = tostring(event.tool or "") .. " " .. tostring(event.line or "")
    elseif event.type == "steering" then
        for _, steering in ipairs(task.steering) do
            if steering.id == event.id and steering.status ~= "consumed" then
                if event.status == "queued" or event.status == "consumed" or event.status == "not_consumed" then
                    steering.status = event.status
                end
            end
        end
    elseif event.type == "done" and protocol.terminal(event.status) then
        task.done = { status = event.status, text = tostring(event.text or "") }
        task.usage = event.usage
    elseif event.type == "notice" then
        task.latest = tostring(event.text or "")
    end
    self:changed(task)
end

function Manager:flush(task)
    if task.flushing or not task.port or task.cancelled or task.exited or task.done then return end
    task.flushing = true
    self.runtime.spawn(function()
        local ok, err = pcall(function()
            for _, steering in ipairs(task.steering) do
                if steering.status == "pending" and not task.cancelled and not task.exited and not task.done then
                    steering.status = "sending"
                    local response, problem = self.runtime.request(task.port, task.token,
                        { id = steering.id, action = "steer", text = steering.text })
                    if steering.status ~= "consumed" and not task.exited then
                        steering.status = response and "queued" or "delivery_unknown"
                        steering.error = problem
                    end
                    self:changed(task)
                end
            end
        end)
        task.flushing = false
        if not ok then
            task.latest = "Steering delivery failed: " .. tostring(err)
            self:changed(task)
        end
    end)
end

function Manager:steer(id, text, source)
    local task = self:get(id)
    if not task then return "error: unknown agent " .. tostring(id) end
    if protocol.terminal(task.status) or task.cancelled or task.done then return "error: agent is no longer running" end
    local number = #task.steering + 1
    local command, err = protocol.command({ id = id .. "-steer-" .. number, action = "steer", text = text })
    if not command then return "error: " .. err end
    if number > 256 then return "error: steering history limit reached" end
    task.steering[number] = { id = command.id, text = text, source = source or "parent", status = "pending" }
    self:changed(task)
    self:flush(task)
    return command.id .. " queued for delivery; it will be consumed at the next model/tool-cycle boundary."
end

function Manager:terminate(task)
    if (task.terminating and not self.closing) or task.exited or not task.proc then return end
    task.terminating = true
    if self.runtime.stop then self.runtime.stop(task) else task.proc.kill() end
end

function Manager:stop(id)
    local task = self:get(id)
    if not task then return "error: unknown agent " .. tostring(id) end
    if protocol.terminal(task.status) then return id .. " is already " .. task.status end
    task.cancelled = true
    if task.status == "queued" then
        self:complete(task, "cancelled", "Cancelled before launch")
        self:pump()
    else
        task.status = "stopping"
        self:changed(task)
        self.runtime.spawn(function() self:terminate(task) end)
    end
    return "Stopping " .. id
end

function Manager:shutdown()
    self.closing = true
    for _, task in ipairs(self:list()) do
        if not protocol.terminal(task.status) then
            task.cancelled = true
            self:terminate(task)
        end
    end
end

return Manager
