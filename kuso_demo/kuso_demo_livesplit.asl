state("KUSO") {}

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
	vars.Log = (Action<dynamic>) ((output) => print("[kuso demo ASL] " + output));
}

init
{
	var RoomPtrFound = false;
	var MiscPtrFound = false;
	vars.SleepMarginPtrFound = false;

	vars.SubtractFramesCache = 0;
	vars.SubtractFrames = 0;

	vars.CancelSource = new CancellationTokenSource();
	vars.ScanThread = new Thread(() =>
	{
		vars.ScanThreadReady = true;
		var GameBaseAddr = (int) game.MainModule.BaseAddress;

		vars.Log("Starting scan thread.");
		vars.Log("game.MainModule.BaseAddress = 0x" + GameBaseAddr.ToString("X"));

		var RoomTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7");
		var MiscTrg = new SigScanTarget(4, "8B 08 89 ?? ?? ?? ?? ?? 8B 56 2C 50 89");
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

			if (SleepMarginPtr != IntPtr.Zero)
			{
				var SleepMarginValue = game.ReadValue<int>(SleepMarginPtr);
				vars.SleepMarginOriginalBytes = game.ReadBytes((IntPtr) SleepMarginPtr, 4);
				vars.SleepMarginPtr = SleepMarginPtr;
				vars.SleepMarginChecked = false;

				vars.Log("Sleep Margin address = 0x" + SleepMarginPtr.ToString("X"));
				vars.Log("Sleep Margin value = (int) " + SleepMarginValue);

				if (SleepMarginValue >= 0 && RoomPtrFound)
					vars.SleepMarginPtrFound = true;
			}

			if (MiscPtrFound && vars.SleepMarginPtrFound)
			{
				vars.Log("Found all pointers. Searching for Frame Counter address..");

				int offset = 0;
				while (!token.IsCancellationRequested)
				{
					var MiscSearchOffset = vars.MiscSearchBase + offset;

					if (game.ReadValue<int>((IntPtr) MiscSearchOffset) == 7 &&
					    game.ReadValue<int>((IntPtr) MiscSearchOffset + 16) == 7 &&
					    game.ReadValue<int>((IntPtr) MiscSearchOffset + 32) == 7 &&
					    game.ReadValue<int>((IntPtr) MiscSearchOffset + 48) == 7 &&
					    game.ReadValue<int>((IntPtr) MiscSearchOffset + 64) == 7 &&
					    game.ReadValue<int>((IntPtr) MiscSearchOffset + 80) == 7 &&
					    game.ReadValue<int>((IntPtr) MiscSearchOffset + 96) == 7 &&
					    game.ReadValue<int>((IntPtr) MiscSearchOffset + 112) == 7 &&
					    game.ReadValue<int>((IntPtr) MiscSearchOffset + 128) == 7 &&
					    game.ReadValue<int>((IntPtr) MiscSearchOffset + 144) == 7 &&
					    game.ReadValue<int>((IntPtr) MiscSearchOffset + 160) == 7)
					{
						var FrameCountFoundAddr = MiscSearchOffset + 24;
						var FrameCountFoundAddrValue = game.ReadValue<double>((IntPtr) FrameCountFoundAddr);

						if (FrameCountFoundAddrValue.ToString().All(Char.IsDigit))
						{
							vars.Room = new MemoryWatcher<int>(RoomPtr);
							vars.FrameCount = new MemoryWatcher<double>(new DeepPointer(FrameCountFoundAddr - GameBaseAddr));

							vars.Log("Frame Counter address = 0x" + FrameCountFoundAddr.ToString("X"));
							vars.Log("Frame Counter value = (double) " + FrameCountFoundAddrValue);
							vars.Log("All done.");
							break;
						}
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
	if (vars.SleepMarginPtrFound)
	{
		if (settings["SleepMargin"])
		{
			vars.SleepMarginChecked = true;

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

			else vars.SleepMarginCheckedBytes = vars.SleepMarginOriginalBytes;

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
					game.Resume();
					vars.Log(e.ToString());
				}
				finally
				{
					game.Resume();
				}
			}
		}

		else if (!settings["SleepMargin"] && vars.SleepMarginChecked)
		{
			vars.SleepMarginChecked = false;

			var SleepMarginCurrentBytes = BitConverter.ToString(game.ReadBytes((IntPtr) vars.SleepMarginPtr, 4));

			if (SleepMarginCurrentBytes != BitConverter.ToString(vars.SleepMarginOriginalBytes))
			{
				try
				{
					game.Suspend();
					game.WriteBytes((IntPtr) vars.SleepMarginPtr, (byte[]) vars.SleepMarginOriginalBytes);
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
		}
	}

	if (vars.ScanThread.IsAlive) return false;

	vars.Room.Update(game);
	vars.FrameCount.Update(game);

	if (vars.FrameCount.Current < vars.SubtractFrames)
	{
		vars.SubtractFramesCache = 0;
		vars.SubtractFrames = 0;
	}

	if (vars.Room.Old == 4 && vars.Room.Current > 4)
		 vars.SubtractFrames = vars.SubtractFramesCache;

	else if (vars.Room.Current == 4 && vars.FrameCount.Current > 90)
		 vars.SubtractFramesCache = vars.FrameCount.Current;
}

start
{
	var x = vars.FrameCount.Current - vars.FrameCount.Old;
	return x >= 1 && x <= 3;
}

split
{
	return vars.Room.Current > vars.Room.Old && vars.Room.Old != 0 && vars.Room.Old != 4 ||
	       vars.Room.Old > vars.Room.Current && vars.Room.Current == 4;
}

reset
{
	return vars.FrameCount.Old > vars.FrameCount.Current ||
	       vars.Room.Current > 0 && vars.Room.Current < 4 ||
	       vars.Room.Old == 4 && vars.Room.Current > 4;
}

gameTime
{
	return TimeSpan.FromSeconds((vars.FrameCount.Current - vars.SubtractFrames) / 60f);
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

	if (vars.SleepMarginPtrFound)
	{
		var SleepMarginCurrentBytes = BitConverter.ToString(game.ReadBytes((IntPtr) vars.SleepMarginPtr, 4));

		if (SleepMarginCurrentBytes != BitConverter.ToString(vars.SleepMarginOriginalBytes))
		{
			try
			{
				game.Suspend();
				game.WriteBytes((IntPtr) vars.SleepMarginPtr, (byte[]) vars.SleepMarginOriginalBytes);
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
	}
}

// v0.1.2 02-Dec-2021
