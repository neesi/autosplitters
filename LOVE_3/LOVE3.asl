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

	vars.FrameSearch = (Action)(() =>
	{
		game.Suspend();
		IntPtr framePtrValue = game.ReadPointer((IntPtr) vars.FramePtr);

		int step1 = new DeepPointer(framePtrValue + 0x28).Deref<int>(game);
		int step2 = new DeepPointer(framePtrValue + 0x58).Deref<int>(game);
		int step3 = new DeepPointer((IntPtr) (step1 + step2) + 0x4).Deref<int>(game);
		long step4 = step3 & 0x7FFFFFF;
		long step5 = (0x1 - (0x61C8864F * step4)) & 0x7FFFFFFF;
		long step6 = vars.FrameSearchMore.Current & step5;
		long step7 = step6 + (step6 * 2);
		long step8 = vars.FrameSearchBase.Current + (step7 * 4);

		vars.Address = game.ReadValue<int>((IntPtr) step8);
	});

	vars.TargetsFound = false;
	vars.FrameCountFound = false;
	vars.NewFrame = false;

	vars.CancelSource = new CancellationTokenSource();
	System.Threading.Tasks.Task.Run(async () =>
	{
		vars.Log("Task started. Target scanning..");

		int gameBaseAddr = (int) game.MainModule.BaseAddress;
		vars.Log("game.MainModule.BaseAddress: 0x" + gameBaseAddr.ToString("X"));

		var runTimeTrg = new SigScanTarget(4, "CC 53 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 56 57 83 CF FF");
		var roomNumTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7");
		var roomNameTrg = new SigScanTarget(10, "7E ?? 8B 2D ?? ?? ?? ?? 8B 3D ?? ?? ?? ?? 2B EF 3B F3 7D");
		var miscTrg = new SigScanTarget(9, "C3 56 8B 74 24 ?? 57 8B 3D ?? ?? ?? ?? 8B");
		var frameTrg = new SigScanTarget(3, "CC CC A1 ?? ?? ?? ?? 53 8B 58 2C");

		if (game.MainModule.ModuleName.ToLower() == "love3_demo.exe")
		{
			frameTrg = new SigScanTarget(7, "8B 8E ?? ?? ?? ?? A3 ?? ?? ?? ?? 89 ?? ?? ?? ?? ?? 89");

			vars.FrameSearch = (Action)(() =>
			{
				game.Suspend();
				IntPtr framePtrValue = game.ReadPointer((IntPtr) vars.FramePtr);
				vars.Address = new DeepPointer(framePtrValue - 0x80 + 0x8C).Deref<int>(game);
			});
		}

		foreach (var target in new SigScanTarget[] { runTimeTrg, roomNumTrg, roomNameTrg, miscTrg, frameTrg })
		{
			target.OnFound = (p, s, ptr) => p.ReadPointer(ptr);
		}

		var token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			var scanErrorList = new List<string>();
			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

			IntPtr runTimePtr = scanner.Scan(runTimeTrg);
			IntPtr roomNumPtr = scanner.Scan(roomNumTrg);
			IntPtr roomNamePtr = scanner.Scan(roomNameTrg);
			IntPtr miscPtr = scanner.Scan(miscTrg);
			IntPtr framePtr = vars.FramePtr = scanner.Scan(frameTrg);

			var resultNames = new String[] { "runTimePtr", "roomNumPtr", "roomNamePtr", "miscPtr", "framePtr" };
			var resultValues = new IntPtr[] { runTimePtr, roomNumPtr, roomNamePtr, miscPtr, framePtr };

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

			if (found == 5)
			{
				int runTimeFrames = game.ReadValue<int>(runTimePtr);
				vars.Log("runTimeFrames: " + runTimeFrames);

				if (runTimeFrames <= 120)
				{
					scanErrorList.Add("ERROR: waiting for runTimeFrames to be > 120");
				}
				else
				{
					int roomNum = game.ReadValue<int>(roomNumPtr);
					IntPtr roomNamePtrValue = game.ReadPointer(roomNamePtr);

					string roomName = new DeepPointer(roomNamePtrValue + (roomNum * 4), 0x0).DerefString(game, 128);
					current.RoomName = String.IsNullOrEmpty(roomName) ? "" : roomName.ToLower();
					vars.Log("current.RoomName: \"" + current.RoomName + "\"");

					if (!System.Text.RegularExpressions.Regex.IsMatch(current.RoomName, @"^\w{4,}$"))
					{
						scanErrorList.Add("ERROR: invalid current.RoomName");
					}

					IntPtr miscPtrValue = vars.MiscPtrValue = game.ReadPointer(miscPtr);
					int frameSearchBase = new DeepPointer(miscPtrValue + 0x2C, 0x10).Deref<int>(game);
					vars.Log("frameSearchBase: 0x" + frameSearchBase.ToString("X"));

					if (!(frameSearchBase > gameBaseAddr))
					{
						scanErrorList.Add("ERROR: invalid frameSearchBase");
					}
				}

				if (scanErrorList.Count == 0)
				{
					vars.RunTime = new MemoryWatcher<int>(runTimePtr);
					vars.RoomNum = new MemoryWatcher<int>(roomNumPtr);
					vars.RoomNamePtr = new MemoryWatcher<int>(roomNamePtr);
					vars.FrameSearchBase = new MemoryWatcher<int>(new DeepPointer(vars.MiscPtrValue + 0x2C, 0x10));
					vars.FrameSearchMore = new MemoryWatcher<int>(new DeepPointer(vars.MiscPtrValue + 0x2C, 0x8));
					vars.FrameCount = new MemoryWatcher<double>(IntPtr.Zero);

					vars.TargetsFound = true;
					vars.Log("Found all targets. Enter a level to grab Frame Counter address..");
					break;
				}
			}

			scanErrorList.ForEach(vars.Log);
			vars.Log("Retrying..");
			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		vars.FrameSearchBase.Update(game);
		vars.FrameSearchMore.Update(game);

		var addrPool = new Dictionary<int, Tuple<double, int, int>>();
		vars.Address = 0;

		while (!token.IsCancellationRequested && !vars.FrameCountFound)
		{
			try
			{
				vars.FrameSearch();
			}
			catch (Exception ex)
			{
				game.Resume();
				vars.Log(ex.ToString());
			}
			finally
			{
				game.Resume();
			}

			if (!vars.RoomActionList.Contains(current.RoomName) && !addrPool.ContainsKey(vars.Address))
			{
				addrPool.Add(vars.Address, Tuple.Create(0.0, 0, 0));
			}

			if (vars.NewFrame)
			{
				vars.FrameSearchBase.Update(game);
				vars.FrameSearchMore.Update(game);

				foreach (int address in addrPool.Keys.ToList())
				{
					double value = game.ReadValue<double>((IntPtr) address);
					double oldValue = addrPool[address].Item1;
					int increased = addrPool[address].Item2;
					int unchanged = addrPool[address].Item3;

					if (value.ToString().All(Char.IsDigit) && value > oldValue)
					{
						increased++;
						addrPool[address] = Tuple.Create(value, increased, 0);

						if (increased > 40 && !vars.RoomActionList.Contains(current.RoomName))
						{
							IntPtr frameCountAddr = (IntPtr) address;
							double frameCountValue = game.ReadValue<double>(frameCountAddr);
							vars.Log("Frame Counter: 0x" + frameCountAddr.ToString("X") + ", value: (double) " + frameCountValue);

							vars.FrameCount = new MemoryWatcher<double>(frameCountAddr);

							vars.FrameCountFound = true;
							vars.Log("Task completed successfully.");
							break;
						}
					}
					else if (value == oldValue)
					{
						unchanged++;
						addrPool[address] = Tuple.Create(value, increased, unchanged);
					}

					if (!value.ToString().All(Char.IsDigit) || value < oldValue || unchanged > 4)
					{
						addrPool[address] = Tuple.Create(value, 0, 0);
					}
				}

				vars.NewFrame = false;
			}
		}
	});
}

update
{
	if (!vars.TargetsFound) return false;

	vars.RoomNum.Update(game);
	vars.RoomNamePtr.Update(game);
	vars.FrameCount.Update(game);

	if (!vars.FrameCountFound)
	{
		vars.RunTime.Update(game);

		if (vars.RunTime.Current > vars.RunTime.Old)
		{
			vars.NewFrame = true;
		}
	}

	if (vars.RoomNum.Changed)
	{
		string roomName = new DeepPointer((IntPtr) vars.RoomNamePtr.Current + (vars.RoomNum.Current * 4), 0x0).DerefString(game, 128);
		current.RoomName = String.IsNullOrEmpty(roomName) ? "" : roomName.ToLower();

		if (vars.PrintRoomNameChanges)
		{
			vars.Log("old.RoomName: \"" + old.RoomName + "\" -> current.RoomName: \"" + current.RoomName + "\"");
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

// v0.3.5 13-May-2022
