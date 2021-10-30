state("Love") {}

startup
{
	vars.ScanThreadReady = false;
	vars.Dbg = (Action<dynamic>) ((output) => print("[LOVE ASL] " + output));
}

init
{
	vars.CancelSource = new CancellationTokenSource();
	vars.ScanThread = new Thread(() =>
	{
		vars.ScanThreadReady = true;
		vars.GameBaseAddr = game.MainModule.BaseAddress;

		vars.Dbg("Starting scan thread.");
		vars.Dbg("MainModule.BaseAddress = 0x" + vars.GameBaseAddr.ToString("X"));

		var RoomTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7");
		var FrameTrg = new SigScanTarget(2, "8B 35 ?? ?? ?? ?? 85 F6 75 10 B9");

		foreach (var trg in new[] { RoomTrg, FrameTrg })
			trg.OnFound = (p, s, ptr) => p.ReadPointer(ptr);

		IntPtr RoomPtr = IntPtr.Zero, FramePtr = IntPtr.Zero;

		var token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

			if (RoomPtr == IntPtr.Zero && (RoomPtr = scanner.Scan(RoomTrg)) != IntPtr.Zero)
				vars.Dbg("Found room address at 0x" + RoomPtr.ToString("X"));

			if (RoomPtr != IntPtr.Zero)
				vars.RoomValue = game.ReadValue<int>(RoomPtr);

			if (FramePtr == IntPtr.Zero && (FramePtr = scanner.Scan(FrameTrg)) != IntPtr.Zero)
				vars.Dbg("Found frame counter pointer at 0x" + FramePtr.ToString("X"));

			if (FramePtr != IntPtr.Zero)
				vars.FrameSearchBase = game.ReadValue<int>(FramePtr);

			if (new[] { RoomPtr, FramePtr }.All(ptr => ptr != IntPtr.Zero) && vars.RoomValue > 0 && vars.FrameSearchBase > (int) vars.GameBaseAddr)
			{
				vars.Dbg("Scan completed successfully. Enter speedrun or unlimited mode to grab frame counter address.");

				int offset = 0;

				while (!token.IsCancellationRequested)
				{
					var FrameSearchOffset = vars.FrameSearchBase + offset;
					var FrameSearchValue = game.ReadValue<double>((IntPtr) FrameSearchOffset);

					if (FrameSearchValue == 99999999)
					{
						var FrameFoundAddr = FrameSearchOffset - 32;

						vars.Room = new MemoryWatcher<int>(RoomPtr);
						vars.FrameCount = new MemoryWatcher<double>(new DeepPointer(FrameFoundAddr - (int) vars.GameBaseAddr));

						vars.Dbg("Found frame counter address at 0x" + FrameFoundAddr.ToString("X"));
						break;
					}

					offset++;

					if (offset > 20000) offset = 0;
				}

				break;
			}

			vars.Dbg("Scan was unsuccessful. Retrying.");
			Thread.Sleep(2000);
		}
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
	return vars.FrameCount.Current > vars.FrameCount.Old;
}

split
{
	return vars.Room.Changed && vars.FrameCount.Current > 90;
}

reset
{
	return vars.Room.Current < 12 && vars.Room.Old > vars.Room.Current ||
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
	if (vars.ScanThreadReady) vars.CancelSource.Cancel();
}

// v0.1.0a 30-Oct-2021
