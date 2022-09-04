state("kuso") {}

startup
{
	vars.Log = (Action<object>)(output => print("   [LOVE 2: kuso " + vars.Version + "]   " + output));

	if (timer.CurrentTimingMethod == TimingMethod.RealTime)
	{
		var timingMessage = MessageBox.Show(
			"Change timing method to Game Time?\nIt keeps LiveSplit in sync with the game's frame counter.",
			"LiveSplit | LOVE 2: kuso",
			MessageBoxButtons.YesNo,
			MessageBoxIcon.Question,
			MessageBoxDefaultButton.Button1,
			(MessageBoxOptions)0x40000);

		if (timingMessage == DialogResult.Yes)
		{
			timer.CurrentTimingMethod = TimingMethod.GameTime;
		}
	}
}

init
{
	vars.TaskSuccessful = false;

	var roomNumTrg = new SigScanTarget(7, "CC CC CC 8B D1 8B 0D ?? ?? ?? ?? E9 ?? ?? ?? ?? CC");
	var roomBaseTrg = new SigScanTarget(16, "FF C8 48 63 D0 48 63 D9 48 3B D3 7C 18 48 8B 0D");
	var framePageTrg = new SigScanTarget(4, "C3 48 8B 15 ?? ?? ?? ?? 48 85 D2 0F 85");
	var frameVarTrg = new SigScanTarget(0, "70 6C 61 79 65 72 46 72 61 6D 65 73 00 78 78 78 70 6C 61 79 65 72 46 72 61 6D 65 73 00 78 78 78"); // playerFrames

	var tempUnpatchedTrg = new SigScanTarget(0, "FF 15 9C 51 6A 00 8B E8 33 C0");
	var tempPatchedTrg = new SigScanTarget(0, "89 07 E9 58 01 00 00 90");
	var sleepMarginTrg = new SigScanTarget(11, "8B ?? ?? ?? ?? ?? ?? 83 C4 0C A3 ?? ?? ?? ?? C6");

	sleepMarginTrg.OnFound = (p, s, ptr) => p.ReadPointer(ptr);

	if (game.MainModule.ModuleMemorySize == 6680576 && !game.Is64Bit())
	{
		vars.Version = "Demo";
		vars.Bytes = 0x4;

		vars.RoomBasePtr = 0x7C9668;
		vars.RoomNumPtr = 0x9CB860;
	}
	else if (game.Is64Bit())
	{
		vars.Version = "Full";
		vars.Bytes = 0x8;

		foreach (var target in new SigScanTarget[] { roomNumTrg, roomBaseTrg, framePageTrg })
		{
			target.OnFound = (p, s, ptr) => ptr + 0x4 + p.ReadValue<int>(ptr);
		}
	}
	else
	{
		vars.Version = "Unknown";
		vars.Log("Only 32-bit demo and 64-bit full game versions are supported. Stopping.");
		goto skip;
	}

	vars.RoomName = (Action)(() =>
	{
		try
		{
			string name = new DeepPointer(game.ReadPointer((IntPtr)vars.RoomBasePtr) + (game.ReadValue<int>((IntPtr)vars.RoomNumPtr) * vars.Bytes), 0x0).DerefString(game, 128);

			if (System.Text.RegularExpressions.Regex.IsMatch(name, @"^\w{4,}$"))
			{
				current.RoomName = name.ToLower();
			}
		}
		catch
		{
		}
	});

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
		"room_2p_start",
		"room_2p_select",
		"room_2p_results",
		"room_loadgame",
		"room_about"
	};

	vars.SubtractFrames = 0;
	vars.SubtractFramesCache = 0;

	vars.CancelSource = new CancellationTokenSource();
	System.Threading.Tasks.Task.Run(async () =>
	{
		vars.Log("Task started. Target scanning..");

		var token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

			if (vars.Version == "Full")
			{
				IntPtr roomNumPtr = vars.RoomNumPtr = scanner.Scan(roomNumTrg);
				IntPtr roomBasePtr = vars.RoomBasePtr = scanner.Scan(roomBaseTrg);
				IntPtr framePagePtr = vars.FramePagePtr = scanner.Scan(framePageTrg);

				vars.Names = new String[] { "roomNumPtr", "roomBasePtr", "framePagePtr" };
				vars.Results = new IntPtr[] { roomNumPtr, roomBasePtr, framePagePtr };
			}
			else if (vars.Version == "Demo")
			{
				IntPtr tempUnpatched = vars.TempUnpatched = scanner.Scan(tempUnpatchedTrg);
				IntPtr tempPatched = vars.TempPatched = scanner.Scan(tempPatchedTrg);
				IntPtr sleepMarginPtr = vars.SleepMarginPtr = scanner.Scan(sleepMarginTrg);

				vars.Names = new String[] { "tempUnpatched", "tempPatched", "sleepMarginPtr" };
				vars.Results = new IntPtr[] { tempUnpatched, tempPatched, sleepMarginPtr };
			}

			int index = 0;
			int found = 0;
			foreach (IntPtr result in vars.Results)
			{
				if (result != IntPtr.Zero)
				{
					found++;
					vars.Log((index + 1) + ". " + vars.Names[index] + ": [0x" + result.ToString("X") + "] -> 0x" + game.ReadPointer(result).ToString("X"));
				}
				else
				{
					vars.Log((index + 1) + ". " + vars.Names[index] + ": not found");
				}

				index++;
			}

			if ((vars.Version == "Full" && found == 3) || (vars.Version == "Demo" && (vars.TempUnpatched != IntPtr.Zero || vars.TempPatched != IntPtr.Zero) && vars.SleepMarginPtr != IntPtr.Zero))
			{
				current.RoomName = "";
				vars.RoomName();
				vars.Log("current.RoomName: \"" + current.RoomName + "\"");

				if (current.RoomName == "")
				{
					vars.Log("ERROR: invalid current.RoomName");
				}
				else
				{
					if (vars.Version == "Full")
					{
						vars.Log("Scanning for Frame Counter address..");
						break;
					}
					else if (vars.Version == "Demo")
					{
						vars.Log("Patching game..");

						byte[] tempPatch = new byte[] { 0xE9, 0x58, 0x01, 0x00, 0x00, 0x90 };
						byte[] sleepMarginPatch = new byte[] { 0xC8, 0x00, 0x00, 0x00 };

						try
						{
							game.Suspend();
							game.WriteBytes((IntPtr)vars.TempUnpatched, tempPatch); // when exiting the game, it tries to delete your %temp% folder. this patches that bug.
							game.WriteBytes((IntPtr)vars.SleepMarginPtr, sleepMarginPatch); // makes the game run at full 60fps.
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

						if (game.ReadValue<int>((IntPtr)vars.SleepMarginPtr) != 0xC8)
						{
							vars.Log("ERROR: Patching failed.");
						}
						else
						{
							vars.RoomNum = new MemoryWatcher<int>((IntPtr)0x9CB860);
							vars.FrameCount = new MemoryWatcher<double>(new DeepPointer((IntPtr)0x7C9730, 0x34, 0x10, 0x88, 0x10));

							vars.Log("Task completed successfully.");
							vars.TaskSuccessful = true;
							goto end;
						}
					}
				}
			}

			vars.Log("Retrying..");
			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		while (!token.IsCancellationRequested)
		{
			IntPtr frameVarAddress = IntPtr.Zero;
			vars.FramePageBase = 0;
			int framePage = game.ReadValue<int>((IntPtr)vars.FramePagePtr);

			foreach (var page in game.MemoryPages(false))
			{
				long start = (long)page.BaseAddress;
				int size = (int)page.RegionSize;
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
					var scanner = new SignatureScanner(game, page.BaseAddress, (int)page.RegionSize);
					var toBytes = BitConverter.GetBytes((int)frameVarAddress);
					var toString = BitConverter.ToString(toBytes).Replace("-", " ");
					var target = new SigScanTarget(0, "00 00 00 00", toString, "00 00 00 00");
					var pointers = scanner.ScanAll(target);

					foreach (IntPtr pointer in pointers)
					{
						int frameIdentifier = game.ReadValue<int>(pointer - 0x4);

						if (frameIdentifier <= 0x186A0) continue;

						var toBytes_ = BitConverter.GetBytes(frameIdentifier);
						var toString_ = BitConverter.ToString(toBytes_).Replace("-", " ");
						var target_ = new SigScanTarget(0, "00 00 00 00", toString_);

						foreach (var page_ in game.MemoryPages(false))
						{
							var scanner_ = new SignatureScanner(game, page_.BaseAddress, (int)page_.RegionSize);
							var pointers_ = scanner_.ScanAll(target_);

							foreach (IntPtr pointer_ in pointers_)
							{
								int frameCountAddress = game.ReadValue<int>(pointer_ - 0x4);
								double frameCount = game.ReadValue<double>((IntPtr)frameCountAddress);

								if (frameCountAddress >= vars.FramePageBase && frameCountAddress <= vars.FramePageEnd && frameCount.ToString().All(Char.IsDigit))
								{
									vars.RoomName();

									vars.RoomNum = new MemoryWatcher<int>(vars.RoomNumPtr);
									vars.FrameCount = new MemoryWatcher<double>((IntPtr)frameCountAddress);

									vars.Log("frameCountAddress: [0x" + frameCountAddress.ToString("X") + "] -> " + frameCount);
									vars.Log("Task completed successfully.");
									vars.TaskSuccessful = true;

									goto end;
								}
							}
						}
					}
				}
			}

			await System.Threading.Tasks.Task.Delay(1000, token);
		}

		end:;
	});

	skip:;
}

update
{
	if (!vars.TaskSuccessful) return false;

	vars.RoomNum.Update(game);
	vars.FrameCount.Update(game);

	if (vars.RoomNum.Changed)
	{
		vars.RoomName();

		if (current.RoomName != old.RoomName)
		{
			vars.Log("current.RoomName: \"" + old.RoomName + "\" -> \"" + current.RoomName + "\"");

			if (old.RoomName == "room_levelselect")
			{
				vars.SubtractFrames = vars.SubtractFramesCache;
			}
		}
	}

	if (vars.Version == "Demo")
	{
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
}

start
{
	return !vars.RoomActionList.Contains(current.RoomName) && vars.FrameCount.Current == vars.FrameCount.Old + 1;
}

split
{
	return vars.RoomNum.Changed && vars.FrameCount.Current > 90;
}

reset
{
	return vars.FrameCount.Current < vars.FrameCount.Old ||
	       vars.RoomActionList.Contains(current.RoomName) && (vars.Version == "Full" || (vars.Version == "Demo" && current.RoomName != "room_levelselect")) ||
	       vars.Version == "Demo" && current.RoomName != old.RoomName && old.RoomName == "room_levelselect";
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

// v0.4.4 04-Sep-2022
