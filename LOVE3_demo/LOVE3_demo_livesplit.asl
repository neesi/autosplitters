state("LOVE3_Demo") {}

startup
{
	vars.ScanThreadReady = false;
	vars.Log = (Action<dynamic>) ((output) => print("[LOVE 3 demo ASL] " + output));
}

init
{
	vars.CancelSource = new CancellationTokenSource();
	vars.ScanThread = new Thread(() =>
	{
		vars.ScanThreadReady = true;
		var GameBaseAddr = (int) game.MainModule.BaseAddress;

		vars.Log("Starting scan thread.");
		vars.Log("game.MainModule.BaseAddress = 0x" + GameBaseAddr.ToString("X"));

		var RoomTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7");
		var MiscTrg = new SigScanTarget(2, "8B 35 ?? ?? ?? ?? 85 F6 75 10 B9");

		foreach (var trg in new[] { RoomTrg, MiscTrg })
			trg.OnFound = (p, s, ptr) => p.ReadPointer(ptr);

		IntPtr RoomPtr = IntPtr.Zero, MiscPtr = IntPtr.Zero;

		var RoomPtrFound = false;
		var MiscPtrFound = false;

		var token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

			if (RoomPtr == IntPtr.Zero)
				RoomPtr = scanner.Scan(RoomTrg);

			if (MiscPtr == IntPtr.Zero)
				MiscPtr = scanner.Scan(MiscTrg);

			if (RoomPtr != IntPtr.Zero)
			{
				var RoomValue = game.ReadValue<int>(RoomPtr);

				vars.Log("Room address = 0x" + RoomPtr.ToString("X"));
				vars.Log("Room value = (int) " + RoomValue);

				if (RoomValue > 0 && RoomValue < 500)
					RoomPtrFound = true;
			}

			if (MiscPtr != IntPtr.Zero)
			{
				var MiscPtrValue = game.ReadValue<int>(MiscPtr);

				vars.Log("Misc pointer = 0x" + MiscPtr.ToString("X"));
				vars.Log("Misc pointer value = (hex) " + MiscPtrValue.ToString("X"));

				if (MiscPtrValue > GameBaseAddr)
				{
					vars.MiscSearchBase = game.ReadValue<int>(MiscPtr) - 6000;
					vars.Log("Misc search base = (hex) " + vars.MiscSearchBase.ToString("X"));
					MiscPtrFound = true;
				}
			}

			if (RoomPtrFound && MiscPtrFound)
			{
				vars.Log("Found all pointers. Searching for Time Attack and Frame Counter addresses..");

				var TimeAttackFound = false;
				var FrameCountFound = false;

				int offset = 0;
				while (!token.IsCancellationRequested)
				{
					var MiscSearchOffset = vars.MiscSearchBase + offset;

					if (game.ReadValue<int>((IntPtr) MiscSearchOffset) == 16777216 &&
					    game.ReadValue<int>((IntPtr) MiscSearchOffset + 27) == 2021161080 &&
					    game.ReadValue<int>((IntPtr) MiscSearchOffset + 32) == 16777216 &&
					    game.ReadValue<int>((IntPtr) MiscSearchOffset + 47) == 2021161080)
					{
						vars.TimeAttackFoundAddr = MiscSearchOffset + 39;
						var TimeAttackFoundAddrValue = game.ReadValue<double>((IntPtr) vars.TimeAttackFoundAddr);

						if (!TimeAttackFound && (TimeAttackFoundAddrValue == 0 || TimeAttackFoundAddrValue == 1))
						{
							vars.Log("Time Attack address = 0x" + vars.TimeAttackFoundAddr.ToString("X"));
							vars.Log("Time Attack value = (double) " + TimeAttackFoundAddrValue);
							TimeAttackFound = true;
						}

						vars.FrameCountFoundAddr = MiscSearchOffset + 119;
						var FrameCountFoundAddrValue = game.ReadValue<double>((IntPtr) vars.FrameCountFoundAddr);

						if (!FrameCountFound && FrameCountFoundAddrValue.ToString().All(Char.IsDigit))
						{
							vars.Log("Frame Counter address = 0x" + vars.FrameCountFoundAddr.ToString("X"));
							vars.Log("Frame Counter value = (double) " + FrameCountFoundAddrValue);
							FrameCountFound = true;
						}
					}

					if (TimeAttackFound && FrameCountFound)
					{
						vars.Room = new MemoryWatcher<int>(RoomPtr);
						vars.TimeAttack = new MemoryWatcher<double>(new DeepPointer(vars.TimeAttackFoundAddr - GameBaseAddr));
						vars.FrameCount = new MemoryWatcher<double>(new DeepPointer(vars.FrameCountFoundAddr - GameBaseAddr));

						vars.Log("All done. Note: the script works in Time Attack mode only.");
						break;
					}

					offset++;
					if (offset > 200000) offset = 0;
				}

				break;
			}

			vars.Log("Scan failed. Retrying.");
			Thread.Sleep(2000);
		}

		vars.Log("Exiting scan thread.");
	});

	vars.ScanThread.Start();
}

update
{
	if (vars.ScanThread.IsAlive) return false;

	vars.Room.Update(game);
	vars.TimeAttack.Update(game);
	vars.FrameCount.Update(game);
}

start
{
	return !vars.Room.Changed && vars.TimeAttack.Current == 1 && vars.FrameCount.Old + 1 == vars.FrameCount.Current;
}

split
{
	return vars.Room.Changed && vars.TimeAttack.Current == 1 && vars.FrameCount.Current > 10;
}

reset
{
	return vars.FrameCount.Old > vars.FrameCount.Current ||
	       vars.Room.Current > 0 && vars.Room.Current < 6 ||
	       vars.Room.Current == 11 ||
	       vars.TimeAttack.Current == 0;
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

// v0.1.5 05-Dec-2021
