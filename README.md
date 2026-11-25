# Bitrise Grand Prix

> **A [Bitrise](https://bitrise.io) project, built for the community.** It is open source under
> the MIT licence, so anyone can run it at their own meetup, conference booth or team event.

Phone-controlled RC car racing for conference booths and team events. A host opens a
session on a big screen, players scan a QR code, and everyone gets the track's time limit
(90 to 130 seconds) to put in three fast laps on their own phone. The big screen shows every
car live in 3D. There are six tracks, from the fast Release Train Ring to the tight Hotfix
Hairpins, each with at least two jumps.

It looks like a toy racing circuit in Bitrise colours: small cars seen from high above with a
Bitrise livery (the Bitrise badge on the roof, bonnet stripes and a wing with yellow end
plates), your own always in Bitrise purple and everyone else's in their driver's colour; purple
asphalt, Armco and tyre stacks, a grandstand full of fans, team tents, feather flags, and
trackside banners for Bitrise and its products (Build Cache, Insights, Release Management,
CodePush, RDE, Build Hub). Cars trail dust at speed, drift through the corners leaving
tyre marks and smoke, kick up dirt on the grass, steer their front wheels and lean into the
bends. Start lights on the finish gantry count you down, chase lights run along the gantry
and the grandstand, marker lights flash round the bends and light studs pulse along the road
edges. The fans bob, sway, do the odd Mexican wave, jump when a car flies past and take
flash photos.

Every boost, bug, checkpoint, lap, countdown beep, bump, landing and finish has a sound, as
do the motor and the tyres; they are all made in code when the game loads, so there are no
audio files. Players have sound on by default and the big screen has it off; the speaker
button in the game switches it, and each remembers the choice.

Built with [Godot 4](https://godotengine.org) (the game, exported to the web), Node and
TypeScript (the session server) and React (the session controller site).

> **Status: bootstrap.** The game, the session server and the controller site work end to end
> in desktop browsers at phone sizes. It has not been tried on real phones yet.

## How it fits together

```
 phone browser                       session server                    booth screen
┌───────────────────┐  join (HTTP)  ┌──────────────────────┐  HTTP    ┌──────────────────────┐
│ Godot game        │──────────────▶│ sessions, players,   │◀─────────│ controller site      │
│ own car + physics │  WebSocket    │ referee: laps and    │ WebSocket│ standings, QR screen │
│ ghosts of others  │◀─────────────▶│ times from positions │─────────▶│ + Godot spectator    │
└───────────────────┘               └──────────────────────┘          └──────────────────────┘
```

- **Each phone simulates its own car.** There is no input lag and bad Wi-Fi cannot ruin a
  run. The phone reports its position about ten times a second.
- **The server does no physics, but it keeps the score.** It batches those positions into one
  snapshot per tick and fans it out, so other players appear as ghost cars (no collisions
  between players). It also watches each car's positions to decide, on its own clock, when
  checkpoints and laps happen (see [Security and fair play](#security-and-fair-play)). Thirty concurrent racers is
  roughly 300 small messages a second.
- **Sessions are drop-in.** A session stays open until the host closes it. Each player's run
  ends after 3 laps or when the track's time limit runs out, and they can go again. The
  leaderboard keeps each player's best run.

## The game

| Thing | What it does | Looks like |
| --- | --- | --- |
| Boost | +50 % speed for one second | Box with the Build Cache icon |
| Obstacle | -50 % speed for one second | Box with the bug icon |
| Ramp | A jump. On a shortcut it launches you over a wall; too slow and you hit the wall | Chevron deck with the remote access icon |
| Finish line | Counts a lap once every checkpoint has been passed | Gantry with the Release Management icon |
| Grass and sand | Slows you to about 40 % | Everything that is not road |
| Armco | Solid; you bounce off | Barriers along the track wherever there is room |

The game is played with the phone held sideways; held upright it asks you to turn it.
Controls are on screen: the left thumb steers with a stick, and the right thumb has a large
accelerate button and a smaller reverse button (which brakes first). Steering is relative to
the car, like a real RC car, and the camera never turns, so left and right feel swapped when
you drive towards the bottom of the screen. On a laptop use the arrow keys or WASD, Enter to
start, and any key to skip the track intro; on a laptop or desktop the on-screen controls stay
hidden and the start panel says which keys to press.

On screen while racing:

- **Position**, top left: where your run stands against everyone else's best run, measured
  at the last checkpoint you passed (so it changes during the lap), with the top of the
  standings and the gap to the driver ahead.
- **Lap and time**, top right. The lap number pulses as you cross the line, yellow for the
  last lap. The remaining time appears in the last 15 seconds. Only a run's total time counts
  and is shown: there are no lap times, on the phone or on the site.
- An LED board for the countdown and for how the run ended (FINISH or TIME'S UP), a short
  fly-over of the track before your first run, and the results over the live track at the end.

The HUD and panels are set in Figtree, Bitrise's brand font (the one Bitkit uses): its
heaviest weight for names, numbers and buttons, and Bold for sentences and tables. Its digits
are all set to the same width, so the running time holds still as it counts.

## Quick start

You need Node 22 or newer, and Godot 4.7 with its web export templates to build the game.

```bash
npm install
npm run build:game     # exports the Godot project to game/export/web
npm run build          # builds the controller site (with gzipped scripts) and the server
npm run dev:server     # http://localhost:8787
```

Open <http://localhost:8787> to create a session, or
<http://localhost:8787/game/index.html> for a practice run without one.

To develop the controller site with hot reload, run `npm run dev:controller` as well and open
<http://localhost:5173>; it proxies `/api`, `/ws` and `/game` to the server.

## Running a session

1. Open the controller site and choose **New session**. Give it a name and pick a track.
2. Put the session page on the big screen. It shows the race live in 3D, how many players
   are connected, and the leaderboard. It never shows the QR code.
3. Put the QR code on a phone (or tablet) next to it, propped up where players can scan it.
   See [A phone for the QR code](#a-phone-for-the-qr-code).
4. Players scan the code, enter a driver name and race. They can go again as often as they like.
   Someone whose camera will not read the code can be sent a join link instead: **Share join
   link** on the QR screen makes one that works once, for three minutes.
5. For people without a phone, set up a laptop station. See [A laptop station](#a-laptop-station).
6. **Close session** when you are done. Results are kept and the session can be reopened.

### A phone for the QR code

The QR screen shows the join code, which changes every 5 seconds, with a bar counting down
to the next one. It is made to fill a phone held upright.

Get it onto the phone in one of two ways:

- **Copy phone link** on the session page (on your laptop), then send the link to the phone
  privately, for example by AirDrop or a message to yourself, and open it there. The link
  goes to the clipboard, not on the big screen.
- Or open the session's QR screen on the phone and unlock it with the admin token.

Either way the phone keeps only a key that can show join codes for this one session. It
cannot manage sessions, so it is safe to leave unattended at the booth. Making a new phone
link (or unlocking another device) stops the old one, which then says so.

Keep the phone's screen on. Over HTTPS (a `PUBLIC_URL` deployment) the page keeps it awake by
itself; on plain HTTP over the venue Wi-Fi browsers do not allow that, and the page asks you
to turn auto-lock off in the phone's settings. Turn the brightness up too: cameras read a
bright screen best.

"Race view only" opens just the 3D view, for a second display. It shows the whole track at a
fixed angle, and spectators cheer when cars pass them. The host can remove a driver
(and their results) from the leaderboard.

No phones to hand? Send bots (they join through the QR screen's code, so pass the admin
token if the server has one):

```bash
ADMIN_TOKEN=... npm run bots --workspace @bitrise-grand-prix/server -- CODE 6
```

Everything the site does goes through the HTTP API, so sessions can also be scripted:

| Method | Path | Admin | Purpose |
| --- | --- | --- | --- |
| GET | `/api/config` | | What the server is configured to do |
| GET | `/api/tracks` | | Available tracks |
| GET | `/api/sessions` | yes | All sessions |
| POST | `/api/sessions` | yes | Create a session (`name`, `trackId`) |
| GET | `/api/sessions/:code` | | One session: players, leaderboard, results |
| POST | `/api/sessions/:code/close` | yes | Stop new runs and joins |
| POST | `/api/sessions/:code/reopen` | yes | Open it again |
| DELETE | `/api/sessions/:code` | yes | Delete it and its results |
| POST | `/api/sessions/:code/screen-key` | yes | A key for the QR phone; replaces the previous one |
| GET | `/api/sessions/:code/join-code` | yes, or `X-Screen-Key` | The QR screen's current join code |
| POST | `/api/sessions/:code/tickets` | | Trade a join code (`token`) for a one-time join ticket |
| POST | `/api/sessions/:code/station-key` | yes | A key for the laptop station; replaces the previous one |
| POST | `/api/sessions/:code/station-ticket` | `X-Station-Key` | A one-time join ticket for the laptop station's next driver |
| POST | `/api/sessions/:code/players` | | Join (`name`, `ticket`); returns the player's token |
| DELETE | `/api/sessions/:code/players/:id` | yes | Remove a player and their results |

"Admin" routes need `Authorization: Bearer <ADMIN_TOKEN>` when `ADMIN_TOKEN` is set.

### A laptop station

A laptop at the booth where people without a phone can race with the keyboard. Press **Copy
laptop link** on the session page, send the link to the booth laptop the same way as the phone
link, and open it there. From then on the laptop shows a name box: each driver types a name,
presses Enter and races with WASD or the arrow keys. When the run is over, **Race again** lets
them go again and **Next driver** (or Esc) brings the name box back for the next person.

The laptop keeps a key that can join drivers to this one session and do nothing else. Anyone
holding the link could join drivers from anywhere, so keep it on that laptop. Making a new
laptop link stops the old one.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8787` | Port the server listens on |
| `ADMIN_TOKEN` | not set | Required to manage sessions and to open the QR screen. Use 16+ random characters. Without it anyone can do both, which is fine on a laptop at a booth; with `NODE_ENV=production` the server refuses to start without one |
| `ALLOW_NO_ADMIN_TOKEN` | not set | `true` lets a production server start without `ADMIN_TOKEN` anyway |
| `TRUST_PROXY` | not set | Behind a reverse proxy, set to `true` (or the number of proxies) so rate limits see each phone's address instead of the proxy's |
| `PUBLIC_URL` | not set | The URL phones should open, for example `https://race.example.com`. Without it the QR code uses the address the host opened, or this machine's LAN address when that is `localhost` |
| `DATA_DIR` | `./data` | Where `sessions.json` is kept |
| `PERSIST` | `true` | `false` keeps sessions in memory only |
| `GAME_DIR` | `game/export/web` | The Godot web export |
| `CONTROLLER_DIR` | `packages/controller/dist` | The built controller site |

Phones must be able to reach the server, so for a conference deploy it somewhere public over
HTTPS rather than relying on venue Wi-Fi letting devices talk to your laptop.

## Project layout

```
game/                    Godot project
  scripts/main.gd          entry point: player, spectator and practice modes; camera, intro
  scripts/car.gd           car physics
  scripts/car_visual.gd    the car model, painted in the driver's colour
  scripts/car_fx.gd        dust trail, drift marks, smoke, dirt, boost sparks
  scripts/audio.gd         every sound effect, synthesised at load time
  scripts/track.gd         builds the drivable track from a JSON file: road, kerbs, Armco, lights
  scripts/scenery.gd       grass, hills, trees, grandstand, tents, flags, crowds
  scripts/pickup.gd        boost and bug boxes
  scripts/models.gd        loads and recolours the Kenney models
  scripts/race.gd          countdown, laps, checkpoints, time limit
  scripts/ghosts.gd        other players' cars, interpolated
  scripts/hud.gd           position, times, controls, LED countdown, panels, transitions
  scripts/net.gd           WebSocket client
  shaders/                 grass, asphalt, car paint, crowds, flags, blinking lights
  tracks/*.json            track definitions (also read by the server)
  assets/fonts/            Figtree, the HUD font (SIL Open Font License)
  assets/icons/            generated icon tiles
  assets/models/           Kenney Car Kit and Nature Kit models (CC0)
packages/shared/         protocol types, constants, ranking, track geometry
packages/server/         session store, HTTP API, WebSocket relay, join codes, run referee
packages/controller/     session controller site (React)
scripts/                 export-game.sh, measure-laps.sh, build-icons.mjs
```

## Tracks

A track is one JSON file in `game/tracks/`. To add one, create the file, then import it in
`packages/shared/src/tracks.ts` so the server offers it.

- `centerline`: control points `[x, z]` of a closed loop, driven in order. The road is a
  smooth curve through them.
- `checkpoints`: indices of control points that hold a gate. A lap only counts after passing
  them all in order, so place them where every legal route goes, shortcuts included.
- `boosts`, `obstacles`, `billboards`: placed by `at` (position along the loop in
  control-point units, so `2.5` is halfway between points 2 and 3) and `offset` (metres to
  the right of the driving direction).
- `shortcuts`, `ramps`, `walls`: plain coordinates.
- `ramps`: at least two (a test checks), each on the road or on a shortcut. On the road, keep
  them narrower than the road so drivers can go round, and leave 25 m of straight to land on.
- `minLapMs`: a lap faster than this is rejected. After changing a track or the car, run
  `./scripts/measure-laps.sh 90 <track-id>` and set it comfortably below what a human could do:
  the shortest legal lap at 50 m/s works.
- `timeLimitMs`: how long a run may take. Start from the autopilot's three laps and allow about
  1.75 times that on an easy track, up to 2 times on a narrow, twisty one.

## Icons, models and marketing art

The car, trees, bushes, rocks, cones and debris are CC0 models from Kenney's
[Car Kit](https://kenney.nl/assets/car-kit) and [Nature Kit](https://kenney.nl/assets/nature-kit),
recoloured in code (`scripts/models.gd`). Only the models the game uses are in
`game/assets/models/`. Everything else (track, barriers, grandstand, tents, flags, people) is
built in code, and the grandstand, crowds, banners and trees place themselves around whatever
track is loaded, keeping clear of the road and of the camera's line of sight.

The icon boxes are tiles generated from the public Bitkit icon set. To change which icon a
box shows, edit the mapping at the top of `scripts/build-icons.mjs` and run
`node scripts/build-icons.mjs`. The ramp currently uses Bitkit's "remote access" icon, the
closest match in the set to remote dev environments.

Billboards show an icon and a slogan from the track file. To show artwork instead, drop an
image in `game/assets/marketing/` and give the billboard an `image` path. See `NOTICE.md`
for what the code licence does and does not cover.

## Security and fair play

**Joining.** Only someone standing in front of the QR screen can join:

- The QR code holds a join code made from the current time and signed with a secret only the
  server has. A new one appears every 5 seconds and each works for 10, so a phone that scans
  just before the change still has time to open the link, a photo of it is soon useless, and
  nobody can make one up. Both times are constants in `packages/shared/src/index.ts`
  (`JOIN_CODE_ROTATE_MS`, `JOIN_CODE_TTL_MS`).
- Only the host, or the one device the host gave a phone link to, can show the QR code. The
  session page anyone can see shows the race and the standings, never the code. The key in a
  phone link travels in the part of the address after `#`, which browsers never send to the
  server or pass on to other sites.
- The server trades the code for a one-time ticket on the phone's very first request, before
  the site has even downloaded, and hands the ticket to the page after `#`. So only the scan
  and that first request race the code's 10 seconds; a slow phone or busy Wi-Fi can take as
  long as it likes over the rest. The player then has three minutes to type a name. Joining
  without a valid ticket is refused. A code that arrives too late gets "That code has expired",
  and scanning again works.
- The QR screen can also trade its current code for a ticket itself and share it as a join
  link, for someone who cannot scan. The ticket travels after `#` like the screen key, works
  once, and runs out after three minutes.
- A laptop station's key stands in for scanning: it gets a one-time ticket for each new
  driver, for its one session, and nothing else. It travels after `#` like the screen key, and
  making a new one cancels the old.

**Results.** Physics runs on the phone, so a phone's word about its lap times counts for
nothing. Phones only report where their car is, about ten times a second; the server's
referee (`packages/server/src/referee.ts`) works out checkpoints, laps and times from those
positions on its own clock, and rejects a run if the car:

- goes faster than the car can: its top speed, half as much again only just after driving
  through a boost box, and much less on grass;
- jumps across the track, drives through a wall, leaves the arena or does not start on the grid;
- reports a clock running ahead of real time, or a lap faster than the track's `minLapMs`;
- finishes after the track's `timeLimitMs`.

The referee judges every run on the server's copy of the track, so in a session the game builds
the track from that copy too (it comes with the welcome message) and keeps its own files for
practice. A game exported before or after a track edit still races the boxes the referee knows
about: one it doesn't know would make an honest run look faster than the car can go. After
changing a track, rebuild and restart the server for it to take effect.

That rules out typed-in times, teleports, speed hacks and cutting across the grass. It does
not make cheating impossible: a bot that drives a perfect line at the car's limits passes, and
would be about as fast as the in-game autopilot. Keep prizes proportionate; the host can
remove a player and their results at any time.

**Other measures.** Player tokens are stored only as hashes; admin token checks are
constant-time and rate-limited, as are scans and joins; WebSocket connections from other
sites are refused; and the server sends a strict Content Security Policy, `no-referrer` (so a
join link never leaks to another site), `nosniff` and frame protection, plus HSTS when
`PUBLIC_URL` is HTTPS.

## Deploying

```bash
npm run build:game
docker build -t bitrise-grand-prix .
docker run -p 8787:8787 -v bitrise-grand-prix-data:/data \
  -e ADMIN_TOKEN=change-me -e PUBLIC_URL=https://race.example.com bitrise-grand-prix
```

Serve it over HTTPS. One instance holds all state in memory, so run a single replica.

## Development

```bash
npm test          # server tests
npm run typecheck
./scripts/measure-laps.sh [seconds] [track-id]   # autopilot lap times, headless
```

`/game/index.html?autopilot=1` makes the car drive itself, which is handy for demos.
`?track=hotfix-hairpins` practises on another track (any file name in `game/tracks`).
`?debug=1` shows the frame rate and draw calls, for checking how a phone copes.

## Known gaps

- Sound has not been heard on real phones yet. Godot's browser build restarts a looped sound
  at its original pitch, so `audio.gd` plays the motor and tyre squeal as overlapping
  two-second sounds instead of loops; see the note at the top of that file.
- Driver names are filtered for length and markup only; there is no profanity filter, so use
  "remove player" for names that should not be on a big screen.
- The HUD font covers Latin, including accented letters, and falls back to Godot's built-in
  font for Cyrillic and Greek. Names in other scripts, such as Chinese or Arabic, may show as
  boxes in the game.
- Not yet tested on real phones, only in a desktop browser at phone sizes. Shadows, crowds and
  trees cost frames; phones get fewer trees and smaller shadows automatically, and
  `?debug=1` shows how a phone is coping.

## Licence

MIT for the code. Brand assets are a separate matter: see `NOTICE.md`.
