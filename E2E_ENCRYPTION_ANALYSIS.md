# E2E Encryption Analysis — Campfire

## 1. Overview of Current Implementation

Campfire implements end-to-end encryption for **direct (1:1) rooms** using a protocol inspired by the Signal Protocol:

- **X3DH (Extended Triple Diffie-Hellman)** — key agreement for session establishment
- **Double Ratchet** — symmetric key derivation for message encryption
- **AES-256-GCM** — authenticated encryption of message content
- **ECDH on P-256** — elliptic curve key generation
- **HKDF-SHA-256** — key derivation function
- **Multi-device support** — per-device sessions and envelope fanout

### Architecture Components

| Layer | Component | Location |
|-------|-----------|----------|
| Client crypto | `E2EClient` class | `app/javascript/lib/e2e/client.js` |
| Client UI decrypt | `e2e_message_controller` | `app/javascript/controllers/e2e_message_controller.js` |
| Client UI encrypt | `composer_controller` | `app/javascript/controllers/composer_controller.js` |
| Server key management | `E2eDevicesController` | `app/controllers/users/e2e_devices_controller.rb` |
| Server prekey bundles | `E2ePrekeyBundlesController` | `app/controllers/users/e2e_prekey_bundles_controller.rb` |
| Server room key info | `E2eKeyBundlesController` | `app/controllers/rooms/e2e_key_bundles_controller.rb` |
| Models | `E2e::Device`, `E2e::SignedPrekey`, `E2e::OneTimePrekey`, `E2e::MessageEnvelope` | `app/models/e2e/` |
| Message storage | `Message` with `e2e_algorithm` + `e2e_payload` | `app/models/message.rb` |
| DB schema | 4 E2E tables + user/message E2E columns | `db/schema.rb` |

---

## 2. What Works Well

1. **X3DH key agreement** is correctly implemented with the standard 3-4 DH computation pattern (IK-SPK, EK-IK, EK-SPK, optional EK-OTK).
2. **Multi-device fanout** — messages are encrypted per-device for both peer and self devices, enabling cross-device decryption.
3. **One-time prekey management** — atomic claim with `with_lock` preventing race conditions.
4. **Session rotation** — sessions rotate after 200 messages or 3 days.
5. **Stale session eviction** — sessions older than 30 days are pruned.
6. **Skipped message keys** — out-of-order message delivery is handled, with a cap of 500 skipped keys.
7. **AAD (Additional Authenticated Data)** — encryption includes versioned AAD binding sender, recipient, device IDs, and counter.
8. **Server-side validation** — the messages controller validates E2E payloads: algorithm, sender/recipient, device existence, envelope uniqueness.
9. **Encrypted messages are not editable** — UI correctly disables editing for E2E messages.
10. **Webhooks blocked for encrypted messages** — bots cannot receive encrypted content.

---

## 3. Critical Gaps and Vulnerabilities

### 3.1 CRITICAL: No Signed Prekey Signature Verification

**File:** `app/javascript/lib/e2e/client.js:1314-1318`

```javascript
async function pseudoSign(identityPublicKeyJwk, signedPrekeyPublicKeyJwk) {
  const digestInput = textEncoder.encode(`${JSON.stringify(identityPublicKeyJwk)}:${JSON.stringify(signedPrekeyPublicKeyJwk)}`)
  const digest = await crypto.subtle.digest("SHA-256", digestInput)
  return bytesToBase64Url(new Uint8Array(digest))
}
```

The `pseudoSign` function is a **hash, not a digital signature**. It creates SHA-256(identity_pub || signed_prekey_pub) — this is not a cryptographic signature. Anyone who knows both public keys can compute the same hash. There is no verification of this "signature" on the receiving side either.

**Impact:** A malicious server (or MITM) could substitute the signed prekey with its own key and produce a valid "signature", enabling a complete undetected key substitution attack.

**Fix needed:** Use Ed25519 or ECDSA with the identity key's private key to sign the signed prekey. Verify the signature when fetching a peer's prekey bundle.

### 3.2 CRITICAL: Private Keys Stored in localStorage

**File:** `app/javascript/lib/e2e/client.js:924-937`

```javascript
#writeStorage(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value))
  } catch {
    // Ignore storage write errors
  }
}
```

Identity keys, signed prekeys, and one-time prekey private keys are all stored in `localStorage` as unencrypted JSON (JWK format with `d` parameter). This means:

- Any XSS vulnerability exposes all private keys
- Browser extensions with page access can read them
- Keys persist indefinitely (no TTL or cleanup of consumed keys)
- localStorage is accessible from any JS running on the same origin

**Impact:** Complete compromise of all past and future encrypted messages via any XSS attack.

**Fix needed:** Use IndexedDB with non-exportable CryptoKey objects where possible, or encrypt at-rest storage with a key derived from user credentials.

### 3.3 CRITICAL: No Identity Key Verification (Trust On First Use Without Verification)

There is no mechanism for users to verify each other's identity keys. The system uses implicit TOFU (Trust On First Use) with no:

- Safety number / fingerprint display
- QR code or emoji verification
- Key change notification UI
- Trust store for verified keys

