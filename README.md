# Wormhole

An addon for **WoW Forever**: find and offer warlock summons and mage portals on the world map.

Built for the Forever client (`_forever_`, interface 16001). It is not made for Retail or Classic.

- **World map tab:** offers per zone, pins for each provider, fees, filters and sorting.
- **Requests:** ask up to three providers at once, auto-retract after 60 seconds.
- **Providers:** set fee, note and destinations, pause while AFK or in instances, auto invite.
- **Clickers:** get called for summon jobs within a chosen range, paid by the warlock.

## Use

- `/wh` opens the setup window.
- `/wh on`, `/wh off` toggles your offer.
- `/wh requests` opens requests or clicker jobs.
- `/wh options` opens the options.
- `/wh test` toggles test mode (act as any service, only other testers see the offer).

## Install

Extract into `Interface/AddOns/` of the `_forever_` client.

## Develop

`luajit tests/spec.lua` from the addon folder runs the simulated multi-client tests.
