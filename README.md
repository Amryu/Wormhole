# Wayfarer

Find and offer warlock summons and mage portals in WoW Forever.

- **World map tab:** offers per zone, pins for each provider, fees, filters and sorting.
- **Requests:** ask up to three providers at once, auto-retract after 60 seconds.
- **Providers:** set fee, note and destinations, pause while AFK or in instances, auto invite.
- **Clickers:** get called for summon jobs within a chosen range, paid by the warlock.

## Use

- `/wf` opens the setup window.
- `/wf on`, `/wf off` toggles your offer.
- `/wf requests` opens requests or clicker jobs.
- `/wf options` opens the options.
- `/wf test` toggles test mode (act as any service, only other testers see the offer).

## Install

Extract into `Interface/AddOns/` of the `_forever_` client.

## Develop

`luajit tests/spec.lua` from the addon folder runs the simulated multi-client tests.
