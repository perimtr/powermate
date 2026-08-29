# Knurl naming: clearance research

Date: 2026-08-29. Scope: informal knockout research on the proposed
product name "Knurl". **This is not legal advice**, and it is not a
substitute for a full search. It is the same kind of pass the messenger
got before Perimtr Comms was chosen (see
~/Projects/comms/NAMING-CLEARANCE.md), done so counsel starts from
evidence rather than from zero.

## The mark under review

- **Knurl**, an ordinary English noun and verb: the milled ridging cut
  into a knob or a fastener so fingers can grip it.
- Category: a macOS menu bar utility. A control surface that maps
  physical dials (the Griffin PowerMate, MIDI controllers) to system
  volume, per-app volume, media keys and per-app profiles.
- Planned identifiers: repo perimtr/knurl, Homebrew cask
  `perimtr/tap/knurl`, bundle id io.perimtr.knurl, home page
  perimtr.io/knurl.
- Would replace PowerMate as the product name. PowerMate would remain
  in prose as a supported device.

## Findings

1. **No software product of any prominence is called Knurl.** Searches
   for a Knurl app, tool or developer product returned nothing in the
   2026 tooling landscape. There is no established brand to collide
   with.

2. **No KNURL trademark surfaced in the software classes.** Nothing was
   found in class 9 (software) or class 42 (software services). The word
   does appear inside the goods descriptions of unrelated industrial
   marks (IMPERIAL, registration 0893220, covers steel stamping
   equipment including "knurl or roll carriages"), which is the word
   being used descriptively, not held as a mark. Caveat: Justia and the
   USPTO search interfaces both block automated access, so this is a
   search-engine-mediated result, not a database sweep. **Counsel should
   run the real search.**

3. **Nearby registered marks, neither in our lane.**
   - KNURLING, registration 5632854, registered 2018-12-18, class 25,
     athletic apparel and clothing. Same root word, unrelated goods.
   - KNURR / KNÜRR DCM, registration 4054689, class 9, racks and
     housings for electrical and electronic assemblies (Knürr AG, the
     German enclosure maker). One letter from Knurl and it sits in class
     9, so it deserves a look, though the goods are metal cabinets
     rather than software and the marks look and sound distinct.

4. **Three small active software packages already use the exact
   string.** None is a consumer product, none appears to be a brand, but
   all are live in developer namespaces:
   - npm `knurl` 0.1.2, updated 2026-04-27: "a declarative,
     event-driven graphical interface for monitoring and modifying
     JavaScript variables".
   - PyPI `knurl` 0.5.0: "rock-solid primitives for content-addressable
     hashing, chain fingerprinting, and config diffing".
   - GitHub `asraym/knurl`: a C++17 static analysis utility for Python
     codebases.
   These block those package namespaces, not the product name. We
   publish a Mac app through Homebrew, so no collision in practice.

5. **The closest sector adjacency is Knurling, not Knurl.**
   `knurling-rs` is Ferrous Systems' tooling project for embedded Rust
   (the defmt and probe-run family), with an active organisation and
   a following on GitHub. Same root word, same broad audience
   (developer tools), different product entirely. Worth naming for
   counsel because "Knurl" and "Knurling" are one suffix apart in an
   overlapping community, even though the goods differ.

6. **Every obvious domain is taken, none is in use.**
   - knurl.com: registered 1998, resolves to old Interland hosting.
   - knurl.io: registered 2016, NameCheap, nameservers at Vultr but
     **no A record**, so nothing is served.
   - knurl.app and knurl.dev: registered, resolving to what look like
     registrar parking addresses.
   - knurl.sh: appears unregistered.
   No third party is visibly operating a Knurl product on any of them,
   which supports finding 1: these are held, not used.

## What this means

The name is **clear enough to proceed on**, with three honest caveats:

- It is a **descriptive-adjacent word**, not a coined one. "Knurl"
  describes a physical texture associated with knobs, and our product
  is about knobs. That is exactly why it is a good name, and also why
  it is weaker as a mark than a coined word like decaud would be.
  Expect a narrower scope of protection and do not expect to stop
  anyone from using the word descriptively.
- **No domain is available** at .com, .io, .app or .dev. The migration
  plan already assumes perimtr.io/knurl, which sidesteps this entirely
  and matches the decread pattern. knurl.sh is the only short option
  that looked free.
- **The knurling-rs adjacency** is the one thing worth a lawyer's
  opinion rather than a search engine's.

## Recommendation

Proceed with Knurl, on the perimtr.io/knurl path, and have counsel run
a proper class 9 and 42 search plus an opinion on the Knurling and
Knürr adjacencies before the 2.0 release goes public. Nothing in this
research is a reason to stop; the rename plan in KNURL-MIGRATION.md can
start on the reversible phases while that opinion is pending.

If counsel comes back uneasy, the fallback is the pattern that already
worked once: **Perimtr Dial**, a house mark plus a plain descriptor,
which carries the same low risk that made Perimtr Comms the answer for
the messenger.

## Search log (for counsel pickup)

Run 2026-08-29. Domain whois and DNS: knurl.com, knurl.io, knurl.app,
knurl.dev, knurl.sh. Package registries: npm, PyPI, crates.io (crates
returned 403, unverified). GitHub repository search for knurl.
Trademark research was search-engine-mediated: Justia returned 403 to
automated fetches and the USPTO interfaces are JavaScript-gated, so no
direct database query was performed. **A full USPTO and common-law
search remains outstanding.**
