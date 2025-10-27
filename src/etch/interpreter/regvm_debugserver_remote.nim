# regvm_debugserver_remote.nim
# TCP-based remote debug server for embedded Etch scenarios
# Allows debugging Etch scripts running inside C/C++ applications
# Similar to Python's debugpy for embedded Python interpreters

import std/[json, net, os, times, nativesockets, strutils]
import regvm, regvm_debugserver

type
  RegRemoteDebugServer* = ref object
    server*: RegDebugServer  # Reuse existing debug server logic
    socket*: Socket
    clientSocket*: Socket
    port*: int
    listening*: bool
    connected*: bool

proc newRegRemoteDebugServer*(program: RegBytecodeProgram, sourceFile: string, port: int = 9823): RegRemoteDebugServer =
  ## Create a new remote debug server that listens on a TCP port
  ## program: Compiled Etch bytecode program
  ## sourceFile: Source file path for debug information
  ## port: TCP port to listen on (default: 9823)

  var remoteServer = RegRemoteDebugServer(
    server: newRegDebugServer(program, sourceFile),
    socket: newSocket(),
    clientSocket: nil,
    port: port,
    listening: false,
    connected: false
  )

  # Override the debug server's event handler to send events over TCP socket
  # This captures events like 'stopped', 'terminated', 'output' etc.
  remoteServer.server.debugger.onDebugEvent = proc(event: string, data: JsonNode) =
    if remoteServer.connected and remoteServer.clientSocket != nil:
      let eventMsg = %*{
        "type": "event",
        "event": event,
        "body": data
      }
      stderr.writeLine("DEBUG: Sending event to client: " & event)
      stderr.flushFile()

      try:
        let msgStr = $eventMsg & "\n"
        remoteServer.clientSocket.send(msgStr)
      except OSError as e:
        stderr.writeLine("ERROR: Failed to send event: " & e.msg)
        stderr.flushFile()
        remoteServer.connected = false

  result = remoteServer

proc startListening*(server: RegRemoteDebugServer): bool =
  ## Start listening for debug connections on the configured port
  ## Returns: true on success, false on failure
  try:
    server.socket.setSockOpt(OptReuseAddr, true)
    server.socket.bindAddr(Port(server.port), "127.0.0.1")
    server.socket.listen()
    server.listening = true

    stderr.writeLine("DEBUG: Remote debug server listening on port " & $server.port)
    stderr.flushFile()
    return true
  except OSError as e:
    stderr.writeLine("ERROR: Failed to start debug server on port " & $server.port & ": " & e.msg)
    stderr.flushFile()
    return false

proc acceptConnection*(server: RegRemoteDebugServer, timeoutMs: int = 0): bool =
  ## Accept a connection from a debug client (VSCode)
  ## timeoutMs: Timeout in milliseconds (0 = block indefinitely)
  ## Returns: true if connection accepted, false on timeout or error
  try:
    if timeoutMs > 0:
      # Non-blocking accept with timeout
      server.socket.getFd().setBlocking(false)
      let startTime = epochTime()

      while true:
        try:
          # Don't create socket beforehand - accept() does it
          new(server.clientSocket)
          server.socket.accept(server.clientSocket)
          server.connected = true

          stderr.writeLine("DEBUG: Remote debug client connected")
          stderr.flushFile()

          # Set sockets back to blocking mode
          server.socket.getFd().setBlocking(true)
          server.clientSocket.getFd().setBlocking(true)
          return true

        except OSError as e:
          # Check if it's a "would block" error (no connection yet)
          if "Resource temporarily unavailable" in e.msg or "would block" in e.msg.toLowerAscii() or "Bad file descriptor" in e.msg:
            # Check timeout
            let elapsed = (epochTime() - startTime) * 1000.0
            if elapsed >= timeoutMs.float:
              stderr.writeLine("DEBUG: Connection timeout after " & $timeoutMs & "ms")
              stderr.flushFile()
              server.socket.getFd().setBlocking(true)
              return false

            # Sleep a bit before retrying
            sleep(100)  # Sleep for 100ms
            continue
          else:
            # Real error
            stderr.writeLine("ERROR: Failed to accept connection: " & e.msg)
            stderr.flushFile()
            server.socket.getFd().setBlocking(true)
            return false
    else:
      # Blocking accept
      new(server.clientSocket)
      server.socket.accept(server.clientSocket)
      server.connected = true

      stderr.writeLine("DEBUG: Remote debug client connected")
      stderr.flushFile()
      return true

  except OSError as e:
    stderr.writeLine("ERROR: Failed to accept connection: " & e.msg)
    stderr.flushFile()
    return false

proc sendMessage*(server: RegRemoteDebugServer, message: JsonNode) =
  ## Send a JSON message to the connected debug client
  if not server.connected or server.clientSocket == nil:
    stderr.writeLine("ERROR: Cannot send message - no client connected")
    stderr.flushFile()
    return

  try:
    let msgStr = $message & "\n"
    server.clientSocket.send(msgStr)
  except OSError as e:
    stderr.writeLine("ERROR: Failed to send message: " & e.msg)
    stderr.flushFile()
    server.connected = false

