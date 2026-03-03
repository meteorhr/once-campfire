const textEncoder = new TextEncoder()

export async function encryptFile(file) {
  const key = await crypto.subtle.generateKey(
    { name: "AES-GCM", length: 256 },
    true,
    ["encrypt"]
  )

  const iv = crypto.getRandomValues(new Uint8Array(12))
  const plaintext = await file.arrayBuffer()

  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    plaintext
  )

  const exportedKey = await crypto.subtle.exportKey("raw", key)

  const encryptedBlob = new Blob([ciphertext], { type: "application/octet-stream" })
  const encryptedFile = new File([encryptedBlob], `${file.name}.enc`, { type: "application/octet-stream" })

  return {
    encryptedFile,
    metadata: {
      original_name: file.name,
      original_type: file.type,
      original_size: file.size,
      key: bytesToBase64Url(new Uint8Array(exportedKey)),
      iv: bytesToBase64Url(iv)
    }
  }
}

export async function decryptFile(encryptedArrayBuffer, metadata) {
  const key = await crypto.subtle.importKey(
    "raw",
    base64UrlToBytes(metadata.key),
    { name: "AES-GCM", length: 256 },
    false,
    ["decrypt"]
  )

  const iv = base64UrlToBytes(metadata.iv)

  const decryptedBuffer = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv },
    key,
    encryptedArrayBuffer
  )

  return new Blob([decryptedBuffer], { type: metadata.original_type || "application/octet-stream" })
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
