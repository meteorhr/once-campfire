const ALGORITHM = "double_ratchet_v1"
const STORAGE_NAMESPACE = "once:e2e:v2"
const IDENTITY_STORAGE_KEY = `${STORAGE_NAMESPACE}:identity`
const DEVICE_STORAGE_KEY = `${STORAGE_NAMESPACE}:device`
const MIN_ONE_TIME_PREKEYS = 20
const MAX_SKIPPED_KEYS = 500
const MAX_SKIP_AHEAD = 1000
const SESSION_ROTATE_AFTER_MESSAGES = 200
const SESSION_ROTATE_AFTER_MS = 3 * 24 * 60 * 60 * 1000
const SESSION_EVICT_AFTER_MS = 30 * 24 * 60 * 60 * 1000
const SIGNED_PREKEY_ROTATE_AFTER_MS = 7 * 24 * 60 * 60 * 1000
const ZERO_SALT = new Uint8Array(32)
const textEncoder = new TextEncoder()
const textDecoder = new TextDecoder()

let activeClient = null

export async function getRoomE2EClient({ enabled = false, roomId, peerUserId, deviceUrl, prekeyBundleUrl, selfPrekeyBundleUrl }) {
  if (!enabled || !roomId || !peerUserId || !deviceUrl || !prekeyBundleUrl) {
    return null
  }

  if (activeClient && activeClient.matches({ roomId, peerUserId, deviceUrl, prekeyBundleUrl, selfPrekeyBundleUrl })) {
    await activeClient.initialize()
    return activeClient
  }

  activeClient = new E2EClient({ roomId, peerUserId, deviceUrl, prekeyBundleUrl, selfPrekeyBundleUrl })
  await activeClient.initialize()
  return activeClient
}

class E2EClient {
  #roomId
  #peerUserId
  #deviceUrl
  #prekeyBundleUrl
  #selfPrekeyBundleUrl
  #identity = null
  #deviceState = null
  #peerState = null
  #initialized = false
  #initializing = null
  #onboarded = false

  constructor({ roomId, peerUserId, deviceUrl, prekeyBundleUrl, selfPrekeyBundleUrl }) {
    this.#roomId = Number(roomId)
    this.#peerUserId = Number(peerUserId)
    this.#deviceUrl = deviceUrl
    this.#prekeyBundleUrl = prekeyBundleUrl
    this.#selfPrekeyBundleUrl = selfPrekeyBundleUrl || null
  }

  matches({ roomId, peerUserId, deviceUrl, prekeyBundleUrl, selfPrekeyBundleUrl }) {
    return (
      this.#roomId === Number(roomId) &&
      this.#peerUserId === Number(peerUserId) &&
      this.#deviceUrl === deviceUrl &&
      this.#prekeyBundleUrl === prekeyBundleUrl &&
      this.#selfPrekeyBundleUrl === (selfPrekeyBundleUrl || null)
    )
  }

  async initialize() {
    if (this.#initialized) {
      return
    }

    if (this.#initializing) {
      await this.#initializing
      return
    }

    this.#initializing = this.#initializeInternal()
    await this.#initializing
    this.#initializing = null
  }

  get available() {
    return this.#initialized && this.#onboarded
  }

  async encrypt(plaintext) {
    await this.initialize()

    if (!this.available) {
      throw new Error("E2E onboarding is not complete")
    }

    const envelopes = []

    const peerBundle = await this.#fetchPrekeyBundle(this.#prekeyBundleUrl, this.#knownDeviceIdsForUser(this.#peerUserId))
    const peerDevices = this.#extractBundleDevices(peerBundle)

    if (peerDevices.length === 0) {
      throw new Error("Peer prekey bundle is unavailable")
    }

    for (const peerDevice of peerDevices) {
      const session = await this.#ensureInitiatorSessionForDevice(peerDevice, this.#peerUserId)
      if (!session) {
        continue
      }

      const envelope = await this.#encryptForSession(session, plaintext, this.#peerUserId, peerDevice.device_id)
      if (envelope) {
        envelopes.push(envelope)
      }
    }

    if (this.#selfPrekeyBundleUrl) {
      const selfBundle = await this.#fetchPrekeyBundle(this.#selfPrekeyBundleUrl, this.#knownDeviceIdsForUser(Current.user.id))
      const selfDevices = this.#extractBundleDevices(selfBundle)

      for (const selfDevice of selfDevices) {
        if (String(selfDevice.device_id) === this.#deviceState.deviceId) {
          continue
        }

        const session = await this.#ensureInitiatorSessionForDevice(selfDevice, Current.user.id)
        if (!session) {
          continue
        }

        const envelope = await this.#encryptForSession(session, plaintext, Current.user.id, selfDevice.device_id)
        if (envelope) {
          envelopes.push(envelope)
        }
      }
    }

    if (!envelopes.some((envelope) => Number(envelope.recipient_user_id) === this.#peerUserId)) {
      throw new Error("Unable to encrypt for peer devices")
    }

    this.#persistPeerState()

    return {
      v: 3,
      alg: ALGORITHM,
      from: Current.user.id,
      to: this.#peerUserId,
      from_device_id: this.#deviceState.deviceId,
      envelopes
    }
  }

  async decrypt(payload, senderId) {
    await this.initialize()

    if (!this.available || payload?.alg !== ALGORITHM) {
      return null
    }

    const numericSenderId = Number(senderId)

    if (numericSenderId === Current.user.id) {
      return this.#decryptOwnMessage(payload)
    }

    if (numericSenderId !== this.#peerUserId) {
      return null
    }

    const envelope = this.#findIncomingEnvelope(payload)
    if (!envelope) {
      return null
    }

    const senderDeviceId = String(envelope.sender_device_id || payload.from_device_id || envelope.x3dh?.sender_device_id || "")
    if (!senderDeviceId) {
      return null
    }

    let session = this.#sessionForDevice(this.#peerUserId, senderDeviceId)

    if (!session) {
      session = await this.#bootstrapResponderSession({
        senderUserId: this.#peerUserId,
        senderDeviceId,
        envelope
      })
    }

