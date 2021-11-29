state("kuso") {}

startup
{
	settings.Add("SleepMargin", false, "SleepMargin -- Fix low FPS");
	settings.Add("SleepMargin1", false, "1", "SleepMargin");
	settings.Add("SleepMargin10", false, "10", "SleepMargin");
	settings.Add("SleepMargin40", false, "40", "SleepMargin");
	settings.Add("SleepMargin80", false, "80", "SleepMargin");
	settings.Add("SleepMargin200", false, "200", "SleepMargin");
	settings.SetToolTip("SleepMargin", "Highest checked value is used. Uncheck to set game default.");

	vars.ScanThreadReady = false;
	vars.Log = (Action<dynamic>) ((output) => print("[kuso ASL] " + output));
}

init
{
	vars.State = 2;

	vars.RoomPtrFound = false;
	vars.MiscPtrFound = false;
	vars.SleepMarginPtrFound = false;

	vars.CancelSource = new CancellationTokenSource();
	vars.ScanThread = new Thread(() =>
	{
		vars.ScanThreadReady = true;
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
			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

			if (RoomPtr == IntPtr.Zero)
				RoomPtr = scanner.Scan(RoomTrg);

			if (MiscPtr == IntPtr.Zero)
				MiscPtr = scanner.Scan(MiscTrg);

			if (SleepMarginPtr == IntPtr.Zero)
				SleepMarginPtr = scanner.Scan(SleepMarginTrg);

			if (RoomPtr != IntPtr.Zero)
			{
				var RoomValue = game.ReadValue<int>(RoomPtr);

				vars.Log("Room address = 0x" + RoomPtr.ToString("X"));
				vars.Log("Room value = (int) " + RoomValue);

				if (RoomValue > 0 && RoomValue < 500)
					vars.RoomPtrFound = true;
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
					vars.MiscPtrFound = true;
				}
			}

			if (SleepMarginPtr != IntPtr.Zero)
			{
				var SleepMarginValue = game.ReadValue<int>(SleepMarginPtr);
				vars.SleepMarginOriginalBytes = game.ReadBytes((IntPtr) SleepMarginPtr, 4);
				vars.SleepMarginPtr = SleepMarginPtr;

				vars.Log("Sleep Margin address = 0x" + SleepMarginPtr.ToString("X"));
				vars.Log("Sleep Margin value = (int) " + SleepMarginValue);

				if (SleepMarginValue >= 0 && vars.RoomPtrFound)
					vars.SleepMarginPtrFound = true;
			}

			if (vars.MiscPtrFound && vars.SleepMarginPtrFound)
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
							GameModeFound = true;
							vars.Log("Game Mode address = 0x" + vars.GameModeFoundAddr.ToString("X"));
							vars.Log("Game Mode value = (double) " + GameModeFoundAddrValue);
						}
					}

					if (!FrameCountFound && game.ReadValue<double>((IntPtr) MiscSearchOffset) == 1800)
					{
						vars.FrameCountFoundAddr = MiscSearchOffset + 224;
						var FrameCountFoundAddrValue = game.ReadValue<double>((IntPtr) vars.FrameCountFoundAddr);

						if (FrameCountFoundAddrValue.ToString().All(Char.IsDigit))
						{
							FrameCountFound = true;
							vars.Log("Frame Counter address = 0x" + vars.FrameCountFoundAddr.ToString("X"));
							vars.Log("Frame Counter value = (double) " + FrameCountFoundAddrValue);
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

			vars.Log("Scan failed. Retrying.");
			Thread.Sleep(2000);
		}
	});

	vars.ScanThread.Start();
}

update
{
	try
	{
		if (vars.SleepMarginPtrFound)
		{
			var SleepMarginCurrentBytes = BitConverter.ToString(game.ReadBytes((IntPtr) vars.SleepMarginPtr, 4));

			if (settings["SleepMargin"])
			{
				vars.State = 1;

				if (settings["SleepMargin200"])
					vars.SleepMarginChecked = new byte[] { 0xC8, 0x00, 0x00, 0x00 };

				else if (settings["SleepMargin80"])
					vars.SleepMarginChecked = new byte[] { 0x50, 0x00, 0x00, 0x00 };

				else if (settings["SleepMargin40"])
					vars.SleepMarginChecked = new byte[] { 0x28, 0x00, 0x00, 0x00 };

				else if (settings["SleepMargin10"])
					vars.SleepMarginChecked = new byte[] { 0x0A, 0x00, 0x00, 0x00 };

				else if (settings["SleepMargin1"])
					vars.SleepMarginChecked = new byte[] { 0x01, 0x00, 0x00, 0x00 };

				else vars.SleepMarginChecked = vars.SleepMarginOriginalBytes;

				if (SleepMarginCurrentBytes != BitConverter.ToString(vars.SleepMarginChecked))
				{
					game.Suspend();
					game.WriteBytes((IntPtr) vars.SleepMarginPtr, (byte[]) vars.SleepMarginChecked);
				}
			}

			else if (!settings["SleepMargin"] && vars.State == 1)
			{
				vars.State = 0;

				if (SleepMarginCurrentBytes != BitConverter.ToString(vars.SleepMarginOriginalBytes))
				{
					game.Suspend();
					game.WriteBytes((IntPtr) vars.SleepMarginPtr, (byte[]) vars.SleepMarginOriginalBytes);
				}
			}
		}
	}
	catch (Exception e)
	{
		game.Resume();
		vars.Log(e.ToString());
	}
	finally
	{
		game.Resume();
	}

	if (vars.ScanThread.IsAlive) return false;

	vars.Room.Update(game);
	vars.GameMode.Update(game);
	vars.FrameCount.Update(game);
}

start
{
	var x = vars.FrameCount.Current - vars.FrameCount.Old;
	return x >= 1 && x <= 3;
}

split
{
	return vars.Room.Changed && vars.GameMode.Current != 5 && vars.FrameCount.Current > 90;
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
	if (vars.ScanThreadReady) vars.CancelSource.Cancel();
	if (game == null) return;

	try
	{
		if (vars.SleepMarginPtrFound)
		{
			var SleepMarginCurrentBytes = BitConverter.ToString(game.ReadBytes((IntPtr) vars.SleepMarginPtr, 4));

			if (SleepMarginCurrentBytes != BitConverter.ToString(vars.SleepMarginOriginalBytes))
			{
				game.Suspend();
				game.WriteBytes((IntPtr) vars.SleepMarginPtr, (byte[]) vars.SleepMarginOriginalBytes);
			}
		}
	}
	catch (Exception e)
	{
		game.Resume();
		vars.Log(e.ToString());
	}
	finally
	{
		game.Resume();
	}
}

// v0.1.0 29-Nov-2021
