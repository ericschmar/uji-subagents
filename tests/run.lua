local protocol = require('managed_subagent.protocol')
local Manager = require('managed_subagent.manager')
local agents = require('managed_subagent.agents')
local passed = 0
local function eq(actual, expected, label)
    assert(actual == expected, (label or 'value') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function test(name, fn)
    fn()
    passed = passed + 1
    io.stdout:write('ok ', name, '\n')
end

local queue, deliveries, handles, requests = {}, {}, {}, {}
local function runtime()
    return {
        spawn = function(fn) queue[#queue + 1] = fn end,
        token = function() return 'secret' end,
        start = function(task, event, exit)
            local handle = { task = task, event = event, exit = exit, killed = 0 }
            function handle.kill() handle.killed = handle.killed + 1 end

            handles[#handles + 1] = handle
            return handle
        end,
        request = function(port, token, command)
            requests[#requests + 1] = { port = port, token = token, command = command }
            return { status = 'queued' }
        end,
        deliver = function(task, text) deliveries[#deliveries + 1] = { task = task, text = text } end,
    }
end
local function drain()
    while #queue > 0 do table.remove(queue, 1)() end
end
local function manager(concurrency)
    queue, deliveries, handles, requests = {}, {}, {}, {}
    return Manager.new({ runtime = runtime(), concurrency = concurrency or 4 })
end
local function launch(m, count, mode)
    local items = {}
    for i = 1, count do items[i] = { found = { name = 'agent' .. i }, task = 'task' .. i } end
    return m:launch(items, mode or 'parallel', 'parent', '/tmp', { model = 'provider/model' })
end
local function ready(handle, seq)
    handle.event({ type = 'ready', task_id = handle.task.id, seq = seq or 1, port = 1234, session_id = 'child' })
end
local function done(handle, seq, status, text)
    handle.event({ type = 'done', task_id = handle.task.id, seq = seq, status = status, text = text })
    handle.exit(status == 'completed' and 0 or 1)
end

test('launch returns before scheduled starts', function()
    local m = manager()
    local tasks = launch(m, 1)
    eq(#tasks, 1); eq(tasks[1].status, 'starting'); eq(#handles, 0)
    drain(); eq(#handles, 1)
end)
test('concurrency shared across launches', function()
    local m = manager(1)
    launch(m, 1); launch(m, 1); drain()
    eq(#handles, 1); done(handles[1], 2, 'completed', 'one'); drain(); eq(#handles, 2)
end)
test('chain starts in dependency order and substitutes answer', function()
    local m = manager(1)
    local tasks = m:launch({ { found = { name = 'first' }, task = 'first' },
        { found = { name = 'second' }, task = '{previous}' } }, 'chain', 'parent', '/tmp', { model = 'provider/model' })
    drain()
    eq(#handles, 1); done(handles[1], 2, 'completed', 'answer'); drain()
    eq(#handles, 2); eq(tasks[2].task, 'answer')
end)
test('failed chain cancels downstream steps', function()
    local m = manager(1); local tasks = launch(m, 3, 'chain'); drain()
    done(handles[1], 2, 'failed', 'bad')
    eq(tasks[2].status, 'cancelled'); eq(tasks[3].status, 'cancelled')
end)
test('queued and running stop', function()
    local m = manager(1); local tasks = launch(m, 2); m:stop(tasks[2].id)
    eq(tasks[2].status, 'cancelled'); drain(); m:stop(tasks[1].id); drain()
    eq(handles[1].killed, 1)
end)
test('duplicate exit/result delivers exactly once', function()
    local m = manager(); local t = launch(m, 1)[1]; drain()
    done(handles[1], 2, 'completed', 'ok'); done(handles[1], 3, 'completed', 'again')
    eq(#deliveries, 1); eq(t.result, 'ok')
end)
test('steering before ready flushes on ready', function()
    local m = manager(); local t = launch(m, 1)[1]; drain()
    m:steer(t.id, 'redirect'); eq(#requests, 0); ready(handles[1]); drain()
    eq(#requests, 1); eq(requests[1].command.text, 'redirect')
end)
test('consumed steering acknowledgement is not downgraded', function()
    local m = manager(); local t = launch(m, 1)[1]; drain(); ready(handles[1])
    m:steer(t.id, 'x'); drain(); local id = t.steering[1].id
    handles[1].event({ type = 'steering', task_id = t.id, seq = 2, id = id, status = 'consumed' })
    handles[1].event({ type = 'steering', task_id = t.id, seq = 3, id = id, status = 'queued' })
    eq(t.steering[1].status, 'consumed')
end)
test('invalid steering text rejected', function()
    local m = manager(); local t = launch(m, 1)[1]
    assert(m:steer(t.id, '  '):match('error:'))
end)
test('protocol malformed event rejected using uji JSON', function()
    eq(protocol.decode('{'), nil)
end)
test('protocol command size and blank validation', function()
    assert(not protocol.command({ id = 'x', action = 'steer', text = ' ' }))
    assert(not protocol.command({ id = 'x', action = 'steer', text = string.rep('a', protocol.max_steering + 1) }))
    local wire = uji.json.encode({ version = 1, type = 'ready', seq = 1 })
    eq(protocol.decode(wire).type, 'ready')
    eq(protocol.decode(string.rep('x', protocol.max_bytes + 1)), nil)
end)
test('protocol authenticates and enforces request size', function()
    local function serve(token, header, body)
        local lines = { 'POST /control HTTP/1.1', header, 'Content-Length: ' .. #body, '' }
        local conn = { output = '' }
        function conn:line() return table.remove(lines, 1) end

        function conn:read(n)
            eq(n, #body); return body
        end

        function conn:write(value) self.output = self.output .. value end

        protocol.serve(conn, token, function(command) return { id = command.id } end)
        return conn.output
    end
    local body = uji.json.encode({ id = 'a', action = 'stop' })
    assert(serve('secret', 'Authorization: Bearer wrong', body):match('403 Forbidden'))
    assert(serve('secret', 'Authorization: Bearer secret', body):match('200 OK'))
    local escaped = uji.json.encode({ id = 'escaped', action = 'steer', text = string.rep('"', protocol.max_steering) })
    assert(serve('secret', 'Authorization: Bearer secret', escaped):match('200 OK'))
    local oversized = string.rep('x', protocol.max_steering * 6 + 1025)
    assert(serve('secret', 'Authorization: Bearer secret', oversized):match('413 Content Too Large'))
end)
test('agent discovery scope and project approval', function()
    local original = uji.config.files
    uji.config.files = function(_, options)
        local all = { { name = 'user.md', text = '---\ndescription: User\n---\nBody', path = '/user', project = false },
            { name = 'project.md', text = '---\ndescription: Project\n---\nPrompt', path = '/project', project = true } }
        if not options.project then return { all[1] } end
        return all
    end
    local ui = uji.ui.select
    uji.ui.select = function() return 'Cancel' end
    local found = agents.discover('project')
    eq(found.user, nil); eq(found.project.name, 'project')
    local opts = { scope = 'project', max_tasks = 8, confirm_project = true }
    local result, err = agents.resolve({ agent = 'project', task = 'do' }, opts)
    eq(result, nil); assert(err:match('not approved'))
    uji.ui.select = ui; uji.config.files = original
end)
test('UI and worker modules load in the installed runtime', function()
    assert(require('managed_subagent.ui').wrap_theme)
    require('managed_subagent.worker').check()
    assert(require('managed_subagent').setup)
end)
io.stdout:write('passed ', passed, ' tests\n')
