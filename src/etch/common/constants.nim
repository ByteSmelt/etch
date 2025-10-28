# constants.nim
# Program-wide constants for the Etch language implementation

# VM types
type
  VMType* = enum
    vmRegister = 1 # Register-based VM

# Module names for logging
const
  MODULE_COMPILER* = "COMPILER"
  MODULE_PROVER* = "PROVER"
  MODULE_VM* = "VM"
  MODULE_CLI* = "CLI"

# Program metadata
const
  PROGRAM_NAME* = "Etch"
  PROGRAM_VERSION* = "0.1.0"
  SOURCE_FILE_EXTENSION* = ".etch"
  BYTECODE_CACHE_DIR* = "__etch__"
  BYTECODE_FILE_EXTENSION* = ".etcx"

# Global names
const
  MAIN_FUNCTION_NAME* = "main"
  GLOBAL_INIT_FUNCTION_NAME* = "<global>"

# Function utils
const
  FUNCTION_NAME_SEPARATOR_STRING* = "::"     # Separates function name from signature: funcName::signature
  FUNCTION_RETURN_SEPARATOR_STRING* = ":"    # Separates parameters from return type: params:returnType

# Bytecode serialization constants
const
  BYTECODE_MAGIC* = "ETCH"
  BYTECODE_VERSION* = 27  # Added ropInitGlobal for C API global override support

# RegVM constants
const
  MAX_REGISTERS* = 255  # Maximum number of registers per function frame (must fit in uint8)
  MAX_CONSTANTS* = 65536  # Maximum constants per function (16-bit index)

# Symbolic execution constants
const
  MAX_LOOP_ITERATIONS* = 1_000_000
  MAX_RECURSION_DEPTH* = 1_000

# Replay constants
const
  REPLAY_VERSION* = 1  # Version of replay format
  DEFAULT_SNAPSHOT_INTERVAL* = 1_000  # Take snapshot every N instructions
