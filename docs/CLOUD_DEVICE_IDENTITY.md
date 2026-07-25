# Lustre Cloud device identity and presence

Lustre Cloud has two separate principals. Clerk sessions identify people in the browser. A permanent P-256 `SecKey` identifies a macOS agent. Neither credential is accepted in place of the other, and the loopback bearer token never enters the cloud protocol.

The device public key uses the uncompressed P-256 point (65 bytes, Base64 in JSON). Its thumbprint is SHA-256 encoded with base64url. Signatures are DER-encoded ECDSA/SHA-256. Private-key bytes are never exported by a product API.

The signing input is length-prefixed binary fields, not JSON: `LUSTRE-CLOUD-DEVICE-V1`, protocol version, purpose, exact configured audience, subject ID, decoded nonce bytes, public-key thumbprint, and ISO-8601 expiry. `enrollment` and `session` purposes are distinct. Any changed byte, audience, purpose, expiry, nonce, or subject invalidates the signature.

Pairing codes contain 100 bits of Crockford Base32 entropy, expire after five minutes, are returned once, and are stored only as a server-peppered HMAC. An enrollment nonce and a session nonce are one-minute, one-use values. Database conditional updates make consumption authoritative; a concurrent completion has one winner.

Revocation is terminal. It invalidates pending session challenges and fresh device authentication rechecks revocation before and after proof verification. A local `lustre cloud disconnect` removes only local enrollment metadata; it does not revoke the cloud device record.

No pairing code, nonce, public key, signature, access token, loopback token, provider cookie, destination credential, local path, IP history, or media URL is written to audit records or application logs.

## Slice 2A: experimental read-only presence

The first hosted connection is presence-only. After loading local enrollment, `lustre-agent` requests a fresh device-session challenge, signs the canonical `session` envelope with the same Keychain key, and exchanges it for a short-lived token. That token is supplied only in a WebSocket subprotocol during the Vercel upgrade; it is never placed in a URL.

The experimental Vercel gateway accepts a strictly bounded heartbeat frame every 30 seconds and stores only server receipt time, agent version, connection generation, and monotonic sequence in `lustre_device_presence`. A new connection atomically supersedes an older generation. A late heartbeat cannot change current presence, and every write remains conditional on the device not being revoked.

The browser does not subscribe to this socket. It uses a Clerk-authenticated HTTP presence route and reports `online` only when the latest accepted heartbeat is within 75 seconds, `offline` when older, `neverConnected` when no accepted heartbeat exists, and `revoked` separately. `last_authenticated_at` remains an authentication fact, not a heartbeat fact.

The Vercel WebSocket adapter is intentionally replaceable. The agent reconnects after any transport close, error, deployment replacement, infrastructure termination, or network transition with bounded jittered backoff, and obtains a new token for every reconnect. It does not assume a fixed connection lifetime. No job data, commands, destination data, provider state, or loopback capability is exposed by this protocol.