    if (!session) {
      return null
    }

    const plaintext = await this.#decryptIncomingEnvelope(session, payload, envelope)

    if (plaintext !== null) {
      session.lastReceivedAt = new Date().toISOString()
      session.updatedAt = session.lastReceivedAt
      this.#persistPeerState()
    }

    return plaintext
  }

  async #initializeInternal() {
    if (!window.crypto?.subtle) {
      this.#initialized = true
      return
    }

    this.#identity = await this.#loadOrCreateIdentity()
    this.#deviceState = await this.#loadOrCreateDeviceState()
    this.#peerState = this.#loadOrCreatePeerState()

    this.#pruneStaleSessions()
    await this.#rotateSignedPrekeyIfNeeded()
    await this.#ensureOneTimePrekeys()
    await this.#refreshDeviceOnServer()

    this.#initialized = true
    this.#onboarded = true
  }

  async #decryptOwnMessage(payload) {
    const envelopes = this.#extractOutgoingEnvelopes(payload)

    for (const envelope of envelopes) {
      const recipientDeviceId = String(envelope.recipient_device_id || "")
      const senderDeviceId = String(envelope.sender_device_id || "")
      const recipientUserId = Number(envelope.recipient_user_id || payload.to || this.#peerUserId)

      if (recipientDeviceId === this.#deviceState.deviceId && senderDeviceId && senderDeviceId !== this.#deviceState.deviceId) {
        let session = this.#sessionForDevice(Current.user.id, senderDeviceId)

        if (!session) {
          session = await this.#bootstrapResponderSession({
            senderUserId: Current.user.id,
            senderDeviceId,
            envelope
          })
        }

        if (session) {
          const plaintext = await this.#decryptIncomingEnvelope(session, payload, envelope)
          if (plaintext !== null) {
            session.lastReceivedAt = new Date().toISOString()
            session.updatedAt = session.lastReceivedAt
            this.#persistPeerState()
            return plaintext
          }
        }
      }

      if (senderDeviceId === this.#deviceState.deviceId) {
        if (recipientDeviceId) {
          const session = this.#sessionForDevice(recipientUserId, recipientDeviceId)
          if (!session) {
            continue
          }

          const plaintext = await this.#decryptOutgoingEnvelope(session, payload, envelope)
          if (plaintext !== null) {
            return plaintext
          }
          continue
        }

        for (const session of this.#sessionsForUser(recipientUserId)) {
          const plaintext = await this.#decryptOutgoingEnvelope(session, payload, envelope)
          if (plaintext !== null) {
            return plaintext
          }
        }
      }
    }

    return null
  }

  async #encryptForSession(session, plaintext, recipientUserId, recipientDeviceId) {
    const chainKey = base64UrlToBytes(session.sendChainKey)
    const { messageKey, nextChainKey } = await this.#advanceChain(chainKey)
    const counter = Number(session.sendCounter)

    const aad = this.#buildAad({
      payloadVersion: 3,
      counter,
      senderDeviceId: this.#deviceState.deviceId,
      recipientUserId,
      recipientDeviceId,
      fromUserId: Current.user.id,
      toUserId: this.#peerUserId
    })

    const encrypted = await encryptMessage(messageKey, plaintext, aad)

    session.sendCounter = counter + 1
    session.sendChainKey = bytesToBase64Url(nextChainKey)
    session.lastSentAt = new Date().toISOString()
    session.updatedAt = session.lastSentAt

    const envelope = {
      sender_device_id: this.#deviceState.deviceId,
      recipient_user_id: recipientUserId,
      recipient_device_id: recipientDeviceId,
      c: counter,
      iv: encrypted.iv,
      ciphertext: encrypted.ciphertext
    }

    if (counter === 0 && session.bootstrap?.pending) {
      envelope.x3dh = session.bootstrap.header
      session.bootstrap.pending = false
    }

    return envelope
  }

  async #decryptOutgoingEnvelope(session, payload, envelope) {
    const counter = Number(envelope.c)
    if (!Number.isInteger(counter) || counter < 0) {
      return null
    }

    const messageKey = await this.#deriveMessageKeyForCounter(session.baseSendChainKey, counter)

    const aad = this.#buildAad({
      payloadVersion: payload.v || 1,
      counter,
      senderDeviceId: envelope.sender_device_id || payload.from_device_id,
      recipientUserId: envelope.recipient_user_id,
      recipientDeviceId: envelope.recipient_device_id,
      fromUserId: payload.from,
      toUserId: payload.to
    })

    return decryptMessage(messageKey, envelope, aad)
  }

  async #decryptIncomingEnvelope(session, payload, envelope) {
    const messageCounter = Number(envelope.c)
    if (!Number.isInteger(messageCounter) || messageCounter < 0) {
      return null
    }

    if (messageCounter - Number(session.recvCounter) > MAX_SKIP_AHEAD) {
      return null
    }

    let messageKey

    if (messageCounter < Number(session.recvCounter)) {
      const skippedKey = session.skippedKeys[String(messageCounter)]
      if (skippedKey) {
        messageKey = base64UrlToBytes(skippedKey)
        delete session.skippedKeys[String(messageCounter)]
      } else {
        messageKey = await this.#deriveMessageKeyForCounter(session.baseRecvChainKey, messageCounter)
      }
    } else {
      while (Number(session.recvCounter) < messageCounter) {
        const step = await this.#advanceChain(base64UrlToBytes(session.recvChainKey))
        session.skippedKeys[String(session.recvCounter)] = bytesToBase64Url(step.messageKey)
        session.recvChainKey = bytesToBase64Url(step.nextChainKey)
        session.recvCounter = Number(session.recvCounter) + 1
      }

      const step = await this.#advanceChain(base64UrlToBytes(session.recvChainKey))
      messageKey = step.messageKey
      session.recvChainKey = bytesToBase64Url(step.nextChainKey)
      session.recvCounter = Number(session.recvCounter) + 1

      this.#trimSkippedKeys(session)
    }

    session.updatedAt = new Date().toISOString()

    const aad = this.#buildAad({
      payloadVersion: payload.v || 1,
      counter: messageCounter,
      senderDeviceId: envelope.sender_device_id || payload.from_device_id,
      recipientUserId: envelope.recipient_user_id,
      recipientDeviceId: envelope.recipient_device_id,
      fromUserId: payload.from,
      toUserId: payload.to
    })

    return decryptMessage(messageKey, envelope, aad)
  }

  #buildAad({ payloadVersion, counter, senderDeviceId, recipientUserId, recipientDeviceId, fromUserId, toUserId }) {
    return {
      v: Number(payloadVersion || 1),
      alg: ALGORITHM,
      from: Number(fromUserId),
      to: Number(toUserId),
      from_device_id: senderDeviceId || null,
      sender_device_id: senderDeviceId || null,
      recipient_user_id: Number(recipientUserId || 0),
      recipient_device_id: recipientDeviceId || null,
      c: Number(counter)
    }
  }

  async #ensureInitiatorSessionForDevice(deviceBundle, targetUserId) {
    const peerDeviceId = String(deviceBundle.device_id || "")
    if (!peerDeviceId) {
      return null
    }

    const existingSession = this.#sessionForDevice(targetUserId, peerDeviceId)

    if (existingSession && !this.#shouldRotateSession(existingSession)) {
      return existingSession
    }

    const nextSession = await this.#createInitiatorSession(deviceBundle, targetUserId)
    this.#setSession(nextSession)
    return nextSession
  }

  #shouldRotateSession(session) {
    if (!session) {
      return true
    }

    if (Number(session.sendCounter) >= SESSION_ROTATE_AFTER_MESSAGES) {
      return true
    }

    const createdAt = parseIsoTime(session.createdAt)
    if (!createdAt) {
      return true
    }

    return Date.now() - createdAt > SESSION_ROTATE_AFTER_MS
  }

  async #bootstrapResponderSession({ senderUserId, senderDeviceId, envelope }) {
    const header = envelope?.x3dh
    if (!header) {
      return null
    }

    if (String(header.recipient_device_id || "") !== this.#deviceState.deviceId) {
      return null
    }

    const signedPrekey = this.#findSignedPrekey(Number(header.recipient_signed_prekey_id))
    if (!signedPrekey) {
      return null
    }

    const senderIdentityKey = parseJwk(header.sender_identity_key)
    const senderEphemeralKey = parseJwk(header.sender_ephemeral_key)

    if (!senderIdentityKey || !senderEphemeralKey) {
      return null
    }

    const sharedSecrets = []
    sharedSecrets.push(await deriveSharedSecret(await importEcdhPrivateKey(signedPrekey.privateKeyJwk), senderIdentityKey))
    sharedSecrets.push(await deriveSharedSecret(this.#identity.privateKey, senderEphemeralKey))
    sharedSecrets.push(await deriveSharedSecret(await importEcdhPrivateKey(signedPrekey.privateKeyJwk), senderEphemeralKey))

    const oneTimePrekeyId = Number(header.recipient_one_time_prekey_id)
    if (Number.isFinite(oneTimePrekeyId) && oneTimePrekeyId > 0) {
      const oneTimePrekey = await this.#consumeOneTimePrekey(oneTimePrekeyId)
      if (oneTimePrekey) {
        sharedSecrets.push(await deriveSharedSecret(await importEcdhPrivateKey(oneTimePrekey.privateKeyJwk), senderEphemeralKey))
      }
    }

    const rootKey = await hkdf(concatUint8Arrays(sharedSecrets), "once/e2e/x3dh/root-key/v1")
    const initiatorChainKey = await hkdf(rootKey, "once/e2e/chain/initiator")
    const responderChainKey = await hkdf(rootKey, "once/e2e/chain/responder")

    const nowIso = new Date().toISOString()

    const session = {
      version: 4,
      peerUserId: Number(senderUserId),
      peerDeviceId: String(senderDeviceId),
      sendCounter: 0,
      recvCounter: 0,
      sendChainKey: bytesToBase64Url(responderChainKey),
      recvChainKey: bytesToBase64Url(initiatorChainKey),
      baseSendChainKey: bytesToBase64Url(responderChainKey),
      baseRecvChainKey: bytesToBase64Url(initiatorChainKey),
      skippedKeys: {},
      bootstrap: { pending: false },
      createdAt: nowIso,
      updatedAt: nowIso,
      lastReceivedAt: nowIso,
      lastSentAt: null
    }

    this.#setSession(session)
    this.#persistDeviceState()
    this.#persistPeerState()

    return session
  }

  async #createInitiatorSession(bundleDevice, targetUserId) {
    const peerDeviceId = String(bundleDevice.device_id || "")
    const peerIdentityKey = parseJwk(bundleDevice.identity_key)
    const peerSignedPrekey = parseJwk(bundleDevice?.signed_prekey?.public_key)
    const peerOneTimePrekey = parseJwk(bundleDevice?.one_time_prekey?.public_key)

    if (!peerDeviceId || !peerIdentityKey || !peerSignedPrekey) {
      throw new Error("Peer bundle is incomplete")
    }

    const ephemeralKey = await generateEcdhKeyPair()

    const sharedSecrets = []
    sharedSecrets.push(await deriveSharedSecret(this.#identity.privateKey, peerSignedPrekey))
    sharedSecrets.push(await deriveSharedSecret(ephemeralKey.privateKey, peerIdentityKey))
    sharedSecrets.push(await deriveSharedSecret(ephemeralKey.privateKey, peerSignedPrekey))

    if (peerOneTimePrekey) {
      sharedSecrets.push(await deriveSharedSecret(ephemeralKey.privateKey, peerOneTimePrekey))
    }

    const rootKey = await hkdf(concatUint8Arrays(sharedSecrets), "once/e2e/x3dh/root-key/v1")
    const initiatorChainKey = await hkdf(rootKey, "once/e2e/chain/initiator")
    const responderChainKey = await hkdf(rootKey, "once/e2e/chain/responder")
    const nowIso = new Date().toISOString()

    return {
      version: 4,
      peerUserId: Number(targetUserId),
      peerDeviceId,
      sendCounter: 0,
      recvCounter: 0,
      sendChainKey: bytesToBase64Url(initiatorChainKey),
      recvChainKey: bytesToBase64Url(responderChainKey),
      baseSendChainKey: bytesToBase64Url(initiatorChainKey),
      baseRecvChainKey: bytesToBase64Url(responderChainKey),
      skippedKeys: {},
      bootstrap: {
        pending: true,
        header: {
          sender_device_id: this.#deviceState.deviceId,
          sender_identity_key: JSON.stringify(this.#identity.publicKeyJwk),
          sender_ephemeral_key: JSON.stringify(ephemeralKey.publicKeyJwk),
          recipient_device_id: peerDeviceId,
          recipient_signed_prekey_id: bundleDevice.signed_prekey.key_id,
          recipient_one_time_prekey_id: bundleDevice.one_time_prekey?.key_id || null
        }
      },
      createdAt: nowIso,
      updatedAt: nowIso,
      lastSentAt: null,
      lastReceivedAt: null
    }
  }

  #findIncomingEnvelope(payload) {
    if (Array.isArray(payload?.envelopes)) {
      return payload.envelopes.find((envelope) => {
        const recipientDeviceId = String(envelope?.recipient_device_id || "")
        const recipientUserId = Number(envelope?.recipient_user_id || Current.user.id)
        return recipientDeviceId === this.#deviceState.deviceId && recipientUserId === Current.user.id
      }) || null
    }

    if (payload?.iv && payload?.ciphertext) {
      return {
        sender_device_id: payload?.x3dh?.sender_device_id || payload?.from_device_id,
        recipient_user_id: Current.user.id,
        recipient_device_id: this.#deviceState.deviceId,
        c: payload.c,
        iv: payload.iv,
        ciphertext: payload.ciphertext,
        x3dh: payload.x3dh
      }
    }

    return null
  }

  #extractOutgoingEnvelopes(payload) {
    if (Array.isArray(payload?.envelopes)) {
      return payload.envelopes
    }

    if (payload?.iv && payload?.ciphertext) {
      return [ {
        sender_device_id: payload?.x3dh?.sender_device_id || payload?.from_device_id || this.#deviceState.deviceId,
        recipient_user_id: payload.to,
        recipient_device_id: payload?.x3dh?.recipient_device_id,
        c: payload.c,
        iv: payload.iv,
        ciphertext: payload.ciphertext,
        x3dh: payload.x3dh
      } ]
    }

    return []
  }

  async #deriveMessageKeyForCounter(baseChainKey, counter) {
    let chainKey = base64UrlToBytes(baseChainKey)
    let messageKey = null

    for (let index = 0; index <= Number(counter); index += 1) {
      const step = await this.#advanceChain(chainKey)
      messageKey = step.messageKey
      chainKey = step.nextChainKey
    }

    return messageKey
  }

  async #advanceChain(chainKey) {
    const messageKey = await hkdf(chainKey, "once/e2e/message-key")
    const nextChainKey = await hkdf(chainKey, "once/e2e/next-chain-key")

    return { messageKey, nextChainKey }
  }

  #trimSkippedKeys(session) {
    const keys = Object.keys(session.skippedKeys).sort((a, b) => Number(a) - Number(b))

    while (keys.length > MAX_SKIPPED_KEYS) {
      const oldest = keys.shift()
      delete session.skippedKeys[oldest]
    }
  }

  #pruneStaleSessions() {
    const sessions = this.#peerState.sessions || {}
    const now = Date.now()

    for (const [ key, session ] of Object.entries(sessions)) {
      if (!validSessionState(session)) {
        delete sessions[key]
        continue
      }

      const touchedAt = parseIsoTime(session.updatedAt || session.lastReceivedAt || session.lastSentAt || session.createdAt)
      if (!touchedAt || now - touchedAt > SESSION_EVICT_AFTER_MS) {
        delete sessions[key]
      }
    }

    this.#persistPeerState()
  }

  #sessionKey(peerUserId, peerDeviceId) {
    return `${Number(peerUserId)}:${String(peerDeviceId || "")}`
  }

  #sessionForDevice(peerUserId, peerDeviceId) {
    const key = this.#sessionKey(peerUserId, peerDeviceId)
    const session = this.#peerState.sessions?.[key]

    if (!validSessionState(session)) {
      delete this.#peerState.sessions[key]
      return null
    }

    return session
  }

  #setSession(session) {
    const key = this.#sessionKey(session.peerUserId, session.peerDeviceId)
    this.#peerState.sessions[key] = session
  }

  #sessionsForUser(peerUserId) {
    return Object.values(this.#peerState.sessions || {}).filter((session) => Number(session.peerUserId) === Number(peerUserId))
  }

  #knownDeviceIdsForUser(peerUserId) {
    return uniqueStrings(this.#sessionsForUser(peerUserId).map((session) => session.peerDeviceId))
  }

  #extractBundleDevices(bundle) {
    if (Array.isArray(bundle?.devices)) {
      return bundle.devices.filter((device) => validBundleDevice(device))
    }

    if (validBundleDevice(bundle?.device)) {
      return [ bundle.device ]
    }

    return []
  }

  async #loadOrCreateIdentity() {
    const existing = this.#readStorage(IDENTITY_STORAGE_KEY)

    if (validIdentityState(existing)) {
      try {
        return {
          publicKeyJwk: existing.publicKeyJwk,
          privateKeyJwk: existing.privateKeyJwk,
          publicKey: await importEcdhPublicKey(existing.publicKeyJwk),
          privateKey: await importEcdhPrivateKey(existing.privateKeyJwk)
        }
      } catch {
        this.#removeStorage(IDENTITY_STORAGE_KEY)
      }
    }

    const generated = await generateEcdhKeyPair()
    const identity = {
      publicKeyJwk: generated.publicKeyJwk,
      privateKeyJwk: generated.privateKeyJwk
    }

    this.#writeStorage(IDENTITY_STORAGE_KEY, identity)

    return {
      ...identity,
      publicKey: generated.publicKey,
      privateKey: generated.privateKey
    }
  }

  async #loadOrCreateDeviceState() {
    const existing = this.#readStorage(DEVICE_STORAGE_KEY)

    if (validDeviceState(existing)) {
      return normalizeDeviceState(existing)
    }

    const signedPrekey = await generateEcdhKeyPair()
    const nowIso = new Date().toISOString()
    const signedPrekeyId = randomIntegerId()

    return {
      deviceId: randomIdentifier("device"),
      name: currentDeviceName(),
      signedPrekey: {
        keyId: signedPrekeyId,
        publicKeyJwk: signedPrekey.publicKeyJwk,
        privateKeyJwk: signedPrekey.privateKeyJwk,
        rotatedAt: nowIso
      },
      nextSignedPrekeyId: signedPrekeyId + 1,
      oneTimePrekeys: [],
      nextOneTimePrekeyId: randomIntegerId()
    }
  }

  #loadOrCreatePeerState() {
    const existing = this.#readStorage(this.#peerStateStorageKey)

    if (!validPeerState(existing)) {
      return {
        version: 4,
        roomId: this.#roomId,
        peerUserId: this.#peerUserId,
        sessions: {}
      }
    }

    return {
      version: 4,
      roomId: this.#roomId,
      peerUserId: this.#peerUserId,
      sessions: normalizeSessions(existing.sessions)
    }
  }

  get #peerStateStorageKey() {
    return `${STORAGE_NAMESPACE}:peer_state:${this.#roomId}:${this.#peerUserId}`
  }

  async #rotateSignedPrekeyIfNeeded() {
    const rotatedAt = parseIsoTime(this.#deviceState.signedPrekey?.rotatedAt)

    if (rotatedAt && Date.now() - rotatedAt < SIGNED_PREKEY_ROTATE_AFTER_MS) {
      return
    }

    const generated = await generateEcdhKeyPair()

    this.#deviceState.signedPrekey = {
      keyId: Number(this.#deviceState.nextSignedPrekeyId),
      publicKeyJwk: generated.publicKeyJwk,
      privateKeyJwk: generated.privateKeyJwk,
      rotatedAt: new Date().toISOString()
    }

    this.#deviceState.nextSignedPrekeyId = Number(this.#deviceState.nextSignedPrekeyId) + 1
    this.#persistDeviceState()
  }

  async #refreshDeviceOnServer() {
    const pendingOneTimePrekeys = this.#deviceState.oneTimePrekeys.filter((prekey) => !prekey.uploadedAt && !prekey.consumedAt)

    const signature = await pseudoSign(this.#identity.publicKeyJwk, this.#deviceState.signedPrekey.publicKeyJwk)
    const payload = {
      e2e_device: {
        device_id: this.#deviceState.deviceId,
        name: this.#deviceState.name,
        identity_key: JSON.stringify(this.#identity.publicKeyJwk),
        signed_prekey: {
          key_id: this.#deviceState.signedPrekey.keyId,
          public_key: JSON.stringify(this.#deviceState.signedPrekey.publicKeyJwk),
          signature
        },
        one_time_prekeys: pendingOneTimePrekeys.map((prekey) => ({
          key_id: prekey.keyId,
          public_key: JSON.stringify(prekey.publicKeyJwk)
        }))
      }
    }

    const response = await fetch(this.#deviceUrl, {
      method: "PUT",
      headers: {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken()
      },
      credentials: "same-origin",
      body: JSON.stringify(payload)
    })

    if (!response.ok) {
      throw new Error(`Failed to register device: ${response.status}`)
    }

    const nowIso = new Date().toISOString()
    for (const prekey of pendingOneTimePrekeys) {
      prekey.uploadedAt = nowIso
    }

    this.#persistDeviceState()
  }

  async #fetchPrekeyBundle(url, knownDeviceIds = []) {
    if (!url) {
      return null
    }

    try {
      const requestUrl = new URL(url, window.location.origin)
      const normalizedKnownIds = uniqueStrings(knownDeviceIds)

      if (normalizedKnownIds.length > 0) {
        requestUrl.searchParams.set("known_device_ids", normalizedKnownIds.join(","))
      }

      const response = await fetch(requestUrl.toString(), {
        method: "GET",
        headers: { "Accept": "application/json" },
        credentials: "same-origin"
      })

      if (!response.ok) {
        return null
      }

      return response.json()
    } catch {
      return null
    }
  }

  #findSignedPrekey(keyId) {
    const signedPrekey = this.#deviceState.signedPrekey
    if (!signedPrekey || Number(signedPrekey.keyId) !== Number(keyId)) {
      return null
    }

    return signedPrekey
  }

  async #consumeOneTimePrekey(keyId) {
    const index = this.#deviceState.oneTimePrekeys.findIndex((prekey) => Number(prekey.keyId) === Number(keyId) && !prekey.consumedAt)
    if (index < 0) {
      return null
    }

    const prekey = this.#deviceState.oneTimePrekeys[index]
    prekey.consumedAt = new Date().toISOString()

    await this.#ensureOneTimePrekeys()
    this.#refreshDeviceOnServer().catch(() => {})

    return prekey
  }

  async #ensureOneTimePrekeys() {
    for (const prekey of this.#deviceState.oneTimePrekeys) {
      if (!prekey.publicKeyJwk || !prekey.privateKeyJwk) {
        const generated = await generateEcdhKeyPair()
        prekey.publicKeyJwk = generated.publicKeyJwk
        prekey.privateKeyJwk = generated.privateKeyJwk
        prekey.uploadedAt = null
      }
    }

    const availableCount = this.#deviceState.oneTimePrekeys.filter((prekey) => !prekey.consumedAt).length
    const needed = Math.max(0, MIN_ONE_TIME_PREKEYS - availableCount)

    for (let index = 0; index < needed; index += 1) {
      const generated = await generateEcdhKeyPair()

      this.#deviceState.oneTimePrekeys.push({
        keyId: this.#deviceState.nextOneTimePrekeyId,
        publicKeyJwk: generated.publicKeyJwk,
        privateKeyJwk: generated.privateKeyJwk,
        uploadedAt: null,
        consumedAt: null
      })

      this.#deviceState.nextOneTimePrekeyId += 1
    }

    this.#persistDeviceState()
  }

  #persistPeerState() {
    this.#writeStorage(this.#peerStateStorageKey, this.#peerState)
  }

  #persistDeviceState() {
    this.#writeStorage(DEVICE_STORAGE_KEY, this.#deviceState)
  }

  #readStorage(key) {
    try {
      const rawValue = localStorage.getItem(key)
      return rawValue ? JSON.parse(rawValue) : null
    } catch {
      return null
    }
  }

  #writeStorage(key, value) {
    try {
      localStorage.setItem(key, JSON.stringify(value))
    } catch {
      // Ignore storage write errors and continue with in-memory state.
    }
  }

  #removeStorage(key) {
    try {
      localStorage.removeItem(key)
    } catch {
      // Ignore storage cleanup errors.
    }
  }
}

