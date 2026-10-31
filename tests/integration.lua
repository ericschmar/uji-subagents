local store = ...
local app = require("uji.core.app")
local Manager = require("managed_subagent.manager")
local protocol = require("managed_subagent.protocol")
local sys = require("uji.sys")
local parent = store:create_session("Managed integration parent")
app.attach(parent)
require("uji.core.model").resolve({ provider = "managed-test", model = "fake" })
local manager = Manager.new({ concurrency = 2 })
local deliveries = {}
local deliver = manager.runtime.deliver
manager.runtime.deliver = function(task, text)
    deliveries[#deliveries + 1] = { task = task, text = text }
    deliver(task, text)
end
local agent = { name = "test", prompt = "", model = "managed-test/fake" }
local function wait(predicate, label)
    local deadline = uji.os.clock() + 12
    while not predicate() and uji.os.clock() < deadline do uji.sleep(0.02) end
    assert(predicate(), label)
end
local tasks = manager:launch({ { found = agent, task = "one" }, { found = agent, task = "two" } },
    "parallel", parent.id, uji.os.cwd(), {})
assert(#tasks == 2)
app.agent:submit("MAIN_THREAD_CAN_RESPOND")
assert(app.agent:working(), "main agent must remain able to start its own turn")
wait(function() return tasks[1].port and tasks[2].port end, "workers should become ready")
local response, err = protocol.request(tasks[1].port, "wrong-secret", { id = "bad", action = "stop" })
assert(not response and err:find("403"), "real control listener must reject unauthenticated clients")
assert(not manager:steer(tasks[1].id, "PARENT_STEERING", "parent"):find("error:"))
assert(not manager:steer(tasks[2].id, "VIEW_STEERING", "ui"):find("error:"))
wait(function() return tasks[1].partial ~= "" and tasks[2].partial ~= "" end, "live text must stream before completion")
wait(function() return tasks[1].exited and tasks[2].exited end, "workers should finish")
for index, expected in ipairs({ "PARENT_STEERING", "VIEW_STEERING" }) do
    local task = tasks[index]
    assert(task.status == "completed", task.error)
    assert(task.result:find(expected, 1, true), "worker must consume steering before answering")
    assert(task.steering[1].status == "consumed", "consumption acknowledgement should arrive")
    local session = store:session(task.session_id)
    assert(session and #session:entries() >= 3, "child conversation must be persisted")
end
assert(#deliveries == 2, "each result must arrive once")
wait(function() return not app.agent:working() end, "main agent must consume automatic result messages")
local received = 0
for _, entry in ipairs(parent:entries()) do
    if entry.message.type == "user" and entry.message.text:find("Subagent agent-", 1, true) then received = received + 1 end
end
assert(received == 2, "production completion delivery must reach the main transcript exactly once per task")
local stopped = manager:launch({ { found = agent, task = "stop me" } }, "single", parent.id, uji.os.cwd(), {})[1]
wait(function() return stopped.port end, "third worker should start")
manager:stop(stopped.id)
wait(function() return stopped.exited end, "cancelled worker must exit")
assert(stopped.status == "cancelled", stopped.error)
assert(manager.active == 0, "no worker slots should leak")
local child_rows = store.db:query("SELECT id FROM sessions WHERE parent = ?", { parent.id })
assert(#child_rows == 3, "workers must be saved under the main session")
for _, mode in ipairs({ "stop", "shutdown" }) do
    local marker = os.tmpname()
    os.remove(marker)
    local shell = manager:launch({ { found = agent, task = "SHELL_TEST " .. marker } }, "single", parent.id, uji.os.cwd(),
        {})[1]
    wait(function() return shell.latest and shell.latest:find("SHELL_STARTED", 1, true) end, "shell must start")
    if mode == "stop" then manager:stop(shell.id) else manager:shutdown() end
    wait(function() return shell.exited end, "shell worker must exit")
    uji.sleep(2.2)
    local leaked = io.open(marker, "r")
    if leaked then
        leaked:close()
        os.remove(marker)
    end
    assert(not leaked, mode .. " must stop shell subprocesses, not just the worker")
end
manager:shutdown()
io.stdout:write(
    "passed real-process integration: two workers, live deltas, parent/UI steering, authentication, persistence, cancellation and shell cleanup\n")
