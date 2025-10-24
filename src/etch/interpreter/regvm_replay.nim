# regvm_replay.nim
# Replay engine for register-based VM - enables "video scrubbing" through program execution
# This allows seeking to any point in execution history with near-instant performance

import std/[tables, times]
import regvm, ../common/constants


type
  # Lightweight state snapshot taken at intervals
  VMSnapshot* = object
    instructionIndex*: int
    timestamp*: float

    # Full VM state at this point
    frames*: seq[RegisterFrame]
    globals*: Table[string, V]
    rngState*: uint64

    # Debug metadata
    sourceFile*: string
    sourceLine*: int

  # Tracks changes between snapshots
  DeltaKind* = enum
    dkRegWrite      # Register value changed
    dkGlobalWrite   # Global variable changed
    dkFramePush     # Function call (new frame)
    dkFramePop      # Function return (pop frame)
    dkRNGChange     # RNG state changed (for determinism)
    dkPCJump        # Program counter jumped

  ExecutionDelta* = object
    instructionIndex*: int
    case kind*: DeltaKind
    of dkRegWrite:
      frameIdx*: int
      regIdx*: uint8
      oldVal*: V
      newVal*: V
    of dkGlobalWrite:
      globalName*: string
      oldGlobal*: V
      newGlobal*: V
    of dkFramePush:
      pushedFrame*: RegisterFrame
    of dkFramePop:
      poppedFrame*: RegisterFrame
    of dkRNGChange:
      oldRNG*: uint64
      newRNG*: uint64
    of dkPCJump:
      oldPC*: int
      newPC*: int

  ReplayEngine* = ref object
    # Snapshot storage - sparse checkpoints for fast seeking
    snapshots*: seq[VMSnapshot]
    snapshotInterval*: int  # Take snapshot every N instructions

    # Delta storage - every state change
    deltas*: seq[ExecutionDelta]
    deltaIndex*: Table[int, seq[int]]  # instructionIdx -> delta indices

    # Recording/playback state
    isRecording*: bool
    isReplaying*: bool
    currentInstruction*: int
    totalInstructions*: int

    # Statistics
    totalSnapshots*: int
    totalDeltas*: int
    recordingStartTime*: float

    # Reference to VM and program
    vm*: RegisterVM
    program*: RegBytecodeProgram


# Create new replay engine
proc newReplayEngine*(vm: RegisterVM, snapshotInterval: int = DEFAULT_SNAPSHOT_INTERVAL): ReplayEngine =
  result = ReplayEngine(
    snapshots: @[],
    snapshotInterval: snapshotInterval,
    deltas: @[],
    deltaIndex: initTable[int, seq[int]](),
    isRecording: false,
    isReplaying: false,
    currentInstruction: 0,
    totalInstructions: 0,
    totalSnapshots: 0,
    totalDeltas: 0,
    recordingStartTime: 0.0,
    vm: vm,
    program: vm.program
  )


# Deep copy a RegisterFrame (needed for snapshots)
proc copyRegisterFrame(frame: RegisterFrame): RegisterFrame =
  result = RegisterFrame(
    regs: frame.regs,
    pc: frame.pc,
    base: frame.base,
    returnAddr: frame.returnAddr,
    baseReg: frame.baseReg,
    deferStack: frame.deferStack,
    deferReturnPC: frame.deferReturnPC
  )


# Take full snapshot of VM state
proc takeSnapshot*(engine: ReplayEngine, instrIdx: int) =
  if not engine.isRecording:
    return

  let vm = engine.vm

  # Get debug info if available
  var sourceFile = ""
  var sourceLine = 0
  if instrIdx >= 0 and instrIdx < vm.program.instructions.len:
    let instr = vm.program.instructions[instrIdx]
    sourceFile = instr.debug.sourceFile
    sourceLine = instr.debug.line

  # Deep copy frames
  var framesCopy: seq[RegisterFrame] = @[]
  for frame in vm.frames:
    framesCopy.add(copyRegisterFrame(frame))

  var snapshot = VMSnapshot(
    instructionIndex: instrIdx,
    timestamp: epochTime(),
    frames: framesCopy,
    globals: vm.globals,  # Tables are ref types, but V values are copied
    rngState: vm.rngState,
    sourceFile: sourceFile,
    sourceLine: sourceLine
  )

  engine.snapshots.add(snapshot)
  engine.totalSnapshots += 1


# Record a delta (state change)
proc recordDelta*(engine: ReplayEngine, delta: ExecutionDelta) =
  if not engine.isRecording:
    return

  let idx = engine.deltas.len
  engine.deltas.add(delta)
  engine.totalDeltas += 1

  # Index by instruction for fast lookup
  if not engine.deltaIndex.hasKey(delta.instructionIndex):
    engine.deltaIndex[delta.instructionIndex] = @[]
  engine.deltaIndex[delta.instructionIndex].add(idx)


# Restore VM to a specific snapshot
proc restoreSnapshot*(engine: ReplayEngine, snapshot: VMSnapshot) =
  let vm = engine.vm

  # Restore full state - deep copy frames
  vm.frames = @[]
  for frame in snapshot.frames:
    vm.frames.add(copyRegisterFrame(frame))

  vm.globals = snapshot.globals
  vm.rngState = snapshot.rngState

  if vm.frames.len > 0:
    vm.currentFrame = addr vm.frames[^1]
    vm.currentFrame.pc = snapshot.instructionIndex

  engine.currentInstruction = snapshot.instructionIndex


