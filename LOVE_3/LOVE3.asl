state("LOVE3") {}
state("LOVE3_Demo") {}

startup
{
	settings.Add("gameTime", true, "Automatically change timing method to Game Time");

	vars.ActionRooms = new List<string>
	{
		"room_controlsdisplay",
		"room_displaylogos",
		"room_levelselect",
		"room_mainmenu",
		"room_menu_lovecustom",
		"room_startup"
	};
}

init
{
	try
	{
		vars.GameExe = modules.First().ModuleName;
		if (!vars.GameExe.ToLower().EndsWith(".exe"))
		{
			throw new Exception("Game not loaded yet.");
		}

		vars.Ready = false;
	}
	catch
	{
		throw;
	}

	bool is64bit = game.Is64Bit();
	int pointerSize = is64bit ? 8 : 4;
	string alignment = is64bit ? "00 00 00 00" : "";

	string exePath = modules.First().FileName;
	string winPath = new FileInfo(exePath).DirectoryName + @"\data.win";

	long exeSize = new FileInfo(exePath).Length;
	long winSize = new FileInfo(winPath).Length;
	long exeMemorySize = modules.First().ModuleMemorySize;
	IntPtr baseAddress = modules.First().BaseAddress;

	var log = vars.Log = (Action<object>)(input =>
	{
		print("[" + vars.GameExe + "] " + input);
	});

	var qt = vars.Qt = (Func<object, string>)(input =>
	{
		input = input ?? "";
		return "\"" + input.ToString() + "\"";
	});

	var hex = (Func<object, string>)(input =>
	{
		if (input == null || input is string)
		{
			return "0";
		}

		return "0x" + Convert.ToInt64(input.ToString()).ToString("X");
	});

	log(qt(exePath) + ", exeSize: " + exeSize + ", winSize: " + winSize + ", exeMemorySize: " + hex(exeMemorySize) + ", baseAddress: " + hex(baseAddress) + ", is64bit: " + is64bit);

	vars.CancelSource = new CancellationTokenSource();
	CancellationToken token = vars.CancelSource.Token;

	System.Threading.Tasks.Task.Run(async () =>
	{
		var pointerTargets = new Dictionary<string, SigScanTarget>();
		if (is64bit)
		{
			pointerTargets.Add("RoomNum", new SigScanTarget(7, "CC CC CC 8B D1 8B 0D ?? ?? ?? ?? E9 ?? ?? ?? ?? CC"));
			pointerTargets.Add("RoomBase", new SigScanTarget(20, "48 ?? ?? ?? ?? 89 35 ?? ?? ?? ?? 89 35 ?? ?? ?? ?? 48 89 35"));
			pointerTargets.Add("VariablePage", new SigScanTarget(4, "C3 48 8B 15 ?? ?? ?? ?? 48 85 D2 0F 85"));
		}
		else
		{
			pointerTargets.Add("RoomNum", new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7"));
			pointerTargets.Add("RoomBase", new SigScanTarget(10, "7E ?? 8B 2D ?? ?? ?? ?? 8B 3D ?? ?? ?? ?? 2B EF 3B F3 7D"));
			pointerTargets.Add("VariablePage", new SigScanTarget(9, "FF 05 ?? ?? ?? ?? 8B 06 A3 ?? ?? ?? ?? 8B"));
		}

		while (!token.IsCancellationRequested)
		{
			log("Scanning for pointers..");

			var scanner = new SignatureScanner(game, modules.First().BaseAddress, modules.First().ModuleMemorySize);
			var pointersFound = new Dictionary<string, IntPtr>();

			foreach (KeyValuePair<string, SigScanTarget> target in pointerTargets)
			{
				target.Value.OnFound = (proc, scan, address) => is64bit ? address + 0x4 + proc.ReadValue<int>(address) : proc.ReadPointer(address);
				IntPtr pointer = scanner.Scan(target.Value);

				if (pointer != IntPtr.Zero)
				{
					pointersFound.Add(target.Key, pointer);
					log(target.Key + ": " + hex(pointer) + " = " + hex(game.ReadPointer(pointer)));
				}
				else
				{
					log(target.Key + ": not found");
				}
			}

			log("pointersFound: " + pointersFound.Count + "/" + pointerTargets.Count);

			if (pointersFound.Count == pointerTargets.Count)
			{
				vars.RoomNum = pointersFound["RoomNum"];
				vars.RoomBase = pointersFound["RoomBase"];
				vars.VariablePage = pointersFound["VariablePage"];

				vars.RoomName = (Action)(() =>
				{
					try
					{
						IntPtr roomBase = game.ReadPointer((IntPtr)vars.RoomBase);
						int roomNum = game.ReadValue<int>((IntPtr)vars.RoomNum);
						string roomName = new DeepPointer(roomBase + (roomNum * pointerSize), 0x0).DerefString(game, 128) ?? "";

						if (System.Text.RegularExpressions.Regex.IsMatch(roomName, @"^\w{3,}$"))
						{
							current.RoomName = roomName.ToLower();
						}
					}
					catch
					{
					}
				});

				current.RoomName = "";
				vars.RoomName();

				if (current.RoomName != "")
				{
					log("current.RoomName: " + qt(current.RoomName));
					break;
				}
				else
				{
					log("Invalid current.RoomName");
				}
			}

			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		var variableTargets = new List<KeyValuePair<string, SigScanTarget>>();
		if (!token.IsCancellationRequested)
		{
			log("Adding variable targets..");

			var variableTarget = (Action<string, int, string>)((variable, offset, signature) =>
			{
				try
				{
					if (!String.IsNullOrWhiteSpace(variable))
					{
						variable = System.Text.RegularExpressions.Regex.Replace(variable, @"\s+", "");
						signature = signature.Replace("\t", "");

						string a = variable + '.';
						int b = (a.Length / 8) + 1;
						string c = a.Length % 8 == 0 ? "" : new string('x', (b * 8) - a.Length);
						string d = a + c + a + c;
						byte[] e = Encoding.UTF8.GetBytes(d);

						if (String.IsNullOrWhiteSpace(signature))
						{
							signature = BitConverter.ToString(e).Replace("-", " ").Replace("2E", "00");
						}

						if (!variableTargets.Any(t => t.Key == variable))
						{
							variableTargets.Add(new KeyValuePair<string, SigScanTarget>(variable, new SigScanTarget(offset, signature)));
							log(variable + ": SigScanTarget(" + offset + ", " + qt(signature) + ") -> " + qt(d));
						}
					}
				}
				catch
				{
				}
			});

			// If the signature is empty, it is automatically generated from the case-sensitive variable name.

			variableTarget("playertime", 0, "70 6C 61 79 65 72 74 69 6D 65 00 78 78 78 78 78 70 6C 61 79 65 72 74 69 6D 65 00 78 78 78 78 78");
			//variableTarget("gamemode", 0, "67 61 6D 65 6D 6F 64 65 00 78 78 78 78 78 78 78 67 61 6D 65 6D 6F 64 65 00 78 78 78 78 78 78 78");
			//variableTarget("spawnpoints", 0, "");
		}

		while (!token.IsCancellationRequested)
		{
			log("Scanning for variable strings..");

			// 1. Scan variableTargets for string addresses.
			// 2. Scan for pointers to each address in stringsFound.
			// 3. variableIdentifier is next to stringPointer. -4 bytes for 32-bit, -8 bytes for 64-bit.
			// 4. Scan for instances of the supposed variableIdentifier.
			// 5. variablePointer is next to variableIdentifier. -4 bytes for 32-bit, -8 bytes for 64-bit.
			// 6. If variableAddress is in the same page as variablePageAddress, it is potentially the actual variable address.

			// fastScan allows only one variablesFound address per variableTarget and skips further scan attempts for that variable.
			// Each variableTarget should have only one associated variableAddress.
			// Disabling fastScan may help with debugging if the script is finding a wrong variableAddress.

			bool fastScan = true;

			var stringsFound = new List<KeyValuePair<string, IntPtr>>();
			var variablesFound = new List<KeyValuePair<string, IntPtr>>();
			int uniqueStringsFound = 0;
			int uniqueVariablesFound = 0;

			long variablePageAddress = (long)game.ReadPointer((IntPtr)vars.VariablePage);
			long variablePageBase = 0;
			long variablePageEnd = 0;
			int variablePageSize = 0;

			foreach (var page in game.MemoryPages())
			{
				var scanner = new SignatureScanner(game, page.BaseAddress, (int)page.RegionSize);
				foreach (KeyValuePair<string, SigScanTarget> target in variableTargets)
				{
					IEnumerable<IntPtr> results = scanner.ScanAll(target.Value);
					foreach (IntPtr stringAddress in results)
					{
						stringsFound.Add(new KeyValuePair<string, IntPtr>(target.Key, stringAddress));
						uniqueStringsFound = stringsFound.GroupBy(f => f.Key).Distinct().Count();
						log(target.Key + ": " + hex(stringAddress));
					}
				}

				long pageBase = (long)page.BaseAddress;
				int pageSize = (int)page.RegionSize;
				long pageEnd = pageBase + pageSize;

				if (variablePageAddress >= pageBase && variablePageAddress <= pageEnd)
				{
					variablePageBase = pageBase;
					variablePageEnd = pageEnd;
					variablePageSize = pageSize;
				}
			}

			log("uniqueStringsFound: " + uniqueStringsFound + "/" + variableTargets.Count);
			log("variablePageAddress: " + hex(variablePageAddress) + ", " + hex(variablePageEnd) + " - " + hex(variablePageBase) + " = " + hex(variablePageSize));

			if (uniqueStringsFound == variableTargets.Count && variableTargets.Count > 0 && variablePageBase > 0)
			{
				log("Scanning for variable addresses..");

				foreach (var pageA in game.MemoryPages())
				{
					var scannerA = new SignatureScanner(game, pageA.BaseAddress, (int)pageA.RegionSize);
					foreach (KeyValuePair<string, IntPtr> element in stringsFound)
					{
						if (token.IsCancellationRequested)
						{
							goto task_end;
						}

						if (fastScan && variablesFound.Any(f => f.Key == element.Key))
						{
							continue;
						}

						if (is64bit)
						{
							vars.StringAddress = (long)element.Value;
						}
						else
						{
							vars.StringAddress = (int)element.Value;
						}

						byte[] a = BitConverter.GetBytes(vars.StringAddress);
						string b = BitConverter.ToString(a).Replace("-", " ");
						var targetA = new SigScanTarget(pointerSize - 4, alignment + b);
						IEnumerable<IntPtr> resultsA = scannerA.ScanAll(targetA);

						foreach (IntPtr stringPointer in resultsA)
						{
							int variableIdentifier = game.ReadValue<int>(stringPointer - pointerSize);
							if (variableIdentifier <= 0x186A0)
							{
								continue;
							}

							byte[] c = BitConverter.GetBytes(variableIdentifier);
							string d = BitConverter.ToString(c).Replace("-", " ");
							var targetB = new SigScanTarget(-4, alignment + d);

							foreach (var pageB in game.MemoryPages())
							{
								var scannerB = new SignatureScanner(game, pageB.BaseAddress, (int)pageB.RegionSize);
								IEnumerable<IntPtr> resultsB = scannerB.ScanAll(targetB);

								foreach (IntPtr variablePointer in resultsB)
								{
									long variableAddress = (long)game.ReadPointer(variablePointer);
									var variable = new KeyValuePair<string, IntPtr>(element.Key, (IntPtr)variableAddress);

									if (variableAddress >= variablePageBase && variableAddress <= variablePageEnd)
									{
										// Usually variableAddress = double, but sometimes variableAddress -> address1 -> address2 = string.
										// Note that address1 and address2 change, but variableAddress does not.

										double value = game.ReadValue<double>((IntPtr)variableAddress);
										string e = element.Key + ": " + hex(variableIdentifier) + ", " + hex(variablePointer) + " -> " + hex(variableAddress);

										if (!value.ToString().Any(Char.IsLetter) && value.ToString().Length <= 12)
										{
											log(e + " = <double>" + value);
										}
										else
										{
											IntPtr f = game.ReadPointer((IntPtr)variableAddress);
											IntPtr g = game.ReadPointer(f);
											string h = game.ReadString(g, 128) ?? "";
											log(e + " -> " + hex(f) + " -> " + hex(g) + " = " + qt(h));
										}

										if (!variablesFound.Any(f => f.Equals(variable)))
										{
											variablesFound.Add(variable);
											uniqueVariablesFound = variablesFound.GroupBy(f => f.Key).Distinct().Count();
										}

										if (fastScan)
										{
											if (uniqueVariablesFound == variableTargets.Count)
											{
												goto scan_completed;
											}
											else
											{
												goto next_element;
											}
										}
									}
								}
							}
						}

						next_element:;
					}
				}

				scan_completed:;

				log("uniqueVariablesFound: " + uniqueVariablesFound + "/" + variableTargets.Count);

				if (uniqueVariablesFound == variableTargets.Count)
				{
					bool framesFound = false;
					foreach (KeyValuePair<string, IntPtr> element in variablesFound)
					{
						string name = element.Key;
						IntPtr address = element.Value;

						if (name == "playertime")
						{
							double value = game.ReadValue<double>(address);
							if (value.ToString().All(Char.IsDigit))
							{
								if (!framesFound)
								{
									vars.Frames = address;
									framesFound = true;
								}
							}
							else
							{
								log("Discarded " + name + ": " + hex(address) + " = <double>" + value);
							}
						}
					}

					if (framesFound)
					{
						vars.RoomNumber = new MemoryWatcher<int>(vars.RoomNum);
						vars.FrameCount = new MemoryWatcher<double>(vars.Frames);
						goto done;
					}
				}
			}

			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		goto task_end;

		done:;

		if (settings["gameTime"])
		{
			timer.CurrentTimingMethod = TimingMethod.GameTime;
		}

		vars.RoomName();
		vars.Ready = true;
		log("All done.");

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
			vars.Log("current.RoomName: " + vars.Qt(old.RoomName) + " -> " + vars.Qt(current.RoomName));
		}
	}
}

start
{
	return !vars.ActionRooms.Contains(current.RoomName) && vars.FrameCount.Current == vars.FrameCount.Old + 1;
}

split
{
	return vars.RoomNumber.Changed && !current.RoomName.Contains("leaderboard") && !old.RoomName.Contains("leaderboard") && vars.FrameCount.Current > 90;
}

reset
{
	return vars.FrameCount.Current < vars.FrameCount.Old ||
	       vars.ActionRooms.Contains(current.RoomName);
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

// v0.7.7 26-Mar-2023
