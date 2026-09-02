#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

function fail(message) {
  throw new Error(message);
}

export function loadNativeTunnelContract(repoRoot) {
  const contractPath = path.join(repoRoot, "config/arcp-native-payloads.json");
  if (!fs.statSync(contractPath, { throwIfNoEntry: false })?.isFile()) {
    fail("native tunnel payload contract is missing");
  }
  const raw = fs.readFileSync(contractPath, "utf8");
  const contract = JSON.parse(raw);
  if (
    contract.schema_version !== 1 ||
    !/^android-tunnels-v[1-9][0-9]*$/.test(contract.contract_version ?? "") ||
    contract.toolchain?.go_version !== "1.26.7" ||
    contract.toolchain?.android_ndk_version !== "27.2.12479018" ||
    contract.toolchain?.android_api !== 21 ||
    contract.forbid_unlisted_tunnel_payloads !== true
  ) {
    fail("native tunnel payload contract metadata is invalid");
  }
  const expectedLibraries = new Set(["libcloudflared.so", "libngrok_java.so"]);
  if (Object.keys(contract.libraries ?? {}).length !== expectedLibraries.size) {
    fail("native tunnel library set is invalid");
  }
  const entries = [];
  for (const [library, definition] of Object.entries(contract.libraries ?? {})) {
    if (!expectedLibraries.delete(library) || !Array.isArray(definition.required_abis)) {
      fail(`native tunnel library definition is invalid: ${library}`);
    }
    if (definition.required_abis.length === 0 || new Set(definition.required_abis).size !== definition.required_abis.length) {
      fail(`native tunnel ABI list is empty or duplicated: ${library}`);
    }
    for (const abi of definition.required_abis) {
      if (!/^[A-Za-z0-9_-]+$/.test(abi)) fail(`invalid native tunnel ABI: ${abi}`);
      entries.push(`lib/${abi}/${library}`);
    }
  }
  if (expectedLibraries.size !== 0) fail("native tunnel library set is incomplete");

  const required = entries.sort();
  const expected = [
    "lib/arm64-v8a/libcloudflared.so",
    "lib/arm64-v8a/libngrok_java.so",
    "lib/armeabi-v7a/libcloudflared.so",
    "lib/x86_64/libcloudflared.so",
    "lib/x86_64/libngrok_java.so",
  ];
  if (JSON.stringify(required) !== JSON.stringify(expected)) {
    fail("native tunnel payload matrix differs from the reviewed asymmetric contract");
  }
  return { contract, raw, required };
}

export function nativeTunnelContractDigest(repoRoot) {
  const { contract } = loadNativeTunnelContract(repoRoot);
  return crypto.createHash("sha256").update(JSON.stringify(contract)).digest("hex");
}

export function validateNativeTunnelEntries(repoRoot, apkEntries) {
  const { required } = loadNativeTunnelContract(repoRoot);
  const actual = new Set(apkEntries.filter(Boolean));
  for (const entry of required) {
    if (!actual.has(entry)) fail(`APK is missing required tunnel payload: ${entry}`);
  }
  const tunnelName = /\/(libcloudflared\.so|libngrok_java\.so)$/;
  for (const entry of actual) {
    if (entry.startsWith("lib/") && tunnelName.test(entry) && !required.includes(entry)) {
      fail(`APK contains unsupported tunnel payload: ${entry}`);
    }
  }
}

async function main() {
  const [repoRoot, command] = process.argv.slice(2);
  if (!repoRoot || !["required", "hash", "summary", "validate"].includes(command)) {
    fail("usage: native-tunnel-payloads.mjs <repo-root> <required|hash|summary|validate>");
  }
  const loaded = loadNativeTunnelContract(repoRoot);
  if (command === "required") {
    process.stdout.write(`${loaded.required.join("\n")}\n`);
  } else if (command === "hash") {
    process.stdout.write(`${nativeTunnelContractDigest(repoRoot)}\n`);
  } else if (command === "summary") {
    process.stdout.write(`${JSON.stringify({
      schema_version: loaded.contract.schema_version,
      contract_version: loaded.contract.contract_version,
      contract_sha256: nativeTunnelContractDigest(repoRoot),
      toolchain: loaded.contract.toolchain,
      required_payloads: loaded.required,
    })}\n`);
  } else {
    const input = await new Promise((resolve, reject) => {
      let data = "";
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", (chunk) => { data += chunk; });
      process.stdin.on("end", () => resolve(data));
      process.stdin.on("error", reject);
    });
    validateNativeTunnelEntries(repoRoot, input.split(/\r?\n/));
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exit(1);
  });
}
