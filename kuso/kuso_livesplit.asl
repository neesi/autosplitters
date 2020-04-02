state("kuso", "Could not load game.") { }

state("kuso", "kuso") {

  int    LevelID    : 0x6C2DB8;
  double Framecount : 0x4B2780, 0x2C, 0x10, 0x90, 0x80;
}

startup {

  refreshRate    = 120;
  vars.GameRetry = 0;
  vars.GameStop  = "Could not load game.";

  settings.Add("",                                                                     false);
  settings.Add("                      LiveSplit autosplitter for LOVE 2: kuso",        false);
  settings.Add(" ",                                                                    false);
  settings.Add("   - Autostarts the timer.",                                           false);
  settings.Add("   - Autosplits after each level, so make a total of:",                false);
  settings.Add("       25 Split Segments for kuso level set.",                         false);
  settings.Add("       16 Split Segments for LOVE level set.",                         false);
  settings.Add("       41 Split Segments for LOVE + kuso level set.",                  false);
  settings.Add("   - Autoresets, except after the final split (completed run).",       false);
  settings.Add("  ",                                                                   false);
  settings.Add("   Right-click Splits -> Compare Against: Game Time (important).",     false);
  settings.Add("   \"Game Time\" stays in sync with the game's framecounter.",         false);
  settings.Add("   ",                                                                  false);
  settings.Add("-------------------------------------------------------------------------------------------",  false);
  settings.Add("IL_Splits_kuso", true, "  <----  Enable automatic splits for IL mode.");
  settings.Add("------------------------------------------------------------------------------------------- ", false);
  settings.Add("    ",                                                                 false);
  settings.Add("   If you see \"Game Version: Could not load game.\" near top-right,", false);
  settings.Add("   there may have been an update for kuso and this script needs",      false);
  settings.Add("   to be updated as well to work with the game's new version.",        false);
  settings.Add("     ",                                                                false);
  settings.Add("   I'll check up on kuso updates every once in a while (or not).",     false);
  settings.Add("      ",                                                               false);
  settings.Add("   v0.0.5-p3  02-Apr-2020    https://neesi.github.io/autosplitters/",  false);
}

init {

  vars.GameRetry++;
  vars.GameFailed  = "Game failed to load. Retrying (" + vars.GameRetry + ")";
  vars.GameSize    = modules.First().ModuleMemorySize;
  vars.GameVersion = modules.First().FileVersionInfo.FileVersion;
  vars.GameCopr    = modules.First().FileVersionInfo.LegalCopyright;

  print("ModuleMemorySize = \"" + vars.GameSize.ToString() + "\"");
  print("FileVersion      = \"" + vars.GameVersion.ToString() + "\"");
  print("LegalCopyright   = \"" + vars.GameCopr.ToString() + "\"");

  if      (vars.GameRetry > 50)               { version = vars.GameStop; vars.GameRetry = 0; }
  else if (vars.GameSize != 7659520)          { throw new Exception(vars.GameFailed); }
  else if (vars.GameCopr == "Fred Wood 2017") { version = "kuso"; }
  else                                        { version = vars.GameStop; vars.GameRetry = 0; }
}

update { if (version == vars.GameStop) { return false; } }

exit   { vars.GameRetry = 0; } isLoading { return true; } gameTime { return TimeSpan.FromSeconds(current.Framecount / 60); }

reset  { if (current.LevelID <= 54 && current.Framecount < old.Framecount || current.LevelID < 3 || current.LevelID > 54 && current.LevelID < 62) { return true; } }

split  { if (current.LevelID == old.LevelID + 1 || current.LevelID != old.LevelID && (current.LevelID == 62 || current.LevelID == 63 && settings["IL_Splits_kuso"] || current.LevelID == 65)) { return true; } }

start  { if (current.LevelID >= 3 && current.LevelID <= 54) { return true; } }