state("Love") {}

startup
{
	vars.Log = (Action<dynamic>)(output => print("   [LOVE]   " + output));
	vars.PrintRoomNameChanges = false;
}

init
{
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

		var runTimeTrg = new SigScanTarget(4, "74 37 FF ?? ?? ?? ?? ?? E8 ?? ?? ?? ?? FF");
		var roomNumTrg = new SigScanTarget(8, "56 E8 ?? ?? ?? ?? 8B 0D ?? ?? ?? ?? 83 C4 08 A1 ?? ?? ?? ?? 5F 5E 5B");
		var roomNameTrg = new SigScanTarget(10, "7E ?? 8B 2D ?? ?? ?? ?? 8B 3D ?? ?? ?? ?? 2B EF");
		var miscTrg = new SigScanTarget(10, "8B C8 E8 ?? ?? ?? ?? 8B D8 A1 ?? ?? ?? ?? 56 8B 73 08");
		var frameTrg = new SigScanTarget(3, "57 50 A3 ?? ?? ?? ?? E8 ?? ?? ?? ?? 8B 45 0C");

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
					int frameSearchBase = new DeepPointer(miscPtrValue + 0x24, 0x10).Deref<int>(game);
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
					vars.FrameSearchBase = new MemoryWatcher<int>(new DeepPointer(vars.MiscPtrValue + 0x24, 0x10));
					vars.FrameSearchMore = new MemoryWatcher<int>(new DeepPointer(vars.MiscPtrValue + 0x24, 0x8));
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

		var addrPool = new Dictionary<IntPtr, Tuple<double, int, int>>();
		vars.Address = 0;
		var candidates = new List<int>();
		while (!token.IsCancellationRequested && !vars.FrameCountFound)
		{
			try
			{
				game.Suspend();
				IntPtr framePtrValue = game.ReadPointer((IntPtr) vars.FramePtr);

				int step1 = new DeepPointer(framePtrValue - 0x68, 0x0).Deref<int>(game);
				long step2 = step1 & 0xFFFFFFF;
				long step3 = (step2 * 0x61C8864FL) & 0xFFFFFFFF;
				long step4 = (0x1 - step3) & 0xFFFFFFFF;
				long step5 = step4 & 0x7FFFFFFF;
				long step6 = vars.FrameSearchMore.Current & step5;
				long step7 = step6 + (step6 * 2);
				long step8 = vars.FrameSearchBase.Current + (step7 * 4);

				vars.Address = game.ReadPointer((IntPtr) step8);
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

			if (!addrPool.ContainsKey(vars.Address) && !vars.RoomActionList.Contains(current.RoomName))
			{
				addrPool.Add(vars.Address, Tuple.Create(0.0, 0, 0));
			}

			if (vars.NewFrame)
			{
				foreach (IntPtr address in addrPool.Keys.ToList())
				{
					double value = game.ReadValue<double>(address);
					double oldValue = addrPool[address].Item1;
					int increased = addrPool[address].Item2;
					int unchanged = addrPool[address].Item3;

					if (value.ToString().All(Char.IsDigit) && value > oldValue)
					{
						increased++;
						addrPool[address] = Tuple.Create(value, increased, 0);

						if (increased > 40 && !vars.RoomActionList.Contains(current.RoomName))
						{
							if (!candidates.Contains((int) address))
							{
								candidates.Add((int) address);
							}

							if (increased > 140)
							{
								int frameCountAddr = candidates.Max();
								vars.FrameCount = new MemoryWatcher<double>((IntPtr) frameCountAddr);

								vars.FrameCountFound = true;
								vars.Log("Frame Counter: 0x" + frameCountAddr.ToString("X") + ", value: (double) " + value);
								vars.Log("Task completed successfully.");
								break;
							}
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
						candidates.Remove((int) address);
					}
				}

				if (vars.FrameSearchBase.Changed || vars.FrameSearchMore.Changed || vars.RoomActionList.Contains(current.RoomName))
				{
					addrPool.Clear();
					candidates.Clear();
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
		vars.FrameSearchBase.Update(game);
		vars.FrameSearchMore.Update(game);

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

// v0.3.5 30-Jul-2022
