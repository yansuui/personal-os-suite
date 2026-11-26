import assert from 'node:assert/strict'
import { once } from 'node:events'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, rmSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { test } from 'node:test'
import { CloudStore } from '../src/store.ts'
import { hashToken } from '../src/auth.ts'
import { createV2Server } from '../src/server.ts'

const START = Date.parse('2026-01-02T03:04:05.000Z')

function storeFixture(t: import('node:test').TestContext) {
  let timestamp = START
  const store = new CloudStore(':memory:', () => new Date(timestamp))
  const device = store.pairDevice({ name: 'test-client', role: 'client', tokenHash: 'test-hash' })
  t.after(() => store.close())
  return {
    store, device, advance: (ms: number) => { timestamp += ms },
  }
}

test('invalid goal-question flags fail startup before creating a database or listener', t => {
  const directory = mkdtempSync(join(import.meta.dirname, '.goal-flag-test-'))
  t.after(() => {
    assert.equal(dirname(directory), import.meta.dirname)
    assert.ok(basename(directory).startsWith('.goal-flag-test-'))
    rmSync(directory, { recursive: true, force: true })
  })
  for (const flag of ['', 'true', 'false', '2', ' 1', '01']) {
    const dbPath = join(directory, 'must-not-exist.sqlite')
    const result = spawnSync(process.execPath, ['src/main.ts'], {
      cwd: join(import.meta.dirname, '..'),
      encoding: 'utf8', timeout: 5_000,
      env: {
        ...process.env,
        'V2_ADMIN_SECRET': 'test-only-startup-secret',
        POS_GOAL_QUESTIONS_ENABLED: flag, DB_PATH: dbPath, PORT: '0',
      },
    })
    assert.ifError(result.error)
    assert.equal(result.signal, null)
    assert.equal(result.status, 1, `invalid flag ${JSON.stringify(flag)} must fail`)
    assert.match(result.stderr, /POS_GOAL_QUESTIONS_ENABLED must be 0 or 1/)
    assert.ok(!result.stdout.includes('listening on port'))
    assert.equal(existsSync(dbPath), false)
  }
})

