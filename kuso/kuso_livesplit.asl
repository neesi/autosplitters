state("kuso") {}

startup
{
	settings.Add("SleepMargin", false, "SleepMargin -- Fix low FPS");
	settings.Add("SleepMargin1", false, "1", "SleepMargin");
	settings.Add("SleepMargin10", false, "10", "SleepMargin");
	settings.Add("SleepMargin40", false, "40", "SleepMargin");
	settings.Add("SleepMargin80", false, "80", "SleepMargin");
	settings.Add("SleepMargin200", false, "200", "SleepMargin");
	settings.SetToolTip("SleepMargin", "Greatest checked value is used. Uncheck all and restart game to set game default.");

	vars.Log = (Action<dynamic>) ((output) => print("[kuso ASL] " + output));
	vars.ScanThread = null;
}

init
{
	var RoomPtrFound = false;
	var MiscPtrFound = false;
	vars.SleepMarginPtrFound = false;

	vars.ScanErrorList = new List<string>();
	vars.CancelSource = new CancellationTokenSource();
	vars.ScanThread = new Thread(() =>
	{
		var GameBaseAddr = (int) game.MainModule.BaseAddress;

		vars.Log("Starting scan thread.");
		vars.Log("game.MainModule.BaseAddress = 0x" + GameBaseAddr.ToString("X"));

		var RoomTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7");
		var MiscTrg = new SigScanTarget(2, "8B 35 ?? ?? ?? ?? 85 F6 75 10 B9");
		var SleepMarginTrg = new SigScanTarget(11, "8B ?? ?? ?? ?? ?? ?? 83 C4 0C A3 ?? ?? ?? ?? C6");

		foreach (var trg in new[] { RoomTrg, MiscTrg, SleepMarginTrg })
			trg.OnFound = (p, s, ptr) => p.ReadPointer(ptr);

		IntPtr RoomPtr = IntPtr.Zero, MiscPtr = IntPtr.Zero, SleepMarginPtr = IntPtr.Zero;

		var token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			vars.ScanErrorList.Clear();

			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

			if (RoomPtr == IntPtr.Zero && (RoomPtr = scanner.Scan(RoomTrg)) == IntPtr.Zero)
				vars.ScanErrorList.Add("ERROR: Room pointer not found.");

			if (MiscPtr == IntPtr.Zero && (MiscPtr = scanner.Scan(MiscTrg)) == IntPtr.Zero)
				vars.ScanErrorList.Add("ERROR: Misc pointer not found.");

			if (SleepMarginPtr == IntPtr.Zero && (SleepMarginPtr = vars.SleepMarginPtr = scanner.Scan(SleepMarginTrg)) == IntPtr.Zero)
				vars.ScanErrorList.Add("ERROR: SleepMargin pointer not found.");

			if (RoomPtr != IntPtr.Zero)
			{
				var RoomValue = game.ReadValue<int>(RoomPtr);

				vars.Log("Room address = 0x" + RoomPtr.ToString("X"));
				vars.Log("Room value = (int) " + RoomValue);

				if (RoomValue > 0 && RoomValue < 500) RoomPtrFound = true;
				else vars.ScanErrorList.Add("ERROR: invalid Room value.");
			}

			if (MiscPtr != IntPtr.Zero)
			{
				var MiscPtrValue = game.ReadValue<int>(MiscPtr);

				vars.Log("Misc address = 0x" + MiscPtr.ToString("X"));
				vars.Log("Misc value = (hex) " + MiscPtrValue.ToString("X"));

				if (MiscPtrValue > GameBaseAddr)
				{
					vars.MiscSearchBase = game.ReadValue<int>(MiscPtr) - 6000;
					vars.Log("Misc search base = (hex) " + vars.MiscSearchBase.ToString("X"));
					MiscPtrFound = true;
				}
				else vars.ScanErrorList.Add("ERROR: invalid Misc value.");
			}

			if (SleepMarginPtr != IntPtr.Zero)
			{
				var SleepMarginValue = game.ReadValue<int>(SleepMarginPtr);

				vars.Log("SleepMargin address = 0x" + SleepMarginPtr.ToString("X"));
				vars.Log("SleepMargin value = (int) " + SleepMarginValue);

				if (SleepMarginValue >= 0)
				{
					if (RoomPtrFound) vars.SleepMarginPtrFound = true;
				}
				else vars.ScanErrorList.Add("ERROR: invalid SleepMargin value.");
			}

			if (MiscPtrFound && vars.SleepMarginPtrFound)
			{
				vars.Log("Found all pointers. Searching for Game Mode and Frame Counter addresses..");

				var GameModeFound = false;
				var FrameCountFound = false;

				int offset = 0;
				while (!token.IsCancellationRequested)
				{
					var MiscSearchOffset = vars.MiscSearchBase + offset;

					if (!GameModeFound && game.ReadValue<double>((IntPtr) MiscSearchOffset) == -2 && game.ReadValue<double>((IntPtr) MiscSearchOffset + 4) == 4474615)
					{
						vars.GameModeFoundAddr = MiscSearchOffset - 28;
						var GameModeFoundAddrValue = game.ReadValue<double>((IntPtr) vars.GameModeFoundAddr);

						if (GameModeFoundAddrValue.ToString().All(Char.IsDigit))
						{
							vars.Log("Game Mode address = 0x" + vars.GameModeFoundAddr.ToString("X"));
							vars.Log("Game Mode value = (double) " + GameModeFoundAddrValue);
							GameModeFound = true;
						}
					}

					if (!FrameCountFound && game.ReadValue<double>((IntPtr) MiscSearchOffset) == 1800)
					{
						vars.FrameCountFoundAddr = MiscSearchOffset + 224;
						var FrameCountFoundAddrValue = game.ReadValue<double>((IntPtr) vars.FrameCountFoundAddr);

						if (FrameCountFoundAddrValue.ToString().All(Char.IsDigit))
						{
							vars.Log("Frame Counter address = 0x" + vars.FrameCountFoundAddr.ToString("X"));
							vars.Log("Frame Counter value = (double) " + FrameCountFoundAddrValue);
							FrameCountFound = true;
						}
					}

					if (GameModeFound && FrameCountFound)
					{
						vars.Room = new MemoryWatcher<int>(RoomPtr);
						vars.GameMode = new MemoryWatcher<double>(new DeepPointer(vars.GameModeFoundAddr - GameBaseAddr));
						vars.FrameCount = new MemoryWatcher<double>(new DeepPointer(vars.FrameCountFoundAddr - GameBaseAddr));

						vars.Log("All done.");
						break;
					}

					offset++;
					if (offset > 200000) offset = 0;
				}

				break;
			}

			vars.ScanErrorList.ForEach(vars.Log);
			vars.Log("Scan failed. Retrying.");
			Thread.Sleep(2000);
		}

		vars.Log("Exiting scan thread.");
	});

	vars.ScanThread.Start();
}

