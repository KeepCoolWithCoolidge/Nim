#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Dominik Picheta
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## This module implements nice syntactic sugar based on Nim's
## macro system.

import macros

proc createProcType(p, b: NimNode): NimNode {.compileTime.} =
  #echo treeRepr(p)
  #echo treeRepr(b)
  result = newNimNode(nnkProcTy)
  var formalParams = newNimNode(nnkFormalParams)

  formalParams.add b

  case p.kind
  of nnkPar, nnkTupleConstr:
    for i in 0 ..< p.len:
      let ident = p[i]
      var identDefs = newNimNode(nnkIdentDefs)
      case ident.kind
      of nnkExprColonExpr:
        identDefs.add ident[0]
        identDefs.add ident[1]
      else:
        identDefs.add newIdentNode("i" & $i)
        identDefs.add(ident)
      identDefs.add newEmptyNode()
      formalParams.add identDefs
  else:
    var identDefs = newNimNode(nnkIdentDefs)
    identDefs.add newIdentNode("i0")
    identDefs.add(p)
    identDefs.add newEmptyNode()
    formalParams.add identDefs

  result.add formalParams
  result.add newEmptyNode()
  #echo(treeRepr(result))
  #echo(result.toStrLit())

macro `=>`*(p, b: untyped): untyped =
  ## Syntax sugar for anonymous procedures.
  ##
  ## .. code-block:: nim
  ##
  ##   proc passTwoAndTwo(f: (int, int) -> int): int =
  ##     f(2, 2)
  ##
  ##   passTwoAndTwo((x, y) => x + y) # 4

  #echo treeRepr(p)
  #echo(treeRepr(b))
  var params: seq[NimNode] = @[newIdentNode("auto")]

  case p.kind
  of nnkPar, nnkTupleConstr:
    for c in children(p):
      var identDefs = newNimNode(nnkIdentDefs)
      case c.kind
      of nnkExprColonExpr:
        identDefs.add(c[0])
        identDefs.add(c[1])
        identDefs.add(newEmptyNode())
      of nnkIdent:
        identDefs.add(c)
        identDefs.add(newIdentNode("auto"))
        identDefs.add(newEmptyNode())
      of nnkInfix:
        if c[0].kind == nnkIdent and c[0].ident == !"->":
          var procTy = createProcType(c[1], c[2])
          params[0] = procTy[0][0]
          for i in 1 ..< procTy[0].len:
            params.add(procTy[0][i])
        else:
          error("Expected proc type (->) got (" & $c[0].ident & ").")
        break
      else:
        echo treeRepr c
        error("Incorrect procedure parameter list.")
      params.add(identDefs)
  of nnkIdent:
    var identDefs = newNimNode(nnkIdentDefs)
    identDefs.add(p)
    identDefs.add(newIdentNode("auto"))
    identDefs.add(newEmptyNode())
    params.add(identDefs)
  of nnkInfix:
    if p[0].kind == nnkIdent and p[0].ident == !"->":
      var procTy = createProcType(p[1], p[2])
      params[0] = procTy[0][0]
      for i in 1 ..< procTy[0].len:
        params.add(procTy[0][i])
    else:
      error("Expected proc type (->) got (" & $p[0].ident & ").")
  else:
    error("Incorrect procedure parameter list.")
  result = newProc(params = params, body = b, procType = nnkLambda)
  #echo(result.treeRepr)
  #echo(result.toStrLit())
  #return result # TODO: Bug?

macro `->`*(p, b: untyped): untyped =
  ## Syntax sugar for procedure types.
  ##
  ## .. code-block:: nim
  ##
  ##   proc pass2(f: (float, float) -> float): float =
  ##     f(2, 2)
  ##
  ##   # is the same as:
  ##
  ##   proc pass2(f: proc (x, y: float): float): float =
  ##     f(2, 2)

  result = createProcType(p, b)