test('goal/task writes are durable within store, idempotent, revision fenced, and summarized deterministically', t => {
  const { store, device, advance } = storeFixture(t)
  const create = {
    deviceId: device.id, commandId: 'goal-create-1', title: 'Ship feature',
    description: 'desc', successCriteria: 'works', targetDate: '2026-02-03',
  }
  const goalResult = store.createGoal(create)
  assert.equal(goalResult.created, true)
  assert.equal(goalResult.value.ownerId, 'default')
  assert.equal(goalResult.value.revision, 1)
  assert.deepEqual(store.createGoal(create), { ...goalResult, created: false })
  assert.throws(() => store.createGoal({ ...create, title: 'Changed' }), { code: 'command_id_conflict' })

  const goalId = goalResult.value.id
  const taskResult = store.createTask(goalId, {
    deviceId: device.id, commandId: 'task-create-1', title: 'Implement', dueDate: '2026-02-04',
  })!
  assert.equal(taskResult.created, true)
  assert.deepEqual(store.createTask(goalId, {
    deviceId: device.id, commandId: 'task-create-1', title: 'Implement', dueDate: '2026-02-04',
  }), { ...taskResult, created: false })
  assert.equal(store.getTask(taskResult.value.id)?.progressEntries.length, 1)

  assert.throws(() => store.updateTask(taskResult.value.id, {
    deviceId: device.id, commandId: 'task-block-no-reason', expectedRevision: 1,
    action: 'set_status', status: 'blocked',
  }), { code: 'blocked_reason_required' })
  advance(1000)
  const blocked = store.updateTask(taskResult.value.id, {
    deviceId: device.id, commandId: 'task-block-1', expectedRevision: 1,
    action: 'set_status', status: 'blocked', note: 'Waiting on review',
  })!
  assert.equal(blocked.value.status, 'blocked')
  assert.equal(blocked.value.revision, 2)
  assert.throws(() => store.updateTask(taskResult.value.id, {
    deviceId: device.id, commandId: 'task-block-stale', expectedRevision: 1,
    action: 'progress', note: 'stale write',
  }), { code: 'revision_conflict' })

  const detail = store.getGoalView(goalId)!
  assert.equal(detail.summary.completedTasks, 0)
  assert.equal(detail.summary.activeTasks, 1)
  assert.equal(detail.summary.blockedTasks, 1)
  assert.equal(detail.summary.completionPercent, 0)
  assert.equal(detail.tasks[0].blockedReason, 'Waiting on review')
  assert.equal(detail.viewRevision, 3)
  assert.equal(detail.tasks[0].revision, 2)
  assert.equal(store.getTask(taskResult.value.id)?.progressEntries[1].actorDeviceId, device.id)

  assert.throws(() => store.updateGoal(goalId, {
    deviceId: device.id, commandId: 'goal-complete-blocked', expectedRevision: 1, action: 'complete',
  }), { code: 'goal_has_open_tasks' })
  const canceled = store.updateTask(taskResult.value.id, {
    deviceId: device.id, commandId: 'task-cancel', expectedRevision: 2,
    action: 'set_status', status: 'canceled', note: 'resolved externally',
  })!
  assert.equal(canceled.value.status, 'canceled')
  const emptySummary = store.getGoalView(goalId)!.summary
  assert.equal(emptySummary.activeTasks, 0)
  assert.equal(emptySummary.canceledTasks, 1)
  assert.equal(emptySummary.completionPercent, null)
  const completedGoal = store.updateGoal(goalId, {
    deviceId: device.id, commandId: 'goal-complete', expectedRevision: 1, action: 'complete',
  })!
  assert.equal(completedGoal.value.status, 'completed')
  assert.throws(() => store.updateGoal(goalId, {
    deviceId: device.id, commandId: 'goal-edit-done', expectedRevision: 2,
    action: 'update', title: 'edited',
  }), { code: 'goal_read_only' })
  const reopened = store.updateGoal(goalId, {
    deviceId: device.id, commandId: 'goal-reopen', expectedRevision: 2, action: 'reopen',
  })!
  assert.equal(reopened.value.status, 'active')
})

test('set_status persists supplied non-blocked notes separately from result notes', t => {
  const { store, device, advance } = storeFixture(t)
  const goal = store.createGoal({ deviceId: device.id, commandId: 'note-goal', title: 'Notes' })
  const task = store.createTask(goal.value.id, {
    deviceId: device.id, commandId: 'note-task', title: 'Complete work',
  })!
  advance(1)
  const updated = store.updateTask(task.value.id, {
    deviceId: device.id, commandId: 'note-complete', expectedRevision: 1,
    action: 'set_status', status: 'completed', note: 'Status update detail',
    resultNote: 'Delivered output',
  })!
  assert.equal(updated.value.resultNote, 'Delivered output')
  const statusNotes = store.getTask(task.value.id)?.progressEntries.slice(1)
    .map(entry => [entry.kind, entry.note])
    .sort(([first], [second]) => String(first).localeCompare(String(second)))
  assert.deepEqual(statusNotes, [
    ['result', 'Delivered output'],
    ['status', 'Status update detail'],
  ])
})

test('blocked status history preserves trimmed reason in the fixed snapshot', t => {
  const { store, device, advance } = storeFixture(t)
  const goal = store.createGoal({ deviceId: device.id, commandId: 'trim-goal', title: 'Blocked notes' })
  const task = store.createTask(goal.value.id, {
    deviceId: device.id, commandId: 'trim-task', title: 'Dependency work',
  })!
  advance(1)
  const blocked = store.updateTask(task.value.id, {
    deviceId: device.id, commandId: 'trim-block', expectedRevision: 1,
    action: 'set_status', status: 'blocked', note: `${' '.repeat(500)}Dependency \n`,
  })!
  assert.equal(blocked.value.blockedReason, 'Dependency')
  const history = store.getTask(task.value.id)!.progressEntries
  assert.equal(history.at(-1)!.note, 'Dependency')
  const conversation = store.createConversation({})
  const question = store.appendUserMessage({
    conversationId: conversation.id, role: 'user', clientRequestId: 'trim-question',
    text: 'What is blocked?', goalId: goal.value.id,
  })
  const snapshot = store.goalContextForRun(question.run.id)!
  assert.equal(snapshot.includedTasks[0].progressEntries.at(-1)!.note, 'Dependency')
  assert.deepEqual(snapshot.omissions.truncatedFields, [])
  assert.ok(!snapshot.omissions.reasons.includes('text_truncated'))
})

