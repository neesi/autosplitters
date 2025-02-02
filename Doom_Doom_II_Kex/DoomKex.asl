/*
	Doom + Doom II Kex

	- tested on a few maps only
	- tested steam and gog only
	- script initialization will not complete while in a multiplayer lobby
*/

state("doom") {}
state("doom_gog") {}

startup
{
	settings.Add("gameTime", true, "Game Time :: change timing method on script initialization");
	settings.Add("ilMode", false, "IL mode :: reset on map start, start after screen melt");

	vars.Log = (Action<object>)(input =>
	{
		print("[Doom + Doom II] " + input);
	});

	vars.Targets = new Dictionary<string, SigScanTarget>
	{
		{ "BaseAddress", new SigScanTarget(3, "48 8B 05 ?? ?? ?? ?? 33 F6 89 35 ?? ?? ?? ?? 48 89 05 ?? ?? ?? ?? 48 85 C0") },
		{ "GameTic", new SigScanTarget(6, "41 8B D1 4C 89 0D ?? ?? ?? ?? 48 ?? ?? ?? E9 ?? ?? ?? ?? CC") },
		{ "IsInGame_offset", new SigScanTarget(22, "E8 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 4C 8B 15 ?? ?? ?? ?? 40 88") },
		{ "MusicName", new SigScanTarget(7, "84 C0 ?? ?? 4C 8B 0D ?? ?? ?? ?? 4D 3B CF ?? ?? ?? ?? ?? ?? 4D") },
		{ "MapTic_offset", new SigScanTarget(15, "FF 80 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 8B ?? ?? ?? ?? ?? B0 01") },
		{ "GameTicSaved_offset", new SigScanTarget(2, "89 87 ?? ?? ?? ?? 89 9F ?? ?? ?? ?? E8 ?? ?? ?? ?? 48 89") },
		{ "IsMeltScreen_offset", new SigScanTarget(2, "C6 83 ?? ?? ?? ?? 00 E8 ?? ?? ?? ?? 48 8B ?? ?? ?? ?? ?? 48 8B ?? ?? ?? ?? ?? E8") }
	};

	foreach (KeyValuePair<string, SigScanTarget> target in vars.Targets)
	{
		target.Value.OnFound = (proc, scan, result) => target.Key.EndsWith("_offset") ? (IntPtr)proc.ReadValue<int>(result) : result + 0x4 + proc.ReadValue<int>(result);
	}

	refreshRate = 120;
}

init
{
	vars.TargetsFound = false;
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
				IntPtr result = scanner.Scan(target.Value);
				if (result != IntPtr.Zero)
				{
					results.Add(target.Key, result);
					vars.Log(target.Key + ": 0x" + result.ToString("X"));
				}
			}

			if (results.Count == vars.Targets.Count)
			{
				string musicName = game.ReadString(game.ReadPointer(results["MusicName"]), 255) ?? "";
				if (musicName != "")
				{
					vars.Watchers = new MemoryWatcherList
					{
						new MemoryWatcher<long>(results["GameTic"]) { Name = "GameTic" },
						new MemoryWatcher<byte>(new DeepPointer(results["BaseAddress"], (int)results["IsInGame_offset"])) { Name = "IsInGame", FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull },
						new StringWatcher(new DeepPointer(results["MusicName"], 0x0), 255) { Name = "MusicName" },
						new MemoryWatcher<int>(new DeepPointer(results["BaseAddress"], (int)results["MapTic_offset"])) { Name = "MapTic", FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull },
						new MemoryWatcher<int>(new DeepPointer(results["BaseAddress"], (int)results["GameTicSaved_offset"])) { Name = "GameTicSaved", FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull },
						new MemoryWatcher<byte>(new DeepPointer(results["BaseAddress"], (int)results["IsMeltScreen_offset"])) { Name = "IsMeltScreen", FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull }
					};

					if (settings["gameTime"])
					{
						timer.CurrentTimingMethod = TimingMethod.GameTime;
					}

					vars.TargetsFound = true;
					break;
				}
				else
				{
					vars.Log("Music name must not be empty.");
				}
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

	if (vars.Watchers["MusicName"].Changed)
	{
		vars.Log("\"" + vars.Watchers["MusicName"].Old + "\"" + " -> " + "\"" + vars.Watchers["MusicName"].Current + "\"");
	}
}

start
{
	if (vars.Watchers["IsInGame"].Current == 1 && (!settings["ilMode"] && vars.Watchers["IsMeltScreen"].Current == 1 && vars.Watchers["IsMeltScreen"].Old == 0 ||
	vars.Watchers["MapTic"].Current > vars.Watchers["MapTic"].Old && vars.Watchers["MapTic"].Current > 1 && vars.Watchers["MapTic"].Current < 10 && vars.Watchers["MapTic"].Old > 0))
	{
		vars.StartTic = vars.Watchers["GameTicSaved"].Current;
		return true;
	}
}

split
{
	return vars.Watchers["MusicName"].Current.ToUpper() != vars.Watchers["MusicName"].Old.ToUpper() &&
	(vars.Watchers["MusicName"].Current.ToUpper() == "D_INTER" || vars.Watchers["MusicName"].Current.ToUpper() == "D_DM2INT");
}

reset
{
	if (vars.Watchers["IsInGame"].Current == 0 ||
	settings["ilMode"] && vars.Watchers["MapTic"].Current > 0 && vars.Watchers["MapTic"].Current < 10 && (vars.Watchers["MapTic"].Current < vars.Watchers["MapTic"].Old || vars.Watchers["MapTic"].Old == 0))
	{
		vars.StartTic = 0;
		return true;
	}
}

gameTime
{
	return settings["ilMode"] ? TimeSpan.FromSeconds(vars.Watchers["MapTic"].Current / 35f) : TimeSpan.FromSeconds((vars.Watchers["GameTic"].Current - vars.StartTic) / 35f);
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

// v0.0.1 02-Feb-2025
