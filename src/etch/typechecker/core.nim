# core.nim
# Main type checker core functions and unified type inference

import std/[tables]
import ../frontend/ast
import types, statements


proc typecheck*(prog: Program) =
  var subst: TySubst

  # First pass: collect all variable declarations for forward references
  var gscope = Scope(
    types: initTable[string, EtchType](),
    flags: initTable[string, VarFlag](),
    userTypes: initTable[string, EtchType](),
    prog: prog
  )

  # Second pass: add all user-defined types to scope
  for typeName, typeDecl in prog.types:
    gscope.userTypes[typeName] = typeDecl

  # Third pass: add all global variable types to scope (without checking initializers)
  for g in prog.globals:
    if g.kind == skVar:
      gscope.types[g.vname] = g.vtype
      gscope.flags[g.vname] = g.vflag

  # Fourth pass: typecheck all global statements with complete scope
  for g in prog.globals:
    typecheckStmt(prog, nil, gscope, g, subst)
