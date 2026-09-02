#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DEVICES=([REDACTED_DEVICE_ALIAS] [REDACTED_DEVICE_ALIAS] [REDACTED_DEVICE_ALIAS])

for device in "${DEVICES[@]}"; do
  "${REPO_ROOT}/myconf/${device}/scripts/verify.sh"
done

REPO_ROOT="$REPO_ROOT" node <<'NODE'
const fs = require('fs');
const path = require('path');

const root = process.env.REPO_ROOT;
const devices = ['[REDACTED_DEVICE_ALIAS]', '[REDACTED_DEVICE_ALIAS]', '[REDACTED_DEVICE_ALIAS]'];
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
  'scripts/verify.sh'
];
const phoneOnlyFiles = ['android/provision-unlock-pin.sh', 'regery/domain.json'];

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
  if (device !== '[REDACTED_DEVICE_ALIAS]') {
    for (const relative of phoneOnlyFiles) {
      if (!fs.existsSync(path.join(deviceRoot, relative))) fail(`${device} is missing phone-only file ${relative}`);
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
  const expectedToolPermissions = device === '[REDACTED_DEVICE_ALIAS]'
    ? `--es tool_permissions '{"disabledTools":[],"disabledParams":{}}'`
    : `--es tool_permissions "'{\\"disabledTools\\":[],\\"disabledParams\\":{}}'"`;
  if (!applyScript.includes(expectedToolPermissions)) {
    fail(`${device}/android/apply-config.sh must use ToolPermissionsConfig JSON field names`);
  }
  const expectedEmptyTunnelArgs = device === '[REDACTED_DEVICE_ALIAS]'
    ? `--es cloudflare_tunnel_extra_args ""`
    : `--es cloudflare_tunnel_extra_args "''"`;
  if (!applyScript.includes(expectedEmptyTunnelArgs)) {
    fail(`${device}/android/apply-config.sh must restore empty Cloudflare extra arguments explicitly`);
  }
  const expectedSlug = device === '[REDACTED_DEVICE_ALIAS]' ? `--es device_slug "[REDACTED_DEVICE_ALIAS]"` : `--es device_slug "''"`;
  if (!applyScript.includes(expectedSlug)) {
    fail(`${device}/android/apply-config.sh must preserve its device slug through adb shell quoting`);
  }
  if (!applyScript.includes('adb_shell_stdin am broadcast') ||
      applyScript.includes('"${ADB[@]}" shell am broadcast')) {
    fail(`${device}/android/apply-config.sh must keep configuration secrets out of the adb shell command line`);
  }
  if (androidConfig.remote_access?.cloudflare?.extra_arguments !== '') {
    fail(`${device}/android/config.json must not use the broken token-mode --edge workaround`);
  }
  if (device === '[REDACTED_DEVICE_ALIAS]') {
    for (const forbidden of ['settings put secure', 'enabled_accessibility_services', 'allow_listener',
      'pm grant', 'Shizuku', 'ngrok', '_PIN']) {
      if (applyScript.toLowerCase().includes(forbidden.toLowerCase())) {
        fail(`[REDACTED_DEVICE_ALIAS]/android/apply-config.sh contains forbidden provisioning behavior: ${forbidden}`);
      }
    }
    continue;
  }
  const unlockScript = fs.readFileSync(path.join(deviceRoot, 'android/provision-unlock-pin.sh'), 'utf8');
  if (!unlockScript.includes('--extra "key_version:s:${key_version}"') ||
      !unlockScript.includes('--extra "ciphertext:s:${ciphertext}"')) {
    fail(`${device}/android/provision-unlock-pin.sh must use content-call KEY:TYPE:VALUE extras`);
  }
  if (unlockScript.includes('s:key_version:') || unlockScript.includes('s:ciphertext:')) {
    fail(`${device}/android/provision-unlock-pin.sh contains reversed content-call extra syntax`);
  }
  if (!unlockScript.includes('configured=true')) {
    fail(`${device}/android/provision-unlock-pin.sh must verify that provisioning was persisted`);
  }
  if (!unlockScript.includes('CredentialType:[[:space:]]+PIN') ||
      !unlockScript.includes('require_pin_screen_lock || exit 1')) {
    fail(`${device}/android/provision-unlock-pin.sh must reject non-PIN Android screen locks`);
  }
}

if (!fs.existsSync(path.join(root, 'myconf/[REDACTED_DEVICE_ALIAS]/ngrok/account.json')) ||
    !fs.existsSync(path.join(root, 'myconf/[REDACTED_DEVICE_ALIAS]/ngrok/ngrok.yml'))) {
  fail('[REDACTED_DEVICE_ALIAS] must retain its documented ngrok fallback files');
}
if (fs.existsSync(path.join(root, 'myconf/[REDACTED_DEVICE_ALIAS]/ngrok'))) {
  fail('[REDACTED_DEVICE_ALIAS] must remain Cloudflare-only and must not contain an ngrok directory');
}
if (fs.existsSync(path.join(root, 'myconf/[REDACTED_DEVICE_ALIAS]/ngrok')) ||
    fs.existsSync(path.join(root, 'myconf/[REDACTED_DEVICE_ALIAS]/android/provision-unlock-pin.sh'))) {
  fail('[REDACTED_DEVICE_ALIAS] must remain Cloudflare-only without phone PIN provisioning');
}

if (!process.exitCode) {
  console.log('OK: [REDACTED_DEVICE_ALIAS], [REDACTED_DEVICE_ALIAS] and [REDACTED_DEVICE_ALIAS] follow their declared device-configuration contracts.');
  console.log('OK: [REDACTED_DEVICE_ALIAS] has optional ngrok; [REDACTED_DEVICE_ALIAS] and [REDACTED_DEVICE_ALIAS] are Cloudflare-only.');
  console.log('OK: all devices restore tool permissions and empty ADB values safely.');
  console.log('OK: all devices send configuration broadcasts through adb shell stdin.');
  console.log('OK: no device uses the broken token-mode --edge workaround.');
  console.log('OK: both PIN provisioning scripts validate Android content-call persistence.');
  console.log('OK: both PIN provisioning scripts reject pattern and password screen locks.');
  console.log('OK: [REDACTED_DEVICE_ALIAS] has no permission, PIN, Shizuku or ngrok provisioning side effects.');
}
NODE
