#
#
#           The Nim Compiler
#        (c) Copyright 2013 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# Module providing functions for calling the different external C compilers
# Uses some hard-wired facts about each C/C++ compiler, plus options read
# from a lineinfos file, to provide generalized procedures to compile
# nim files.

import
  ropes, os, strutils, osproc, platform, condsyms, options, msgs,
  lineinfos, std / sha1, streams, pathutils, sequtils, times, strtabs

type
  TInfoCCProp* = enum         # properties of the C compiler:
    hasSwitchRange,           # CC allows ranges in switch statements (GNU C)
    hasComputedGoto,          # CC has computed goto (GNU C extension)
    hasCpp,                   # CC is/contains a C++ compiler
    hasAssume,                # CC has __assume (Visual C extension)
    hasGcGuard,               # CC supports GC_GUARD to keep stack roots
    hasGnuAsm,                # CC's asm uses the absurd GNU assembler syntax
    hasDeclspec,              # CC has __declspec(X)
    hasAttribute,             # CC has __attribute__((X))
  TInfoCCProps* = set[TInfoCCProp]
  TInfoCC* = tuple[
    name: string,        # the short name of the compiler
    objExt: string,      # the compiler's object file extension
    optSpeed: string,    # the options for optimization for speed
    optSize: string,     # the options for optimization for size
    compilerExe: string, # the compiler's executable
    cppCompiler: string, # name of the C++ compiler's executable (if supported)
    compileTmpl: string, # the compile command template
    buildGui: string,    # command to build a GUI application
    buildDll: string,    # command to build a shared library
    buildLib: string,    # command to build a static library
    linkerExe: string,   # the linker's executable (if not matching compiler's)
    linkTmpl: string,    # command to link files to produce an exe
    includeCmd: string,  # command to add an include dir
    linkDirCmd: string,  # command to add a lib dir
    linkLibCmd: string,  # command to link an external library
    debug: string,       # flags for debug build
    pic: string,         # command for position independent code
                         # used on some platforms
    asmStmtFrmt: string, # format of ASM statement
    structStmtFmt: string, # Format for struct statement
    produceAsm: string,   # Format how to produce assembler listings
    props: TInfoCCProps] # properties of the C compiler


# Configuration settings for various compilers.
# When adding new compilers, the cmake sources could be a good reference:
# http://cmake.org/gitweb?p=cmake.git;a=tree;f=Modules/Platform;

template compiler(name, settings: untyped): untyped =
  proc name: TInfoCC {.compileTime.} = settings

const
  gnuAsmListing = "-Wa,-acdl=$asmfile -g -fverbose-asm -masm=intel"

# GNU C and C++ Compiler
compiler gcc:
  result = (
    name: "gcc",
    objExt: "o",
    optSpeed: " -O3 -fno-ident",
    optSize: " -Os -fno-ident",
    compilerExe: "gcc",
    cppCompiler: "g++",
    compileTmpl: "-c $options $include -o $objfile $file",
    buildGui: " -mwindows",
    buildDll: " -shared",
    buildLib: "ar rcs $libfile $objfiles",
    linkerExe: "",
    linkTmpl: "$buildgui $builddll -o $exefile $objfiles $options",
    includeCmd: " -I",
    linkDirCmd: " -L",
    linkLibCmd: " -l$1",
    debug: "",
    pic: "-fPIC",
    asmStmtFrmt: "asm($1);$n",
    structStmtFmt: "$1 $3 $2 ", # struct|union [packed] $name
    produceAsm: gnuAsmListing,
    props: {hasSwitchRange, hasComputedGoto, hasCpp, hasGcGuard, hasGnuAsm,
            hasAttribute})

# GNU C and C++ Compiler
compiler nintendoSwitchGCC:
  result = (
    name: "switch_gcc",
    objExt: "o",
    optSpeed: " -O3 ",
    optSize: " -Os ",
    compilerExe: "aarch64-none-elf-gcc",
    cppCompiler: "aarch64-none-elf-g++",
    compileTmpl: "-w -MMD -MP -MF $dfile -c $options $include -o $objfile $file",
    buildGui: " -mwindows",
    buildDll: " -shared",
    buildLib: "aarch64-none-elf-gcc-ar rcs $libfile $objfiles",
    linkerExe: "aarch64-none-elf-gcc",
    linkTmpl: "$buildgui $builddll -Wl,-Map,$mapfile -o $exefile $objfiles $options",
    includeCmd: " -I",
    linkDirCmd: " -L",
    linkLibCmd: " -l$1",
    debug: "",
    pic: "-fPIE",
    asmStmtFrmt: "asm($1);$n",
    structStmtFmt: "$1 $3 $2 ", # struct|union [packed] $name
    produceAsm: gnuAsmListing,
    props: {hasSwitchRange, hasComputedGoto, hasCpp, hasGcGuard, hasGnuAsm,
            hasAttribute})

# LLVM Frontend for GCC/G++
compiler llvmGcc:
  result = gcc() # Uses settings from GCC

  result.name = "llvm_gcc"
  result.compilerExe = "llvm-gcc"
  result.cppCompiler = "llvm-g++"
  when defined(macosx):
    # OS X has no 'llvm-ar' tool:
    result.buildLib = "ar rcs $libfile $objfiles"
  else:
    result.buildLib = "llvm-ar rcs $libfile $objfiles"

# Clang (LLVM) C/C++ Compiler
compiler clang:
  result = llvmGcc() # Uses settings from llvmGcc

  result.name = "clang"
  result.compilerExe = "clang"
  result.cppCompiler = "clang++"

# Microsoft Visual C/C++ Compiler
compiler vcc:
  result = (
    name: "vcc",
    objExt: "obj",
    optSpeed: " /Ogityb2 /G7 ",
    optSize: " /O1 /G7 ",
    compilerExe: "cl",
    cppCompiler: "cl",
    compileTmpl: "/c$vccplatform $options $include /Fo$objfile $file",
    buildGui: " /link /SUBSYSTEM:WINDOWS ",
    buildDll: " /LD",
    buildLib: "lib /OUT:$libfile $objfiles",
    linkerExe: "cl",
    linkTmpl: "$options $builddll$vccplatform /Fe$exefile $objfiles $buildgui",
    includeCmd: " /I",
    linkDirCmd: " /LIBPATH:",
    linkLibCmd: " $1.lib",
    debug: " /RTC1 /Z7 ",
    pic: "",
    asmStmtFrmt: "__asm{$n$1$n}$n",
    structStmtFmt: "$3$n$1 $2",
    produceAsm: "/Fa$asmfile",
    props: {hasCpp, hasAssume, hasDeclspec})

