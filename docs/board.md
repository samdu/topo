# The house board

The one thing in Topo that several people hold at once. The transcript and the memory are one person's and never leave their Apple ID; the board is shared across the household's, so it lives somewhere else entirely.

## Where it is

Container `iCloud.zone.hexagon.topo.board`, custom zone `Board`. Not the log's container, and that is the point rather than an accident: nothing that can reach a shared zone can reach the personal one, which is a property of the container rather than of anyone's care.

One person creates the zone and shares it with a `CKShare` on the whole zone — a board is one thing, and a person who can see it can post to it. Everybody else accepts the share, which puts the zone in their shared database, and writes into it through their own login. A house where nobody has shared one yet still has a board: one person's, unshared, which is what the first card looks like before anyone is invited.

`TopoBoard` in `Apps/Shared/TopoCloudKit.swift` is that: the container, the zone, the share, and finding the one somebody shared with you.

## What a card is

`Card` records, named `card/<device>/<sequence>`, one per revision, saved create-only — the same arrangement as the turn log and the memory, for the same reason.

| Field | Holds |
| ----- | ----- |
| `card` | Which card this is a revision of: the name of the revision that first posted it |
| `owner` | Whose card it is. A card someone else ticks keeps its owner |
| `body` | What it says |
| `state` | `posted`, `ticked` or `dismissed` |
| `parents` | The revisions of this card it replaces |
| `at`, `device`, `sequence`, `nonce` | As everywhere else here |

Posting, ticking, dismissing, reposting and amending are the whole vocabulary. Anything needing judgement is a message to an agent, not a change to a card.

## Two devices at once

Where two devices change one card without seeing each other, the newer revision is the card and the older is not shown.

That is the opposite of what the memory does, and deliberately. A note is a document where losing somebody's paragraph is unacceptable, so a conflict there becomes a copy beside the file. A card is one line that a household is looking at together, where two answers on a wall is worse than the older one being superseded. Nothing is destroyed either way: every revision stays in the log, and the one that lost is there to read.

A change made after seeing the fork resolves it, because a write continues from every head the writer saw.

## On a screen in a room

Womble shows the board beside the transcript: side by side on a wide screen with the transcript given the greater share, stacked on a tall one with the board above, following the device rather than asking. It shows the cards that are still open — a ticked card is not deleted, but a noticeboard is for what is open.

Womble writes nothing to it. It has no login to write with, and a tap on a card is the client app's business.
