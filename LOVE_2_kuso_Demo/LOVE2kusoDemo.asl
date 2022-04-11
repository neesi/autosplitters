state("KUSO") {}

startup
{
	vars.Log = (Action<dynamic>)(output => print("[LOVE 2: kuso Demo] " + output));

	vars.PrintFrameCandidateChanges = false;
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
		vars.Log("# game.MainModule.BaseAddress: 0x" + gameBaseAddr.ToString("X"));

		var runTimeTrg = new SigScanTarget(8, "D9 54 24 04 D9 EE 8B 15");
		var roomNumTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7");
		var roomNameTrg = new SigScanTarget(13, "90 8A 08 88 0C 02 40 84 C9 ?? ?? 8B 0D ?? ?? ?? ?? 8B");
		var miscTrg = new SigScanTarget(4, "8B 08 89 ?? ?? ?? ?? ?? 8B 56 2C 50 89");
		var tempUnpatchedTrg = new SigScanTarget(0, "FF 15 9C 51 6A 00 8B E8 33 C0");
		var tempPatchedTrg = new SigScanTarget(0, "89 07 E9 58 01 00 00 90");
		var sleepMarginTrg = new SigScanTarget(11, "8B ?? ?? ?? ?? ?? ?? 83 C4 0C A3 ?? ?? ?? ?? C6");

		foreach (var trg in new[] { runTimeTrg, roomNumTrg, roomNameTrg, miscTrg, sleepMarginTrg })
		{
			trg.OnFound = (p, s, ptr) => p.ReadPointer(ptr);
		}

		IntPtr runTimePtr = IntPtr.Zero, roomNumPtr = IntPtr.Zero, roomNamePtr = IntPtr.Zero, miscPtr = IntPtr.Zero, tempUnpatched = IntPtr.Zero, tempPatched = IntPtr.Zero, sleepMarginPtr = IntPtr.Zero;

		var token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			var scanErrorList = new List<string>();
			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

			if ((runTimePtr = scanner.Scan(runTimeTrg)) != IntPtr.Zero)
			{
				int runTimeValue = game.ReadValue<int>(runTimePtr);
				vars.Log("# runTimePtr address: 0x" + runTimePtr.ToString("X") + ", value: (int) " + runTimeValue);

				if (runTimeValue <= 120)
				{
					scanErrorList.Add("ERROR: waiting for runTimeValue to be > 120");
				}
			}
			else
			{
				scanErrorList.Add("ERROR: runTimePtr not found.");
			}

			if ((roomNumPtr = scanner.Scan(roomNumTrg)) != IntPtr.Zero)
			{
				int roomNumValue = game.ReadValue<int>(roomNumPtr);
				vars.Log("# roomNumPtr address: 0x" + roomNumPtr.ToString("X") + ", value: (int) " + roomNumValue);
			}
			else
			{
				scanErrorList.Add("ERROR: roomNumPtr not found.");
			}

			if ((roomNamePtr = scanner.Scan(roomNameTrg)) != IntPtr.Zero)
			{
				int roomNamePtrValue = game.ReadValue<int>(roomNamePtr);
				vars.Log("# roomNamePtr address: 0x" + roomNamePtr.ToString("X") + ", value: (hex) " + roomNamePtrValue.ToString("X"));

				int roomNumValue = game.ReadValue<int>(roomNumPtr);
				int roomNameInt = game.ReadValue<int>((IntPtr) roomNamePtrValue + (4 * roomNumValue));

				string roomName = game.ReadString((IntPtr) roomNameInt, 128);
				current.RoomName = String.IsNullOrEmpty(roomName) ? "" : roomName.ToLower();
				vars.Log("# current.RoomName: \"" + current.RoomName + "\"");

				if (System.Text.RegularExpressions.Regex.IsMatch(current.RoomName, @"^\w{4,}$"))
				{
					vars.RunTime = new MemoryWatcher<int>(runTimePtr);
					vars.RoomNum = new MemoryWatcher<int>(roomNumPtr);
					vars.RoomNamePtr = new MemoryWatcher<int>(roomNamePtr);
					vars.FrameCount = new MemoryWatcher<double>(IntPtr.Zero);
				}
				else
				{
					scanErrorList.Add("ERROR: invalid current.RoomName");
				}
			}
			else
			{
				scanErrorList.Add("ERROR: roomNamePtr not found.");
			}

			if ((miscPtr = scanner.Scan(miscTrg)) != IntPtr.Zero)
			{
				vars.MiscSearchBase = game.ReadValue<int>(miscPtr);
				vars.Log("# miscPtr address: 0x" + miscPtr.ToString("X") + ", value: (hex) " + vars.MiscSearchBase.ToString("X"));

				if ((tempPatched = scanner.Scan(tempPatchedTrg)) != IntPtr.Zero)
				{
					vars.Log("Game is already patched.");
				}
				else if ((tempUnpatched = scanner.Scan(tempUnpatchedTrg)) != IntPtr.Zero)
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
			}
			else
			{
				scanErrorList.Add("ERROR: miscPtr not found.");
			}

			if ((sleepMarginPtr = vars.SleepMarginPtr = scanner.Scan(sleepMarginTrg)) != IntPtr.Zero)
			{
				int sleepMarginValue = game.ReadValue<int>(sleepMarginPtr);
				vars.Log("# sleepMarginPtr address: 0x" + sleepMarginPtr.ToString("X") + ", value: (int) " + sleepMarginValue);
			}
			else
			{
				scanErrorList.Add("ERROR: sleepMarginPtr not found.");
			}

			if (scanErrorList.Count == 0)
			{
				vars.TargetsFound = true;
				vars.Log("Found all targets. Enter a level to grab Frame Counter address..");

				var addrPool = new Dictionary<int, Tuple<double, int, int>>();
				var frameCandidates = new List<int>();

				int offset = 0x0;
				while (!token.IsCancellationRequested && !vars.FrameCountFound)
				{
					offset += 0x10;

					int address = vars.MiscSearchBase + offset;
					double value = game.ReadValue<double>((IntPtr) address);

					if (addrPool.Count < 512)
					{
						var tuple = Tuple.Create(value, 0, 0);
						addrPool.Add(address, tuple);
					}
					else if (addrPool.Count == 512)
					{
						vars.RunTime.Update(game);

						if (vars.RunTime.Current > vars.RunTime.Old)
						{
							vars.NewFrame = true;
						}

						double oldValue = addrPool[address].Item1;
						int increased = addrPool[address].Item2;
						int unchanged = addrPool[address].Item3;

						if (value.ToString().All(Char.IsDigit) && value > oldValue)
						{
							increased++;
							var tuple = Tuple.Create(value, increased, 0);
							addrPool[address] = tuple;

							if (increased > 30 && value < 300 && !vars.RoomActionList.Contains(current.RoomName) && !frameCandidates.Contains(address))
							{
								frameCandidates.Add(address);

								if (vars.PrintFrameCandidateChanges)
								{
									vars.Log("Added " + address.ToString("X") + " " + addrPool[address] + ". frameCandidates.Count = " + frameCandidates.Count);
								}
							}
						}
						else if (vars.NewFrame && value == oldValue && frameCandidates.Contains(address))
						{
							unchanged++;
							var tuple = Tuple.Create(value, increased, unchanged);
							addrPool[address] = tuple;

							vars.NewFrame = false;
						}

						if (!value.ToString().All(Char.IsDigit) || value < oldValue || unchanged > 5)
						{
							if (frameCandidates.Contains(address))
							{
								if (vars.PrintFrameCandidateChanges)
								{
									vars.Log("Removed " + address.ToString("X") + " " + addrPool[address] + ". frameCandidates.Count = " + (frameCandidates.Count - 1));
								}

								frameCandidates.Remove(address);
							}

							var tuple = Tuple.Create(value, 0, 0);
							addrPool[address] = tuple;
						}
					}

					if (offset == 0x2000) offset = 0x0;

					if (frameCandidates.Count >= 1)
					{
						for (int i = 0; i < frameCandidates.Count; i++)
						{
							int candidate = frameCandidates[i];
							if (addrPool[candidate].Item2 < 50) break;

							if (i == frameCandidates.Count - 1)
							{
								int frameCountAddr = frameCandidates.Max();
								double frameCountValue = game.ReadValue<double>((IntPtr) frameCountAddr);
								vars.Log("# Frame Counter address: 0x" + frameCountAddr.ToString("X") + ", value: (double) " + frameCountValue);

								vars.FrameCount = new MemoryWatcher<double>(new DeepPointer(frameCountAddr - gameBaseAddr));
								vars.FrameCountFound = true;
							}
						}
					}
				}

				break;
			}

			scanErrorList.ForEach(vars.Log);
			vars.Log("Target scan failed. Retrying..");
			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		string taskEndMessage = vars.FrameCountFound ? "Task completed successfully." : "Task was canceled.";
		vars.Log(taskEndMessage);
	});
}

update
{
	if (!vars.TargetsFound) return false;

	vars.SleepMargin();
	vars.RoomNum.Update(game);
	vars.RoomNamePtr.Update(game);
	vars.FrameCount.Update(game);

	if (vars.RoomNum.Changed)
	{
		int roomNameInt = game.ReadValue<int>((IntPtr) vars.RoomNamePtr.Current + (int) (4 * vars.RoomNum.Current));
		string roomName = game.ReadString((IntPtr) roomNameInt, 128);
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

// v0.2.5 11-Apr-2022