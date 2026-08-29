#!/usr/bin/env node

import { spawnSync } from "node:child_process";

const [analyzer, apk] = process.argv.slice(2);
if (!analyzer || !apk) {
  console.error("Usage: verify-admin-ui-manifest.mjs <apkanalyzer> <apk>");
  process.exit(2);
}

const result = spawnSync(analyzer, ["manifest", "print", apk], { encoding: "utf8" });
if (result.status !== 0) {
  console.error(result.stderr || "apkanalyzer manifest print failed");
  process.exit(1);
}

const manifest = result.stdout;
const requireMatch = (condition, message) => {
  if (!condition) throw new Error(message);
};
const count = (pattern) => [...manifest.matchAll(pattern)].length;
const componentTag = (tag, className) => {
  const pattern = new RegExp(`<${tag}\\b(?=[^>]*android:name="${className.replaceAll(".", "\\.")}")[^>]*>`, "m");
  return manifest.match(pattern)?.[0] ?? "";
};

try {
  requireMatch(
    /<uses-permission\b[^>]*android:name="android\.permission\.USE_BIOMETRIC"/m.test(manifest),
    "merged manifest does not request USE_BIOMETRIC",
  );
  requireMatch(
    !/<uses-permission\b[^>]*android:name="android\.permission\.DUMP"/m.test(manifest),
    "application must not request the privileged DUMP permission",
  );
  requireMatch(count(/android:name="android\.intent\.category\.LAUNCHER"/g) === 2, "expected exactly two launcher entries");
  requireMatch(count(/android:name="android\.intent\.action\.MAIN"/g) === 2, "expected exactly two MAIN entries");

  const activityName = "com.mwodevelop.androidremotecontrol.shizukuadmin.RemoteUnlockAdminActivity";
  const activityTag = componentTag("activity", activityName);
  requireMatch(activityTag, "administrator activity is absent from the merged manifest");
  requireMatch(activityTag.includes('android:exported="true"'), "administrator activity must be exported for launcher use");

  const providerName =
    "com.danielealbano.androidremotecontrolmcp.security.remoteunlock.RemoteUnlockProvisioningProvider";
  const providerTag = componentTag("provider", providerName);
  requireMatch(providerTag, "remote-unlock provider is absent from the merged manifest");
  requireMatch(providerTag.includes('android:exported="true"'), "remote-unlock provider must remain ADB reachable");
  requireMatch(
    providerTag.includes('android:permission="android.permission.DUMP"'),
    "remote-unlock provider must remain protected by DUMP",
  );

  console.log("OK: merged APK manifest contains the isolated biometric administrator launcher and protected provider.");
} catch (error) {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
}
