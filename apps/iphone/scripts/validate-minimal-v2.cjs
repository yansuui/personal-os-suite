// Windows/offline source validation. This does not compile or execute Swift.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const contract = fs.readFileSync(path.resolve(root, '../../packages/contracts/MINIMAL-V2-CONTRACT.md'), 'utf8');
const api = read('Sources/POSCore/URLSessionPOSAPI.swift');
const protocol = read('Sources/POSCore/POSAPI.swift');
const models = read('Sources/POSCore/Models.swift');
const sync = read('Sources/POSCore/SyncEngine.swift');
const app = read('Sources/POSFeatures/AppModel.swift');
const rootView = read('Sources/POSFeatures/RootView.swift');
const testsRoot = path.join(root, 'Tests/POSCoreTests');
const featureTestsRoot = path.join(root, 'Tests/POSFeaturesTests');
const swiftFiles = directory => fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
  const file = path.join(directory, entry.name);
  return entry.isDirectory() ? swiftFiles(file) : file.endsWith('.swift') ? [file] : [];
});
const sources = swiftFiles(path.join(root, 'Sources'));
const tests = [...swiftFiles(testsRoot), ...swiftFiles(featureTestsRoot)];
let checks = 0;
const check = (name, action) => {
  action();
  checks++;
  console.log(`PASS ${name}`);
};
const struct = name => {
  const start = models.indexOf(`public struct ${name}:`);
  assert.ok(start >= 0, `missing ${name}`);
  const next = models.indexOf('\npublic struct ', start + 1);
  return models.slice(start, next < 0 ? models.length : next);
};
const method = (source, name, next) => {
  const start = source.indexOf(`func ${name}(`);
  const end = next ? source.indexOf(`func ${next}(`, start + 1) : source.length;
  assert.ok(start >= 0 && end > start, `missing ${name}`);
  return source.slice(start, end);
};

