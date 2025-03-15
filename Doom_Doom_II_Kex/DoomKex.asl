state("doom") {}
state("doom_egs") {}
state("doom_gog") {}
state("osiris2_WinStore") {}

startup
{
	settings.Add("gameTime", true, "Compare Against -> Game Time on script initialization");
	settings.Add("floatingSecond", false, "Solo Multi-Game / Co-Op Multi-Ep mode :: must enable for these runs");
	settings.Add("ilMode", false, "IL mode :: reset on map start, start on player control, sync to igt");
	settings.SetToolTip("gameTime", "Game Time is more accurate");
	settings.SetToolTip("floatingSecond", "inaccurate time (± 1 tic / run, with Game Time), disables auto reset");
	settings.SetToolTip("ilMode", "overrides Solo Multi-Game / Co-Op Multi-Ep mode, igt syncing requires Compare Against -> Game Time");

	vars.Log = (Action<object>)(input =>
	{
		print("[Doom + Doom II] " + input);
	});

	vars.Title = new List<string>
	{
		"D_INTRO",
		"D_DM2TTL"
	};

	vars.Intermission = new List<string>
	{
		"D_INTER",
		"D_DM2INT"
	};

	vars.Targets = new Dictionary<string, SigScanTarget>
	{
		{ "baseAddress1", new SigScanTarget(3, "48 8B 05 ?? ?? ?? ?? 33 F6 89 35 ?? ?? ?? ?? 48 89 05 ?? ?? ?? ?? 48 85 C0") },
		{ "baseAddress2", new SigScanTarget(13, "40 32 FF 48 8B AE ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 80 BD ?? ?? ?? ?? 00") },
		{ "floatingSecond1", new SigScanTarget(15, "41 57 48 81 EC ?? ?? ?? ?? 48 8B F9 48 8B 2D ?? ?? ?? ?? 48 85 ED") },
		{ "floatingSecond2", new SigScanTarget(17, "0F 57 ?? 0F 57 ?? 48 8B CB E8 ?? ?? ?? ?? 48 8B 0D ?? ?? ?? ?? 48 85 C9") },
		{ "gameTicOffset1", new SigScanTarget(2, "8B 90 ?? ?? ?? ?? 89 90 ?? ?? ?? ?? 8B CA 2B 88 ?? ?? ?? ?? 89 88") },
		{ "gameTicOffset2", new SigScanTarget(6, "48 C1 E6 ?? 8B 83 ?? ?? ?? ?? 8B F8 2B BB ?? ?? ?? ?? 80 BB") },
		{ "gameTicPauseOnMeltOffset1", new SigScanTarget(8, "8B 90 ?? ?? ?? ?? 89 90 ?? ?? ?? ?? 8B CA 2B 88 ?? ?? ?? ?? 89 88") },
		{ "gameTicPauseOnMeltOffset2", new SigScanTarget(2, "8B 88 ?? ?? ?? ?? 89 88 ?? ?? ?? ?? ?? ?? 44 89 A0 ?? ?? ?? ?? 85 D2") },
		{ "isDemoPlayingOffset1", new SigScanTarget(17, "8B 04 ?? 41 89 07 0F B7 ?? ?? 66 41 89 ?? ?? 80 BB") },
		{ "isDemoPlayingOffset2", new SigScanTarget(17, "4D 63 F9 49 63 F0 8B FA 48 8B 1D ?? ?? ?? ?? 80 BB") },
		{ "isInGameOffset1", new SigScanTarget(20, "33 C0 89 42 ?? 48 8B 93 ?? ?? ?? ?? 88 83 ?? ?? ?? ?? 88 83") },
		{ "isInGameOffset2", new SigScanTarget(24, "74 0C E8 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 4C 8B 15 ?? ?? ?? ?? 40 88") },
		{ "musicName1", new SigScanTarget(3, "48 8B 0D ?? ?? ?? ?? E8 ?? ?? ?? ?? 85 C0 74 ?? 48 8B CB E8 ?? ?? ?? ?? 48 8D 7B") },
		{ "musicName2", new SigScanTarget(7, "84 C0 ?? ?? 4C 8B 0D ?? ?? ?? ?? 4D 3B CF ?? ?? ?? ?? ?? ?? 4D 8B D7") },
		{ "mapTicOffset1", new SigScanTarget(15, "FF 80 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 8B ?? ?? ?? ?? ?? B0 ?? 89 8F") },
		{ "mapTicOffset2", new SigScanTarget(3, "48 63 88 ?? ?? ?? ?? 48 69 D9 ?? ?? ?? ?? 83 3D ?? ?? ?? ?? 01") },
		{ "gameTicSavedOffset1", new SigScanTarget(17, "44 8B 80 ?? ?? ?? ?? 48 8D 0D ?? ?? ?? ?? 44 2B 80 ?? ?? ?? ?? 8B 90") },
		{ "gameTicSavedOffset2", new SigScanTarget(8, "8B 87 ?? ?? ?? ?? 89 87 ?? ?? ?? ?? 89 9F ?? ?? ?? ?? E8 ?? ?? ?? ?? 48 89 9F") }
	};

	foreach (KeyValuePair<string, SigScanTarget> target in vars.Targets)
	{
		string key = target.Key.Remove(target.Key.Length - 1);
		target.Value.OnFound = (proc, scan, result) => key.EndsWith("Offset") ? (IntPtr)proc.ReadValue<int>(result) : result + 0x4 + proc.ReadValue<int>(result);
	}
}

