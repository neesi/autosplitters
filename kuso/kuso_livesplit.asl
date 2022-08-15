state("kuso") {}

startup
{
	vars.Log = (Action<dynamic>)(output => print("   [LOVE 2: kuso]   " + output));
	vars.PrintRoomNameChanges = false;
}

init
{
	vars.RoomActionList = new List<string>()
	{
		"room_startup",
		"room_titlescreen",
		"room_mainmenu",
		"room_gameselect",
		"room_levelsetselect",
		"room_levelselect",
		"room_levelselect_kuso",
		"room_levelselect_love",
		"room_levelselect_other",
		"room_achievements",
		"room_tut1",
		"room_tut2",
		"room_tut3",
		"room_credits",
		"room_options",
		"room_options_camera",
		"room_options_animationstyle",
		"room_options_animationstylesteam",
		"room_controls",
		"room_kusosnail_play",
		"room_loadgame",
		"room_2p_start",
		"room_2p_select",
		"room_2p_results",
		"room_loadgame"
	};

	vars.RoomName = (Action)(() =>
	{
		string roomName = new DeepPointer(game.ReadPointer((IntPtr) vars.RoomNamePtr) + (game.ReadValue<int>((IntPtr) vars.RoomNumPtr) * 8), 0x0).DerefString(game, 128);
		current.RoomName = String.IsNullOrEmpty(roomName) ? "" : roomName.ToLower();
	});

	vars.FrameCountFound = false;
	vars.CancelSource = new CancellationTokenSource();
	System.Threading.Tasks.Task.Run(async () =>
	{
		vars.Log("Task started. Target scanning..");

		var runTimeTrg = new SigScanTarget(13, "CC CC 8B 0D ?? ?? ?? ?? 33 D2 48 FF 05");
		var roomNumTrg = new SigScanTarget(7, "CC CC CC 8B D1 8B 0D ?? ?? ?? ?? E9 ?? ?? ?? ?? CC");
		var roomNameTrg = new SigScanTarget(16, "FF C8 48 63 D0 48 63 D9 48 3B D3 7C 18 48 8B 0D");
		var frameVarTrg = new SigScanTarget(0, "70 6C 61 79 65 72 46 72 61 6D 65 73 00 78 78 78 70 6C 61 79 65 72 46 72 61 6D 65 73 00 78 78 78"); // playerFrames
		var pointerPageTrg = new SigScanTarget(3, "4C 8B 05 ?? ?? ?? ?? 48 8B D8 40 84 ED");
		var framePageTrg = new SigScanTarget(4, "C3 48 8B 15 ?? ?? ?? ?? 48 85 D2 0F 85");

		foreach (var target in new SigScanTarget[] { runTimeTrg, roomNumTrg, roomNameTrg, pointerPageTrg, framePageTrg })
		{
			target.OnFound = (p, s, ptr) => ptr + 0x4 + p.ReadValue<int>(ptr);
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
					vars.RoomName();
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

			int pointerPage = new DeepPointer(vars.PointerPagePtr, 0x48, 0x10).Deref<int>(game);
			int framePage = game.ReadValue<int>((IntPtr) vars.FramePagePtr);

			int found = 0;
			foreach (var page in game.MemoryPages(false))
			{
				long start = (long) page.BaseAddress;
				int size = (int) page.RegionSize;
				long end = start + size;

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

					byte[] frameVarAddressToBytes = BitConverter.GetBytes((int) frameVarAddress);
					string frameVarBytesToString = BitConverter.ToString(frameVarAddressToBytes).Replace("-", " ");
					var frameVarAddressTrg = new SigScanTarget(0, "00 00 00 00", frameVarBytesToString, "00 00 00 00");
					var frameVarAddressPointers = scanner.ScanAll(frameVarAddressTrg);

					if (frameVarAddressPointers.Count() > 0)
					{
						foreach (IntPtr frameVarAddressPointer in frameVarAddressPointers)
						{
							scanner = new SignatureScanner(game, (IntPtr) vars.PointerPageBase, vars.PointerPageSize);

							int frameIdentifier = game.ReadValue<int>(frameVarAddressPointer - 0x4);
							byte[] frameIdentifierToBytes = BitConverter.GetBytes(frameIdentifier);
							string frameBytesToString = BitConverter.ToString(frameIdentifierToBytes).Replace("-", " ");
							var frameIdentifierTrg = new SigScanTarget(0, "00 00 00 00", frameBytesToString);
							var frameIdentifierPointers = scanner.ScanAll(frameIdentifierTrg);

							if (frameIdentifierPointers.Count() > 0)
							{
								foreach (IntPtr frameIdentifierPointer in frameIdentifierPointers)
								{
									int frameCountAddress = game.ReadValue<int>(frameIdentifierPointer - 0x4);
									double frameCount = game.ReadValue<double>((IntPtr) frameCountAddress);

									if (frameCountAddress >= vars.FramePageBase && frameCountAddress <= vars.FramePageEnd && frameCount.ToString().All(Char.IsDigit))
									{
										vars.RoomName();

										vars.RoomNum = new MemoryWatcher<int>(vars.RoomNumPtr);
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
	vars.FrameCount.Update(game);

	if (vars.RoomNum.Changed)
	{
		vars.RoomName();

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
	return vars.RoomNum.Changed && vars.FrameCount.Current > 90;
}

reset
{
	return vars.FrameCount.Current < vars.FrameCount.Old ||
	       vars.RoomActionList.Contains(current.RoomName);
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

// v0.3.5 16-Aug-2022
