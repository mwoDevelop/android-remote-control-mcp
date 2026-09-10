# Verified app activation (owner extension)

`open_app` retains its package ID input, configured name prefix and existing
per-tool permission gate. Accepting a launch intent is not proof that Android
displayed the requested application. The owner handler composes the upstream
`AppManager` operation with a read-only accessibility postcondition:

- `foreground_confirmed`: the fresh active window belongs to the target package.
- `launch_requested_unconfirmed`: Android accepted the launch request, but the
  target was not observed within 3 seconds or accessibility was unavailable.
  This is not a claim that launch failed. Read the screen before acting again;
  do not automatically repeat a potentially successful launch.
- A rejected launch (for example, a package without a launchable activity) still
  raises the original MCP action error. Cancellation is propagated.

Observation polls every 150 ms. It does not require Shizuku, dismiss a lock
screen, change an OEM permission, bypass parental controls or grant access.
Slow loading, overlays and background-start restrictions can all prevent timely
confirmation; the status alone does not distinguish their root cause.

## OEM background-start policy

On HyperOS, inspect the per-app **Open new windows while running in the
background** permission when Android logs an aborted background activity start.
The [Xiaomi developer documentation](https://dev.mi.com/xiaomihyperos/documentation/detail?pId=1625)
describes this separate policy. An enabled accessibility service or a foreground
MCP service is not, on its own, proof that an OEM will permit activity launches.
The local administrator should grant only the permission needed for the intended
ARCP operation; do not globally enable overlays, lock-screen access or debugging
to make a diagnostic test pass. Device-specific provisioning and evidence stay
in the private configuration repository. This handler only observes the result;
it never modifies Android/OEM policy itself.

## Upstream integration boundary

Implementation and tests are under the fork-owned
`com.mwodevelop.androidremotecontrolmcp.apps` namespace. The upstream
`AppManagerImpl` and `OpenAppHandler` classes are unchanged. The only composition
seam replaces the open-app handler registration in `registerAppManagementTools`;
other application tools retain their existing handlers.

When updating upstream, preserve that registration, compare the input schema
and permission key, and run the owner verifier tests plus upstream application
manager and integration tests. An upstream registration signature change needs
review of this one seam; OCP reduces, but cannot guarantee the absence of,
future merge conflicts. This source change must be promoted through the normal
owner channel workflow before a published stable/edge release includes it.

Unit coverage includes immediate/delayed confirmation, timeout, unavailable
accessibility, null root, invalid package, blank input and parent cancellation.
Device-specific deployment results belong only in the private operations repo.
