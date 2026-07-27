"use strict";

const readline = require("node:readline");
const { randomUUID } = require("node:crypto");
const vm = require("node:vm");

const PROTOCOL_VERSION = 1;
const mockMode = process.env.SHARD_SIDECAR_MOCK === "1";

let MongoClient;
let EJSON;
let BSON;
let client;
let selectedDatabase = "test";
const cursors = new Map();

if (!mockMode) {
  ({ MongoClient } = require("mongodb"));
  BSON = require("bson");
  ({ EJSON } = BSON);
}

const input = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
  terminal: false,
});

input.on("line", async (line) => {
  if (!line.trim()) {
    return;
  }

  let request;
  try {
    request = JSON.parse(line);
  } catch {
    writeError(null, "invalid_json", "The runtime received invalid JSON.");
    return;
  }

  if (request.protocolVersion !== PROTOCOL_VERSION) {
    writeError(
      request.id,
      "protocol_mismatch",
      `Unsupported protocol version ${request.protocolVersion}.`,
    );
    return;
  }

  try {
    const result = await handle(request.operation, request.payload ?? {});
    writeResponse(request.id, serialize(result));
  } catch (error) {
    const code = error?.codeName ?? error?.code ?? "runtime_error";
    writeError(
      request.id,
      String(code),
      redact(error?.message ?? String(error)),
      Boolean(error?.errorLabels?.includes("RetryableWriteError")),
    );
  }
});

input.on("close", async () => {
  await closeClient();
  process.exit(0);
});

async function handle(operation, payload) {
  if (mockMode) {
    return handleMock(operation, payload);
  }

  switch (operation) {
    case "connect":
      return connect(payload);
    case "disconnect":
      await closeClient();
      return { connected: false };
    case "ping":
      return requireDatabase().command({ ping: 1 });
    case "listDatabases":
      return listDatabases();
    case "listCollections":
      return listCollections(payload.database);
    case "listIndexes":
      return requireDatabase(payload.database)
        .collection(requiredString(payload.collection, "collection"))
        .listIndexes()
        .toArray()
        .then((indexes) => indexes.map(formatIndex));
    case "sampleSchema":
      return sampleSchema(payload);
    case "createIndex":
      return createIndex(payload);
    case "dropIndex":
      return dropIndex(payload);
    case "execute":
      return execute(payload, false);
    case "fetchCursorPage":
      return fetchCursorPage(payload);
    case "explain":
      return execute(payload, true);
    case "autocomplete":
      return autocomplete(payload);
    case "parseShellDocument":
      return parseShellDocument(payload);
    case "cancel":
      return { cancelled: false, restartRequired: true };
    default:
      throw codedError("unsupported_operation", `Unsupported operation: ${operation}`);
  }
}

async function connect(payload) {
  await closeClient();
  const profile = payload.profile ?? {};
  selectedDatabase = profile.defaultDatabase || "test";

  const uri = buildConnectionURI(profile);
  client = new MongoClient(
    uri,
    buildClientOptions(profile, payload.password, payload.tlsCertificatePassphrase),
  );
  await client.connect();
  const buildInfo = await requireDatabase("admin").command({ buildInfo: 1 });
  return {
    connected: true,
    serverVersion: buildInfo.version,
  };
}

async function listDatabases() {
  const response = await requireDatabase("admin").admin().listDatabases({
    nameOnly: true,
    authorizedDatabases: true,
  });
  return response.databases.map(({ name }) => name).sort();
}

async function listCollections(databaseName = selectedDatabase) {
  return requireDatabase(databaseName)
    .listCollections({}, { nameOnly: true })
    .toArray()
    .then((collections) => collections.map(({ name }) => name).sort());
}

function formatIndex(index) {
  return {
    name: index.name,
    keys: Object.entries(index.key).map(([field, direction]) => ({
      field,
      direction: String(direction),
    })),
    unique: Boolean(index.unique),
    sparse: Boolean(index.sparse),
    expireAfterSeconds: index.expireAfterSeconds == null
      ? null
      : String(index.expireAfterSeconds),
  };
}

async function createIndex(payload) {
  const collection = requireDatabase(payload.database)
    .collection(requiredString(payload.collection, "collection"));
  const keys = Object.fromEntries(
    (payload.keys ?? []).map(({ field, direction }) => [
      requiredString(field, "index field"),
      Number(direction),
    ]),
  );
  if (!Object.keys(keys).length) {
    throw codedError("invalid_request", "At least one index field is required.");
  }
  const name = await collection.createIndex(keys, {
    unique: Boolean(payload.unique),
  });
  return { name };
}

