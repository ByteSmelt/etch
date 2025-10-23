# comptime.nim
# Compile-time evaluation and injection helpers for Etch

import std/[tables, options]
import common/[types]
import prover/[function_evaluation, types]
import frontend/ast
import interpreter/[regvm_compiler, regvm_exec, regvm]
import typechecker/[statements, types as tc_types]


proc hasImpureExpr(e: Expr): bool


proc hasImpureCalls(s: Stmt): bool =
  case s.kind
  of skExpr:
    return hasImpureExpr(s.sexpr)
  of skVar:
    if s.vinit.isSome:
      return hasImpureExpr(s.vinit.get)
  of skAssign:
    return hasImpureExpr(s.aval)
  of skIf:
    if hasImpureExpr(s.cond): return true
    for stmt in s.thenBody:
      if hasImpureCalls(stmt): return true
    for stmt in s.elseBody:
      if hasImpureCalls(stmt): return true
  of skWhile:
    if hasImpureExpr(s.wcond): return true
    for stmt in s.wbody:
      if hasImpureCalls(stmt): return true
  of skFor:
    if s.farray.isSome and hasImpureExpr(s.farray.get): return true
    if s.fstart.isSome and hasImpureExpr(s.fstart.get): return true
    if s.fend.isSome and hasImpureExpr(s.fend.get): return true
    for stmt in s.fbody:
      if hasImpureCalls(stmt): return true
  of skReturn:
    if s.re.isSome:
      return hasImpureExpr(s.re.get)
  else:
    discard
  return false


proc hasImpureExpr(e: Expr): bool =
  case e.kind
  of ekCall:
    if e.fname in ["print", "seed", "rand", "readFile"]:
      return true
    for arg in e.args:
      if hasImpureExpr(arg): return true
  of ekBin:
    return hasImpureExpr(e.lhs) or hasImpureExpr(e.rhs)
  of ekUn:
    return hasImpureExpr(e.ue)
  of ekArray:
    for elem in e.elements:
      if hasImpureExpr(elem): return true
  of ekIndex:
    return hasImpureExpr(e.arrayExpr) or hasImpureExpr(e.indexExpr)
  of ekSlice:
    if hasImpureExpr(e.sliceExpr): return true
    if e.startExpr.isSome and hasImpureExpr(e.startExpr.get): return true
    if e.endExpr.isSome and hasImpureExpr(e.endExpr.get): return true
  of ekNewRef:
    return hasImpureExpr(e.init)
  of ekDeref:
    return hasImpureExpr(e.refExpr)
  of ekCast:
    return hasImpureExpr(e.castExpr)
  else:
    discard
  return false


proc isPureFunction(fn: FunDecl): bool =
  for stmt in fn.body:
    if hasImpureCalls(stmt):
      return false
  return true


proc foldExpr(prog: Program, e: var Expr)
proc foldStmt(prog: Program, s: var Stmt)

