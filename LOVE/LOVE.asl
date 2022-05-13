state("Love") {}

startup
{
	vars.Log = (Action<dynamic>)(output => print("   [LOVE]   " + output));
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
		"loading",
		"controls_room",
		"start",
		"mainmenu",
		"gameselect",
		"about_room",
		"levelselect_room",
		"tutorial_room",
		"options_room",
		"soundtest_room",
		"flap_start_room",
		"flap_play_room",
		"room_load",
		"room_keyconfig_start",
		"room_keyconfig_config"
	};

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
		var frameTrg = new SigScanTarget(20, "8B 33 C7 46 ?? 00 00 00 00 C7 86 ?? 00 00 00 ?? ?? ?? ?? A1");
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
			IntPtr sleepMarginPtr = vars.SleepMarginPtr = scanner.Scan(sleepMarginTrg);

			var resultNames = new String[] { "runTimePtr", "roomNumPtr", "roomNamePtr", "miscPtr", "framePtr", "sleepMarginPtr" };
			var resultValues = new IntPtr[] { runTimePtr, roomNumPtr, roomNamePtr, miscPtr, framePtr, sleepMarginPtr };

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

			if (found == 6)
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

					int sleepMargin = game.ReadValue<int>(sleepMarginPtr);
					vars.Log("sleepMargin: " + sleepMargin);
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
				game.Suspend();
				IntPtr framePtrValue = game.ReadPointer((IntPtr) vars.FramePtr);

				int step1 = new DeepPointer(framePtrValue + 0x24, 0x4).Deref<int>(game);
				long step2 = (step1 & 0xFFFFFFF) - 0x186A0;
				long step3 = (0x1 - (0x61C8864F * step2)) & 0xFFFFFFFF;
				long step4 = step3 & 0x7FFFFFFF;
				long step5 = vars.FrameSearchMore.Current & step4;
				long step6 = step5 + (step5 * 2);
				long step7 = vars.FrameSearchBase.Current + (step6 * 4);

				vars.Address = game.ReadValue<int>((IntPtr) step7);
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

// v0.3.5 13-May-2022
