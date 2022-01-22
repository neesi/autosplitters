state("LOVE3") {}

startup
{
	vars.Log = (Action<dynamic>) ((output) => print("[LOVE 3 ASL] " + output));
	vars.ScanThread = null;
	vars.Debug = false;
}

init
{
	vars.ScanErrorList = new List<string>();
	vars.CancelSource = new CancellationTokenSource();
	vars.ScanThread = new Thread(() =>
	{
		var GameBaseAddr = (int) game.MainModule.BaseAddress;

		vars.Log("Starting scan thread.");
		vars.Log("# game.MainModule.BaseAddress: 0x" + GameBaseAddr.ToString("X"));

		var RoomNumTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7");
		var RoomNameTrg = new SigScanTarget(44, "C3 CC CC CC CC CC CC CC ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 8D 14 85 00 00 00 00 83 3C 0A 00 ?? ?? ?? ?? ?? ?? ?? 8B");
		var MiscTrg = new SigScanTarget(2, "8B 35 ?? ?? ?? ?? 85 F6 75 10 B9");

		foreach (var trg in new[] { RoomNumTrg, RoomNameTrg, MiscTrg })
			trg.OnFound = (p, s, ptr) => p.ReadPointer(ptr);

		IntPtr RoomNumPtr = IntPtr.Zero, RoomNamePtr = IntPtr.Zero, MiscPtr = IntPtr.Zero;

		var RoomNumPtrFound = false;
		var RoomNamePtrFound = false;
		var MiscPtrFound = false;

		var token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			vars.ScanErrorList.Clear();
			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

			if (RoomNumPtr == IntPtr.Zero && (RoomNumPtr = scanner.Scan(RoomNumTrg)) == IntPtr.Zero)
				vars.ScanErrorList.Add("ERROR: RoomNum pointer not found.");

			if (RoomNamePtr == IntPtr.Zero && (RoomNamePtr = scanner.Scan(RoomNameTrg)) == IntPtr.Zero)
				vars.ScanErrorList.Add("ERROR: RoomName pointer not found.");

			if (MiscPtr == IntPtr.Zero && (MiscPtr = scanner.Scan(MiscTrg)) == IntPtr.Zero)
				vars.ScanErrorList.Add("ERROR: Misc pointer not found.");

			if (RoomNumPtr != IntPtr.Zero)
			{
				var RoomNumValue = game.ReadValue<int>(RoomNumPtr);
				vars.Log("# RoomNum address: 0x" + RoomNumPtr.ToString("X") + ", value: (int) " + RoomNumValue);

				if (RoomNumValue > 0 && RoomNumValue < 5000)
				{
					RoomNumPtrFound = true;
				}
				else
				{
					vars.ScanErrorList.Add("ERROR: invalid RoomNum value.");
				}
			}

			if (RoomNamePtr != IntPtr.Zero)
			{
				var RoomNamePtrValue = game.ReadValue<int>(RoomNamePtr);
				vars.Log("# RoomNamePtr address: 0x" + RoomNamePtr.ToString("X") + ", value: (hex) " + RoomNamePtrValue.ToString("X"));

				if (RoomNamePtrValue > GameBaseAddr)
				{
					vars.RoomName = "";
					RoomNamePtrFound = true;
				}
				else
				{
					vars.ScanErrorList.Add("ERROR: invalid RoomNamePtr value.");
				}
			}

			if (MiscPtr != IntPtr.Zero)
			{
				var MiscPtrValue = game.ReadValue<int>(MiscPtr);
				vars.Log("# MiscPtr address: 0x" + MiscPtr.ToString("X") + ", value: (hex) " + MiscPtrValue.ToString("X"));

				if (MiscPtrValue > GameBaseAddr)
				{
					vars.MiscSearchBase = game.ReadValue<int>(MiscPtr) - 6000;
					vars.Log("# Pattern search base: 0x" + vars.MiscSearchBase.ToString("X"));
					MiscPtrFound = true;
				}
				else
				{
					vars.ScanErrorList.Add("ERROR: invalid MiscPtr value.");
				}
			}

			if (RoomNumPtrFound && RoomNamePtrFound && MiscPtrFound)
			{
				vars.Log("Found all pointers. Searching for Time Attack and Frame Counter addresses..");

				var TimeAttackFound = false;
				var FrameCountFound = false;

				int offset = 0;
				while (!token.IsCancellationRequested)
				{
					var MiscSearchAddr = vars.MiscSearchBase + offset;

					if (game.ReadValue<int>((IntPtr) MiscSearchAddr) == 7 &&
					    game.ReadValue<int>((IntPtr) MiscSearchAddr + 2) == 65536 &&
					    game.ReadValue<int>((IntPtr) MiscSearchAddr + 99) == 512)
					{
						vars.TimeAttackFoundAddr = MiscSearchAddr - 264;
						var TimeAttackFoundAddrValue = game.ReadValue<double>((IntPtr) vars.TimeAttackFoundAddr);

						if (!TimeAttackFound && (TimeAttackFoundAddrValue == 0 || TimeAttackFoundAddrValue == 1))
						{
							if (!vars.Debug)
							{
								vars.Log("# Time Attack address: 0x" + vars.TimeAttackFoundAddr.ToString("X") + ", value: (double) " + TimeAttackFoundAddrValue);
							}

							TimeAttackFound = true;
						}

						vars.FrameCountFoundAddr = MiscSearchAddr + 8;
						var FrameCountFoundAddrValue = game.ReadValue<double>((IntPtr) vars.FrameCountFoundAddr);

						if (!FrameCountFound && FrameCountFoundAddrValue.ToString().All(Char.IsDigit))
						{
							if (!vars.Debug)
							{
								vars.Log("# Frame Counter address: 0x" + vars.FrameCountFoundAddr.ToString("X") + ", value: (double) " + FrameCountFoundAddrValue);
							}

							FrameCountFound = true;
						}

						if (vars.Debug)
						{
							var TimeAttackAddr = "n/a";
							var FrameCountAddr = "n/a";

							if (TimeAttackFound)
							{
								TimeAttackAddr = "0x" + vars.TimeAttackFoundAddr.ToString("X") + " (double) " + TimeAttackFoundAddrValue;
								TimeAttackFound = false;
							}

							if (FrameCountFound)
							{
								FrameCountAddr = "0x" + vars.FrameCountFoundAddr.ToString("X") + " (double) " + FrameCountFoundAddrValue;
								FrameCountFound = false;
							}

							vars.Log("# Found pattern at 0x" + MiscSearchAddr.ToString("X") + " (TimeAttackAddr: " + TimeAttackAddr + ", FrameCountAddr: " + FrameCountAddr + ")");
						}
					}

					if (!vars.Debug && TimeAttackFound && FrameCountFound)
					{
						vars.RoomNum = new MemoryWatcher<int>(RoomNumPtr);
						vars.RoomNamePtr = new MemoryWatcher<int>(RoomNamePtr);
						vars.TimeAttack = new MemoryWatcher<double>(new DeepPointer(vars.TimeAttackFoundAddr - GameBaseAddr));
						vars.FrameCount = new MemoryWatcher<double>(new DeepPointer(vars.FrameCountFoundAddr - GameBaseAddr));

						vars.Log("All done. Note: the script works in Time Attack mode only (including Level Select).");
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
	if (vars.ScanThread.IsAlive) return false;

	vars.RoomNum.Update(game);
	vars.RoomNamePtr.Update(game);
	vars.TimeAttack.Update(game);
	vars.FrameCount.Update(game);

	if (vars.RoomNum.Changed)
	{
		var RoomNameInt = game.ReadValue<int>((IntPtr) vars.RoomNamePtr.Current + (int) (4 * vars.RoomNum.Current));
		vars.RoomName = game.ReadString((IntPtr) RoomNameInt, 128).ToLower();
	}
}

start
{
	return !vars.RoomNum.Changed && vars.TimeAttack.Current == 1 && vars.FrameCount.Current == vars.FrameCount.Old + 1;
}

split
{
	return vars.RoomNum.Changed && vars.TimeAttack.Current == 1 && vars.FrameCount.Current > 90;
}

reset
{
	return vars.FrameCount.Current < vars.FrameCount.Old ||
	       vars.TimeAttack.Current == 0 ||
	       vars.RoomName == "room_mainmenu" ||
	       vars.RoomName == "room_levelselect";
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

// v0.1.7 22-Jan-2022
