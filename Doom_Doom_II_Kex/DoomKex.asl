/*
	Doom + Doom II Kex

	- tested on a few maps only
	- tested steam and gog only
*/

state("doom") {}
state("doom_gog") {}

startup
{
	refreshRate = 120;
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
		{ "BaseAddress1", new SigScanTarget(3, "48 8B 05 ?? ?? ?? ?? 33 F6 89 35 ?? ?? ?? ?? 48 89 05 ?? ?? ?? ?? 48 85 C0") },
		{ "BaseAddress2", new SigScanTarget(11, "48 8B CF E8 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 48 89 05 ?? ?? ?? ?? 48 85 C0") },
		{ "GameTic1", new SigScanTarget(6, "41 8B D1 4C 89 0D ?? ?? ?? ?? 48 ?? ?? ?? E9 ?? ?? ?? ?? CC") },
		{ "GameTic2", new SigScanTarget(22, "48 89 05 ?? ?? ?? ?? 8B 05 ?? ?? ?? ?? 3B 05 ?? ?? ?? ?? 48 89 1D") },
		{ "IsInGame_offset1", new SigScanTarget(22, "E8 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 4C 8B 15 ?? ?? ?? ?? 40 88") },
		{ "IsInGame_offset2", new SigScanTarget(20, "33 C0 89 42 ?? 48 8B 93 ?? ?? ?? ?? 88 83 ?? ?? ?? ?? 88 83") },
		{ "MusicName1", new SigScanTarget(7, "84 C0 ?? ?? 4C 8B 0D ?? ?? ?? ?? 4D 3B CF ?? ?? ?? ?? ?? ?? 4D") },
		{ "MusicName2", new SigScanTarget(19, "48 85 DB ?? ?? ?? ?? ?? ?? 48 8D 15 ?? ?? ?? ?? 48 8B 0D ?? ?? ?? ?? E8") },
		{ "MapTic_offset1", new SigScanTarget(15, "FF 80 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 8B ?? ?? ?? ?? ?? B0 01") },
		{ "MapTic_offset2", new SigScanTarget(3, "48 63 88 ?? ?? ?? ?? 48 69 D9 ?? ?? ?? ?? 83 3D ?? ?? ?? ?? 01") },
		{ "GameTicSaved_offset1", new SigScanTarget(2, "89 87 ?? ?? ?? ?? 89 9F ?? ?? ?? ?? E8 ?? ?? ?? ?? 48 89") },
		{ "GameTicSaved_offset2", new SigScanTarget(17, "44 8B 80 ?? ?? ?? ?? 48 8D 0D ?? ?? ?? ?? 44 2B 80 ?? ?? ?? ?? 8B 90") },
		{ "IsMeltScreen_offset1", new SigScanTarget(2, "C6 83 ?? ?? ?? ?? 00 E8 ?? ?? ?? ?? 48 8B ?? ?? ?? ?? ?? 48 8B ?? ?? ?? ?? ?? E8") },
		{ "IsMeltScreen_offset2", new SigScanTarget(16, "8B 83 ?? ?? ?? ?? 8B F8 2B BB ?? ?? ?? ?? 80 BB ?? ?? ?? ?? 00 8B AB") }
	};

	foreach (KeyValuePair<string, SigScanTarget> target in vars.Targets)
	{
		string key = target.Key.Remove(target.Key.Length - 1);
		target.Value.OnFound = (proc, scan, result) => key.EndsWith("_offset") ? (IntPtr)proc.ReadValue<int>(result) : result + 0x4 + proc.ReadValue<int>(result);
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
		while (true)
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
				IntPtr address = game.ReadPointer(results["MusicName"]);
				string musicName = game.ReadString(address, 255) ?? "";
				long gameTic = game.ReadValue<long>(results["GameTic"]);

				if (musicName != "" || gameTic > 0)
				{
					vars.Watchers = new MemoryWatcherList
					{
						new MemoryWatcher<long>(results["GameTic"])
						{ Name = "GameTic" },
						new MemoryWatcher<byte>(new DeepPointer(results["BaseAddress"], (int)results["IsInGame_offset"]))
						{ Name = "IsInGame", FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull },
						new StringWatcher(new DeepPointer(results["MusicName"], 0x0), 255)
						{ Name = "MusicName" },
						new MemoryWatcher<int>(new DeepPointer(results["BaseAddress"], (int)results["MapTic_offset"]))
						{ Name = "MapTic", FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull },
						new MemoryWatcher<int>(new DeepPointer(results["BaseAddress"], (int)results["GameTicSaved_offset"]))
						{ Name = "GameTicSaved", FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull },
						new MemoryWatcher<byte>(new DeepPointer(results["BaseAddress"], (int)results["IsMeltScreen_offset"]))
						{ Name = "IsMeltScreen", FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull }
					};

					if (settings["gameTime"])
					{
						timer.CurrentTimingMethod = TimingMethod.GameTime;
					}

					vars.TargetsFound = true;
					break;
				}

				vars.Log("MusicName = " + "\"" + musicName + "\"" + " GameTic = " + gameTic);
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

	if (vars.Watchers["GameTic"].Current < vars.Watchers["GameTic"].Old)
	{
		vars.StartTic = 0;
	}

	if (vars.Watchers["MusicName"].Changed)
	{
		vars.Log("\"" + vars.Watchers["MusicName"].Old + "\"" + " -> " + "\"" + vars.Watchers["MusicName"].Current + "\"");
	}
}

start
{
	if (settings.StartEnabled && vars.Watchers["IsInGame"].Current == 1 &&
	(!settings["ilMode"] && vars.Watchers["IsMeltScreen"].Current == 1 && vars.Watchers["IsMeltScreen"].Old == 0 && !vars.Intermission.Contains(vars.Watchers["MusicName"].Current.ToUpper()) ||
	vars.Watchers["MapTic"].Current > vars.Watchers["MapTic"].Old && vars.Watchers["MapTic"].Current > 1 && vars.Watchers["MapTic"].Current < 10 && vars.Watchers["MapTic"].Old > 0))
	{
		vars.AutoStarted = true;
		return true;
	}
}

onStart
{
	vars.StartTic = vars.AutoStarted ? vars.Watchers["GameTicSaved"].Current : vars.Watchers["GameTic"].Current;
}

split
{
	return vars.Watchers["MusicName"].Current.ToUpper() != vars.Watchers["MusicName"].Old.ToUpper() && vars.Intermission.Contains(vars.Watchers["MusicName"].Current.ToUpper());
}

reset
{
	return vars.Watchers["IsInGame"].Current == 0 ||
	settings["ilMode"] && vars.Watchers["MapTic"].Current > 0 && vars.Watchers["MapTic"].Current < 10 && (vars.Watchers["MapTic"].Current < vars.Watchers["MapTic"].Old || vars.Watchers["MapTic"].Old == 0);
}

onReset
{
	vars.AutoStarted = false;
	vars.StartTic = 0;
}

gameTime
{
	return settings["ilMode"] ? TimeSpan.FromSeconds(vars.Watchers["MapTic"].Current / 35.0f) : TimeSpan.FromSeconds((vars.Watchers["GameTic"].Current - vars.StartTic) / 35.0f);
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

// v0.0.4 08-Feb-2025