proc foldExpr(prog: Program, e: var Expr) =
  case e.kind
  of ekBin:
    foldExpr(prog, e.lhs); foldExpr(prog, e.rhs)
  of ekUn:
    foldExpr(prog, e.ue)
  of ekCall:
    for i in 0..<e.args.len: foldExpr(prog, e.args[i])

    if prog.funInstances.hasKey(e.fname):
      let fn = prog.funInstances[e.fname]

      if isPureFunction(fn):
        var allConstLiterals = true
        var argInfos: seq[Info] = @[]

        for arg in e.args:
          case arg.kind
          of ekInt:
            argInfos.add(infoConst(arg.ival))
          of ekFloat:
            argInfos.add(infoConst(int64(arg.fval)))
          of ekBool:
            argInfos.add(infoConst(if arg.bval: 1'i64 else: 0'i64))
          of ekString:
            allConstLiterals = false
            break
          else:
            allConstLiterals = false
            break

        if allConstLiterals and argInfos.len == fn.params.len:
          let evalResult = tryEvaluatePureFunction(e, argInfos, fn, prog)
          if evalResult.isSome:
            e = Expr(kind: ekInt, ival: evalResult.get, pos: e.pos)
  of ekNewRef:
    foldExpr(prog, e.init)
  of ekDeref:
    foldExpr(prog, e.refExpr)
  of ekCast:
    foldExpr(prog, e.castExpr)
  of ekArray:
    for i in 0..<e.elements.len: foldExpr(prog, e.elements[i])
  of ekIndex:
    foldExpr(prog, e.arrayExpr)
    foldExpr(prog, e.indexExpr)
  of ekSlice:
    foldExpr(prog, e.sliceExpr)
    if e.startExpr.isSome: foldExpr(prog, e.startExpr.get)
    if e.endExpr.isSome: foldExpr(prog, e.endExpr.get)
  of ekIf:
    foldExpr(prog, e.ifCond)
    for i in 0..<e.ifThen.len: foldStmt(prog, e.ifThen[i])
    for i in 0..<e.ifElifChain.len:
      foldExpr(prog, e.ifElifChain[i].cond)
      for j in 0..<e.ifElifChain[i].body.len: foldStmt(prog, e.ifElifChain[i].body[j])
    for i in 0..<e.ifElse.len: foldStmt(prog, e.ifElse[i])
  of ekComptime:
    foldExpr(prog, e.comptimeExpr)

    # Try to evaluate the expression at compile-time
    if e.comptimeExpr.kind == ekCall:
      let call = e.comptimeExpr

      # Special handling for readFile which should be evaluated at compile-time
      if call.fname == "readFile" and call.args.len == 1 and call.args[0].kind == ekString:
        let filename = call.args[0].sval
        try:
          let content = readFile(filename)
          e = Expr(kind: ekString, sval: content, pos: e.pos)
        except Exception as ex:
          echo "Warning: Failed to read file '", filename, "' at compile-time: ", ex.msg
          echo "Exception: ", ex.getStackTrace()
      else:
        # For other functions, try to evaluate using the prover
        if prog.funInstances.hasKey(call.fname):
          let fn = prog.funInstances[call.fname]
          if isPureFunction(fn):
            var allConstLiterals = true
            var argInfos: seq[Info] = @[]

            for arg in call.args:
              case arg.kind
              of ekInt:
                argInfos.add(infoConst(arg.ival))
              of ekFloat:
                argInfos.add(infoConst(int64(arg.fval)))
              of ekBool:
                argInfos.add(infoConst(if arg.bval: 1'i64 else: 0'i64))
              else:
                allConstLiterals = false
                break

            if allConstLiterals and argInfos.len == fn.params.len:
              let evalResult = tryEvaluatePureFunction(call, argInfos, fn, prog)
              if evalResult.isSome:
                e = Expr(kind: ekInt, ival: evalResult.get, pos: e.pos)
    elif e.comptimeExpr.kind in [ekInt, ekFloat, ekString, ekBool]:
      # Already a constant, just use it
      e = e.comptimeExpr
  of ekCompiles:
    # Only evaluate if the type environment has been captured
    # This will be empty on the first fold pass (before typechecking)
    # and populated on the second pass (after typechecking)
    if e.compilesEnv.len == 0:
      # Skip for now - will be evaluated in second fold pass after typechecking
      discard
    else:
      # Try to compile the block and return true/false based on success
      var compiles = true
      try:
        # Create an isolated scope with captured outer scope types
        # This allows the compiles block to reference outer variables
        var isolatedScope = tc_types.Scope(
          types: e.compilesEnv,  # Use captured type environment
          flags: initTable[string, VarFlag](),
          userTypes: initTable[string, EtchType](),
          prog: prog
        )

        # Create a dummy function declaration for typechecking
        var dummyFd = FunDecl(
          name: "__compiles_check__",
          typarams: @[],
          params: @[],
          ret: tVoid(),
          body: e.compilesBlock,
          isExported: false,
          isCFFI: false
        )

        # Try to typecheck each statement in the block
        var subst = initTable[string, EtchType]()
        for stmt in e.compilesBlock:
          typecheckStmt(prog, dummyFd, isolatedScope, stmt, subst)
      except Exception as ex:
        # If any exception occurs during typechecking, the code doesn't compile
        compiles = false

      # Replace the compiles expression with a boolean literal
      e = Expr(kind: ekBool, bval: compiles, typ: tBool(), pos: e.pos)
  else: discard


