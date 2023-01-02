state("LOVE3") {}
state("LOVE3_Demo") {}

startup
{
	vars.FastVariableScan = true;
	vars.Log = (Action<object>)(output => print("   [" + vars.GameExe + "]   " + output));
	settings.Add("gameTime", true, "Automatically change timing method to Game Time");

	vars.RoomActionList = new List<string>()
	{
		"room_startup",
		"room_displaylogos",
		"room_controlsdisplay",
		"room_mainmenu",
		"room_levelselect",
		"room_menu_lovecustom"
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

		if (!is64bit)
		{
			vars.Version = vars.GameExe.ToLower() == "love3.exe" ? "Full" : "Demo";

			vars.PointerTargets = new List<KeyValuePair<string, SigScanTarget>>()
			{
				new KeyValuePair<string, SigScanTarget>("RoomNum", new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7")),
				new KeyValuePair<string, SigScanTarget>("RoomBase", new SigScanTarget(10, "7E ?? 8B 2D ?? ?? ?? ?? 8B 3D ?? ?? ?? ?? 2B EF 3B F3 7D")),
				new KeyValuePair<string, SigScanTarget>("VariablePage", new SigScanTarget(9, "FF 05 ?? ?? ?? ?? 8B 06 A3 ?? ?? ?? ?? 8B"))
			};

			foreach (var target in vars.PointerTargets)
			{
				SigScanTarget trg = target.Value;
				trg.OnFound = (p, s, addr) => p.ReadPointer(addr);
			}
		}
		else if (is64bit)
		{
			// 64-bit LOVE 3 Demo doesn't exist, but the signatures work for 64-bit versions of LOVE 2: kuso and LOVE 3, so this might work if there ever is a 64-bit LOVE 3 Demo.

			vars.Version = vars.GameExe.ToLower() == "love3.exe" ? "Full" : "Demo";

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

			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		while (!token.IsCancellationRequested)
		{
			vars.Log("Scanning for variable targets..");

			var variableTargets = new List<KeyValuePair<string, SigScanTarget>>()
			{
				// Target is a string, which contains the game's variable name for things like frame counter, checkpoint count, ...
				// It should be 32 bytes, for example: "playertime.xxxxxplayertime.xxxxx" (. is 0x00, not ".")

				//new KeyValuePair<string, SigScanTarget>("spawnpoints", new SigScanTarget(0, "73 70 61 77 6E 70 6F 69 6E 74 73 00 78 78 78 78 73 70 61 77 6E 70 6F 69 6E 74 73 00 78 78 78 78")),
				new KeyValuePair<string, SigScanTarget>("playertime", new SigScanTarget(0, "70 6C 61 79 65 72 74 69 6D 65 00 78 78 78 78 78 70 6C 61 79 65 72 74 69 6D 65 00 78 78 78 78 78"))
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

						if (name == "playertime")
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
	return vars.RoomNumber.Changed && !current.RoomName.Contains("leaderboard") && !old.RoomName.Contains("leaderboard") && vars.FrameCount.Current > 90;
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
