state("LOVE3") {}
state("LOVE3_Demo") {}

startup
{
	vars.Log = (Action<dynamic>)(output => print("[LOVE 3] " + output));

	vars.PrintFrameCandidateChanges = false;
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

	vars.PointersFound = false;
	vars.FrameCountFound = false;
	vars.NewFrame = false;

	vars.CancelSource = new CancellationTokenSource();
	System.Threading.Tasks.Task.Run(async () =>
	{
		int gameBaseAddr = (int) game.MainModule.BaseAddress;

		vars.Log("Starting scan task.");
		vars.Log("# game.MainModule.BaseAddress: 0x" + gameBaseAddr.ToString("X"));

		var runTimeTrg = new SigScanTarget(4, "CC 53 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 56 57 83 CF FF");
		var roomNumTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7");
		var roomNameTrg = new SigScanTarget(44, "C3 CC CC CC CC CC CC CC ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 8D 14 85 00 00 00 00 83 3C 0A 00 ?? ?? ?? ?? ?? ?? ?? 8B");
		var miscTrg = new SigScanTarget(2, "8B 35 ?? ?? ?? ?? 85 F6 75 10 B9");

		foreach (var trg in new[] { runTimeTrg, roomNumTrg, roomNameTrg, miscTrg })
		{
			trg.OnFound = (p, s, ptr) => p.ReadPointer(ptr);
		}

		IntPtr runTimePtr = IntPtr.Zero, roomNumPtr = IntPtr.Zero, roomNamePtr = IntPtr.Zero, miscPtr = IntPtr.Zero;

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
			}
			else
			{
				scanErrorList.Add("ERROR: miscPtr not found.");
			}

			if (scanErrorList.Count == 0)
			{
				vars.PointersFound = true;
				vars.Log("Found all pointers. Enter a level to grab Frame Counter address.");

				var addrPool = new Dictionary<int, Tuple<double, int, int>>();
				var frameCandidates = new List<int>();

				int offset = 0x00;
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

							if (increased > 30 && !vars.RoomActionList.Contains(current.RoomName) && !frameCandidates.Contains(address))
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

					if (offset == 0x2000) offset = 0x00;

					if (frameCandidates.Count >= 2)
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
			vars.Log("Scan failed. Retrying.");
			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		string taskEndMessage = vars.FrameCountFound ? "Task completed successfully." : "Task was canceled.";
		vars.Log(taskEndMessage);
	});
}

update
{
	if (!vars.PointersFound) return false;

	vars.RoomNum.Update(game);
	vars.RoomNamePtr.Update(game);
	vars.FrameCount.Update(game);

	if (vars.RoomNum.Changed)
	{
		int roomNameInt = game.ReadValue<int>((IntPtr) vars.RoomNamePtr.Current + (int) (4 * vars.RoomNum.Current));
		string roomName = game.ReadString((IntPtr) roomNameInt, 128);
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

// v0.2.2 09-Apr-2022
