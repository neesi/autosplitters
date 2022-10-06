state("Love") {}

startup
{
	vars.FastVariableScan = true;
	vars.Log = (Action<object>)(output => print("   [" + vars.GameExe + "]   " + output));
	settings.Add("gameTime", true, "Automatically change timing method to Game Time");

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
}

init
{
	try
	{
		vars.GameExe = modules.First().ToString();
		if (!vars.GameExe.EndsWith(".exe"))
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

	vars.CancelSource = new CancellationTokenSource();
	System.Threading.Tasks.Task.Run(async () =>
	{
		CancellationToken token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			if (exeSize == 4917760 && dataSize == 46275241 && !is64bit)
			{
				// itch.io bundles do not come with keys and the current game version on itch is very old.

				vars.Version = "LOVE itch";

				vars.RoomNum = 0xAA46A0;
				vars.RoomBase = 0x8942A4;
				vars.SleepMargin = 0x7EA048;

				vars.RoomNumber = new MemoryWatcher<int>((IntPtr)vars.RoomNum);
				vars.FrameCount = new MemoryWatcher<double>(new DeepPointer((IntPtr)0x8943CC, 0x2C, 0x10, 0xA74, 0x320));
			}
			else if (!is64bit)
			{
				vars.Version = "LOVE";

				vars.PointerTargets = new List<KeyValuePair<string, SigScanTarget>>()
				{
					new KeyValuePair<string, SigScanTarget>("RoomNumTrg", new SigScanTarget(8, "56 E8 ?? ?? ?? ?? 8B 0D ?? ?? ?? ?? 83 C4 08 A1 ?? ?? ?? ?? 5F 5E 5B")),
					new KeyValuePair<string, SigScanTarget>("RoomBaseTrg", new SigScanTarget(10, "7E ?? 8B 2D ?? ?? ?? ?? 8B 3D ?? ?? ?? ?? 2B EF")),
					new KeyValuePair<string, SigScanTarget>("VarPageAddrTrg", new SigScanTarget(3, "33 F6 A1 ?? ?? ?? ?? B9 ?? ?? ?? ?? 89 06 A1"))
				};

				foreach (var target in vars.PointerTargets)
				{
					SigScanTarget trg = target.Value;
					trg.OnFound = (p, s, addr) => p.ReadPointer(addr);
				}
			}
			else if (is64bit)
			{
				// this version doesn't exist, but the signatures work for 64-bit versions of LOVE 2: kuso and LOVE 3, so this might work if there ever is a 64-bit LOVE.

				vars.Version = "LOVE";

				vars.PointerTargets = new List<KeyValuePair<string, SigScanTarget>>()
				{
					new KeyValuePair<string, SigScanTarget>("RoomNumTrg", new SigScanTarget(7, "CC CC CC 8B D1 8B 0D ?? ?? ?? ?? E9 ?? ?? ?? ?? CC")),
					new KeyValuePair<string, SigScanTarget>("RoomBaseTrg", new SigScanTarget(16, "FF C8 48 63 D0 48 63 D9 48 3B D3 7C 18 48 8B 0D")),
					new KeyValuePair<string, SigScanTarget>("VarPageAddrTrg", new SigScanTarget(4, "C3 48 8B 15 ?? ?? ?? ?? 48 85 D2 0F 85"))
				};

				foreach (var target in vars.PointerTargets)
				{
					SigScanTarget trg = target.Value;
					trg.OnFound = (p, s, addr) => addr + 0x4 + p.ReadValue<int>(addr);
				}
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

			if (vars.Version == "LOVE itch")
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
					vars.Log("Patching game..");

					byte[] sleepMarginPatch = new byte[] { 0xC8, 0x00, 0x00, 0x00 };

					try
					{
						game.Suspend();
						game.WriteBytes((IntPtr)vars.SleepMargin, sleepMarginPatch); // makes the game run at full 60fps.
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
			else if (vars.Version == "LOVE")
			{
				vars.Log("Scanning for pointers..");
				break;
			}

			vars.Log("Retrying..");
			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		while (!token.IsCancellationRequested)
		{
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
				vars.RoomNum = pointerTargetsFound.First(f => f.Key == "RoomNumTrg").Value;
				vars.RoomBase = pointerTargetsFound.First(f => f.Key == "RoomBaseTrg").Value;
				vars.VarPageAddr = pointerTargetsFound.First(f => f.Key == "VarPageAddrTrg").Value;

				current.RoomName = "";
				vars.RoomName();
				vars.Log("current.RoomName: \"" + current.RoomName + "\"");

				if (current.RoomName == "")
				{
					vars.Log("ERROR: invalid current.RoomName");
				}
				else
				{
					vars.Log("Scanning for variable addresses..");
					break;
				}
			}

			vars.Log("Retrying..");
			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		while (!token.IsCancellationRequested)
		{
			var variableTargets = new List<KeyValuePair<string, SigScanTarget>>()
			{
				// target is a string, which contains the game's variable name for things like frame counter, checkpoint count, ...
				// it should be 32 bytes, for example: "playerTimer.xxxxplayerTimer.xxxx" (. is 0x00, not ".")

				//new KeyValuePair<string, SigScanTarget>("playerSpawns", new SigScanTarget(0, "70 6C 61 79 65 72 53 70 61 77 6E 73 00 78 78 78 70 6C 61 79 65 72 53 70 61 77 6E 73 00 78 78 78")),
				new KeyValuePair<string, SigScanTarget>("playerTimer", new SigScanTarget(0, "70 6C 61 79 65 72 54 69 6D 65 72 00 78 78 78 78 70 6C 61 79 65 72 54 69 6D 65 72 00 78 78 78 78"))
			};

			var variableTargetsFound = new List<KeyValuePair<string, IntPtr>>();
			var variableAddressesFound = new List<KeyValuePair<string, IntPtr>>();
			int uniqueVariablesFound = 0;

			long variablePageAddress = (long)game.ReadPointer((IntPtr)vars.VarPageAddr);
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
						vars.Log(target.Key + " string: 0x" + result.ToString("X"));
					}
				}

				if (variablePageAddress >= start && variablePageAddress <= end)
				{
					// variablePageAddress is always in the same page as frame counter etc. addresses.

					variablePageBase = start;
					variablePageEnd = end;
				}
			}

			if (variableTargetsFound.Count == variableTargets.Count && variablePageBase > 0)
			{
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
						var target = new SigScanTarget(0, pad, toString, pad);
						IEnumerable<IntPtr> pointers = scanner.ScanAll(target);

						foreach (IntPtr pointer in pointers)
						{
							int variableIdentifier = game.ReadValue<int>(pointer - 0x4);
							if (variableIdentifier <= 0x186A0)
							{
								continue;
							}

							byte[] toBytes_ = BitConverter.GetBytes(variableIdentifier);
							string toString_ = BitConverter.ToString(toBytes_).Replace("-", " ");
							var target_ = new SigScanTarget(0, pad, toString_);

							foreach (var page_ in game.MemoryPages())
							{
								// scan for instances of the supposed variable identifier.

								var scanner_ = new SignatureScanner(game, page_.BaseAddress, (int)page_.RegionSize);
								IEnumerable<IntPtr> results = scanner_.ScanAll(target_);

								foreach (IntPtr result in results)
								{
									// if (result - 0x4) points to an address that is in the same page as variablePageAddress, it is likely the variable address.

									long variableAddress = (long)game.ReadPointer(result - 0x4);
									var element = new KeyValuePair<string, IntPtr>(variable.Key, (IntPtr)variableAddress);

									if ((variableAddress >= variablePageBase && variableAddress <= variablePageEnd) && !variableAddressesFound.Contains(element))
									{
										variableAddressesFound.Add(element);

										double value = game.ReadValue<double>((IntPtr)variableAddress);
										if (value.ToString().All(Char.IsDigit))
										{
											vars.Log(variable.Key + " address: [0x" + variableAddress.ToString("X") + "] -> <double>" + value);
										}
										else
										{
											var ptr = game.ReadPointer((IntPtr)variableAddress);
											vars.Log(variable.Key + " address: [0x" + variableAddress.ToString("X") + "] -> 0x" + ptr);
										}

										uniqueVariablesFound = variableAddressesFound.GroupBy(f => f.Key).Distinct().Count();
										if (vars.FastVariableScan && uniqueVariablesFound == variableTargets.Count)
										{
											goto scan_completed;
										}
										else if (vars.FastVariableScan && variableAddressesFound.Any(f => f.Key == variable.Key))
										{
											goto next_variable;
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
					bool done = false;

					foreach (var variable in variableAddressesFound)
					{
						string name = variable.Key;
						IntPtr address = variable.Value;
						double value = game.ReadValue<double>(address);

						if (name == "playerTimer" && value.ToString().All(Char.IsDigit))
						{
							vars.RoomNumber = new MemoryWatcher<int>(vars.RoomNum);
							vars.FrameCount = new MemoryWatcher<double>(address);

							vars.RoomName();
							done = true;
						}
					}

					if (done)
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

			vars.Log("Retrying..");
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

// v0.4.7 06-Oct-2022