function validIdentityState(value) {
  return Boolean(value?.publicKeyJwk && value?.privateKeyJwk)
}

function validDeviceState(value) {
  return Boolean(
    value &&
    value.deviceId &&
    value.name &&
    value.signedPrekey?.keyId &&
    value.signedPrekey?.publicKeyJwk &&
    value.signedPrekey?.privateKeyJwk &&
    Array.isArray(value.oneTimePrekeys) &&
    Number.isInteger(Number(value.nextOneTimePrekeyId))
  )
}

function normalizeDeviceState(value) {
  return {
    deviceId: value.deviceId,
    name: value.name,
    signedPrekey: {
      keyId: Number(value.signedPrekey.keyId),
      publicKeyJwk: value.signedPrekey.publicKeyJwk,
      privateKeyJwk: value.signedPrekey.privateKeyJwk,
      rotatedAt: value.signedPrekey.rotatedAt || new Date().toISOString()
    },
    nextSignedPrekeyId: Number(value.nextSignedPrekeyId || Number(value.signedPrekey.keyId) + 1),
    oneTimePrekeys: Array.isArray(value.oneTimePrekeys) ? value.oneTimePrekeys : [],
    nextOneTimePrekeyId: Number(value.nextOneTimePrekeyId)
  }
}

function validSessionState(value) {
  return Boolean(
    value &&
    value.sendChainKey &&
    value.recvChainKey &&
    value.baseSendChainKey &&
    value.baseRecvChainKey &&
    Number.isInteger(Number(value.sendCounter)) &&
    Number.isInteger(Number(value.recvCounter)) &&
    typeof value.skippedKeys === "object" &&
    value.peerUserId &&
    value.peerDeviceId
  )
}

