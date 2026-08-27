# Third-party notices

## droid-mcp

The Shizuku administration module contains adapted process-launch and foreground-window parsing logic derived from
[`stixez/droid-mcp`](https://github.com/stixez/droid-mcp) commit
`6bb968ea551d9de28e41185412391802f0b3bfc6`, licensed under the Apache License 2.0.

The adapted implementation uses application-owned bounded output handling, timeouts, DTOs, validation and MCP
authorization. No `droid-mcp` binary, HTTP server, MCP server, Ktor dependency or global shell allowlist is packaged.

The complete Apache License 2.0 text distributed with this fork is available at
[`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt). The referenced upstream license is also available in its
[`LICENSE`](https://github.com/stixez/droid-mcp/blob/6bb968ea551d9de28e41185412391802f0b3bfc6/LICENSE) file.
