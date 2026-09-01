# Knurl migration plan

Renaming the product from PowerMate to Knurl, and broadening it from a
driver for one device into a control surface for macOS. Written
2026-08-29, before any of it is done. Nothing here is urgent: the
shipped 1.5 is healthy and this can wait as long as it needs to.

**Status, 2026-09-01.** Phase 1 is done on the midi-source branch and
waits on one hand test of the knob before it merges. Phase 2 onwards is
held until counsel clears the name (see KNURL-NAMING.md). Nothing has
been renamed anywhere, and nothing public has changed.

The governing distinction, which decides most of the questions below:

- **PowerMate as a product name** goes away. That is the app title, the
  menus, the cask, the repo.
- **PowerMate as a device name** stays everywhere it is accurate. Naming
  a device you are compatible with is ordinary nominative use, and those
  mentions are the only discoverability the project has today. Keep it
  descriptive ("Knurl works with the Griffin PowerMate"), never
  possessive, and never borrow Griffin's logo or trade dress.

## Phase 0: decide before starting

1. **Clear the name.** Give Knurl the same treatment Perimtr Comms got
   in ~/Projects/comms/NAMING-CLEARANCE.md: trademark search in the
   relevant classes, a look for existing Mac or developer tools using
   it, and a domain check. Nothing below should start until this
   passes.
2. **Decide the bundle id.** See Phase 3; the recommendation is to
   change it now, while the installed base is one machine.
3. **Decide the domain shape.** knurl.io as its own home, or
   perimtr.io/knurl in the pattern decread already uses. The website
   work in Phase 6 assumes the second.

## Phase 1: land MIDI first

The rename only makes sense because the app drives more than one
device, so the capability should exist before the identity changes.

1. Extend the virtual MIDI harness to cover what the first pass did not:
   relative (endless) encoders in both two's complement and signed bit
   conventions, several controls arriving at once, and rapid bursts.
   The absolute path is already proven end to end.
2. Have `PowerMateHID` adopt `KnobGestures` instead of keeping its own
   copy of the timing. This was deliberately deferred in the prototype
   because it cannot be verified without hands on the knob. Retest by
   hand afterwards: click, double-click, long press, press and turn.
3. Merge `midi-source` into main. Do not ship a release from it under
   the old name; the next release should be the renamed 2.0.

## Phase 2: rename the repository

**HELD as of 2026-09-01, by the owner's decision: do not rename the
repository until counsel clears the name.** Renaming the public repo is
the first step that publicly commits to Knurl, and KNURL-NAMING.md
recommends a real trademark search before that happens. Renaming back
afterwards works but chains redirects awkwardly. Everything below stays
accurate; it just waits.

Rename in place rather than creating a new repository:

    gh repo rename knurl --repo perimtr/powermate

GitHub redirects the old URL permanently, so git remotes, release
download links, the Homebrew cask URL and the update checker's API path
all keep working, and stars, history, releases and issues carry over.

**Never create a new repository named `powermate` afterwards.** Doing so
silently cancels the redirect and breaks every old link, including the
update check in every 1.3 and later install already in the wild.

Then:

- `git remote set-url origin https://github.com/perimtr/knurl.git` in
  every local checkout and worktree.
- Rewrite the repository description and topics so the device stays
  searchable: mention the Griffin PowerMate in the description, and keep
  topics for powermate, griffin-powermate, midi, macos and menu-bar.

## Phase 3: rename in the code

- **Strings**: menus ("Pause PowerMate", "About PowerMate"), the status
  line, the Settings window title, transient readouts. Consider putting
  the product name in one constant so the next change is a single edit.
- **Info.plist**: CFBundleName, CFBundleDisplayName, CFBundleExecutable,
  and the version to 2.0 (build 7).
- **Makefile**: APP_NAME, which also moves the bundle path, the disk
  image name and the mounted volume name.
- **Package.swift and the source directory**: Sources/PowerMate becomes
  Sources/Knurl, target renamed to match.
- **Keep PowerMateHID.swift and PowerMateLED.swift as they are.** They
  are the PowerMate driver, so those names stay correct under any
  product name.
- **Entitlements**: Support/PowerMate.entitlements becomes
  Support/Knurl.entitlements, referenced from the Makefile.
- **UpdateChecker**: point the releases URL at perimtr/knurl rather than
  relying on the redirect.
