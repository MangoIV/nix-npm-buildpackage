{ stdenvNoCC, writeShellScriptBin, writeText, runCommand,
  stdenv, fetchurl, makeWrapper, nodejs-10_x, yarn2nix, yarn }:
with stdenv.lib; let
  inherit (builtins) fromJSON toJSON split removeAttrs;

  depsToFetches = deps: concatMap depToFetch (attrValues deps);

  depFetchOwn = { resolved, integrity, name ? null, ... }:
    let
      ssri      = split "-" integrity;
      hashType  = head ssri;
      hash      = elemAt ssri 2;
      bname     = baseNameOf resolved;
      fname     = if hasSuffix ".tgz" bname || hasSuffix ".tar.gz" bname
                  then bname else bname + ".tgz";
    in nameValuePair resolved {
      inherit name bname;
      path = fetchurl { name = fname; url = resolved; "${hashType}" = hash; };
    };

  depToFetch = args @ { resolved ? null, dependencies ? {}, ... }:
    (optional (resolved != null) (depFetchOwn args)) ++ (depsToFetches dependencies);

  cacheInput = oFile: iFile: writeText oFile (toJSON (listToAttrs (depToFetch iFile)));

  patchShebangs = writeShellScriptBin "patchShebangs.sh" ''
    set -e
    source ${stdenvNoCC}/setup
    patchShebangs "$@"
  '';

  shellWrap = writeShellScriptBin "npm-shell-wrap.sh" ''
    set -e
    if [ ! -e .shebangs_patched ]; then
      ${patchShebangs}/bin/patchShebangs.sh .
      touch .shebangs_patched
    fi
    exec bash "$@"
  '';

  npmInfo = src: rec {
    pkgJson = src + "/package.json";
    info    = fromJSON (readFile pkgJson);
    name    = "${info.name}-${info.version}";
  };

  npmCmd      = "${nodejs-10_x}/bin/npm";
  npmAlias    = ''npm() { ${npmCmd} "$@" $npmFlags; }'';
  npmModules  = "${nodejs-10_x}/lib/node_modules/npm/node_modules";

  yarnCmd     = "${yarn}/bin/yarn";
  yarnAlias   = ''yarn() { ${yarnCmd} "$@" $yarnFlags; }'';
in {
  buildNpmPackage = args @ {
    src, npmBuild ? "npm ci", npmBuildMore ? "",
    buildInputs ? [], npmFlags ? [], ...
  }:
    let
      info  = npmInfo src;
      lock  = fromJSON (readFile (src + "/package-lock.json"));
    in stdenv.mkDerivation ({
      inherit (info) name;
      inherit (info.info) version;

      XDG_CONFIG_DIRS     = ".";
      NO_UPDATE_NOTIFIER  = true;
      preBuildPhases      = [ "npmCachePhase" ];
      preInstallPhases    = [ "npmPackPhase" ];
      installJavascript   = true;

      npmCachePhase = ''
        addToSearchPath NODE_PATH ${npmModules}   # pacote
        node ${./mknpmcache.js} ${cacheInput "npm-cache-input.json" lock}
      '';

      buildPhase = ''
        ${npmAlias}
        runHook preBuild
        ${npmBuild}
        ${npmBuildMore}
        runHook postBuild
      '';

      # make a package .tgz (no way around it)
      npmPackPhase = ''
        ${npmAlias}
        npm prune --production
        npm pack --ignore-scripts
      '';

      # unpack the .tgz into output directory and add npm wrapper
      # TODO: "cd $out" vs NIX_NPM_BUILDPACKAGE_OUT=$out?
      installPhase = ''
        mkdir -p $out/bin
        tar xzvf ./${info.name}.tgz -C $out --strip-components=1
        if [ "$installJavascript" = "1" ]; then
          cp -R node_modules $out/
          makeWrapper ${npmCmd} $out/bin/npm --run "cd $out"
        fi
      '';
    } // args // {
      buildInputs = [ nodejs-10_x makeWrapper ] ++ buildInputs; # TODO: git?
      npmFlags    = [ "--cache=./npm-cache" "--offline" "--script-shell=${shellWrap}/bin/npm-shell-wrap.sh" ] ++ npmFlags;
    });

  buildYarnPackage = args @ {
    src, yarnBuild ? "yarn", yarnBuildMore ? "", integreties ? {},
    buildInputs ? [], yarnFlags ? [], npmFlags ? [], ...
  }:
    let
      info        = npmInfo src;
      deps        = { dependencies = fromJSON (readFile yarnJson); };
      yarnIntFile = writeText "integreties.json" (toJSON integreties);
      yarnLock    = src + "/yarn.lock";
      yarnJson    = runCommand "yarn.json" {} ''
        set -e
        addToSearchPath NODE_PATH ${npmModules}             # ssri
        addToSearchPath NODE_PATH ${yarn2nix.node_modules}  # @yarnpkg/lockfile
        ${nodejs-10_x}/bin/node ${./mkyarnjson.js} ${yarnLock} ${yarnIntFile} > $out
      '';
    in stdenv.mkDerivation ({
      inherit (info) name;
      inherit (info.info) version;

      # ... TODO ...

      preBuildPhases = [ "yarnConfigPhase" "yarnCachePhase" ];

      # TODO
      yarnConfigPhase = ''
        { echo yarn-offline-mirror \"$PWD/yarn-cache\"
          echo script-shell \"${shellWrap}/bin/npm-shell-wrap.sh\"
        } >> .yarnrc
      '';

      yarnCachePhase = ''
        mkdir -p yarn-cache
        node ${./mkyarncache.js} ${cacheInput "yarn-cache-input.json" deps}
      '';

      # ... TODO ...

      buildPhase = ''
        ${yarnAlias}
        runHook preBuild
        ${yarnBuild}
        ${yarnBuildMore}
        runHook postBuild
      '';

      # ... TODO ...

      installPhase = ''
        mkdir -p $out/bin
        # TODO
      '';
    } // removeAttrs args [ "integreties" ] // {
      buildInputs = [ nodejs-10_x yarn ] ++ buildInputs;        # TODO: git?
      yarnFlags   = [ "--offline" ] ++ yarnFlags;
      # TODO: npmFlags
    });
}