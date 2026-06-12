# ottoswap-bridge

A thin [Windower](https://www.windower.net/) addon that connects FFXI to
**[ottoswap](https://ottoswap.ckmtools.dev)** — share, browse, and analyze your GearSwap sets.

It reads your GearSwap sets (your whole `addons/GearSwap/data` tree), your live equipped
gear, and the equippable items you own, and sends them to ottoswap so the website can show
and analyze your sets. All the analysis runs in your browser; this addon is just the pipe.

## Safety

This addon **only sends data out.** There is deliberately **no inbound command channel** —
it cannot receive or run any command on your client. It's open source so you can read
exactly what it does (it's one short file:
[`ottoswap-bridge/ottoswap-bridge.lua`](ottoswap-bridge/ottoswap-bridge.lua)).

What it sends: your GearSwap data files (read-only), your equipped gear, the items in your
equippable bags (inventory/wardrobes), and your base stats/skills — keyed to a pairing code
you control. Nothing else.

## Install

1. Copy the `ottoswap-bridge` folder into your `Windower/addons` directory.
2. In game: `//lua load ottoswap-bridge`
3. Get a pairing code from [ottoswap.ckmtools.dev](https://ottoswap.ckmtools.dev) and run:
   `//ottoswap setup <pairing-code>`

To load it automatically, add `lua load ottoswap-bridge` to your Windower `scripts/init.txt`.

## Commands

| Command | Description |
|---|---|
| `//ottoswap setup <code>` | Pair with the website using a code from ottoswap |
| `//ottoswap code` | Show your pairing code + a link to pair another device |
| `//ottoswap push` | Push your current gear now |
| `//ottoswap status` | Show pairing status (incl. your code) |
| `//ottoswap endpoint <url>` | Override the relay endpoint (advanced) |

Your pairing **persists across sessions** — set up once and the bridge keeps pushing while
you play. Forgot your code? Run `//ottoswap code`, or open
`your-ottoswap-code.txt` in the addon folder. The pairing code works on **any device or
network** — open the link it gives you on your phone/laptop to pair it there too.

## Requirements

Windower 4 with LuaSec (`ssl.https`) available — the standard install includes it.

## Status

Early development. The relay is live at `ottoswapapi.ckmtools.dev`. The addon reads and
pushes the GearSwap data tree (`/sets`) and live gear (`/push`); the web client that
consumes them is still being built.

## License

MIT — see [LICENSE](LICENSE).