function validPeerState(value) {
  return Boolean(
    value &&
    Number.isInteger(Number(value.roomId)) &&
    Number.isInteger(Number(value.peerUserId)) &&
    typeof value.sessions === "object"
  )
}

function normalizeSessions(input) {
  const sessions = {}

  for (const [ key, session ] of Object.entries(input || {})) {
    if (!validSessionState(session)) {
      continue
    }

    const peerUserId = Number(session.peerUserId)
    const peerDeviceId = String(session.peerDeviceId || key)
    const normalizedKey = `${peerUserId}:${peerDeviceId}`

    sessions[normalizedKey] = {
      ...session,
      version: Number(session.version || 4),
      peerUserId,
      peerDeviceId,
      sendCounter: Number(session.sendCounter),
      recvCounter: Number(session.recvCounter),
      skippedKeys: { ...(session.skippedKeys || {}) },
      createdAt: session.createdAt || new Date().toISOString(),
      updatedAt: session.updatedAt || session.createdAt || new Date().toISOString(),
      lastSentAt: session.lastSentAt || null,
      lastReceivedAt: session.lastReceivedAt || null,
      bootstrap: normalizeBootstrap(session.bootstrap)
    }
  }

  return sessions
}

function normalizeBootstrap(bootstrap) {
  if (!bootstrap || typeof bootstrap !== "object") {
    return { pending: false }
  }

  return {
    pending: Boolean(bootstrap.pending),
    header: bootstrap.header || null
  }
}

