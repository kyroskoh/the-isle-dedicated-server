# Engine.ini reference (The Isle - Evrima)

| Section | Key | Default | server.conf | Status | Description |
|---|---|---|---|---|---|
| `[EpicOnlineServices]` | `DedicatedServerClientId` | public id | `EOS_CLIENT_ID` | core | EOS client used by dedicated servers. Required to appear in the browser |
| `[EpicOnlineServices]` | `DedicatedServerClientSecret` | public secret | `EOS_CLIENT_SECRET` | core | EOS client secret |
| `[/Script/OnlineSubsystemUtils.IpNetDriver]` | `MaxClientRate` | `100000` | (generated) | UE | Max bytes/s per client |
| `[/Script/OnlineSubsystemUtils.IpNetDriver]` | `MaxInternetClientRate` | `100000` | (generated) | UE | Max bytes/s per internet client |
| `[/Script/OnlineSubsystemUtils.IpNetDriver]` | `NetServerMaxTickRate` | engine default | `NET_TICK_RATE` | UE | Server tick rate (Hz). Higher costs more CPU |
| `[/Script/Engine.Player]` | `ConfiguredInternetSpeed` | | override only | UE | Default internet speed for clients (bytes/s) |
| `[/Script/Engine.Player]` | `ConfiguredLanSpeed` | | override only | UE | Default LAN speed (bytes/s) |
| `[Core.Log]` | `LogNet` etc. | | override only | UE | Per-category log verbosity, e.g. `LogNet=Warning` |

Anything else goes in `config/overrides/Engine.ini`. See
[`config/examples/overrides/Engine.ini`](../examples/overrides/Engine.ini).
