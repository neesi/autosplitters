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
			pointerTargets.Add("RoomNum", new SigScanTarget(6, "48 ?? ?? ?? 3B 35 ?? ?? ?? ?? 41 ?? ?? ?? 49 ?? ?? E8 ?? ?? ?? ?? FF"));
			pointerTargets.Add("RoomBase", new SigScanTarget(18, "84 C9 ?? F2 ?? ?? ?? ?? 8D 1C C5 00 00 00 00 ?? 8B"));
			pointerTargets.Add("VariableNames", new SigScanTarget(15, "3B 35 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 48 8B 1C E8"));
			pointerTargets.Add("GlobalData", new SigScanTarget(20, "BA FF FF FF 00 E8 ?? ?? ?? ?? 48 89 05 ?? ?? ?? ?? 48 89 05"));
		}
		else
		{
			pointerTargets.Add("RoomNum", new SigScanTarget(8, "85 C0 ?? ?? ?? ?? FF 35 ?? ?? ?? ?? E8 ?? ?? ?? ?? 83 C4 04 50 8D"));
			pointerTargets.Add("RoomBase", new SigScanTarget(11, "4A 8B 41 FC 89 01 ?? ?? ?? ?? A1 ?? ?? ?? ?? 68 ?? ?? ?? ?? ?? ?? ?? E8"));
			pointerTargets.Add("VariableNames", new SigScanTarget(7, "0F ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 8B 2C B0 85 ED"));
			pointerTargets.Add("GlobalData", new SigScanTarget(8, "8B D8 85 DB ?? ?? 8B 3D ?? ?? ?? ?? 83 7F ?? ?? ?? ?? ?? ?? 00 00 8B 47"));
		}

		foreach (KeyValuePair<string, SigScanTarget> target in pointerTargets)
		{
			target.Value.OnFound = (proc, scan, address) => is64bit ? address + 0x4 + proc.ReadValue<int>(address) : proc.ReadPointer(address);
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

			string[] variableStrings = { "playertime", /* "gamemode", "spawnpoints" */ };

			var scanner = new SignatureScanner(game, modules.First().BaseAddress, modules.First().ModuleMemorySize);
			IEnumerable<IntPtr> variableNamePointers = scanner.ScanAll(pointerTargets["VariableNames"]);
			log("VariableNames: " + variableNamePointers.Count());

			var variableStringsFound = new List<Tuple<string, int>>();
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
			log("GlobalData: " + globalDataPointers.Count());

			var pointerBasesFound = new List<Tuple<IntPtr, IntPtr, int, IntPtr, IntPtr, int>>();
			foreach (IntPtr pointer in globalDataPointers)
			{
				IntPtr address = game.ReadPointer(pointer);
				if (address != IntPtr.Zero)
				{
					int offset = pointerSize;
					while (pointerBasesFound.Where(x => x.Item2 == address).Count() < 3 && offset <= 0xFFFF)
					{
						IntPtr searchAddress = game.ReadPointer(address + offset);
						if (searchAddress != IntPtr.Zero)
						{
							IntPtr pointerBase = game.ReadPointer(searchAddress + 0x10);
							int andOperand = game.ReadValue<int>(searchAddress + 0x8);

							if (pointerBase != IntPtr.Zero && andOperand > 0 && !pointerBasesFound.Any(x => x.Item5 == pointerBase && x.Item6 == andOperand))
							{
								foreach (MemoryBasicInformation page in game.MemoryPages())
								{
									long pageBase = (long)page.BaseAddress;
									int pageSize = (int)page.RegionSize;
									long pageEnd = pageBase + pageSize;

									if ((long)pointerBase >= pageBase && (long)pointerBase <= pageEnd)
									{
										pointerBasesFound.Add(Tuple.Create(pointer, address, offset, searchAddress, pointerBase, andOperand));
										break;
									}
								}
							}
						}

						offset += pointerSize;
					}
				}
			}

			if (pointerBasesFound.Count > 0)
			{
				vars.PointerBasesFound = pointerBasesFound;
				break;
			}

			log("Pointer base not found.");
			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		if (!token.IsCancellationRequested)
		{
			log("Scanning for global variable addresses..");

			var variablesFound = new List<Tuple<string, IntPtr>>();
			foreach (Tuple<IntPtr, IntPtr, int, IntPtr, IntPtr, int> elementA in vars.PointerBasesFound)
			{
				variablesFound.Clear();
				string a = "pointerBase: " + hex(elementA.Item1) + " -> " + hex(elementA.Item2) + " + " + hex(elementA.Item3) + " -> ";
				string b = hex(elementA.Item4) + " + 0x10 = " + hex(elementA.Item5) + ", " + hex(elementA.Item4) + " + 0x8 = " + hex(elementA.Item6);
				log(a + b);

				foreach (Tuple<string, int> elementB in vars.VariableStringsFound)
				{
					try
					{
						int variableIdentifier = elementB.Item2;
						int identifierExtension = (0x1 - (0x61C8864F * variableIdentifier)) & 0x7FFFFFFF;
						int result = identifierExtension & elementA.Item6;

						long offset = result * (pointerSize + 0x8);
						IntPtr variablePointer = (IntPtr)((long)elementA.Item5 + offset);

						int identifier = game.ReadValue<int>(variablePointer + pointerSize);
						int extension = game.ReadValue<int>(variablePointer + pointerSize + 0x4);

						if (identifier == variableIdentifier && extension == identifierExtension)
						{
							IntPtr variableAddress = game.ReadPointer(variablePointer);
							double value = game.ReadValue<double>(variableAddress);

							// Values are either variableAddress = double, or variableAddress -> address1 -> address2 = string.
							// Note that address1 and address2 may change while the game is running, variableAddress does not.

							if (!value.ToString().Any(Char.IsLetter) && value.ToString().Length <= 12)
							{
								log(elementB.Item1 + ": " + hex(variablePointer) + " -> " + hex(variableAddress) + " = <double>" + value);
							}
							else
							{
								IntPtr address1 = game.ReadPointer(variableAddress);
								IntPtr address2 = game.ReadPointer(address1);
								string str = game.ReadString(address2, 256);
								log(elementB.Item1 + ": " + hex(variablePointer) + " -> " + hex(variableAddress) + " -> " + hex(address1) + " -> " + hex(address2) + " = " + qt(str));
							}

							variablesFound.Add(Tuple.Create(elementB.Item1, variableAddress));
						}
					}
					catch
					{
					}
				}

				log("variablesFound: " + variablesFound.Count + "/" + vars.VariableStringsFound.Count);

				if (variablesFound.Count == vars.VariableStringsFound.Count)
				{
					IntPtr frameAddress = variablesFound.Where(x => x.Item1 == "playertime").Select(x => x.Item2).FirstOrDefault();
					vars.RoomNumber = new MemoryWatcher<int>(vars.RoomNum);
					vars.FrameCount = new MemoryWatcher<double>(frameAddress);
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

// v0.9.2 06-Aug-2023
