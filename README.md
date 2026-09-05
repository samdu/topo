# Topo

Topo is one always-on mind per person, with every Apple device you own as a limb of it. The mind is an agent running on a Mac in your house (or, with no Mac, on the phone itself); your iPhone, iPad, watch, TV and the old iPad in the drawer are its arms: they carry the microphone, the screen, the notifications and the sensors, and they share one transcript through your own iCloud account, so nothing of yours passes through a server we run. It is open source under the GPL and not for profit; the whole design is in [docs/design.md](docs/design.md). The name is Aquaman's octopus sidekick Topo, first seen in Adventure Comics #229 (1956), written by Jack Miller and drawn by Ramona Fradon: the product is the octopus, the mind is the head, and every device is an arm.

## Building

`Packages/TopoCore` is the transcript log, the primary lease and the device directory, a Swift package with no UI; `Packages/TopoLink` is the socket layer the lease probes over. `swift test` in either directory runs its tests against an in-memory database and loopback sockets; nothing needs a signed-in device or a CloudKit container.