macro dump*(x: typed): untyped =
  ## Dumps the content of an expression, useful for debugging.
  ## It accepts any expression and prints a textual representation
  ## of the tree representing the expression - as it would appear in
  ## source code - together with the value of the expression.
  ##
  ## As an example,
  ##
  ## .. code-block:: nim
  ##   let
  ##     x = 10
  ##     y = 20
  ##   dump(x + y)
  ##
  ## will print ``x + y = 30``.
  let s = x.toStrLit
  let r = quote do:
    debugEcho `s`, " = ", `x`
  return r

# TODO: consider exporting this in macros.nim
proc freshIdentNodes(ast: NimNode): NimNode =
  # Replace NimIdent and NimSym by a fresh ident node
  # see also https://github.com/nim-lang/Nim/pull/8531#issuecomment-410436458
  proc inspect(node: NimNode): NimNode =
    case node.kind:
    of nnkIdent, nnkSym:
      result = ident($node)
    of nnkEmpty, nnkLiterals:
      result = node
    else:
      result = node.kind.newTree()
      for child in node:
        result.add inspect(child)
  result = inspect(ast)

macro distinctBase*(T: typedesc): untyped =
  ## reverses ``type T = distinct A``; works recursively.
  runnableExamples:
    type T = distinct int
    doAssert distinctBase(T) is int
    doAssert: not compiles(distinctBase(int))
    type T2 = distinct T
    doAssert distinctBase(T2) is int

  let typeNode = getTypeImpl(T)
  expectKind(typeNode, nnkBracketExpr)
  if typeNode[0].typeKind != ntyTypeDesc:
    error "expected typeDesc, got " & $typeNode[0]
  var typeSym = typeNode[1]
  typeSym = getTypeImpl(typeSym)
  if typeSym.typeKind != ntyDistinct:
    error "type is not distinct"
  typeSym = typeSym[0]
  while typeSym.typeKind == ntyDistinct:
    typeSym = getTypeImpl(typeSym)[0]
  typeSym.freshIdentNodes

