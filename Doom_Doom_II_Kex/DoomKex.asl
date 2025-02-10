state("doom") {}
state("doom_egs") {}
state("doom_gog") {}
state("osiris2_WinStore") {}

startup
{
	settings.Add("gameTime", true, "Game Time :: change timing method on script initialization");
	settings.Add("ilMode", false, "IL mode :: reset on map start, start after screen melt");

	vars.Log = (Action<object>)(input =>
	{
		print("[Doom + Doom II] " + input);
	});

	vars.Intermission = new List<string>
	{
		"D_INTER",
		"D_DM2INT"
	};

	vars.Targets = new Dictionary<string, SigScanTarget>
	{
		{ "baseAddress1", new SigScanTarget(3, "48 8B 05 ?? ?? ?? ?? 33 F6 89 35 ?? ?? ?? ?? 48 89 05 ?? ?? ?? ?? 48 85 C0") },
		{ "baseAddress2", new SigScanTarget(11, "48 8B CF E8 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 48 89 05 ?? ?? ?? ?? 48 85 C0") },
		{ "gameTic1", new SigScanTarget(6, "41 8B D1 4C 89 0D ?? ?? ?? ?? 48 ?? ?? ?? E9 ?? ?? ?? ?? CC") },
		{ "gameTic2", new SigScanTarget(22, "48 89 05 ?? ?? ?? ?? 8B 05 ?? ?? ?? ?? 3B 05 ?? ?? ?? ?? 48 89 1D") },
		{ "isInGameOffset1", new SigScanTarget(22, "E8 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 4C 8B 15 ?? ?? ?? ?? 40 88") },
		{ "isInGameOffset2", new SigScanTarget(20, "33 C0 89 42 ?? 48 8B 93 ?? ?? ?? ?? 88 83 ?? ?? ?? ?? 88 83") },
		{ "musicName1", new SigScanTarget(7, "84 C0 ?? ?? 4C 8B 0D ?? ?? ?? ?? 4D 3B CF ?? ?? ?? ?? ?? ?? 4D") },
		{ "musicName2", new SigScanTarget(19, "48 85 DB ?? ?? ?? ?? ?? ?? 48 8D 15 ?? ?? ?? ?? 48 8B 0D ?? ?? ?? ?? E8") },
		{ "mapTicOffset1", new SigScanTarget(15, "FF 80 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 8B ?? ?? ?? ?? ?? B0 01") },
		{ "mapTicOffset2", new SigScanTarget(3, "48 63 88 ?? ?? ?? ?? 48 69 D9 ?? ?? ?? ?? 83 3D ?? ?? ?? ?? 01") },
		{ "gameTicSavedOffset1", new SigScanTarget(2, "89 87 ?? ?? ?? ?? 89 9F ?? ?? ?? ?? E8 ?? ?? ?? ?? 48 89") },
		{ "gameTicSavedOffset2", new SigScanTarget(17, "44 8B 80 ?? ?? ?? ?? 48 8D 0D ?? ?? ?? ?? 44 2B 80 ?? ?? ?? ?? 8B 90") },
		{ "isMeltScreenOffset1", new SigScanTarget(2, "C6 83 ?? ?? ?? ?? 00 E8 ?? ?? ?? ?? 48 8B ?? ?? ?? ?? ?? 48 8B ?? ?? ?? ?? ?? E8") },
		{ "isMeltScreenOffset2", new SigScanTarget(16, "8B 83 ?? ?? ?? ?? 8B F8 2B BB ?? ?? ?? ?? 80 BB ?? ?? ?? ?? 00 8B AB") }
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
	vars.AutoStarted = false;
	vars.StartTic = 0;

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

			if (results.Count == 7)
			{
				IntPtr address = game.ReadPointer(results["musicName"]);
				string musicName = game.ReadString(address, 128);
				long gameTic = game.ReadValue<long>(results["gameTic"]);

				if (!string.IsNullOrEmpty(musicName) || (musicName != null && gameTic > 0))
				{
					vars.Watchers = new MemoryWatcherList
					{
						new MemoryWatcher<long>(results["gameTic"])
						{ Name = "gameTic" },
						new MemoryWatcher<byte>(new DeepPointer(results["baseAddress"], (int)results["isInGameOffset"]))
						{ Name = "isInGame", FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull },
						new StringWatcher(new DeepPointer(results["musicName"], 0x0), 128)
						{ Name = "musicName" },
						new MemoryWatcher<int>(new DeepPointer(results["baseAddress"], (int)results["mapTicOffset"]))
						{ Name = "mapTic", FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull },
						new MemoryWatcher<int>(new DeepPointer(results["baseAddress"], (int)results["gameTicSavedOffset"]))
						{ Name = "gameTicSaved", FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull },
						new MemoryWatcher<byte>(new DeepPointer(results["baseAddress"], (int)results["isMeltScreenOffset"]))
						{ Name = "isMeltScreen", FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull }
					};

					if (settings["gameTime"])
					{
						timer.CurrentTimingMethod = TimingMethod.GameTime;
					}

					vars.TargetsFound = true;
					break;
				}

				vars.Log("musicName = " + "\"" + musicName + "\"" + " gameTic = " + gameTic);
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

	if (vars.Watchers["gameTic"].Current < vars.Watchers["gameTic"].Old)
	{
		vars.StartTic = 0;
	}

	if (vars.Watchers["musicName"].Changed)
	{
		vars.Log("\"" + vars.Watchers["musicName"].Old + "\"" + " -> " + "\"" + vars.Watchers["musicName"].Current + "\"");
	}
}

start
{
	if (settings.StartEnabled && vars.Watchers["isInGame"].Current == 1 &&
	(!settings["ilMode"] && vars.Watchers["isMeltScreen"].Current == 1 && vars.Watchers["isMeltScreen"].Old == 0 && !vars.Intermission.Contains(vars.Watchers["musicName"].Current.ToUpper()) ||
	vars.Watchers["mapTic"].Current > vars.Watchers["mapTic"].Old && vars.Watchers["mapTic"].Current > 1 && vars.Watchers["mapTic"].Current < 10 && vars.Watchers["mapTic"].Old > 0))
	{
		vars.AutoStarted = true;
		return true;
	}
}

onStart
{
	vars.StartTic = vars.AutoStarted ? vars.Watchers["gameTicSaved"].Current : vars.Watchers["gameTic"].Current;
}

split
{
	return vars.Watchers["musicName"].Current.ToUpper() != vars.Watchers["musicName"].Old.ToUpper() && vars.Intermission.Contains(vars.Watchers["musicName"].Current.ToUpper());
}

reset
{
	return vars.Watchers["isInGame"].Current == 0 ||
	settings["ilMode"] && vars.Watchers["mapTic"].Current > 0 && vars.Watchers["mapTic"].Current < 10 && (vars.Watchers["mapTic"].Current < vars.Watchers["mapTic"].Old || vars.Watchers["mapTic"].Old == 0);
}

onReset
{
	vars.AutoStarted = false;
	vars.StartTic = 0;
}

gameTime
{
	return settings["ilMode"] ? TimeSpan.FromSeconds(vars.Watchers["mapTic"].Current / 35.0f) : TimeSpan.FromSeconds((vars.Watchers["gameTic"].Current - vars.StartTic) / 35.0f);
}

isLoading
{
	return true;
}

exit
{
	vars.CancelSource.Cancel();
}

shutdown
{
	vars.CancelSource.Cancel();
}

// v0.0.6 10-Feb-2025
