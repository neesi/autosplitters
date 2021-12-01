state("Love") {}

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
	vars.Log = (Action<dynamic>) ((output) => print("[LOVE ASL] " + output));
}

init
{
	vars.State = 2;

	var RoomPtrFound = false;
	var MiscPtrFound = false;
	vars.SleepMarginPtrFound = false;

	vars.Room = new MemoryWatcher<int>(IntPtr.Zero);
	vars.FrameCount = new MemoryWatcher<double>(IntPtr.Zero);

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

				vars.Log("Sleep Margin address = 0x" + SleepMarginPtr.ToString("X"));
				vars.Log("Sleep Margin value = (int) " + SleepMarginValue);

				if (SleepMarginValue >= 0 && RoomPtrFound)
					vars.SleepMarginPtrFound = true;
			}

			if (MiscPtrFound && vars.SleepMarginPtrFound)
			{
				vars.Room = new MemoryWatcher<int>(RoomPtr);

				vars.Log("Found all pointers. Enter speedrun or unlimited mode to grab Frame Counter address.");

				int offset = 0;
				while (!token.IsCancellationRequested)
				{
					var FrameCountSearchOffset = vars.MiscSearchBase + offset;
					var FrameCountSearchValue = game.ReadValue<double>((IntPtr) FrameCountSearchOffset);

					if (FrameCountSearchValue == 99999999)
					{
						var FrameCountFoundAddr = FrameCountSearchOffset - 32;
						var FrameCountFoundAddrValue = game.ReadValue<double>((IntPtr) FrameCountFoundAddr);

						if (FrameCountFoundAddrValue.ToString().All(Char.IsDigit))
						{
							vars.FrameCount = new MemoryWatcher<double>(new DeepPointer(FrameCountFoundAddr - GameBaseAddr));

							vars.Log("Frame Counter address = 0x" + FrameCountFoundAddr.ToString("X"));
							vars.Log("Frame Counter value = (double) " + FrameCountFoundAddrValue);
							vars.Log("All done.");
							break;
						}
					}

					offset++;
					if (offset > 26000) offset = 0;
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
	vars.Room.Update(game);
	vars.FrameCount.Update(game);

	if (vars.SleepMarginPtrFound)
	{
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

			var SleepMarginCurrentBytes = BitConverter.ToString(game.ReadBytes((IntPtr) vars.SleepMarginPtr, 4));

			if (SleepMarginCurrentBytes != BitConverter.ToString(vars.SleepMarginChecked))
			{
				try
				{
					game.Suspend();
					game.WriteBytes((IntPtr) vars.SleepMarginPtr, (byte[]) vars.SleepMarginChecked);
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

		else if (!settings["SleepMargin"] && vars.State == 1)
		{
			vars.State = 0;

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
}

start
{
	var x = vars.FrameCount.Current - vars.FrameCount.Old;
	return x >= 1 && x <= 3;
}

split
{
	return vars.Room.Changed && vars.FrameCount.Current > 90;
}

reset
{
	return vars.FrameCount.Old > vars.FrameCount.Current ||
	       vars.Room.Current > 0 && vars.Room.Current < 4 ||
	       vars.Room.Old > vars.Room.Current && vars.Room.Current < 12;
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

// v0.1.2 01-Dec-2021
