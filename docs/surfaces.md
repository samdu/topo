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

## The page a television opens

Off Apple there is no bundle to install, so a Womble is a web page the hub serves on the house's own network — `Womble/Web`, static, no build step and no dependencies, because the browser on the other end may be a television's.

It reads one document, polled, and shows the same two things the app does: the house board and the transcript.

### Where it is

`GET /s/<token>/surface.json`, and the page itself is served from `/s/<token>/`, so it asks for `surface.json` beside itself and never handles a token at all.

The token is the whole of the access control, and it has to be: this is a person's transcript on a household network, and the roster being open to anyone on the LAN is about *reading who is registered*, not about reading what anyone said. So:

- One token per screen, minted by the hub when somebody in the house registers that screen — the same tap that puts an agent on a Bonjour surface's roster, and the same rule: the network can ask, the room decides.
- Unguessable: 128 bits or more from a cryptographic source, not a device name or a counter.
- Revocable, in the app, and revoked by default when the screen is taken off the roster.
- Bound to what that screen may see. A token is a screen, not an account: it is the household board and the transcript of whoever registered it, and nothing else.
- Refused when unknown, with a 404 and no hint of whether the token was ever real.

A token in a path is in the browser's history and in any proxy's logs, so the hub serves this on the LAN only, over the local network interfaces, and never through the tunnel.

### The document

```json
{
  "version": 1,
  "house": "Hexagon Zone",
  "transcript": {
    "complete": true,
    "notice": null,
    "turns": [
      { "ref": "phone/1", "role": "person", "text": "…", "at": "2026-09-05T19:02:00Z" }
    ]
  },
  "board": {
    "cards": [
      { "id": "hub/3", "owner": "hub", "body": "Bins out tonight", "state": "posted",
        "postedAt": "2026-09-05T19:02:33Z", "at": "2026-09-05T19:02:33Z" }
    ]
  }
}
```

| Field | Holds |
| ----- | ----- |
| `version` | `1`. A page that does not know the version says so rather than guessing |
| `house` | What to call the household, or absent |
| `transcript.turns` | Oldest first, as the log orders them: `ref`, `role` (`person` or `assistant`), `text`, `at` in RFC 3339 |
| `transcript.complete` | False when the read could not be finished. The page says so above the turns whether or not a `notice` came with it: a partial conversation shown as the whole one is the transcript's one unforgivable failure |
| `transcript.notice` | A line to show above the turns, or null: what the app puts in its banner |
| `board.cards` | Newest posting first: `id`, `owner`, `body`, `state` (`posted`, `ticked`, `dismissed`), `postedAt`, `at` |

One document rather than two endpoints, because a wall screen wants the board and the transcript to agree with each other, and two requests can disagree.

The hub decides what a page may see, and the token is how it knows which page is asking. This is the household's view — the board, and the transcript of whoever the screen is registered to — and the page has no login of its own and asks for nothing else.

### Polling

Every five seconds, with `If-None-Match` when the hub gave an `ETag`, and again when a hidden tab comes back. A wall screen wants to be current more than it wants to be quick, and a `304` costs the hub nothing.

A transient failure — no answer, a `500` — leaves what is on screen where it is and says the hub is not answering, because a screen that clears itself over a hiccup is worse than one showing what it last knew.

A `401`, `403` or `404` is not that. It means this screen is not registered, and the page clears the board, the transcript and its cached state at once: revoking a screen has to stop it showing what it was showing, and a screen that has left the house may be in somebody else's hands. It keeps asking, so a hub that has only just started up, or a screen registered again, comes back on its own. A screen that clears itself because the network hiccuped is worse than one showing what it last knew — the same rule as the app.

### Writing

None. Every one of these screens is a noticeboard: it shows what the house posted, and a tap that changes something is the client app's business.

## What this is not

There is no unregistering from the network's side: an agent can ask to join and cannot make itself leave, and a screen's roster is cleared by the person holding it. Nothing here reaches an agent or carries a turn — a Womble shows the transcript from CloudKit, as it always did. This is only how a hub learns that the screen exists and whose it is.
