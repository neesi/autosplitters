state("Love") {}
state("LOVE-Classic") {}

startup
{
	settings.Add("gameTime", true, "Automatically change timing method to Game Time");
	settings.Add("patchLowFPS", false, "Make the game run at full intended FPS");
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
		var ordinalIgnoreCase = StringComparison.OrdinalIgnoreCase;

		if (!vars.GameExe.EndsWith(".exe", ordinalIgnoreCase))
		{
			throw new Exception("Game not loaded yet.");
		}

		vars.FPS = game.ProcessName.Equals("LOVE-Classic", ordinalIgnoreCase) ? 30.0d : 60.0d;
		vars.PatchedLowFPS = false;
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

	var log = vars.Log = (Action<object>)(input =>
	{
		print("[" + vars.GameExe + "] " + input);
	});

	var qt = vars.Qt = (Func<object, string>)(input =>
	{
		input = input != null ? input.ToString().Split('\0')[0] : "";
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

	vars.CancelSource = new CancellationTokenSource();
	CancellationToken token = vars.CancelSource.Token;

	System.Threading.Tasks.Task.Run(async () =>
	{
		// Resolves global GameMaker variable names to data addresses. Finds the current room name.
		// For games made with GameMaker: Studio IDE 1.4.1760 (30-Aug-2016) and newer, up until and including the latest GameMaker Studio 2/GameMaker (Zeus) runtime.
		// Does not work with 1.4.1760 YYC or 1.4.1763 YYC (06-Oct-2016).
		// Tested on stable/LTS, VM/YYC 32-bit/64-bit (Windows only), excluding the earliest GameMaker Studio 2 runtimes.
		// Oldest GMS2 runtime I have found/tested is 2.0.6.96 (16-May-2017), but the first stable GMS2 IDE is 2.0.5.76 (07-Mar-2017).

		string[] variableTargets = { "playerTimer", /* "playerSpawns", "gameType" */ };

		var signatureTargets = new Dictionary<string, SigScanTarget>();
		if (is64bit)
		{
			signatureTargets.Add("RoomNumber", new SigScanTarget(6, "48 0F ?? ?? 3B ?? ?? ?? ?? ?? 41 0F 94 ?? ?? ?? ?? E8 ?? ?? ?? ?? FF"));
			signatureTargets.Add("RoomBase", new SigScanTarget(10, "8D 1C C5 00 00 00 00 ?? 8B ?? ?? ?? ?? ?? 48 ?? ?? ?? 48 ?? ?? 74"));
			signatureTargets.Add("VariableNames", new SigScanTarget(15, "3B 35 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 48 8B 1C E8"));
			signatureTargets.Add("GlobalData", new SigScanTarget(16, "BA FF FF FF 00 E8 ?? ?? ?? ?? 48 ?? ?? 48 89 05 ?? ?? ?? ?? 48"));
			signatureTargets.Add("GlobalDataOld", new SigScanTarget(13, "BA FF FF FF 00 E8 ?? ?? ?? ?? 48 89 05 ?? ?? ?? ?? 48"));
			signatureTargets.Add("SleepMargin", new SigScanTarget(10, "48 8B CE E8 ?? ?? ?? ?? 89 05 ?? ?? ?? ?? EB 2C 48 8D 15 ?? ?? ?? ?? 48 8B ?? E8"));
		}
		else
		{
			signatureTargets.Add("RoomNumber", new SigScanTarget(7, "E8 ?? ?? ?? ?? 8B 0D ?? ?? ?? ?? 3B C8 75 1A 6A 01 68 ?? ?? ?? ?? E8"));
			signatureTargets.Add("RoomBase", new SigScanTarget(11, "4A 8B 41 FC 89 01 ?? ?? ?? ?? A1 ?? ?? ?? ?? 68 ?? ?? ?? ?? ?? ?? ?? E8"));
			signatureTargets.Add("RoomBaseOld", new SigScanTarget(13, "90 8A ?? 88 ?? ?? 40 84 C9 75 F6 8B 0D ?? ?? ?? ?? 8B ?? ?? 85 C0")); // GMS IDE 1.4.1760 ... 1.4.9999 VM/YYC (04-Oct-2018)
			signatureTargets.Add("VariableNames", new SigScanTarget(1, "A3 ?? ?? ?? ?? C7 05 ?? ?? ?? ?? 08 00 00 00 E8 ?? ?? ?? ?? 83 C4 18 C3 CC"));
			signatureTargets.Add("VariableNamesOld", new SigScanTarget(14, "68 ?? ?? ?? ?? 8D 04 ?? 00 00 00 00 50 68 ?? ?? ?? ?? E8 ?? ?? ?? ?? 89 35")); // GMS IDE 1.4.1760, 1.4.1763 VM
			signatureTargets.Add("GlobalData", new SigScanTarget(4, "55 56 8B 35 ?? ?? ?? ?? ?? ?? ?? 85 F6 0F 84 ?? 00 00 00"));
			signatureTargets.Add("SleepMargin", new SigScanTarget(11, "8B ?? E8 ?? ?? ?? ?? 83 C4 0C A3 ?? ?? ?? ?? C6 05 ?? ?? ?? ?? 01 E9 ?? ?? ?? ?? B9"));
		}

		foreach (KeyValuePair<string, SigScanTarget> target in signatureTargets.Where(x => !x.Key.StartsWith("VariableNames") && !x.Key.StartsWith("GlobalData")))
		{
			target.Value.OnFound = (proc, scan, result) => is64bit ? result + 0x4 + proc.ReadValue<int>(result) : proc.ReadPointer(result);
		}

		scan_start:;

		IntPtr exeBaseAddress = modules.First().BaseAddress;
		int exeMemorySize = modules.First().ModuleMemorySize;
		int variableTargetsCount = variableTargets.Distinct().Count();
		var scanner = new SignatureScanner(game, exeBaseAddress, exeMemorySize);

		log(qt(exePath));
		log("exeSize: " + exeSize + ", winSize: " + winSize + ", exeMemorySize: " + hex(exeMemorySize) + ", exeBaseAddress: " + hex(exeBaseAddress) + ", is64bit: " + is64bit);

		log("Scanning for current room name..");

		var roomBasePointers = new List<Tuple<string, IntPtr>>();
		foreach (IntPtr pointer in scanner.ScanAll(signatureTargets["RoomBase"]).Distinct())
		{
			roomBasePointers.Add(Tuple.Create("RoomBase", pointer));
		}

		if (!is64bit)
		{
			foreach (IntPtr pointer in scanner.ScanAll(signatureTargets["RoomBaseOld"]).Distinct())
			{
				roomBasePointers.Add(Tuple.Create("RoomBaseOld", pointer));
			}
		}

		IEnumerable<IntPtr> roomNumberAddresses = scanner.ScanAll(signatureTargets["RoomNumber"]).Distinct();
		foreach (var element in roomBasePointers)
		{
			string signatureTargetName = element.Item1;
			IntPtr roomBasePointer = element.Item2;

			foreach (IntPtr roomNumberAddress in roomNumberAddresses)
			{
				vars.RoomName = (Action)(() =>
				{
					try
					{
						current.RoomName = "";
						IntPtr roomBaseAddress = game.ReadPointer(roomBasePointer);

						if (roomBaseAddress != IntPtr.Zero)
						{
							byte[] number = game.ReadBytes(roomNumberAddress, 4);
							if (number != null)
							{
								int roomNumber = BitConverter.ToInt32(number, 0);
								IntPtr roomNameAddress = game.ReadPointer(roomBaseAddress + (roomNumber * pointerSize));
								string roomName = game.ReadString(roomNameAddress, 256) ?? "";

								if (System.Text.RegularExpressions.Regex.IsMatch(roomName, @"^[a-zA-Z_]+[a-zA-Z0-9_]*$"))
								{
									current.RoomName = roomName.ToLowerInvariant();
									if (!vars.Ready)
									{
										log("RoomNumber: " + hex(roomNumberAddress) + " = " + hex(roomNumber));
										log(signatureTargetName + ": " + hex(roomBasePointer) + " = " + hex(roomBaseAddress));
										log(hex(roomBaseAddress) + " + (" + hex(roomNumber) + " * " + hex(pointerSize) + ") -> " +
										hex(roomNameAddress) + " = " + qt(current.RoomName));
									}
								}
							}
						}
					}
					catch
					{
					}
				});

				vars.RoomName();
				if (current.RoomName != "")
				{
					vars.RoomNumberAddress = roomNumberAddress;
					goto room_name_found;
				}
			}
		}

		log("Room name not found.");
		await System.Threading.Tasks.Task.Delay(2000, token);
		goto scan_start;

		room_name_found:;

		log("Scanning for global variable names..");

		var variableNamesBasesFound = new List<Tuple<string, IntPtr, IntPtr, int>>();
		foreach (IntPtr result in scanner.ScanAll(signatureTargets["VariableNames"]))
		{
			IntPtr variableNamesBasePointer, variableNamesCountAddress;
			if (is64bit)
			{
				variableNamesBasePointer = result + 0x4 + game.ReadValue<int>(result);
				variableNamesCountAddress = (result - 0xD) + 0x4 + game.ReadValue<int>(result - 0xD);
			}
			else
			{
				variableNamesBasePointer = game.ReadPointer(result);
				variableNamesCountAddress = game.ReadPointer(result + 0x6);
			}

			int variableNamesCount = game.ReadValue<int>(variableNamesCountAddress);
			long offset = (long)variableNamesBasePointer - (long)variableNamesCountAddress;

			if (variableNamesCount > 0 && variableNamesCount <= 0xFFFF && (is64bit && (offset == 0x8 || offset == 0x10) || !is64bit && offset == 0xC))
			{
				if (!variableNamesBasesFound.Any(x => x.Item1 == "VariableNames" && x.Item2 == variableNamesBasePointer))
				{
					variableNamesBasesFound.Add(Tuple.Create("VariableNames", variableNamesBasePointer, variableNamesCountAddress, variableNamesCount));
				}
			}
		}

		if (!is64bit)
		{
			foreach (IntPtr result in scanner.ScanAll(signatureTargets["VariableNamesOld"]))
			{
				IntPtr variableNamesBasePointer = game.ReadPointer(result);
				IntPtr variableNamesCountAddress = game.ReadPointer(result + 0xB);
				int variableNamesCount = game.ReadValue<int>(variableNamesCountAddress);
				long offset = (long)variableNamesCountAddress - (long)variableNamesBasePointer;

				if (variableNamesCount > 0 && variableNamesCount <= 0xFFFF && offset == 0x4)
				{
					if (!variableNamesBasesFound.Any(x => x.Item1 == "VariableNamesOld" && x.Item2 == variableNamesBasePointer))
					{
						variableNamesBasesFound.Add(Tuple.Create("VariableNamesOld", variableNamesBasePointer, variableNamesCountAddress, variableNamesCount));
					}
				}
			}
		}

		if (variableNamesBasesFound.Count == 0)
		{
			log("Name base not found.");
			await System.Threading.Tasks.Task.Delay(2000, token);
			goto scan_start;
		}

		var variableNamesFoundLists = new List<List<Tuple<IntPtr, int, IntPtr, string>>>();
		foreach (var element in variableNamesBasesFound)
		{
			string signatureTargetName = element.Item1;
			IntPtr variableNamesBasePointer = element.Item2;
			IntPtr variableNamesCountAddress = element.Item3;
			int variableNamesCount = element.Item4;

			IntPtr variableNamesBaseAddress = game.ReadPointer(variableNamesBasePointer);
			int variableNameIndex = variableNamesBaseAddress == IntPtr.Zero ? int.MaxValue : 0;

			log(signatureTargetName + ": " + hex(variableNamesBasePointer) + " = " + hex(variableNamesBaseAddress) + ", " +
			hex(variableNamesCountAddress) + " = " + hex(variableNamesCount));

			if (variableTargetsCount > 0)
			{
				var variableNamesFound = new List<Tuple<IntPtr, int, IntPtr, string>>();
				while (variableNameIndex < variableNamesCount)
				{
					IntPtr variableNameAddress = game.ReadPointer(variableNamesBaseAddress + (variableNameIndex * pointerSize));
					string variableName = game.ReadString(variableNameAddress, 256);

					if (!string.IsNullOrWhiteSpace(variableName) && variableTargets.Contains(variableName))
					{
						variableNamesFound.Add(Tuple.Create(variableNamesBaseAddress, variableNameIndex, variableNameAddress, variableName));

						log(hex(variableNamesBaseAddress) + " + (" + hex(variableNameIndex) + " * " + hex(pointerSize) + ") -> " +
						hex(variableNameAddress) + " = " + qt(variableName));
					}

					variableNameIndex++;
				}

				int variableNamesFoundCount = variableNamesFound.Select(x => x.Item4).Distinct().Count();
				if (!variableNamesFoundLists.Any(x => x.SequenceEqual(variableNamesFound)) && variableNamesFoundCount == variableTargetsCount)
				{
					variableNamesFoundLists.Add(variableNamesFound);
				}

				log("variableNamesFound: " + variableNamesFoundCount + "/" + variableTargetsCount);
			}
		}

		log("Scanning for global variable addresses..");

		IEnumerable<IntPtr> globalDataResults = scanner.ScanAll(signatureTargets["GlobalData"]);
		if (is64bit)
		{
			globalDataResults = globalDataResults.Union(scanner.ScanAll(signatureTargets["GlobalDataOld"]));
		}

		var pointerBasesFound = new List<Tuple<IntPtr, IntPtr, int, IntPtr, IntPtr, int>>();
		foreach (IntPtr result in globalDataResults)
		{
			IntPtr searchBaseFirstPointer, searchBaseFirstAddress, searchBaseSecondPointer, searchBaseSecondAddress;
			if (is64bit)
			{
				searchBaseFirstPointer = result + 0x4 + game.ReadValue<int>(result);
				searchBaseFirstAddress = game.ReadPointer(searchBaseFirstPointer);
				searchBaseSecondPointer = (result + 0x7) + 0x4 + game.ReadValue<int>(result + 0x7);
				searchBaseSecondAddress = game.ReadPointer(searchBaseSecondPointer);
			}
			else
			{
				searchBaseFirstPointer = game.ReadPointer(result);
				searchBaseFirstAddress = game.ReadPointer(searchBaseFirstPointer);
				searchBaseSecondPointer = IntPtr.Zero;
				searchBaseSecondAddress = IntPtr.Zero;
			}

			var searchBasesFound = new List<Tuple<IntPtr, IntPtr>>();
			if (searchBaseFirstAddress != IntPtr.Zero && !searchBasesFound.Any(x => x.Item2 == searchBaseFirstAddress))
			{
				searchBasesFound.Add(Tuple.Create(searchBaseFirstPointer, searchBaseFirstAddress));
			}

			if (searchBaseSecondAddress != IntPtr.Zero && !searchBasesFound.Any(x => x.Item2 == searchBaseSecondAddress))
			{
				searchBasesFound.Add(Tuple.Create(searchBaseSecondPointer, searchBaseSecondAddress));
			}

			foreach (var element in searchBasesFound)
			{
				IntPtr searchBasePointer = element.Item1;
				IntPtr searchBaseAddress = element.Item2;

				int searchBaseOffset = pointerSize;
				while (pointerBasesFound.Where(x => x.Item2 == searchBaseAddress).Count() < 4 && searchBaseOffset <= 0x3FF)
				{
					IntPtr pointerBasePointer = game.ReadPointer(searchBaseAddress + searchBaseOffset);
					if (pointerBasePointer != IntPtr.Zero)
					{
						IntPtr pointerBaseAddress = game.ReadPointer(pointerBasePointer + 0x10);
						int andOperand = game.ReadBytes(pointerBaseAddress, pointerSize) != null ? game.ReadValue<int>(pointerBasePointer + 0x8) : 0;

						if (andOperand > 0 && andOperand <= 0xFFFF && !pointerBasesFound.Any(x => x.Item5 == pointerBaseAddress && x.Item6 == andOperand))
						{
							pointerBasesFound.Add(Tuple.Create(searchBasePointer, searchBaseAddress, searchBaseOffset, pointerBasePointer, pointerBaseAddress, andOperand));
						}
					}

					searchBaseOffset += pointerSize;
				}
			}
		}

		if (pointerBasesFound.Count == 0)
		{
			log("Pointer base not found.");
			await System.Threading.Tasks.Task.Delay(2000, token);
			goto scan_start;
		}

		foreach (var element in pointerBasesFound)
		{
			IntPtr searchBasePointer = element.Item1;
			IntPtr searchBaseAddress = element.Item2;
			int searchBaseOffset = element.Item3;
			IntPtr pointerBasePointer = element.Item4;
			IntPtr pointerBaseAddress = element.Item5;
			int andOperand = element.Item6;

			log("GlobalData: " + hex(searchBasePointer) + " -> " + hex(searchBaseAddress) + " + " + hex(searchBaseOffset) + " -> " +
			hex(pointerBasePointer) + " + 0x10 = " + hex(pointerBaseAddress) + ", " + hex(pointerBasePointer) + " + 0x8 = " + hex(andOperand));

			foreach (var list in variableNamesFoundLists)
			{
				var variableAddressesFound = new List<Tuple<string, IntPtr>>();
				foreach (var variableTarget in list)
				{
					IntPtr variableNamesBaseAddress = vars.VariableNamesBaseAddress = variableTarget.Item1;
					int variableNameIndex = variableTarget.Item2;
					IntPtr variableNameAddress = variableTarget.Item3;
					string variableName = variableTarget.Item4;

					try
					{
						// GM runtime 2023.11.0.157 (04-Dec-2023) ...

						int variableIdentifierD = variableNameIndex + 0x186A0;
						int identifierExtensionD = variableIdentifierD + 0x1;
						int resultD = identifierExtensionD & andOperand;
						int offsetD = checked(resultD * (pointerSize + 0x8));
						IntPtr variablePointerD = checked(pointerBaseAddress + offsetD);
						int identifierD = game.ReadValue<int>(variablePointerD + pointerSize);
						int extensionD = game.ReadValue<int>(variablePointerD + pointerSize + 0x4);

						// GMS2 runtime 2.3.0.401 (14-Aug-2020) ... GM runtime 2023.8.2.152 (06-Oct-2023)

						int variableIdentifierC = variableNameIndex + 0x186A0;
						int identifierExtensionC = (0x1 - (0x61C8864F * variableIdentifierC)) & 0x7FFFFFFF;
						int resultC = identifierExtensionC & andOperand;
						int offsetC = checked(resultC * (pointerSize + 0x8));
						IntPtr variablePointerC = checked(pointerBaseAddress + offsetC);
						int identifierC = game.ReadValue<int>(variablePointerC + pointerSize);
						int extensionC = game.ReadValue<int>(variablePointerC + pointerSize + 0x4);

						// GMS2 runtime 2.2.1.287 (05-Dec-2018) ... 2.2.5.378 (18-Dec-2019)

						int variableIdentifierB = variableNameIndex;
						int identifierExtensionB = (0x1 - (0x61C8864F * variableIdentifierB)) & 0x7FFFFFFF;
						int resultB = identifierExtensionB & andOperand;
						int offsetB = checked(resultB * (pointerSize + 0x8));
						IntPtr variablePointerB = checked(pointerBaseAddress + offsetB);
						int identifierB = game.ReadValue<int>(variablePointerB + pointerSize);
						int extensionB = game.ReadValue<int>(variablePointerB + pointerSize + 0x4);

						// GMS IDE 1.4.1760 (30-Aug-2016) ... GMS2 runtime 2.2.0.261 (09-Oct-2018)

						int variableIdentifierA = variableNameIndex;
						int identifierExtensionA = variableIdentifierA + 0x1;
						int resultA = identifierExtensionA & andOperand;
						int offsetA = checked((resultA * (pointerSize + 0x8)) + 0x4);
						IntPtr variablePointerA = checked(pointerBaseAddress + offsetA);
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
							Tuple<string, IntPtr> variable = Tuple.Create(variableName, variableAddress);
							string ifDuplicateFound = "";

							if (variableAddressesFound.Contains(variable))
							{
								ifDuplicateFound = " (duplicate, ignored)";
							}
							else
							{
								variableAddressesFound.Add(variable);
							}

							// Values are either variableAddress = double, or variableAddress -> stringPointer -> stringAddress = string.
							// Note that stringPointer and stringAddress may change while the game is running, variableAddress does not.

							double value = game.ReadValue<double>(variableAddress);
							if (!value.ToString().Any(char.IsLetter) && value.ToString().Length <= 12)
							{
								log(hex(variableNameAddress) + " = " + qt(variableName) + " -> " + hex(variablePointer) + " -> " +
								hex(variableAddress) + " = <double>" + value + gameMakerGroup + ifDuplicateFound);
							}
							else
							{
								IntPtr stringPointer = game.ReadPointer(variableAddress);
								IntPtr stringAddress = game.ReadPointer(stringPointer);
								string stringValue = game.ReadString(stringAddress, 256);

								log(hex(variableNameAddress) + " = " + qt(variableName) + " -> " + hex(variablePointer) + " -> " + hex(variableAddress) + " -> " +
								hex(stringPointer) + " -> " + hex(stringAddress) + " = " + qt(stringValue) + gameMakerGroup + ifDuplicateFound);
							}
						}
					}
					catch
					{
					}
				}

				int variableAddressesFoundCount = variableAddressesFound.Distinct().Count();
				string ifZeroFound = variableAddressesFoundCount == 0 ? " (" + hex(vars.VariableNamesBaseAddress) + ")" : "";

				log("variableAddressesFound: " + variableAddressesFoundCount + "/" + variableTargetsCount + ifZeroFound);

				if (variableAddressesFoundCount == variableTargetsCount)
				{
					if (token.IsCancellationRequested)
					{
						goto task_end;
					}

					IntPtr frameCountAddress = variableAddressesFound.Where(x => x.Item1 == "playerTimer").Select(x => x.Item2).FirstOrDefault();
					vars.RoomNumber = new MemoryWatcher<int>(vars.RoomNumberAddress);
					vars.FrameCount = new MemoryWatcher<double>(frameCountAddress);
					goto ready;
				}
			}
		}

		await System.Threading.Tasks.Task.Delay(2000, token);
		goto scan_start;

		ready:;

		vars.PatchLowFPS = (Action)(() =>
		{
			// Makes a GameMaker game run at full intended frame rate regardless of display refresh rate or Windows version.
			// Increases sleep margin value. This doesn't fix the actual underlying issue,
			// but achieves the desired result (full FPS) at the cost of increased CPU usage.
			// Affects all (?) versions up until and including GMS2 runtime 2.3.1.409 (16-Dec-2020).
			// This GameMaker issue was fixed in GMS2 runtime 2.3.2.420 (30-Mar-2021).

			try
			{
				game.Suspend();

				IntPtr sleepMarginAddress = scanner.Scan(signatureTargets["SleepMargin"]);
				byte[] value = game.ReadBytes(sleepMarginAddress, 4);

				if (value != null)
				{
					int sleepMarginNewValue = 200;
					int sleepMarginOldValue = BitConverter.ToInt32(value, 0);
					game.WriteBytes(sleepMarginAddress, BitConverter.GetBytes(sleepMarginNewValue));
					log("Sleep margin patched. " + hex(sleepMarginAddress) + " = <int>" + sleepMarginOldValue + " -> " + sleepMarginNewValue);
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

isLoading
{
	return true;
}

gameTime
{
	return TimeSpan.FromSeconds(vars.FrameCount.Current / vars.FPS);
}

reset
{
	return vars.FrameCount.Current < vars.FrameCount.Old ||
	       vars.ActionRooms.Contains(current.RoomName);
}

split
{
	return vars.RoomNumber.Changed && vars.FrameCount.Current > 90;
}

exit
{
	vars.CancelSource.Cancel();
}

shutdown
{
	vars.CancelSource.Cancel();
}

// v1.0.7 08-Nov-2025 https://github.com/neesi/autosplitters/tree/main/LOVE
