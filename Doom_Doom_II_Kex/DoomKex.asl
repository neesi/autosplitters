state("doom") {}
state("doom_egs") {}
state("doom_gog") {}
state("osiris2_WinStore") {}

startup
{
	vars.Log = (Action<object>)(output =>
	{
		print("[Doom + Doom II Kex] " + output);
	});

	vars.Targets = new Dictionary<string, SigScanTarget>
	{
		{ "gameType1", new SigScanTarget(22, "FF 15 ?? ?? ?? ?? 48 8B 15 ?? ?? ?? ?? 48 8B 0D ?? ?? ?? ?? 8B 05 ?? ?? ?? ?? 89") },
		{ "gameType2", new SigScanTarget(13, "48 8B ?? ?? ?? ?? ?? 48 ?? ?? ?? FF 05 ?? ?? ?? ?? FF ?? E8 ?? ?? ?? ?? 3B") },
		{ "arrayPointer1", new SigScanTarget(7, "84 C0 74 ?? 4C ?? ?? ?? ?? ?? ?? 74 ?? 48 8B ?? ?? ?? ?? ?? 80 38 ?? 75 ?? 80 78") },
		{ "arrayPointer2", new SigScanTarget(15, "84 DB 74 ?? 48 8B ?? E8 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 48 89 05 ?? ?? ?? ?? 48") },
		{ "isInGameOffset1", new SigScanTarget(25, "83 F9 0A 75 ?? 39 ?? ?? ?? ?? ?? 74 ?? 40 38 ?? ?? ?? ?? ?? 75 ?? 40 38") },
		{ "isInGameOffset2", new SigScanTarget(4, "75 ?? 80 B8 ?? ?? ?? ?? ?? 0F 84 ?? ?? ?? ?? 8B 90 ?? ?? ?? ?? 83 FA") },
		{ "gameStateOffset1", new SigScanTarget(6, "48 8B 0C ?? 8B 83 ?? ?? ?? ?? 48 89 8B ?? ?? ?? ?? 39 83") },
		{ "gameStateOffset2", new SigScanTarget(9, "48 8B ?? ?? ?? ?? ?? 39 ?? ?? ?? ?? ?? 75 ?? 38 ?? ?? ?? ?? ?? 75 ?? C7") },
		{ "mapTicOffset1", new SigScanTarget(5, "74 ?? 49 63 91 ?? ?? ?? ?? 48 C1 E2 ?? 48 03 ?? ?? 48 C1 E2 ?? E9") },
		{ "mapTicOffset2", new SigScanTarget(9, "C7 ?? ?? ?? FF FF ?? 8B 81 ?? ?? ?? ?? 89 ?? ?? C6 ?? ?? ?? 0F 1F") }
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
				var module = gameModules.First(m => m.ModuleName.EndsWith(".exe", ordinalIgnoreCase));
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

			if (results.Count == 5)
			{
				IntPtr arrayPointer = results["arrayPointer"];
				IntPtr arrayAddress = game.ReadPointer(arrayPointer);

				if (arrayAddress != IntPtr.Zero)
				{
					var isInGame = new DeepPointer(arrayPointer, (int)results["isInGameOffset"]);
					var gameState = new DeepPointer(arrayPointer, (int)results["gameStateOffset"]);
					var mapTic = new DeepPointer(arrayPointer, (int)results["mapTicOffset"]);

					vars.GameType = new MemoryWatcher<byte>(results["gameType"]);
					vars.ArrayAddress = new MemoryWatcher<IntPtr>(arrayPointer);
					vars.IsInGame = new MemoryWatcher<byte>(isInGame);
					vars.GameState = new MemoryWatcher<byte>(gameState);
					vars.MapTic = new MemoryWatcher<int>(mapTic);

					vars.Watchers = new MemoryWatcherList
					{
						vars.GameType,
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

reset
{
	return vars.GameType.Changed && vars.GameType.Old == 3
		|| vars.ArrayAddress.Current == IntPtr.Zero && vars.GameType.Current == 3
		|| vars.ArrayAddress.Current != IntPtr.Zero && vars.GameState.Current == 3
		&& vars.IsInGame.Current == 0 && vars.MapTic.Current > 0;
}

split
{
	return vars.GameState.Changed && vars.GameState.Current == 1 && vars.IsInGame.Current == 1;
}

start
{
	return vars.ArrayAddress.Current != IntPtr.Zero && vars.GameState.Current == 0
		&& vars.IsInGame.Current == 1 && vars.MapTic.Current > 0;
}

exit
{
	vars.CancelSource.Cancel();
}

shutdown
{
	vars.CancelSource.Cancel();
}

// v0.2.6 16-Aug-2025
