import { createServer } from 'node:http'
import type { IncomingMessage, Server, ServerResponse } from 'node:http'
import {
  authenticateDevice,
  createDeviceToken,
  hashToken,
  matchesPairSecret,
  publicDevice,
} from './auth.ts'
import type { CloudStoreApi, StoreClock } from './store-api.ts'
import type { MessageRecord } from './types.ts'

const MAX_BODY_BYTES = 1024 * 1024
const POLL_INTERVAL_MS = 250

export interface V2ServerOptions {
  store: CloudStoreApi
  adminSecret: string
  /** Public configured worker model; never pass endpoint URLs or credentials. */
  model?: string
  now?: StoreClock
}

class HttpError extends Error {
  status: number
  code: string

  constructor(status: number, code: string, message: string) {
    super(message)
    this.status = status
    this.code = code
  }
}

function badRequest(message: string): never {
  throw new HttpError(400, 'invalid_request', message)
}

function sendJson(response: ServerResponse, status: number, value: unknown): void {
  if (response.destroyed || response.writableEnded) return
  const body = JSON.stringify(value)
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
  })
  response.end(body)
}

async function readBody(
  request: IncomingMessage,
  allowEmpty = false,
): Promise<Record<string, unknown>> {
  const contentType = request.headers['content-type']
  if (contentType && contentType.split(';', 1)[0].trim().toLowerCase() !== 'application/json') {
    request.resume()
    badRequest('Content-Type must be application/json.')
  }
  const bytes = await new Promise<Buffer>((resolve, reject) => {
    const chunks: Buffer[] = []
    let size = 0
    const cleanup = () => {
      request.off('data', onData)
      request.off('end', onEnd)
      request.off('aborted', onAborted)
      request.off('error', onError)
    }
    const onData = (chunk: Buffer) => {
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        cleanup()
        request.resume()
        reject(new HttpError(413, 'payload_too_large', 'JSON body must not exceed 1 MB.'))
        return
      }
      chunks.push(chunk)
    }
    const onEnd = () => {
      cleanup()
      resolve(Buffer.concat(chunks, size))
    }
    const onAborted = () => {
      cleanup()
      reject(new HttpError(400, 'invalid_request', 'Request body was interrupted.'))
    }
    const onError = (error: Error) => {
      cleanup()
      reject(error)
    }
    request.on('data', onData)
    request.once('end', onEnd)
    request.once('aborted', onAborted)
    request.once('error', onError)
  })
  if (bytes.length === 0 && allowEmpty) return {}
  let value: unknown
  try {
    value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes))
  } catch {
    throw new HttpError(400, 'invalid_json', 'Request body must contain valid JSON.')
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    badRequest('JSON body must be an object.')
  }
  return value as Record<string, unknown>
}

function fields(body: Record<string, unknown>, allowed: string[]): void {
  if (Object.keys(body).some((key) => !allowed.includes(key))) {
    badRequest('Request body contains an unknown field.')
  }
}

function requiredString(value: unknown, name: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    badRequest(`${name} must be a non-empty string.`)
  }
  return value
}

function optionalText(value: unknown, name: string): string | null | undefined {
  if (value !== undefined && value !== null && typeof value !== 'string') {
    badRequest(`${name} must be a string or null.`)
  }
  return value as string | null | undefined
}

function queryFields(url: URL, allowed: string[] = []): void {
  for (const key of url.searchParams.keys()) {
    if (!allowed.includes(key) || url.searchParams.getAll(key).length !== 1) {
      badRequest('Query contains an unknown or repeated parameter.')
    }
  }
}

function messageQuery(url: URL): { after: number; wait: number } {
  queryFields(url, ['after', 'wait'])
  const afterValue = url.searchParams.get('after') ?? '0'
  const waitValue = url.searchParams.get('wait') ?? '0'
  const after = Number(afterValue)
  const wait = Number(waitValue)
  if (!/^(0|[1-9]\d*)$/.test(afterValue) || !Number.isSafeInteger(after)) {
    badRequest('after must be a non-negative safe integer.')
  }
  if (!/^(0|[1-9]\d*)(\.\d+)?$/.test(waitValue) || !Number.isFinite(wait) || wait > 25) {
    badRequest('wait must be between 0 and 25 seconds.')
  }
  return { after, wait }
}

