#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DEVICES=([REDACTED_DEVICE_ALIAS] [REDACTED_DEVICE_ALIAS])

for device in "${DEVICES[@]}"; do
  "${REPO_ROOT}/myconf/${device}/scripts/verify.sh"
done

REPO_ROOT="$REPO_ROOT" node <<'NODE'
const fs = require('fs');
const path = require('path');

const root = process.env.REPO_ROOT;
const devices = ['[REDACTED_DEVICE_ALIAS]', '[REDACTED_DEVICE_ALIAS]'];
const commonFiles = [
  '.env.example',
  '.env.secrets',
  'README.md',
  'snapshot.json',
  'android/config.json',
  'android/apply-config.sh',
  'chatgpt/connectors.json',
  'cloudflare/.terraform.lock.hcl',
  'cloudflare/imports.tf',
  'cloudflare/live-snapshot.json',
  'cloudflare/main.tf',
  'cloudflare/outputs.tf',
  'cloudflare/variables.tf',
  'cloudflare/versions.tf',
  'regery/domain.json',
  'scripts/verify.sh'
];

const contracts = {
  'snapshot.json': [
    'schema_version', 'captured_at', 'device', 'provisioning_status',
    'primary_mcp_url', 'fallback_mcp_url', 'remote_access_policy', 'links'
  ],
  'android/config.json': [
    'schema_version', 'captured_at', 'configuration_state', 'device',
    'application', 'runtime_status_at_capture', 'general', 'access', 'https',
    'privacy', 'remote_access', 'mcp_tools', 'android_permissions', 'storage',
    'event_channel'
  ],
  'chatgpt/connectors.json': [
    'schema_version', 'captured_at', 'owner_scope', 'distribution', 'visibility',
    'review_status', 'safety_status', 'apps_privacy_control', 'connectors',
    'non_exportable_secrets', 'restore_method'
  ],
  'cloudflare/live-snapshot.json': [
    'schema_version', 'captured_at', 'account', 'zone', 'dns_records', 'tunnel'
  ],
  'regery/domain.json': [
    'schema_version', 'captured_at', 'account', 'domain', 'restore_method'
  ]
};

function fail(message) {
  console.error(`ERROR: ${message}`);
  process.exitCode = 1;
}

for (const device of devices) {
  const deviceRoot = path.join(root, 'myconf', device);
  for (const relative of commonFiles) {
    if (!fs.existsSync(path.join(deviceRoot, relative))) {
      fail(`${device} is missing common file ${relative}`);
    }
  }

  for (const [relative, requiredKeys] of Object.entries(contracts)) {
    const value = JSON.parse(fs.readFileSync(path.join(deviceRoot, relative), 'utf8'));
    if (value.schema_version !== 1) {
      fail(`${device}/${relative} uses unsupported schema_version`);
    }
    const missing = requiredKeys.filter(key => !Object.hasOwn(value, key));
    if (missing.length) {
      fail(`${device}/${relative} is missing keys: ${missing.join(', ')}`);
    }
  }

  const androidConfig = JSON.parse(
    fs.readFileSync(path.join(deviceRoot, 'android/config.json'), 'utf8')
  );
  const identity = androidConfig.device?.deployment_identity;
  for (const key of ['manufacturer', 'model', 'device']) {
    if (typeof identity?.[key] !== 'string' || !identity[key].trim()) {
      fail(`${device}/android/config.json has invalid device.deployment_identity.${key}`);
    }
  }
  if (androidConfig.device?.alias !== device) {
    fail(`${device}/android/config.json device.alias must equal ${device}`);
  }

  const applyScript = fs.readFileSync(path.join(deviceRoot, 'android/apply-config.sh'), 'utf8');
  if (!applyScript.includes(`--es tool_permissions "'{\\"disabledTools\\":[],\\"disabledParams\\":{}}'"`)) {
    fail(`${device}/android/apply-config.sh must use ToolPermissionsConfig JSON field names`);
  }
  if (!applyScript.includes(`--es cloudflare_tunnel_extra_args "''"`)) {
    fail(`${device}/android/apply-config.sh must restore empty Cloudflare extra arguments explicitly`);
  }
  if (!applyScript.includes(`--es device_slug "''"`)) {
    fail(`${device}/android/apply-config.sh must preserve the empty device slug through adb shell quoting`);
  }
  if (androidConfig.remote_access?.cloudflare?.extra_arguments !== '') {
    fail(`${device}/android/config.json must not use the broken token-mode --edge workaround`);
  }
}

if (!fs.existsSync(path.join(root, 'myconf/[REDACTED_DEVICE_ALIAS]/ngrok/account.json')) ||
    !fs.existsSync(path.join(root, 'myconf/[REDACTED_DEVICE_ALIAS]/ngrok/ngrok.yml'))) {
  fail('[REDACTED_DEVICE_ALIAS] must retain its documented ngrok fallback files');
}
if (fs.existsSync(path.join(root, 'myconf/[REDACTED_DEVICE_ALIAS]/ngrok'))) {
  fail('[REDACTED_DEVICE_ALIAS] must remain Cloudflare-only and must not contain an ngrok directory');
}

if (!process.exitCode) {
  console.log('OK: [REDACTED_DEVICE_ALIAS] and [REDACTED_DEVICE_ALIAS] follow the same device-configuration contract.');
  console.log('OK: [REDACTED_DEVICE_ALIAS] has the optional ngrok extension; [REDACTED_DEVICE_ALIAS] is Cloudflare-only.');
  console.log('OK: both devices restore tool permissions using application JSON field names.');
  console.log('OK: both devices restore empty ADB string values without argument shifting.');
  console.log('OK: neither device uses the broken token-mode --edge workaround.');
}
NODE
