# Pairing

How the devices on one Apple ID come to know each other. The records here live beside the turn log and the lease in the private CloudKit database, container `iCloud.zone.hexagon.topo`, custom zone `Topo`; Womble set those names first and every bundle uses them. The code is `Device`, `PairingCode` and `DeviceDirectory` in `Packages/TopoCore`, tested against the in-memory database like the rest of the package.

## The device record

Every bundle that runs the client or the hub writes one record about itself at every launch, type `Device`, name `device/<id>`:

| Field | Holds |
| ----- | ----- |
| `name` | What the person calls it: "Sam's Mac mini", "iPhone" |
| `kind` | `mac`, `phone`, `pad`, `watch`, `tv`, `womble` |
| `publicKey` | Base64 of the device's Curve25519 public key, made once and kept in its keychain, for the tunnel layer |
| `endpoints` | Where it answers on the LAN, `host:port`, newest first |
| `pairedWith` | Device IDs it is paired with |
| `registeredAt` | First launch against this database |
| `seenAt` | Last launch or refresh |

The ID is made once per install and kept in the keychain (`mac-<uuid>` on the hub). The record is created if absent and otherwise updated with the current name, kind, key, endpoints and `seenAt`; `pairedWith` and `registeredAt` survive the update. Roles are not stored: primary is whoever holds the lease, the hub is the device of kind `mac`, and everything else is a viewer or a limb by what it can do.

Womble writes no record. Its access is the Apple ID it is signed into, which is all a viewer needs to read the log, so it is a reader of these records and not a party to them.

## The code on the hub's screen

The hub shows a QR code carrying `topo://pair?v=1&d=<id>&n=<name>&k=<publicKey>&e=<endpoint>`. `d` and `k` are required; `n` defaults to the ID and `e` is the first LAN endpoint, offered so the scanner can reach the hub without waiting for a query.

The phone scans it and runs the scanner's half, `DeviceDirectory.pair(_:as:)`:

1. Fetch `device/<d>` by ID. Absent means the hub has not launched against this Apple ID, or its launch has not landed yet: `unknownDevice`.
2. Require the record's `publicKey` to equal `k`. The code is on a screen in the room; the record is in iCloud. Agreement between the two is what the scan proves. A mismatch is `keyMismatch` and nothing is written.
3. Add `d` to the phone's own `pairedWith`, and the phone's ID to the hub's, each by compare-and-set on the record's change tag, retried while it moves. Two phones scanning at once both land.

Pairing is symmetric and idempotent: scanning the same code again changes nothing. A device does not pair with itself. There is no unpairing yet; removing an ID from both `pairedWith` lists is all it would take.

## What the hub shows

The hub lists every device record: paired with this Mac or not, when it was last seen, whether it is on this network now (a Bonjour browse for `_topo._tcp`, whose service names are device IDs), and which one holds the primary lease. Presence is a browse result and not a record: the directory says who is paired, the network says who is reachable. On macOS the browse and the advert both need the app to be allowed on the local network; until it is, the hub says so in the list, and the lease and its probe still work over the address the record names.

## What the QR does not do

It is not a credential. Every device on the Apple ID can already read and write these records; the scan records consent and proximity, and pins the key that the tunnel layer will use, so a record written by something else on the account cannot pass for the hub. Viewers never hold the Claude login; pairing does not move it.
