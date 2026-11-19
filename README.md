# SillyTavern PKMN Adventure Notebook

Logs your Pokémon playthrough in mGBA and feeds it to SillyTavern as an Author's-Note-style notebook.

```
mGBA  ──(pkmn_notebook.lua reads the game)──►  http://127.0.0.1:8888  ──►  SillyTavern extension  ──►  your prompt
                       │
                       └─► mgba/logs/<adventure>.jsonl   (permanent log, even when SillyTavern is closed)
```

**Supported games:** Game Boy Advance Pokémon games (Gen 3): Ruby, Sapphire, Emerald, FireRed and LeafGreen (US versions), plus romhacks built on them.

---

## 1. Install the SillyTavern extension

In SillyTavern, open **Extensions** (the stacked-blocks icon) → **Install extension**, and paste:

```
https://github.com/FlamingDoritos/SillyTavern-PKMN-Adventure-Notebook
```

The notebook opens from either of these places:

* the **🪄 Extensions menu** (wand button next to the chat box) → **Adventure Notebook**, or
* **Extensions panel → PKMN Adventure Notebook → Open notebook**.

## 2. Set up mGBA (once)

The mGBA script is in the `mgba/` folder of this repository. You can get it in either of two ways:

* **Download ZIP:** use the green **Code** button on GitHub and keep the `mgba` folder somewhere handy.
* **Use SillyTavern's copy:** after installing, it's already at `SillyTavern\data\default-user\extensions\SillyTavern-PKMN-Adventure-Notebook\mgba\`.

Then:

1. Open mGBA (0.10 or newer) and load your game.
2. Go to **Tools → Scripting…**, then **File → Load script…**.
3. Pick `mgba\pkmn_notebook.lua`.

The scripting window shows:

```
[Notebook] SillyTavern bridge listening on http://127.0.0.1:8888
[Notebook] Scanning ROM for game data (first time only, a few seconds)...
[Notebook]   species        header inline @0x3185C8 stride 11 (412)
[Notebook]   moves ...
```

Windows may ask whether mGBA can use the network. Allow it on **private networks**. The extension only connects to your own PC.

Leave the scripting window open while you play. It has an **"Adventure Notebook"** tab that shows your party, current battle and latest events.

> mGBA only runs scripts while the game is running. A paused emulator does not answer SillyTavern.
> After loading a save state from much later in the game, the script treats it as a fresh starting point. It does not log the whole difference as new events.

## 3. Play

The extension connects to the game by itself and syncs every 5 seconds. The dot in the notebook header turns green when it is connected. Every new event shows up in the **Log** tab.

---

## The notebook panel

### Notebook tab: works like Author's Note
| Option | What it does |
|---|---|
| **Inject notebook** | Global on/off. |
| **Enabled in this chat** | Per-chat on/off. *On for new chats* (Game tab) sets the default. |
| **Adventure for this chat** | Choose which playthrough this chat follows. "Active game adventure" follows whatever is running in mGBA. |
| **Use custom settings for this chat** | Gives this chat its own template, placement, depth, role and frequency, like Author's Note's chat-specific note. With it off, you edit the defaults for all chats. |
| **Notebook contents** | Switch each part on or off: player's name, location, badges, play time, party, milestones, recent events. A switched-off part disappears from the notebook, together with its heading (player's name off → "the player"). Applies to both modes. |
| **Mode: Live / AI-written** | *Live* rebuilds the notebook from the template before every message. *AI-written* uses a summary written by the AI SillyTavern is connected to. |
| **Update notebook with AI** | Sends the game facts (only the parts you switched on, with a longer event history) and the previous AI notebook to your connected AI, which writes an updated notebook. The result is shown in an editable box and stays saved per adventure. Press it again whenever you want it refreshed. **AI reply length** (default 2000 tokens) caps the answer; reasoning / thinking models need it high enough to think and then write. If the direct request comes back empty, the extension retries through your normal chat preset. Your chat notes and the current battle are still added live. |
| **Notebook template** | The text that gets injected. Placeholders: `{{party}}` `{{party_short}}` `{{party_full}}` `{{recent}}` `{{milestones}}` `{{location}}` `{{badges}}` `{{battle}}` `{{caught}}` `{{visited}}` `{{player}}` `{{game}}` `{{money}}` `{{playtime}}` `{{last_event}}` `{{notes}}`. SillyTavern macros (`{{user}}`, `{{char}}`, …) also work. |
| **Chat notes** | Your own notes for this chat (Nuzlocke rules, story beats, relationships). They fill `{{notes}}`. |
| **Placement** | Before Main Prompt / After Main Prompt / In-chat @ Depth, with a System, User or Assistant role. Same as Author's Note. |
| **Frequency** | Insert every N user messages (0 = off, 1 = always). Shows a countdown like Author's Note. |
| **Include in World Info scanning** | Lets lorebook entries trigger on the notebook text. |
| **Current party** | Your team at a glance: gender (♂ / ♀ / ∅), nature, HP, and a gold sparkle next to the level of shiny Pokémon. |
| **What goes into the notebook** | How many recent events and milestones to include, the minimum importance, how detailed the party is, whether to include **gender** and **nature**, whether to show the **play time next to events** (also applies to what the AI gets), and which kinds of events to include. |
| **Preview** | Exactly what will be sent, with a token count. |

### Log tab
* Click any line to **edit** it. Edits are kept when new events sync in.
* **★** sets importance from 0 to 3. Importance 3 = milestone (badges, gym leaders, Elite Four, Champion, shiny catches).
* 📌 pins an event to the milestones. 👁 hides it from the prompt. 🗑 deletes it.
* **Add** writes your own entries into the story log.
* **Wild natures** shows or hides wild Pokémon's natures, in the log and in the prompt.
* **New member natures** does the same for Pokémon joining your team: catches, gifts, hatched Eggs and PC withdrawals.

### Game tab
* Bridge address. Change it if you set another port in `notebook_config.lua`, or run SillyTavern on another device. In that case, use the PC's LAN IP, e.g. `http://192.168.1.20:8888`.
* Live party with HP, status, moves and held items, plus the current battle.
* Adventures list: one per save file (game + trainer name + ID). From here you can **import** a `mgba\logs\*.jsonl` file, e.g. to catch up after playing with SillyTavern closed, or **export** an adventure.

