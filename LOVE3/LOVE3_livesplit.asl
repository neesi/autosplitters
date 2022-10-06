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
		"room_credits",
		"room_keyboardmapping",
		"room_tutorial",
		"room_achievements"
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
			if (!is64bit)
			{
				vars.Version = vars.GameExe.ToLower() == "love3.exe" ? "Full" : "Demo";

				vars.PointerTargets = new List<KeyValuePair<string, SigScanTarget>>()
				{
					new KeyValuePair<string, SigScanTarget>("RoomNumTrg", new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7")),
					new KeyValuePair<string, SigScanTarget>("RoomBaseTrg", new SigScanTarget(10, "7E ?? 8B 2D ?? ?? ?? ?? 8B 3D ?? ?? ?? ?? 2B EF 3B F3 7D")),
					new KeyValuePair<string, SigScanTarget>("VarPageAddrTrg", new SigScanTarget(9, "FF 05 ?? ?? ?? ?? 8B 06 A3 ?? ?? ?? ?? 8B"))
				};

				foreach (var target in vars.PointerTargets)
				{
					SigScanTarget trg = target.Value;
					trg.OnFound = (p, s, addr) => p.ReadPointer(addr);
				}
			}
			else if (vars.GameExe.ToLower() == "love3.exe" && is64bit)
			{
				vars.Version = "Full";

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

			vars.Log("Scanning for pointers..");
			break;
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
				// it should be 32 bytes, for example: "playertime.xxxxxplayertime.xxxxx" (. is 0x00, not ".")

				//new KeyValuePair<string, SigScanTarget>("spawnpoints", new SigScanTarget(0, "73 70 61 77 6E 70 6F 69 6E 74 73 00 78 78 78 78 73 70 61 77 6E 70 6F 69 6E 74 73 00 78 78 78 78")),
				new KeyValuePair<string, SigScanTarget>("playertime", new SigScanTarget(0, "70 6C 61 79 65 72 74 69 6D 65 00 78 78 78 78 78 70 6C 61 79 65 72 74 69 6D 65 00 78 78 78 78 78"))
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
											IntPtr ptr = game.ReadPointer((IntPtr)variableAddress);
											vars.Log(variable.Key + " address: [0x" + variableAddress.ToString("X") + "] -> 0x" + ptr.ToString("X"));
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

						if (name == "playertime" && value.ToString().All(Char.IsDigit))
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

// v0.4.7 06-Oct-2022