async function sampleSchema(payload) {
  const collection = requireDatabase(payload.database)
    .collection(requiredString(payload.collection, "collection"));
  const sampleSize = Math.min(200, positiveInteger(payload.sampleSize, 100));
  const [documents, indexes] = await Promise.all([
    collection.find({}).limit(sampleSize).toArray(),
    collection.listIndexes().toArray(),
  ]);
  const indexNamesByField = new Map();
  for (const index of indexes) {
    for (const field of Object.keys(index.key ?? {})) {
      const names = indexNamesByField.get(field) ?? [];
      names.push(index.name);
      indexNamesByField.set(field, names);
    }
  }

  const fields = new Map();
  for (const document of documents) {
    collectSchemaFields(document, "", fields, 0);
    if (fields.size >= 500) {
      break;
    }
  }

  return [...fields.entries()]
    .map(([path, metadata]) => ({
      path,
      types: [...metadata.types].sort(),
      elementTypes: [...metadata.elementTypes].sort(),
      indexNames: (indexNamesByField.get(path) ?? []).sort(),
    }))
    .sort((left, right) => left.path.localeCompare(right.path));
}

function collectSchemaFields(value, prefix, fields, depth) {
  if (!value || typeof value !== "object" || Array.isArray(value) || depth >= 8) {
    return;
  }
  for (const [key, child] of Object.entries(value)) {
    if (fields.size >= 500) {
      return;
    }
    const path = prefix ? `${prefix}.${key}` : key;
    const metadata = fields.get(path) ?? {
      types: new Set(),
      elementTypes: new Set(),
    };
    metadata.types.add(bsonTypeName(child));
    if (Array.isArray(child)) {
      for (const element of child.slice(0, 20)) {
        metadata.elementTypes.add(bsonTypeName(element));
        collectSchemaFields(element, path, fields, depth + 1);
      }
    } else {
      collectSchemaFields(child, path, fields, depth + 1);
    }
    fields.set(path, metadata);
  }
}

function bsonTypeName(value) {
  if (value === null || value === undefined) {
    return "Null";
  }
  if (Array.isArray(value)) {
    return "Array";
  }
  if (value instanceof Date) {
    return "Date";
  }
  if (value?._bsontype) {
    return value._bsontype;
  }
  switch (typeof value) {
    case "boolean":
      return "Boolean";
    case "number":
      return Number.isInteger(value) ? "Integer" : "Double";
    case "string":
      return "String";
    case "object":
      return "Object";
    default:
      return "Unknown";
  }
}

async function dropIndex(payload) {
  const collection = requireDatabase(payload.database)
    .collection(requiredString(payload.collection, "collection"));
  await collection.dropIndex(requiredString(payload.name, "index name"));
  return { dropped: true };
}

async function execute(payload, explain) {
  const script = requiredString(payload.script, "script").trim();
  const databaseName = payload.database || selectedDatabase;
  selectedDatabase = databaseName;

  if (/^show\s+dbs$/i.test(script)) {
    return listDatabases();
  }
  if (/^show\s+collections$/i.test(script)) {
    return listCollections(databaseName);
  }
  const useMatch = script.match(/^use\s+([^\s;]+)\s*;?$/i);
  if (useMatch) {
    selectedDatabase = useMatch[1];
    return { switchedTo: selectedDatabase };
  }

  const database = createDatabaseFacade(requireDatabase(databaseName), {
    batchSize: positiveInteger(payload.batchSize, 50),
    explain,
  });
  const source = stripTrailingSemicolons(script);

  try {
    const wrapped = `(async () => await (${source}))()`;
    return await new vm.Script(wrapped, { filename: "shard-query.js" }).runInNewContext(
      createContext(database),
      { timeout: 30_000 },
    );
  } catch (error) {
    if (!(error instanceof SyntaxError)) {
      throw error;
    }

    const wrapped = `(async () => { ${script}\n })()`;
    return await new vm.Script(wrapped, { filename: "shard-query.js" }).runInNewContext(
      createContext(database),
      { timeout: 30_000 },
    );
  }
}

