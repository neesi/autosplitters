state("kuso") {}

startup
{
	settings.Add("gameTime", true, "Automatically change timing method to Game Time");

	vars.ActionRooms = new List<string>
	{
		"room_2p_select",
		"room_gameselect",
		"room_levelselect",
		"room_levelselect_kuso",
		"room_levelselect_love",
		"room_levelselect_other",
		"room_levelsetselect",
		"room_mainmenu",
		"room_startup",
		"room_titlescreen"
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
		input = input == null ? "" : input.ToString().Split('\0')[0];
		return "\"" + input + "\"";
	});

	var hex = vars.Hex = (Func<object, string>)(input =>
	{
		if (input != null)
		{
			long number;
			bool success = long.TryParse(input.ToString(), out number);

			if (success)
			{
				return "0x" + number.ToString("X");
			}
		}

		return "0";
	});

	vars.RoomName = (Action)(() =>
	{
		try
		{
			IntPtr roomBase = game.ReadPointer((IntPtr)vars.RoomBase);
			if (roomBase != IntPtr.Zero)
			{
				int roomNum = game.ReadValue<int>((IntPtr)vars.RoomNum);
				string roomName = new DeepPointer(roomBase + (roomNum * pointerSize), 0x0).DerefString(game, 256) ?? "";

				if (System.Text.RegularExpressions.Regex.IsMatch(roomName, @"^\w{3,}$"))
				{
					current.RoomName = roomName.ToLower();
				}
			}
		}
		catch
		{
		}
	});

	log(qt(exePath) + ", exeSize: " + exeSize + ", winSize: " + winSize + ", exeMemorySize: " + hex(exeMemorySize) + ", baseAddress: " + hex(baseAddress) + ", is64bit: " + is64bit);

	vars.CancelSource = new CancellationTokenSource();
	CancellationToken token = vars.CancelSource.Token;

	System.Threading.Tasks.Task.Run(async () =>
	{
		var pointerTargets = new Dictionary<string, SigScanTarget>();
		if (is64bit)
		{
			vars.Version = "Full";

			pointerTargets.Add("RoomNum", new SigScanTarget(6, "48 ?? ?? ?? 3B 35 ?? ?? ?? ?? 41 ?? ?? ?? 49 ?? ?? E8 ?? ?? ?? ?? FF"));
			pointerTargets.Add("RoomBase", new SigScanTarget(18, "84 C9 ?? F2 ?? ?? ?? ?? 8D 1C C5 00 00 00 00 ?? 8B"));
			pointerTargets.Add("VariableNames", new SigScanTarget(15, "3B 35 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 48 8B 1C E8"));
			pointerTargets.Add("GlobalData", new SigScanTarget(20, "BA FF FF FF 00 E8 ?? ?? ?? ?? 48 89 05 ?? ?? ?? ?? 48 89 05"));
		}
		else if (exeSize == 5178368 && winSize == 133467400 && !is64bit)
		{
			vars.Version = "Full itch";

			vars.RoomNum = 0xAC2DB8;
			vars.RoomBase = 0x8B2774;
			vars.SleepMargin = 0x7FF088;

			vars.RoomNumber = new MemoryWatcher<int>((IntPtr)vars.RoomNum);
			vars.FrameCount = new MemoryWatcher<double>(new DeepPointer((IntPtr)0x8B2780, 0x2C, 0x10, 0x48C, 0x700));
		}
		else if (exeSize == 4270592 && !is64bit)
		{
			vars.Version = "Demo";

			vars.RoomNum = 0x9CB860;
			vars.RoomBase = 0x7C9668;
			vars.SleepMargin = 0x77E398;
			vars.TempBug = 0x4A5FF0;

			vars.RoomNumber = new MemoryWatcher<int>((IntPtr)vars.RoomNum);
			vars.FrameCount = new MemoryWatcher<double>(new DeepPointer((IntPtr)0x7C9730, 0x34, 0x10, 0x88, 0x10));
		}
		else
		{
			log("Unsupported game version. Stopping.");
			goto task_end;
		}

		foreach (KeyValuePair<string, SigScanTarget> target in pointerTargets)
		{
			target.Value.OnFound = (proc, scan, address) => is64bit ? address + 0x4 + proc.ReadValue<int>(address) : proc.ReadPointer(address);
		}

		log("vars.Version: " + vars.Version);

		while (!token.IsCancellationRequested && (vars.Version == "Full itch" || vars.Version == "Demo"))
		{
			current.RoomName = "";
			vars.RoomName();
			if (current.RoomName != "")
			{
				try
				{
					game.Suspend();

					// Makes the game run at full 60fps regardless of display refresh rate or Windows version.
					game.WriteBytes((IntPtr)vars.SleepMargin, new byte[] { 0xC8, 0x00, 0x00, 0x00 });

					if (vars.Version == "Demo")
					{
						// Stops the game from attempting to delete %TEMP% folder. https://github.com/neesi/autosplitters/tree/main/LOVE_2_kuso
						game.WriteBytes((IntPtr)vars.TempBug, new byte[] { 0xE9, 0x58, 0x01, 0x00, 0x00, 0x90 });
					}
				}
				finally
				{
					game.Resume();
				}

				log("current.RoomName: " + qt(current.RoomName));
				goto ready;
			}

			log("Invalid room name.");
			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		scan_start:;

		while (!token.IsCancellationRequested)
		{
			log("Scanning for current room name..");

			var scanner = new SignatureScanner(game, modules.First().BaseAddress, modules.First().ModuleMemorySize);
			IEnumerable<IntPtr> roomNumPointers = scanner.ScanAll(pointerTargets["RoomNum"]);
			IEnumerable<IntPtr> roomBasePointers = scanner.ScanAll(pointerTargets["RoomBase"]);

			log("RoomNum: " + roomNumPointers.Count());
			log("RoomBase: " + roomBasePointers.Count());

			current.RoomName = "";
			foreach (IntPtr basePointer in roomBasePointers)
			{
				vars.RoomBase = basePointer;
				foreach (IntPtr numPointer in roomNumPointers)
				{
					vars.RoomNum = numPointer;
					vars.RoomName();

					if (current.RoomName != "")
					{
						goto room_found;
					}
				}
			}

			log("Invalid room name.");
			await System.Threading.Tasks.Task.Delay(2000, token);
			continue;

			room_found:;

			log("RoomNum: " + hex(vars.RoomNum) + " = " + hex(game.ReadValue<int>((IntPtr)vars.RoomNum)));
			log("RoomBase: " + hex(vars.RoomBase) + " = " + hex(game.ReadPointer((IntPtr)vars.RoomBase)));
			log("current.RoomName: " + qt(current.RoomName));
			break;
		}

		while (!token.IsCancellationRequested)
		{
			log("Scanning for global variable strings..");

			string[] variableStrings = { "playerFrames", /* "gameMode", "playerSpawns" */ };
			var variableStringsFound = new List<Tuple<string, int>>();

			var scanner = new SignatureScanner(game, modules.First().BaseAddress, modules.First().ModuleMemorySize);
			IEnumerable<IntPtr> variableNamePointers = scanner.ScanAll(pointerTargets["VariableNames"]);
			log("VariableNames: " + variableNamePointers.Count());

			foreach (IntPtr pointer in variableNamePointers)
			{
				variableStringsFound.Clear();
				IntPtr variableBase = game.ReadPointer(pointer);
				int variableCount = game.ReadValue<int>(pointer - (pointerSize + 0x4));

				if (variableBase != IntPtr.Zero && variableCount > 0 && variableCount <= 0xFFFF)
				{
					log("VariableNames: " + hex(pointer) + " = " + hex(variableBase) + ", " + hex(variableCount));
					int variableIndex = 0;

					while (variableIndex <= variableCount)
					{
						IntPtr stringAddress = game.ReadPointer(variableBase + (variableIndex * pointerSize));
						string variableName = game.ReadString(stringAddress, 256);

						if (!String.IsNullOrWhiteSpace(variableName) && variableStrings.Contains(variableName) && !variableStringsFound.Any(x => x.Item1 == variableName))
						{
							int variableIdentifier = 0x186A0 + variableIndex;
							variableStringsFound.Add(Tuple.Create(variableName, variableIdentifier));
							log(variableName + ": " + hex(stringAddress) + ", " + hex(variableIdentifier));

							if (variableStringsFound.Count == variableStrings.Count())
							{
								goto variable_strings_found;
							}
						}

						variableIndex++;
					}
				}
			}

			log("Not all strings found.");
			await System.Threading.Tasks.Task.Delay(2000, token);
			continue;

			variable_strings_found:;

			vars.VariableStringsFound = variableStringsFound;
			break;
		}

		while (!token.IsCancellationRequested)
		{
			log("Scanning for global pointer base..");

			var scanner = new SignatureScanner(game, modules.First().BaseAddress, modules.First().ModuleMemorySize);
			IEnumerable<IntPtr> globalDataPointers = scanner.ScanAll(pointerTargets["GlobalData"]);
			var pointerBaseCandidates = new List<Tuple<IntPtr, IntPtr, int, IntPtr, IntPtr, int>>();
			log("GlobalData: " + globalDataPointers.Count());

			foreach (IntPtr pointer in globalDataPointers)
			{
				IntPtr address = game.ReadPointer(pointer);
				if (address != IntPtr.Zero)
				{
					int offset = pointerSize;
					while (offset <= 0xFFFF)
					{
						IntPtr searchAddress = game.ReadPointer(address + offset);
						if (searchAddress != IntPtr.Zero)
						{
							IntPtr pointerBase = game.ReadPointer(searchAddress + 0x10);
							int andOperand = game.ReadValue<int>(searchAddress + 0x8);

							if (pointerBase != IntPtr.Zero && andOperand > 0 && !pointerBaseCandidates.Any(x => x.Item5 == pointerBase && x.Item6 == andOperand))
							{
								pointerBaseCandidates.Add(Tuple.Create(pointer, address, offset, searchAddress, pointerBase, andOperand));
								break;
							}
						}

						offset += pointerSize;
					}
				}
			}

			if (pointerBaseCandidates.Count > 0)
			{
				var pointerBasesFound = new List<Tuple<IntPtr, int>>();
				foreach (MemoryBasicInformation page in game.MemoryPages())
				{
					long pageBase = (long)page.BaseAddress;
					int pageSize = (int)page.RegionSize;
					long pageEnd = pageBase + pageSize;

					foreach (Tuple<IntPtr, IntPtr, int, IntPtr, IntPtr, int> element in pointerBaseCandidates)
					{
						if ((long)element.Item5 >= pageBase && (long)element.Item5 <= pageEnd)
						{
							pointerBasesFound.Add(Tuple.Create(element.Item5, element.Item6));
							string a = "pointerBase: " + hex(element.Item1) + " -> " + hex(element.Item2) + " + " + hex(element.Item3) + " -> ";
							string b = hex(element.Item4) + " + 0x10 = " + hex(element.Item5) + ", " + hex(element.Item4) + " + 0x8 = " + hex(element.Item6);
							log(a + b);
						}
					}
				}

				if (pointerBasesFound.Count > 0)
				{
					vars.PointerBasesFound = pointerBasesFound;
					break;
				}
			}

			log("Pointer base not found.");
			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		if (!token.IsCancellationRequested)
		{
			log("Scanning for global variable addresses..");

			// Fast scan allows only one found variable address per variable string and skips further scan attempts for that variable.
			// Each variable string should have only one associated variable address.
			// Disabling fast scan may help with debugging if the script is finding a wrong variable address.

			bool fastScan = true;

			var variablesFound = new List<Tuple<string, IntPtr>>();
			int uniqueVariablesFound = 0;

			foreach (Tuple<string, int> elementA in vars.VariableStringsFound)
			{
				if (token.IsCancellationRequested)
				{
					goto task_end;
				}

				int variableIdentifier = elementA.Item2;
				byte[] a = BitConverter.GetBytes(variableIdentifier);
				string b = BitConverter.ToString(a).Replace("-", " ");

				int c = 0x1 - (0x61C8864F * variableIdentifier) & 0x7FFFFFFF;
				byte[] d = BitConverter.GetBytes(c);
				string e = BitConverter.ToString(d).Replace("-", " ");

				var target = new SigScanTarget(-pointerSize, b + e);
				foreach (MemoryBasicInformation page in game.MemoryPages())
				{
					var scanner = new SignatureScanner(game, page.BaseAddress, (int)page.RegionSize);
					IEnumerable<IntPtr> results = scanner.ScanAll(target);

					foreach (IntPtr variablePointer in results)
					{
						IntPtr variableAddress = game.ReadPointer(variablePointer);
						Tuple<string, IntPtr> variable = Tuple.Create(elementA.Item1, variableAddress);

						foreach (Tuple<IntPtr, int> elementB in vars.PointerBasesFound)
						{
							long f = c & elementB.Item2;
							long g = f * (pointerSize + 0x8);

							if ((long)variablePointer == (long)elementB.Item1 + g)
							{
								// Values are either variableAddress = double, or variableAddress -> address1 -> address2 = string.
								// Note that address1 and address2 may change while the game is running, variableAddress does not.

								double value = game.ReadValue<double>(variableAddress);
								string h = elementA.Item1 + ": " + hex(elementB.Item1) + ", " + hex(elementB.Item2);
								string i = hex(variablePointer) + " -> " + hex(variableAddress);

								if (!value.ToString().Any(Char.IsLetter) && value.ToString().Length <= 12)
								{
									log(h + ", " + i + " = <double>" + value);
								}
								else
								{
									IntPtr j = game.ReadPointer(variableAddress);
									IntPtr k = game.ReadPointer(j);
									string l = game.ReadString(k, 256);
									log(h + ", " + i + " -> " + hex(j) + " -> " + hex(k) + " = " + qt(l));
								}

								if (!variablesFound.Contains(variable))
								{
									variablesFound.Add(variable);
									uniqueVariablesFound = variablesFound.GroupBy(x => x.Item1).Distinct().Count();
								}

								if (fastScan)
								{
									if (uniqueVariablesFound == vars.VariableStringsFound.Count)
									{
										goto scan_completed;
									}
									else
									{
										goto next_elementA;
									}
								}
							}
						}
					}
				}

				next_elementA:;
			}

			scan_completed:;

			log("uniqueVariablesFound: " + uniqueVariablesFound + "/" + vars.VariableStringsFound.Count);

			if (uniqueVariablesFound == vars.VariableStringsFound.Count)
			{
				bool framesFound = false;
				foreach (Tuple<string, IntPtr> element in variablesFound)
				{
					string name = element.Item1;
					IntPtr address = element.Item2;

					if (name == "playerFrames")
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
					goto ready;
				}
			}

			await System.Threading.Tasks.Task.Delay(2000, token);
			goto scan_start;
		}

		goto task_end;

		ready:;

		if (settings["gameTime"])
		{
			timer.CurrentTimingMethod = TimingMethod.GameTime;
		}

		vars.SubtractFrames = 0;
		vars.SubtractFramesCache = 0;

		current.RoomName = "";
		vars.InitialUpdate = true;
		vars.Ready = true;

		task_end:;

		log("Task end.");
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

	if (vars.RoomNumber.Changed || vars.InitialUpdate)
	{
		vars.InitialUpdate = false;
		vars.RoomName();

		if (current.RoomName != old.RoomName && old.RoomName != "")
		{
			vars.Log("current.RoomName: " + vars.Qt(old.RoomName) + " -> " + vars.Qt(current.RoomName));

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
	return !vars.ActionRooms.Contains(current.RoomName) && vars.FrameCount.Current == vars.FrameCount.Old + 1;
}

split
{
	return vars.RoomNumber.Changed && vars.FrameCount.Current > 90;
}

reset
{
	return vars.FrameCount.Current < vars.FrameCount.Old ||
	       vars.ActionRooms.Contains(current.RoomName) && (vars.Version.Contains("Full") || (vars.Version == "Demo" && current.RoomName != "room_levelselect")) ||
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

// v0.9.0 31-Jul-2023
