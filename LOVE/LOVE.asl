state("Love") {}

startup
{
	settings.Add("gameTime", true, "Automatically change timing method to Game Time");
	settings.Add("patchLowFPS", false, "Make the game run at full intended FPS");
	settings.SetToolTip("gameTime", "Game Time stays in sync with in-game time");
	settings.SetToolTip("patchLowFPS", "Affects old versions of LOVE");

	vars.ActionRooms = new List<string>
	{
		"controls_room",
		"flap_play_room",
		"flap_start_room",
		"gameselect",
		"levelselect_room",
		"loading",
		"mainmenu",
		"start"
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

		vars.PatchedLowFPS = false;
		vars.Ready = false;
	}
	catch
	{
		throw;
	}

	IntPtr baseAddress = modules.First().BaseAddress;
	long exeMemorySize = modules.First().ModuleMemorySize;
	bool is64bit = game.Is64Bit();
	int pointerSize = is64bit ? 8 : 4;

	string exePath = modules.First().FileName;
	string winPath = new FileInfo(exePath).DirectoryName + @"\data.win";
	long exeSize = new FileInfo(exePath).Length;
	long winSize = new FileInfo(winPath).Exists ? new FileInfo(winPath).Length : 0;

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
			current.RoomName = "";
			IntPtr roomBaseAddress = game.ReadPointer((IntPtr)vars.RoomBaseElement.Item2);

			if (roomBaseAddress != IntPtr.Zero)
			{
				byte[] number = game.ReadBytes((IntPtr)vars.RoomNumberAddress, 4);
				if (number != null)
				{
					int roomNumber = BitConverter.ToInt32(number, 0);
					IntPtr roomNameAddress = game.ReadPointer(roomBaseAddress + (roomNumber * pointerSize));
					string roomName = game.ReadString(roomNameAddress, 256) ?? "";

					if (System.Text.RegularExpressions.Regex.IsMatch(roomName, @"^[a-zA-Z_]+[a-zA-Z0-9_]*$"))
					{
						current.RoomName = roomName.ToLower();
						if (!vars.Ready)
						{
							log("RoomNumber: " + hex(vars.RoomNumberAddress) + " = " + hex(roomNumber));
							log(vars.RoomBaseElement.Item1 + ": " + hex(vars.RoomBaseElement.Item2) + " = " + hex(roomBaseAddress));
							log(hex(roomBaseAddress) + " + (" + hex(roomNumber) + " * " + hex(pointerSize) + ") -> " + hex(roomNameAddress) + " = " + qt(current.RoomName));
						}
					}
				}
			}
		}
		catch
		{
		}
	});

	log(qt(exePath));
	log("exeSize: " + exeSize + ", winSize: " + winSize + ", exeMemorySize: " + hex(exeMemorySize) + ", baseAddress: " + hex(baseAddress) + ", is64bit: " + is64bit);

	vars.CancelSource = new CancellationTokenSource();
	CancellationToken token = vars.CancelSource.Token;

	System.Threading.Tasks.Task.Run(async () =>
	{
		// Resolves global GameMaker variable names to data addresses.
		// For games made with GameMaker: Studio IDE 1.4.1760 (30-Aug-2016) and newer, up until and including the latest GameMaker Studio 2/GameMaker (Zeus) runtime.
		// Does not work with 1.4.1760 YYC or 1.4.1763 YYC (06-Oct-2016).
		// Tested on stable/LTS, VM/YYC 32-bit/64-bit (Windows only), excluding the earliest GameMaker Studio 2 runtimes.
		// Oldest GMS2 runtime I have found/tested is 2.0.6.96 (16-May-2017), but the first stable GMS2 IDE is 2.0.5.76 (07-Mar-2017).

		var targets = new Dictionary<string, SigScanTarget>();
		if (is64bit)
		{
			targets.Add("RoomNumber", new SigScanTarget(6, "48 ?? ?? ?? 3B 35 ?? ?? ?? ?? 41 ?? ?? ?? 49 ?? ?? E8 ?? ?? ?? ?? FF"));
			targets.Add("RoomBase", new SigScanTarget(18, "84 C9 ?? F2 ?? ?? ?? ?? 8D 1C C5 00 00 00 00 ?? 8B"));
			targets.Add("VariableNames", new SigScanTarget(15, "3B 35 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 48 8B 1C E8"));
			targets.Add("GlobalData", new SigScanTarget(20, "BA FF FF FF 00 E8 ?? ?? ?? ?? 48 89 05 ?? ?? ?? ?? 48"));
			targets.Add("SleepMargin", new SigScanTarget(10, "48 8B CE E8 ?? ?? ?? ?? 89 05 ?? ?? ?? ?? EB 2C 48 8D 15 ?? ?? ?? ?? 48 8B ?? E8"));
		}
		else
		{
			targets.Add("RoomNumber", new SigScanTarget(7, "E8 ?? ?? ?? ?? 8B 0D ?? ?? ?? ?? 3B C8 75 1A 6A 01 68 ?? ?? ?? ?? E8"));
			targets.Add("RoomBase", new SigScanTarget(11, "4A 8B 41 FC 89 01 ?? ?? ?? ?? A1 ?? ?? ?? ?? 68 ?? ?? ?? ?? ?? ?? ?? E8"));
			targets.Add("RoomBaseOld", new SigScanTarget(13, "90 8A ?? 88 ?? ?? 40 84 C9 75 F6 8B 0D ?? ?? ?? ?? 8B ?? ?? 85 C0")); // GMS IDE 1.4.1760 ... 1.4.9999 VM/YYC
			targets.Add("VariableNames", new SigScanTarget(1, "A3 ?? ?? ?? ?? C7 05 ?? ?? ?? ?? 08 00 00 00 E8 ?? ?? ?? ?? 83 C4 18 C3 CC"));
			targets.Add("VariableNamesOld", new SigScanTarget(14, "68 ?? ?? ?? ?? 8D 04 ?? 00 00 00 00 50 68 ?? ?? ?? ?? E8 ?? ?? ?? ?? 89 35")); // GMS IDE 1.4.1760, 1.4.1763 VM
			targets.Add("GlobalData", new SigScanTarget(4, "55 56 8B 35 ?? ?? ?? ?? ?? ?? ?? 85 F6 0F 84 ?? 00 00 00"));
			targets.Add("SleepMargin", new SigScanTarget(11, "8B ?? E8 ?? ?? ?? ?? 83 C4 0C A3 ?? ?? ?? ?? C6 05 ?? ?? ?? ?? 01 E9 ?? ?? ?? ?? B9"));
		}

		foreach (KeyValuePair<string, SigScanTarget> target in targets.Where(x => !x.Key.StartsWith("VariableNames") && x.Key != "GlobalData"))
		{
			target.Value.OnFound = (proc, scan, address) => is64bit ? address + 0x4 + proc.ReadValue<int>(address) : proc.ReadPointer(address);
		}

		scan_start:;
		while (!token.IsCancellationRequested)
		{
			log("Scanning for current room name..");

			var scanner = new SignatureScanner(game, modules.First().BaseAddress, modules.First().ModuleMemorySize);
			IEnumerable<IntPtr> roomNumberAddresses = scanner.ScanAll(targets["RoomNumber"]).Distinct();
			IEnumerable<IntPtr> a = scanner.ScanAll(targets["RoomBase"]).Distinct();
			IEnumerable<IntPtr> b = !is64bit ? scanner.ScanAll(targets["RoomBaseOld"]).Distinct() : Enumerable.Empty<IntPtr>();

			var roomBasePointers = new List<Tuple<string, IntPtr>>();
			foreach (IntPtr pointer in a)
			{
				roomBasePointers.Add(Tuple.Create("RoomBase", pointer));
			}

			foreach (IntPtr pointer in b)
			{
				roomBasePointers.Add(Tuple.Create("RoomBaseOld", pointer));
			}

			foreach (Tuple<string, IntPtr> element in roomBasePointers)
			{
				vars.RoomBaseElement = element;
				foreach (IntPtr address in roomNumberAddresses)
				{
					vars.RoomNumberAddress = address;
					vars.RoomName();

					if (current.RoomName != "")
					{
						goto room_name_found;
					}
				}
			}

			log("Room name not found.");
			await System.Threading.Tasks.Task.Delay(2000, token);
			continue;

			room_name_found:;
			break;
		}

		while (!token.IsCancellationRequested)
		{
			log("Scanning for global variable names..");

			string[] variableNames = { "playerTimer", /* "gameType", "playerSpawns" */ };

			var scanner = new SignatureScanner(game, modules.First().BaseAddress, modules.First().ModuleMemorySize);
			IEnumerable<IntPtr> a = scanner.ScanAll(targets["VariableNames"]);
			IEnumerable<IntPtr> b = !is64bit ? scanner.ScanAll(targets["VariableNamesOld"]) : Enumerable.Empty<IntPtr>();

			var variableBasePointers = new List<Tuple<string, IntPtr, IntPtr, int>>();
			foreach (IntPtr address in a)
			{
				IntPtr variableBasePointer = is64bit ? address + 0x4 + game.ReadValue<int>(address) : game.ReadPointer(address);
				IntPtr variableCountAddress = is64bit ? (address - 0xD) + 0x4 + game.ReadValue<int>(address - 0xD) : game.ReadPointer(address + 0x6);
				long offset = (long)variableBasePointer - (long)variableCountAddress;
				int count = game.ReadValue<int>(variableCountAddress);

				if ((is64bit && offset == 0x10 || !is64bit && offset == 0xC) && count > 0 && count <= 0xFFFF)
				{
					Tuple<string, IntPtr, IntPtr, int> element = Tuple.Create("VariableNames", variableBasePointer, variableCountAddress, count);
					if (!variableBasePointers.Any(x => x.Item1 == "VariableNames" && x.Item2 == variableBasePointer))
					{
						variableBasePointers.Add(element);
					}
				}
			}

			foreach (IntPtr address in b)
			{
				IntPtr variableBasePointer = game.ReadPointer(address);
				IntPtr variableCountAddress = game.ReadPointer(address + 0xB);
				long offset = (long)variableCountAddress - (long)variableBasePointer;
				int count = game.ReadValue<int>(variableCountAddress);

				if (offset == 0x4 && count > 0 && count <= 0xFFFF)
				{
					Tuple<string, IntPtr, IntPtr, int> element = Tuple.Create("VariableNamesOld", variableBasePointer, variableCountAddress, count);
					if (!variableBasePointers.Any(x => x.Item1 == "VariableNamesOld" && x.Item2 == variableBasePointer))
					{
						variableBasePointers.Add(element);
					}
				}
			}

			var variableNamesFound = new List<Tuple<string, int>>();
			foreach (Tuple<string, IntPtr, IntPtr, int> element in variableBasePointers)
			{
				variableNamesFound.Clear();
				IntPtr variableBaseAddress = game.ReadPointer(element.Item2);
				log(element.Item1 + ": " + hex(element.Item2) + " = " + hex(variableBaseAddress) + ", " + hex(element.Item3) + " = " + hex(element.Item4));

				int variableIndex = variableBaseAddress == IntPtr.Zero ? int.MaxValue : 0;
				while (variableIndex <= element.Item4)
				{
					IntPtr variableNameAddress = game.ReadPointer(variableBaseAddress + (variableIndex * pointerSize));
					string variableName = game.ReadString(variableNameAddress, 256);

					if (!string.IsNullOrWhiteSpace(variableName) && variableNames.Contains(variableName))
					{
						string duplicate = "";
						if (variableNamesFound.Any(x => x.Item1 == variableName))
						{
							duplicate = " (duplicate, ignored)";
						}
						else
						{
							variableNamesFound.Add(Tuple.Create(variableName, variableIndex));
						}

						log(hex(variableBaseAddress) + " + (" + hex(variableIndex) + " * " + hex(pointerSize) + ") -> " + hex(variableNameAddress) + " = " + qt(variableName) + duplicate);
					}

					variableIndex++;
				}

				log("variableNamesFound: " + variableNamesFound.Count + "/" + variableNames.Distinct().Count());

				if (variableNamesFound.Count == variableNames.Distinct().Count() && variableNamesFound.Count > 0)
				{
					goto variable_names_found;
				}
			}

			if (variableBasePointers.Count == 0)
			{
				log("Variable base not found.");
			}

			await System.Threading.Tasks.Task.Delay(2000, token);
			goto scan_start;

			variable_names_found:;
			vars.VariableNamesFound = variableNamesFound;
			break;
		}

		while (!token.IsCancellationRequested)
		{
			log("Scanning for global variable addresses..");

			var scanner = new SignatureScanner(game, modules.First().BaseAddress, modules.First().ModuleMemorySize);
			IEnumerable<IntPtr> globalDataResults = scanner.ScanAll(targets["GlobalData"]).Distinct();

			var pointerBasesFound = new List<Tuple<IntPtr, IntPtr, int, IntPtr, IntPtr, int>>();
			foreach (IntPtr address in globalDataResults)
			{
				IntPtr searchBasePrimaryPointer = is64bit ? address + 0x4 + game.ReadValue<int>(address) : game.ReadPointer(address);
				IntPtr searchBasePrimaryAddress = game.ReadPointer(searchBasePrimaryPointer);
				IntPtr searchBaseSecondaryPointer = is64bit ? (address - 0x7) + 0x4 + game.ReadValue<int>(address - 0x7) : IntPtr.Zero;
				IntPtr searchBaseSecondaryAddress = is64bit ? game.ReadPointer(searchBaseSecondaryPointer) : IntPtr.Zero;

				var searchBasesFound = new List<Tuple<IntPtr, IntPtr>>();
				if (searchBasePrimaryAddress != IntPtr.Zero && !searchBasesFound.Any(x => x.Item2 == searchBasePrimaryAddress))
				{
					searchBasesFound.Add(Tuple.Create(searchBasePrimaryPointer, searchBasePrimaryAddress));
				}

				if (searchBaseSecondaryAddress != IntPtr.Zero && !searchBasesFound.Any(x => x.Item2 == searchBaseSecondaryAddress))
				{
					searchBasesFound.Add(Tuple.Create(searchBaseSecondaryPointer, searchBaseSecondaryAddress));
				}

				foreach (Tuple<IntPtr, IntPtr> element in searchBasesFound)
				{
					int offset = pointerSize;
					while (pointerBasesFound.Where(x => x.Item2 == element.Item2).Count() < 4 && offset <= 0xFFFF)
					{
						IntPtr pointerBasePointer = game.ReadPointer(element.Item2 + offset);
						if (pointerBasePointer != IntPtr.Zero)
						{
							IntPtr pointerBaseAddress = game.ReadPointer(pointerBasePointer + 0x10);
							int andOperand = game.ReadBytes(pointerBaseAddress, pointerSize) != null ? game.ReadValue<int>(pointerBasePointer + 0x8) : 0;

							if (andOperand > 0 && andOperand <= 0xFFFF && !pointerBasesFound.Any(x => x.Item5 == pointerBaseAddress && x.Item6 == andOperand))
							{
								pointerBasesFound.Add(Tuple.Create(element.Item1, element.Item2, offset, pointerBasePointer, pointerBaseAddress, andOperand));
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
			goto scan_start;
		}

		if (!token.IsCancellationRequested)
		{
			var variableAddressesFound = new List<Tuple<string, IntPtr>>();
			foreach (Tuple<IntPtr, IntPtr, int, IntPtr, IntPtr, int> elementA in vars.PointerBasesFound)
			{
				variableAddressesFound.Clear();
				string a = "GlobalData: " + hex(elementA.Item1) + " -> " + hex(elementA.Item2) + " + " + hex(elementA.Item3) + " -> ";
				string b = hex(elementA.Item4) + " + 0x10 = " + hex(elementA.Item5) + ", " + hex(elementA.Item4) + " + 0x8 = " + hex(elementA.Item6);
				log(a + b);

				foreach (Tuple<string, int> elementB in vars.VariableNamesFound)
				{
					try
					{
						// GM runtime 2023.11.0.157 (04-Dec-2023) ...

						int variableIdentifierD = elementB.Item2 + 0x186A0;
						int identifierExtensionD = variableIdentifierD + 0x1;
						int resultD = identifierExtensionD & elementA.Item6;
						long offsetD = resultD * (pointerSize + 0x8);
						IntPtr variablePointerD = (IntPtr)((long)elementA.Item5 + offsetD);
						int identifierD = game.ReadValue<int>(variablePointerD + pointerSize);
						int extensionD = game.ReadValue<int>(variablePointerD + pointerSize + 0x4);

						// GMS2 runtime 2.3.0.401 (14-Aug-2020) ... GM runtime 2023.8.2.152 (06-Oct-2023)

						int variableIdentifierC = elementB.Item2 + 0x186A0;
						int identifierExtensionC = (0x1 - (0x61C8864F * variableIdentifierC)) & 0x7FFFFFFF;
						int resultC = identifierExtensionC & elementA.Item6;
						long offsetC = resultC * (pointerSize + 0x8);
						IntPtr variablePointerC = (IntPtr)((long)elementA.Item5 + offsetC);
						int identifierC = game.ReadValue<int>(variablePointerC + pointerSize);
						int extensionC = game.ReadValue<int>(variablePointerC + pointerSize + 0x4);

						// GMS2 runtime 2.2.1.287 (05-Dec-2018) ... 2.2.5.378 (18-Dec-2019)

						int variableIdentifierB = elementB.Item2;
						int identifierExtensionB = (0x1 - (0x61C8864F * variableIdentifierB)) & 0x7FFFFFFF;
						int resultB = identifierExtensionB & elementA.Item6;
						long offsetB = resultB * (pointerSize + 0x8);
						IntPtr variablePointerB = (IntPtr)((long)elementA.Item5 + offsetB);
						int identifierB = game.ReadValue<int>(variablePointerB + pointerSize);
						int extensionB = game.ReadValue<int>(variablePointerB + pointerSize + 0x4);

						// GMS IDE 1.4.1760 (30-Aug-2016) ... GMS2 runtime 2.2.0.261 (09-Oct-2018)

						int variableIdentifierA = elementB.Item2;
						int identifierExtensionA = variableIdentifierA + 0x1;
						int resultA = identifierExtensionA & elementA.Item6;
						long offsetA = (resultA * (pointerSize + 0x8)) + 0x4;
						IntPtr variablePointerA = (IntPtr)((long)elementA.Item5 + offsetA);
						int identifierA = game.ReadValue<int>(variablePointerA - pointerSize);
						int extensionA = game.ReadValue<int>(variablePointerA + pointerSize);

						string gameMakerGroup = "";
						IntPtr variablePointer = IntPtr.Zero;
						IntPtr variableAddress = IntPtr.Zero;

						if (variableIdentifierD == identifierD && identifierExtensionD == extensionD)
						{
							gameMakerGroup = " (D)";
							variablePointer = variablePointerD;
							variableAddress = game.ReadPointer(variablePointerD);
						}
						else if (variableIdentifierC == identifierC && identifierExtensionC == extensionC)
						{
							gameMakerGroup = " (C)";
							variablePointer = variablePointerC;
							variableAddress = game.ReadPointer(variablePointerC);
						}
						else if (variableIdentifierB == identifierB && identifierExtensionB == extensionB)
						{
							gameMakerGroup = " (B)";
							variablePointer = variablePointerB;
							variableAddress = game.ReadPointer(variablePointerB);
						}
						else if (variableIdentifierA == identifierA && identifierExtensionA == extensionA)
						{
							gameMakerGroup = " (A)";
							variablePointer = variablePointerA;
							variableAddress = game.ReadPointer(variablePointerA);
						}

						if (variableAddress != IntPtr.Zero)
						{
							// Values are either variableAddress = double, or variableAddress -> stringPointer -> stringAddress = string.
							// Note that stringPointer and stringAddress may change while the game is running, variableAddress does not.

							double value = game.ReadValue<double>(variableAddress);
							if (!value.ToString().Any(char.IsLetter) && value.ToString().Length <= 12)
							{
								log(qt(elementB.Item1) + " -> " + hex(variablePointer) + " -> " + hex(variableAddress) + " = <double>" + value + gameMakerGroup);
							}
							else
							{
								IntPtr stringPointer = game.ReadPointer(variableAddress);
								IntPtr stringAddress = game.ReadPointer(stringPointer);
								string stringValue = game.ReadString(stringAddress, 256);

								string c = qt(elementB.Item1) + " -> " + hex(variablePointer) + " -> " + hex(variableAddress) + " -> ";
								string d = hex(stringPointer) + " -> " + hex(stringAddress) + " = " + qt(stringValue) + gameMakerGroup;
								log(c + d);
							}

							variableAddressesFound.Add(Tuple.Create(elementB.Item1, variableAddress));
						}
					}
					catch
					{
					}
				}

				log("variableAddressesFound: " + variableAddressesFound.Count + "/" + vars.VariableNamesFound.Count);

				if (variableAddressesFound.Count == vars.VariableNamesFound.Count)
				{
					IntPtr frameAddress = variableAddressesFound.Where(x => x.Item1 == "playerTimer").Select(x => x.Item2).FirstOrDefault();
					vars.RoomNumber = new MemoryWatcher<int>(vars.RoomNumberAddress);
					vars.FrameCount = new MemoryWatcher<double>(frameAddress);
					goto ready;
				}
			}

			await System.Threading.Tasks.Task.Delay(2000, token);
			goto scan_start;
		}

		goto task_end;

		ready:;
		vars.PatchLowFPS = (Action)(() =>
		{
			// Makes the game run at full intended frame rate regardless of display refresh rate or Windows version.
			// Increases sleep margin value. It doesn't fix the actual underlying problem, but has essentially the same outcome (full FPS).
			// Affects all (?) versions up until and including GMS2 runtime 2.3.1.409 (16-Dec-2020).
			// This GameMaker problem was fixed in GMS2 runtime 2.3.2.420 (30-Mar-2021).

			try
			{
				game.Suspend();

				var scanner = new SignatureScanner(game, modules.First().BaseAddress, modules.First().ModuleMemorySize);
				IntPtr sleepMarginAddress = scanner.Scan(targets["SleepMargin"]);
				byte[] value = game.ReadBytes(sleepMarginAddress, 4);

				if (value != null)
				{
					int sleepMarginNewValue = 200;
					int sleepMarginPreviousValue = BitConverter.ToInt32(value, 0);
					game.WriteBytes(sleepMarginAddress, BitConverter.GetBytes(sleepMarginNewValue));
					log("Sleep margin patched. " + hex(sleepMarginAddress) + " = <int>" + sleepMarginPreviousValue + " -> " + sleepMarginNewValue);
				}
				else
				{
					log("Sleep margin not found.");
				}
			}
			finally
			{
				vars.PatchedLowFPS = true;
				game.Resume();
			}
		});

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
		vars.Log("current.RoomName: " + vars.Qt(current.RoomName) + " [" + vars.RoomNumber.Current + "]");
	}

	if (!vars.PatchedLowFPS && settings["patchLowFPS"])
	{
		vars.PatchLowFPS();
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

// v0.9.6 12-Dec-2023