compiler clangcl:
  result = vcc()
  result.name = "clang_cl"
  result.compilerExe = "clang-cl"
  result.cppCompiler = "clang-cl"
  result.linkerExe = "clang-cl"

# Intel C/C++ Compiler
compiler icl:
  result = vcc()
  result.name = "icl"
  result.compilerExe = "icl"
  result.linkerExe = "icl"

# Intel compilers try to imitate the native ones (gcc and msvc)
compiler icc:
  result = gcc()
  result.name = "icc"
  result.compilerExe = "icc"
  result.linkerExe = "icc"

# Local C Compiler
compiler lcc:
  result = (
    name: "lcc",
    objExt: "obj",
    optSpeed: " -O -p6 ",
    optSize: " -O -p6 ",
    compilerExe: "lcc",
    cppCompiler: "",
    compileTmpl: "$options $include -Fo$objfile $file",
    buildGui: " -subsystem windows",
    buildDll: " -dll",
    buildLib: "", # XXX: not supported yet
    linkerExe: "lcclnk",
    linkTmpl: "$options $buildgui $builddll -O $exefile $objfiles",
    includeCmd: " -I",
    linkDirCmd: "", # XXX: not supported yet
    linkLibCmd: "", # XXX: not supported yet
    debug: " -g5 ",
    pic: "",
    asmStmtFrmt: "_asm{$n$1$n}$n",
    structStmtFmt: "$1 $2",
    produceAsm: "",
    props: {})

# Borland C Compiler
compiler bcc:
  result = (
    name: "bcc",
    objExt: "obj",
    optSpeed: " -O3 -6 ",
    optSize: " -O1 -6 ",
    compilerExe: "bcc32c",
    cppCompiler: "cpp32c",
    compileTmpl: "-c $options $include -o$objfile $file",
    buildGui: " -tW",
    buildDll: " -tWD",
    buildLib: "", # XXX: not supported yet
    linkerExe: "bcc32",
    linkTmpl: "$options $buildgui $builddll -e$exefile $objfiles",
    includeCmd: " -I",
    linkDirCmd: "", # XXX: not supported yet
    linkLibCmd: "", # XXX: not supported yet
    debug: "",
    pic: "",
    asmStmtFrmt: "__asm{$n$1$n}$n",
    structStmtFmt: "$1 $2",
    produceAsm: "",
    props: {hasSwitchRange, hasComputedGoto, hasCpp, hasGcGuard,
            hasAttribute})

# Digital Mars C Compiler
compiler dmc:
  result = (
    name: "dmc",
    objExt: "obj",
    optSpeed: " -ff -o -6 ",
    optSize: " -ff -o -6 ",
    compilerExe: "dmc",
    cppCompiler: "",
    compileTmpl: "-c $options $include -o$objfile $file",
    buildGui: " -L/exet:nt/su:windows",
    buildDll: " -WD",
    buildLib: "", # XXX: not supported yet
    linkerExe: "dmc",
    linkTmpl: "$options $buildgui $builddll -o$exefile $objfiles",
    includeCmd: " -I",
    linkDirCmd: "", # XXX: not supported yet
    linkLibCmd: "", # XXX: not supported yet
    debug: " -g ",
    pic: "",
    asmStmtFrmt: "__asm{$n$1$n}$n",
    structStmtFmt: "$3$n$1 $2",
    produceAsm: "",
    props: {hasCpp})

# Watcom C Compiler
compiler wcc:
  result = (
    name: "wcc",
    objExt: "obj",
    optSpeed: " -ox -on -6 -d0 -fp6 -zW ",
    optSize: "",
    compilerExe: "wcl386",
    cppCompiler: "",
    compileTmpl: "-c $options $include -fo=$objfile $file",
    buildGui: " -bw",
    buildDll: " -bd",
    buildLib: "", # XXX: not supported yet
    linkerExe: "wcl386",
    linkTmpl: "$options $buildgui $builddll -fe=$exefile $objfiles ",
    includeCmd: " -i=",
    linkDirCmd: "", # XXX: not supported yet
    linkLibCmd: "", # XXX: not supported yet
    debug: " -d2 ",
    pic: "",
    asmStmtFrmt: "__asm{$n$1$n}$n",
    structStmtFmt: "$1 $2",
    produceAsm: "",
    props: {hasCpp})

# Tiny C Compiler
compiler tcc:
  result = (
    name: "tcc",
    objExt: "o",
    optSpeed: "",
    optSize: "",
    compilerExe: "tcc",
    cppCompiler: "",
    compileTmpl: "-c $options $include -o $objfile $file",
    buildGui: "-Wl,-subsystem=gui",
    buildDll: " -shared",
    buildLib: "", # XXX: not supported yet
    linkerExe: "tcc",
    linkTmpl: "-o $exefile $options $buildgui $builddll $objfiles",
    includeCmd: " -I",
    linkDirCmd: "", # XXX: not supported yet
    linkLibCmd: "", # XXX: not supported yet
    debug: " -g ",
    pic: "",
    asmStmtFrmt: "__asm{$n$1$n}$n",
    structStmtFmt: "$1 $2",
    produceAsm: "",
    props: {hasSwitchRange, hasComputedGoto})

# Pelles C Compiler
compiler pcc:
  # Pelles C
  result = (
    name: "pcc",
    objExt: "obj",
    optSpeed: " -Ox ",
    optSize: " -Os ",
    compilerExe: "cc",
    cppCompiler: "",
    compileTmpl: "-c $options $include -Fo$objfile $file",
    buildGui: " -SUBSYSTEM:WINDOWS",
    buildDll: " -DLL",
    buildLib: "", # XXX: not supported yet
    linkerExe: "cc",
    linkTmpl: "$options $buildgui $builddll -OUT:$exefile $objfiles",
    includeCmd: " -I",
    linkDirCmd: "", # XXX: not supported yet
    linkLibCmd: "", # XXX: not supported yet
    debug: " -Zi ",
    pic: "",
    asmStmtFrmt: "__asm{$n$1$n}$n",
    structStmtFmt: "$1 $2",
    produceAsm: "",
    props: {})

