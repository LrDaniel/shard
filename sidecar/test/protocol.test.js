"use strict";

const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const path = require("node:path");
const test = require("node:test");

const sidecarPath = path.join(__dirname, "..", "index.js");

test("mock runtime speaks the versioned JSON protocol", async () => {
  const child = spawn(process.execPath, [sidecarPath], {
    env: { ...process.env, SHARD_SIDECAR_MOCK: "1" },
    stdio: ["pipe", "pipe", "pipe"],
  });

  const response = await send(child, {
    protocolVersion: 1,
    id: "7f9680f9-7f69-4c14-a82a-5be851dd18b8",
    operation: "connect",
    payload: { profile: { defaultDatabase: "test" } },
  });

  assert.equal(response.protocolVersion, 1);
  assert.equal(response.result.connected, true);
  assert.equal(response.result.serverVersion, "8.0.0-mock");
  child.stdin.end();
});

test("runtime rejects unknown operations without leaking secrets", async () => {
  const child = spawn(process.execPath, [sidecarPath], {
    env: { ...process.env, SHARD_SIDECAR_MOCK: "1" },
    stdio: ["pipe", "pipe", "pipe"],
  });

  const response = await send(child, {
    protocolVersion: 1,
    id: "ac0f96d5-e4dd-4507-b2db-30ccf842e610",
    operation: "password=secret",
    payload: {},
  });

  assert.equal(response.error.code, "unsupported_operation");
  assert.doesNotMatch(response.error.message, /secret/);
  child.stdin.end();
});

test("runtime parses shell-style MongoDB documents into canonical EJSON", async () => {
  const child = spawn(process.execPath, [sidecarPath], {
    env: { ...process.env, SHARD_SIDECAR_MOCK: "0" },
    stdio: ["pipe", "pipe", "pipe"],
  });

  const response = await send(child, {
    protocolVersion: 1,
    id: "60518cbc-f38c-4db3-9d3f-a9a262a206f6",
    operation: "parseShellDocument",
    payload: {
      source: `{
        "_id": ObjectId("507f1f77bcf86cd799439011"),
        "count": NumberLong("9007199254740993"),
        "createdAt": ISODate("2026-07-23T00:00:00.000Z")
      }`,
    },
  });

  assert.deepEqual(response.result._id, { $oid: "507f1f77bcf86cd799439011" });
  assert.deepEqual(response.result.count, { $numberLong: "9007199254740993" });
  assert.deepEqual(response.result.createdAt, {
    $date: { $numberLong: "1784764800000" },
  });
  child.stdin.end();
});

test("mock runtime returns context-aware completion choices", async () => {
  const child = spawn(process.execPath, [sidecarPath], {
    env: { ...process.env, SHARD_SIDECAR_MOCK: "1" },
    stdio: ["pipe", "pipe", "pipe"],
  });

  const response = await send(child, {
    protocolVersion: 1,
    id: "8d39e889-ad4a-47ba-86a0-14d38bd0bc08",
    operation: "autocomplete",
    payload: { database: "sample_mflix", prefix: "db." },
  });

  assert.deepEqual(response.result, [
    "db.getCollectionNames()",
    "db.getCollection(\"movies\")",
  ]);
  child.stdin.end();
});

test("mock runtime returns collection index metadata", async () => {
  const child = spawn(process.execPath, [sidecarPath], {
    env: { ...process.env, SHARD_SIDECAR_MOCK: "1" },
    stdio: ["pipe", "pipe", "pipe"],
  });

  const response = await send(child, {
    protocolVersion: 1,
    id: "a5d9088a-cf6a-4d0e-a5bb-37c50de77027",
    operation: "listIndexes",
    payload: { database: "sample_mflix", collection: "movies" },
  });

  assert.equal(response.result[0].name, "_id_");
  assert.deepEqual(response.result[1].keys, [
    { field: "title", direction: "1" },
  ]);
  child.stdin.end();
});

test("mock runtime returns explain execution statistics", async () => {
  const child = spawn(process.execPath, [sidecarPath], {
    env: { ...process.env, SHARD_SIDECAR_MOCK: "1" },
    stdio: ["pipe", "pipe", "pipe"],
  });

  const response = await send(child, {
    protocolVersion: 1,
    id: "f46d67a1-1025-48a8-a58c-94c4db38e15e",
    operation: "explain",
    payload: {
      database: "sample_mflix",
      script: `db.getCollection("movies").find({ title: "Shard" })`,
    },
  });

  assert.equal(response.result.executionStats.totalDocsExamined, 1);
  assert.equal(
    response.result.queryPlanner.winningPlan.inputStage.indexName,
    "title_1",
  );
  child.stdin.end();
});

test("mock runtime returns typed schema fields and index metadata", async () => {
  const child = spawn(process.execPath, [sidecarPath], {
    env: { ...process.env, SHARD_SIDECAR_MOCK: "1" },
    stdio: ["pipe", "pipe", "pipe"],
  });

  const response = await send(child, {
    protocolVersion: 1,
    id: "cc437642-2301-414f-bda9-6ab36a64ee17",
    operation: "sampleSchema",
    payload: {
      database: "sample_mflix",
      collection: "movies",
      sampleSize: 100,
    },
  });

  assert.deepEqual(response.result[0], {
    path: "_id",
    types: ["ObjectId"],
    elementTypes: [],
    indexNames: ["_id_"],
  });
  assert.equal(response.result[1].types[0], "Date");
  child.stdin.end();
});

function send(child, request) {
  return new Promise((resolve, reject) => {
    let buffer = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline >= 0) {
        resolve(JSON.parse(buffer.slice(0, newline)));
      }
    });
    child.once("error", reject);
    child.stdin.write(`${JSON.stringify(request)}\n`);
  });
}
