state("GMRT_test") {}

startup
{
	vars.Log = (Action<object>)(output =>
	{
		print("[GMRT test] " + output);
	});

	vars.Targets = new Dictionary<string, SigScanTarget>
	{
		{ "variableNames1", new SigScanTarget(3, "48 ?? ?? ?? ?? ?? ?? 48 89 C2 E8 ?? ?? ?? ?? 89 06 48 8B 44 24 ?? 48 31 E0") },
		{ "variableNames2", new SigScanTarget(12, "48 89 F9 ?? ?? 48 83 C0 ?? 48 ?? ?? ?? ?? ?? ?? 48 89 C2") },
		{ "globalData1", new SigScanTarget(3, "48 89 3D ?? ?? ?? ?? 48 85 C9 74 ?? E8 ?? ?? ?? ?? 48 8B 35 ?? ?? ?? ?? 48 8D 15") },
		{ "globalData2", new SigScanTarget(3, "48 8B 05 ?? ?? ?? ?? C3 CC CC CC CC CC CC CC CC 48 8D 0D ?? ?? ?? ?? E9") },
		{ "roomNumber1", new SigScanTarget(10, "48 ?? ?? ?? ?? 8B 41 ?? 89 05 ?? ?? ?? ?? C3 B8 FF FF FF FF 89") },
		{ "roomNumber2", new SigScanTarget(8, "48 83 EC ?? 89 CE 8B 05 ?? ?? ?? ?? 48 8B 0D ?? ?? ?? ?? 48 8B 0C C1") },
		{ "roomBase1", new SigScanTarget(3, "4C 8B ?? ?? ?? ?? ?? 4D 29 C1 49 C1 F9 ?? B8 FF FF FF FF 49 39 C9") },
		{ "roomBase2", new SigScanTarget(16, "89 D3 45 84 C0 ?? ?? 8B 05 ?? ?? ?? ?? 48 8B ?? ?? ?? ?? ?? 48 8B 04 C2") }
	};

	foreach (KeyValuePair<string, SigScanTarget> target in vars.Targets)
	{
		target.Value.OnFound = (process, _, address) => address + 0x4 + process.ReadValue<int>(address);
	}
}