async function autocomplete(payload) {
  const prefix = String(payload.prefix ?? "");
  const databaseName = payload.database || selectedDatabase;
  const methods = [
    "db.getCollectionNames()",
    "db.getSiblingDB()",
    "db.runCommand()",
    "db.stats()",
    "ObjectId()",
    "ISODate()",
    "NumberInt()",
    "NumberLong()",
    "NumberDecimal()",
    "EJSON.serialize()",
    "EJSON.deserialize()",
    ".find({})",
    ".findOne({})",
    ".aggregate([])",
    ".countDocuments({})",
    ".distinct()",
    ".sort({})",
    ".limit()",
    ".project({})",
    ".explain(\"executionStats\")",
    ".insertOne({})",
    ".updateOne({}, {})",
    ".deleteOne({})",
    "$match",
    "$project",
    "$group",
    "$sort",
    "$limit",
    "$lookup",
    "$unwind",
    "$set",
    "$unset",
    "show dbs",
    "show collections",
  ];
  const collections = await listCollections(databaseName);
  const choices = [
    ...methods,
    ...collections.flatMap((name) => [
      `db.getCollection(${JSON.stringify(name)})`,
      `db.${name}`,
    ]),
  ];
  return choices.filter((choice) => choice.startsWith(prefix)).slice(0, 100);
}

function createContext(database) {
  return {
    db: database,
    EJSON,
    ObjectId: BSON.ObjectId,
    ISODate: (value) => new Date(value),
    print: (...values) => values.map(String).join(" "),
  };
}

function parseShellDocument(payload) {
  const source = requiredString(payload.source, "source");
  const context = vm.createContext(
    {
      ObjectId: (value) => new BSON.ObjectId(value),
      ISODate: (value) => new Date(value),
      NumberInt: (value) => new BSON.Int32(Number(value)),
      NumberLong: (value) => BSON.Long.fromString(String(value)),
      NumberDecimal: (value) => BSON.Decimal128.fromString(String(value)),
      Timestamp: (time, increment) => new BSON.Timestamp({
        t: Number(time),
        i: Number(increment),
      }),
      BinData: (subtype, base64) => new BSON.Binary(
        Buffer.from(String(base64), "base64"),
        Number(subtype),
      ),
      RegExp: (pattern, options = "") => new BSON.BSONRegExp(
        String(pattern),
        String(options),
      ),
      MinKey: () => new BSON.MinKey(),
      MaxKey: () => new BSON.MaxKey(),
    },
    {
      codeGeneration: { strings: false, wasm: false },
      name: "shard-document-parser",
    },
  );
  const value = new vm.Script(`(${source})`, {
    filename: "shard-document.js",
  }).runInContext(context, { timeout: 1_000 });

  if (!value || Array.isArray(value) || typeof value !== "object") {
    throw codedError("invalid_document", "A MongoDB document must be an object.");
  }
  return value;
}

function createDatabaseFacade(database, options) {
  const methods = {
    getCollection: (name) => createCollectionFacade(database.collection(name), options),
    getCollectionNames: () => listCollections(database.databaseName),
    getName: () => database.databaseName,
    getSiblingDB: (name) => createDatabaseFacade(client.db(name), options),
    runCommand: (command) => database.command(command),
    stats: () => database.stats(),
  };

  return new Proxy(methods, {
    get(target, property) {
      if (property in target) {
        return target[property];
      }
      if (typeof property === "string" && !property.startsWith("_")) {
        return createCollectionFacade(database.collection(property), options);
      }
      return undefined;
    },
  });
}

function createCollectionFacade(collection, options) {
  const write = (name, operation) => (...args) => {
    if (options.explain) {
      throw codedError(
        "explain_unsupported",
        `Explain cannot run the write operation ${name}.`,
      );
    }
    return operation(...args);
  };

  return {
    aggregate: (pipeline = [], aggregateOptions = {}) =>
      new CursorFacade(collection.aggregate(pipeline, aggregateOptions), options),
    countDocuments: (filter = {}, countOptions = {}) =>
      collection.countDocuments(normalizeIdFilter(filter), countOptions),
    deleteMany: write("deleteMany", (filter = {}, deleteOptions = {}) =>
      collection.deleteMany(normalizeIdFilter(filter), deleteOptions)),
    deleteOne: write("deleteOne", (filter = {}, deleteOptions = {}) =>
      collection.deleteOne(normalizeIdFilter(filter), deleteOptions)),
    distinct: (field, filter = {}, distinctOptions = {}) =>
      collection.distinct(field, filter, distinctOptions),
    drop: write("drop", () => collection.drop()),
    find: (filter = {}, findOptions = {}) =>
      new CursorFacade(collection.find(normalizeIdFilter(filter), findOptions), options),
    findOne: (filter = {}, findOptions = {}) =>
      collection.findOne(normalizeIdFilter(filter), findOptions),
    insertMany: write("insertMany", (documents, insertOptions = {}) =>
      collection.insertMany(documents, insertOptions)),
    insertOne: write("insertOne", (document, insertOptions = {}) =>
      collection.insertOne(document, insertOptions)),
    replaceOne: write("replaceOne", (filter, replacement, replaceOptions = {}) =>
      collection.replaceOne(normalizeIdFilter(filter), replacement, replaceOptions)),
    updateMany: write("updateMany", (filter, update, updateOptions = {}) =>
      collection.updateMany(normalizeIdFilter(filter), update, updateOptions)),
    updateOne: write("updateOne", (filter, update, updateOptions = {}) =>
      collection.updateOne(normalizeIdFilter(filter), update, updateOptions)),
  };
}