proc receiveMessage*(server: RegRemoteDebugServer, timeoutMs: int = 0): JsonNode =
  ## Receive a JSON message from the connected debug client
  ## timeoutMs: Timeout in milliseconds (0 = block indefinitely)
  ## Returns: Parsed JSON message or nil on error/timeout
  if not server.connected or server.clientSocket == nil:
    stderr.writeLine("ERROR: Cannot receive message - no client connected")
    stderr.flushFile()
    return nil

  try:
    var line = ""

    if timeoutMs > 0:
      # Non-blocking receive with timeout
      server.clientSocket.getFd().setBlocking(false)
      let startTime = epochTime()

      while true:
        try:
          line = server.clientSocket.recvLine()
          if line.len == 0:
            # Connection closed
            stderr.writeLine("DEBUG: Client disconnected")
            stderr.flushFile()
            server.connected = false
            server.clientSocket.getFd().setBlocking(true)
            return nil

          # Set back to blocking mode and return result
          server.clientSocket.getFd().setBlocking(true)
          return parseJson(line)

        except OSError as e:
          # Check if it's a "would block" error
          if "Resource temporarily unavailable" in e.msg or "would block" in e.msg.toLowerAscii():
            # Check timeout
            let elapsed = (epochTime() - startTime) * 1000.0
            if elapsed >= timeoutMs.float:
              server.clientSocket.getFd().setBlocking(true)
              return nil

            # Sleep a bit before retrying
            sleep(100)
            continue
          else:
            # Real error
            stderr.writeLine("ERROR: Failed to receive message: " & e.msg)
            stderr.flushFile()
            server.connected = false
            server.clientSocket.getFd().setBlocking(true)
            return nil
    else:
      # Blocking receive
      line = server.clientSocket.recvLine()
      if line.len == 0:
        # Connection closed
        stderr.writeLine("DEBUG: Client disconnected")
        stderr.flushFile()
        server.connected = false
        return nil

    # Parse JSON
    return parseJson(line)

  except OSError as e:
    # Don't log EINTR as error - it's expected when C++ debugger pauses the process
    if "Interrupted system call" notin e.msg:
      stderr.writeLine("ERROR: Failed to receive message: " & e.msg)
      stderr.flushFile()
      server.connected = false
    # Re-raise EINTR so caller can retry
    raise
  except JsonParsingError as e:
    stderr.writeLine("ERROR: Failed to parse JSON: " & e.msg)
    stderr.flushFile()
    return nil

proc handleRequest*(server: RegRemoteDebugServer, request: JsonNode): JsonNode =
  ## Handle a debug request and return response
  ## This wraps the existing RegDebugServer.handleDebugRequest
  ## Note: Events are automatically sent via the onDebugEvent handler set in newRegRemoteDebugServer

  # Handle the request using existing debug server logic
  let response = handleDebugRequest(server.server, request)

  # Add request metadata
  if request.hasKey("seq"):
    response["request_seq"] = request["seq"]
  response["type"] = %"response"
  response["command"] = request["command"]

  return response

proc runMessageLoop*(server: RegRemoteDebugServer): bool =
  ## Run the main message loop, handling debug requests until disconnection
  ## Returns: true if loop exited normally, false on error

  stderr.writeLine("DEBUG: Starting remote debug message loop")
  stderr.flushFile()

  while server.connected:
    # Receive request from client (with retry on EINTR)
    var request: JsonNode = nil
    var retries = 0
    const maxRetries = 3

    while retries < maxRetries:
      try:
        request = server.receiveMessage(timeoutMs = 0)  # Blocking
        break  # Success
      except OSError as e:
        if "Interrupted system call" in e.msg and retries < maxRetries - 1:
          # EINTR - retry (happens when C++ debugger pauses the process)
          stderr.writeLine("DEBUG: Receive interrupted (EINTR), retrying...")
          stderr.flushFile()
          retries += 1
          sleep(10)  # Brief pause before retry
          continue
        else:
          # Other error or max retries
          stderr.writeLine("ERROR: Failed to receive message: " & e.msg)
          stderr.flushFile()
          request = nil
          break

    if request == nil:
      # Connection closed or error
      break

    stderr.writeLine("DEBUG: Received request: " & request["command"].getStr())
    stderr.flushFile()

    # Handle the request
    let response = server.handleRequest(request)

    # Send response
    server.sendMessage(response)

    # Check for disconnect/terminate
    let command = request["command"].getStr()
    if command == "disconnect" or command == "terminate":
      stderr.writeLine("DEBUG: Received " & command & " command, exiting message loop")
      stderr.flushFile()
      break

  stderr.writeLine("DEBUG: Remote debug message loop ended")
  stderr.flushFile()
  return true

proc close*(server: RegRemoteDebugServer) =
  ## Close the debug server and all connections
  if server.clientSocket != nil:
    try:
      server.clientSocket.close()
    except:
      discard
    server.clientSocket = nil

  if server.socket != nil:
    try:
      server.socket.close()
    except:
      discard
    server.socket = nil

  server.connected = false
  server.listening = false

  stderr.writeLine("DEBUG: Remote debug server closed")
  stderr.flushFile()

proc isConnected*(server: RegRemoteDebugServer): bool =
  ## Check if a client is currently connected
  return server.connected and server.clientSocket != nil
