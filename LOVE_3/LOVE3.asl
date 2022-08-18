state("LOVE3") {}

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

		var roomNumTrg = new SigScanTarget(7, "CC CC CC 8B D1 8B 0D ?? ?? ?? ?? E9 ?? ?? ?? ?? CC");
		var roomNameTrg = new SigScanTarget(16, "FF C8 48 63 D0 48 63 D9 48 3B D3 7C 18 48 8B 0D");
		var frameVarTrg = new SigScanTarget(0, "70 6C 61 79 65 72 74 69 6D 65 00 78 78 78 78 78 70 6C 61 79 65 72 74 69 6D 65 00 78 78 78 78 78"); // playertime
		var framePageTrg = new SigScanTarget(4, "C3 48 8B 15 ?? ?? ?? ?? 48 85 D2 0F 85");

		foreach (var target in new SigScanTarget[] { roomNumTrg, roomNameTrg, framePageTrg })
		{
			target.OnFound = (p, s, ptr) => ptr + 0x4 + p.ReadValue<int>(ptr);
		}

		var token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

			IntPtr roomNumPtr = vars.RoomNumPtr = scanner.Scan(roomNumTrg);
			IntPtr roomNamePtr = vars.RoomNamePtr = scanner.Scan(roomNameTrg);
			IntPtr framePagePtr = vars.FramePagePtr = scanner.Scan(framePageTrg);

			var names = new String[] { "roomNumPtr", "roomNamePtr", "framePagePtr" };
			var results = new IntPtr[] { roomNumPtr, roomNamePtr, framePagePtr };

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

					byte[] frameVarAddressToBytes = BitConverter.GetBytes((int) frameVarAddress);
					string addressBytesToString = BitConverter.ToString(frameVarAddressToBytes).Replace("-", " ");
					var frameVarAddressTrg = new SigScanTarget(0, "00 00 00 00", addressBytesToString, "00 00 00 00");
					var frameVarAddressPointers = scanner.ScanAll(frameVarAddressTrg);

					foreach (IntPtr frameVarAddressPointer in frameVarAddressPointers)
					{
						int frameIdentifier = game.ReadValue<int>(frameVarAddressPointer - 0x4);

						if (frameIdentifier <= 0x186A0) continue;

						byte[] frameIdentifierToBytes = BitConverter.GetBytes(frameIdentifier);
						string identifierBytesToString = BitConverter.ToString(frameIdentifierToBytes).Replace("-", " ");
						var frameIdentifierTrg = new SigScanTarget(0, "00 00 00 00", identifierBytesToString);

						foreach (var page_ in game.MemoryPages(false))
						{
							scanner = new SignatureScanner(game, page_.BaseAddress, (int) page_.RegionSize);

							var frameIdentifierPointers = scanner.ScanAll(frameIdentifierTrg);

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

// v0.4.0 18-Aug-2022