function normalizeIdFilter(filter) {
  if (!filter || Array.isArray(filter) || typeof filter !== "object") {
    return filter;
  }

  const normalized = { ...filter };
  if (typeof normalized._id === "string" && /^[a-f\d]{24}$/i.test(normalized._id)) {
    normalized._id = { $in: [normalized._id, new BSON.ObjectId(normalized._id)] };
  }
  for (const operator of ["$and", "$or", "$nor"]) {
    if (Array.isArray(normalized[operator])) {
      normalized[operator] = normalized[operator].map(normalizeIdFilter);
    }
  }
  return normalized;
}

class CursorFacade {
  constructor(cursor, options) {
    this.cursor = cursor;
    this.options = options;
  }

  batchSize(value) {
    this.cursor.batchSize(value);
    return this;
  }

  hint(value) {
    this.cursor.hint(value);
    return this;
  }

  limit(value) {
    this.cursor.limit(value);
    return this;
  }

  project(value) {
    this.cursor.project(value);
    return this;
  }

  skip(value) {
    this.cursor.skip(value);
    return this;
  }

  sort(value) {
    this.cursor.sort(value);
    return this;
  }

  async explain(verbosity = "executionStats") {
    return this.cursor.explain(verbosity);
  }

  async toArray() {
    if (this.options.explain) {
      return this.explain();
    }
    return readCursorPage(this.cursor, this.options.batchSize);
  }

  then(resolve, reject) {
    return this.toArray().then(resolve, reject);
  }
}

async function readCursorPage(cursor, batchSize) {
  const documents = [];
  while (documents.length < batchSize && await cursor.hasNext()) {
    documents.push(await cursor.next());
  }
  const hasMore = await cursor.hasNext();
  if (!hasMore) {
    await cursor.close();
    return { documents, cursorId: null, hasMore: false };
  }
  const cursorId = randomUUID();
  cursors.set(cursorId, cursor);
  return { documents, cursorId, hasMore: true };
}

async function fetchCursorPage(payload) {
  const cursorId = requiredString(payload.cursorId, "cursorId");
  const cursor = cursors.get(cursorId);
  if (!cursor) {
    throw codedError("cursor_not_found", "The result cursor has expired.");
  }
  cursors.delete(cursorId);
  return readCursorPage(cursor, positiveInteger(payload.batchSize, 50));
}

function requireDatabase(name = selectedDatabase) {
  if (!client) {
    throw codedError("not_connected", "Connect to a MongoDB server first.");
  }
  return client.db(name);
}

function buildConnectionURI(profile) {
  if (
    typeof profile.connectionString === "string"
    && /^mongodb(?:\+srv)?:\/\//i.test(profile.connectionString)
  ) {
    return profile.connectionString;
  }
  const host = String(profile.host || "localhost");
  const encodedHost = host.includes(":") && !host.startsWith("[") ? `[${host}]` : host;
  const database = encodeURIComponent(profile.defaultDatabase || "test");
  return `mongodb://${encodedHost}:${positiveInteger(profile.port, 27017)}/${database}`;
}

function buildClientOptions(profile, password, tlsCertificatePassphrase) {
  const options = {
    appName: "Shard",
    directConnection: Boolean(profile.directConnection),
  };
  if (profile.username) {
    options.auth = {
      username: profile.username,
      password: password || "",
    };
  }
  if (profile.authenticationDatabase) {
    options.authSource = profile.authenticationDatabase;
  }
  if (profile.authentication === "scramSHA1") {
    options.authMechanism = "SCRAM-SHA-1";
  } else if (profile.authentication === "scramSHA256") {
    options.authMechanism = "SCRAM-SHA-256";
  } else if (profile.authentication === "x509") {
    options.authMechanism = "MONGODB-X509";
  }
  if (profile.replicaSet) {
    options.replicaSet = profile.replicaSet;
  }
  if (profile.tls?.enabled) {
    options.tls = true;
    options.tlsCAFile = profile.tls.caFile || undefined;
    options.tlsCertificateKeyFile = profile.tls.certificateKeyFile || undefined;
    options.tlsCertificateKeyFilePassword = tlsCertificatePassphrase || undefined;
    options.tlsAllowInvalidCertificates = Boolean(profile.tls.allowInvalidCertificates);
    options.tlsAllowInvalidHostnames = Boolean(profile.tls.allowInvalidHostnames);
  }
  return options;
}