function resourceId(value: string): string {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) badRequest('Resource id is invalid.')
  return value
}

function pauseUntilPoll(
  request: IncomingMessage,
  response: ServerResponse,
  milliseconds: number,
): Promise<boolean> {
  return new Promise((resolve) => {
    if (request.aborted || response.destroyed) {
      resolve(false)
      return
    }
    const finish = (connected: boolean) => {
      clearTimeout(timer)
      request.off('aborted', onClose)
      response.off('close', onClose)
      resolve(connected)
    }
    const onClose = () => finish(false)
    const timer = setTimeout(() => finish(true), milliseconds)
    request.once('aborted', onClose)
    response.once('close', onClose)
  })
}

async function pollMessages(
  request: IncomingMessage,
  response: ServerResponse,
  store: CloudStoreApi,
  conversationId: string,
  after: number,
  wait: number,
): Promise<MessageRecord[] | null> {
  const deadline = performance.now() + wait * 1000
  for (;;) {
    if (request.aborted || response.destroyed) return null
    const messages = store.listMessages(conversationId, after)
    if (messages.length > 0) return messages
    const remaining = deadline - performance.now()
    if (remaining <= 0) return []
    if (!(await pauseUntilPoll(request, response, Math.min(POLL_INTERVAL_MS, remaining)))) return null
  }
}

