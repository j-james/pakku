import
  algorithm, future, options, os, posix, sequtils, sets, strutils, tables,
  "../args", "../aur", "../config", "../common", "../format", "../package",
    "../pacman", "../utils",
  "../wrapper/alpm"

type
  Installed = tuple[
    name: string,
    version: string,
    groups: seq[string],
    foreign: bool
  ]

  SatisfyResult = tuple[
    installed: bool,
    name: string,
    buildPkgInfo: Option[PackageInfo]
  ]

  BuildResult = tuple[
    version: string,
    arch: string,
    ext: string,
    names: seq[string]
  ]

proc groupsSeq(pkg: ptr AlpmPackage): seq[string] =
  toSeq(pkg.groups.items).map(s => $s)

proc orderInstallation(ordered: seq[seq[seq[PackageInfo]]], grouped: seq[seq[PackageInfo]],
  dependencies: Table[PackageReference, SatisfyResult]): seq[seq[seq[PackageInfo]]] =
  let orderedNamesSet = lc[c.name | (a <- ordered, b <- a, c <- b), string].toSet

  proc hasBuildDependency(pkgInfos: seq[PackageInfo]): bool =
    for pkgInfo in pkgInfos:
      for reference in pkgInfo.allDepends:
        let satres = dependencies[reference.reference]
        if satres.buildPkgInfo.isSome and
          not (satres.buildPkgInfo.unsafeGet in pkgInfos) and
          not (satres.buildPkgInfo.unsafeGet.name in orderedNamesSet):
          return true
    return false

  let split: seq[tuple[pkgInfos: seq[PackageInfo], dependent: bool]] =
    grouped.map(i => (i, i.hasBuildDependency))

  let newOrdered = ordered & split.filter(s => not s.dependent).map(s => s.pkgInfos)
  let unordered = split.filter(s => s.dependent).map(s => s.pkgInfos)

  if unordered.len > 0:
    if unordered.len == grouped.len:
      newOrdered & unordered
    else:
      orderInstallation(newOrdered, unordered, dependencies)
  else:
    newOrdered

proc orderInstallation(pkgInfos: seq[PackageInfo],
  dependencies: Table[PackageReference, SatisfyResult]): seq[seq[seq[PackageInfo]]] =
  let grouped = pkgInfos.groupBy(i => i.base).map(p => p.values)

  orderInstallation(@[], grouped, dependencies)
    .map(x => x.filter(s => s.len > 0))
    .filter(x => x.len > 0)

