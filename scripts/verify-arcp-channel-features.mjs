#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const [repoRoot, channel, outputMode = "summary"] = process.argv.slice(2);

function fail(message) {
  process.stderr.write(`ERROR: ${message}\n`);
  process.exit(1);
}

if (!repoRoot || !["stable", "edge"].includes(channel)) {
  fail("usage: verify-arcp-channel-features.mjs <repo-root> <stable|edge> [summary|hash]");
}

const ledgerPath = path.join(repoRoot, "config/arcp-channel-features.json");
if (!fs.existsSync(ledgerPath)) fail("feature ledger is missing");

const raw = fs.readFileSync(ledgerPath, "utf8");
const ledger = JSON.parse(raw);
if (ledger.schema_version !== 1) fail("unsupported feature ledger schema");
if (!ledger.required_channels?.includes(channel)) fail(`channel ${channel} is not required by the ledger`);

const requiredPaths = [];
for (const feature of ledger.features ?? []) {
  if (!feature.id || !feature.canonical_commit || !feature.implementation) {
    fail("feature entry is incomplete");
  }
  requiredPaths.push([feature.id, feature.implementation]);
  for (const test of feature.tests ?? []) requiredPaths.push([`${feature.id} test`, test]);
}

const adapter = ledger.channel_adapters?.[channel];
if (!adapter?.implementation || !adapter?.common_context) fail(`channel ${channel} adapter is incomplete`);
requiredPaths.push([`${channel} adapter`, adapter.implementation]);
requiredPaths.push(["common request context", adapter.common_context]);

for (const [label, relativePath] of requiredPaths) {
  const absolutePath = path.resolve(repoRoot, relativePath);
  if (!absolutePath.startsWith(`${path.resolve(repoRoot)}${path.sep}`)) fail(`unsafe path for ${label}`);
  const stat = fs.statSync(absolutePath, { throwIfNoEntry: false });
  if (!stat?.isFile()) fail(`${label} is missing: ${relativePath}`);
}

const normalized = JSON.stringify(ledger);
const digest = crypto.createHash("sha256").update(normalized).digest("hex");
if (outputMode === "hash") {
  process.stdout.write(`${digest}\n`);
} else if (outputMode === "summary") {
  process.stdout.write(
    JSON.stringify({
      schema_version: ledger.schema_version,
      channel,
      feature_count: ledger.features.length,
      adapter: adapter.upstream_transport,
      contract_sha256: digest,
    }) + "\n",
  );
} else {
  fail(`unknown output mode: ${outputMode}`);
}
