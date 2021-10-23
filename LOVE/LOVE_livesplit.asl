state("Love") {}

startup
{
	vars.ScanThreadReady = false;
	vars.Dbg = (Action<dynamic>) ((output) => print("[LOVE ASL] " + output));

	settings.Add("", false);
	settings.Add("   Right-click livesplit -> Compare Against: Game Time", false);
	settings.Add("   \"Game Time\" stays in sync with the game's framecounter.", false);
	settings.Add(" ", false);
	settings.Add("   Enter speedrun mode to activate the splitter.", false);
	settings.Add("   After that, it will work in every other game mode.", false);
}

init
{
	vars.levelactiveCodecaveAddr = IntPtr.Zero;
	vars.frameCodecaveAddr = IntPtr.Zero;

	game.Resume(); // why not

	Thread.Sleep(1000); // hacky way to "fix" occasional update debug errors when you start the game. the errors seem harmless.

	vars.levelactiveFound = false;
	vars.framecounterFound = false;
	vars.allDone = false;

	vars.levelactiveOriginalBytes = new byte[] { 0x6A, 0x0C, 0xFF, 0x46, 0x40 };
	vars.frameOriginalBytes = new byte[] { 0xF2, 0x0F, 0x10, 0x01, 0xF2, 0x0F, 0x11, 0x47, 0xF0 };

	vars.CancelSource = new CancellationTokenSource();
	vars.ScanThread = new Thread(() =>
	{
		vars.ScanThreadReady = true;

		vars.Dbg("Starting scan thread.");
		vars.Dbg("MainModule.BaseAddress = 0x" + game.MainModule.BaseAddress.ToString("X"));

		vars.levelactiveInjectedTrg = new SigScanTarget(0, "E9 ?? ?? ?? ?? ?? ?? ?? ?? ?? 8B 7C 24 1C 8B C8 83 C4 10");
		vars.frameInjectedTrg = new SigScanTarget(5, "89 48 ?? ?? ?? E9 ?? ?? ?? ?? 90 90 90 90 ?? ?? 8B 01");
		var levelactiveTrg = new SigScanTarget(0, "6A 0C FF 46 40 ?? ?? ?? ?? ?? 8B 7C 24 1C 8B C8");
		var roomTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7");
		var roomPtrTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7") { OnFound = (p, s, ptr) => p.ReadPointer(ptr) };
		var frameTrg = new SigScanTarget(0, "F2 0F 10 01 F2 0F 11 47 F0 ?? ?? 8B 01");

		IntPtr levelactiveInjectedSigAddr = IntPtr.Zero, frameInjectedSigAddr = IntPtr.Zero, levelactiveSigAddr = IntPtr.Zero, roomSigAddr = IntPtr.Zero, roomPtrSigAddr = IntPtr.Zero, frameSigAddr = IntPtr.Zero;

		var token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

			try
			{
				if (levelactiveInjectedSigAddr == IntPtr.Zero && (levelactiveInjectedSigAddr = scanner.Scan(vars.levelactiveInjectedTrg)) != IntPtr.Zero)
				{
					game.Suspend();
					game.WriteBytes((IntPtr) levelactiveInjectedSigAddr, (byte[]) vars.levelactiveOriginalBytes);

					vars.Dbg("Removed levelactive grabber.");
				}
			}
			catch (Exception e)
			{
				game.Resume();
				vars.Dbg(e.ToString());
			}
			finally
			{
				game.Resume();
			}

			try
			{
				if (frameInjectedSigAddr == IntPtr.Zero && (frameInjectedSigAddr = scanner.Scan(vars.frameInjectedTrg)) != IntPtr.Zero)
				{
					game.Suspend();
					game.WriteBytes((IntPtr) frameInjectedSigAddr, (byte[]) vars.frameOriginalBytes);

					vars.Dbg("Removed framecounter grabber.");
				}
			}
			catch (Exception e)
			{
				game.Resume();
				vars.Dbg(e.ToString());
			}
			finally
			{
				game.Resume();
			}

			if (levelactiveSigAddr == IntPtr.Zero && (levelactiveSigAddr = scanner.Scan(levelactiveTrg)) != IntPtr.Zero)
				vars.Dbg("Found levelactive signature at 0x" + levelactiveSigAddr.ToString("X"));

			if (roomSigAddr == IntPtr.Zero && (roomSigAddr = scanner.Scan(roomTrg)) != IntPtr.Zero)
				vars.Dbg("Found room signature at 0x" + roomSigAddr.ToString("X"));

			if (roomPtrSigAddr == IntPtr.Zero && (roomPtrSigAddr = scanner.Scan(roomPtrTrg)) != IntPtr.Zero)
				vars.Dbg("Found room address at 0x" + roomPtrSigAddr.ToString("X"));

			if (frameSigAddr == IntPtr.Zero && (frameSigAddr = scanner.Scan(frameTrg)) != IntPtr.Zero)
				vars.Dbg("Found framecounter signature at 0x" + frameSigAddr.ToString("X"));

			if (new[] { levelactiveSigAddr, roomSigAddr, roomPtrSigAddr, frameSigAddr }.All(ptr => ptr != IntPtr.Zero))
			{
				vars.Dbg("Scan completed. Injecting levelactive and framecounter grabbers.");

				try
				{
					game.Suspend();

		// levelactive codecave begin

					vars.levelactiveCodecaveAddr = game.AllocateMemory(64);						// start address of levelactive codecave
					vars.levelactiveSigAddr = levelactiveSigAddr;							// start address of levelactive sig scan result
					var levelactivePlaceholderAddr = vars.levelactiveCodecaveAddr+34;				// start address of levelactive placeholder in the codecave
					vars.levelactiveGrabber = new MemoryWatcher<int>((IntPtr) levelactivePlaceholderAddr);		// waiting for dynamic levelactive address to be found

					var codecaveLevelactiveGrabber = new List<byte>
					{
						0x81, 0x7E, 0x50, 0x52, 0x00, 0x00, 0x00,						// cmp [esi+50],00000052
						0x75, 0x0F,										// jne +15 bytes
						0x81, 0x7E, 0x54, 0x14, 0x00, 0x00, 0x00,						// cmp [esi+54],00000014
						0x75, 0x06,										// jne +6 bytes
						0x89, 0x35										// mov [levelactivePlaceholderAddr],esi
					};

					codecaveLevelactiveGrabber.AddRange(BitConverter.GetBytes((int) levelactivePlaceholderAddr));
					codecaveLevelactiveGrabber.AddRange(new byte[]
					{												// original code
						0x6A, 0x0C,										// push 0C
						0xFF, 0x46, 0x40									// inc [esi+40]
					});

					game.WriteBytes((IntPtr) vars.levelactiveCodecaveAddr, codecaveLevelactiveGrabber.ToArray());

					// write jump out of codecave to static mem
					game.WriteJumpInstruction((IntPtr) vars.levelactiveCodecaveAddr+29, levelactiveSigAddr+5);	// jmp levelactiveSigAddr+5

		// levelactive codecave end

		// levelactive inject begin

					// write jump from static mem to codecave
					game.WriteJumpInstruction(levelactiveSigAddr, (IntPtr) vars.levelactiveCodecaveAddr);

		// levelactive inject end

		// framecounter codecave begin

					vars.frameCodecaveAddr = game.AllocateMemory(64);					// start address of framecounter codecave
					vars.frameSigAddr = frameSigAddr;							// start address of framecounter sig scan result
					var framePlaceholderAddr = vars.frameCodecaveAddr+29;					// start address of framecounter placeholder in the codecave
					vars.framecounterGrabber = new MemoryWatcher<int>((IntPtr) framePlaceholderAddr);	// waiting for dynamic framecounter address to be found

					var codecaveFramecounterGrabber = new List<byte>
					{
						0x81, 0x79, 0x20, 0x00, 0x00, 0x00, 0xFC,					// cmp [ecx+20],FC000000	(99999999 lives in speedrun / unlimited modes)
						0x75, 0x06,									// jne +6 bytes
						0x89, 0x0D									// mov [framePlaceholderAddr],ecx
					};

					codecaveFramecounterGrabber.AddRange(BitConverter.GetBytes((int) framePlaceholderAddr));
					codecaveFramecounterGrabber.AddRange(new byte[]
					{											// original code
						0xF2, 0x0F, 0x10, 0x01,								// movsd xmm0,[ecx]
						0xF2, 0x0F, 0x11, 0x47, 0xF0							// movsd [edi-10],xmm0
					});

					game.WriteBytes((IntPtr) vars.frameCodecaveAddr, codecaveFramecounterGrabber.ToArray());

					// write jump out of codecave to static mem
					game.WriteJumpInstruction((IntPtr) vars.frameCodecaveAddr+24, frameSigAddr+9);		// jmp frameSigAddr+9

		// framecounter codecave end

		// framecounter inject begin

					// write jump from static mem to codecave
					game.WriteJumpInstruction(frameSigAddr, (IntPtr) vars.frameCodecaveAddr);

					game.WriteBytes((IntPtr) frameSigAddr+5, new byte[]
					{
						0x90, 0x90, 0x90, 0x90
					});

		// framecounter inject end

				}
				catch (Exception e)
				{
					game.Resume();
					vars.Dbg(e.ToString());
				}
				finally
				{
					game.Resume();
				}

				vars.Dbg("Injection completed. Enter speedrun or unlimited mode to grab levelactive and framecounter addresses.");
				break;
			}

			vars.Dbg("Scan was unsuccessful. Retrying.");
			Thread.Sleep(2000);
		}

		vars.levelactive = new MemoryWatcher<int>(new DeepPointer(0));
		vars.room = new MemoryWatcher<int>(roomPtrSigAddr);
		vars.framecounter = new MemoryWatcher<double>(new DeepPointer(0));
	});

	vars.ScanThread.Start();
}

