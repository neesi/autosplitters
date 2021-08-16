state("Love") {}

startup
{
	vars.Dbg = (Action<dynamic>) ((output) => print("[LOVE ASL] " + output));

	settings.Add("IL_Splits_LOVE", true, "Enable automatic splits for IL mode.");
}

init
{
	vars.CancelSource = new CancellationTokenSource();
	vars.ScanThread = new Thread(() =>
	{
		vars.Dbg("Starting scan thread.");

		var roomManagerTrg = new SigScanTarget(1, "A1 ???????? 50 A3");
		var gameManagerTrg = new SigScanTarget(1, "B9 ???????? 56 B8 ???????? 89 4C 24");

		foreach (var trg in new[] { roomManagerTrg, gameManagerTrg })
			trg.OnFound = (p, s, ptr) => p.ReadPointer(ptr);

		IntPtr roomManager = IntPtr.Zero, gameManager = IntPtr.Zero;

		var token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

			if (roomManager == IntPtr.Zero && (roomManager = scanner.Scan(roomManagerTrg)) != IntPtr.Zero)
				vars.Dbg("Found roomManager at 0x" + roomManager.ToString("X"));

			if (gameManager == IntPtr.Zero && (gameManager = scanner.Scan(gameManagerTrg)) != IntPtr.Zero)
				vars.Dbg("Found gameManager at 0x" + gameManager.ToString("X"));

			if (new[] { roomManager, gameManager }.All(ptr => ptr != IntPtr.Zero))
			{
				vars.Dbg("Found all pointers successfully.");
				break;
			}

			vars.Dbg("Couldn't find all pointers. Retrying.");
			Thread.Sleep(2000);
		}

		vars.Room = new MemoryWatcher<int>(roomManager);
		vars.FrameCount = new MemoryWatcher<double>(new DeepPointer(gameManager, 0x610, 0x354, 0x120));
	});

	vars.ScanThread.Start();
}

update
{
	if (vars.ScanThread.IsAlive) return false;

	vars.Room.Update(game);
	vars.FrameCount.Update(game);
}

start
{
	if (!vars.Room.Changed) return;

	return (vars.Room.Old == 4 || vars.Room.Old == 25) && vars.Room.Current != 3;
}

split
{
	if (!vars.Room.Changed) return;

	return vars.Room.Current == vars.Room.Old + 1 ||
	       vars.Room.Current == 23 ||
	       vars.Room.Old != 22 && vars.Room.Current == 24;
}

reset
{
	return vars.Room.Changed && (vars.Room.Current == 6 || vars.Room.Current == 25) ||
	       vars.FrameCount.Old > vars.FrameCount.Current;
}

gameTime
{
	return TimeSpan.FromSeconds(vars.FrameCount.Current / 60f);
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