update
{
	if (vars.SleepMarginPtrFound && settings["SleepMargin"])
	{
		if (settings["SleepMargin200"])
			vars.SleepMarginCheckedBytes = new byte[] { 0xC8, 0x00, 0x00, 0x00 };

		else if (settings["SleepMargin80"])
			vars.SleepMarginCheckedBytes = new byte[] { 0x50, 0x00, 0x00, 0x00 };

		else if (settings["SleepMargin40"])
			vars.SleepMarginCheckedBytes = new byte[] { 0x28, 0x00, 0x00, 0x00 };

		else if (settings["SleepMargin10"])
			vars.SleepMarginCheckedBytes = new byte[] { 0x0A, 0x00, 0x00, 0x00 };

		else if (settings["SleepMargin1"])
			vars.SleepMarginCheckedBytes = new byte[] { 0x01, 0x00, 0x00, 0x00 };

		else goto update;

		var SleepMarginCurrentBytes = BitConverter.ToString(game.ReadBytes((IntPtr) vars.SleepMarginPtr, 4));

		if (SleepMarginCurrentBytes != BitConverter.ToString(vars.SleepMarginCheckedBytes))
		{
			try
			{
				game.Suspend();
				game.WriteBytes((IntPtr) vars.SleepMarginPtr, (byte[]) vars.SleepMarginCheckedBytes);
			}
			catch (Exception e)
			{
				vars.Log(e.ToString());
			}
			finally
			{
				game.Resume();
			}
		}
	}

	update:

	if (vars.ScanThread.IsAlive) return false;

	vars.Room.Update(game);
	vars.GameMode.Update(game);
	vars.FrameCount.Update(game);
}

start
{
	return !vars.Room.Changed && vars.FrameCount.Old + 1 == vars.FrameCount.Current;
}

split
{
	return vars.Room.Changed && vars.GameMode.Current != 5 && vars.FrameCount.Current > 10;
}

reset
{
	return vars.FrameCount.Old > vars.FrameCount.Current ||
	       vars.Room.Current > 0 && vars.Room.Current < 3 ||
	       vars.Room.Old > vars.Room.Current && vars.Room.Current < 12 && vars.GameMode.Current != 5;
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
	if (vars.ScanThread != null) vars.CancelSource.Cancel();
}

// v0.1.8 20-Dec-2021