init
{
	vars.TargetsFound = false;
	vars.FloatingSecondStartTic = 0;
	vars.StartTic = 0;
	vars.LateSplitTics = 0;
	vars.AutoSplit = false;

	vars.CancelSource = new CancellationTokenSource();
	CancellationToken token = vars.CancelSource.Token;

	System.Threading.Tasks.Task.Run(async () =>
	{
		while (!token.IsCancellationRequested)
		{
			var scanner = new SignatureScanner(game, modules.First().BaseAddress, modules.First().ModuleMemorySize);
			var results = new Dictionary<string, IntPtr>();

			foreach (KeyValuePair<string, SigScanTarget> target in vars.Targets)
			{
				string key = target.Key.Remove(target.Key.Length - 1);
				if (!results.ContainsKey(key))
				{
					IntPtr result = scanner.Scan(target.Value);
					if (result != IntPtr.Zero)
					{
						results.Add(key, result);
						vars.Log(target.Key + ": 0x" + result.ToString("X"));
					}
				}
			}

			if (results.Count == 9)
			{
				string musicName = new DeepPointer(results["musicName"], 0x0).DerefString(game, 128);
				if (!string.IsNullOrEmpty(musicName))
				{
					vars.Watchers = new MemoryWatcherList
					{
						new MemoryWatcher<double>(new DeepPointer(results["floatingSecond"], 0x0))
						{
							Name = "floatingSecond"
						},
						new MemoryWatcher<int>(new DeepPointer(results["baseAddress"], (int)results["gameTicOffset"]))
						{
							Name = "gameTic"
						},
						new MemoryWatcher<int>(new DeepPointer(results["baseAddress"], (int)results["gameTicPauseOnMeltOffset"]))
						{
							Name = "gameTicPauseOnMelt"
						},
						new MemoryWatcher<short>(new DeepPointer(results["baseAddress"], (int)results["isDemoPlayingOffset"]))
						{
							Name = "isDemoPlaying"
						},
						new MemoryWatcher<byte>(new DeepPointer(results["baseAddress"], (int)results["isInGameOffset"]))
						{
							Name = "isInGame"
						},
						new StringWatcher(new DeepPointer(results["musicName"], 0x0), 128)
						{
							Name = "musicName"
						},
						new MemoryWatcher<int>(new DeepPointer(results["baseAddress"], (int)results["mapTicOffset"]))
						{
							Name = "mapTic",
							FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull
						},
						new MemoryWatcher<int>(new DeepPointer(results["baseAddress"], (int)results["gameTicSavedOffset"]))
						{
							Name = "gameTicSaved",
							FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull
						}
					};

					if (settings["gameTime"])
					{
						timer.CurrentTimingMethod = TimingMethod.GameTime;
					}

					vars.TargetsFound = true;
					break;
				}

				vars.Log("Music name must not be null or empty.");
			}

			vars.Log("Retrying..");
			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		vars.Log("Task end.");
	});
}

update
{
	if (!vars.TargetsFound)
	{
		return false;
	}

	vars.Watchers.UpdateAll(game);

	if (vars.Watchers["gameTicPauseOnMelt"].Current < vars.Watchers["gameTicPauseOnMelt"].Old && vars.Watchers["mapTic"].Current == 0 && vars.Watchers["gameTicSaved"].Current == 0)
	{
		vars.StartTic = 0;
	}

	if (vars.Watchers["musicName"].Changed)
	{
		vars.Log("\"" + vars.Watchers["musicName"].Old + "\"" + " -> " + "\"" + vars.Watchers["musicName"].Current + "\"");
	}
}

isLoading
{
	return true;
}

gameTime
{
	if (settings.SplitEnabled && vars.Watchers["musicName"].Current.ToUpper() != vars.Watchers["musicName"].Old.ToUpper() && vars.Intermission.Contains(vars.Watchers["musicName"].Current.ToUpper()))
	{
		int coopGameTics = vars.Watchers["gameTic"].Current - vars.Watchers["gameTicSaved"].Current;
		int coopLateSplitTics = coopGameTics - vars.Watchers["mapTic"].Current;

		if (coopLateSplitTics > 0 && coopLateSplitTics < 10)
		{
			vars.LateSplitTics = vars.Watchers["gameTicSaved"].Current == 0 ? coopLateSplitTics - 1 : coopLateSplitTics;
		}
		else
		{
			vars.LateSplitTics = vars.Watchers["gameTic"].Current - vars.Watchers["gameTicPauseOnMelt"].Current;
		}

		vars.AutoSplit = true;
	}

	if (settings["ilMode"])
	{
		return TimeSpan.FromSeconds(vars.Watchers["mapTic"].Current / 35.0f);
	}

	if (settings["floatingSecond"])
	{
		long currentTic = (long)(vars.Watchers["floatingSecond"].Current * 35.0d);
		return TimeSpan.FromSeconds(((currentTic - vars.FloatingSecondStartTic) - vars.LateSplitTics) / 35.0f);
	}

	return TimeSpan.FromSeconds(((vars.Watchers["gameTic"].Current - vars.StartTic) - vars.LateSplitTics) / 35.0f);
}

reset
{
	return (settings["ilMode"] || !settings["floatingSecond"]) &&
	(vars.Watchers["isInGame"].Current == 0 && (vars.Watchers["isDemoPlaying"].Current == 1 || vars.Title.Contains(vars.Watchers["musicName"].Current.ToUpper())) ||
	vars.Watchers["musicName"].Current == "" && vars.Watchers["mapTic"].Current == 0 && vars.Watchers["gameTicSaved"].Current == 0 ||
	settings["ilMode"] && vars.Watchers["mapTic"].Current > 0 && vars.Watchers["mapTic"].Current < 10 && (vars.Watchers["mapTic"].Current < vars.Watchers["mapTic"].Old || vars.Watchers["mapTic"].Old == 0));
}

onReset
{
	vars.FloatingSecondStartTic = 0;
	vars.StartTic = 0;
	vars.LateSplitTics = 0;
	vars.AutoSplit = false;
}

split
{
	return vars.AutoSplit;
}

onSplit
{
	vars.LateSplitTics = 0;
	vars.AutoSplit = false;
}

start
{
	return vars.Watchers["isInGame"].Current == 1 && vars.Watchers["isDemoPlaying"].Current == 0 && !vars.Intermission.Contains(vars.Watchers["musicName"].Current.ToUpper()) &&
	(!settings["ilMode"] && vars.Watchers["gameTicSaved"].Changed && vars.Watchers["gameTicSaved"].Current > 0 ||
	vars.Watchers["mapTic"].Current > vars.Watchers["mapTic"].Old && vars.Watchers["mapTic"].Current < 10 &&
	(vars.Watchers["gameTicSaved"].Current == 0 && vars.Watchers["mapTic"].Current > 0 || vars.Watchers["mapTic"].Current > 1));
}

onStart
{
	int lateStartTics = Math.Max(0, (vars.Watchers["gameTic"].Current - vars.Watchers["gameTicSaved"].Current) - (vars.Watchers["gameTicSaved"].Current == 0 ? 1 : 0));
	vars.FloatingSecondStartTic = (long)((vars.Watchers["floatingSecond"].Current * 35.0d) - lateStartTics);
	vars.StartTic = vars.Watchers["gameTicSaved"].Current == 0 ? 1 : vars.Watchers["gameTicSaved"].Current;
}

exit
{
	vars.CancelSource.Cancel();
}

shutdown
{
	vars.CancelSource.Cancel();
}

// v0.1.3 15-Mar-2025