# Your C Compiler
compiler ucc:
  result = (
    name: "ucc",
    objExt: "o",
    optSpeed: " -O3 ",
    optSize: " -O1 ",
    compilerExe: "cc",
    cppCompiler: "",
    compileTmpl: "-c $options $include -o $objfile $file",
    buildGui: "",
    buildDll: " -shared ",
    buildLib: "", # XXX: not supported yet
    linkerExe: "cc",
    linkTmpl: "-o $exefile $buildgui $builddll $objfiles $options",
    includeCmd: " -I",
    linkDirCmd: "", # XXX: not supported yet
    linkLibCmd: "", # XXX: not supported yet
    debug: "",
    pic: "",
    asmStmtFrmt: "__asm{$n$1$n}$n",
    structStmtFmt: "$1 $2",
    produceAsm: "",
    props: {})

const
  CC*: array[succ(low(TSystemCC))..high(TSystemCC), TInfoCC] = [
    gcc(),
    nintendoSwitchGCC(),
    llvmGcc(),
    clang(),
    lcc(),
    bcc(),
    dmc(),
    wcc(),
    vcc(),
    tcc(),
    pcc(),
    ucc(),
    icl(),
    icc(),
    clangcl()]

  hExt* = ".h"

proc libNameTmpl(conf: ConfigRef): string {.inline.} =
  result = if conf.target.targetOS == osWindows: "$1.lib" else: "lib$1.a"

proc nameToCC*(name: string): TSystemCC =
  ## Returns the kind of compiler referred to by `name`, or ccNone
  ## if the name doesn't refer to any known compiler.
  for i in succ(ccNone)..high(TSystemCC):
    if cmpIgnoreStyle(name, CC[i].name) == 0:
      return i
  result = ccNone

proc listCCnames(): seq[string] =
  for i in succ(ccNone)..high(TSystemCC):
    result.add CC[i].name

proc isVSCompatible*(conf: ConfigRef): bool =
  return conf.cCompiler == ccVcc or
          conf.cCompiler == ccClangCl or
          (conf.cCompiler == ccIcl and conf.target.hostOS in osDos..osWindows)

proc getConfigVar(conf: ConfigRef; c: TSystemCC, suffix: string): string =
  # use ``cpu.os.cc`` for cross compilation, unless ``--compileOnly`` is given
  # for niminst support
  let fullSuffix =
    if conf.cmd == cmdCompileToCpp:
      ".cpp" & suffix
    elif conf.cmd == cmdCompileToOC:
      ".objc" & suffix
    elif conf.cmd == cmdCompileToJS:
      ".js" & suffix
    else:
      suffix

  if (conf.target.hostOS != conf.target.targetOS or conf.target.hostCPU != conf.target.targetCPU) and
      optCompileOnly notin conf.globalOptions:
    let fullCCname = platform.CPU[conf.target.targetCPU].name & '.' &
                     platform.OS[conf.target.targetOS].name & '.' &
                     CC[c].name & fullSuffix
    result = getConfigVar(conf, fullCCname)
    if result.len == 0:
      # not overridden for this cross compilation setting?
      result = getConfigVar(conf, CC[c].name & fullSuffix)
  else:
    result = getConfigVar(conf, CC[c].name & fullSuffix)

proc setCC*(conf: ConfigRef; ccname: string; info: TLineInfo) =
  conf.cCompiler = nameToCC(ccname)
  if conf.cCompiler == ccNone:
    let ccList = listCCnames().join(", ")
    localError(conf, info, "unknown C compiler: '$1'. Available options are: $2" % [ccname, ccList])
  conf.compileOptions = getConfigVar(conf, conf.cCompiler, ".options.always")
  conf.linkOptions = ""
  conf.cCompilerPath = getConfigVar(conf, conf.cCompiler, ".path")
  for i in low(CC)..high(CC): undefSymbol(conf.symbols, CC[i].name)
  defineSymbol(conf.symbols, CC[conf.cCompiler].name)

proc addOpt(dest: var string, src: string) =
  if dest.len == 0 or dest[^1] != ' ': dest.add(" ")
  dest.add(src)

proc addLinkOption*(conf: ConfigRef; option: string) =
  addOpt(conf.linkOptions, option)

proc addCompileOption*(conf: ConfigRef; option: string) =
  if strutils.find(conf.compileOptions, option, 0) < 0:
    addOpt(conf.compileOptions, option)

proc addLinkOptionCmd*(conf: ConfigRef; option: string) =
  addOpt(conf.linkOptionsCmd, option)

proc addCompileOptionCmd*(conf: ConfigRef; option: string) =
  conf.compileOptionsCmd.add(option)

proc initVars*(conf: ConfigRef) =
  # we need to define the symbol here, because ``CC`` may have never been set!
  for i in low(CC)..high(CC): undefSymbol(conf.symbols, CC[i].name)
  defineSymbol(conf.symbols, CC[conf.cCompiler].name)
  addCompileOption(conf, getConfigVar(conf, conf.cCompiler, ".options.always"))
  #addLinkOption(getConfigVar(cCompiler, ".options.linker"))
  if conf.cCompilerPath.len == 0:
    conf.cCompilerPath = getConfigVar(conf, conf.cCompiler, ".path")

proc completeCfilePath*(conf: ConfigRef; cfile: AbsoluteFile,
                        createSubDir: bool = true): AbsoluteFile =
  result = completeGeneratedFilePath(conf, cfile, createSubDir)

proc toObjFile*(conf: ConfigRef; filename: AbsoluteFile): AbsoluteFile =
  # Object file for compilation
  result = AbsoluteFile(filename.string & "." & CC[conf.cCompiler].objExt)

proc addFileToCompile*(conf: ConfigRef; cf: Cfile) =
  conf.toCompile.add(cf)

proc addLocalCompileOption*(conf: ConfigRef; option: string; nimfile: AbsoluteFile) =
  let key = completeCfilePath(conf, withPackageName(conf, nimfile)).string
  var value = conf.cfileSpecificOptions.getOrDefault(key)
  if strutils.find(value, option, 0) < 0:
    addOpt(value, option)
    conf.cfileSpecificOptions[key] = value