when (NimMajor, NimMinor) >= (1, 1):
  macro outplace*[T](arg: T, call: untyped; inplaceArgPosition: static[int] = 1): T =
    ## Turns an `in-place`:idx: algorithm into one that works on
    ## a copy and returns this copy. The second parameter is the
    ## index of the calling expression that is replaced by a copy
    ## of this expression.
    ## **Since**: Version 1.2.
    runnableExamples:
      import algorithm

      var a = @[1, 2, 3, 4, 5, 6, 7, 8, 9]
      doAssert a.outplace(sort()) == sorted(a)
      #Chaining:
      var aCopy = a
      aCopy.insert(10)

      doAssert a.outplace(insert(10)).outplace(sort()) == sorted(aCopy)

    expectKind call, nnkCallKinds
    let tmp = genSym(nskVar, "outplaceResult")
    var callsons = call[0..^1]
    callsons.insert(tmp, inplaceArgPosition)
    result = newTree(nnkStmtListExpr,
      newVarStmt(tmp, arg),
      copyNimNode(call).add callsons,
      tmp)

  proc transLastStmt(n, res, bracketExpr: NimNode): (NimNode, NimNode, NimNode) =
    # Looks for the last statement of the last statement, etc...
    case n.kind
    of nnkStmtList, nnkStmtListExpr, nnkBlockStmt, nnkBlockExpr, nnkWhileStmt,
        nnkForStmt, nnkIfExpr, nnkIfStmt, nnkTryStmt, nnkCaseStmt,
        nnkElifBranch, nnkElse, nnkElifExpr:
      result[0] = copyNimTree(n)
      result[1] = copyNimTree(n)
      result[2] = copyNimTree(n)
      if n.len >= 1:
        (result[0][^1], result[1][^1], result[2][^1]) = transLastStmt(n[^1], res,
            bracketExpr)
    of nnkTableConstr:
      result[1] = n[0][0]
      result[2] = n[0][1]
      bracketExpr.add([newCall(bindSym"typeof", newEmptyNode()), newCall(
          bindSym"typeof", newEmptyNode())])
      template adder(res, k, v) = res[k] = v
      result[0] = getAst(adder(res, n[0][0], n[0][1]))
    of nnkCurly:
      result[2] = n[0]
      bracketExpr.add(newCall(bindSym"typeof", newEmptyNode()))
      template adder(res, v) = res.incl(v)
      result[0] = getAst(adder(res, n[0]))
    else:
      result[2] = n
      bracketExpr.add(newCall(bindSym"typeof", newEmptyNode()))
      template adder(res, v) = res.add(v)
      result[0] = getAst(adder(res, n))

  macro collect*(init, body: untyped): untyped =
    ## Comprehension for seq/set/table collections. ``init`` is
    ## the init call, and so custom collections are supported.
    ##
    ## The last statement of ``body`` has special syntax that specifies
    ## the collection's add operation. Use ``{e}`` for set's ``incl``,
    ## ``{k: v}`` for table's ``[]=`` and ``e`` for seq's ``add``.
    ##
    ## The ``init`` proc can be called with any number of arguments,
    ## i.e. ``initTable(initialSize)``.
    runnableExamples:
      import sets, tables
      let data = @["bird", "word"]
      ## seq:
      let k = collect(newSeq):
        for i, d in data.pairs:
          if i mod 2 == 0: d

      assert k == @["bird"]
      ## seq with initialSize:
      let x = collect(newSeqOfCap(4)):
        for i, d in data.pairs:
          if i mod 2 == 0: d

      assert x == @["bird"]
      ## HashSet:
      let y = initHashSet.collect:
        for d in data.items: {d}

      assert y == data.toHashSet
      ## Table:
      let z = collect(initTable(2)):
        for i, d in data.pairs: {i: d}

      assert z == {1: "word", 0: "bird"}.toTable
    # analyse the body, find the deepest expression 'it' and replace it via
    # 'result.add it'
    let res = genSym(nskVar, "collectResult")
    expectKind init, {nnkCall, nnkIdent, nnkSym}
    let bracketExpr = newTree(nnkBracketExpr,
      if init.kind == nnkCall: init[0] else: init)
    let (resBody, keyType, valueType) = transLastStmt(body, res, bracketExpr)
    if bracketExpr.len == 3:
      bracketExpr[1][1] = keyType
      bracketExpr[2][1] = valueType
    else:
      bracketExpr[1][1] = valueType
    let call = newTree(nnkCall, bracketExpr)
    if init.kind == nnkCall:
      for i in 1 ..< init.len:
        call.add init[i]
    result = newTree(nnkStmtListExpr, newVarStmt(res, call), resBody, res)

  when isMainModule:
    import algorithm

    var a = @[1, 2, 3, 4, 5, 6, 7, 8, 9]
    doAssert outplace(a, sort()) == sorted(a)
    doAssert a.outplace(sort()) == sorted(a)
    #Chaining:
    var aCopy = a
    aCopy.insert(10)
    doAssert a.outplace(insert(10)).outplace(sort()) == sorted(aCopy)

    import random

    const b = @[0, 1, 2]
    let c = b.outplace shuffle()
    doAssert c[0] == 1
    doAssert c[1] == 0

    #test collect
    import sets, tables

    let data = @["bird", "word"] # if this gets stuck in your head, its not my fault
    assert collect(newSeq, for (i, d) in data.pairs: (if i mod 2 == 0: d)) == @["bird"]
    assert collect(initTable(2), for (i, d) in data.pairs: {i: d}) == {1: "word",
          0: "bird"}.toTable
    assert initHashSet.collect(for d in data.items: {d}) == data.toHashSet

    let x = collect(newSeqOfCap(4)):
        for (i, d) in data.pairs:
          if i mod 2 == 0: d
    assert x == @["bird"]