- **Docs**: README, AGENTS.md and PRIVACY.md reframed as "Knurl, which
  works with the Griffin PowerMate and MIDI controllers". Every
  verification recipe carries the log subsystem and the defaults domain,
  so those strings change with the bundle id.

### The bundle id, and the settings migration

Changing `io.perimtr.powermate` to `io.perimtr.knurl` resets three
things: TCC permissions, the login item, and the defaults domain.

Recommendation: **change it during this rename.** With an installed base
of essentially one machine this is the cheapest it will ever be, and the
cost only grows with adoption. Carrying a mismatched id forever is
survivable but it is a wart that touches every log recipe and every
`defaults` command.

Settings can be carried across in code. On first launch, if the new
domain is empty and the old one has data, copy every key over and set a
migrated flag. Leave the old domain in place rather than deleting it, so
a rollback keeps working:

- old domain: `io.perimtr.powermate`
- new domain: `io.perimtr.knurl`
- flag: `didMigrateFromPowerMate`

TCC cannot be migrated. Permissions have to be granted again once, by
hand, and that is unavoidable no matter how the rename is sequenced.

## Phase 4: the one manual pass on this Mac

1. Remove the old app before running the new one. Two builds with
   different bundle ids will both try to seize the device, and the
   second one loses.
2. Launch Knurl 2.0, confirm the settings migration brought the profiles
   across, then re-grant Accessibility and Input Monitoring. System
   Audio Recording re-prompts by itself the first time the Frontmost App
   Volume mode runs.
3. Re-tick Start at Login, since the login item is registered per bundle
   id.

## Phase 5: distribution

- Release 2.0 from the renamed repository. CI needs no changes: the
  secrets, the Developer ID signing and the notarization all travel with
  the repo.
- Have CI publish `Knurl-2.0.dmg` plus the stable `Knurl.dmg`, and keep
  copying it to `PowerMate.dmg` for one release cycle so no existing
  link 404s mid-transition.
- Homebrew: add `Casks/knurl.rb` to perimtr/homebrew-tap, and mark the
  powermate cask deprecated rather than deleting it. Point the tap's
  auto-follow workflow at the new repository and asset name.
- Switching this Mac over means `brew uninstall --cask powermate` and
  then `brew install --cask perimtr/tap/knurl`. Watch that uninstall:
  Homebrew's autoremove runs alongside it and has swept unrelated
  formulae on this machine before.

## Phase 6: the website

- Product page moves from /powermate to /knurl, with a redirect route
  kept for the old path. The privacy page moves the same way.
- Regenerate the card icon from the new generator
  (Support/appicon-small-256.png) and keep `--product-accent` at
  #409EFF: colour recognition outlasts a name change.
- Copy becomes "Knurl works with the Griffin PowerMate and MIDI
  controllers", which keeps the device searchable on the site even
  though it is no longer the product name.

## Phase 7: verification

Nothing counts as done until these pass:

- App launches, seizes the knob, LED responds, MIDI learn works.
- Migrated settings show the old profiles.
- The published dmg validates: `xcrun stapler validate` and
  `spctl -a -t open --context context:primary-signature` both accept it.
- `brew install --cask perimtr/tap/knurl` installs 2.0 on a clean path.
- An older install still sees the update: confirm the GitHub API
  redirect from the old repository path actually resolves, since every
  1.3 and later install depends on it.
- perimtr.io/powermate redirects, and the download button serves the new
  disk image.

## Risks and rollback

- **The redirect is the load-bearing piece.** Protect it by never
  recreating the old repository name.
- **TCC reset** is a one-time cost for every existing user. Today that
  is one person.
- **Two apps fighting for the device** during the transition, solved by
  removing the old one first.
- **Rollback** is cheap up to Phase 5: repositories can be renamed back,
  releases are untouched, and the old cask keeps working. After 2.0 is
  published, roll forward rather than back.

## Open questions

- knurl.io, or perimtr.io/knurl in the decread pattern?
- Does the About panel keep a line naming the supported devices? It is a
  good place to keep the PowerMate association visible.
- How long to keep publishing `PowerMate.dmg` alongside `Knurl.dmg`.
- Whether the PowerMate keeps first-class billing in the README, or
  becomes one entry in a supported-devices list once other devices land.