test('goal context size omissions describe only final included task truncations', t => {
  const { store, device } = storeFixture(t)
  const goal = store.createGoal({ deviceId: device.id, commandId: 'size-goal', title: 'Context bounds' })
  const safeText = (length: number, char: string) => char.repeat(length)
  const baselineTasks: string[] = []
  for (let index = 0; index < 12; index++) {
    const created = store.createTask(goal.value.id, {
      deviceId: device.id, commandId: `size-base-${index}`, title: `base-${index}`,
    })!
    baselineTasks.push(created.value.id)
    store.updateTask(created.value.id, {
      deviceId: device.id, commandId: `size-base-update-${index}`, expectedRevision: 1,
      action: 'update', title: safeText(400, 't'), description: safeText(800, 'd'),
    })
  }
  const retained = store.createTask(goal.value.id, {
    deviceId: device.id, commandId: 'size-retained', title: 'Retained clipped task',
  })!
  store.updateTask(retained.value.id, {
    deviceId: device.id, commandId: 'size-retained-block', expectedRevision: 1,
    action: 'set_status', status: 'blocked', note: 'Waiting',
  })
  store.updateTask(retained.value.id, {
    deviceId: device.id, commandId: 'size-retained-clip', expectedRevision: 2,
    action: 'update', title: safeText(450, 'r'), description: safeText(900, 's'),
  })
  const removed = store.createTask(goal.value.id, {
    deviceId: device.id, commandId: 'size-removed', title: 'Removed clipped task',
  })!
  store.updateTask(removed.value.id, {
    deviceId: device.id, commandId: 'size-removed-clip', expectedRevision: 1,
    action: 'update', title: safeText(900, 'x'), description: safeText(1_200, 'y'),
  })
  store.updateTask(removed.value.id, {
    deviceId: device.id, commandId: 'size-removed-cancel', expectedRevision: 2,
    action: 'set_status', status: 'canceled', note: 'No longer needed',
  })

  const conversation = store.createConversation({})
  const question = store.appendUserMessage({
    conversationId: conversation.id, role: 'user', clientRequestId: 'size-question',
    text: 'Summarize this goal', goalId: goal.value.id,
  })
  const context = store.goalContextForRun(question.run.id)!
  const includedIds = new Set(context.includedTasks.map(item => item.task.id))
  const truncations = context.omissions.truncatedFields
  assert.ok(JSON.stringify(context).length <= 16_000)
  assert.ok(context.includedTasks.length < baselineTasks.length + 2)
  assert.ok(includedIds.has(retained.value.id))
  assert.ok(!includedIds.has(removed.value.id))
  assert.ok(truncations.some(field => field.startsWith(`tasks.${retained.value.id}.`)))
  assert.ok(truncations.every(field => field.startsWith('goal.') || [...includedIds].some(id => field.startsWith(`tasks.${id}.`))))
  assert.ok(!truncations.some(field => field.startsWith(`tasks.${removed.value.id}.`)))
  assert.ok(context.omissions.reasons.includes('context_size'))
  assert.ok(context.omissions.reasons.includes('text_truncated'))
  const allTaskIds = new Set([...baselineTasks, retained.value.id, removed.value.id])
  assert.equal(context.omissions.taskCount, allTaskIds.size - context.includedTasks.length)
  const omittedProgress = [...allTaskIds].reduce((sum, id) => {
    const total = store.getTask(id)!.progressEntries.length
    const included = context.includedTasks.find(item => item.task.id === id)?.progressEntries.length ?? 0
    return sum + total - included
  }, 0)
  assert.equal(context.omissions.progressEntryCount, omittedProgress)
})

