state("Love") {}

startup
{
	vars.ScanThreadReady = false;
	vars.Dbg = (Action<dynamic>) ((output) => print("[LOVE ASL] " + output));
}

init
{
	vars.LevelActiveCodecaveAddr = IntPtr.Zero;
	vars.FrameCodecaveAddr = IntPtr.Zero;
	
	vars.LevelActiveFound = false;
	vars.FramecounterFound = false;
	vars.AllDone = false;

	vars.LevelActiveOriginalBytes = new byte[] { 0x6A, 0x0C, 0xFF, 0x46, 0x40 };
	vars.FrameOriginalBytes = new byte[] { 0xF2, 0x0F, 0x10, 0x01, 0xF2, 0x0F, 0x11, 0x47, 0xF0 };

	vars.CancelSource = new CancellationTokenSource();
	vars.ScanThread = new Thread(() =>
	{
		vars.ScanThreadReady = true;

		vars.Dbg("Starting scan thread.");
		vars.Dbg("MainModule.BaseAddress = 0x" + game.MainModule.BaseAddress.ToString("X"));

		vars.LevelActiveInjectedTrg = new SigScanTarget(0, "E9 ?? ?? ?? ?? ?? ?? ?? ?? ?? 8B 7C 24 1C 8B C8 83 C4 10");
		vars.FrameInjectedTrg = new SigScanTarget(5, "89 48 ?? ?? ?? E9 ?? ?? ?? ?? 90 90 90 90 ?? ?? 8B 01");
		var LevelActiveTrg = new SigScanTarget(0, "6A 0C FF 46 40 ?? ?? ?? ?? ?? 8B 7C 24 1C 8B C8");
		var RoomTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7");
		var RoomPtrTrg = new SigScanTarget(1, "A1 ?? ?? ?? ?? 50 A3 ?? ?? ?? ?? C7") { OnFound = (p, s, ptr) => p.ReadPointer(ptr) };
		var FrameTrg = new SigScanTarget(0, "F2 0F 10 01 F2 0F 11 47 F0 ?? ?? 8B 01");

		IntPtr LevelActiveInjectedSigAddr = IntPtr.Zero, FrameInjectedSigAddr = IntPtr.Zero, LevelActiveSigAddr = IntPtr.Zero, RoomSigAddr = IntPtr.Zero, RoomPtrSigAddr = IntPtr.Zero, FrameSigAddr = IntPtr.Zero;

		var token = vars.CancelSource.Token;
		while (!token.IsCancellationRequested)
		{
			var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

			try
			{
				if (LevelActiveInjectedSigAddr == IntPtr.Zero && (LevelActiveInjectedSigAddr = scanner.Scan(vars.LevelActiveInjectedTrg)) != IntPtr.Zero)
				{
					game.Suspend();
					game.WriteBytes((IntPtr) LevelActiveInjectedSigAddr, (byte[]) vars.LevelActiveOriginalBytes);

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
				if (FrameInjectedSigAddr == IntPtr.Zero && (FrameInjectedSigAddr = scanner.Scan(vars.FrameInjectedTrg)) != IntPtr.Zero)
				{
					game.Suspend();
					game.WriteBytes((IntPtr) FrameInjectedSigAddr, (byte[]) vars.FrameOriginalBytes);

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

			if (LevelActiveSigAddr == IntPtr.Zero && (LevelActiveSigAddr = scanner.Scan(LevelActiveTrg)) != IntPtr.Zero)
				vars.Dbg("Found levelactive signature at 0x" + LevelActiveSigAddr.ToString("X"));

			if (RoomSigAddr == IntPtr.Zero && (RoomSigAddr = scanner.Scan(RoomTrg)) != IntPtr.Zero)
				vars.Dbg("Found room signature at 0x" + RoomSigAddr.ToString("X"));

			if (RoomPtrSigAddr == IntPtr.Zero && (RoomPtrSigAddr = scanner.Scan(RoomPtrTrg)) != IntPtr.Zero)
				vars.Dbg("Found room address at 0x" + RoomPtrSigAddr.ToString("X"));

			if (FrameSigAddr == IntPtr.Zero && (FrameSigAddr = scanner.Scan(FrameTrg)) != IntPtr.Zero)
				vars.Dbg("Found framecounter signature at 0x" + FrameSigAddr.ToString("X"));

			if (new[] { LevelActiveSigAddr, RoomSigAddr, RoomPtrSigAddr, FrameSigAddr }.All(ptr => ptr != IntPtr.Zero))
			{
				vars.Dbg("Scan completed. Injecting levelactive and framecounter grabbers.");

				try
				{
					game.Suspend();

		// levelactive codecave begin

					vars.LevelActiveCodecaveAddr = game.AllocateMemory(64);						// start address of levelactive codecave
					vars.LevelActiveSigAddr = LevelActiveSigAddr;							// start address of levelactive sig scan result
					var LevelActivePlaceholderAddr = vars.LevelActiveCodecaveAddr+34;				// start address of levelactive placeholder in the codecave
					vars.LevelActiveGrabber = new MemoryWatcher<int>((IntPtr) LevelActivePlaceholderAddr);		// waiting for dynamic levelactive address to be found

					var CodecaveLevelActiveGrabber = new List<byte>
					{
						0x81, 0x7E, 0x50, 0x52, 0x00, 0x00, 0x00,						// cmp [esi+50],00000052
						0x75, 0x0F,										// jne +15 bytes
						0x81, 0x7E, 0x54, 0x14, 0x00, 0x00, 0x00,						// cmp [esi+54],00000014
						0x75, 0x06,										// jne +6 bytes
						0x89, 0x35										// mov [LevelActivePlaceholderAddr],esi
					};

					CodecaveLevelActiveGrabber.AddRange(BitConverter.GetBytes((int) LevelActivePlaceholderAddr));
					CodecaveLevelActiveGrabber.AddRange(new byte[]
					{												// original code
						0x6A, 0x0C,										// push 0C
						0xFF, 0x46, 0x40									// inc [esi+40]
					});

					game.WriteBytes((IntPtr) vars.LevelActiveCodecaveAddr, CodecaveLevelActiveGrabber.ToArray());

					// write jump out of codecave to static mem
					game.WriteJumpInstruction((IntPtr) vars.LevelActiveCodecaveAddr+29, LevelActiveSigAddr+5);	// jmp LevelActiveSigAddr+5

		// levelactive codecave end

		// levelactive inject begin

					// write jump from static mem to codecave
					game.WriteJumpInstruction(LevelActiveSigAddr, (IntPtr) vars.LevelActiveCodecaveAddr);

		// levelactive inject end

		// framecounter codecave begin

					vars.FrameCodecaveAddr = game.AllocateMemory(64);						// start address of framecounter codecave
					vars.FrameSigAddr = FrameSigAddr;								// start address of framecounter sig scan result
					var FramePlaceholderAddr = vars.FrameCodecaveAddr+29;						// start address of framecounter placeholder in the codecave
					vars.FramecounterGrabber = new MemoryWatcher<int>((IntPtr) FramePlaceholderAddr);		// waiting for dynamic framecounter address to be found

					var CodecaveFramecounterGrabber = new List<byte>
					{
						0x81, 0x79, 0x20, 0x00, 0x00, 0x00, 0xFC,						// cmp [ecx+20],FC000000	(99999999 lives in speedrun / unlimited modes)
						0x75, 0x06,										// jne +6 bytes
						0x89, 0x0D										// mov [FramePlaceholderAddr],ecx
					};

					CodecaveFramecounterGrabber.AddRange(BitConverter.GetBytes((int) FramePlaceholderAddr));
					CodecaveFramecounterGrabber.AddRange(new byte[]
					{												// original code
						0xF2, 0x0F, 0x10, 0x01,									// movsd xmm0,[ecx]
						0xF2, 0x0F, 0x11, 0x47, 0xF0								// movsd [edi-10],xmm0
					});

					game.WriteBytes((IntPtr) vars.FrameCodecaveAddr, CodecaveFramecounterGrabber.ToArray());

					// write jump out of codecave to static mem
					game.WriteJumpInstruction((IntPtr) vars.FrameCodecaveAddr+24, FrameSigAddr+9);			// jmp FrameSigAddr+9

		// framecounter codecave end

		// framecounter inject begin

					// write jump from static mem to codecave
					game.WriteJumpInstruction(FrameSigAddr, (IntPtr) vars.FrameCodecaveAddr);

					game.WriteBytes((IntPtr) FrameSigAddr+5, new byte[]
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

		vars.LevelActive = new MemoryWatcher<int>(new DeepPointer(0));
		vars.Room = new MemoryWatcher<int>(RoomPtrSigAddr);
		vars.Framecounter = new MemoryWatcher<double>(new DeepPointer(0));
	});

	vars.ScanThread.Start();
}

update
{
	if (vars.ScanThread.IsAlive) return false;

		vars.LevelActive.Update(game);
		vars.Room.Update(game);
		vars.Framecounter.Update(game);

	if (vars.AllDone) return;

		vars.LevelActiveGrabber.Update(game);
		vars.FramecounterGrabber.Update(game);

	if (vars.LevelActiveGrabber.Current != 0 && !vars.LevelActiveFound)
	{
		vars.LevelActiveFound = true;

		var LevelActiveFinalAddr = vars.LevelActiveGrabber.Current - (int) game.MainModule.BaseAddress + 64; // hex 40 offset
		vars.LevelActive = new MemoryWatcher<int>(new DeepPointer(LevelActiveFinalAddr));

		vars.Dbg("Found levelactive address at 0x" + (vars.LevelActiveGrabber.Current + 64).ToString("X"));

		try
		{
			game.Suspend();
			game.WriteBytes((IntPtr) vars.LevelActiveSigAddr, (byte[]) vars.LevelActiveOriginalBytes);
			vars.Dbg("Removed levelactive grabber.");

			game.FreeMemory((IntPtr) vars.LevelActiveCodecaveAddr);

			if (vars.FramecounterFound)
			{
				vars.AllDone = true;
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

	if (vars.FramecounterGrabber.Current != 0 && !vars.FramecounterFound)
	{
		vars.FramecounterFound = true;

		var FramecounterFinalAddr = vars.FramecounterGrabber.Current - (int) game.MainModule.BaseAddress;
		vars.Framecounter = new MemoryWatcher<double>(new DeepPointer(FramecounterFinalAddr));

		vars.Dbg("Found framecounter address at 0x" + vars.FramecounterGrabber.Current.ToString("X"));

		try
		{
			game.Suspend();
			game.WriteBytes((IntPtr) vars.FrameSigAddr, (byte[]) vars.FrameOriginalBytes);
			vars.Dbg("Removed framecounter grabber.");

			game.FreeMemory((IntPtr) vars.FrameCodecaveAddr);

			if (vars.LevelActiveFound)
			{
				vars.AllDone = true;
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
	return vars.AllDone && vars.LevelActive.Current == 1;
}

split
{
	return vars.Room.Changed && vars.Framecounter.Current > 90;
}

reset
{
	return vars.Room.Current < 12 && vars.Room.Old > vars.Room.Current ||
	       vars.Framecounter.Old > vars.Framecounter.Current;
}

gameTime
{
	return TimeSpan.FromSeconds(vars.Framecounter.Current / 60f);
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
	if (vars.ScanThreadReady && vars.ScanThread.IsAlive) vars.CancelSource.Cancel();

	if (game == null) return;

	IntPtr LevelActiveInjectedSigAddr = IntPtr.Zero, FrameInjectedSigAddr = IntPtr.Zero;
	var scanner = new SignatureScanner(game, game.MainModule.BaseAddress, game.MainModule.ModuleMemorySize);

	try
	{
		if (LevelActiveInjectedSigAddr == IntPtr.Zero && (LevelActiveInjectedSigAddr = scanner.Scan(vars.LevelActiveInjectedTrg)) != IntPtr.Zero)
		{
			game.Suspend();
			game.WriteBytes((IntPtr) LevelActiveInjectedSigAddr, (byte[]) vars.LevelActiveOriginalBytes);
			vars.Dbg("Removed levelactive grabber.");

			if (vars.LevelActiveCodecaveAddr != IntPtr.Zero)
				game.FreeMemory((IntPtr) vars.LevelActiveCodecaveAddr);
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
		if (FrameInjectedSigAddr == IntPtr.Zero && (FrameInjectedSigAddr = scanner.Scan(vars.FrameInjectedTrg)) != IntPtr.Zero)
		{
			game.Suspend();
			game.WriteBytes((IntPtr) FrameInjectedSigAddr, (byte[]) vars.FrameOriginalBytes);
			vars.Dbg("Removed framecounter grabber.");

			if (vars.FrameCodecaveAddr != IntPtr.Zero)
				game.FreeMemory((IntPtr) vars.FrameCodecaveAddr);
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