check('HTTP routes match the frozen v2 client contract', () => {
  const routes = [...new Set([...api.matchAll(/"(v\d+\/[^"\n]+)"/g)].map(match => '/' + match[1].replace('\\(conversationID)', ':conversationId').replace('\\(runID)', ':runId')))];
  // cancelRun composes the frozen path from the shared, validated runsPath helper.
  if (api.includes('path: runsPath(runID) + "/cancel"')) routes.push('/v2/runs/:runId/cancel');
  assert.deepEqual(routes.sort(), ['/v2/health', '/v2/pair', '/v2/me', '/v2/conversations', '/v2/conversations/:conversationId/messages', '/v2/runs/:runId', '/v2/runs/:runId/cancel'].sort());
  for (const route of routes) assert.ok(contract.includes(route), `route missing from contract: ${route}`);
  for (const file of sources) assert.ok(!/\bv1\//.test(fs.readFileSync(file, 'utf8')), `${file} still references v1`);
});
check('POSAPI only exposes supported client operations', () => {
  assert.deepEqual([...protocol.matchAll(/func (\w+)\(/g)].map(m => m[1]).sort(),
    ['health', 'pair', 'me', 'createConversation', 'conversations', 'messages', 'sendMessage', 'run', 'cancelRun'].sort());
  assert.ok(!/api\.(tasks|approve|submitVerdict|context|presence|timeline)\(/.test(app + sync));
});
check('pair wire shape and credentials are isolated', () => {
  const pair = struct('PairRequest');
  assert.deepEqual([...pair.matchAll(/public let (\w+):/g)].map(m => m[1]), ['name', 'role']);
  const pairAPI = method(api, 'pair', 'me');
  assert.ok(pairAPI.includes('"x-pair-secret": secret'));
  assert.ok(!pairAPI.includes('authorizedRequest('));
  assert.ok(!method(api, 'health', 'pair').includes('authorizedRequest('));
  assert.ok(api.includes('"authorization": "Bearer \\(session.token)"'));
});
check('message wire models retain conversation, request key, run and created', () => {
  for (const key of ['conversationID = "conversationId"', 'clientRequestID = "clientRequestId"']) assert.ok(struct('ChatMessage').includes(key));
  assert.ok(struct('MessagePage').includes('let nextCursor: Int\n'));
  assert.ok(struct('MessagePage').includes('let messages: [ChatMessage]'));
  const request = struct('SendMessageRequest');
  assert.deepEqual([...request.matchAll(/public let (\w+):/g)].map(m => m[1]), ['clientRequestID', 'text']);
  const ack = struct('SendMessageAck');
  for (const key of ['message: ChatMessage', 'run: Run', 'created: Bool']) assert.ok(ack.includes(key));
  assert.ok(api.includes('JSONEncoder()') && api.includes('.sortedKeys'));
});
check('long polling clamps wait and keeps required HTTP timeout margin', () => {
  assert.ok(api.includes('let regularTimeout: TimeInterval = 15'));
  assert.ok(api.includes('min(25, max(0, waitSeconds))'));
  assert.ok(api.includes('TimeInterval(max(30, wait + 10))'));
  for (const query of ['after', 'wait']) assert.ok(api.includes(`URLQueryItem(name: "${query}"`));
  assert.ok(api.includes('page.nextCursor == (page.messages.last?.seq ?? after)'));
  assert.ok(api.includes('$0.conversationID == conversationID && $0.seq > after'));
});
check('polling cursor is scoped to the requested conversation', () => {
  assert.ok(sync.includes('$0.conversationID == conversationID'));
  assert.ok(!sync.includes('snapshot.cursor'));
  assert.ok(sync.includes('if !page.messages.isEmpty'));
  assert.ok(sync.indexOf('yield(.messages(page.messages))') < sync.indexOf('yield(.cursor(cursor))'));
  assert.ok(!sync.includes('bufferingNewest'));
  assert.ok(sync.includes('loopTask?.cancel()') && sync.includes('min(backoffSeconds * 2, 30)'));
});
check('pending request key persists before network send and survives retry', () => {
  assert.ok(struct('PendingMessage').includes('Codable'));
  assert.ok(struct('PendingMessage').includes('SendMessageRequest(clientRequestID: clientRequestID, text: text)'));
  const send = method(app, 'send', 'retryPending');
  assert.ok(send.indexOf('guard persistSnapshot()') < send.lastIndexOf('await sendPending(pending)'));
  const pending = method(app, 'sendPending', 'approve');
  assert.ok(pending.includes('pending.request'));
  assert.ok(!pending.includes('UUID()'));
  assert.ok(!pending.includes('updateCursor('), 'send acknowledgement must not skip unread messages');
  assert.ok(pending.includes('if case .conflict = failure { await refresh() }'));
  assert.ok(struct('CachedSnapshot').includes('decodeIfPresent([PendingMessage].self'));
});
check('snapshot compatibility and credential storage remain in place', () => {
  const cache = struct('CachedSnapshot');
  for (const field of ['timeline', 'cursor', 'tasks', 'context', 'conversations', 'conversationStates', 'pendingMessages']) assert.ok(cache.includes(`case ${field}`) || cache.includes(field));
  assert.ok(app.includes('timeline: restoredSnapshot?.timeline ?? []'));
  assert.ok(app.includes('POSCoreBridge.stableDigest(identity)'));
  assert.ok(read('Sources/POSCore/SnapshotStore.swift').includes('options: [.atomic]'));
  const credentials = read('Sources/POSCore/CredentialStore.swift');
  assert.ok(credentials.includes('com.personalos.ios.session'));
  assert.ok(credentials.includes('kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly'));
  assert.ok(!cache.includes('let token:') && !cache.includes('let secret:'));
  const bootstrap = method(app, 'bootstrap', 'pair');
  assert.ok(bootstrap.indexOf('hydrateFromSnapshot()') < bootstrap.indexOf('await refresh()'));
});
check('hidden unsupported UI cannot reach legacy APIs', () => {
  assert.ok(!/(TodayView|TasksView|MemoryView)\(/.test(rootView));
  assert.ok(rootView.includes('AssistantView(') && rootView.includes('MeView('));
  assert.ok(read('Sources/POSFeatures/Views/MeView.swift').includes('尚未接入'));
  for (const name of ['approve', 'reject', 'accept', 'requestRework']) {
    const declaration = app.split('\n').find(line => line.includes(`func ${name}(`));
    assert.ok(declaration && declaration.includes('未接入 v2') && !declaration.includes('api.'));
  }
});
check('stale identity and sync responses have generation guards', () => {
  assert.ok(app.includes('identityGeneration += 1'));
  assert.ok(app.includes('guard generation == identityGeneration else { return }'));
  assert.ok(app.includes('self.syncGeneration == generation'));
  assert.ok(app.includes('self.selectedConversationID == id'));
});
check('new sends and pending confirmation have focused AppModel regressions', () => {
  const send = method(app, 'send', 'retryPending');
  assert.ok(send.includes('let pending = PendingMessage(conversationID: id, text: text'));
  assert.ok(!send.includes('pendingMessages.first'), 'a new send must not reuse a pending key by text');
  const apply = method(app, 'apply', 'updateCursor');
  assert.ok(apply.includes('message.conversationID == id, message.role == "user"'));
  assert.ok(apply.includes('$0.conversationID == id && confirmedRequestIDs.contains($0.clientRequestID)'));
  const featureTests = swiftFiles(featureTestsRoot).map(file => fs.readFileSync(file, 'utf8')).join('\n');
  assert.ok(featureTests.includes('import POSFeatures'));
  for (const name of ['testNewSendUsesNewKeyForSameTextAfterUnconfirmedSend',
    'testRestoredPendingKeepsKeyAndBodyForAutomaticAndExplicitRetry',
    'testPolledUserMessageConfirmsOnlyMatchingConversationAndRequestKey']) {
    assert.ok(featureTests.includes(`func ${name}(`), `missing ${name}`);
  }
  const project = read('project.yml');
  const featureTarget = project.slice(project.indexOf('\n  POSFeaturesTests:'), project.indexOf('\nschemes:'));
  assert.ok(featureTarget.includes('path: Tests/POSFeaturesTests'));
  assert.ok(featureTarget.includes('- target: POSCore') && featureTarget.includes('- target: POSFeatures'));
  assert.ok(project.includes('POSFeaturesTests: [test]') && project.includes('- name: POSFeaturesTests'));
});
check('focused XCTest sources cover contract and persistence regressions', () => {
  const testText = tests.map(file => fs.readFileSync(file, 'utf8')).join('\n');
  for (const name of ['testPairUsesOnlyNameRoleAndPairSecret', 'testCreateAndListConversationsUseFrozenEnvelopes',
    'testNewAndReplayShareMessageRunAndIdempotencyKey', 'testMessagesDecodeUserAndAssistantWithSharedSequence',
    'testInitialCursorUsesOnlyRequestedConversation', 'testLongPollClampsWaitAndKeepsTimeoutMargin',
    'testV2SnapshotRestoresConversationCursorAndPendingIdempotencyKey', 'testLegacySnapshotRemainsReadableWithoutInventingV2Conversation',
    'testConflictMapsToConflictAndIsNotRetried']) assert.ok(testText.includes(`func ${name}(`), `missing ${name}`);
  assert.ok(!/\b(api\.(tasks|context|presence|timeline)\(|TimelinePage|TaskList)/.test(testText));
  let jsonFixtures = 0;
  for (const raw of testText.matchAll(/#"(\{[^\n]*?\})"#/g)) { JSON.parse(raw[1]); jsonFixtures++; }
  assert.ok(jsonFixtures >= 5);
  console.log(`INFO ${tests.length} XCTest source files, ${[...testText.matchAll(/func test\w+\(/g)].length} test methods, ${jsonFixtures} literal JSON fixtures parsed`);
});
console.log(`PASS ${checks} static validation groups; ${sources.length} Swift source files checked`);
console.log('NOT VERIFIED: Swift compilation, XCTest execution, simulator/device runtime, cloud deployment or IPA installation.');