test('goal context reports no text truncation when only clipped tasks are size-omitted', t => {
  const { store, device } = storeFixture(t)
  const goal = store.createGoal({ deviceId: device.id, commandId: 'clean-size-goal', title: 'Clean context bounds' })
  for (let index = 0; index < 12; index++) {
    const created = store.createTask(goal.value.id, {
      deviceId: device.id, commandId: `clean-size-base-${index}`, title: `base-${index}`,
    })!
    store.updateTask(created.value.id, {
      deviceId: device.id, commandId: `clean-size-base-update-${index}`, expectedRevision: 1,
      action: 'update', title: 't'.repeat(400), description: 'd'.repeat(800),
    })
  }
  const clipped = store.createTask(goal.value.id, {
    deviceId: device.id, commandId: 'clean-size-clipped', title: 'Clipped last task',
  })!
  store.updateTask(clipped.value.id, {
    deviceId: device.id, commandId: 'clean-size-clip', expectedRevision: 1,
    action: 'update', title: 'x'.repeat(900), description: 'y'.repeat(1_200),
  })
  store.updateTask(clipped.value.id, {
    deviceId: device.id, commandId: 'clean-size-cancel', expectedRevision: 2,
    action: 'set_status', status: 'canceled', note: 'No longer needed',
  })
  const conversation = store.createConversation({})
  const question = store.appendUserMessage({
    conversationId: conversation.id, role: 'user', clientRequestId: 'clean-size-question',
    text: 'Summarize this goal', goalId: goal.value.id,
  })
  const context = store.goalContextForRun(question.run.id)!
  assert.ok(JSON.stringify(context).length <= 16_000)
  assert.ok(!context.includedTasks.some(item => item.task.id === clipped.value.id))
  assert.deepEqual(context.omissions.truncatedFields, [])
  assert.ok(context.omissions.reasons.includes('context_size'))
  assert.ok(!context.omissions.reasons.includes('text_truncated'))
})

test('goal context keeps the 30-task and three-entry progress limits', t => {
  const { store, device } = storeFixture(t)
  const goal = store.createGoal({ deviceId: device.id, commandId: 'limits-goal', title: 'Context limits' })
  let firstTaskId = ''
  for (let index = 0; index < 31; index++) {
    const created = store.createTask(goal.value.id, {
      deviceId: device.id, commandId: `limits-task-${index}`, title: `task-${index}`,
    })!
    if (index === 0) firstTaskId = created.value.id
  }
  for (let index = 0; index < 3; index++) {
    store.updateTask(firstTaskId, {
      deviceId: device.id, commandId: `limits-progress-${index}`, expectedRevision: index + 1,
      action: 'progress', note: `progress-${index}`,
    })
  }
  const conversation = store.createConversation({})
  const question = store.appendUserMessage({
    conversationId: conversation.id, role: 'user', clientRequestId: 'limits-question',
    text: 'Summarize this goal', goalId: goal.value.id,
  })
  const context = store.goalContextForRun(question.run.id)!
  assert.ok(context.includedTasks.length <= 30)
  assert.equal(context.omissions.taskCount, 31 - context.includedTasks.length)
  assert.ok(context.omissions.reasons.includes('task_limit'))
  assert.ok(context.omissions.reasons.includes('progress_limit'))
  assert.equal(context.omissions.progressEntryCount,
    34 - context.includedTasks.reduce((sum, item) => sum + item.progressEntries.length, 0))
})

