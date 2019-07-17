state("KUSO", "Could not load game.") { }

state("KUSO", "kuso (demo)") {

  int    LevelID     : 0x5CB860;
  int    LevelActive : 0x3B3E10;
  double Framecount  : 0x3C9734, 0x34, 0x10, 0x88, 0x10;
}

startup {

  refreshRate    = 120;
  vars.GameRetry = 0;
  vars.GameStop  = "Could not load game.";

  settings.Add("                       LiveSplit autosplitter for kuso demo",           false);
  settings.Add("",                                                                      false);
  settings.Add("   Make sure you've read the README  (URL at the bottom)",              false);
  settings.Add(" ",                                                                     false);
  settings.Add("   - Autostarts the timer.",                                            false);
  settings.Add("   - Autosplits after each level, so make a total of:",                 false);
  settings.Add("       3 Split Segments for kuso level set.",                           false);
  settings.Add("       6 Split Segments for LOVE level set.",                           false);
  settings.Add("   - Autoresets, except after the final split (completed run).",        false);
  settings.Add("  ",                                                                    false);
  settings.Add("   Right-click Splits -> Compare Against: Game Time (important).",      false);
  settings.Add("   \"Game Time\" stays in sync with the game's framecounter.",          false);
  settings.Add("   ",                                                                   false);
  settings.Add("-------------------------------------------------------------------------------------------",  false);
  settings.Add("IL_Splits_kuso_demo", true, "  <----  Enable automatic splits for IL mode.");
  settings.Add("------------------------------------------------------------------------------------------- ", false);
  settings.Add("    ",                                                                  false);
  settings.Add("   If you see \"Game Version: Could not load game.\" near top-right,",  false);
  settings.Add("   there may have been an update for kuso demo and this script needs",  false);
  settings.Add("   to be updated as well to work with the game's new version.",         false);
  settings.Add("     ",                                                                 false);
  settings.Add("   I'll check up on kuso demo updates every once in a while (or not).", false);
  settings.Add("      ",                                                                false);
  settings.Add("   v0.0.4-p0  21-Jun-2019    https://neesi.github.io/autosplitters/",   false);
}
init {

  vars.GameRetry++;
  vars.GameSubIL   = 0;
  vars.GameFixIL   = 0;
  vars.GameFailed  = "Game failed to load. Retrying (" + vars.GameRetry + ")";
  vars.GameSize    = modules.First().ModuleMemorySize;
  vars.GameVersion = modules.First().FileVersionInfo.FileVersion;
  vars.GameCopr    = modules.First().FileVersionInfo.LegalCopyright;

  System.Text.RegularExpressions.Regex kusodemoRegex = new System.Text.RegularExpressions.Regex("^ {64}$");
  System.Text.RegularExpressions.Match kusodemoMatch = kusodemoRegex.Match(vars.GameCopr);

  print("ModuleMemorySize = \"" + vars.GameSize.ToString() + "\"");
  print("FileVersion      = \"" + vars.GameVersion.ToString() + "\"");
  print("LegalCopyright   = \"" + vars.GameCopr.ToString() + "\"");

  if      (vars.GameRetry > 50)                               { version = vars.GameStop; vars.GameRetry = 0; }
  else if (vars.GameSize != 6680576)                          { throw new Exception(vars.GameFailed); }
  else if (vars.GameSize == 6680576 && kusodemoMatch.Success) { version = "kuso (demo)"; }
  else                                                        { version = vars.GameStop; vars.GameRetry = 0; }
}

update {

  if (version == vars.GameStop) { return false; }

  if (current.Framecount < vars.GameFixIL)            { vars.GameSubIL = 0; vars.GameFixIL = 0; }
  if (current.LevelID == 4 && current.Framecount > 0) { vars.GameSubIL = current.Framecount; }
}

exit  { vars.GameRetry = 0; } isLoading { return true; } gameTime { return TimeSpan.FromSeconds((current.Framecount - vars.GameFixIL) / 60); }

reset { if (old.LevelID == 4 && current.LevelID > 4) { vars.GameFixIL = vars.GameSubIL; return true; } else if (current.Framecount < old.Framecount || current.LevelID < 4) { vars.GameSubIL = 0; vars.GameFixIL = 0; return true; } }

split { if (current.LevelID == old.LevelID + 1 && old.LevelID != 4 || old.LevelID > 4 && current.LevelID == 4 && settings["IL_Splits_kuso_demo"] || current.LevelID != old.LevelID && (current.LevelID == 15 || current.LevelID == 16)) { return true; } }

start { if (current.LevelActive == 1 && current.LevelID > 4) { return true; } }