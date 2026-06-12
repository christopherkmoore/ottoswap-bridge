# ottoswap-bridge

A thin [Windower](https://www.windower.net/) addon that connects FFXI to
**[ottoswap](https://ottoswap.ckmtools.dev)** — share, browse, and analyze your GearSwap sets.

It reads your GearSwap sets (your whole `addons/GearSwap/data` tree), your live equipped
gear, and the equippable items you own, and sends them to ottoswap so the website can show
and analyze your sets. All the analysis runs in your browser; this addon is just the pipe.

<p align="center">
  <a href="https://ottoswap.ckmtools.dev">
    <img src="docs/img/set-detail.png" width="100%"
         alt="ottoswap set editor — equipment viewer, live stat totals, and owned-gear upgrade suggestions">
  </a>
  <br>
  <em>Open any set to see its stat totals and get upgrade suggestions from gear you already own — augments and all.</em>
</p>

<p align="center">
  <img src="docs/img/gallery.png" width="100%"
       alt="ottoswap gallery — every GearSwap set across all your characters and jobs">
  <br>
  <em>Every set across all your characters and jobs, in one place.</em>
</p>

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

Live and in active development. The site ([ottoswap.ckmtools.dev](https://ottoswap.ckmtools.dev))
browses and analyzes your sets today — stat totals, owned-gear upgrade suggestions, augment
decoding, and set sharing via link. The relay runs on `ottoswapapi.ckmtools.dev`. New features
are still landing regularly.

## License

MIT — see [LICENSE](LICENSE).