async function closeClient() {
  const openCursors = [...cursors.values()];
  cursors.clear();
  await Promise.allSettled(openCursors.map((cursor) => cursor.close()));
  if (!client) {
    return;
  }
  const existing = client;
  client = undefined;
  await existing.close(true);
}

function serialize(value) {
  if (mockMode) {
    return value === undefined ? null : value;
  }
  return value === undefined
    ? null
    : EJSON.serialize(value, { relaxed: false });
}

function writeResponse(id, result) {
  process.stdout.write(
    `${JSON.stringify({ protocolVersion: PROTOCOL_VERSION, id, result })}\n`,
  );
}

function writeError(id, code, message, retryable = false) {
  process.stdout.write(
    `${JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      id,
      error: {
        code,
        message: redact(message),
        retryable,
        connected: Boolean(client),
      },
    })}\n`,
  );
}

function redact(value) {
  return String(value)
    .replace(/mongodb(?:\+srv)?:\/\/([^:@/\s]+):([^@/\s]+)@/gi, "mongodb://$1:••••@")
    .replace(/(password|passphrase)([\"'=:\s]+)[^,\s}\"']+/gi, "$1$2••••");
}

function requiredString(value, name) {
  if (typeof value !== "string" || !value.trim()) {
    throw codedError("invalid_request", `${name} must be a non-empty string.`);
  }
  return value;
}

function positiveInteger(value, fallback) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function stripTrailingSemicolons(value) {
  return value.replace(/;+\s*$/, "");
}

function codedError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function handleMock(operation, payload) {
  switch (operation) {
    case "connect":
      return { connected: true, serverVersion: "8.0.0-mock" };
    case "disconnect":
      return { connected: false };
    case "ping":
      return { ok: 1 };
    case "listDatabases":
      return ["admin", "config", "sample_mflix"];
    case "listCollections":
      return payload.database === "sample_mflix"
        ? ["comments", "movies", "users"]
        : [];
    case "listIndexes":
      return [
        {
          name: "_id_",
          keys: [{ field: "_id", direction: "1" }],
          unique: false,
          sparse: false,
        },
        {
          name: "title_1",
          keys: [{ field: "title", direction: "1" }],
          unique: false,
          sparse: false,
        },
      ];
    case "sampleSchema":
      return [
        {
          path: "_id",
          types: ["ObjectId"],
          elementTypes: [],
          indexNames: ["_id_"],
        },
        {
          path: "createdAt",
          types: ["Date"],
          elementTypes: [],
          indexNames: ["createdAt_1"],
        },
        {
          path: "title",
          types: ["String"],
          elementTypes: [],
          indexNames: ["title_1"],
        },
      ];
    case "createIndex":
      return { name: `${payload.keys?.[0]?.field ?? "field"}_1` };
    case "dropIndex":
      return { dropped: true };
    case "autocomplete":
      return [
        "db.getCollectionNames()",
        "db.getCollection(\"movies\")",
        ".aggregate([])",
        ".find({})",
        "ObjectId()",
        "$match",
      ].filter((choice) => choice.startsWith(String(payload.prefix ?? "")));
    case "parseShellDocument":
      return payload.source ? { parsed: true } : {};
    case "execute":
      return {
        documents: [
          {
            _id: { $oid: "507f1f77bcf86cd799439011" },
            title: "Shard",
            released: { $date: "2026-07-23T00:00:00.000Z" },
            score: { $numberDecimal: "9.8" },
          },
        ],
        cursorId: "mock-cursor",
        hasMore: true,
      };
    case "explain":
      return {
        queryPlanner: {
          winningPlan: {
            stage: "FETCH",
            inputStage: { stage: "IXSCAN", indexName: "title_1" },
          },
          rejectedPlans: [{ stage: "COLLSCAN" }],
        },
        executionStats: {
          executionTimeMillis: 3,
          nReturned: 1,
          totalDocsExamined: 1,
          totalKeysExamined: 1,
        },
      };
    case "fetchCursorPage":
      return { documents: [], cursorId: null, hasMore: false };
    case "cancel":
      return { cancelled: true };
    default:
      throw codedError("unsupported_operation", `Unsupported operation: ${operation}`);
  }
}