### Data tab
Browse what the script read out of the ROM: Pokémon, moves, abilities, items, types, map names, trainers and trainer classes. Romhacks show their own names here.

### Macros for anywhere in SillyTavern
`{{pkmn_notebook}}` `{{pkmn_party}}` `{{pkmn_location}}` `{{pkmn_recent}}` `{{pkmn_milestones}}` `{{pkmn_badges}}` `{{pkmn_battle}}` `{{pkmn_last_event}}`. You can use them in character cards, lorebooks, Quick Replies and the real Author's Note.

---

## What gets logged
| Event | Example |
|---|---|
| New area | *Arrived at Route 104 for the first time* |
| Trainer battles | *Defeated Leader Roxanne (Geodude Lv12, Nosepass Lv15)* · *Lost to Rival May (…) and blacked out* |
| Wild encounters | *Encountered a wild Zigzagoon (Lv3, Timid nature) — ran away*. Logged when the battle starts, then updated with the result: defeated it / ran away / it fled / caught it! / blacked out. The **Wild natures** checkbox in the Log tab shows or hides the nature. |
| Catches | *Caught Ziggy the Zigzagoon (Lv3, Timid nature) at Route 101*, also when sent to the PC |
| Party | *Ziggy (Lv5, Jolly nature) joined the party*, left the party, received an Egg, Egg hatched, nicknames |
| Growth | level-ups, evolutions, moves learned (and forgotten) |
| Faints | *Ziggy fainted against Leader Roxanne* (useful for Nuzlockes) |
| Milestones | badges (with their names), becoming Champion |
| Healing | *The whole party was healed* (Pokémon Center, mom, healers…) |
| PC | *Deposited Ziggy (Lv8) in the PC* · *Withdrew Ziggy (Lv8) from the PC* |
| Poké Mart | *Visited the Poké Mart in Oldale Town and bought some Potions and a Repel*. Quantities are generalized: 1 = "a", 2–5 = "some", more = "many". Sales are noted too. A Mart is recognized after the first purchase made in it; from then on, visits without buying are logged as well. |
| Key items | *Obtained the Mach Bike (key item)* |
| Live state | location, party (HP, status, moves, gender, nature, shiny, item, where met), badges, money, play time, current battle |

## How it works with romhacks
**Names.** Pokémon, moves, items, abilities, types, maps, trainers and trainer classes are read straight out of the ROM. The script tries, in order:
1. the pointers in Game Freak's ROM header,
2. pointers inside the original game code (for binary hacks that moved tables),
3. anchor entries in any letter case (e.g. Bulbasaur → Ivysaur, Pound → Karate Chop), as inline tables, structs or pointer tables,
4. structural fallbacks (the "??????????" placeholder species, "Route …" map lists, gym-leader trainer entries).