init
{
	// Proof of Concept for a GameMaker GMRT auto splitter.
	// Tested on GMRT/GMRT VM 0.19.0 beta (10-Dec-2025), Windows only.
	// Resolves global GameMaker variable names to data addresses. Finds the current room name.

	var variables = new List<KeyValuePair<string, string>>
	{
		new KeyValuePair<string, string>("variable1", "number"),
		new KeyValuePair<string, string>("variable2", "IntPtr"),
		new KeyValuePair<string, string>("variable3", "bool"),
		new KeyValuePair<string, string>("variable4", "string")
	};

	vars.CancelSource = new CancellationTokenSource();
	CancellationToken token = vars.CancelSource.Token;

	System.Threading.Tasks.Task.Run(async () =>
	{
		while (!token.IsCancellationRequested)
		{
			var results = new Dictionary<string, IntPtr>();
			try
			{
				ProcessModuleWow64Safe[] gameModules = game.ModulesWow64Safe();
				var module = gameModules.First(m => m.ModuleName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase));
				var scanner = new SignatureScanner(game, module.BaseAddress, module.ModuleMemorySize - 0x10000);

				foreach (KeyValuePair<string, SigScanTarget> target in vars.Targets)
				{
					string name = target.Key.Remove(target.Key.Length - 1);
					if (!results.ContainsKey(name))
					{
						IntPtr result = scanner.Scan(target.Value);
						if (result != IntPtr.Zero)
						{
							results.Add(name, result);
							vars.Log(target.Key + ": 0x" + result.ToString("X"));
						}
					}
				}
			}
			catch
			{
			}

			if (results.Count == 4)
			{
				IntPtr variableNames = results["variableNames"];
				IntPtr globalData = results["globalData"];
				IntPtr roomNumber = results["roomNumber"];
				IntPtr roomBase = results["roomBase"];

				var found = new List<string>();
				for (int i = 0x0; i <= 0xFFFF; i++)
				{
					string name = new DeepPointer(variableNames, i * 0x8, 0x0).DerefString(game, 256);
					if (found.Contains(name))
					{
						continue;
					}

					foreach (KeyValuePair<string, string> variable in variables.Where(x => x.Key.Equals(name)))
					{
						IntPtr address1 = new DeepPointer(globalData, 0x18, 0x18).Deref<IntPtr>(game);
						IntPtr address2 = game.ReadPointer(address1);
						int andOperand1 = (int)(i * 0x9E3779B1) + 0x1;
						int andOperand2 = game.ReadValue<int>(address1 + 0x10) - 0x1;
						int value1 = game.ReadValue<int>(address1 + 0xC);
						int value2 = (andOperand1 & andOperand2) & 0x7FFFFFFF;
						int globalVariableIndex = game.ReadValue<int>(address2 + value1 + (value2 * 0x8));
						IntPtr globalVariableBase = new DeepPointer(globalData, 0x48).Deref<IntPtr>(game);
						IntPtr address = globalVariableBase + (globalVariableIndex * 0x8);
						string addr = "0x" + address.ToString("X");
						found.Add(name);

						switch (variable.Value)
						{
							case "number":
							{
								if (game.ReadValue<byte>(address + 0x7) == 0x7F)
								{
									IntPtr longAddress = (IntPtr)(game.ReadValue<long>(address) & 0xFFFFFFFFFFFF) + 0x18;
									byte[] bytes = game.ReadBytes(longAddress, 0x8);

									if (bytes != null)
									{
										string longAddr = "0x" + longAddress.ToString("X");
										long valueL = BitConverter.ToInt64(bytes, 0x0); // int64() in GameMaker
										vars.Log(name + ": [" + addr + "] + 0x18 = " + longAddr + " = <long>" + valueL);
										break;
									}
								}

								double valueD = game.ReadValue<double>(address); // real() in GameMaker
								vars.Log(name + ": " + addr + " = <double>" + valueD);
								break;
							}

							case "IntPtr": // ptr() in GameMaker
							{
								IntPtr value = (IntPtr)(game.ReadValue<long>(address) & 0xFFFFFFFFFFFF);
								vars.Log(name + ": " + addr + " = <IntPtr>0x" + value.ToString("X"));
								break;
							}

							case "bool": // bool() in GameMaker
							{
								bool value = game.ReadValue<bool>(address);
								vars.Log(name + ": " + addr + " = <bool>" + value);
								break;
							}

							case "string": // string() in GameMaker
							{
								IntPtr stringAddress = (IntPtr)(game.ReadValue<long>(address) & 0xFFFFFFFFFFFF) + 0x18;
								string stringAddr = "0x" + stringAddress.ToString("X");
								string value = game.ReadString(stringAddress, 256);
								vars.Log(name + ": [" + addr + "] + 0x18 = " + stringAddr + " = \"" + value + "\"");
								break;
							}
						}
					}

					if (found.Count == variables.Count)
					{
						break;
					}
				}

				int number = game.ReadValue<int>(roomNumber);
				string room = new DeepPointer(roomBase, number * 0x8, 0x18).DerefString(game, 256);
				vars.Log("current room: \"" + room + "\" [" + number + "]");

				if (found.Count == variables.Count && !string.IsNullOrWhiteSpace(room))
				{
					break;
				}
			}

			vars.Log("Retrying..");
			await System.Threading.Tasks.Task.Delay(2000, token);
		}

		vars.Log("Task end.");
	});
}

exit
{
	vars.CancelSource.Cancel();
}

shutdown
{
	vars.CancelSource.Cancel();
}

// v0.0.4 23-Jan-2026 https://github.com/neesi/autosplitters/tree/main/GMRT
