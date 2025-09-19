state("DOOM") {}
state("DOOM II") {}

startup
{
	vars.Log = (Action<object>)(output =>
	{
		print("[Doom + Doom II Unity] " + output);
	});

	vars.Targets = new Dictionary<string, SigScanTarget>
	{
		{ "arrayPointer1", new SigScanTarget(3, "48 8B 05 ?? ?? ?? ?? 45 33 ?? 45 8B ?? 44 89 ?? ?? ?? ?? ?? 8B F2") },
		{ "arrayPointer2", new SigScanTarget(3, "48 8B 0D ?? ?? ?? ?? C7 05 ?? ?? ?? ?? ?? ?? ?? ?? 48 89 0D ?? ?? ?? ?? 85 C0") },
		{ "gameStateOffset1", new SigScanTarget(19, "89 05 ?? ?? ?? ?? 48 8B 04 C2 48 89 05 ?? ?? ?? ?? 8B 81") },
		{ "gameStateOffset2", new SigScanTarget(17, "48 ?? ?? ?? 4C 8B 05 ?? ?? ?? ?? 48 8B D9 41 8B 80 ?? ?? ?? ?? 85 C0") },
		{ "demoStateOffset1", new SigScanTarget(8, "0F 44 C1 48 8B CF 89 83 ?? ?? ?? ?? E8 ?? ?? ?? ?? 48 85 C0") },
		{ "demoStateOffset2", new SigScanTarget(11, "83 FA ?? 0F 85 ?? ?? ?? ?? 29 91 ?? ?? ?? ?? 0F 89 ?? ?? ?? ?? 89 91") },
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
					var gameState = new DeepPointer(arrayPointer, (int)results["gameStateOffset"]);
					var demoState = new DeepPointer(arrayPointer, (int)results["demoStateOffset"]);
					var mapTic = new DeepPointer(arrayPointer, (int)results["mapTicOffset"]);

					vars.ArrayAddress = new MemoryWatcher<IntPtr>(arrayPointer);
					vars.GameState = new MemoryWatcher<byte>(gameState);
					vars.DemoState = new MemoryWatcher<int>(demoState);
					vars.MapTic = new MemoryWatcher<int>(mapTic);

					vars.Watchers = new MemoryWatcherList
					{
						vars.ArrayAddress,
						vars.GameState,
						vars.DemoState,
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

start
{
	return vars.ArrayAddress.Current != IntPtr.Zero && vars.GameState.Current == 0
		&& vars.DemoState.Current == 0 && vars.MapTic.Current > 0;
}

reset
{
	return vars.GameState.Current == 3 && vars.DemoState.Current > 0;
}

split
{
	return vars.GameState.Changed && vars.GameState.Current == 1 && vars.DemoState.Current == 0;
}

exit
{
	vars.CancelSource.Cancel();
}

shutdown
{
	vars.CancelSource.Cancel();
}

// v0.0.6 20-Sep-2025 https://github.com/neesi/autosplitters/tree/main/Doom_Doom_II_Unity