proc findDependencies(config: Config, handle: ptr AlpmHandle, dbs: seq[ptr AlpmDatabase],
  satisfied: Table[PackageReference, SatisfyResult], unsatisfied: seq[PackageReference],
  printMode: bool, noaur: bool): (Table[PackageReference, SatisfyResult], seq[PackageReference]) =
  proc checkDependencyCycle(pkgInfo: PackageInfo, reference: PackageReference): bool =
    for checkReference in pkgInfo.allDepends:
      if checkReference.arch.isNone or checkReference.arch == some(config.arch):
        if checkReference.reference == reference:
          return false
        let buildPkgInfo = satisfied.opt(checkReference.reference)
          .map(r => r.buildPkgInfo).flatten
        if buildPkgInfo.isSome and not checkDependencyCycle(buildPkgInfo.unsafeGet, reference):
          return false
    return true

  proc findInSatisfied(reference: PackageReference): Option[PackageInfo] =
    for satref, res in satisfied.pairs:
      if res.buildPkgInfo.isSome:
        let pkgInfo = res.buildPkgInfo.unsafeGet
        if satref == reference or reference.isProvidedBy((pkgInfo.name, none(string),
          some((ConstraintOperation.eq, pkgInfo.version)))):
          return some(pkgInfo)
        for provides in pkgInfo.provides:
          if provides.arch.isNone or provides.arch == some(config.arch):
            if reference.isProvidedBy(provides.reference) and
              checkDependencyCycle(pkgInfo, reference):
              return some(pkgInfo)
    return none(PackageInfo)

  proc findInDatabaseWithGroups(db: ptr AlpmDatabase, reference: PackageReference,
    directName: bool): Option[tuple[name: string, groups: seq[string]]] =
    for pkg in db.packages:
      if reference.isProvidedBy(($pkg.name, none(string),
        some((ConstraintOperation.eq, $pkg.version)))):
        return some(($pkg.name, pkg.groupsSeq))
      for provides in pkg.provides:
        if reference.isProvidedBy(provides.toPackageReference):
          if directName:
            return some(($pkg.name, pkg.groupsSeq))
          else:
            return some(($provides.name, pkg.groupsSeq))
    return none((string, seq[string]))

  proc findInDatabase(db: ptr AlpmDatabase, reference: PackageReference,
    directName: bool, checkIgnored: bool): Option[string] =
    let res = findInDatabaseWithGroups(db, reference, directName)
    if res.isSome:
      let r = res.unsafeGet
      if checkIgnored and config.ignored(r.name, r.groups):
        none(string)
      else:
        some(r.name)
    else:
      none(string)

  proc findInDatabases(reference: PackageReference,
    directName: bool, checkIgnored: bool): Option[string] =
    for db in dbs:
      let name = findInDatabase(db, reference, directName, checkIgnored)
      if name.isSome:
        return name
    return none(string)

  proc find(reference: PackageReference): Option[SatisfyResult] =
    let localName = findInDatabase(handle.local, reference, true, false)
    if localName.isSome:
      some((true, localName.unsafeGet, none(PackageInfo)))
    else:
      let pkgInfo = findInSatisfied(reference)
      if pkgInfo.isSome:
        some((false, pkgInfo.unsafeGet.name, pkgInfo))
      else:
        let syncName = findInDatabases(reference, false, true)
        if syncName.isSome:
          some((false, syncName.unsafeGet, none(PackageInfo)))
        else:
          none(SatisfyResult)

  type ReferenceResult = tuple[reference: PackageReference, result: Option[SatisfyResult]]

  let findResult: seq[ReferenceResult] = unsatisfied.map(r => (r, r.find))
  let success = findResult.filter(r => r.result.isSome)
  let aurCheck = findResult.filter(r => r.result.isNone).map(r => r.reference)

  let (aurSuccess, aurFail) = if not noaur and aurCheck.len > 0: (block:
      let (update, terminate) = if aurCheck.len >= 4:
          printProgressShare(config.progressBar, tr"checking build dependencies")
        else:
          (proc (a: int, b: int) {.closure.} = discard, proc {.closure.} = discard)
      try:
        withAur():
          let (pkgInfos, aerrors) = getAurPackageInfo(aurCheck.map(r => r.name),
            none(seq[RpcPackageInfo]), update)
          for e in aerrors: printError(config.color, e)

          let acceptedPkgInfos = pkgInfos.filter(i => not config.ignored(i.name, i.groups))
          let aurTable = acceptedPkgInfos.map(i => (i.name, i)).toTable
          let aurResult = aurCheck.map(proc (reference: PackageReference): ReferenceResult =
            if aurTable.hasKey(reference.name):
              (reference, some((false, reference.name, some(aurTable[reference.name]))))
            else:
              (reference, none(SatisfyResult)))

          let aurSuccess = aurResult.filter(r => r.result.isSome)
          let aurFail = aurResult.filter(r => r.result.isNone).map(r => r.reference)
          (aurSuccess, aurFail)
      finally:
        terminate())
    else:
      (@[], aurCheck)

  let newSatisfied = (toSeq(satisfied.pairs) &
    success.map(r => (r.reference, r.result.unsafeGet)) &
    aurSuccess.map(r => (r.reference, r.result.unsafeGet))).toTable

  let newUnsatisfied = lc[x.reference | (y <- aurSuccess,
    r <- y.result, i <- r.buildPkgInfo, x <- i.allDepends,
    x.arch.isNone or x.arch == some(config.arch)), PackageReference].deduplicate

  if aurFail.len > 0:
    (newSatisfied, aurFail)
  elif newUnsatisfied.len > 0:
    findDependencies(config, handle, dbs, newSatisfied, newUnsatisfied, printMode, noaur)
  else:
    (newSatisfied, @[])

proc findDependencies(config: Config, handle: ptr AlpmHandle,
  dbs: seq[ptr AlpmDatabase], pkgInfos: seq[PackageInfo], printMode: bool, noaur: bool):
  (Table[PackageReference, SatisfyResult], seq[PackageReference]) =
  let satisfied = pkgInfos.map(p => ((p.name, none(string), none(VersionConstraint)),
    (false, p.name, some(p)))).toTable
  let unsatisfied = lc[x.reference | (i <- pkgInfos, x <- i.allDepends,
    x.arch.isNone or x.arch == some(config.arch)), PackageReference].deduplicate
  findDependencies(config, handle, dbs, satisfied, unsatisfied, printMode, noaur)