test('goal/task HTTP routes expose stable envelopes, enforce client writes and replay command receipts', async t => {
  const store = new CloudStore(':memory:')
  const server = createV2Server({ store, adminSecret: 'test-admin', goalQuestionsEnabled: true })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const address = server.address()
  assert.ok(address && typeof address === 'object')
  const base = `http://127.0.0.1:${address.port}`
  t.after(async () => {
    const closed = new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()))
    server.closeAllConnections()
    await closed
    store.close()
  })
  const call = async (path: string, token?: string, body?: unknown, method?: string) => {
    const response = await fetch(`${base}${path}`, {
      method: method ?? (body === undefined ? 'GET' : 'POST'),
      headers: {
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        ...(body === undefined ? {} : { 'content-type': 'application/json' }),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    return { status: response.status, json: await response.json() as Record<string, any> }
  }
  const pair = async (role: 'client' | 'agent') => {
    const result = await call('/v2/pair', undefined, { name: role, role }, 'POST')
    assert.equal(result.status, 401)
    const response = await fetch(`${base}/v2/pair`, {
      method: 'POST', headers: { 'content-type': 'application/json', 'x-pair-secret': 'test-admin' },
      body: JSON.stringify({ name: role, role }),
    })
    assert.equal(response.status, 201)
    return (await response.json() as { token: string }).token
  }
  const client = await pair('client')
  const agent = await pair('agent')
  assert.deepEqual((await call('/v2/capabilities', client)).json, { goalsTasksVersion: 1, goalQuestionsVersion: 1 })
  const denied = await call('/v2/goals', agent, { commandId: 'agent-cmd', title: 'denied' })
  assert.equal(denied.status, 403)

  const created = await call('/v2/goals', client, {
    commandId: 'http-goal-create', title: 'Goal', targetDate: '2026-03-04',
  })
  assert.equal(created.status, 201)
  assert.equal(created.json.created, true)
  assert.deepEqual(Object.keys(created.json), ['goal', 'created'])
  const unfilteredGoals = await call('/v2/goals', client, undefined, 'GET')
  assert.equal(unfilteredGoals.status, 200)
  assert.equal(unfilteredGoals.json.goals.length, 1)
  assert.equal(unfilteredGoals.json.goals[0].id, created.json.goal.id)
  const replay = await call('/v2/goals', client, {
    commandId: 'http-goal-create', title: 'Goal', targetDate: '2026-03-04',
  })
  assert.equal(replay.status, 200)
  assert.equal(replay.json.created, false)
  const goalId = created.json.goal.id as string
  const task = await call(`/v2/goals/${goalId}/tasks`, client, {
    commandId: 'http-task-create', title: 'First task',
  })
  assert.equal(task.status, 201)
  assert.deepEqual(Object.keys(task.json), ['task', 'created'])
  const view = await call(`/v2/goals/${goalId}`, client)
  assert.deepEqual(Object.keys(view.json), ['goalView'])
  assert.equal(view.json.goalView.tasks.length, 1)
  const taskId = task.json.task.id as string
  const taskDetail = await call(`/v2/tasks/${taskId}`, client)
  assert.deepEqual(Object.keys(taskDetail.json), ['task', 'progressEntries', 'nextCursor', 'progressRevision'])
  assert.equal(taskDetail.json.progressEntries.length, 1)
  const firstProgress = await call(`/v2/tasks/${taskId}?progressLimit=1`, client)
  assert.equal(firstProgress.json.nextCursor, null)
  const noteOne = await call(`/v2/tasks/${taskId}/commands`, client, {
    commandId: 'http-progress-one', expectedRevision: 1, action: 'progress', note: 'first update',
  })
  assert.equal(noteOne.status, 200)
  const noteTwo = await call(`/v2/tasks/${taskId}/commands`, client, {
    commandId: 'http-progress-two', expectedRevision: 2, action: 'progress', note: 'second update',
  })
  assert.equal(noteTwo.status, 200)
  const progressPageOne = await call(`/v2/tasks/${taskId}?progressLimit=1`, client)
  assert.equal(progressPageOne.json.nextCursor, 1)
  const progressPageTwo = await call(`/v2/tasks/${taskId}?progressAfter=1&progressLimit=1&progressRevision=${progressPageOne.json.progressRevision}`, client)
  assert.equal(progressPageTwo.status, 200)
  assert.equal(progressPageTwo.json.progressEntries[0].note, 'first update')
  assert.equal(progressPageTwo.json.nextCursor, 2)
  const changedTask = await call(`/v2/tasks/${taskId}/commands`, client, {
    commandId: 'http-progress-three', expectedRevision: 3, action: 'progress', note: 'version changes',
  })
  assert.equal(changedTask.status, 200)
  const progressConflict = await call(`/v2/tasks/${taskId}?progressAfter=2&progressLimit=1&progressRevision=${progressPageOne.json.progressRevision}`, client)
  assert.equal(progressConflict.status, 409)
  assert.equal(progressConflict.json.error.code, 'progress_revision_conflict')
  const stale = await call(`/v2/tasks/${taskId}/commands`, client, {
    commandId: 'http-status', expectedRevision: 99, action: 'progress', note: 'x',
  })
  assert.equal(stale.status, 409)
  assert.equal(stale.json.error.code, 'revision_conflict')
  const updated = await call(`/v2/goals/${goalId}/commands`, client, {
    commandId: 'http-goal-update', expectedRevision: 1, action: 'update', title: 'Renamed',
  })
  assert.equal(updated.status, 200)
  assert.equal(updated.json.goal.title, 'Renamed')
  const invalidDate = await call('/v2/goals', client, {
    commandId: 'http-invalid-date', title: 'Invalid date', targetDate: '2026-02-30',
  })
  assert.equal(invalidDate.status, 400)

  const conversation = await call('/v2/conversations', client, { title: 'goal context' })
  const conversationId = conversation.json.conversation.id as string
  const question = { conversationId, clientRequestId: 'goal-question-key', text: 'What remains?' }
  const asked = await call(`/v2/goals/${goalId}/questions`, client, question)
  assert.equal(asked.status, 201)
  const runId = asked.json.run.id as string
  assert.equal(asked.json.run.goalId, goalId)
  const questionReplay = await call(`/v2/goals/${goalId}/questions`, client, question)
  assert.equal(questionReplay.status, 200)
  assert.equal(questionReplay.json.run.id, runId)
  assert.equal(questionReplay.json.created, false)
  const crossEntry = await call(`/v2/conversations/${conversationId}/messages`, client, {
    clientRequestId: question.clientRequestId, text: question.text,
  })
  assert.equal(crossEntry.status, 409)
  assert.equal(crossEntry.json.error.code, 'goal_question_conflict')

  const contextBefore = await call(`/v2/runs/${runId}/goal-context`, client)
  assert.equal(contextBefore.status, 200)
  assert.equal(contextBefore.json.goalContext.goalId, goalId)
  assert.equal(contextBefore.json.goalContext.includedTasks.length, 1)
  assert.deepEqual(contextBefore.json.goalContext.omissions, {
    taskCount: 0, progressEntryCount: 1, truncatedFields: [], reasons: ['progress_limit'],
  })
  assert.equal(contextBefore.json.goalContext.summary.todoTasks, 1)
  assert.equal(contextBefore.json.goalContext.summary.activeTasks, 1)
  const mutateAfterSnapshot = await call(`/v2/tasks/${taskId}/commands`, client, {
    commandId: 'http-after-snapshot', expectedRevision: 4, action: 'progress', note: 'after the snapshot',
  })
  assert.equal(mutateAfterSnapshot.status, 200)
  const contextAfter = await call(`/v2/runs/${runId}/goal-context`, client)
  assert.deepEqual(contextAfter.json.goalContext, contextBefore.json.goalContext)

  const legacyLease = await call('/v2/runs/lease', agent, {})
  assert.deepEqual(legacyLease.json, { run: null, leaseToken: null })
  const capableLease = await call('/v2/runs/lease', agent, { goalQuestionsVersion: 1 })
  assert.equal(capableLease.json.run.id, runId)
  assert.equal(capableLease.json.run.goalId, goalId)

  const changedTextReplay = await call(`/v2/goals/${goalId}/questions`, client, {
    ...question, text: 'A different question',
  })
  assert.equal(changedTextReplay.status, 409)
  assert.equal(changedTextReplay.json.error.code, 'goal_question_conflict')
  const invalidSnapshot = await call(`/v2/runs/${runId}/goal-context`, client)
  assert.equal(invalidSnapshot.json.goalContext.asOf, contextBefore.json.goalContext.asOf)
})