function validBundleDevice(device) {
  return Boolean(
    device &&
    device.device_id &&
    device.identity_key &&
    device.signed_prekey?.key_id &&
    device.signed_prekey?.public_key
  )
}

function uniqueStrings(values) {
  return Array.from(new Set(
    Array.from(values || []).map((value) => String(value || "").trim()).filter(Boolean)
  ))
}

function parseIsoTime(value) {
  if (!value) {
    return null
  }

  const time = Date.parse(value)
  return Number.isFinite(time) ? time : null
}

function currentDeviceName() {
  const platform = navigator.userAgentData?.platform || navigator.platform || "Unknown"
  return `Web ${String(platform).slice(0, 32)}`
}

function randomIdentifier(prefix) {
  if (crypto.randomUUID) {
    return `${prefix}-${crypto.randomUUID()}`
  }

  return `${prefix}-${Math.random().toString(36).slice(2)}-${Date.now().toString(36)}`
}

function randomIntegerId() {
  return Math.floor(Date.now() % 1_000_000_000 + Math.random() * 10_000)
}

async function generateEcdhKeyPair() {
  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    [ "deriveBits" ]
  )

  return {
    publicKey: keyPair.publicKey,
    privateKey: keyPair.privateKey,
    publicKeyJwk: await crypto.subtle.exportKey("jwk", keyPair.publicKey),
    privateKeyJwk: await crypto.subtle.exportKey("jwk", keyPair.privateKey)
  }
}