proc filterNotFoundSyncTargets[T: RpcPackageInfo](syncTargets: seq[SyncPackageTarget],
  pkgInfos: seq[T]): (Table[string, T], seq[SyncPackageTarget]) =
  let rpcInfoTable = pkgInfos.map(d => (d.name, d)).toTable

  proc notFoundOrFoundInAur(target: SyncPackageTarget): bool =
    target.foundInfo.isNone and
      not (target.isAurTargetSync and rpcInfoTable.hasKey(target.name))

  # collect packages which were found neither in sync DB nor in AUR
  let notFoundTargets = syncTargets.filter(notFoundOrFoundInAur)

  (rpcInfoTable, notFoundTargets)

proc printSyncNotFound(config: Config, notFoundTargets: seq[SyncPackageTarget]) =
  let dbs = config.dbs.toSet

  for target in notFoundTargets:
    if target.repo.isNone or target.repo == some("aur") or target.repo.unsafeGet in dbs:
      printError(config.color, trp("target not found: %s\n") % [target.name])
    else:
      printError(config.color, trp("database not found: %s\n") % [target.repo.unsafeGet])

proc printUnsatisfied(config: Config,
  satisfied: Table[PackageReference, SatisfyResult], unsatisfied: seq[PackageReference]) =
  if unsatisfied.len > 0:
    for _, satres in satisfied.pairs:
      for pkgInfo in satres.buildPkgInfo:
        for reference in pkgInfo.allDepends:
          let pref = reference.reference
          if pref in unsatisfied:
            printError(config.color,
              trp("unable to satisfy dependency '%s' required by %s\n") %
              [$pref, pkgInfo.name])