update
{
	if (vars.ScanThread.IsAlive) return false;

		vars.levelactive.Update(game);
		vars.room.Update(game);
		vars.framecounter.Update(game);

	if (vars.allDone) return;

		vars.levelactiveGrabber.Update(game);
		vars.framecounterGrabber.Update(game);

	if (vars.levelactiveGrabber.Current != 0 && !vars.levelactiveFound)
	{
		vars.levelactiveFound = true;

		var levelactiveFinalAddr = vars.levelactiveGrabber.Current - (int) game.MainModule.BaseAddress + 64; // hex 40 offset
		vars.levelactive = new MemoryWatcher<int>(new DeepPointer(levelactiveFinalAddr));

		vars.Dbg("Found levelactive address at 0x" + (vars.levelactiveGrabber.Current + 64).ToString("X"));

		try
		{
			game.Suspend();
			game.WriteBytes((IntPtr) vars.levelactiveSigAddr, (byte[]) vars.levelactiveOriginalBytes);
			vars.Dbg("Removed levelactive grabber.");

			game.FreeMemory((IntPtr) vars.levelactiveCodecaveAddr);

			if (vars.framecounterFound)
			{
				vars.allDone = true;
				vars.Dbg("All done.");
			}
		}
		catch (Exception e)
		{
			game.Resume();
			vars.Dbg(e.ToString());
		}
		finally
		{
			game.Resume();
		}
	}

	if (vars.framecounterGrabber.Current != 0 && !vars.framecounterFound)
	{
		vars.framecounterFound = true;

		var framecounterFinalAddr = vars.framecounterGrabber.Current - (int) game.MainModule.BaseAddress;
		vars.framecounter = new MemoryWatcher<double>(new DeepPointer(framecounterFinalAddr));

		vars.Dbg("Found framecounter address at 0x" + vars.framecounterGrabber.Current.ToString("X"));

		try
		{
			game.Suspend();
			game.WriteBytes((IntPtr) vars.frameSigAddr, (byte[]) vars.frameOriginalBytes);
			vars.Dbg("Removed framecounter grabber.");

			game.FreeMemory((IntPtr) vars.frameCodecaveAddr);

			if (vars.levelactiveFound)
			{
				vars.allDone = true;
				vars.Dbg("All done.");
			}
		}
		catch (Exception e)
		{
			game.Resume();
			vars.Dbg(e.ToString());
		}
		finally
		{
			game.Resume();
		}
	}
}