proc resetCompilationLists*(conf: ConfigRef) =
  conf.toCompile.setLen 0
  ## XXX: we must associate these with their originating module
  # when the module is loaded/unloaded it adds/removes its items
  # That's because we still need to hash check the external files
  # Maybe we can do that in checkDep on the other hand?
  conf.externalToLink.setLen 0

proc addExternalFileToLink*(conf: ConfigRef; filename: AbsoluteFile) =
  conf.externalToLink.insert(filename.string, 0)

proc execWithEcho(conf: ConfigRef; cmd: string, msg = hintExecuting): int =
  rawMessage(conf, msg, cmd)
  result = execCmd(cmd)

proc execExternalProgram*(conf: ConfigRef; cmd: string, msg = hintExecuting) =
  if execWithEcho(conf, cmd, msg) != 0:
    rawMessage(conf, errGenerated, "execution of an external program failed: '$1'" %
      cmd)

proc generateScript(conf: ConfigRef; script: Rope) =
  let (_, name, _) = splitFile(conf.outFile.string)
  let filename = getNimcacheDir(conf) / RelativeFile(addFileExt("compile_" & name,
                                     platform.OS[conf.target.targetOS].scriptExt))
  if writeRope(script, filename):
    copyFile(conf.libpath / RelativeFile"nimbase.h",
             getNimcacheDir(conf) / RelativeFile"nimbase.h")
  else:
    rawMessage(conf, errGenerated, "could not write to file: " & filename.string)

proc getOptSpeed(conf: ConfigRef; c: TSystemCC): string =
  result = getConfigVar(conf, c, ".options.speed")
  if result == "":
    result = CC[c].optSpeed   # use default settings from this file

proc getDebug(conf: ConfigRef; c: TSystemCC): string =
  result = getConfigVar(conf, c, ".options.debug")
  if result == "":
    result = CC[c].debug      # use default settings from this file

proc getOptSize(conf: ConfigRef; c: TSystemCC): string =
  result = getConfigVar(conf, c, ".options.size")
  if result == "":
    result = CC[c].optSize    # use default settings from this file

proc noAbsolutePaths(conf: ConfigRef): bool {.inline.} =
  # We used to check current OS != specified OS, but this makes no sense
  # really: Cross compilation from Linux to Linux for example is entirely
  # reasonable.
  # `optGenMapping` is included here for niminst.
  result = conf.globalOptions * {optGenScript, optGenMapping} != {}

proc cFileSpecificOptions(conf: ConfigRef; nimname, fullNimFile: string): string =
  result = conf.compileOptions
  addOpt(result, conf.cfileSpecificOptions.getOrDefault(fullNimFile))

  for option in conf.compileOptionsCmd:
    if strutils.find(result, option, 0) < 0:
      addOpt(result, option)

  if optCDebug in conf.globalOptions:
    let key = nimname & ".debug"
    if existsConfigVar(conf, key): addOpt(result, getConfigVar(conf, key))
    else: addOpt(result, getDebug(conf, conf.cCompiler))
  if optOptimizeSpeed in conf.options:
    let key = nimname & ".speed"
    if existsConfigVar(conf, key): addOpt(result, getConfigVar(conf, key))
    else: addOpt(result, getOptSpeed(conf, conf.cCompiler))
  elif optOptimizeSize in conf.options:
    let key = nimname & ".size"
    if existsConfigVar(conf, key): addOpt(result, getConfigVar(conf, key))
    else: addOpt(result, getOptSize(conf, conf.cCompiler))
  let key = nimname & ".always"
  if existsConfigVar(conf, key): addOpt(result, getConfigVar(conf, key))

proc getCompileOptions(conf: ConfigRef): string =
  result = cFileSpecificOptions(conf, "__dummy__", "__dummy__")

proc vccplatform(conf: ConfigRef): string =
  # VCC specific but preferable over the config hacks people
  # had to do before, see #11306
  case conf.target.targetCPU
  of cpuI386:
    result = " --platform:x86"
  of cpuArm:
    result = " --platform:arm"
  of cpuAmd64:
    result = " --platform:amd64"
  else:
    result = ""

proc getLinkOptions(conf: ConfigRef): string =
  result = conf.linkOptions & " " & conf.linkOptionsCmd & " "
  for linkedLib in items(conf.cLinkedLibs):
    result.add(CC[conf.cCompiler].linkLibCmd % linkedLib.quoteShell)
  for libDir in items(conf.cLibs):
    result.add(join([CC[conf.cCompiler].linkDirCmd, libDir.quoteShell]))

proc needsExeExt(conf: ConfigRef): bool {.inline.} =
  result = (optGenScript in conf.globalOptions and conf.target.targetOS == osWindows) or
           (conf.target.hostOS == osWindows)

proc getCompilerExe(conf: ConfigRef; compiler: TSystemCC; cfile: AbsoluteFile): string =
  result = if conf.cmd == cmdCompileToCpp and not cfile.string.endsWith(".c"):
             CC[compiler].cppCompiler
           else:
             CC[compiler].compilerExe
  if result.len == 0:
    rawMessage(conf, errGenerated,
      "Compiler '$1' doesn't support the requested target" %
      CC[compiler].name)

proc getLinkerExe(conf: ConfigRef; compiler: TSystemCC): string =
  result = if CC[compiler].linkerExe.len > 0: CC[compiler].linkerExe
           elif optMixedMode in conf.globalOptions and conf.cmd != cmdCompileToCpp: CC[compiler].cppCompiler
           else: getCompilerExe(conf, compiler, AbsoluteFile"")

