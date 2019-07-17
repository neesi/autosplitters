state("Love", "Could not load game.") { }

state("Love", "LOVE") {

  int    LevelID     : 0x6AC9F0;
  int    LevelActive : 0x49A5C8, 0x00, 0xCC, 0x0C, 0xCC;
  double Framecount  : 0x49C3E0, 0x60, 0x10, 0x64, 0x00;
}

startup {

  refreshRate    = 60;
  vars.GameRetry = 0;
  vars.GameStop  = "Could not load game.";

  settings.Add("",                                                                     false);
  settings.Add("                            LiveSplit autosplitter for LOVE",          false);
  settings.Add(" ",                                                                    false);
  settings.Add("   - Autostarts the timer.",                                           false);
  settings.Add("   - Autosplits after each level, so make a total of:",                false);
  settings.Add("       16 Split Segments for full level set.",                         false);
  settings.Add("         7 Split Segments for remix mode.",                            false);
  settings.Add("   - Autoresets, except after the final split (completed run).",       false);
  settings.Add("  ",                                                                   false);
  settings.Add("   Right-click Splits -> Compare Against: Game Time (important).",     false);
  settings.Add("   \"Game Time\" stays in sync with the game's framecounter.",         false);
  settings.Add("   ",                                                                  false);
  settings.Add("-------------------------------------------------------------------------------------------",  false);
  settings.Add("IL_Splits_LOVE", true, "  <----  Enable automatic splits for IL mode.");
  settings.Add("------------------------------------------------------------------------------------------- ", false);
  settings.Add("    ",                                                                 false);
  settings.Add("   If you see \"Game Version: Could not load game.\" near top-right,", false);
  settings.Add("   there may have been an update for LOVE and this script needs",      false);
  settings.Add("   to be updated as well to work with the game's new version.",        false);
  settings.Add("     ",                                                                false);
  settings.Add("   I'll check up on LOVE updates every once in a while (or not).",     false);
  settings.Add("      ",                                                               false);
  settings.Add("   v0.0.4-p0  14-Jul-2019    https://neesi.github.io/autosplitters/",  false);
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

  if      (vars.GameRetry > 50)                    { version = vars.GameStop; vars.GameRetry = 0; }
  else if (vars.GameSize != 7892992)               { throw new Exception(vars.GameFailed); }
  else if (vars.GameCopr == "2014-2018 Fred Wood") { version = "LOVE"; }
  else                                             { version = vars.GameStop; vars.GameRetry = 0; }
}

update { if (version == vars.GameStop) { return false; } }

exit   { vars.GameRetry = 0; } isLoading { return true; } gameTime { return TimeSpan.FromSeconds(current.Framecount / 30); }

reset  { if (current.Framecount < old.Framecount || current.LevelID < 4 || current.LevelID == 24) { return true; } }

split  { if (current.LevelID == old.LevelID + 1 || current.LevelID != old.LevelID && (current.LevelID == 22 && settings["IL_Splits_LOVE"])) { return true; } }

start  { if (current.LevelActive == 1 && current.LevelID != 25) { return true; } }