start
{
	return vars.allDone && vars.levelactive.Current == 1;
}

split
{
	return vars.room.Changed && vars.framecounter.Current > 90;
}

reset
{
	return vars.room.Current < 12 && vars.room.Old > vars.room.Current ||
	       vars.framecounter.Old > vars.framecounter.Current;
}

gameTime
{
	return TimeSpan.FromSeconds(vars.framecounter.Current / 60f);
}

isLoading
{
	return true;
}

exit
{
	if (vars.ScanThread.IsAlive) vars.CancelSource.Cancel();
}

shutdown
{
	if (vars.ScanThreadReady && vars.ScanThread.IsAlive) vars.CancelSource.Cancel();

	if (game == null) return;

	IntPtr levelactiveInjectedSigAddr = IntPtr.Zero, frameInjectedSigAddr = IntPtr.Zero;
	var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

	try
	{
		if (levelactiveInjectedSigAddr == IntPtr.Zero && (levelactiveInjectedSigAddr = scanner.Scan(vars.levelactiveInjectedTrg)) != IntPtr.Zero)
		{
			game.Suspend();
			game.WriteBytes((IntPtr) levelactiveInjectedSigAddr, (byte[]) vars.levelactiveOriginalBytes);
			vars.Dbg("Removed levelactive grabber.");

			if (vars.levelactiveCodecaveAddr != IntPtr.Zero)
				game.FreeMemory((IntPtr) vars.levelactiveCodecaveAddr);
		}
	}
	catch (Exception e)
	{
		game.Resume();
		vars.Dbg(e.ToString());
	}
	finally
	{
		game.Resume();
	}

	try
	{
		if (frameInjectedSigAddr == IntPtr.Zero && (frameInjectedSigAddr = scanner.Scan(vars.frameInjectedTrg)) != IntPtr.Zero)
		{
			game.Suspend();
			game.WriteBytes((IntPtr) frameInjectedSigAddr, (byte[]) vars.frameOriginalBytes);
			vars.Dbg("Removed framecounter grabber.");

			if (vars.frameCodecaveAddr != IntPtr.Zero)
				game.FreeMemory((IntPtr) vars.frameCodecaveAddr);
		}
	}
	catch (Exception e)
	{
		game.Resume();
		vars.Dbg(e.ToString());
	}
	finally
	{
		game.Resume();
	}

	game.Resume(); // why not
}
