export const UNLOCK_SESSION_DURATION_MS = 2 * 60 * 60 * 1000;

const DATABASE_NAME = "formflow-private-session";
const DATABASE_VERSION = 1;
const STORE_NAME = "unlock";
const RECORD_ID = "active";

function openDatabase(indexedDb = globalThis.indexedDB) {
  if (!indexedDb) return Promise.resolve(null);
  return new Promise((resolve, reject) => {
    const request = indexedDb.open(DATABASE_NAME, DATABASE_VERSION);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(STORE_NAME)) {
        request.result.createObjectStore(STORE_NAME, { keyPath: "id" });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
    request.onblocked = () => reject(new Error("Unlock session database is blocked."));
  });
}

function requestResult(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function transactionComplete(transaction) {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error || new Error("Unlock session transaction was aborted."));
  });
}

export function isRememberedUnlockValid(record, vault, now = Date.now()) {
  return Boolean(
    record &&
      record.id === RECORD_ID &&
      record.key &&
      Number(record.expiresAt) > Number(now) &&
      record.salt === vault?.kdf?.salt &&
      Number(record.iterations) === Number(vault?.kdf?.iterations),
  );
}

export async function saveRememberedUnlock(
  key,
  vault,
  durationMs = UNLOCK_SESSION_DURATION_MS,
  indexedDb = globalThis.indexedDB,
) {
  let database;
  try {
    database = await openDatabase(indexedDb);
    if (!database) return null;
    const expiresAt = Date.now() + Math.max(60_000, Number(durationMs) || UNLOCK_SESSION_DURATION_MS);
    const transaction = database.transaction(STORE_NAME, "readwrite");
    transaction.objectStore(STORE_NAME).put({
      id: RECORD_ID,
      key,
      expiresAt,
      salt: vault.kdf.salt,
      iterations: Number(vault.kdf.iterations),
    });
    await transactionComplete(transaction);
    return expiresAt;
  } catch {
    return null;
  } finally {
    database?.close();
  }
}

export async function loadRememberedUnlock(vault, indexedDb = globalThis.indexedDB) {
  let database;
  try {
    database = await openDatabase(indexedDb);
    if (!database) return null;
    const transaction = database.transaction(STORE_NAME, "readonly");
    const completed = transactionComplete(transaction);
    const record = await requestResult(transaction.objectStore(STORE_NAME).get(RECORD_ID));
    await completed;
    if (isRememberedUnlockValid(record, vault)) return record;
  } catch {
    return null;
  } finally {
    database?.close();
  }
  await clearRememberedUnlock(indexedDb);
  return null;
}

export async function clearRememberedUnlock(indexedDb = globalThis.indexedDB) {
  let database;
  try {
    database = await openDatabase(indexedDb);
    if (!database) return false;
    const transaction = database.transaction(STORE_NAME, "readwrite");
    transaction.objectStore(STORE_NAME).delete(RECORD_ID);
    await transactionComplete(transaction);
    return true;
  } catch {
    return false;
  } finally {
    database?.close();
  }
}