async function importEcdhPublicKey(jwk) {
  return crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "ECDH", namedCurve: "P-256" },
    true,
    []
  )
}

async function importEcdhPrivateKey(jwk) {
  return crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "ECDH", namedCurve: "P-256" },
    true,
    [ "deriveBits" ]
  )
}

async function deriveSharedSecret(privateKey, publicKeyJwk) {
  const publicKey = await importEcdhPublicKey(publicKeyJwk)

  return new Uint8Array(await crypto.subtle.deriveBits(
    { name: "ECDH", public: publicKey },
    privateKey,
    256
  ))
}

async function hkdf(inputKeyMaterial, info, salt = ZERO_SALT, length = 32) {
  const key = await crypto.subtle.importKey(
    "raw",
    ensureUint8Array(inputKeyMaterial),
    "HKDF",
    false,
    [ "deriveBits" ]
  )

  const bits = await crypto.subtle.deriveBits(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: ensureUint8Array(salt),
      info: textEncoder.encode(info)
    },
    key,
    length * 8
  )

  return new Uint8Array(bits)
}

async function encryptMessage(messageKey, plaintext, aad) {
  const key = await crypto.subtle.importKey(
    "raw",
    ensureUint8Array(messageKey),
    { name: "AES-GCM" },
    false,
    [ "encrypt" ]
  )

  const iv = crypto.getRandomValues(new Uint8Array(12))
  const encodedPlaintext = textEncoder.encode(plaintext)
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: encodeAad(aad) },
    key,
    encodedPlaintext
  )

  return {
    iv: bytesToBase64Url(iv),
    ciphertext: bytesToBase64Url(new Uint8Array(ciphertext))
  }
}