export function createV2Server({ store, adminSecret, model, now = () => new Date() }: V2ServerOptions): Server {
  if (typeof adminSecret !== 'string' || adminSecret.length === 0) {
    throw new TypeError('adminSecret must be a non-empty string.')
  }
  const modelName = model?.trim()
  if (modelName !== undefined && !/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$/.test(modelName)) {
    throw new TypeError('model must be a model identifier of at most 200 characters.')
  }

  async function handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    let url: URL
    try {
      url = new URL(request.url ?? '/', 'http://localhost')
    } catch {
      badRequest('Request URL is invalid.')
    }
    let path: string
    try {
      path = url.pathname.split('/').map((part) => {
        const decoded = decodeURIComponent(part)
        if (decoded.includes('/') || decoded.includes('\\')) badRequest('Path segment is invalid.')
        return decoded
      }).join('/')
    } catch (error) {
      if (error instanceof HttpError) throw error
      badRequest('Path contains invalid encoding.')
    }
    const method = request.method

    if (method === 'GET' && path === '/v2/health') {
      queryFields(url)
      sendJson(response, 200, {
        ok: true, service: 'personal-os-cloud', protocolVersion: 2, dbPath: store.dbPath,
        ...(modelName === undefined ? {} : { model: modelName }),
      })
      return
    }
    if (method === 'POST' && path === '/v2/pair') {
      const secret = request.headers['x-pair-secret']
      if (!matchesPairSecret(typeof secret === 'string' ? secret : undefined, adminSecret)) {
        throw new HttpError(401, 'unauthorized', 'A valid pairing secret is required.')
      }
      queryFields(url)
      const body = await readBody(request)
      fields(body, ['name', 'role'])
      const name = requiredString(body.name, 'name')
      if (body.role !== 'client' && body.role !== 'agent') {
        badRequest('role must be client or agent.')
      }
      const token = createDeviceToken()
      const device = store.pairDevice({ name, role: body.role, tokenHash: hashToken(token) })
      sendJson(response, 201, { device: publicDevice(device), token })
      return
    }

    const authorization = request.headers.authorization
    const device = authenticateDevice(store, authorization, now())
    if (!device) throw new HttpError(401, 'unauthorized', 'A valid device bearer token is required.')

    if (method === 'GET' && path === '/v2/me') {
      queryFields(url)
      sendJson(response, 200, { device: publicDevice(device) })
      return
    }
    if (path === '/v2/conversations' && (method === 'GET' || method === 'POST')) {
      queryFields(url)
      if (method === 'GET') {
        sendJson(response, 200, { conversations: store.listConversations() })
      } else {
        const body = await readBody(request)
        fields(body, ['title'])
        const title = optionalText(body.title, 'title')
        sendJson(response, 201, { conversation: store.createConversation({ title }) })
      }
      return
    }
    const messagesMatch = path.match(/^\/v2\/conversations\/([^/]*)\/messages$/)
    if (messagesMatch && (method === 'GET' || method === 'POST')) {
      const conversationId = resourceId(messagesMatch[1])
      const cursor = method === 'GET' ? messageQuery(url) : (queryFields(url), null)
      if (!store.getConversation(conversationId)) {
        throw new HttpError(404, 'not_found', 'Conversation not found.')
      }
      if (method === 'GET' && cursor) {
        const messages = await pollMessages(request, response, store, conversationId, cursor.after, cursor.wait)
        if (messages === null) return
        const nextCursor = messages.length > 0 ? messages[messages.length - 1].seq : cursor.after
        sendJson(response, 200, { messages, nextCursor })
      } else {
        const body = await readBody(request)
        fields(body, ['clientRequestId', 'text'])
        const clientRequestId = requiredString(body.clientRequestId, 'clientRequestId')
        const text = requiredString(body.text, 'text')
        const result = store.appendUserMessage({ conversationId, role: 'user', clientRequestId, text })
        sendJson(response, result.created ? 201 : 200, result)
      }
      return
    }
    if (method === 'POST' && path === '/v2/runs/lease') {
      queryFields(url)
      if (device.role !== 'agent') throw new HttpError(403, 'forbidden', 'An agent device is required.')
      const body = await readBody(request, true)
      fields(body, ['leaseMs'])
      const leaseMs = body.leaseMs === undefined ? 30_000 : body.leaseMs
      if (typeof leaseMs !== 'number' || !Number.isSafeInteger(leaseMs) || leaseMs <= 0 || leaseMs > 86_400_000) {
        badRequest('leaseMs must be an integer between 1 and 86400000 milliseconds.')
      }
      store.requeueExpiredLeases()
      const lease = store.leaseRun({ leaseMs })
      sendJson(response, 200, lease ?? { run: null, leaseToken: null })
      return
    }
    const runMatch = path.match(/^\/v2\/runs\/([^/]*)(?:\/(cancel|complete))?$/)
    if (runMatch && ((method === 'GET' && !runMatch[2]) ||
      (method === 'POST' && (runMatch[2] === 'cancel' || runMatch[2] === 'complete')))) {
      queryFields(url)
      const runId = resourceId(runMatch[1])
      const action = runMatch[2]
      if (action === 'complete' && device.role !== 'agent') {
        throw new HttpError(403, 'forbidden', 'An agent device is required.')
      }
      if (!store.getRun(runId)) throw new HttpError(404, 'not_found', 'Run not found.')
      if (!action) {
        sendJson(response, 200, { run: store.getRun(runId) })
      } else if (action === 'cancel') {
        const body = await readBody(request, true)
        fields(body, [])
        const run = store.cancelRun(runId)
        if (!run) throw new HttpError(404, 'not_found', 'Run not found.')
        sendJson(response, 200, { run })
      } else {
        const body = await readBody(request)
        fields(body, ['leaseToken', 'status', 'resultText', 'error'])
        const leaseToken = requiredString(body.leaseToken, 'leaseToken')
        if (body.status !== 'completed' && body.status !== 'failed') {
          badRequest('status must be completed or failed.')
        }
        const resultText = optionalText(body.resultText, 'resultText')
        const error = optionalText(body.error, 'error')
        const run = store.completeRun(runId, leaseToken, { status: body.status, resultText, error })
        if (!run) throw new HttpError(409, 'conflict', 'Run lease is invalid or the run is no longer running.')
        sendJson(response, 200, { run })
      }
      return
    }
    throw new HttpError(404, 'not_found', 'Route not found.')
  }

  return createServer((request, response) => {
    void handle(request, response).catch((error: unknown) => {
      const failure = error instanceof HttpError
        ? error
        : new HttpError(500, 'internal_error', 'Internal server error.')
      sendJson(response, failure.status, { error: { code: failure.code, message: failure.message } })
      if (!request.complete) request.resume()
    })
  })
}
