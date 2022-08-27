state("LOVE3") {}
state("LOVE3_Demo") {}

startup
{
	vars.Log = (Action<object>)(output => print("   [LOVE 3 " + vars.Version + "]   " + output));
}

init
{
	vars.TaskSuccessful = false;

	var roomNumTrg = new SigScanTarget(7, "CC CC CC 8B D1 8B 0D ?? ?? ?? ?? E9 ?? ?? ?? ?? CC");
	var roomBaseTrg = new SigScanTarget(16, "FF C8 48 63 D0 48 63 D9 48 3B D3 7C 18 48 8B 0D");
	var framePageTrg = new SigScanTarget(4, "C3 48 8B 15 ?? ?? ?? ?? 48 85 D2 0F 85");
	var frameVarTrg = new SigScanTarget(0, "70 6C 61 79 65 72 74 69 6D 65 00 78 78 78 78 78 70 6C 61 79 65 72 74 69 6D 65 00 78 78 78 78 78"); // playertime

	if (game.MainModule.ModuleName.ToLower() == "love3_demo.exe" && !game.Is64Bit())
	{
		vars.Version = "Demo";
		vars.Offset = "";
		vars.Bytes = 4;

		roomNumTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7");
		roomBaseTrg = new SigScanTarget(10, "7E ?? 8B 2D ?? ?? ?? ?? 8B 3D ?? ?? ?? ?? 2B EF 3B F3 7D");
		framePageTrg = new SigScanTarget(9, "FF 05 ?? ?? ?? ?? 8B 06 A3 ?? ?? ?? ?? 8B 3F");

		foreach (var target in new SigScanTarget[] { roomNumTrg, roomBaseTrg, framePageTrg })
		{
			target.OnFound = (p, s, ptr) => p.ReadPointer(ptr);
		}
	}
	else if (game.MainModule.ModuleName.ToLower() == "love3.exe" && game.Is64Bit())
	{
		vars.Version = "Full";
		vars.Offset = "00 00 00 00";
		vars.Bytes = 8;

		foreach (var target in new SigScanTarget[] { roomNumTrg, roomBaseTrg, framePageTrg })
		{
			target.OnFound = (p, s, ptr) => ptr + 0x4 + p.ReadValue<int>(ptr);
		}
	}
	else
	{
		vars.Version = "Unknown";
		vars.Log("Only 32-bit demo and 64-bit full game versions are supported. Stopping.");
		goto skip;
	}

	vars.RoomName = (Action)(() =>
	{
		try
		{
			string name = new DeepPointer(game.ReadPointer((IntPtr) vars.RoomBasePtr) + (game.ReadValue<int>((IntPtr) vars.RoomNumPtr) * vars.Bytes), 0x0).DerefString(game, 128);

			if (System.Text.RegularExpressions.Regex.IsMatch(name, @"^\w{4,}$"))
			{
				current.RoomName = name.ToLower();
			}
		}
		catch
		{
		}
	});

	vars.RoomActionList = new List<string>()
	{
		"room_startup",
		"room_displaylogos",
		"room_controlsdisplay",
		"room_mainmenu",
		"room_levelselect",
		"room_leaderboards",
		"room_demo_leaderboards",
		"room_credits",
		"room_keyboardmapping",
		"room_tutorial",
		"room_achievements"
	};

	vars.CancelSource = new CancellationTokenSource();
	System.Threading.Tasks.Task.Run(async () =>
	{
		vars.Log("Task started. Target scanning..");

		var token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

			IntPtr roomNumPtr = vars.RoomNumPtr = scanner.Scan(roomNumTrg);
			IntPtr roomBasePtr = vars.RoomBasePtr = scanner.Scan(roomBaseTrg);
			IntPtr framePagePtr = vars.FramePagePtr = scanner.Scan(framePageTrg);

			var names = new String[] { "roomNumPtr", "roomBasePtr", "framePagePtr" };
			var results = new IntPtr[] { roomNumPtr, roomBasePtr, framePagePtr };

			int index = 0;
			int found = 0;
			foreach (IntPtr result in results)
			{
				if (result != IntPtr.Zero)
				{
					found++;
					vars.Log((index + 1) + ". " + names[index] + ": [0x" + result.ToString("X") + "] -> 0x" + game.ReadPointer(result).ToString("X"));
				}
				else
				{
					vars.Log((index + 1) + ". " + names[index] + ": not found");
				}

				index++;
			}

			if (found == 3)
			{
				current.RoomName = "";
				vars.RoomName();
				vars.Log("current.RoomName: \"" + current.RoomName + "\"");

				if (current.RoomName == "")
				{
					vars.Log("ERROR: invalid current.RoomName");
				}
				else
				{
					vars.Log("Scanning for Frame Counter address..");
					break;
				}
			}

			vars.Log("Retrying..");
			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		while (!token.IsCancellationRequested)
		{
			IntPtr frameVarAddress = IntPtr.Zero;
			vars.FramePageBase = 0;

			int framePage = game.ReadValue<int>((IntPtr) vars.FramePagePtr);

			foreach (var page in game.MemoryPages(false))
			{
				long start = (long) page.BaseAddress;
				int size = (int) page.RegionSize;
				long end = start + size;

				if (frameVarAddress == IntPtr.Zero)
				{
					var scanner = new SignatureScanner(game, page.BaseAddress, size);
					frameVarAddress = scanner.Scan(frameVarTrg);
				}

				if (framePage >= start && framePage <= end)
				{
					vars.FramePageBase = start;
					vars.FramePageEnd = end;
				}
			}

			if (frameVarAddress != IntPtr.Zero && vars.FramePageBase > 0)
			{
				foreach (var page in game.MemoryPages(false))
				{
					var scanner = new SignatureScanner(game, page.BaseAddress, (int) page.RegionSize);
					var toBytes = BitConverter.GetBytes((int) frameVarAddress);
					var toString = BitConverter.ToString(toBytes).Replace("-", " ");
					var target = new SigScanTarget(0, vars.Offset, toString, vars.Offset);
					var pointers = scanner.ScanAll(target);

					foreach (IntPtr pointer in pointers)
					{
						int frameIdentifier = game.ReadValue<int>(pointer - 0x4);

						if (frameIdentifier <= 0x186A0) continue;

						var toBytes_ = BitConverter.GetBytes(frameIdentifier);
						var toString_ = BitConverter.ToString(toBytes_).Replace("-", " ");
						var target_ = new SigScanTarget(0, vars.Offset, toString_);

						foreach (var page_ in game.MemoryPages(false))
						{
							var scanner_ = new SignatureScanner(game, page_.BaseAddress, (int) page_.RegionSize);
							var pointers_ = scanner_.ScanAll(target_);

							foreach (IntPtr pointer_ in pointers_)
							{
								int frameCountAddress = game.ReadValue<int>(pointer_ - 0x4);
								double frameCount = game.ReadValue<double>((IntPtr) frameCountAddress);

								if (frameCountAddress >= vars.FramePageBase && frameCountAddress <= vars.FramePageEnd && frameCount.ToString().All(Char.IsDigit))
								{
									vars.RoomName();

									vars.RoomNum = new MemoryWatcher<int>(vars.RoomNumPtr);
									vars.FrameCount = new MemoryWatcher<double>((IntPtr) frameCountAddress);

									vars.Log("Frame Counter: 0x" + frameCountAddress.ToString("X") + ", value: (double) " + frameCount);
									vars.Log("Task completed successfully.");
									vars.TaskSuccessful = true;

									goto end;
								}
							}
						}
					}
				}
			}

			await System.Threading.Tasks.Task.Delay(1000, token);
		}

		end:;
	});

	skip:;
}

update
{
	if (!vars.TaskSuccessful) return false;

	vars.RoomNum.Update(game);
	vars.FrameCount.Update(game);

	if (vars.RoomNum.Changed)
	{
		vars.RoomName();

		if (current.RoomName != old.RoomName)
		{
			vars.Log("current.RoomName: \"" + old.RoomName + "\" -> \"" + current.RoomName + "\"");
		}
	}
}

start
{
	return !vars.RoomNum.Changed && !vars.RoomActionList.Contains(current.RoomName) && vars.FrameCount.Current == vars.FrameCount.Old + 1;
}

split
{
	return vars.RoomNum.Changed && !current.RoomName.Contains("leaderboard") && vars.FrameCount.Current > 90;
}

reset
{
	return vars.FrameCount.Current < vars.FrameCount.Old ||
	       vars.RoomActionList.Contains(current.RoomName) && !current.RoomName.Contains("leaderboard");
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

// v0.3.4 27-Aug-2022