async function decryptMessage(messageKey, envelope, aad) {
  try {
    const key = await crypto.subtle.importKey(
      "raw",
      ensureUint8Array(messageKey),
      { name: "AES-GCM" },
      false,
      [ "decrypt" ]
    )

    const decrypted = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: base64UrlToBytes(envelope.iv),
        additionalData: encodeAad(aad)
      },
      key,
      base64UrlToBytes(envelope.ciphertext)
    )

    return textDecoder.decode(decrypted)
  } catch {
    return null
  }
}

function encodeAad(payload) {
  const version = Number(payload?.v || 1)

  if (version < 2) {
    return textEncoder.encode(JSON.stringify([
      payload.v,
      payload.alg,
      payload.from,
      payload.to,
      payload.c
    ]))
  }

  if (version < 3) {
    return textEncoder.encode(JSON.stringify([
      payload.v,
      payload.alg,
      payload.from,
      payload.to,
      payload.from_device_id,
      payload.sender_device_id,
      payload.recipient_device_id,
      payload.c
    ]))
  }

  return textEncoder.encode(JSON.stringify([
    payload.v,
    payload.alg,
    payload.from,
    payload.to,
    payload.from_device_id,
    payload.sender_device_id,
    payload.recipient_user_id,
    payload.recipient_device_id,
    payload.c
  ]))
}

