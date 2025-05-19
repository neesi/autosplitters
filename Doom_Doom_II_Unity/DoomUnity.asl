state("DOOM") {}
state("DOOM II") {}

startup
{
	settings.Add("ilMode", false, "IL mode :: reset on map start, start on player control, sync to igt");
	settings.SetToolTip("ilMode", "igt syncing requires Compare Against -> Game Time");

	vars.Log = (Action<object>)(output =>
	{
		print("[Doom + Doom II Unity] " + output);
	});

	vars.Targets = new Dictionary<string, SigScanTarget>
	{
		{ "arrayPointer1", new SigScanTarget(3, "48 8B 05 ?? ?? ?? ?? 45 33 ?? 45 8B ?? 44 89 ?? ?? ?? ?? ?? 8B F2") },
		{ "arrayPointer2", new SigScanTarget(3, "48 8B 0D ?? ?? ?? ?? C7 05 ?? ?? ?? ?? ?? ?? ?? ?? 48 89 0D ?? ?? ?? ?? 85 C0") },
		{ "isInGameOffset1", new SigScanTarget(24, "74 0C E8 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 89 ?? ?? ?? ?? ?? FF ?? 89") },
		{ "isInGameOffset2", new SigScanTarget(2, "89 83 ?? ?? ?? ?? 89 83 ?? ?? ?? ?? 89 83 ?? ?? ?? ?? 41 83 F8 03 75") },
		{ "gameStateOffset1", new SigScanTarget(19, "89 05 ?? ?? ?? ?? 48 8B 04 C2 48 89 05 ?? ?? ?? ?? 8B 81") },
		{ "gameStateOffset2", new SigScanTarget(17, "48 ?? ?? ?? 4C 8B 05 ?? ?? ?? ?? 48 8B D9 41 8B 80 ?? ?? ?? ?? 85 C0") },
		{ "mapTicOffset1", new SigScanTarget(3, "41 8B 90 ?? ?? ?? ?? 4C 8D 05 ?? ?? ?? ?? 48 63 46 20 C1") },
		{ "mapTicOffset2", new SigScanTarget(12, "C7 05 ?? ?? ?? ?? ?? ?? ?? ?? 8B 88 ?? ?? ?? ?? B8 ?? ?? ?? ?? F7 E9 03 D1") }
	};

	foreach (KeyValuePair<string, SigScanTarget> target in vars.Targets)
	{
		bool isOffset = target.Key.Remove(target.Key.Length - 1).EndsWith("Offset");
		target.Value.OnFound = (process, _, address) => isOffset
			? (IntPtr)process.ReadValue<int>(address)
			: address + 0x4 + process.ReadValue<int>(address);
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
			var results = new Dictionary<string, IntPtr>();
			try
			{
				ProcessModuleWow64Safe[] gameModules = game.ModulesWow64Safe();
				var ordinalIgnoreCase = StringComparison.OrdinalIgnoreCase;
				var module = gameModules.First(m => m.ModuleName.Equals("DoomLib.dll", ordinalIgnoreCase));
				var scanner = new SignatureScanner(game, module.BaseAddress, module.ModuleMemorySize);

				foreach (KeyValuePair<string, SigScanTarget> target in vars.Targets)
				{
					string name = target.Key.Remove(target.Key.Length - 1);
					if (!results.ContainsKey(name))
					{
						IntPtr result = scanner.Scan(target.Value);
						if (result != IntPtr.Zero)
						{
							results.Add(name, result);
							vars.Log(target.Key + ": 0x" + result.ToString("X"));
						}
					}
				}
			}
			catch
			{
			}

			if (results.Count == 4)
			{
				IntPtr arrayPointer = results["arrayPointer"];
				IntPtr arrayAddress = game.ReadPointer(arrayPointer);

				if (arrayAddress != IntPtr.Zero)
				{
					var isInGame = new DeepPointer(arrayPointer, (int)results["isInGameOffset"]);
					var gameState = new DeepPointer(arrayPointer, (int)results["gameStateOffset"]);
					var mapTic = new DeepPointer(arrayPointer, (int)results["mapTicOffset"]);

					vars.ArrayAddress = new MemoryWatcher<IntPtr>(arrayPointer);
					vars.IsInGame = new MemoryWatcher<byte>(isInGame);
					vars.GameState = new MemoryWatcher<byte>(gameState);
					vars.MapTic = new MemoryWatcher<int>(mapTic);

					vars.Watchers = new MemoryWatcherList
					{
						vars.ArrayAddress,
						vars.IsInGame,
						vars.GameState,
						vars.MapTic
					};

					vars.TargetsFound = true;
					break;
				}

				vars.Log("Array address must not be zero.");
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
		double inGameTime = vars.GameState.Current == 0
			? (double)Math.Truncate((vars.MapTic.Current / 35.0m) * 100) / 100
			: Math.Round(vars.MapTic.Current / 35.0d, 2, MidpointRounding.AwayFromZero);

		return TimeSpan.FromSeconds(inGameTime);
	}

	if (timer.LoadingTimes != TimeSpan.Zero)
	{
		timer.LoadingTimes = TimeSpan.Zero;
	}
}

reset
{
	return vars.IsInGame.Current == 0 && vars.GameState.Current == 3
		|| settings["ilMode"] && vars.MapTic.Current > 0 && vars.MapTic.Current < 10
		&& (vars.MapTic.Current < vars.MapTic.Old || vars.MapTic.Old == 0);
}

split
{
	return vars.GameState.Changed && vars.GameState.Current == 1 && vars.IsInGame.Current == 1;
}

start
{
	return vars.MapTic.Changed && vars.ArrayAddress.Current != IntPtr.Zero
		&& vars.IsInGame.Current == 1 && vars.GameState.Current == 0
		&& ((!settings["ilMode"] && vars.MapTic.Current > 0) || vars.MapTic.Current > 1);
}

exit
{
	vars.CancelSource.Cancel();
}

shutdown
{
	vars.CancelSource.Cancel();
}

// v0.0.3 19-May-2025