proc foldStmt(prog: Program, s: var Stmt) =
  case s.kind
  of skVar:
    if s.vinit.isSome:
      var x = s.vinit.get
      foldExpr(prog, x)
      s.vinit = some(x)
      if s.vtype.kind == tkGeneric and s.vtype.name == "__comptime_infer__":
        case x.kind
        of ekInt:
          s.vtype = ast.tInt()
        of ekFloat:
          s.vtype = ast.tFloat()
        of ekString:
          s.vtype = ast.tString()
        of ekBool:
          s.vtype = ast.tBool()
        else:
          discard  # Will be caught by type checker
  of skAssign:
    var x = s.aval; foldExpr(prog, x)
    s.aval = x
  of skFieldAssign:
    var target = s.faTarget; foldExpr(prog, target)
    s.faTarget = target
    var value = s.faValue; foldExpr(prog, value)
    s.faValue = value
  of skDiscard:
    # Fold all discard expressions
    for i in 0..<s.dexprs.len:
      var expr = s.dexprs[i]
      foldExpr(prog, expr)
      s.dexprs[i] = expr
  of skIf:
    foldExpr(prog, s.cond)
    for i in 0..<s.thenBody.len: foldStmt(prog, s.thenBody[i])
    for i in 0..<s.elseBody.len: foldStmt(prog, s.elseBody[i])
  of skWhile:
    foldExpr(prog, s.wcond)
    for i in 0..<s.wbody.len: foldStmt(prog, s.wbody[i])
  of skFor:
    if s.farray.isSome():
      var x = s.farray.get(); foldExpr(prog, x)
      s.farray = some(x)
    else:
      var start = s.fstart.get()
      foldExpr(prog, start)
      s.fstart = some(start)
      var endVal = s.fend.get()
      foldExpr(prog, endVal)
      s.fend = some(endVal)
    for i in 0..<s.fbody.len: foldStmt(prog, s.fbody[i])
  of skExpr:
    var x = s.sexpr; foldExpr(prog, x)
    s.sexpr = x
  of skBreak:
    discard
  of skReturn:
    if s.re.isSome:
      var x = s.re.get; foldExpr(prog, x)
      s.re = some(x)
  of skComptime:
    for i in 0..<s.cbody.len:
      foldStmt(prog, s.cbody[i])

    # Clear the comptimeInjections table before execution
    comptimeInjections.clear()

    # Execute the comptime block using the VM
    try:
      # Create a temporary function containing the comptime block
      # Name it "main" so the VM will execute it as the entry point
      let comptimeFunc = FunDecl(
        name: "main",
        typarams: @[],
        params: @[],
        ret: tVoid(),
        body: s.cbody,
        isExported: false,
        isCFFI: false
      )

      # Create a temporary program with just this function
      var tempProg = Program(
        funs: initTable[string, seq[FunDecl]](),
        funInstances: initTable[string, FunDecl](),
        globals: @[],
        types: initTable[string, EtchType]()  # Don't share types to avoid pollution
      )
      tempProg.funInstances["main"] = comptimeFunc

      # Make all function instances available for comptime execution
      # But create copies to avoid modifying the original
      for name, funcDecl in prog.funInstances:
        if name != "main":
          tempProg.funInstances[name] = funcDecl

      # Compile to bytecode
      let bytecode = compileProgram(tempProg, optimizeLevel = 0, verbose = false, debug = false)

      # Execute the comptime block
      discard runRegProgram(bytecode, false)
    except Exception as e:
      echo "Warning: Failed to execute comptime block: ", e.msg
      echo "Exception: ", e.getStackTrace()

    # Now extract injected variables from the VM execution
    var injectedVars: seq[Stmt] = @[]

    # Process each inject() call in the AST to get the type information
    # The actual values come from comptimeInjections table
    for stmt in s.cbody:
      if stmt.kind == skExpr and stmt.sexpr.kind == ekCall and stmt.sexpr.fname == "inject":
        if stmt.sexpr.args.len == 3:
          let nameExpr = stmt.sexpr.args[0]
          let typeExpr = stmt.sexpr.args[1]

          if nameExpr.kind == ekString and typeExpr.kind == ekString:
            let varName = nameExpr.sval
            let typeStr = typeExpr.sval

            var varType: EtchType
            case typeStr:
              of "string": varType = tString()
              of "int": varType = tInt()
              of "bool": varType = tBool()
              of "float": varType = tFloat()
              else: varType = tString() # default to string

            # Get the actual value from the VM execution
            if comptimeInjections.hasKey(varName):
              let injectedValue = comptimeInjections[varName]

              # Convert VM value to AST expression
              var valueExpr: Expr
              if injectedValue.isInt():
                valueExpr = Expr(kind: ekInt, ival: injectedValue.ival, pos: stmt.pos)
              elif injectedValue.isFloat():
                valueExpr = Expr(kind: ekFloat, fval: injectedValue.fval, pos: stmt.pos)
              elif injectedValue.isString():
                valueExpr = Expr(kind: ekString, sval: injectedValue.sval, pos: stmt.pos)
              elif injectedValue.isBool():
                valueExpr = Expr(kind: ekBool, bval: injectedValue.bval, pos: stmt.pos)
              else:
                # Fallback to a default value
                valueExpr = Expr(kind: ekInt, ival: 0, pos: stmt.pos)

              let varDecl = Stmt(
                kind: skVar,
                vname: varName,
                vtype: varType,
                vinit: some(valueExpr),
                pos: stmt.pos
              )
              injectedVars.add(varDecl)

    s.cbody = injectedVars
  of skDefer:
    # Fold statements in defer body
    for i in 0..<s.deferBody.len:
      foldStmt(prog, s.deferBody[i])
  of skTypeDecl:
    discard
  of skImport:
    discard


