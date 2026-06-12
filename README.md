# ottoswap-bridge

A thin [Windower](https://www.windower.net/) addon that connects FFXI to
**[ottoswap](https://ottoswap.ckmtools.dev)** — share, browse, and analyze your GearSwap sets.

It reads your live equipped gear and the equippable items you own, and sends them to
ottoswap so the website can show and analyze your sets. All the analysis runs in your
browser; this addon is just the pipe.

## Safety

This addon **only sends data out.** There is deliberately **no inbound command channel** —
it cannot receive or run any command on your client. It's open source so you can read
exactly what it does (it's one short file: [`ottoswap/ottoswap.lua`](ottoswap/ottoswap.lua)).

What it sends: your equipped gear, the items in your equippable bags (inventory/wardrobes),
and your base stats/skills — keyed to a pairing code you control. Nothing else.

## Install

1. Copy the `ottoswap` folder into your `Windower/addons` directory.
2. In game: `//lua load ottoswap`
3. Get a pairing code from [ottoswap.ckmtools.dev](https://ottoswap.ckmtools.dev) and run:
   `//ottoswap setup <pairing-code>`

To load it automatically, add `lua load ottoswap` to your Windower `scripts/init.txt`.

## Commands

| Command | Description |
|---|---|
| `//ottoswap setup <code>` | Pair with the website using a code from ottoswap |
| `//ottoswap push` | Push your current gear now |
| `//ottoswap status` | Show pairing status |
| `//ottoswap endpoint <url>` | Override the relay endpoint (advanced) |

## Requirements

Windower 4 with LuaSec (`ssl.https`) available — the standard install includes it.

## Status

Early development. The hosted relay is being stood up; until then the addon is functional
but has nothing to talk to. GearSwap set-definition import is the next addition.

## License

MIT — see [LICENSE](LICENSE).
