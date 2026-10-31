local M = {}
local TASK = {
    type = "object",
    properties = {
        agent = { type = "string", description = "The agent to run." },
        task = { type = "string", description = "Include everything the agent needs; it has its own context." },
        cwd = { type = "string", description = "The working directory, shared with the parent by default." },
    },
    required = { "agent", "task" },
}

function M.setup(options)
    local opts = {
        policy = "allow",
        scope = "user",
        confirm_project = true,
        concurrency = 4,
        max_tasks = 8,
        output = 51200,
        max_history = 100
    }
    for key, value in pairs(options or {}) do opts[key] = value end
    for _, key in ipairs({ "concurrency", "max_tasks", "output", "max_history" }) do
        assert(type(opts[key]) == "number" and opts[key] >= 1 and opts[key] % 1 == 0,
            key .. " must be a positive integer")
    end
    local app = require("uji.core.app")
    local worker = require("managed_subagent.worker")
    worker.check()
    if app.command == "run" and app.flags.parent and uji.os.env("UJI_MANAGED_TOKEN") and uji.os.env("UJI_MANAGED_ID") then
        worker.install()
        return
    end
    if app.flags.parent or app.command == "run" then return end
    local agents = require("managed_subagent.agents")
    local protocol = require("managed_subagent.protocol")
    local manager = require("managed_subagent.manager").new(opts)
    M.manager = manager
    uji.context.add("managed-subagents", function()
        local lines = {
            "The subagent tool starts background agents and returns IDs immediately, not their answers.",
            "Continue working or respond to the user while they run. Completion results arrive automatically; do not poll in a loop.",
            "Use subagent_status to inspect progress/results, subagent_steer to redirect work, and subagent_stop to cancel.",
            "Steering is queued and consumed between model/tool cycles; it cannot undo or preempt an action already running.",
            "Agents share the working directory unless cwd is specified. Coordinate edits to avoid conflicting changes.",
            "Agents you can start:",
        }
        for _, agent in ipairs(agents.list(agents.discover(opts.scope))) do
            lines[#lines + 1] = "- " .. agent.name .. ": " .. agent.description
        end
        return table.concat(lines, "\n")
    end, { priority = 30 })
    uji.tool.add("subagent", {
        description =
            "Start agents in the background and immediately receive task IDs. Give agent/task, parallel tasks, or a chain "
            ..
            "whose {previous} placeholders receive the previous answer. Results arrive automatically. The main conversation remains available.",
        parameters = {
            type = "object",
            properties = {
                agent = TASK.properties.agent,
                task = TASK.properties.task,
                cwd = TASK.properties.cwd,
                tasks = { type = "array", items = TASK },
                chain = { type = "array", items = TASK },
                scope = { type = "string", enum = { "user", "project", "both" } },
            }
        },
        policy = opts.policy,
        display = { label = "Start agents", question = "Start these background agents?" },
        subject = function(args)
            if args.agent then return args.agent end
            local names = {}
            for _, item in ipairs(args.tasks or args.chain or {}) do names[#names + 1] = tostring(item.agent) end
            return table.concat(names, ", ")
        end,
        run = function(args)
            local history = manager:list()
            if #history >= opts.max_history then
                for _, task in ipairs(history) do
                    if not protocol.terminal(task.status) then return
                        "error: task history limit reached; finish active agents first" end
                end
                manager.tasks, manager.order = {}, {}
            end
            local items, mode = agents.resolve(args, opts)
            if not items then return "error: " .. mode end
            if #manager.order + #items > opts.max_history then return "error: task history limit reached" end
            local choice = uji.model.current()
            local tasks, err = manager:launch(items, mode, uji.session.info().id, uji.session.info().directory,
                { model = choice.provider ~= "" and choice.provider .. "/" .. choice.model or nil, effort = choice
                .effort })
            if not tasks then return "error: " .. err end
            local lines = { "Started in background. You can continue; results will arrive automatically." }
            for _, task in ipairs(tasks) do lines[#lines + 1] = task.id ..
                " · " .. task.agent.name .. " · " .. task.status end
            return table.concat(lines, "\n")
        end,
    })
    local id_schema = { type = "string", description = "The task ID returned by subagent, such as agent-1." }
    uji.tool.add("subagent_status", {
        description =
        "Inspect agent progress and steering acknowledgements, or retrieve a finished result. Do not poll in a loop.",
        parameters = { type = "object", properties = { id = id_schema } },
        policy = "allow",
        run = function(args)
            local tasks = args.id and { manager:get(args.id) } or manager:list()
            if args.id and not tasks[1] then return "error: unknown agent " .. args.id end
            local lines = {}
            for _, task in ipairs(tasks) do
                lines[#lines + 1] = task.id .. " · " .. task.agent.name .. " · " .. task.status
                    .. (task.session_id and " · session " .. task.session_id or "")
                if task.latest then lines[#lines + 1] = task.latest end
                if task.result or task.error then lines[#lines + 1] = (task.result or task.error):sub(1, opts.output) end
                for _, steering in ipairs(task.steering) do
                    lines[#lines + 1] = steering.id ..
                    " · " .. steering.status .. (steering.error and " · " .. steering.error or "")
                end
            end
            return #lines > 0 and table.concat(lines, "\n") or "No managed agents yet."
        end,
    })
    for _, action in ipairs({ "steer", "stop" }) do
        local properties = { id = id_schema }
        if action == "steer" then properties.text = { type = "string", description = "The mid-turn instruction to send." } end
        uji.tool.add("subagent_" .. action, {
            description = action == "steer" and
                "Queue mid-turn steering for a running agent; consumed at the next model/tool-cycle boundary."
                or "Explicitly stop a queued or running agent, without stopping the main conversation.",
            parameters = { type = "object", properties = properties, required = action == "steer" and { "id", "text" } or { "id" } },
            policy = opts.policy,
            subject = function(args) return args.id end,
            run = function(args)
                if action == "steer" then return manager:steer(args.id, args.text, "parent") end
                return manager:stop(args.id)
            end,
        })
    end
    uji.on("before_quit", function() manager:shutdown() end, { name = "managed-subagents-cleanup" })
    local restart = uji.os.restart
    uji.os.restart = function(args)
        manager:shutdown()
        return restart(args)
    end
    require("managed_subagent.ui").setup(manager, opts)
end

function M.wrap_theme(theme)
    return require("managed_subagent.ui").wrap_theme(theme)
end

return M