proc getCompileCFileCmd*(conf: ConfigRef; cfile: Cfile,
                         isMainFile = false; produceOutput = false): string =
  var c = conf.cCompiler
  # We produce files like module.nim.cpp, so the absolute Nim filename is not
  # cfile.name but `cfile.cname.changeFileExt("")`:
  var options = cFileSpecificOptions(conf, cfile.nimname, cfile.cname.changeFileExt("").string)
  var exe = getConfigVar(conf, c, ".exe")
  if exe.len == 0: exe = getCompilerExe(conf, c, cfile.cname)

  if needsExeExt(conf): exe = addFileExt(exe, "exe")
  if (optGenDynLib in conf.globalOptions or (conf.hcrOn and not isMainFile)) and
      ospNeedsPIC in platform.OS[conf.target.targetOS].props:
    options.add(' ' & CC[c].pic)

  var includeCmd, compilePattern: string
  if not noAbsolutePaths(conf):
    # compute include paths:
    includeCmd = CC[c].includeCmd & quoteShell(conf.libpath)

    for includeDir in items(conf.cIncludes):
      includeCmd.add(join([CC[c].includeCmd, includeDir.quoteShell]))

    compilePattern = joinPath(conf.cCompilerPath, exe)
  else:
    includeCmd = ""
    compilePattern = getCompilerExe(conf, c, cfile.cname)

  includeCmd.add(join([CC[c].includeCmd, quoteShell(conf.projectPath.string)]))

  var cf = if noAbsolutePaths(conf): AbsoluteFile extractFilename(cfile.cname.string)
           else: cfile.cname

  var objfile =
    if cfile.obj.isEmpty:
      if not cfile.flags.contains(CfileFlag.External) or noAbsolutePaths(conf):
        toObjFile(conf, cf).string
      else:
        completeCfilePath(conf, toObjFile(conf, cf)).string
    elif noAbsolutePaths(conf):
      extractFilename(cfile.obj.string)
    else:
      cfile.obj.string

  # D files are required by nintendo switch libs for
  # compilation. They are basically a list of all includes.
  let dfile = objfile.changeFileExt(".d").quoteShell

  let cfsh = quoteShell(cf)
  result = quoteShell(compilePattern % [
    "dfile", dfile,
    "file", cfsh, "objfile", quoteShell(objfile), "options", options,
    "include", includeCmd, "nim", getPrefixDir(conf).string,
    "lib", conf.libpath.string])

  if optProduceAsm in conf.globalOptions:
    if CC[conf.cCompiler].produceAsm.len > 0:
      let asmfile = objfile.changeFileExt(".asm").quoteShell
      addOpt(result, CC[conf.cCompiler].produceAsm % ["asmfile", asmfile])
      if produceOutput:
        rawMessage(conf, hintUserRaw, "Produced assembler here: " & asmfile)
    else:
      if produceOutput:
        rawMessage(conf, hintUserRaw, "Couldn't produce assembler listing " &
          "for the selected C compiler: " & CC[conf.cCompiler].name)

  result.add(' ')
  result.addf(CC[c].compileTmpl, [
    "dfile", dfile,
    "file", cfsh, "objfile", quoteShell(objfile),
    "options", options, "include", includeCmd,
    "nim", quoteShell(getPrefixDir(conf)),
    "lib", quoteShell(conf.libpath),
    "vccplatform", vccplatform(conf)])

proc footprint(conf: ConfigRef; cfile: Cfile): SecureHash =
  result = secureHash(
    $secureHashFile(cfile.cname.string) &
    platform.OS[conf.target.targetOS].name &
    platform.CPU[conf.target.targetCPU].name &
    extccomp.CC[conf.cCompiler].name &
    getCompileCFileCmd(conf, cfile))

proc externalFileChanged(conf: ConfigRef; cfile: Cfile): bool =
  if conf.cmd notin {cmdCompileToC, cmdCompileToCpp, cmdCompileToOC, cmdCompileToLLVM, cmdNone}:
    return false

  var hashFile = toGeneratedFile(conf, conf.withPackageName(cfile.cname), "sha1")
  var currentHash = footprint(conf, cfile)
  var f: File
  if open(f, hashFile.string, fmRead):
    let oldHash = parseSecureHash(f.readLine())
    close(f)
    result = oldHash != currentHash
  else:
    result = true
  if result:
    if open(f, hashFile.string, fmWrite):
      f.writeLine($currentHash)
      close(f)

proc addExternalFileToCompile*(conf: ConfigRef; c: var Cfile) =
  if optForceFullMake notin conf.globalOptions and fileExists(c.obj) and
      not externalFileChanged(conf, c):
    c.flags.incl CfileFlag.Cached
  else:
    # make sure Nim keeps recompiling the external file on reruns
    # if compilation is not successful
    discard tryRemoveFile(c.obj.string)
  conf.toCompile.add(c)

proc addExternalFileToCompile*(conf: ConfigRef; filename: AbsoluteFile) =
  var c = Cfile(nimname: splitFile(filename).name, cname: filename,
    obj: toObjFile(conf, completeCfilePath(conf, filename, false)),
    flags: {CfileFlag.External})
  addExternalFileToCompile(conf, c)

proc compileCFiles(conf: ConfigRef; list: CfileList, script: var Rope, cmds: var TStringSeq,
                  prettyCmds: var TStringSeq) =
  var currIdx = 0
  for it in list:
    # call the C compiler for the .c file:
    if it.flags.contains(CfileFlag.Cached): continue
    var compileCmd = getCompileCFileCmd(conf, it, currIdx == list.len - 1, produceOutput=true)
    inc currIdx
    if optCompileOnly notin conf.globalOptions:
      cmds.add(compileCmd)
      let (_, name, _) = splitFile(it.cname)
      prettyCmds.add(if hintCC in conf.notes: "CC: " & demanglePackageName(name) else: "")
    if optGenScript in conf.globalOptions:
      script.add(compileCmd)
      script.add("\n")