# Apply a delta forward (move forward in time)
proc applyDelta*(engine: ReplayEngine, delta: ExecutionDelta) =
  let vm = engine.vm

  case delta.kind
  of dkRegWrite:
    if delta.frameIdx < vm.frames.len:
      vm.frames[delta.frameIdx].regs[delta.regIdx] = delta.newVal
  of dkGlobalWrite:
    vm.globals[delta.globalName] = delta.newGlobal
  of dkFramePush:
    vm.frames.add(copyRegisterFrame(delta.pushedFrame))
    if vm.frames.len > 0:
      vm.currentFrame = addr vm.frames[^1]
  of dkFramePop:
    if vm.frames.len > 0:
      discard vm.frames.pop()
    if vm.frames.len > 0:
      vm.currentFrame = addr vm.frames[^1]
  of dkRNGChange:
    vm.rngState = delta.newRNG
  of dkPCJump:
    if vm.frames.len > 0:
      vm.currentFrame.pc = delta.newPC


# Unapply a delta (move backward in time)
proc unapplyDelta*(engine: ReplayEngine, delta: ExecutionDelta) =
  let vm = engine.vm

  case delta.kind
  of dkRegWrite:
    if delta.frameIdx < vm.frames.len:
      vm.frames[delta.frameIdx].regs[delta.regIdx] = delta.oldVal
  of dkGlobalWrite:
    vm.globals[delta.globalName] = delta.oldGlobal
  of dkFramePush:
    if vm.frames.len > 0:
      discard vm.frames.pop()
    if vm.frames.len > 0:
      vm.currentFrame = addr vm.frames[^1]
  of dkFramePop:
    vm.frames.add(copyRegisterFrame(delta.poppedFrame))
    if vm.frames.len > 0:
      vm.currentFrame = addr vm.frames[^1]
  of dkRNGChange:
    vm.rngState = delta.oldRNG
  of dkPCJump:
    if vm.frames.len > 0:
      vm.currentFrame.pc = delta.oldPC


# Seek to a specific instruction (the scrubbing API!)
proc seekTo*(engine: ReplayEngine, targetInstr: int) =
  if engine.snapshots.len == 0:
    return

  # Clamp target to valid range
  let target = max(0, min(targetInstr, engine.totalInstructions))

  # Find nearest snapshot BEFORE or AT target
  var nearestSnapshot: VMSnapshot
  var snapshotIdx = -1

  for i in countdown(engine.snapshots.high, 0):
    if engine.snapshots[i].instructionIndex <= target:
      nearestSnapshot = engine.snapshots[i]
      snapshotIdx = i
      break

  if snapshotIdx < 0:
    # Use first snapshot
    nearestSnapshot = engine.snapshots[0]

  # Restore to snapshot
  engine.restoreSnapshot(nearestSnapshot)

  # Apply deltas forward to reach target
  for i in nearestSnapshot.instructionIndex ..< target:
    if engine.deltaIndex.hasKey(i):
      for deltaIdx in engine.deltaIndex[i]:
        engine.applyDelta(engine.deltas[deltaIdx])

  engine.currentInstruction = target


# Start recording execution
proc startRecording*(engine: ReplayEngine) =
  engine.isRecording = true
  engine.isReplaying = false
  engine.snapshots = @[]
  engine.deltas = @[]
  engine.deltaIndex = initTable[int, seq[int]]()
  engine.currentInstruction = 0
  engine.totalSnapshots = 0
  engine.totalDeltas = 0
  engine.recordingStartTime = epochTime()

  # Take initial snapshot
  engine.takeSnapshot(0)


# Stop recording
proc stopRecording*(engine: ReplayEngine) =
  engine.isRecording = false
  engine.totalInstructions = engine.currentInstruction


# Start replaying (sets flag to prevent further recording)
proc startReplaying*(engine: ReplayEngine) =
  engine.isReplaying = true
  engine.isRecording = false


# Get current replay progress (0.0 to 1.0)
proc getProgress*(engine: ReplayEngine): float =
  if engine.totalInstructions == 0:
    return 0.0
  return engine.currentInstruction.float / engine.totalInstructions.float


# Get total duration of recorded execution
proc getTotalDuration*(engine: ReplayEngine): float =
  if engine.snapshots.len < 2:
    return 0.0
  return engine.snapshots[^1].timestamp - engine.snapshots[0].timestamp


# Seek to a specific time (in seconds from start)
proc seekToTime*(engine: ReplayEngine, targetTime: float) =
  if engine.snapshots.len == 0:
    return

  let startTime = engine.snapshots[0].timestamp
  let targetTimestamp = startTime + targetTime

  # Find instruction closest to target time
  var bestIdx = 0
  var bestDiff = abs(engine.snapshots[0].timestamp - targetTimestamp)

  for i in 1 ..< engine.snapshots.len:
    let diff = abs(engine.snapshots[i].timestamp - targetTimestamp)
    if diff < bestDiff:
      bestDiff = diff
      bestIdx = i

  # Seek to that instruction
  engine.seekTo(engine.snapshots[bestIdx].instructionIndex)


# Get statistics about the replay session
proc getStats*(engine: ReplayEngine): tuple[snapshots: int, deltas: int,
                                            instructions: int, duration: float] =
  return (
    snapshots: engine.totalSnapshots,
    deltas: engine.totalDeltas,
    instructions: engine.totalInstructions,
    duration: engine.getTotalDuration()
  )


# Print replay statistics (for debugging)
proc printStats*(engine: ReplayEngine) =
  let stats = engine.getStats()
  echo "Replay Statistics:"
  echo "  Total instructions: ", stats.instructions
  echo "  Total snapshots: ", stats.snapshots
  echo "  Total deltas: ", stats.deltas
  echo "  Duration: ", stats.duration, " seconds"
  echo "  Snapshot interval: ", engine.snapshotInterval, " instructions"
  if stats.instructions > 0:
    echo "  Memory per instruction: ~",
         (stats.deltas * 50 + stats.snapshots * 1024) div stats.instructions, " bytes"
