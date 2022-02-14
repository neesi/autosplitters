state("LOVE3") {}

startup
{
	vars.Log = (Action<dynamic>) ((output) => print("[LOVE 3 ASL] " + output));
	vars.ScanThread = null;
	vars.PrintRoomNameChanges = false;
}

init
{
	var RoomNumPtrFound = false;
	var RoomNamePtrFound = false;
	vars.RoomNameFound = false;
	var MiscPtrFound = false;

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

				if (RoomNumValue > 0)
				{
					RoomNumPtrFound = true;
				}
				else
				{
					RoomNumPtr = IntPtr.Zero;
					RoomNumPtrFound = false;
					vars.ScanErrorList.Add("ERROR: invalid RoomNum value.");
				}
			}

			if (RoomNamePtr != IntPtr.Zero)
			{
				var RoomNamePtrValue = game.ReadValue<int>(RoomNamePtr);
				vars.Log("# RoomNamePtr address: 0x" + RoomNamePtr.ToString("X") + ", value: (hex) " + RoomNamePtrValue.ToString("X"));

				if (RoomNamePtrValue > GameBaseAddr)
				{
					RoomNamePtrFound = true;
				}
				else
				{
					RoomNamePtr = IntPtr.Zero;
					RoomNamePtrFound = false;
					vars.ScanErrorList.Add("ERROR: invalid RoomNamePtr value.");
				}
			}

			if (RoomNumPtrFound && RoomNamePtrFound)
			{
				var RoomNumValue = game.ReadValue<int>(RoomNumPtr);
				var RoomNamePtrValue = game.ReadValue<int>(RoomNamePtr);
				var RoomNameInt = game.ReadValue<int>((IntPtr) RoomNamePtrValue + (int) (4 * RoomNumValue));
				var RoomName = game.ReadString((IntPtr) RoomNameInt, 128).ToLower();
				vars.Log("# RoomName: " + RoomName);

				if (RoomName.Contains("room_"))
				{
					vars.RoomNum = new MemoryWatcher<int>(RoomNumPtr);
					vars.RoomNamePtr = new MemoryWatcher<int>(RoomNamePtr);

					vars.RoomName = "";
					vars.RoomNameFound = true;
				}
				else
				{
					RoomNumPtr = IntPtr.Zero;
					RoomNamePtr = IntPtr.Zero;
					RoomNumPtrFound = false;
					RoomNamePtrFound = false;
					vars.ScanErrorList.Add("ERROR: invalid Room name.");
				}
			}

			if (MiscPtr != IntPtr.Zero)
			{
				var MiscPtrValue = game.ReadValue<int>(MiscPtr);
				vars.Log("# MiscPtr address: 0x" + MiscPtr.ToString("X") + ", value: (hex) " + MiscPtrValue.ToString("X"));

				if (vars.RoomNameFound)
				{
					if (MiscPtrValue > GameBaseAddr)
					{
						vars.MiscSearchBase = MiscPtrValue - 6000;
						vars.Log("# Misc search base: 0x" + vars.MiscSearchBase.ToString("X"));
						MiscPtrFound = true;
					}
					else
					{
						MiscPtr = IntPtr.Zero;
						vars.ScanErrorList.Add("ERROR: invalid MiscPtr value.");
					}
				}
				else
				{
					MiscPtr = IntPtr.Zero;
					vars.ScanErrorList.Add("ERROR: waiting for RoomName to be found before locking MiscPtr.");
				}
			}

			if (vars.RoomNameFound && MiscPtrFound)
			{
				vars.Log("Found all pointers. Enter a level to grab Frame Counter address.");

				var FrameCountFound = false;

				int offset = 0;
				while (!token.IsCancellationRequested)
				{
					var FrameSearchAddr = vars.MiscSearchBase + offset;
					var FrameDouble = game.ReadValue<double>((IntPtr) FrameSearchAddr);
					var FrameLong = game.ReadValue<long>((IntPtr) FrameSearchAddr);
					var FrameOffset8 = game.ReadValue<int>((IntPtr) FrameSearchAddr + 8);

					if (FrameDouble.ToString().All(Char.IsDigit) && FrameLong > 4607182418800017408 && FrameLong.ToString("X").EndsWith("00000000") && FrameOffset8 == 7)
					{
						Stopwatch s = new Stopwatch();
						s.Start();

						int increased = 0;
						while (!token.IsCancellationRequested && s.Elapsed < TimeSpan.FromMilliseconds(60)) 
						{
							if (game.ReadValue<double>((IntPtr) FrameSearchAddr) < FrameDouble)
							{
								break;
							}

							if (game.ReadValue<double>((IntPtr) FrameSearchAddr) > FrameDouble)
							{
								FrameDouble = game.ReadValue<double>((IntPtr) FrameSearchAddr);
								increased++;

								if (increased > 1)
								{
									vars.FrameCountAddr = FrameSearchAddr;
									var FrameCountAddrValue = game.ReadValue<double>((IntPtr) vars.FrameCountAddr);
									vars.Log("# Frame Counter address: 0x" + vars.FrameCountAddr.ToString("X") + ", value: (double) " + FrameCountAddrValue);
									FrameCountFound = true;
									break;
								}
							}
  						}

						s.Stop();
					}

					if (FrameCountFound)
					{
						vars.FrameCount = new MemoryWatcher<double>(new DeepPointer(vars.FrameCountAddr - GameBaseAddr));

						vars.Log("All done.");
						break;
					}

					offset += 4;
					if (offset > 20000) offset = 0;
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
	if (!vars.RoomNameFound) return false;

	vars.RoomNum.Update(game);
	vars.RoomNamePtr.Update(game);

	if (vars.RoomNum.Changed)
	{
		var RoomNameInt = game.ReadValue<int>((IntPtr) vars.RoomNamePtr.Current + (int) (4 * vars.RoomNum.Current));
		vars.RoomName = game.ReadString((IntPtr) RoomNameInt, 128).ToLower();

		if (vars.PrintRoomNameChanges) vars.Log("Room: " + vars.RoomName);
	}

	if (vars.ScanThread.IsAlive) return false;

	vars.FrameCount.Update(game);
}

start
{
	return !vars.RoomNum.Changed && vars.RoomName != "room_mainmenu" && vars.RoomName != "room_levelselect" && vars.FrameCount.Current == vars.FrameCount.Old + 1;
}

split
{
	return vars.RoomNum.Changed && vars.FrameCount.Current > 90;
}

reset
{
	return vars.FrameCount.Current < vars.FrameCount.Old ||
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

// v0.1.9 14-Feb-2022
