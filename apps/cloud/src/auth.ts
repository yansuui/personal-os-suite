import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import type { CloudStoreApi } from './store-api.ts'
import type { DeviceRecord } from './types.ts'

export function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex')
}

export function createDeviceToken(): string {
  return randomBytes(32).toString('base64url')
}

export function matchesPairSecret(value: string | undefined, secret: string): boolean {
  if (value === undefined) return false
  return timingSafeEqual(
    createHash('sha256').update(value).digest(),
    createHash('sha256').update(secret).digest(),
  )
}

export function authenticateDevice(
  store: CloudStoreApi,
  authorization: string | undefined,
  at: Date,
): DeviceRecord | null {
  const match = authorization?.match(/^Bearer ([^\s]+)$/i)
  if (!match) return null
  const device = store.deviceByTokenHash(hashToken(match[1]))
  if (!device || device.revokedAt !== null) return null
  store.touchDevice(device.id, at)
  return { ...device, lastSeenAt: at.toISOString() }
}

export function publicDevice(device: DeviceRecord): Omit<DeviceRecord, 'tokenHash'> {
  const { tokenHash: _tokenHash, ...result } = device
  return result
}