proc foldComptime*(prog: Program, root: var Program) =
  for i in 0..<root.globals.len:
    var g = root.globals[i]; foldStmt(prog, g); root.globals[i] = g

  for fname, f in pairs(root.funInstances):
    for i in 0..<f.body.len:
      var s = f.body[i]; foldStmt(prog, s); f.body[i] = s

# Helper to only process ekCompiles expressions (skip comptime blocks)
proc foldCompilesInExpr(prog: Program, e: var Expr) =
  case e.kind
  of ekCompiles:
    # Process this if environment is populated
    if e.compilesEnv.len > 0:
      var compiles = true
      try:
        var isolatedScope = tc_types.Scope(
          types: e.compilesEnv,
          flags: initTable[string, VarFlag](),
          userTypes: initTable[string, EtchType](),
          prog: prog
        )
        var dummyFd = FunDecl(
          name: "__compiles_check__",
          typarams: @[],
          params: @[],
          ret: tVoid(),
          body: e.compilesBlock,
          isExported: false,
          isCFFI: false
        )
        var subst = initTable[string, EtchType]()
        for stmt in e.compilesBlock:
          typecheckStmt(prog, dummyFd, isolatedScope, stmt, subst)
      except Exception:
        compiles = false
      e = Expr(kind: ekBool, bval: compiles, typ: tBool(), pos: e.pos)
  of ekBin:
    foldCompilesInExpr(prog, e.lhs)
    foldCompilesInExpr(prog, e.rhs)
  of ekUn:
    foldCompilesInExpr(prog, e.ue)
  of ekIf:
    foldCompilesInExpr(prog, e.ifCond)
  else:
    discard  # Don't recurse further for other expression types

proc foldCompilesInStmt(prog: Program, s: var Stmt) =
  case s.kind
  of skVar:
    if s.vinit.isSome:
      var x = s.vinit.get
      foldCompilesInExpr(prog, x)
      s.vinit = some(x)
  of skAssign:
    foldCompilesInExpr(prog, s.aval)
  of skExpr:
    foldCompilesInExpr(prog, s.sexpr)
  of skIf:
    foldCompilesInExpr(prog, s.cond)
    for i in 0..<s.thenBody.len:
      foldCompilesInStmt(prog, s.thenBody[i])
    for i in 0..<s.elseBody.len:
      foldCompilesInStmt(prog, s.elseBody[i])
  of skWhile:
    foldCompilesInExpr(prog, s.wcond)
    for i in 0..<s.wbody.len:
      foldCompilesInStmt(prog, s.wbody[i])
  # Skip skComptime - don't reprocess comptime blocks!
  else:
    discard

# Second pass specifically for compiles{...} expressions after typechecking
# This is needed because compiles needs the type environment which is only available after typechecking
proc foldCompilesExprs*(prog: Program, root: var Program) =
  for i in 0..<root.globals.len:
    foldCompilesInStmt(prog, root.globals[i])

  for fname, f in pairs(root.funInstances):
    for i in 0..<f.body.len:
      foldCompilesInStmt(prog, f.body[i])