**Impact:** Users cannot detect if the server has substituted a peer's identity key. A malicious server operator can perform a transparent MITM attack.

**Fix needed:** Implement safety numbers (as in Signal) and key change notifications.

### 3.4 HIGH: No Server-Side Signed Prekey Signature Verification

**File:** `app/controllers/users/e2e_devices_controller.rb:56-68`

The server stores the `signature` field but never verifies it. The `upsert_signed_prekey!` method blindly trusts any signature value provided by the client.

```ruby
def upsert_signed_prekey!(device, params)
  signed_prekey = device.signed_prekeys.find_or_initialize_by(key_id: params.fetch(:key_id))
  signed_prekey.assign_attributes(
    public_key: params.fetch(:public_key),
    signature: params.fetch(:signature),  # Never verified!
    ...
  )
  signed_prekey.save!
end
```

**Impact:** A compromised account or malicious admin could upload arbitrary signed prekeys without valid signatures.

### 3.5 HIGH: No Forward Secrecy in Chain Ratchet

The current implementation uses a **symmetric ratchet only** (HKDF chain advancement). It does not implement the **Diffie-Hellman ratchet step** from the Double Ratchet algorithm.

**File:** `app/javascript/lib/e2e/client.js:612-617`

```javascript
async #advanceChain(chainKey) {
  const messageKey = await hkdf(chainKey, "once/e2e/message-key")
  const nextChainKey = await hkdf(chainKey, "once/e2e/next-chain-key")
  return { messageKey, nextChainKey }
}
```

In the real Double Ratchet, each send/receive turn includes a DH ratchet step that generates new ephemeral keys. Without this, compromise of a single chain key reveals **all future messages** in that chain direction until session rotation (up to 200 messages or 3 days).

**Impact:** Reduced forward secrecy. If any chain key is compromised, attacker can derive all subsequent message keys in that direction.

**Fix needed:** Implement the full DH ratchet step per the Signal specification.

### 3.6 HIGH: Encrypted Attachments Not Supported

**File:** `app/javascript/controllers/composer_controller.js:37-39`

```javascript
if (this.e2eEnabledValue && this.#files.length > 0) {
  alert("Encrypted direct chats currently support text messages only.")
  return
}
```

File attachments in E2E rooms are rejected. Users fall back to plaintext for any non-text content.

**Impact:** Users are forced to share files unencrypted, creating a significant gap in the encryption guarantees.

**Fix needed:** Encrypt file contents client-side with a random key, upload the ciphertext, and send the decryption key inside the encrypted envelope.

### 3.7 HIGH: Group Room Encryption Not Supported

E2E encryption is limited to `Rooms::Direct` (1:1) only. The `ensure_direct_room` filter in `E2eKeyBundlesController` and the server-side validation explicitly block encryption in Open/Closed rooms.

**Impact:** All group conversations are fully plaintext, visible to server operator and anyone with DB access.

### 3.8 MEDIUM: No Rate Limiting on Prekey Bundle Requests

**File:** `app/controllers/users/e2e_prekey_bundles_controller.rb`

There are no rate limits on prekey bundle fetching. An attacker could:

- Exhaust a target's one-time prekeys by repeatedly requesting bundles
- Force sessions to fall back to no-OTK mode (weaker key agreement)
- Perform reconnaissance on device counts

**Fix needed:** Add per-user rate limiting on prekey bundle requests.

### 3.9 MEDIUM: No Old Signed Prekey Retention

**File:** `app/javascript/lib/e2e/client.js:769-787`

When the signed prekey rotates, the old private key is overwritten immediately. If there are in-flight X3DH key agreements referencing the old signed prekey ID, the responder will fail to establish a session (the `#findSignedPrekey` method only checks the current signed prekey).

**Impact:** Message loss during key rotation windows.

**Fix needed:** Retain the previous signed prekey for a grace period (e.g., 48 hours) after rotation.

### 3.10 MEDIUM: No Envelope Cleanup / Expiration

`E2e::MessageEnvelope` records accumulate without cleanup. There is no `delivered_at` TTL or garbage collection despite the `delivered_at` column existing in the schema.

**Impact:** Unbounded storage growth; stale envelopes persist indefinitely.

### 3.11 MEDIUM: Message Search Completely Broken for E2E

The FTS5 search index (`message_search_index`) indexes plaintext message content. Encrypted messages have no searchable plaintext, so they are invisible to search.

**Impact:** Users cannot search through their encrypted message history.

### 3.12 MEDIUM: Push Notifications Leak Metadata

Push notifications (`Room::PushMessageJob`) still fire for encrypted messages. While the message content is encrypted, the notification itself reveals:

- That a message was sent
- Which room it belongs to
- Sender identity
- Timing

**Fix needed:** Ensure push notification payloads for encrypted rooms contain only minimal metadata, or use silent pushes.

### 3.13 LOW: P-256 Curve Instead of Curve25519

The implementation uses NIST P-256 for ECDH. While P-256 is secure, the Signal Protocol standard uses Curve25519 (X25519) which offers:

- Simpler, constant-time implementations
- Resistance to invalid curve attacks
- Compatibility with Ed25519 for signing

**Note:** P-256 is a pragmatic choice given WebCrypto API native support. X25519 requires a library.

### 3.14 LOW: randomIntegerId() Has Collision Risk

**File:** `app/javascript/lib/e2e/client.js:1087-1089`

```javascript
function randomIntegerId() {
  return Math.floor(Date.now() % 1_000_000_000 + Math.random() * 10_000)
}
```

This uses `Math.random()` (not CSPRNG) and modular arithmetic that could produce collisions, especially on devices with synchronized clocks.

**Fix needed:** Use `crypto.getRandomValues()` for all security-relevant random values.

### 3.15 LOW: No Device Limit Per User

Users can register unlimited devices without any cap, potentially causing envelope fanout to grow unbounded and increasing encryption/decryption cost.

---

## 4. Improvement Plan

### Phase 1: Critical Security Fixes (Immediate)

| # | Task | Priority | Effort |
|---|------|----------|--------|
| 1.1 | Replace `pseudoSign` with real ECDSA signing (sign SPK with identity key) | CRITICAL | M |
| 1.2 | Add SPK signature verification on initiator side when processing prekey bundles | CRITICAL | M |
| 1.3 | Server-side SPK signature verification in `E2eDevicesController#upsert_signed_prekey!` | HIGH | S |
| 1.4 | Migrate key storage from `localStorage` to IndexedDB with non-exportable keys | CRITICAL | L |
| 1.5 | Use `crypto.getRandomValues()` instead of `Math.random()` in `randomIntegerId()` | LOW | XS |

### Phase 2: Protocol Completeness (1-2 weeks)

| # | Task | Priority | Effort |
|---|------|----------|--------|
| 2.1 | Implement full DH ratchet step (not just symmetric chain ratchet) | HIGH | L |
| 2.2 | Retain previous signed prekey for 48h after rotation | MEDIUM | S |
| 2.3 | Add one-time prekey low-water-mark server notifications | MEDIUM | M |
| 2.4 | Add rate limiting on prekey bundle fetch endpoints | MEDIUM | S |
| 2.5 | Implement device limit (max 5-10 per user) | LOW | S |

### Phase 3: Identity Verification (2-4 weeks)

| # | Task | Priority | Effort |
|---|------|----------|--------|
| 3.1 | Generate safety numbers from identity key pairs | CRITICAL | M |
| 3.2 | Add safety number display UI in direct room settings | CRITICAL | M |
| 3.3 | Add key change notification (banner when peer's identity key changes) | CRITICAL | M |
| 3.4 | Optional QR code verification flow | MEDIUM | M |
| 3.5 | Trust store: persist verified identity keys and detect changes | HIGH | L |

### Phase 4: Feature Completeness (1-2 months)

| # | Task | Priority | Effort |
|---|------|----------|--------|
| 4.1 | Encrypted file attachments (client-side encrypt, upload ciphertext) | HIGH | L |
| 4.2 | Encrypted push notification payloads (or silent push + client-side decrypt) | MEDIUM | M |
| 4.3 | E2E message envelope TTL and cleanup job | MEDIUM | S |
| 4.4 | Client-side encrypted search index (local) | LOW | XL |
| 4.5 | Sender Key protocol for group E2E (Open/Closed rooms) | HIGH | XL |

### Phase 5: Hardening & Audit (Ongoing)

| # | Task | Priority | Effort |
|---|------|----------|--------|
| 5.1 | Add comprehensive E2E protocol unit tests (encrypt/decrypt round-trips) | HIGH | L |
| 5.2 | Add integration tests for multi-device scenarios | HIGH | L |
| 5.3 | CSP headers to mitigate XSS (reduce localStorage attack surface) | MEDIUM | S |
| 5.4 | External security audit of the E2E implementation | CRITICAL | — |
| 5.5 | Protocol documentation with formal security properties | MEDIUM | M |
| 5.6 | Key backup and recovery mechanism (encrypted key export) | MEDIUM | L |

---

## 5. Effort Legend

- **XS** = < 1 hour
- **S** = 1-4 hours
- **M** = 1-2 days
- **L** = 3-5 days
- **XL** = 1-2 weeks

---

## 6. Summary

The current Campfire E2E implementation has a **solid architectural foundation** that mirrors the Signal Protocol structure: X3DH for key agreement, chain ratchet for message keys, AES-GCM for encryption, and multi-device envelope fanout. The server-side validation of encrypted payloads and the database schema are well-designed.

However, there are **3 critical issues** that significantly undermine the security guarantees:

1. **Pseudo-signatures** — The signed prekey "signature" is just a hash, not a digital signature, enabling key substitution attacks.
2. **Plaintext key storage** — Private keys in localStorage are vulnerable to XSS.
3. **No identity verification** — Users cannot detect MITM attacks by the server.

Additionally, the **absence of the DH ratchet step** means the protocol provides weaker forward secrecy than the Signal Protocol it claims to implement.

These issues should be addressed in order of the phases above before the E2E feature can be considered production-ready for security-sensitive use cases.