proc getLinkCmd(conf: ConfigRef; output: AbsoluteFile,
                objfiles: string, isDllBuild: bool): string =
  if optGenStaticLib in conf.globalOptions:
    var libname: string
    if not conf.outFile.isEmpty:
      libname = conf.outFile.string.expandTilde
      if not libname.isAbsolute():
        libname = getCurrentDir() / libname
    else:
      libname = (libNameTmpl(conf) % splitFile(conf.projectName).name)
    result = CC[conf.cCompiler].buildLib % ["libfile", quoteShell(libname),
                                            "objfiles", objfiles]
  else:
    var linkerExe = getConfigVar(conf, conf.cCompiler, ".linkerexe")
    if linkerExe.len == 0: linkerExe = getLinkerExe(conf, conf.cCompiler)
    # bug #6452: We must not use ``quoteShell`` here for ``linkerExe``
    if needsExeExt(conf): linkerExe = addFileExt(linkerExe, "exe")
    if noAbsolutePaths(conf): result = linkerExe
    else: result = joinPath(conf.cCompilerPath, linkerExe)
    let buildgui = if optGenGuiApp in conf.globalOptions and conf.target.targetOS == osWindows:
                     CC[conf.cCompiler].buildGui
                   else:
                     ""
    let builddll = if isDllBuild: CC[conf.cCompiler].buildDll else: ""
    let exefile = quoteShell(output)

    when false:
      if optCDebug in conf.globalOptions:
        writeDebugInfo(exefile.changeFileExt("ndb"))

    # Map files are required by Nintendo Switch compilation. They are a list
    # of all function calls in the library and where they come from.
    let mapfile = quoteShell(getNimcacheDir(conf) / RelativeFile(splitFile(output).name & ".map"))

    let linkOptions = getLinkOptions(conf) & " " &
                      getConfigVar(conf, conf.cCompiler, ".options.linker")
    var linkTmpl = getConfigVar(conf, conf.cCompiler, ".linkTmpl")
    if linkTmpl.len == 0:
      linkTmpl = CC[conf.cCompiler].linkTmpl
    result = quoteShell(result % ["builddll", builddll,
        "mapfile", mapfile,
        "buildgui", buildgui, "options", linkOptions, "objfiles", objfiles,
        "exefile", exefile, "nim", getPrefixDir(conf).string, "lib", conf.libpath.string])
    result.add ' '
    result.addf(linkTmpl, ["builddll", builddll,
        "mapfile", mapfile,
        "buildgui", buildgui, "options", linkOptions,
        "objfiles", objfiles, "exefile", exefile,
        "nim", quoteShell(getPrefixDir(conf)),
        "lib", quoteShell(conf.libpath),
        "vccplatform", vccplatform(conf)])
    # On windows the debug information for binaries is emitted in a separate .pdb
    # file and the binaries (.dll and .exe) contain a full path to that .pdb file.
    # This is a problem for hot code reloading because even when we copy the .dll
    # and load the copy so the build process may overwrite the original .dll on
    # the disk (windows locks the files of running binaries) the copy still points
    # to the original .pdb (and a simple copy of the .pdb won't help). This is a
    # problem when a debugger is attached to the program we are hot-reloading.
    # This problem is nonexistent on Unix since there by default debug symbols
    # are embedded in the binaries so loading a copy of a .so will be fine. There
    # is the '/Z7' flag for the MSVC compiler to embed the debug info of source
    # files into their respective .obj files but the linker still produces a .pdb
    # when a final .dll or .exe is linked so the debug info isn't embedded.
    # There is also the issue that even when a .dll is unloaded the debugger
    # still keeps the .pdb for that .dll locked. This is a major problem and
    # because of this we cannot just alternate between 2 names for a .pdb file
    # when rebuilding a .dll - instead we need to accumulate differently named
    # .pdb files in the nimcache folder - this is the easiest and most reliable
    # way of being able to debug and rebuild the program at the same time. This
    # is accomplished using the /PDB:<filename> flag (there also exists the
    # /PDBALTPATH:<filename> flag). The only downside is that the .pdb files are
    # at least 300kb big (when linking statically to the runtime - or else 5mb+)
    # and will quickly accumulate. There is a hacky solution: we could try to
    # delete all .pdb files with a pattern and swallow exceptions.
    #
    # links about .pdb files and hot code reloading:
    # https://ourmachinery.com/post/dll-hot-reloading-in-theory-and-practice/
    # https://ourmachinery.com/post/little-machines-working-together-part-2/
    # https://github.com/fungos/cr
    # https://fungos.github.io/blog/2017/11/20/cr.h-a-simple-c-hot-reload-header-only-library/
    # on forcing the debugger to unlock a locked .pdb of an unloaded library:
    # https://blog.molecular-matters.com/2017/05/09/deleting-pdb-files-locked-by-visual-studio/
    # and a bit about the .pdb format in case that is ever needed:
    # https://github.com/crosire/blink
    # http://www.debuginfo.com/articles/debuginfomatch.html#pdbfiles
    if conf.hcrOn and isVSCompatible(conf):
      let t = now()
      let pdb = output.string & "." & format(t, "MMMM-yyyy-HH-mm-") & $t.nanosecond & ".pdb"
      result.add " /link /PDB:" & pdb
  if optCDebug in conf.globalOptions and conf.cCompiler == ccVcc:
    result.add " /Zi /FS /Od"

template getLinkCmd(conf: ConfigRef; output: AbsoluteFile, objfiles: string): string =
  getLinkCmd(conf, output, objfiles, optGenDynLib in conf.globalOptions)

template tryExceptOSErrorMessage(conf: ConfigRef; errorPrefix: string = "", body: untyped) =
  try:
    body
  except OSError:
    let ose = (ref OSError)(getCurrentException())
    if errorPrefix.len > 0:
      rawMessage(conf, errGenerated, errorPrefix & " " & ose.msg & " " & $ose.errorCode)
    else:
      rawMessage(conf, errGenerated, "execution of an external program failed: '$1'" %
        (ose.msg & " " & $ose.errorCode))
    raise

proc execLinkCmd(conf: ConfigRef; linkCmd: string) =
  tryExceptOSErrorMessage(conf, "invocation of external linker program failed."):
    execExternalProgram(conf, linkCmd,
      if optListCmd in conf.globalOptions or conf.verbosity > 1: hintExecuting else: hintLinking)

proc execCmdsInParallel(conf: ConfigRef; cmds: seq[string]; prettyCb: proc (idx: int)) =
  let runCb = proc (idx: int, p: Process) =
    let exitCode = p.peekExitCode
    if exitCode != 0:
      rawMessage(conf, errGenerated, "execution of an external compiler program '" &
        cmds[idx] & "' failed with exit code: " & $exitCode & "\n\n" &
        p.outputStream.readAll.strip)
  if conf.numberOfProcessors == 0: conf.numberOfProcessors = countProcessors()
  var res = 0
  if conf.numberOfProcessors <= 1:
    for i in 0..high(cmds):
      tryExceptOSErrorMessage(conf, "invocation of external compiler program failed."):
        res = execWithEcho(conf, cmds[i])
      if res != 0:
        rawMessage(conf, errGenerated, "execution of an external program failed: '$1'" %
          cmds[i])
  else:
    tryExceptOSErrorMessage(conf, "invocation of external compiler program failed."):
      if optListCmd in conf.globalOptions or conf.verbosity > 1:
        res = execProcesses(cmds, {poEchoCmd, poStdErrToStdOut, poUsePath},
                            conf.numberOfProcessors, afterRunEvent=runCb)
      elif conf.verbosity == 1:
        res = execProcesses(cmds, {poStdErrToStdOut, poUsePath},
                            conf.numberOfProcessors, prettyCb, afterRunEvent=runCb)
      else:
        res = execProcesses(cmds, {poStdErrToStdOut, poUsePath},
                            conf.numberOfProcessors, afterRunEvent=runCb)
  if res != 0:
    if conf.numberOfProcessors <= 1:
      rawMessage(conf, errGenerated, "execution of an external program failed: '$1'" %
        cmds.join())

