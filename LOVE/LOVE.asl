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
		"levelselect_room",
		"flap_start_room",
		"flap_play_room"
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

	vars.Ready = false;

	bool is64bit = game.Is64Bit();
	int bytes = is64bit ? 0x8 : 0x4;
	string pad = is64bit ? "00 00 00 00" : "";

	string exePath = modules.First().FileName;
	string dataPath = new FileInfo(exePath).DirectoryName + "\\data.win";

	long exeSize = new FileInfo(exePath).Length;
	long dataSize = new FileInfo(dataPath).Length;
	long exeMemorySize = modules.First().ModuleMemorySize;

	vars.Log("\"" + exePath + "\", exeSize: " + exeSize + ", dataSize: " + dataSize + ", exeMemorySize: " + exeMemorySize + ", 64-bit: " + is64bit);

	vars.CancelSource = new CancellationTokenSource();
	System.Threading.Tasks.Task.Run(async () =>
	{
		vars.Log("Checking game version..");

		if (exeSize == 4917760 && dataSize == 46275241 && !is64bit)
		{
			// itch.io bundles do not come with keys and the current game version on itch is very outdated.

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
				new KeyValuePair<string, SigScanTarget>("RoomNum", new SigScanTarget(8, "56 E8 ?? ?? ?? ?? 8B 0D ?? ?? ?? ?? 83 C4 08 A1 ?? ?? ?? ?? 5F 5E 5B")),
				new KeyValuePair<string, SigScanTarget>("RoomBase", new SigScanTarget(10, "7E ?? 8B 2D ?? ?? ?? ?? 8B 3D ?? ?? ?? ?? 2B EF")),
				new KeyValuePair<string, SigScanTarget>("VariablePage", new SigScanTarget(3, "33 F6 A1 ?? ?? ?? ?? B9 ?? ?? ?? ?? 89 06 A1"))
			};

			foreach (var target in vars.PointerTargets)
			{
				SigScanTarget trg = target.Value;
				trg.OnFound = (p, s, addr) => p.ReadPointer(addr);
			}
		}
		else if (is64bit)
		{
			// 64-bit LOVE doesn't exist, but the signatures work for 64-bit versions of LOVE 2: kuso and LOVE 3, so this might work if there ever is a 64-bit LOVE.

			vars.Version = "LOVE";

			vars.PointerTargets = new List<KeyValuePair<string, SigScanTarget>>()
			{
				new KeyValuePair<string, SigScanTarget>("RoomNum", new SigScanTarget(7, "CC CC CC 8B D1 8B 0D ?? ?? ?? ?? E9 ?? ?? ?? ?? CC")),
				new KeyValuePair<string, SigScanTarget>("RoomBase", new SigScanTarget(20, "48 ?? ?? ?? ?? 89 35 ?? ?? ?? ?? 89 35 ?? ?? ?? ?? 48 89 35")),
				new KeyValuePair<string, SigScanTarget>("VariablePage", new SigScanTarget(4, "C3 48 8B 15 ?? ?? ?? ?? 48 85 D2 0F 85"))
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
				if (System.Text.RegularExpressions.Regex.IsMatch(name, @"^\w{3,}$"))
				{
					current.RoomName = name.ToLower();
				}
			}
			catch
			{
			}
		});

		vars.Done = (Action)(() =>
		{
			if (settings["gameTime"])
			{
				timer.CurrentTimingMethod = TimingMethod.GameTime;
			}

			vars.Log("All done.");
			vars.Ready = true;
		});

		CancellationToken token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			current.RoomName = "";

			if (vars.Version == "LOVE itch")
			{
				vars.RoomName();
				if (current.RoomName != "")
				{
					vars.Log("current.RoomName: \"" + current.RoomName + "\"");

					var sleepMarginPatch = new byte[] { 0xC8, 0x00, 0x00, 0x00 };

					try
					{
						game.Suspend();

						// Makes the game run at full 60fps regardless of your display refresh rate or Windows version.
						game.WriteBytes((IntPtr)vars.SleepMargin, sleepMarginPatch);
					}
					finally
					{
						game.Resume();
					}

					vars.Done();
					goto task_end;
				}
				else
				{
					vars.Log("Invalid current.RoomName");
				}
			}
			else if (vars.Version == "LOVE")
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

					vars.RoomName();
					if (current.RoomName != "")
					{
						vars.Log("current.RoomName: \"" + current.RoomName + "\"");
						break;
					}
					else
					{
						vars.Log("Invalid current.RoomName");
					}
				}
			}

			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		while (!token.IsCancellationRequested)
		{
			vars.Log("Scanning for variable targets..");

			var variableTargets = new List<KeyValuePair<string, SigScanTarget>>()
			{
				// Target is a string, which contains the game's variable name for things like frame counter, checkpoint count, ...
				// It should be 32 bytes, for example: "playerTimer.xxxxplayerTimer.xxxx" (. is 0x00, not ".")

				//new KeyValuePair<string, SigScanTarget>("playerSpawns", new SigScanTarget(0, "70 6C 61 79 65 72 53 70 61 77 6E 73 00 78 78 78 70 6C 61 79 65 72 53 70 61 77 6E 73 00 78 78 78")),
				new KeyValuePair<string, SigScanTarget>("playerTimer", new SigScanTarget(0, "70 6C 61 79 65 72 54 69 6D 65 72 00 78 78 78 78 70 6C 61 79 65 72 54 69 6D 65 72 00 78 78 78 78"))
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
			vars.Log("variablePageAddress: 0x" + variablePageAddress.ToString("X"));

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

						// Scan for pointers to variable string address.

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
								// Scan for instances of the supposed variable identifier.

								var scanner_ = new SignatureScanner(game, page_.BaseAddress, (int)page_.RegionSize);
								IEnumerable<IntPtr> results = scanner_.ScanAll(target_);

								foreach (IntPtr result in results)
								{
									// If result points to an address that is in the same page as variablePageAddress, it is likely the variable address.

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

				vars.Log("variableAddressesFound: " + variableAddressesFound.Count);

				if (uniqueVariablesFound == variableTargets.Count)
				{
					int found = 0;
					foreach (var variable in variableAddressesFound)
					{
						string name = variable.Key;
						IntPtr address = variable.Value;

						if (name == "playerTimer")
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
						vars.Done();
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
	if (!vars.Ready)
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

// v0.5.8 02-Jan-2023
