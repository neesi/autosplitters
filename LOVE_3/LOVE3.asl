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

	vars.TargetsFound = false;
	vars.CancelSource = new CancellationTokenSource();
	System.Threading.Tasks.Task.Run(async () =>
	{
		vars.Log("Task started. Target scanning..");

		var roomNumTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7");
		var roomNameTrg = new SigScanTarget(10, "7E ?? 8B 2D ?? ?? ?? ?? 8B 3D ?? ?? ?? ?? 2B EF 3B F3 7D");
		var pointerPageTrg = new SigScanTarget(9, "C3 56 8B 74 24 ?? 57 8B 3D ?? ?? ?? ?? 8B");
		var framePageTrg = new SigScanTarget(3, "8B 07 A3 ?? ?? ?? ?? 8B 13 8B 4A 0C");

		if (game.MainModule.ModuleName.ToLower() == "love3_demo.exe")
		{
			framePageTrg = new SigScanTarget(3, "8B 07 A3 ?? ?? ?? ?? 8B 1B 8B 43 0C");
		}

		foreach (var target in new SigScanTarget[] { roomNumTrg, roomNameTrg, pointerPageTrg, framePageTrg })
		{
			target.OnFound = (p, s, ptr) => p.ReadPointer(ptr);
		}

		var token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

			IntPtr roomNumPtr = scanner.Scan(roomNumTrg);
			IntPtr roomNamePtr = scanner.Scan(roomNameTrg);
			IntPtr pointerPagePtr = vars.PointerPagePtr = scanner.Scan(pointerPageTrg);
			IntPtr framePagePtr = vars.FramePagePtr = scanner.Scan(framePageTrg);

			var resultNames = new String[] { "roomNumPtr", "roomNamePtr", "pointerPagePtr", "framePagePtr" };
			var resultValues = new IntPtr[] { roomNumPtr, roomNamePtr, pointerPagePtr, framePagePtr };

			int index = 0;
			int found = 0;
			foreach (IntPtr value in resultValues)
			{
				if (value != IntPtr.Zero)
				{
					found++;
					vars.Log((index + 1) + ". " + resultNames[index] + ": 0x" + value.ToString("X"));
				}
				else
				{
					vars.Log((index + 1) + ". " + resultNames[index] + ": not found");
				}

				index++;
			}

			if (found == 4)
			{
				int roomNumPtrValue = game.ReadValue<int>(roomNumPtr);
				IntPtr roomNamePtrValue = game.ReadPointer(roomNamePtr);
				IntPtr pointerPagePtrValue = game.ReadPointer(pointerPagePtr);
				IntPtr framePagePtrValue = game.ReadPointer(framePagePtr);

				vars.Log("roomNumPtr: [0x" + roomNumPtr.ToString("X") + "] -> 0x" + roomNumPtrValue.ToString("X"));
				vars.Log("roomNamePtr: [0x" + roomNamePtr.ToString("X") + "] -> 0x" + roomNamePtrValue.ToString("X"));
				vars.Log("pointerPagePtr: [0x" + pointerPagePtr.ToString("X") + "] -> 0x" + pointerPagePtrValue.ToString("X"));
				vars.Log("framePagePtr: [0x" + framePagePtr.ToString("X") + "] -> 0x" + framePagePtrValue.ToString("X"));

				string roomName = new DeepPointer(roomNamePtrValue + (roomNumPtrValue * 4), 0x0).DerefString(game, 128);
				current.RoomName = String.IsNullOrEmpty(roomName) ? "" : roomName.ToLower();
				vars.Log("current.RoomName: \"" + current.RoomName + "\"");

				if (!System.Text.RegularExpressions.Regex.IsMatch(current.RoomName, @"^\w{4,}$"))
				{
					vars.Log("ERROR: invalid current.RoomName");
				}
				else
				{
					vars.RoomNum = new MemoryWatcher<int>(roomNumPtr);
					vars.RoomNamePtr = new MemoryWatcher<int>(roomNamePtr);
					vars.FrameCount = new MemoryWatcher<double>(IntPtr.Zero);

					vars.TargetsFound = true;
					vars.Log("Found all targets. Scanning for Frame Counter address..");
					break;
				}
			}

			vars.Log("Retrying..");
			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		while (!token.IsCancellationRequested)
		{
			int pointerPage = new DeepPointer((IntPtr) vars.PointerPagePtr, 0x2C, 0x10).Deref<int>(game);
			int framePage = game.ReadValue<int>((IntPtr) vars.FramePagePtr);

			int found = 0;
			foreach (var page in game.MemoryPages(true).Reverse())
			{
				int start = (int) page.BaseAddress;
				int end = (int) page.BaseAddress + (int) page.RegionSize;

				if (pointerPage >= start && pointerPage <= end)
				{
					vars.PointerPageBase = start;
					vars.PointerPageEnd = end;
					found++;
				}

				if (framePage >= start && framePage <= end)
				{
					vars.FramePageBase = start;
					vars.FramePageEnd = end;
					found++;
				}
			}

			if (found == 2)
			{
				foreach (var stringPage in game.MemoryPages(true).Reverse())
				{
					var scanner = new SignatureScanner(game, stringPage.BaseAddress, (int) stringPage.RegionSize);

					IntPtr stringAddress = IntPtr.Zero;
					IntPtr stringAddressPtr = IntPtr.Zero;

					var playertime = new SigScanTarget(0, "70 6C 61 79 65 72 74 69 6D 65 00 78 78 78 78 78 70 6C 61 79 65 72 74 69 6D 65 00 78 78 78 78 78");

					if ((stringAddress = scanner.Scan(playertime)) != IntPtr.Zero)
					{
						foreach (var stringPtrPage in game.MemoryPages(true).Reverse())
						{
							scanner = new SignatureScanner(game, stringPtrPage.BaseAddress, (int) stringPtrPage.RegionSize);
							var stringAddressToBytes = new SigScanTarget(0, BitConverter.GetBytes((int) stringAddress));

							if ((stringAddressPtr = scanner.Scan(stringAddressToBytes)) != IntPtr.Zero)
							{
								int i = vars.PointerPageBase;
								int frameAddressIdentifier = game.ReadValue<int>(stringAddressPtr - 0x4);

								while (i <= vars.PointerPageEnd)
								{
									if (game.ReadValue<int>((IntPtr) i) == frameAddressIdentifier && game.ReadValue<int>((IntPtr) i - 0x4) >= vars.FramePageBase && game.ReadValue<int>((IntPtr) i - 0x4) <= vars.FramePageEnd)
									{
										IntPtr frameCountAddress = game.ReadPointer((IntPtr) i - 0x4);
										double frameCount = game.ReadValue<double>(frameCountAddress);
										vars.FrameCount = new MemoryWatcher<double>(frameCountAddress);

										vars.Log("Frame Counter: 0x" + frameCountAddress.ToString("X") + ", value: (double) " + frameCount);
										vars.Log("Task completed successfully.");
										goto found;
									}

									i += 0x4;
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
	if (!vars.TargetsFound) return false;

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

// v0.3.5 10-Aug-2022
