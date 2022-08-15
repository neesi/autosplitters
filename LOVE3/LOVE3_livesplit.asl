state("LOVE3") {}
state("LOVE3_Demo") {}

startup
{
	vars.Log = (Action<dynamic>)(output => print("   [LOVE 3]   " + output));
	vars.PrintRoomNameChanges = false;
}

init
{
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

	vars.FrameCountFound = false;
	vars.CancelSource = new CancellationTokenSource();
	System.Threading.Tasks.Task.Run(async () =>
	{
		vars.Log("Task started. Target scanning..");

		var runTimeTrg = new SigScanTarget(4, "CC 53 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 56 57 83 CF FF");
		var roomNumTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7");
		var roomNameTrg = new SigScanTarget(10, "7E ?? 8B 2D ?? ?? ?? ?? 8B 3D ?? ?? ?? ?? 2B EF 3B F3 7D");
		var frameVarTrg = new SigScanTarget(0, "70 6C 61 79 65 72 74 69 6D 65 00 78 78 78 78 78 70 6C 61 79 65 72 74 69 6D 65 00 78 78 78 78 78"); // playertime
		var pointerPageTrg = new SigScanTarget(9, "C3 56 8B 74 24 ?? 57 8B 3D ?? ?? ?? ?? 8B");
		var framePageTrg = new SigScanTarget(3, "8B 07 A3 ?? ?? ?? ?? 8B 13 8B 4A 0C");

		if (game.MainModule.ModuleName.ToLower() == "love3_demo.exe")
		{
			framePageTrg = new SigScanTarget(3, "8B 07 A3 ?? ?? ?? ?? 8B 1B 8B 43 0C");
		}

		foreach (var target in new SigScanTarget[] { runTimeTrg, roomNumTrg, roomNameTrg, pointerPageTrg, framePageTrg })
		{
			target.OnFound = (p, s, ptr) => p.ReadPointer(ptr);
		}

		var token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

			IntPtr runTimePtr = scanner.Scan(runTimeTrg);
			IntPtr roomNumPtr = vars.RoomNumPtr = scanner.Scan(roomNumTrg);
			IntPtr roomNamePtr = vars.RoomNamePtr = scanner.Scan(roomNameTrg);
			IntPtr pointerPagePtr = vars.PointerPagePtr = scanner.Scan(pointerPageTrg);
			IntPtr framePagePtr = vars.FramePagePtr = scanner.Scan(framePageTrg);

			var names = new String[] { "runTimePtr", "roomNumPtr", "roomNamePtr", "pointerPagePtr", "framePagePtr" };
			var results = new IntPtr[] { runTimePtr, roomNumPtr, roomNamePtr, pointerPagePtr, framePagePtr };

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

			if (found == 5)
			{
				int runTimeFrames = game.ReadValue<int>(runTimePtr);
				vars.Log("runTimeFrames: " + runTimeFrames);

				if (runTimeFrames <= 120)
				{
					vars.Log("ERROR: waiting for runTimeFrames to be > 120");
				}
				else
				{
					string roomName = new DeepPointer(game.ReadPointer(roomNamePtr) + (game.ReadValue<int>(roomNumPtr) * 4), 0x0).DerefString(game, 128);
					current.RoomName = String.IsNullOrEmpty(roomName) ? "" : roomName.ToLower();
					vars.Log("current.RoomName: \"" + current.RoomName + "\"");

					if (!System.Text.RegularExpressions.Regex.IsMatch(current.RoomName, @"^\w{4,}$"))
					{
						vars.Log("ERROR: invalid current.RoomName");
					}
					else
					{
						vars.Log("Found all targets. Scanning for Frame Counter address..");
						break;
					}
				}
			}

			vars.Log("Retrying..");
			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		while (!token.IsCancellationRequested)
		{
			IntPtr frameVarAddress = IntPtr.Zero;

			int pointerPage = new DeepPointer(vars.PointerPagePtr, 0x2C, 0x10).Deref<int>(game);
			int framePage = game.ReadValue<int>((IntPtr) vars.FramePagePtr);

			int found = 0;
			foreach (var page in game.MemoryPages(false))
			{
				int start = (int) page.BaseAddress;
				int size = (int) page.RegionSize;
				int end = start + size;

				if (frameVarAddress == IntPtr.Zero)
				{
					var scanner = new SignatureScanner(game, page.BaseAddress, size);

					if ((frameVarAddress = scanner.Scan(frameVarTrg)) != IntPtr.Zero) found++;
				}

				if (pointerPage >= start && pointerPage <= end)
				{
					vars.PointerPageBase = start;
					vars.PointerPageSize = size;
					found++;
				}

				if (framePage >= start && framePage <= end)
				{
					vars.FramePageBase = start;
					vars.FramePageEnd = end;
					found++;
				}
			}

			if (found == 3)
			{
				foreach (var page in game.MemoryPages(false))
				{
					var scanner = new SignatureScanner(game, page.BaseAddress, (int) page.RegionSize);

					var frameVarAddressToBytes = new SigScanTarget(0, BitConverter.GetBytes((int) frameVarAddress));
					var frameVarAddressPointers = scanner.ScanAll(frameVarAddressToBytes);

					if (frameVarAddressPointers.Count() > 0)
					{
						foreach (IntPtr frameVarAddressPointer in frameVarAddressPointers)
						{
							scanner = new SignatureScanner(game, (IntPtr) vars.PointerPageBase, vars.PointerPageSize);

							int frameIdentifier = game.ReadValue<int>(frameVarAddressPointer - 0x4);
							var frameIdentifierTrg = new SigScanTarget(0, BitConverter.GetBytes(frameIdentifier));
							var frameIdentifierPointers = scanner.ScanAll(frameIdentifierTrg);

							if (frameIdentifierPointers.Count() > 0)
							{
								foreach (IntPtr frameIdentifierPointer in frameIdentifierPointers)
								{
									int frameCountAddress = game.ReadValue<int>(frameIdentifierPointer - 0x4);
									double frameCount = game.ReadValue<double>((IntPtr) frameCountAddress);

									if (frameCountAddress >= vars.FramePageBase && frameCountAddress <= vars.FramePageEnd && frameCount.ToString().All(Char.IsDigit))
									{
										vars.RoomNum = new MemoryWatcher<int>(vars.RoomNumPtr);
										vars.RoomNamePtr = new MemoryWatcher<int>(vars.RoomNamePtr);
										vars.FrameCount = new MemoryWatcher<double>((IntPtr) frameCountAddress);

										vars.Log("Frame Counter: 0x" + frameCountAddress.ToString("X") + ", value: (double) " + frameCount);
										vars.Log("Task completed successfully.");
										vars.FrameCountFound = true;

										goto found;
									}
								}
							}
						}
					}
				}
			}

			await System.Threading.Tasks.Task.Delay(1000, token);
		}

		found:;
	});
}

update
{
	if (!vars.FrameCountFound) return false;

	vars.RoomNum.Update(game);
	vars.RoomNamePtr.Update(game);
	vars.FrameCount.Update(game);

	if (vars.RoomNum.Changed)
	{
		string roomName = new DeepPointer((IntPtr) vars.RoomNamePtr.Current + (vars.RoomNum.Current * 4), 0x0).DerefString(game, 128);
		current.RoomName = String.IsNullOrEmpty(roomName) ? "" : roomName.ToLower();

		if (vars.PrintRoomNameChanges)
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

// v0.3.2 15-Aug-2022
