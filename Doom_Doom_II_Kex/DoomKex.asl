state("doom") {}
state("doom_egs") {}
state("doom_gog") {}
state("osiris2_WinStore") {}

startup
{
	settings.Add("ilMode", false, "IL mode :: reset on map start, start on player control, sync to igt");
	settings.SetToolTip("ilMode", "igt syncing requires Compare Against -> Game Time");

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
		{ "isInGameOffset1", new SigScanTarget(20, "33 C0 89 42 ?? 48 8B 93 ?? ?? ?? ?? 88 83 ?? ?? ?? ?? 88 83") },
		{ "isInGameOffset2", new SigScanTarget(24, "74 0C E8 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 4C 8B 15 ?? ?? ?? ?? 40 88") },
		{ "musicName1", new SigScanTarget(3, "48 8B 0D ?? ?? ?? ?? E8 ?? ?? ?? ?? 85 C0 74 ?? 48 8B CB E8 ?? ?? ?? ?? 48 8D 7B") },
		{ "musicName2", new SigScanTarget(7, "84 C0 ?? ?? 4C 8B 0D ?? ?? ?? ?? 4D 3B CF ?? ?? ?? ?? ?? ?? 4D 8B D7") },
		{ "mapTicOffset1", new SigScanTarget(15, "FF 80 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 8B ?? ?? ?? ?? ?? B0 ?? 89 8F") },
		{ "mapTicOffset2", new SigScanTarget(3, "48 63 88 ?? ?? ?? ?? 48 69 D9 ?? ?? ?? ?? 83 3D ?? ?? ?? ?? 01") },
		{ "isMeltScreenOffset1", new SigScanTarget(2, "C6 83 ?? ?? ?? ?? 01 E8 ?? ?? ?? ?? 48 8B 1D ?? ?? ?? ?? 4C 63 C7 40 B7 01") },
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

			if (results.Count == 5)
			{
				string musicName = new DeepPointer(results["musicName"], 0x0).DerefString(game, 128);
				if (!string.IsNullOrEmpty(musicName))
				{
					vars.Watchers = new MemoryWatcherList
					{
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
						new MemoryWatcher<byte>(new DeepPointer(results["baseAddress"], (int)results["isMeltScreenOffset"]))
						{
							Name = "isMeltScreen"
						}
					};

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

	if (vars.Watchers["musicName"].Changed)
	{
		vars.Log("\"" + vars.Watchers["musicName"].Old + "\"" + " -> " + "\"" + vars.Watchers["musicName"].Current + "\"");
	}
}

isLoading
{
	return settings["ilMode"];
}

gameTime
{
	if (settings["ilMode"])
	{
		return TimeSpan.FromSeconds(vars.Watchers["mapTic"].Current / 35.0f);
	}

	if (!settings["ilMode"] && timer.LoadingTimes != TimeSpan.Zero)
	{
		timer.LoadingTimes = TimeSpan.Zero;
	}
}

reset
{
	return vars.Watchers["isInGame"].Current == 0 && vars.Title.Contains(vars.Watchers["musicName"].Current.ToUpper()) ||
	vars.Watchers["musicName"].Current == "" && vars.Watchers["mapTic"].Current == 0 ||
	settings["ilMode"] && vars.Watchers["mapTic"].Current > 0 && vars.Watchers["mapTic"].Current < 10 && (vars.Watchers["mapTic"].Current < vars.Watchers["mapTic"].Old || vars.Watchers["mapTic"].Old == 0);
}

split
{
	return vars.Watchers["musicName"].Current.ToUpper() != vars.Watchers["musicName"].Old.ToUpper() && vars.Intermission.Contains(vars.Watchers["musicName"].Current.ToUpper());
}

start
{
	return vars.Watchers["isInGame"].Current == 1 && !vars.Intermission.Contains(vars.Watchers["musicName"].Current.ToUpper()) &&
	(!settings["ilMode"] && vars.Watchers["isMeltScreen"].Current == 1 && vars.Watchers["isMeltScreen"].Old == 0 ||
	vars.Watchers["mapTic"].Current > vars.Watchers["mapTic"].Old && vars.Watchers["mapTic"].Current > 1 && vars.Watchers["mapTic"].Current < 10);
}

exit
{
	vars.CancelSource.Cancel();
}

shutdown
{
	vars.CancelSource.Cancel();
}

// v0.1.4 15-Mar-2025
