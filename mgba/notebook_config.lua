-- PKMN Adventure Notebook — settings for the mGBA script.
-- Edit the values below, save, then reload pkmn_notebook.lua in mGBA (Tools > Scripting > File > Load script).
-- Anything you delete falls back to the default.
return {
  -- TCP port the SillyTavern extension connects to (http://127.0.0.1:<port>).
  port = 8888,

  -- How often the game is checked, in frames (60 frames = 1 second).
  pollFrames = 20,

  -- Write every event to logs/<adventure>.jsonl so nothing is lost when SillyTavern is closed.
  writeLogFile = true,

  -- Log wild battles you ran from / won. Catches are always logged.
  logWildBattles = true,

  -- Log every move learned / forgotten.
  logMoveChanges = true,

  -- Show a status panel ("Adventure Notebook") in mGBA's scripting window.
  showConsoleBuffer = true,

  -- Optional: path to a .sym file from a decomp-based romhack (pokeemerald / pokefirered builds).
  -- RAM addresses (gPlayerParty, gBattleOutcome, gMapHeader ...) are read from it, which makes
  -- romhacks that moved memory around work. Example: [[C:\romhacks\myhack\pokeemerald.sym]]
  symFile = nil,

  -- Optional: force a memory profile instead of auto-detecting: "E" (Emerald), "FR" (FireRed/LeafGreen), "RS" (Ruby/Sapphire)
  forceProfile = nil,

  -- Optional: override individual RAM addresses (numbers), e.g. { outcome = 0x0202433A }.
  -- Keys: party, partyCount, enemy, sb1ptr, sb2ptr, sb1, sb2, battleType, outcome, opponentA, mapHeader, flagsOff, badgeFlag
  addressOverrides = {},

  -- Optional: name shown for the game. By default the ROM's file name is used (read from mGBA's
  -- recent-files list in qt.ini). Set this if the wrong name shows, e.g. romName = "Pokemon Unbound",
  romName = nil,

  -- Optional: folder containing mGBA's qt.ini, if it isn't found automatically.
  -- e.g. mgbaFolder = [[C:\Users\me\Documents\emulators\mGBA-0.10.2-win64]],
  mgbaFolder = nil,

  -- Optional: badge names for your romhack (8 entries). Leave nil to use the base game's names.
  badgeNames = nil,
}
