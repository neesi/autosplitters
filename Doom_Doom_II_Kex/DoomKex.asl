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

	vars.Targets = new Dictionary<string, SigScanTarget>
	{
		{ "basePointer1", new SigScanTarget(3, "48 8B 05 ?? ?? ?? ?? 33 F6 89 35 ?? ?? ?? ?? 48 89 05 ?? ?? ?? ?? 48 85 C0") },
		{ "basePointer2", new SigScanTarget(13, "40 32 FF 48 8B AE ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 80 BD ?? ?? ?? ?? 00") },
		{ "isInGameOffset1", new SigScanTarget(20, "33 C0 89 42 ?? 48 8B 93 ?? ?? ?? ?? 88 83 ?? ?? ?? ?? 88 83") },
		{ "isInGameOffset2", new SigScanTarget(24, "74 0C E8 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 4C 8B 15 ?? ?? ?? ?? 40 88") },
		{ "gameStateOffset1", new SigScanTarget(9, "48 8B 06 48 8B 0C ?? 8B 83 ?? ?? ?? ?? 48 89 8B ?? ?? ?? ?? 39 83") },
		{ "gameStateOffset2", new SigScanTarget(8, "8B 83 ?? ?? ?? ?? 89 83 ?? ?? ?? ?? 89 83 ?? ?? ?? ?? 88 4B ?? 85 C0") },
		{ "mapTicOffset1", new SigScanTarget(15, "FF 80 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 8B ?? ?? ?? ?? ?? B0 ?? 89 8F") },
		{ "mapTicOffset2", new SigScanTarget(3, "48 63 88 ?? ?? ?? ?? 48 69 D9 ?? ?? ?? ?? 83 3D ?? ?? ?? ?? 01") }
	};

	foreach (KeyValuePair<string, SigScanTarget> target in vars.Targets)
	{
		bool isOffset = target.Key.Remove(target.Key.Length - 1).EndsWith("Offset");
		target.Value.OnFound = (proc, scan, addr) => isOffset ? (IntPtr)proc.ReadValue<int>(addr) : addr + 0x4 + proc.ReadValue<int>(addr);
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

			if (results.Count == 4)
			{
				IntPtr basePointer = results["basePointer"];
				IntPtr baseAddress = game.ReadPointer(basePointer);

				if (baseAddress != IntPtr.Zero)
				{
					int isInGameOffset = (int)results["isInGameOffset"];
					int gameStateOffset = (int)results["gameStateOffset"];
					int mapTicOffset = (int)results["mapTicOffset"];

					vars.Watchers = new MemoryWatcherList
					{
						new MemoryWatcher<IntPtr>(basePointer)
						{
							Name = "baseAddress"
						},
						new MemoryWatcher<byte>(new DeepPointer(basePointer, isInGameOffset))
						{
							Name = "isInGame"
						},
						new MemoryWatcher<byte>(new DeepPointer(basePointer, gameStateOffset))
						{
							Name = "gameState"
						},
						new MemoryWatcher<int>(new DeepPointer(basePointer, mapTicOffset))
						{
							Name = "mapTic"
						}
					};

					vars.TargetsFound = true;
					break;
				}

				vars.Log("Base address must not be zero.");
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
	return vars.Watchers["baseAddress"].Current == IntPtr.Zero
		|| vars.Watchers["isInGame"].Current == 0 && vars.Watchers["gameState"].Current == 3
		|| settings["ilMode"] && vars.Watchers["mapTic"].Current > 0 && vars.Watchers["mapTic"].Current < 10
		&& (vars.Watchers["mapTic"].Current < vars.Watchers["mapTic"].Old || vars.Watchers["mapTic"].Old == 0);
}

split
{
	return vars.Watchers["gameState"].Changed && vars.Watchers["gameState"].Current == 1 && vars.Watchers["isInGame"].Current == 1;
}

start
{
	return vars.Watchers["baseAddress"].Current != IntPtr.Zero && vars.Watchers["isInGame"].Current == 1 && vars.Watchers["gameState"].Current == 0
		&& ((!settings["ilMode"] && vars.Watchers["mapTic"].Current > 0) || (settings["ilMode"] && vars.Watchers["mapTic"].Current > 1));
}

exit
{
	vars.CancelSource.Cancel();
}

shutdown
{
	vars.CancelSource.Cancel();
}

// v0.1.7 01-Apr-2025
