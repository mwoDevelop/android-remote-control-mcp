#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const rootArg = process.argv[2];
const selected = process.argv[3];

function fail(message) {
  console.error(`ERROR: ${message}`);
  process.exit(1);
}

if (!rootArg || !path.isAbsolute(rootArg)) fail('configuration root must be an absolute directory');
let root;
try {
  if (fs.lstatSync(rootArg).isSymbolicLink()) fail('configuration root must not be a symlink');
  root = fs.realpathSync(rootArg);
  if (!fs.statSync(root).isDirectory()) fail('configuration root is not a directory');
} catch {
  fail('configuration root is unavailable');
}

const profileName = /^[a-z][a-z0-9-]{0,31}$/;
const packageName = /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/;
const envName = /^[A-Z][A-Z0-9_]*$/;
const exactKeys = (value, allowed, label) => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${label} must be an object`);
  const unknown = Object.keys(value).filter(key => !allowed.includes(key));
  if (unknown.length) fail(`${label} has unknown fields`);
};

function contained(relative, profileRoot, label, mustExist) {
  if (typeof relative !== 'string' || !relative || path.isAbsolute(relative) || relative.includes('\0')) {
    fail(`${label} must be a non-empty relative path`);
  }
  const lexical = path.resolve(profileRoot, relative);
  if (lexical !== profileRoot && !lexical.startsWith(`${profileRoot}${path.sep}`)) fail(`${label} escapes its profile`);
  if (!mustExist && !fs.existsSync(lexical)) return lexical;
  let resolved;
  try {
    if (fs.lstatSync(lexical).isSymbolicLink()) fail(`${label} must not be a symlink`);
    resolved = fs.realpathSync(lexical);
  } catch {
    fail(`${label} is missing`);
  }
  if (resolved !== profileRoot && !resolved.startsWith(`${profileRoot}${path.sep}`)) fail(`${label} escapes its profile`);
  return resolved;
}

let names;
if (selected) {
  if (!profileName.test(selected)) fail('profile name is invalid');
  names = [selected];
} else {
  names = fs.readdirSync(root, {withFileTypes: true})
    .filter(entry => entry.isDirectory() && profileName.test(entry.name) && fs.existsSync(path.join(root, entry.name, 'profile.json')))
    .map(entry => entry.name).sort();
  if (!names.length) fail('configuration root contains no profiles');
}

for (const name of names) {
  const profileRoot = contained(name, root, `profile ${name}`, true);
  const profileFile = contained('profile.json', profileRoot, `${name}/profile.json`, true);
  let profile;
  try { profile = JSON.parse(fs.readFileSync(profileFile, 'utf8')); } catch { fail(`${name}/profile.json is not valid JSON`); }
  exactKeys(profile, ['schema_version', 'name', 'application_id', 'deployment_mode', 'adb_serial_env', 'android_identity', 'capabilities', 'paths'], `${name}/profile.json`);
  if (profile.schema_version !== 1 || profile.name !== name || !profileName.test(profile.name)) fail(`${name} has an invalid schema version or name`);
  if (!packageName.test(profile.application_id)) fail(`${name} has an invalid application ID`);
  if (!['upgrade', 'first_install'].includes(profile.deployment_mode)) fail(`${name} has an invalid deployment mode`);
  if (profile.adb_serial_env !== undefined && !envName.test(profile.adb_serial_env)) fail(`${name} has an invalid ADB serial environment name`);
  exactKeys(profile.android_identity, ['manufacturer', 'model', 'device', 'min_sdk', 'max_sdk', 'abi_any_of'], `${name}.android_identity`);
  for (const key of ['manufacturer', 'model', 'device']) if (typeof profile.android_identity[key] !== 'string' || !profile.android_identity[key]) fail(`${name} has an invalid identity`);
  if (!Number.isInteger(profile.android_identity.min_sdk) || profile.android_identity.min_sdk < 21) fail(`${name} has an invalid minimum SDK`);
  if (profile.android_identity.max_sdk !== undefined && (!Number.isInteger(profile.android_identity.max_sdk) || profile.android_identity.max_sdk < profile.android_identity.min_sdk)) fail(`${name} has an invalid maximum SDK`);
  if (!Array.isArray(profile.android_identity.abi_any_of) || !profile.android_identity.abi_any_of.length || profile.android_identity.abi_any_of.some(v => typeof v !== 'string' || !v)) fail(`${name} has an invalid ABI policy`);
  exactKeys(profile.capabilities, ['fallback_tunnel', 'pin_provisioning', 'first_install', 'require_32bit'], `${name}.capabilities`);
  if (Object.values(profile.capabilities).some(v => typeof v !== 'boolean')) fail(`${name} has a non-boolean capability`);
  if (profile.capabilities.first_install !== (profile.deployment_mode === 'first_install')) fail(`${name} has inconsistent first-install policy`);
  exactKeys(profile.paths, ['android_config', 'apply', 'verify', 'secrets'], `${name}.paths`);
  contained(profile.paths.android_config, profileRoot, `${name}.paths.android_config`, true);
  contained(profile.paths.apply, profileRoot, `${name}.paths.apply`, true);
  contained(profile.paths.verify, profileRoot, `${name}.paths.verify`, true);
  contained(profile.paths.secrets, profileRoot, `${name}.paths.secrets`, false);
}

console.log(`OK: validated ${names.length} external ARCP profile(s).`);