proc linkViaResponseFile(conf: ConfigRef; cmd: string) =
  # Extracting the linker.exe here is a bit hacky but the best solution
  # given ``buildLib``'s design.
  var i = 0
  var last = 0
  if cmd.len > 0 and cmd[0] == '"':
    inc i
    while i < cmd.len and cmd[i] != '"': inc i
    last = i
    inc i
  else:
    while i < cmd.len and cmd[i] != ' ': inc i
    last = i
  while i < cmd.len and cmd[i] == ' ': inc i
  let linkerArgs = conf.projectName & "_" & "linkerArgs.txt"
  let args = cmd.substr(i)
  # GCC's response files don't support backslashes. Junk.
  if conf.cCompiler == ccGcc or conf.cCompiler == ccCLang:
    writeFile(linkerArgs, args.replace('\\', '/'))
  else:
    writeFile(linkerArgs, args)
  try:
    execLinkCmd(conf, cmd.substr(0, last) & " @" & linkerArgs)
  finally:
    removeFile(linkerArgs)

proc getObjFilePath(conf: ConfigRef, f: Cfile): string =
  if noAbsolutePaths(conf): f.obj.extractFilename
  else: f.obj.string

proc hcrLinkTargetName(conf: ConfigRef, objFile: string, isMain = false): AbsoluteFile =
  let basename = splitFile(objFile).name
  let targetName = if isMain: basename & ".exe"
                   else: platform.OS[conf.target.targetOS].dllFrmt % basename
  result = conf.getNimcacheDir / RelativeFile(targetName)

proc callCCompiler*(conf: ConfigRef) =
  var
    linkCmd: string
  if conf.globalOptions * {optCompileOnly, optGenScript} == {optCompileOnly}:
    return # speed up that call if only compiling and no script shall be
           # generated
  #var c = cCompiler
  var script: Rope = nil
  var cmds: TStringSeq = @[]
  var prettyCmds: TStringSeq = @[]
  let prettyCb = proc (idx: int) =
    when declared(echo):
      let cmd = prettyCmds[idx]
      if cmd != "": echo cmd
  compileCFiles(conf, conf.toCompile, script, cmds, prettyCmds)
  if optCompileOnly notin conf.globalOptions:
    execCmdsInParallel(conf, cmds, prettyCb)
  if optNoLinking notin conf.globalOptions:
    # call the linker:
    var objfiles = ""
    for it in conf.externalToLink:
      let objFile = if noAbsolutePaths(conf): it.extractFilename else: it
      objfiles.add(' ')
      objfiles.add(quoteShell(
          addFileExt(objFile, CC[conf.cCompiler].objExt)))

    if conf.hcrOn: # lets assume that optCompileOnly isn't on
      cmds = @[]
      let mainFileIdx = conf.toCompile.len - 1
      for idx, x in conf.toCompile:
        # don't relink each of the many binaries (one for each source file) if the nim code is
        # cached because that would take too much time for small changes - the only downside to
        # this is that if an external-to-link file changes the final target wouldn't be relinked
        if x.flags.contains(CfileFlag.Cached): continue
        # we pass each object file as if it is the project file - a .dll will be created for each such
        # object file in the nimcache directory, and only in the case of the main project file will
        # there be probably an executable (if the project is such) which will be copied out of the nimcache
        let objFile = conf.getObjFilePath(x)
        let buildDll = idx != mainFileIdx
        let linkTarget = conf.hcrLinkTargetName(objFile, not buildDll)
        cmds.add(getLinkCmd(conf, linkTarget, objfiles & " " & quoteShell(objFile), buildDll))
        # try to remove all .pdb files for the current binary so they don't accumulate endlessly in the nimcache
        # for more info check the comment inside of getLinkCmd() where the /PDB:<filename> MSVC flag is used
        if isVSCompatible(conf):
          for pdb in walkFiles(objFile & ".*.pdb"):
            discard tryRemoveFile(pdb)
      # execute link commands in parallel - output will be a bit different
      # if it fails than that from execLinkCmd() but that doesn't matter
      prettyCmds = map(prettyCmds, proc (curr: string): string = return curr.replace("CC", "Link"))
      execCmdsInParallel(conf, cmds, prettyCb)
      # only if not cached - copy the resulting main file from the nimcache folder to its originally intended destination
      if not conf.toCompile[mainFileIdx].flags.contains(CfileFlag.Cached):
        let mainObjFile = getObjFilePath(conf, conf.toCompile[mainFileIdx])
        var src = conf.hcrLinkTargetName(mainObjFile, true)
        var dst = conf.prepareToWriteOutput
        copyFileWithPermissions(src.string, dst.string)
    else:
      for x in conf.toCompile:
        let objFile = if noAbsolutePaths(conf): x.obj.extractFilename else: x.obj.string
        objfiles.add(' ')
        objfiles.add(quoteShell(objFile))
      let mainOutput = if optGenScript notin conf.globalOptions: conf.prepareToWriteOutput
                       else: AbsoluteFile(conf.projectName)
      linkCmd = getLinkCmd(conf, mainOutput, objfiles)
      if optCompileOnly notin conf.globalOptions:
        const MaxCmdLen = when defined(windows): 8_000 else: 32_000
        if linkCmd.len > MaxCmdLen:
          # Windows's command line limit is about 8K (don't laugh...) so C compilers on
          # Windows support a feature where the command line can be passed via ``@linkcmd``
          # to them.
          linkViaResponseFile(conf, linkCmd)
        else:
          execLinkCmd(conf, linkCmd)
  else:
    linkCmd = ""
  if optGenScript in conf.globalOptions:
    script.add(linkCmd)
    script.add("\n")
    generateScript(conf, script)

