state("kuso") {}

startup
{
	vars.Log = (Action<dynamic>)(output => print("[LOVE 2: kuso] " + output));

	vars.PrintFrameChoiceChanges = false;
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
	vars.RoomActionList = new List<string>()
	{
		"room_startup",
		"room_titlescreen",
		"room_mainmenu",
		"room_gameselect",
		"room_levelsetselect",
		"room_levelselect",
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

	var roomRetryList = new List<string>()
	{
		"room_startup",
		"room_titlescreen"
	};

	var quotes = roomRetryList.Select(item => "\"" + item + "\"");
	string roomRetryLog = string.Join(", ", quotes.Take(quotes.Count() - 1)) + (quotes.Count() > 1 ? " or " : "") + quotes.LastOrDefault();

	vars.PointersFound = false;
	vars.FrameCountFound = false;

	vars.NewUpdateCycle = false;
	vars.CancelSource = new CancellationTokenSource();
	System.Threading.Tasks.Task.Run(async () =>
	{
		int gameBaseAddr = (int) game.MainModule.BaseAddress;

		vars.Log("Starting scan task.");
		vars.Log("# game.MainModule.BaseAddress: 0x" + gameBaseAddr.ToString("X"));

		var roomNumTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7");
		var roomNameTrg = new SigScanTarget(44, "C3 CC CC CC CC CC CC CC ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 8D 14 85 00 00 00 00 83 3C 0A 00 ?? ?? ?? ?? ?? ?? ?? 8B");
		var miscTrg = new SigScanTarget(2, "8B 35 ?? ?? ?? ?? 85 F6 75 10 B9");
		var sleepMarginTrg = new SigScanTarget(11, "8B ?? ?? ?? ?? ?? ?? 83 C4 0C A3 ?? ?? ?? ?? C6");

		foreach (var trg in new[] { roomNumTrg, roomNameTrg, miscTrg, sleepMarginTrg })
			trg.OnFound = (p, s, ptr) => p.ReadPointer(ptr);

		IntPtr roomNumPtr = IntPtr.Zero, roomNamePtr = IntPtr.Zero, miscPtr = IntPtr.Zero, sleepMarginPtr = IntPtr.Zero;

		var token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			var scanErrorList = new List<string>();
			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

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

				if (roomRetryList.Contains(current.RoomName))
				{
					scanErrorList.Add("ERROR: waiting for current.RoomName to not be " + roomRetryLog + ".");
				}
				else if (System.Text.RegularExpressions.Regex.IsMatch(current.RoomName, @"^\w{4,}$"))
				{
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
				vars.PointersFound = true;
				vars.Log("Found all pointers. Enter a level to grab Frame Counter address.");

				var addrPool = new Dictionary<int, Tuple<double, int, int>>();
				var frameCandidates = new List<int>();

				int offset = 0;
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

								if (vars.PrintFrameChoiceChanges)
								{
									vars.Log("Added " + address.ToString("X") + " " + addrPool[address] + ". frameCandidates.Count = " + frameCandidates.Count);
								}
							}
						}
						else if (vars.NewUpdateCycle && value == oldValue && frameCandidates.Contains(address))
						{
							unchanged++;
							var tuple = Tuple.Create(value, increased, unchanged);
							addrPool[address] = tuple;

							vars.NewUpdateCycle = false;
						}

						if (!value.ToString().All(Char.IsDigit) || value < oldValue || unchanged > 5)
						{
							if (frameCandidates.Contains(address))
							{
								if (vars.PrintFrameChoiceChanges)
								{
									vars.Log("Removed " + address.ToString("X") + " " + addrPool[address] + ". frameCandidates.Count = " + (frameCandidates.Count - 1));
								}

								frameCandidates.Remove(address);
							}

							var tuple = Tuple.Create(value, 0, 0);
							addrPool[address] = tuple;
						}
					}

					if (offset == 0x2000) offset = 0;

					if (frameCandidates.Count >= 3)
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
								vars.Log("All done.");
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

		vars.Log("Exiting scan task.");
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
			vars.Log("old.RoomName: \"" + old.RoomName + "\" -> current.RoomName: \"" + current.RoomName + "\"");
	}

	if (settings["SleepMargin"])
	{
		byte a = 0;

		if (settings["SleepMargin200"])     a = 200;
		else if (settings["SleepMargin80"]) a = 80;
		else if (settings["SleepMargin40"]) a = 40;
		else if (settings["SleepMargin10"]) a = 10;
		else if (settings["SleepMargin1"])  a = 1;

		if (a > 0 && a != game.ReadValue<int>((IntPtr) vars.SleepMarginPtr))
		{
			byte[] sleepMarginSetting = new byte[] { a, 0, 0, 0 };

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

	if (!vars.NewUpdateCycle) vars.NewUpdateCycle = true;
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

// v0.2.0 02-Apr-2022
