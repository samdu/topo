# Surfaces on the LAN

A surface is a screen in the house: a Womble on a drawer iPad, a pad on a wall. This is how a hub finds one, and how an agent comes to be answered for by it. Nothing here is a CloudKit record — a Womble writes none — so the network is the whole of it, and a screen that is off is simply not there.

## The advert

Every Womble in the foreground advertises `_topo._tcp`, named by its own device ID (`womble-<uuid>`, made once and kept between launches). A browse of that type is therefore the list of screens in the house, and Topo's other devices are on it too: the type is shared with the lease probe, and what tells a screen from a hub is the TXT record.

| Key | Holds |
| --- | ----- |
| `v` | `1`, the version of this arrangement |
| `n` | What the screen is called: "Drawer iPad" |
| `k` | The kind: `womble` |
| `a` | The agents registered here, device IDs, comma-separated |
| `a+` | `1` when the roster did not fit and has to be asked for |

One TXT entry cannot exceed 255 bytes, so a roster longer than that is cut short and marked with `a+`; the whole of it is then a `roster` request away. A record without `v=1`, `n` and `k` is not a surface and is passed over, which is what keeps a hub's own advert out of the list.

## The two requests

The advert names a port, and a line of UTF-8 each way is the whole protocol.

`roster` → `roster <id>,<id>,...`

Open to anyone on the network. Reading which agents a screen answers for is how a hub lists the house without pairing with anything first, and it is not private: it is in the TXT record already.

`register <topo://pair?...>` → `wait` | `ok <id>` | `no <reason>`

The token is the pairing URL from `docs/pairing.md` — `v`, `d`, `n`, `k` and an optional `e` — and Womble reads it only to know who is asking. It is not a credential and Womble is not a party to pairing: it writes no device record, and checks no key against one.

Joining the roster is the room's decision, not the network's. An agent already registered is answered `ok` at once, so a hub that asks again after a restart is nobody's decision to make twice. An agent that is not gets `wait` and a question on the screen naming who is asking; it becomes `ok` when somebody taps Register, and `no` if they tap Not now. A refusal is not remembered — asking later asks the room again, because the answer to "not now" is often "later".

The roster survives launches. It does not survive a reinstall, which costs the registrations and no more; the room can give them again.

## What this is not

There is no unregistering from the network's side: an agent can ask to join and cannot make itself leave, and a screen's roster is cleared by the person holding it. Nothing here reaches an agent or carries a turn — a Womble shows the transcript from CloudKit, as it always did. This is only how a hub learns that the screen exists and whose it is.
