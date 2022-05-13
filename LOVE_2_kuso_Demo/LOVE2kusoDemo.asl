state("KUSO") {}

startup
{
	vars.Log = (Action<dynamic>)(output => print("   [LOVE 2: kuso Demo]   " + output));
	vars.PrintRoomNameChanges = false;

	settings.Add("SleepMargin", false, "SleepMargin -- Fix low in-game FPS");
	settings.SetToolTip("SleepMargin", "Greatest checked value is used. Uncheck all and restart game to set game default.");

		settings.Add("SleepMargin1", false, "1", "SleepMargin");
		settings.Add("SleepMargin10", false, "10", "SleepMargin");
		settings.Add("SleepMargin40", false, "40", "SleepMargin");
		settings.Add("SleepMargin80", false, "80", "SleepMargin");
		settings.Add("SleepMargin200", false, "200", "SleepMargin");
}

init
{
	vars.SleepMargin = (Action)(() =>
	{
		if (settings["SleepMargin"])
		{
			byte margin = 0x00;

			if (settings["SleepMargin200"])     margin = 0xC8;
			else if (settings["SleepMargin80"]) margin = 0x50;
			else if (settings["SleepMargin40"]) margin = 0x28;
			else if (settings["SleepMargin10"]) margin = 0x0A;
			else if (settings["SleepMargin1"])  margin = 0x01;

			if (margin > 0x00 && margin != game.ReadValue<int>((IntPtr) vars.SleepMarginPtr))
			{
				byte[] sleepMarginSetting = new byte[] { margin, 0x00, 0x00, 0x00 };

				try
				{
					game.Suspend();
					game.WriteBytes((IntPtr) vars.SleepMarginPtr, sleepMarginSetting);
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
			}
		}
	});

	vars.RoomActionList = new List<string>()
	{
		"room_startup",
		"room_titlescreen",
		"room_mainmenu",
		"room_gameselect",
		"room_levelselect",
		"room_about",
		"room_options"
	};

	vars.TargetsFound = false;
	vars.FrameCountFound = false;
	vars.NewFrame = false;

	vars.SubtractFrames = 0;
	vars.SubtractFramesCache = 0;

	vars.CancelSource = new CancellationTokenSource();
	System.Threading.Tasks.Task.Run(async () =>
	{
		vars.Log("Task started. Target scanning..");

		int gameBaseAddr = (int) game.MainModule.BaseAddress;
		vars.Log("game.MainModule.BaseAddress: 0x" + gameBaseAddr.ToString("X"));

		var runTimeTrg = new SigScanTarget(8, "D9 54 24 04 D9 EE 8B 15");
		var roomNumTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7");
		var roomNameTrg = new SigScanTarget(13, "90 8A 08 88 0C 02 40 84 C9 ?? ?? 8B 0D ?? ?? ?? ?? 8B");
		var miscTrg = new SigScanTarget(9, "CC 83 EC 20 53 55 56 8B 35 ?? ?? ?? ?? 57");
		var frameTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 3B 05 ?? ?? ?? ?? ?? ?? 8B 0D ?? ?? ?? ?? 83 C1 F0");
		var tempUnpatchedTrg = new SigScanTarget(0, "FF 15 9C 51 6A 00 8B E8 33 C0");
		var tempPatchedTrg = new SigScanTarget(0, "89 07 E9 58 01 00 00 90");
		var sleepMarginTrg = new SigScanTarget(11, "8B ?? ?? ?? ?? ?? ?? 83 C4 0C A3 ?? ?? ?? ?? C6");

		foreach (var target in new SigScanTarget[] { runTimeTrg, roomNumTrg, roomNameTrg, miscTrg, frameTrg, sleepMarginTrg })
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
			IntPtr tempUnpatched = scanner.Scan(tempUnpatchedTrg);
			IntPtr tempPatched = scanner.Scan(tempPatchedTrg);
			IntPtr sleepMarginPtr = vars.SleepMarginPtr = scanner.Scan(sleepMarginTrg);

			var resultNames = new String[] { "runTimePtr", "roomNumPtr", "roomNamePtr", "miscPtr", "framePtr", "tempUnpatched", "tempPatched", "sleepMarginPtr" };
			var resultValues = new IntPtr[] { runTimePtr, roomNumPtr, roomNamePtr, miscPtr, framePtr, tempUnpatched, tempPatched, sleepMarginPtr };

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

			if (found == 7)
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
					int frameSearchBase = new DeepPointer(miscPtrValue + 0x34, 0x10).Deref<int>(game);
					vars.Log("frameSearchBase: 0x" + frameSearchBase.ToString("X"));

					if (!(frameSearchBase > gameBaseAddr))
					{
						scanErrorList.Add("ERROR: invalid frameSearchBase");
					}

					if (tempPatched != IntPtr.Zero)
					{
						vars.Log("Game is already patched.");
					}
					else if (tempUnpatched != IntPtr.Zero)
					{
						byte[] tempPatch = new byte[] { 0xE9, 0x58, 0x01, 0x00, 0x00, 0x90 };

						try
						{
							game.Suspend();
							game.WriteBytes(tempUnpatched, tempPatch); // when exiting the game, it tries to delete your %temp% folder. this patches that bug.
							vars.Log("Game was patched.");
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
					}
					else
					{
						scanErrorList.Add("ERROR: tempUnpatched / tempPatched not found.");
					}

					int sleepMargin = game.ReadValue<int>(sleepMarginPtr);
					vars.Log("sleepMargin: " + sleepMargin);
				}

				if (scanErrorList.Count == 0)
				{
					vars.RunTime = new MemoryWatcher<int>(runTimePtr);
					vars.RoomNum = new MemoryWatcher<int>(roomNumPtr);
					vars.RoomNamePtr = new MemoryWatcher<int>(roomNamePtr);
					vars.FrameSearchBase = new MemoryWatcher<int>(new DeepPointer(vars.MiscPtrValue + 0x34, 0x10));
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

		var addrPool = new Dictionary<int, Tuple<double, int, int>>();
		vars.Address = 0;

		while (!token.IsCancellationRequested && !vars.FrameCountFound)
		{
			try
			{
				game.Suspend();
				IntPtr framePtrValue = game.ReadPointer((IntPtr) vars.FramePtr);

				int step1 = new DeepPointer(framePtrValue - 0x884 + 0x814, 0x0).Deref<int>(game);
				long step2 = step1 & 0xFFFFFFF;
				int step3 = (int) (step2 + 0xFFFE7960) + 1;
				long step4 = step3 + (step3 * 2);
				long step5 = vars.FrameSearchBase.Current + (step4 * 4) + 0x4;

				vars.Address = game.ReadValue<int>((IntPtr) step5);
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

	vars.SleepMargin();
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

		if (old.RoomName == "room_levelselect")
		{
			vars.SubtractFrames = vars.SubtractFramesCache;
		}

		if (vars.PrintRoomNameChanges)
		{
			vars.Log("old.RoomName: \"" + old.RoomName + "\" -> current.RoomName: \"" + current.RoomName + "\"");
		}
	}

	if (vars.FrameCount.Current < vars.SubtractFrames)
	{
		vars.SubtractFrames = 0;
		vars.SubtractFramesCache = 0;
	}

	if (current.RoomName == "room_levelselect" && vars.FrameCount.Current > 90)
	{
		 vars.SubtractFramesCache = vars.FrameCount.Current;
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
	       vars.RoomActionList.Contains(current.RoomName) && current.RoomName != "room_levelselect" ||
	       vars.RoomNum.Changed && old.RoomName == "room_levelselect";
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
	vars.CancelSource.Cancel();
}

// v0.3.5 13-May-2022