proc editLoop(config: Config, base: string, repoPath: string, gitPath: Option[string],
  defaultYes: bool, noconfirm: bool): char =
  proc editFileLoop(file: string): char =
    let default = if defaultYes: 'y' else: 'n'
    let res = printColonUserChoice(config.color,
      tr"View and edit $#?" % [base & "/" & file], ['y', 'n', 's', 'a', '?'],
      default, '?', noconfirm, 'n')

    if res == '?':
      printUserInputHelp(('s', tr"skip all files"),
        ('a', tr"abort operation"))
      editFileLoop(file)
    elif res == 'y':
      let visualEnv = getenv("VISUAL")
      let editorEnv = getenv("EDITOR")
      let editor = if visualEnv != nil and visualEnv.len > 0:
          $visualEnv
        elif editorEnv != nil and editorEnv.len > 0:
          $editorEnv
        else:
          printColonUserInput(config.color, tr"Enter editor executable name" & ":",
            noconfirm, "", "")

      if editor.strip.len == 0:
        'n'
      else:
        discard forkWait(proc: int =
          discard chdir(buildPath(repoPath, gitPath))
          execResult(bashCmd, "-c", """$1 "$2"""", "bash", editor, file))
        editFileLoop(file)
    else:
      res

  let rawFiles = if gitPath.isSome:
      runProgram(gitCmd, "-C", repoPath, "ls-tree", "-r", "--name-only", "@",
        gitPath.unsafeGet & "/").map(s => s[gitPath.unsafeGet.len + 1 .. ^1])
    else:
      runProgram(gitCmd, "-C", repoPath, "ls-tree", "-r", "--name-only", "@")

  let files = ("PKGBUILD" & rawFiles.filter(x => x != ".SRCINFO")).deduplicate

  proc editFileLoopAll(index: int): char =
    if index < files.len:
      let res = editFileLoop(files[index])
      if res == 'n': editFileLoopAll(index + 1) else: res
    else:
      'n'

  editFileLoopAll(0)

proc buildLoop(config: Config, pkgInfos: seq[PackageInfo], noconfirm: bool,
  noextract: bool): (Option[BuildResult], int) =
  let base = pkgInfos[0].base
  let repoPath = repoPath(config.tmpRoot, base)
  let gitPath = pkgInfos[0].gitPath
  let buildPath = buildPath(repoPath, gitPath)

  let buildCode = forkWait(proc: int =
    if chdir(buildPath) == 0:
      discard setenv("PKGDEST", config.tmpRoot, 1)
      discard setenv("CARCH", config.arch, 1)

      if not noextract:
        removeDirQuiet(buildPath & "src")

      let optional: seq[tuple[arg: string, cond: bool]] = @[
        ("-e", noextract),
        ("-m", not config.color)
      ]

      execResult(@[makepkgCmd, "-f"] &
        optional.filter(o => o.cond).map(o => o.arg))
    else:
      quit(1))

  if buildCode != 0:
    printError(config.color, tr"failed to build '$#'" % [base])
    (none(BuildResult), buildCode)
  else:
    let confFileEnv = getenv("MAKEPKG_CONF")
    let confFile = if confFileEnv == nil or confFileEnv.len == 0:
        sysConfDir & "/makepkg.conf"
      else:
        $confFileEnv

    let envExt = getenv("PKGEXT")
    let confExt = if envExt == nil or envExt.len == 0:
        runProgram(bashCmd, "-c",
          "source \"$@\" && echo \"$PKGEXT\"",
          "bash", confFile).optFirst.get("")
      else:
        $envExt

    let extracted = runProgram(bashCmd, "-c",
      """source "$@" && echo "$epoch" && echo "$pkgver" && """ &
      """echo "$pkgrel" && echo "${arch[@]}" && echo "${pkgname[@]}"""",
      "bash", buildPath & "/PKGBUILD")
    if extracted.len != 5:
      printError(config.color, tr"failed to extract package info '$#'" % [base])
      (none(BuildResult), 1)
    else:
      let epoch = extracted[0]
      let versionShort = extracted[1] & "-" & extracted[2]
      let version = if epoch.len > 0: epoch & ":" & versionShort else: versionShort
      let archs = extracted[3].split(" ").toSet
      let arch = if config.arch in archs: config.arch else: "any"
      let names = extracted[4].split(" ")

      (some((version, arch, $confExt, names)), 0)

proc buildFromSources(config: Config, commonArgs: seq[Argument],
  pkgInfos: seq[PackageInfo], noconfirm: bool): (Option[BuildResult], int) =
  let base = pkgInfos[0].base
  let (cloneCode, cloneErrorMessage) = cloneRepo(config, pkgInfos)

  if cloneCode != 0:
    for e in cloneErrorMessage: printError(config.color, e)
    printError(config.color, tr"$#: failed to clone git repository" % [base])
    (none(BuildResult), cloneCode)
  else:
    proc loop(noextract: bool, showEditLoop: bool): (Option[BuildResult], int) =
      let res = if showEditLoop:
          editLoop(config, base, repoPath(config.tmpRoot, base), pkgInfos[0].gitPath,
            false, noconfirm)
        else:
          'n'

      if res == 'a':
        (none(BuildResult), 1)
      else:
        let (buildResult, code) = buildLoop(config, pkgInfos,
          noconfirm, noextract)

        if code != 0:
          proc ask(): char =
            let res = printColonUserChoice(config.color,
              tr"Build failed, retry?", ['y', 'e', 'n', '?'], 'n', '?',
              noconfirm, 'n')
            if res == '?':
              printUserInputHelp(('e', tr"retry with --noextract option"))
              ask()
            else:
              res

          let res = ask()
          if res == 'e':
            loop(true, true)
          elif res == 'y':
            loop(false, true)
          else:
            (buildResult, code)
        else:
          (buildResult, code)

    loop(false, false)

proc installGroupFromSources(config: Config, commonArgs: seq[Argument],
  basePackages: seq[seq[PackageInfo]], explicits: HashSet[string], noconfirm: bool): int =
  proc buildNext(index: int, buildResults: seq[BuildResult]): (seq[BuildResult], int) =
    if index < basePackages.len:
      let (buildResult, code) = buildFromSources(config, commonArgs,
        basePackages[index], noconfirm)

      if code != 0:
        (buildResults, code)
      else:
        buildNext(index + 1, buildResults & buildResult.unsafeGet)
    else:
      (buildResults, 0)

  let (buildResults, buildCode) = buildNext(0, @[])

  proc formatArchiveFile(br: BuildResult, name: string): string =
    config.tmpRoot & "/" & name & "-" & br.version & "-" & br.arch & br.ext

  let files = lc[(name, formatArchiveFile(br, name)) |
    (br <- buildResults, name <- br.names), (string, string)].toTable
  let install = lc[x | (g <- basePackages, i <- g, x <- files.opt(i.name)), string]

  proc handleTmpRoot(clear: bool) =
    for _, file in files:
      if clear or not (file in install):
        try:
          removeFile(file)
        except:
          discard

    if not clear:
      printWarning(config.color, tr"packages are saved to '$#'" % [config.tmpRoot])

  if buildCode != 0:
    handleTmpRoot(true)
    buildCode
  else:
    let res = printColonUserChoice(config.color,
      tr"Continue installing?", ['y', 'n'], 'y', 'n',
      noconfirm, 'y')

    if res != 'y':
      handleTmpRoot(false)
      1
    else:
      let explicit = basePackages.filter(p => p.filter(i => i.name in explicits).len > 0).len > 0
      let asdepsSeq = if not explicit: @[("asdeps", none(string), ArgumentType.long)] else: @[]

      let installCode = pacmanRun(true, config.color, commonArgs &
        ("U", none(string), ArgumentType.short) & asdepsSeq &
        install.map(i => (i, none(string), ArgumentType.target)))

      if installCode != 0:
        handleTmpRoot(false)
        installCode
      else:
        handleTmpRoot(true)
        0

proc handleInstall(args: seq[Argument], config: Config, upgradeCount: int,
  noconfirm: bool, explicits: HashSet[string], installed: seq[Installed],
  dependencies: Table[PackageReference, SatisfyResult],
  directPacmanTargets: seq[string], additionalPacmanTargets: seq[string],
  basePackages: seq[seq[seq[PackageInfo]]]): int =
  let (directCode, directSome) = if directPacmanTargets.len > 0 or upgradeCount > 0:
      (pacmanRun(true, config.color, args.filter(arg => not arg.isTarget) &
        directPacmanTargets.map(t => (t, none(string), ArgumentType.target))), true)
    else:
      (0, false)

  if directCode != 0:
    directCode
  else:
    let commonArgs = args.keepOnlyOptions(commonOptions, upgradeCommonOptions)

    let (paths, confirmAndCloneCode) = if basePackages.len > 0: (block:
        let installedVersions = installed.map(i => (i.name, i.version)).toTable

        printPackages(config.color, config.verbosePkgList,
          lc[(i.name, i.repo, installedVersions.opt(i.name), i.version) |
            (g <- basePackages, b <- g, i <- b), PackageInstallFormat]
            .sorted((a, b) => cmp(a.name, b.name)))
        let input = printColonUserChoice(config.color,
          tr"Proceed with building?", ['y', 'n'], 'y', 'n', noconfirm, 'y')

        if input == 'y':
          let (update, terminate) = if config.debug:
              (proc (a: int, b: int) {.closure.} = discard, proc {.closure.} = discard)
            else:
              printProgressShare(config.progressBar, tr"cloning repositories")

          let flatBasePackages = lc[x | (a <- basePackages, x <- a), seq[PackageInfo]]
          update(0, flatBasePackages.len)

          proc cloneNext(index: int, paths: seq[string]): (seq[string], int) =
            if index < flatBasePackages.len:
              let pkgInfos = flatBasePackages[index]
              let base = pkgInfos[0].base
              let repoPath = repoPath(config.tmpRoot, base)
              let (cloneCode, cloneErrorMessage) = cloneRepo(config, flatBasePackages[index])

              if cloneCode == 0:
                update(index + 1, flatBasePackages.len)
                cloneNext(index + 1, paths & repoPath)
              else:
                terminate()
                for e in cloneErrorMessage: printError(config.color, e)
                printError(config.color, tr"$#: failed to clone git repository" %
                  [pkgInfos[0].base])
                (paths & repoPath, cloneCode)
            else:
              terminate()
              (paths, 0)

          let (paths, cloneCode) = cloneNext(0, @[])
          if cloneCode != 0:
            (paths, cloneCode)
          else:
            proc checkNext(index: int, skipEdit: bool): int =
              if index < flatBasePackages.len:
                let pkgInfos = flatBasePackages[index]
                let base = pkgInfos[0].base
                let repoPath = repoPath(config.tmpRoot, base)

                let aur = pkgInfos[0].repo == "aur"

                if not skipEdit and aur and config.aurComments:
                  echo(tr"downloading comments from AUR...")
                  let (comments, error) = downloadAurComments(base)
                  for e in error: printError(config.color, e)
                  if comments.len > 0:
                    let commentsReversed = toSeq(comments.reversed)
                    printComments(config.color, pkgInfos[0].maintainer, commentsReversed)

                let res = if skipEdit:
                    'n'
                  else: (block:
                    let defaultYes = aur and not config.viewNoDefault
                    editLoop(config, base, repoPath, pkgInfos[0].gitPath, defaultYes, noconfirm))

                if res == 'a':
                  1
                else:
                  checkNext(index + 1, skipEdit or res == 's')
              else:
                0

            (paths, checkNext(0, false))
        else:
          (@[], 1))
      else:
        (@[], 0)

    proc removeTmp() =
      for path in paths:
        removeDirQuiet(path)
      discard rmdir(config.tmpRoot)

    if confirmAndCloneCode != 0:
      removeTmp()
      confirmAndCloneCode
    else:
      let (additionalCode, additionalSome) = if additionalPacmanTargets.len > 0: (block:
          printColon(config.color, tr"Installing build dependencies...")

          (pacmanRun(true, config.color, commonArgs &
            ("S", none(string), ArgumentType.short) &
            ("needed", none(string), ArgumentType.long) &
            ("asdeps", none(string), ArgumentType.long) &
            additionalPacmanTargets.map(t => (t, none(string), ArgumentType.target))), true))
        else:
          (0, false)

      if additionalCode != 0:
        removeTmp()
        additionalCode
      else:
        if basePackages.len > 0:
          # check all pacman dependencies were installed
          let unsatisfied = withAlpm(config.root, config.db,
            config.dbs, config.arch, handle, dbs, errors):
            for e in errors: printError(config.color, e)

            proc checkSatisfied(reference: PackageReference): bool =
              for pkg in handle.local.packages:
                if reference.isProvidedBy(($pkg.name, none(string),
                  some((ConstraintOperation.eq, $pkg.version)))):
                  return true
                for provides in pkg.provides:
                  if reference.isProvidedBy(provides.toPackageReference):
                    return true
              return false

            lc[x.key | (x <- dependencies.namedPairs, not x.value.installed and
              x.value.buildPkgInfo.isNone and not x.key.checkSatisfied), PackageReference]

          if unsatisfied.len > 0:
            removeTmp()
            printUnsatisfied(config, dependencies, unsatisfied)
            1
          else:
            proc installNext(index: int, lastCode: int): (int, int) =
              if index < basePackages.len and lastCode == 0:
                let code = installGroupFromSources(config, commonArgs,
                  basePackages[index], explicits, noconfirm)
                installNext(index + 1, code)
              else:
                (lastCode, index - 1)

            let (code, index) = installNext(0, 0)
            if code != 0 and index < basePackages.len - 1:
              printWarning(config.color, tr"installation aborted")
            removeTmp()
            code
        elif not directSome and not additionalSome:
          echo(trp(" there is nothing to do\n"))
          0
        else:
          0

proc handlePrint(args: seq[Argument], config: Config, printFormat: string,
  upgradeCount: int, directPacmanTargets: seq[string], additionalPacmanTargets: seq[string],
  basePackages: seq[seq[seq[PackageInfo]]]): int =

  let code = if directPacmanTargets.len > 0 or
    additionalPacmanTargets.len > 0 or upgradeCount > 0:
      pacmanRun(false, config.color, args.filter(arg => not arg.isTarget) &
        (directPacmanTargets & additionalPacmanTargets)
        .map(t => (t, none(string), ArgumentType.target)))
    else:
      0

  if code == 0:
    proc printWithFormat(pkgInfo: PackageInfo) =
      echo(printFormat
        .replace("%n", pkgInfo.name)
        .replace("%v", pkgInfo.version)
        .replace("%r", "aur")
        .replace("%s", "0")
        .replace("%l", pkgInfo.gitUrl))

    for installGroup in basePackages:
      for pkgInfos in installGroup:
        for pkgInfo in pkgInfos:
          printWithFormat(pkgInfo)
    0
  else:
    code

proc handleSyncInstall*(args: seq[Argument], config: Config): int =
  let (_, callArgs) = checkAndRefresh(config.color, args)

  let upgradeCount = args.count((some("u"), "sysupgrade"))
  let needed = args.check((none(string), "needed"))
  let noaur = args.check((none(string), "noaur"))
  let build = args.check((none(string), "build"))

  let printModeArg = args.check((some("p"), "print"))
  let printModeFormat = args.filter(arg => arg
    .matchOption((none(string), "print-format"))).optLast
  let printFormat = if printModeArg or printModeFormat.isSome:
      some(printModeFormat.map(arg => arg.value.get).get("%l"))
    else:
      none(string)

  let noconfirm = args
    .filter(arg => arg.matchOption((none(string), "confirm")) or
      arg.matchOption((none(string), "noconfirm"))).optLast
    .map(arg => arg.key == "noconfirm").get(false)

  let targets = args.packageTargets

  let (syncTargets, checkAur, installed) = withAlpm(config.root, config.db,
    config.dbs, config.arch, handle, dbs, errors):
    for e in errors: printError(config.color, e)

    let (syncTargets, checkAur) = findSyncTargets(handle, dbs, targets,
      not build, not build)

    let installed = lc[($p.name, $p.version, p.groupsSeq,
      dbs.filter(d => d[p.name] != nil).len == 0) |
      (p <- handle.local.packages), Installed]

    (syncTargets, checkAur, installed)

  let realCheckAur = if noaur:
      @[]
    elif upgradeCount > 0:
      installed
        .filter(i => i.foreign and
          (config.checkIgnored or not config.ignored(i.name, i.groups)))
        .map(i => i.name) & checkAur
    else:
      checkAur

  withAur():
    if realCheckAur.len > 0 and printFormat.isNone:
      printColon(config.color, tr"Checking AUR database...")
    let (rpcInfos, aerrors) = getRpcPackageInfo(realCheckAur)
    for e in aerrors: printError(config.color, e)

    let (rpcInfoTable, notFoundTargets) = filterNotFoundSyncTargets(syncTargets, rpcInfos)

    if notFoundTargets.len > 0:
      printSyncNotFound(config, notFoundTargets)
      1
    else:
      let fullTargets = mapAurTargets(syncTargets, rpcInfos)
      let pacmanTargets = fullTargets.filter(t => not isAurTargetFull(t))
      let aurTargets = fullTargets.filter(isAurTargetFull)

      if upgradeCount > 0 and not noaur and printFormat.isNone and config.printAurNotFound:
        for inst in installed:
          if inst.foreign and not config.ignored(inst.name, inst.groups) and
            not rpcInfoTable.hasKey(inst.name):
            printWarning(config.color, tr"$# was not found in AUR" % [inst.name])

      let installedTable = installed.map(i => (i.name, i)).toTable

      proc checkNeeded(name: string, version: string): bool =
        if installedTable.hasKey(name):
          let i = installedTable[name]
          vercmp(version, i.version) > 0
        else:
          true

      let targetRpcInfos: seq[tuple[rpcInfo: RpcPackageInfo, upgradeable: bool]] =
        aurTargets.map(t => t.pkgInfo.get).map(i => (i, checkNeeded(i.name, i.version)))

      if printFormat.isNone and needed:
        for rpcInfo in targetRpcInfos:
          if not rpcInfo.upgradeable:
            # not upgradeable assumes that package is installed
            let inst = installedTable[rpcInfo.rpcInfo.name]
            printWarning(config.color, tra("%s-%s is up to date -- skipping\n") %
              [rpcInfo.rpcInfo.name, inst.version])

      let aurTargetsSet = aurTargets.map(t => t.name).toSet
      let fullRpcInfos = (targetRpcInfos
        .filter(i => not needed or i.upgradeable).map(i => i.rpcInfo) &
        rpcInfos.filter(i => upgradeCount > 0 and not (i.name in aurTargetsSet) and
          checkNeeded(i.name, i.version))).deduplicate

      if fullRpcInfos.len > 0 and printFormat.isNone:
        echo(tr"downloading full package descriptions...")
      let (aurPkgInfos, faerrors) = getAurPackageInfo(fullRpcInfos
        .map(i => i.name), some(fullRpcInfos), proc (a: int, b: int) = discard)

      if faerrors.len > 0:
        for e in faerrors: printError(config.color, e)
        1
      else:
        let neededPacmanTargets = if printFormat.isNone and build and needed:
            pacmanTargets.filter(target => (block:
              let version = target.foundInfo.get.pkg.get.version
              if checkNeeded(target.name, version):
                true
              else:
                printWarning(config.color, tra("%s-%s is up to date -- skipping\n") %
                  [target.name, version])
                false))
          else:
            pacmanTargets

        let checkPacmanPkgInfos = printFormat.isNone and build and
          neededPacmanTargets.len > 0

        let (buildPkgInfos, obtainErrorMessages) = if checkPacmanPkgInfos: (block:
            printColon(config.color, tr"Checking repositories...")
            obtainBuildPkgInfos(config, pacmanTargets))
          else:
            (@[], @[])

        if checkPacmanPkgInfos and buildPkgInfos.len < pacmanTargets.len:
          for e in obtainErrorMessages: printError(config.color, e)
          1
        else:
          let pkgInfos = buildPkgInfos & aurPkgInfos
          let targetsSet = fullTargets.map(t => t.name).toSet

          let acceptedPkgInfos = pkgInfos.filter(pkgInfo => (block:
            let instGroups = lc[x | (i <- installedTable.opt(pkgInfo.name),
              x <- i.groups), string]

            if config.ignored(pkgInfo.name, (instGroups & pkgInfo.groups).deduplicate):
              if pkgInfo.name in targetsSet:
                if printFormat.isNone:
                  let input = printColonUserChoice(config.color,
                    trp"%s is in IgnorePkg/IgnoreGroup. Install anyway?" % [pkgInfo.name],
                    ['y', 'n'], 'y', 'n', noconfirm, 'y')
                  input != 'n'
                else:
                  true
              else:
                false
            else:
              true))

          if acceptedPkgInfos.len > 0 and printFormat.isNone:
            echo(trp("resolving dependencies...\n"))
          let (satisfied, unsatisfied) = withAlpm(config.root, config.db,
            config.dbs, config.arch, handle, dbs, errors):
            findDependencies(config, handle, dbs, acceptedPkgInfos,
              printFormat.isSome, noaur)

          if unsatisfied.len > 0:
            printUnsatisfied(config, satisfied, unsatisfied)
            1
          else:
            if printFormat.isNone:
              let acceptedSet = acceptedPkgInfos.map(i => i.name).toSet

              for pkgInfo in pkgInfos:
                if not (pkgInfo.name in acceptedSet):
                  if not (pkgInfo.name in targetsSet) and upgradeCount > 0 and
                    installedTable.hasKey(pkgInfo.name):
                    printWarning(config.color, tra("%s: ignoring package upgrade (%s => %s)\n") %
                      [pkgInfo.name, installedTable[pkgInfo.name].version, pkgInfo.version])
                  else:
                    printWarning(config.color, trp("skipping target: %s\n") % [pkgInfo.name])
                elif pkgInfo.repo == "aur" and pkgInfo.maintainer.isNone:
                  printWarning(config.color, tr"$# is orphaned" % [pkgInfo.name])

            let aurPrintSet = acceptedPkgInfos.map(i => i.name).toSet
            let fullPkgInfos = acceptedPkgInfos & lc[i | (s <- satisfied.values,
              i <- s.buildPkgInfo, not (i.name in aurPrintSet)), PackageInfo].deduplicate

            let directPacmanTargets = pacmanTargets.map(t => t.formatArgument)
            let additionalPacmanTargets = lc[x.name | (x <- satisfied.values,
              not x.installed and x.buildPkgInfo.isNone), string]
            let orderedPkgInfos = orderInstallation(fullPkgInfos, satisfied)

            let pacmanArgs = callArgs.filterExtensions(true, true)

            if printFormat.isSome:
              handlePrint(pacmanArgs, config, printFormat.unsafeGet, upgradeCount,
                directPacmanTargets, additionalPacmanTargets, orderedPkgInfos)
            else:
              let explicits = if not args.check((none(string), "asdeps")):
                  targets.map(t => t.name)
                else:
                  @[]

              let passDirectPacmanTargets = if build: @[] else: directPacmanTargets

              handleInstall(pacmanArgs, config, upgradeCount, noconfirm,
                explicits.toSet, installed, satisfied, passDirectPacmanTargets,
                additionalPacmanTargets, orderedPkgInfos)
