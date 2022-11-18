state("kuso") {}

startup
{
	vars.FastVariableScan = true;
	vars.Log = (Action<object>)(output => print("   [" + vars.GameExe + "]   " + output));
	settings.Add("gameTime", true, "Automatically change timing method to Game Time");

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
		"room_2p_select"
	};
}

init
{
	try
	{
		vars.GameExe = modules.First().ToString();
		if (!vars.GameExe.ToLower().EndsWith(".exe"))
		{
			throw new Exception("Game not loaded yet.");
		}
	}
	catch
	{
		throw;
	}

	bool is64bit = game.Is64Bit();
	int bytes = is64bit ? 0x8 : 0x4;
	string pad = is64bit ? "00 00 00 00" : "";

	string exePath = modules.First().FileName;
	string dataPath = new FileInfo(exePath).DirectoryName + "\\data.win";

	long exeSize = new FileInfo(exePath).Length;
	long dataSize = new FileInfo(dataPath).Length;
	long exeMemorySize = modules.First().ModuleMemorySize;

	vars.Log("\"" + exePath + "\", exeSize: " + exeSize + ", dataSize: " + dataSize + ", exeMemorySize: " + exeMemorySize + ", 64-bit: " + is64bit);

	vars.Done = false;
	vars.SubtractFrames = 0;
	vars.SubtractFramesCache = 0;

	vars.CancelSource = new CancellationTokenSource();
	System.Threading.Tasks.Task.Run(async () =>
	{
		CancellationToken token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			vars.Log("Checking game version..");

			if (exeSize == 4270592 && !is64bit)
			{
				vars.Version = "Demo";

				vars.RoomNum = 0x9CB860;
				vars.RoomBase = 0x7C9668;
				vars.SleepMargin = 0x77E398;
				vars.TempBug = 0x4A5FF0;

				vars.RoomNumber = new MemoryWatcher<int>((IntPtr)vars.RoomNum);
				vars.FrameCount = new MemoryWatcher<double>(new DeepPointer((IntPtr)0x7C9730, 0x34, 0x10, 0x88, 0x10));
			}
			else if (exeSize == 5178368 && dataSize == 133467400 && !is64bit)
			{
				// itch.io bundles do not come with keys and the current game version on itch is very outdated.

				vars.Version = "Full itch";

				vars.RoomNum = 0xAC2DB8;
				vars.RoomBase = 0x8B2774;
				vars.SleepMargin = 0x7FF088;

				vars.RoomNumber = new MemoryWatcher<int>((IntPtr)vars.RoomNum);
				vars.FrameCount = new MemoryWatcher<double>(new DeepPointer((IntPtr)0x8B2780, 0x2C, 0x10, 0x48C, 0x700));
			}
			else if (is64bit)
			{
				vars.Version = "Full";

				vars.PointerTargets = new List<KeyValuePair<string, SigScanTarget>>()
				{
					new KeyValuePair<string, SigScanTarget>("RoomNum", new SigScanTarget(7, "CC CC CC 8B D1 8B 0D ?? ?? ?? ?? E9 ?? ?? ?? ?? CC")),
					new KeyValuePair<string, SigScanTarget>("RoomBase", new SigScanTarget(16, "FF C8 48 63 D0 48 63 D9 48 3B D3 7C 18 48 8B 0D")),
					new KeyValuePair<string, SigScanTarget>("VariablePage", new SigScanTarget(4, "C3 48 8B 15 ?? ?? ?? ?? 48 85 D2 0F 85"))
				};

				foreach (var target in vars.PointerTargets)
				{
					SigScanTarget trg = target.Value;
					trg.OnFound = (p, s, addr) => addr + 0x4 + p.ReadValue<int>(addr);
				}
			}
			else
			{
				vars.Log("Unsupported game version. Stopping.");
				goto task_end;
			}

			vars.RoomName = (Action)(() =>
			{
				try
				{
					string name = new DeepPointer(game.ReadPointer((IntPtr)vars.RoomBase) + (game.ReadValue<int>((IntPtr)vars.RoomNum) * bytes), 0x0).DerefString(game, 128);
					if (System.Text.RegularExpressions.Regex.IsMatch(name, @"^\w{4,}$"))
					{
						current.RoomName = name.ToLower();
					}
				}
				catch
				{
				}
			});

			if (vars.Version == "Demo" || vars.Version == "Full itch")
			{
				current.RoomName = "";
				vars.RoomName();
				vars.Log("current.RoomName: \"" + current.RoomName + "\"");

				if (current.RoomName == "")
				{
					vars.Log("Invalid current.RoomName");
				}
				else
				{
					vars.Log("Patching game..");

					var sleepMarginPatch = new byte[] { 0xC8, 0x00, 0x00, 0x00 };
					var tempPatch = new byte[] { 0xE9, 0x58, 0x01, 0x00, 0x00, 0x90 };

					try
					{
						game.Suspend();

						// makes the game run at full 60fps regardless of your display refresh rate or windows version.
						game.WriteBytes((IntPtr)vars.SleepMargin, sleepMarginPatch);

						if (vars.Version == "Demo")
						{
							// stops the game from attempting to delete your %temp% folder. more info: https://github.com/neesi/autosplitters/tree/main/LOVE_2_kuso
							game.WriteBytes((IntPtr)vars.TempBug, tempPatch);
						}
					}
					finally
					{
						game.Resume();
					}

					if (settings["gameTime"])
					{
						timer.CurrentTimingMethod = TimingMethod.GameTime;
					}

					vars.Log("All done.");
					vars.Done = true;
					goto task_end;
				}
			}
			else if (vars.Version == "Full")
			{
				break;
			}

			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		while (!token.IsCancellationRequested)
		{
			vars.Log("Scanning for pointers..");

			var scanner = new SignatureScanner(game, modules.First().BaseAddress, modules.First().ModuleMemorySize);
			var pointerTargetsFound = new List<KeyValuePair<string, IntPtr>>();

			foreach (var target in vars.PointerTargets)
			{
				IntPtr result = scanner.Scan(target.Value);
				if (result != IntPtr.Zero)
				{
					pointerTargetsFound.Add(new KeyValuePair<string, IntPtr>(target.Key, result));
					vars.Log(target.Key + ": [0x" + result.ToString("X") + "] -> 0x" + game.ReadPointer(result).ToString("X"));
				}
				else
				{
					vars.Log(target.Key + ": not found");
				}
			}

			if (pointerTargetsFound.Count == vars.PointerTargets.Count)
			{
				vars.RoomNum = pointerTargetsFound.FirstOrDefault(f => f.Key == "RoomNum").Value;
				vars.RoomBase = pointerTargetsFound.FirstOrDefault(f => f.Key == "RoomBase").Value;
				vars.VariablePage = pointerTargetsFound.FirstOrDefault(f => f.Key == "VariablePage").Value;

				current.RoomName = "";
				vars.RoomName();
				vars.Log("current.RoomName: \"" + current.RoomName + "\"");

				if (current.RoomName == "")
				{
					vars.Log("Invalid current.RoomName");
				}
				else
				{
					break;
				}
			}

			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		while (!token.IsCancellationRequested)
		{
			vars.Log("Scanning for variable targets..");

			var variableTargets = new List<KeyValuePair<string, SigScanTarget>>()
			{
				// target is a string, which contains the game's variable name for things like frame counter, checkpoint count, ...
				// it should be 32 bytes, for example: "playerFrames.xxxplayerFrames.xxx" (. is 0x00, not ".")

				//new KeyValuePair<string, SigScanTarget>("playerSpawns", new SigScanTarget(0, "70 6C 61 79 65 72 53 70 61 77 6E 73 00 78 78 78 70 6C 61 79 65 72 53 70 61 77 6E 73 00 78 78 78")),
				new KeyValuePair<string, SigScanTarget>("playerFrames", new SigScanTarget(0, "70 6C 61 79 65 72 46 72 61 6D 65 73 00 78 78 78 70 6C 61 79 65 72 46 72 61 6D 65 73 00 78 78 78"))
			};

			var variableTargetsFound = new List<KeyValuePair<string, IntPtr>>();
			var variableAddressesFound = new List<KeyValuePair<string, IntPtr>>();
			int uniqueVariablesFound = 0;

			long variablePageAddress = (long)game.ReadPointer((IntPtr)vars.VariablePage);
			long variablePageBase = 0;
			long variablePageEnd = 0;

			foreach (var page in game.MemoryPages())
			{
				long start = (long)page.BaseAddress;
				int size = (int)page.RegionSize;
				long end = start + size;

				var scanner = new SignatureScanner(game, page.BaseAddress, (int)page.RegionSize);
				foreach (var target in variableTargets)
				{
					if (variableTargetsFound.Any(f => f.Key == target.Key))
					{
						continue;
					}

					IntPtr result = scanner.Scan(target.Value);
					if (result != IntPtr.Zero)
					{
						variableTargetsFound.Add(new KeyValuePair<string, IntPtr>(target.Key, result));
						vars.Log(target.Key + " target: 0x" + result.ToString("X"));
					}
				}

				if (variablePageAddress >= start && variablePageAddress <= end)
				{
					// variablePageAddress is always in the same page as frame counter etc. addresses.

					variablePageBase = start;
					variablePageEnd = end;
				}
			}

			vars.Log("variableTargetsFound: " + variableTargetsFound.Count + "/" + variableTargets.Count);
			vars.Log("variablePageBase: 0x" + variablePageBase.ToString("X") + ", variablePageEnd: 0x" + variablePageEnd.ToString("X"));

			if (variableTargetsFound.Count == variableTargets.Count && variableTargets.Count > 0 && variablePageBase > 0)
			{
				vars.Log("Scanning for variable addresses..");

				foreach (var page in game.MemoryPages())
				{
					var scanner = new SignatureScanner(game, page.BaseAddress, (int)page.RegionSize);
					foreach (var variable in variableTargetsFound)
					{
						if (vars.FastVariableScan && variableAddressesFound.Any(f => f.Key == variable.Key))
						{
							continue;
						}

						// scan for pointers to variable string address.

						byte[] toBytes = BitConverter.GetBytes((int)variable.Value);
						string toString = BitConverter.ToString(toBytes).Replace("-", " ");
						var target = new SigScanTarget(-4, pad, toString, pad);
						IEnumerable<IntPtr> pointers = scanner.ScanAll(target);

						foreach (IntPtr pointer in pointers)
						{
							int variableIdentifier = game.ReadValue<int>(pointer);
							if (variableIdentifier <= 0x186A0)
							{
								continue;
							}

							byte[] toBytes_ = BitConverter.GetBytes(variableIdentifier);
							string toString_ = BitConverter.ToString(toBytes_).Replace("-", " ");
							var target_ = new SigScanTarget(-4, pad, toString_);

							foreach (var page_ in game.MemoryPages())
							{
								// scan for instances of the supposed variable identifier.

								var scanner_ = new SignatureScanner(game, page_.BaseAddress, (int)page_.RegionSize);
								IEnumerable<IntPtr> results = scanner_.ScanAll(target_);

								foreach (IntPtr result in results)
								{
									// if result points to an address that is in the same page as variablePageAddress, it is likely the variable address.

									long variableAddress = (long)game.ReadPointer(result);
									var element = new KeyValuePair<string, IntPtr>(variable.Key, (IntPtr)variableAddress);

									if ((variableAddress >= variablePageBase && variableAddress <= variablePageEnd) && !variableAddressesFound.Contains(element))
									{
										double value = game.ReadValue<double>((IntPtr)variableAddress);
										if (value.ToString().All(Char.IsDigit))
										{
											vars.Log(variable.Key + " address: [0x" + variableAddress.ToString("X") + "] -> <double>" + value);
										}
										else
										{
											IntPtr ptr = game.ReadPointer((IntPtr)variableAddress);
											vars.Log(variable.Key + " address: [0x" + variableAddress.ToString("X") + "] -> 0x" + ptr.ToString("X"));
										}

										if (uniqueVariablesFound < variableTargets.Count)
										{
											variableAddressesFound.Add(element);
											uniqueVariablesFound = variableAddressesFound.GroupBy(f => f.Key).Distinct().Count();
										}

										if (vars.FastVariableScan)
										{
											if (uniqueVariablesFound == variableTargets.Count)
											{
												goto scan_completed;
											}
											else
											{
												goto next_variable;
											}
										}
									}
								}
							}
						}

						next_variable:;
					}
				}

				scan_completed:;

				if (uniqueVariablesFound == variableTargets.Count)
				{
					int found = 0;
					foreach (var variable in variableAddressesFound)
					{
						string name = variable.Key;
						IntPtr address = variable.Value;

						if (name == "playerFrames")
						{
							double value = game.ReadValue<double>(address);
							if (value.ToString().All(Char.IsDigit))
							{
								vars.RoomNumber = new MemoryWatcher<int>(vars.RoomNum);
								vars.FrameCount = new MemoryWatcher<double>(address);
								vars.RoomName();
							}
							else
							{
								break;
							}
						}

						found++;
					}

					if (found == uniqueVariablesFound)
					{
						if (settings["gameTime"])
						{
							timer.CurrentTimingMethod = TimingMethod.GameTime;
						}

						vars.Log("All done.");
						vars.Done = true;
						goto task_end;
					}
				}
			}

			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		task_end:;
	});
}

update
{
	if (!vars.Done)
	{
		return false;
	}

	vars.RoomNumber.Update(game);
	vars.FrameCount.Update(game);

	if (vars.RoomNumber.Changed)
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
	return vars.RoomNumber.Changed && vars.FrameCount.Current > 90;
}

reset
{
	return vars.FrameCount.Current < vars.FrameCount.Old ||
	       vars.RoomActionList.Contains(current.RoomName) && (vars.Version.Contains("Full") || (vars.Version == "Demo" && current.RoomName != "room_levelselect")) ||
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

// v0.5.5 18-Nov-2022