function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content
}

function ensureUint8Array(value) {
  if (value instanceof Uint8Array) {
    return value
  }

  return new Uint8Array(value)
}

function bytesToBase64Url(bytes) {
  let binary = ""
  const chunkSize = 0x8000

  for (let index = 0; index < bytes.length; index += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunkSize))
  }

  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "")
}

function base64UrlToBytes(input) {
  const normalized = String(input || "")
    .replace(/-/g, "+")
    .replace(/_/g, "/")
  const padding = (4 - (normalized.length % 4)) % 4
  const padded = normalized + "=".repeat(padding)
  const binary = atob(padded)
  const bytes = new Uint8Array(binary.length)

  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }

  return bytes
}

function parseJwk(raw) {
  if (!raw) {
    return null
  }

  try {
    return typeof raw === "string" ? JSON.parse(raw) : raw
  } catch {
    return null
  }
}

function concatUint8Arrays(values) {
  const length = values.reduce((sum, value) => sum + value.length, 0)
  const result = new Uint8Array(length)
  let offset = 0

  for (const value of values) {
    result.set(value, offset)
    offset += value.length
  }

  return result
}

async function pseudoSign(identityPublicKeyJwk, signedPrekeyPublicKeyJwk) {
  const digestInput = textEncoder.encode(`${JSON.stringify(identityPublicKeyJwk)}:${JSON.stringify(signedPrekeyPublicKeyJwk)}`)
  const digest = await crypto.subtle.digest("SHA-256", digestInput)
  return bytesToBase64Url(new Uint8Array(digest))
}
