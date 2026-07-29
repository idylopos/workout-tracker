export const VAULT_STORAGE_KEY = "formflow.encrypted-vault.v1";
export const PBKDF2_ITERATIONS = 310000;

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const additionalData = encoder.encode("formflow-encrypted-vault-v1");

function bytesToBase64(bytes) {
  let binary = "";
  const chunkSize = 0x8000;
  for (let index = 0; index < bytes.length; index += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunkSize));
  }
  return btoa(binary);
}

function base64ToBytes(value) {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

async function deriveKey(passphrase, salt, iterations = PBKDF2_ITERATIONS) {
  const sourceKey = await globalThis.crypto.subtle.importKey(
    "raw",
    encoder.encode(passphrase),
    "PBKDF2",
    false,
    ["deriveKey"],
  );
  return globalThis.crypto.subtle.deriveKey(
    {
      name: "PBKDF2",
      hash: "SHA-256",
      salt,
      iterations,
    },
    sourceKey,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

export async function encryptState(state, key, salt, iterations = PBKDF2_ITERATIONS) {
  const iv = globalThis.crypto.getRandomValues(new Uint8Array(12));
  const plaintext = encoder.encode(JSON.stringify(state));
  const ciphertext = await globalThis.crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData, tagLength: 128 },
    key,
    plaintext,
  );
  return {
    version: 1,
    kdf: {
      name: "PBKDF2",
      hash: "SHA-256",
      iterations,
      salt: bytesToBase64(salt),
    },
    cipher: {
      name: "AES-GCM",
      iv: bytesToBase64(iv),
      data: bytesToBase64(new Uint8Array(ciphertext)),
    },
  };
}

export async function createVault(state, passphrase) {
  const salt = globalThis.crypto.getRandomValues(new Uint8Array(16));
  const key = await deriveKey(passphrase, salt);
  const vault = await encryptState(state, key, salt);
  return { state, key, salt, iterations: PBKDF2_ITERATIONS, vault };
}

export async function unlockVault(vault, passphrase) {
  if (
    !vault ||
    vault.version !== 1 ||
    vault.kdf?.name !== "PBKDF2" ||
    vault.kdf?.hash !== "SHA-256" ||
    vault.cipher?.name !== "AES-GCM"
  ) {
    throw new Error("Unsupported encrypted vault format.");
  }
  const iterations = Number(vault.kdf.iterations);
  if (!Number.isInteger(iterations) || iterations < 100000 || iterations > 1000000) {
    throw new Error("Invalid vault key settings.");
  }
  const salt = base64ToBytes(vault.kdf.salt);
  const iv = base64ToBytes(vault.cipher.iv);
  const ciphertext = base64ToBytes(vault.cipher.data);
  const key = await deriveKey(passphrase, salt, iterations);
  const plaintext = await globalThis.crypto.subtle.decrypt(
    { name: "AES-GCM", iv, additionalData, tagLength: 128 },
    key,
    ciphertext,
  );
  return {
    state: JSON.parse(decoder.decode(plaintext)),
    key,
    salt,
    iterations,
    vault,
  };
}

