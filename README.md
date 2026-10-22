# Dynamic Camera Zoom

Zooms the camera and the minimap to set distances in World of Warcraft while something's going on (talking to an NPC,
riding a mount or a flight path, fishing, fighting, being indoors or in a dungeon...), and back to where they were
when it ends.

Retail (Interface 120100) and WoW: Forever (Interface 16001).

## Triggers

- **Combat:** from entering combat until you leave it.
- **Fishing:** while you're casting Fishing (Void Hole Fishing too). Its end Zoom Delay (3 sec by default) keeps it
  from zooming back out between casts.
- **Talking to NPCs:** from opening an NPC's window (gossip, a quest, a vendor, a trainer...) until it closes.
- **Mailbox, Bank & Auction House:** while a mailbox, bank, guild bank or auction house is open.
- **Flight Paths:** from taking off until you land.
- **Flying Mounts** (retail): from mounting until you dismount. Skyriding mounts count as flying.
- **Ground Mounts:** from mounting until you dismount. On WoW: Forever, which has no flying mounts, this is every
  mount (called Mounts).
- **Dungeons & Raids:** while you're in a dungeon or raid (and a delve, on retail).
- **Indoors:** while you're in a building or cave.

Several can be going on at once. The camera and the minimap are each zoomed by the highest one on the **Priority** tab
that zooms them; when none does any more, they go back to where they were before the first one did.

## Settings

Options > AddOns > Dynamic Camera Zoom (or `/dcz`). On the **Triggers** tab:

- **Respect Manual Zoom:** if you zoom the camera or minimap yourself while a trigger has zoomed it, it isn't put back
  when the trigger ends.
- **Wait Out Combat:** other triggers don't zoom until combat ends (the Combat trigger still does).
- **Minimap Zoom Step:** the most time the minimap takes for each zoom level it passes through (Instant to 0.5 sec).
- **Camera Easing:** Linear (one steady speed, the game's own) or Ease Out (the default: starts quickly, slows as it
  arrives).
- **Settings For:** pick a trigger to set its options:
  - **Zoom Camera** and **Camera Distance**, up to your Max Camera Distance (Options > Camera).
  - **Zoom Minimap** and **Minimap Zoom**, from Closest to Farthest.
  - **When It Starts:** a **Zoom Delay** before zooming, and the **Transition Time** the zoom takes.
  - **When It Ends:** **Restore Previous Zoom** (put the camera and minimap back), with its own **Zoom Delay** (how
    long to hold the zoom first) and **Transition Time**.

The **Priority** tab orders the triggers, highest first, with up and down arrows.

To find values to set: `/dcz zoom` prints your camera distance and minimap zoom, and `/dcz trace` prints them each time
you stop zooming (again to turn it off).

`/dcz debug` logs every zoom and camera reading to the saved settings (the last 400 lines; `/dcz debug clear` empties
it), for tracking down a zoom that lands in the wrong place.

## How the zoom works

The game only lets addons zoom the camera by an amount, at the speed of its camera zoom speed setting. For each zoom
the addon sets that speed so the zoom takes the transition time, then puts your own speed back (also at the next login,
if the game closes mid-zoom). The game keeps what's left of a zoom as time, so changing the speed mid-zoom makes it go
farther or shorter. So a zoom that starts while another is still moving keeps that one's speed (one the other way
replaces it, from where the camera is), your speed goes back only once the camera has stopped, and a zoom that comes
just after you zoomed yourself waits for your zoom to stop. When a zoom should be done it's checked, and corrected once
if it landed somewhere else (unless you zoomed yourself in the meantime).

The game's zoom has no curve, so an eased zoom is drawn with straight segments of equal distance (about a fifth of a
yard each), each one zoom: the curve sets how long each takes, so they're fast at the start and slow toward the end.
Each starts as the last one finishes. The curve also blends in a little steady motion, so it lands from a gentle creep
rather than a standstill. (There's no slow-start curve: the game starts every zoom out from rest with a quick burst,
whatever the speed.) Zooming yourself stops it.

The minimap has fixed zoom levels; a transition steps through the levels between.

## Install

`scripts\install-local.ps1 -AddOnsPath <Interface\AddOns>` copies the addon into a client for testing.