Results are cached in `mgba\data\`, so the scan only happens once per ROM (under a second).

**Memory.** The script first checks the base game's RAM layout (Emerald or FireRed). This works for vanilla games and binary hacks, and gives *exact* battle tracking with real outcomes and trainer IDs. If the layout doesn't match, which happens with decomp hacks built on pokeemerald or pokeemerald-expansion, the script **auto-detects** the party, the save data and the map header in RAM. Battles are then tracked from the enemy party: HP, catches, player movement, and the "LEADER ROXANNE"-style battle text for trainer names. The Game tab shows which mode is active.

### Tested games (real ROMs + savestates)
| Game | Names from ROM | Memory | Notes |
|---|---|---|---|
| FireRed, Emerald (vanilla) | ✓ | exact | |
| Clover | ✓ fakemon, custom map names | exact | spoofs an Emerald game code, detected as FireRed |
| GhostGrey | ✓ | exact | |
| Moemon Mega FireRed / Moemon Star Emerald | ✓ | exact | identified a Champion Steven battle in progress |
| AlteRed with Gun, Pokémon WTF | ✓ incl. custom types | exact | |
| Pokémon Odyssey | ✓ custom region | exact | stores Pokémon unencrypted (CFRU), supported |
| Pokémon Pisces, Pokémon Hodgepodge | ✓ 1400+ species | auto-detected | battles tracked from the enemy party |
| Emerald Seaglass, Lazarus, Wishes of Tomorrow, Monomyth, Super Mariomon | ✓ names | auto-detected (expected) | no savestates to test memory with; Mariomon's trainer list wasn't found, so trainer names come from battle text only |

### Game name
The Game tab and the notebook use the **ROM's file name** (e.g. *Pokemon Pisces*) instead of the name stored inside the ROM, which romhacks usually leave as their base game. The script reads it from mGBA's recent-files list (`qt.ini`). If it shows the internal name instead, set `romName` in `notebook_config.lua`, or `mgbaFolder` if your `qt.ini` lives somewhere unusual.

### Overrides
* `symFile` in `notebook_config.lua`: a decomp hack's `.sym` file gives exact RAM addresses, including exact battle tracking.
* `addressOverrides`: set individual addresses.
* `forceProfile`: force `"E"`, `"FR"` or `"RS"`.
* `badgeNames`: your hack's badge names.
* Not supported: non-English base ROMs, and Game Boy / Game Boy Color games (Gen 1–2).

## Troubleshooting
| Problem | Fix |
|---|---|
| Red dot / "Not connected" | Is the script loaded and the game unpaused? Check that the scripting window shows "listening on …8888". Then press **Connect** on the Game tab. |
| "Could not open port 8888" | Another copy of the script, or another program, is using it. Reload mGBA's script, or change `port` in `notebook_config.lua` and update the address in the Game tab. |
| Names show as "Pokémon #123" | The ROM scan didn't find that table. The scripting window lists what was found. Open an issue with that output. |
| Location shows "Map 3.5" | Map names weren't found for this hack. Events still log, just without names. |
| Battles in an auto-detected hack | In auto-detected mode a battle is only finalised once you win, lose, catch, or take a step. If a trainer name is missing, the battle text wasn't readable. A `.sym` file gives exact tracking. |
| Scripting window says "waiting" | Load your save (Continue). On a brand-new game, tracking starts once you have your first Pokémon. |
| mGBA closes when loading the script | Open `notebook_debug.log` next to the script. Its last line shows the step mGBA reached. Please open an issue with that file. |
| "AI update failed" | Make sure a chat is open and a normal message works. With a reasoning / thinking model, raise **AI reply length** on the Notebook tab, or lower the reasoning effort. The browser console (F12) shows each attempt's error. |
| Need to rescan the ROM | Delete the matching file in `mgba\data\`. |

## Files
```
├─ manifest.json, index.js, style.css   ← the SillyTavern extension
├─ README.md
└─ mgba/
   ├─ pkmn_notebook.lua      ← load this in mGBA
   ├─ notebook_config.lua    ← port, options, romhack overrides
   ├─ logs/                  ← one .jsonl log per adventure (save file)
   └─ data/                  ← cached ROM data per game
```
