state("kuso") {}

startup
{
	settings.Add("gameTime", true, "Automatically change timing method to Game Time");
	settings.Add("fpsFix", false, "Fix low FPS");
	settings.SetToolTip("fpsFix", "After enabling, restart game or reload this script");

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

		vars.Demo = false;
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
	long winSize = new FileInfo(winPath).Exists ? new FileInfo(winPath).Length : 0;
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
				byte[] number = game.ReadBytes((IntPtr)vars.RoomNum, 4);
				if (number != null)
				{
					int roomNum = BitConverter.ToInt32(number, 0);
					string roomName = new DeepPointer(roomBase + (roomNum * pointerSize), 0x0).DerefString(game, 256) ?? "";

					if (System.Text.RegularExpressions.Regex.IsMatch(roomName, @"^\w{3,}$"))
					{
						current.RoomName = roomName.ToLower();
					}
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
		// Signatures tested on GameMaker Windows runtime 2.1.4.218 (17-May-2018) and newer. Stable/LTS, YYC/VM.

		var pointerTargets = new Dictionary<string, SigScanTarget>();
		if (exeSize == 4270592 && !is64bit)
		{
			vars.Demo = true;
			vars.RoomNum = 0x9CB860;
			vars.RoomBase = 0x7C9668;
			vars.RoomNumber = new MemoryWatcher<int>((IntPtr)vars.RoomNum);
			vars.FrameCount = new MemoryWatcher<double>(new DeepPointer((IntPtr)0x7C9730, 0x34, 0x10, 0x7C, 0x0));

			while (!token.IsCancellationRequested)
			{
				current.RoomName = "";
				vars.RoomName();

				if (current.RoomName != "")
				{
					try
					{
						game.Suspend();

						// Stops kuso Demo from attempting to delete %TEMP% folder.
						// More info at https://github.com/neesi/autosplitters/tree/main/LOVE_2_kuso

						game.WriteBytes((IntPtr)0x4A5FF0, new byte[] { 0xE9, 0x58, 0x01, 0x00, 0x00, 0x90 });
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
		}
		else if (is64bit)
		{
			pointerTargets.Add("RoomNum", new SigScanTarget(6, "48 ?? ?? ?? 3B 35 ?? ?? ?? ?? 41 ?? ?? ?? 49 ?? ?? E8 ?? ?? ?? ?? FF"));
			pointerTargets.Add("RoomBase", new SigScanTarget(18, "84 C9 ?? F2 ?? ?? ?? ?? 8D 1C C5 00 00 00 00 ?? 8B"));
			pointerTargets.Add("VariableNames", new SigScanTarget(15, "3B 35 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 48 8B 1C E8"));
			pointerTargets.Add("GlobalData", new SigScanTarget(20, "BA FF FF FF 00 E8 ?? ?? ?? ?? 48 89 05 ?? ?? ?? ?? 48 89 05"));
			pointerTargets.Add("SleepMargin", new SigScanTarget(10, "48 8B CE E8 ?? ?? ?? ?? 89 05 ?? ?? ?? ?? EB 2C 48 8D 15 ?? ?? ?? ?? 48 8B ?? E8"));
		}
		else
		{
			pointerTargets.Add("RoomNum", new SigScanTarget(7, "E8 ?? ?? ?? ?? 8B 0D ?? ?? ?? ?? 3B C8 75 1A 6A 01 68 ?? ?? ?? ?? E8"));
			pointerTargets.Add("RoomBase", new SigScanTarget(11, "4A 8B 41 FC 89 01 ?? ?? ?? ?? A1 ?? ?? ?? ?? 68 ?? ?? ?? ?? ?? ?? ?? E8"));
			pointerTargets.Add("VariableNames", new SigScanTarget(1, "A3 ?? ?? ?? ?? C7 05 ?? ?? ?? ?? 08 00 00 00 E8 ?? ?? ?? ?? 83 C4 18 C3 CC"));
			pointerTargets.Add("GlobalData", new SigScanTarget(8, "8B D8 85 DB ?? ?? 8B 3D ?? ?? ?? ?? 83 7F ?? ?? ?? ?? ?? ?? 00 00 8B 47"));
			pointerTargets.Add("SleepMargin", new SigScanTarget(11, "8B ?? E8 ?? ?? ?? ?? 83 C4 0C A3 ?? ?? ?? ?? C6 05 ?? ?? ?? ?? 01 E9 ?? ?? ?? ?? B9"));
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
			IEnumerable<IntPtr> roomNumPointers = scanner.ScanAll(pointerTargets["RoomNum"]).Distinct();
			IEnumerable<IntPtr> roomBasePointers = scanner.ScanAll(pointerTargets["RoomBase"]).Distinct();

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

			var scanner = new SignatureScanner(game, modules.First().BaseAddress, modules.First().ModuleMemorySize);
			IEnumerable<IntPtr> variableNamePointers = scanner.ScanAll(pointerTargets["VariableNames"]).Distinct();
			log("VariableNames: " + variableNamePointers.Count());

			var variableStringsFound = new List<Tuple<string, int>>();
			foreach (IntPtr pointer in variableNamePointers)
			{
				variableStringsFound.Clear();
				IntPtr variableBase = game.ReadPointer(pointer);
				int variableCount = game.ReadValue<int>(pointer - (pointerSize + 0x4));

				if (game.ReadBytes(variableBase, pointerSize) != null && variableCount > 0 && variableCount <= 0xFFFFF)
				{
					log("VariableNames: " + hex(pointer) + " = " + hex(variableBase) + ", " + hex(variableCount));
					int variableIndex = 0;

					while (variableIndex <= variableCount)
					{
						IntPtr stringAddress = game.ReadPointer(variableBase + (variableIndex * pointerSize));
						string variableName = game.ReadString(stringAddress, 256);

						if (!String.IsNullOrWhiteSpace(variableName) && variableStrings.Contains(variableName) && !variableStringsFound.Any(x => x.Item1 == variableName))
						{
							variableStringsFound.Add(Tuple.Create(variableName, variableIndex));
							log(variableName + ": " + hex(stringAddress) + ", " + hex(variableIndex));

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
			IEnumerable<IntPtr> globalDataPointers = scanner.ScanAll(pointerTargets["GlobalData"]).Distinct();
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

							if (game.ReadBytes(pointerBase, pointerSize) != null && andOperand > 0 && andOperand <= 0xFFFF && !pointerBasesFound.Any(x => x.Item5 == pointerBase && x.Item6 == andOperand))
							{
								pointerBasesFound.Add(Tuple.Create(pointer, address, offset, searchAddress, pointerBase, andOperand));
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
						// runtime 2.3.0.401 (14-Aug-2020) ...

						int variableIdentifier = elementB.Item2 + 0x186A0;
						int identifierExtension = (0x1 - (0x61C8864F * variableIdentifier)) & 0x7FFFFFFF;
						int result = identifierExtension & elementA.Item6;
						long offset = result * (pointerSize + 0x8);
						IntPtr variablePointer = (IntPtr)((long)elementA.Item5 + offset);
						int identifier = game.ReadValue<int>(variablePointer + pointerSize);
						int extension = game.ReadValue<int>(variablePointer + pointerSize + 0x4);

						// runtime 2.2.1.287 (05-Dec-2018) ... runtime 2.2.5.378 (18-Dec-2019)

						int variableIdentifierOld = elementB.Item2;
						int identifierExtensionOld = (0x1 - (0x61C8864F * variableIdentifierOld)) & 0x7FFFFFFF;
						int resultOld = identifierExtensionOld & elementA.Item6;
						long offsetOld = resultOld * (pointerSize + 0x8);
						IntPtr variablePointerOld = (IntPtr)((long)elementA.Item5 + offsetOld);
						int identifierOld = game.ReadValue<int>(variablePointerOld + pointerSize);
						int extensionOld = game.ReadValue<int>(variablePointerOld + pointerSize + 0x4);

						// runtime 2.1.4.218 (17-May-2018) ... runtime 2.2.0.261 (09-Oct-2018)

						int variableIdentifierOlder = elementB.Item2;
						int identifierExtensionOlder = variableIdentifierOlder + 0x1;
						int resultOlder = identifierExtensionOlder & elementA.Item6;
						long offsetOlder = (resultOlder * (pointerSize + 0x8)) + 0x4;
						IntPtr variablePointerOlder = (IntPtr)((long)elementA.Item5 + offsetOlder);
						int identifierOlder = game.ReadValue<int>(variablePointerOlder - pointerSize);
						int extensionOlder = game.ReadValue<int>(variablePointerOlder + pointerSize);

						IntPtr variableAddress = IntPtr.Zero;
						if (identifier == variableIdentifier && extension == identifierExtension)
						{
							variableAddress = game.ReadPointer(variablePointer);
						}
						else if (identifierOld == variableIdentifierOld && extensionOld == identifierExtensionOld && extensionOld > 0)
						{
							variablePointer = variablePointerOld;
							variableAddress = game.ReadPointer(variablePointer);
						}
						else if (identifierOlder == variableIdentifierOlder && extensionOlder == identifierExtensionOlder)
						{
							variablePointer = variablePointerOlder;
							variableAddress = game.ReadPointer(variablePointer);
						}

						if (variableAddress != IntPtr.Zero)
						{
							// Values are either variableAddress = double, or variableAddress -> address1 -> address2 = string.
							// Note that address1 and address2 may change while the game is running, variableAddress does not.

							double value = game.ReadValue<double>(variableAddress);
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
					IntPtr frameAddress = variablesFound.Where(x => x.Item1 == "playerFrames").Select(x => x.Item2).FirstOrDefault();
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
		if (settings["fpsFix"])
		{
			try
			{
				game.Suspend();

				// Makes the game run at full 60fps regardless of display refresh rate or Windows version.
				// This GameMaker problem was fixed in runtime 2.3.2.420 (30-Mar-2021).

				if (vars.Demo)
				{
					game.WriteBytes((IntPtr)0x77E398, new byte[] { 0xC8, 0x00, 0x00, 0x00 });
				}
				else
				{
					var scanner = new SignatureScanner(game, modules.First().BaseAddress, modules.First().ModuleMemorySize);
					IntPtr sleepMarginPointer = scanner.Scan(pointerTargets["SleepMargin"]);

					if (sleepMarginPointer != IntPtr.Zero)
					{
						game.WriteBytes(sleepMarginPointer, new byte[] { 0xC8, 0x00, 0x00, 0x00 });
					}
					else
					{
						log("Sleep margin not found.");
					}
				}
			}
			finally
			{
				game.Resume();
			}
		}

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

	if (vars.Demo)
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
	       vars.ActionRooms.Contains(current.RoomName) && (!vars.Demo || (vars.Demo && current.RoomName != "room_levelselect")) ||
	       vars.Demo && current.RoomName != old.RoomName && old.RoomName == "room_levelselect";
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

// v0.9.3 11-Sep-2023