#from json import escapeJson
import json, std / sha1

template hashNimExe(): string = $secureHashFile(os.getAppFilename())

proc writeJsonBuildInstructions*(conf: ConfigRef) =
  template lit(x: untyped) = f.write x
  template str(x: untyped) =
    when compiles(escapeJson(x, buf)):
      buf.setLen 0
      escapeJson(x, buf)
      f.write buf
    else:
      f.write escapeJson(x)

  proc cfiles(conf: ConfigRef; f: File; buf: var string; clist: CfileList, isExternal: bool) =
    var i = 0
    for it in clist:
      if CfileFlag.Cached in it.flags: continue
      let compileCmd = getCompileCFileCmd(conf, it)
      if i > 0: lit ",\L"
      lit "["
      str it.cname.string
      lit ", "
      str compileCmd
      lit "]"
      inc i

  proc linkfiles(conf: ConfigRef; f: File; buf, objfiles: var string; clist: CfileList;
                 llist: seq[string]) =
    var pastStart = false
    for it in llist:
      let objfile = if noAbsolutePaths(conf): it.extractFilename
                    else: it
      let objstr = addFileExt(objfile, CC[conf.cCompiler].objExt)
      objfiles.add(' ')
      objfiles.add(objstr)
      if pastStart: lit ",\L"
      str objstr
      pastStart = true

    for it in clist:
      let objstr = quoteShell(it.obj)
      objfiles.add(' ')
      objfiles.add(objstr)
      if pastStart: lit ",\L"
      str objstr
      pastStart = true
    lit "\L"

  proc depfiles(conf: ConfigRef; f: File) =
    var i = 0
    for it in conf.m.fileInfos:
      let path = it.fullPath.string
      if isAbsolute(path): # TODO: else?
        if i > 0: lit "],\L"
        lit "["
        str path
        lit ", "
        str $secureHashFile(path)
        inc i
    lit "]\L"


  var buf = newStringOfCap(50)

  let jsonFile = conf.getNimcacheDir / RelativeFile(conf.projectName & ".json")

  var f: File
  if open(f, jsonFile.string, fmWrite):
    lit "{\"compile\":[\L"
    cfiles(conf, f, buf, conf.toCompile, false)
    lit "],\L\"link\":[\L"
    var objfiles = ""
    # XXX add every file here that is to link
    linkfiles(conf, f, buf, objfiles, conf.toCompile, conf.externalToLink)

    lit "],\L\"linkcmd\": "
    str getLinkCmd(conf, conf.absOutFile, objfiles)

    if optRun in conf.globalOptions or isDefined(conf, "nimBetterRun"):
      lit ",\L\"cmdline\": "
      str conf.commandLine
      lit ",\L\"depfiles\":[\L"
      depfiles(conf, f)
      lit "],\L\"nimexe\": \L"
      str hashNimExe()
      lit "\L"

    lit "\L}\L"
    close(f)

proc changeDetectedViaJsonBuildInstructions*(conf: ConfigRef; projectfile: AbsoluteFile): bool =
  let jsonFile = toGeneratedFile(conf, projectfile, "json")
  if not fileExists(jsonFile): return true
  if not fileExists(conf.absOutFile): return true
  result = false
  try:
    let data = json.parseFile(jsonFile.string)
    if not data.hasKey("depfiles") or not data.hasKey("cmdline"):
      return true
    let oldCmdLine = data["cmdline"].getStr
    if conf.commandLine != oldCmdLine:
      return true
    if hashNimExe() != data["nimexe"].getStr:
      return true
    let depfilesPairs = data["depfiles"]
    doAssert depfilesPairs.kind == JArray
    for p in depfilesPairs:
      doAssert p.kind == JArray
      # >= 2 for forwards compatibility with potential later .json files:
      doAssert p.len >= 2
      let depFilename = p[0].getStr
      let oldHashValue = p[1].getStr
      let newHashValue = $secureHashFile(depFilename)
      if oldHashValue != newHashValue:
        return true
  except IOError, OSError, ValueError:
    echo "Warning: JSON processing failed: ", getCurrentExceptionMsg()
    result = true

proc runJsonBuildInstructions*(conf: ConfigRef; projectfile: AbsoluteFile) =
  let jsonFile = toGeneratedFile(conf, projectfile, "json")
  try:
    let data = json.parseFile(jsonFile.string)
    let toCompile = data["compile"]
    doAssert toCompile.kind == JArray
    var cmds: TStringSeq = @[]
    var prettyCmds: TStringSeq = @[]
    for c in toCompile:
      doAssert c.kind == JArray
      doAssert c.len >= 2

      cmds.add(c[1].getStr)
      let (_, name, _) = splitFile(c[0].getStr)
      prettyCmds.add("CC: " & demanglePackageName(name))

    let prettyCb = proc (idx: int) =
      when declared(echo):
        echo prettyCmds[idx]
    execCmdsInParallel(conf, cmds, prettyCb)

    let linkCmd = data["linkcmd"]
    doAssert linkCmd.kind == JString
    execLinkCmd(conf, linkCmd.getStr)
  except:
    when declared(echo):
      echo getCurrentException().getStackTrace()
    quit "error evaluating JSON file: " & jsonFile.string

proc genMappingFiles(conf: ConfigRef; list: CfileList): Rope =
  for it in list:
    result.addf("--file:r\"$1\"$N", [rope(it.cname.string)])

proc writeMapping*(conf: ConfigRef; symbolMapping: Rope) =
  if optGenMapping notin conf.globalOptions: return
  var code = rope("[C_Files]\n")
  code.add(genMappingFiles(conf, conf.toCompile))
  code.add("\n[C_Compiler]\nFlags=")
  code.add(strutils.escape(getCompileOptions(conf)))

  code.add("\n[Linker]\nFlags=")
  code.add(strutils.escape(getLinkOptions(conf) & " " &
                            getConfigVar(conf, conf.cCompiler, ".options.linker")))

  code.add("\n[Environment]\nlibpath=")
  code.add(strutils.escape(conf.libpath.string))

  code.addf("\n[Symbols]$n$1", [symbolMapping])
  let filename = conf.projectPath / RelativeFile"mapping.txt"
  if not writeRope(code, filename):
    rawMessage(conf, errGenerated, "could not write to file: " & filename.string)
