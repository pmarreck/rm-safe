{
  description = "rm-safe: a safer rm that moves files to the trash (luajit + portable bash)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;

        luajitWithLfs = pkgs.luajit.withPackages (ps: [ ps.luafilesystem ]);

        # g-prefixed GNU tools (mirrors ~/.config/nix/flake.nix): coreutils-prefixed
        # gives g* coreutils; this adds gsed/ggrep/gfind/gawk.
        gnuPrefixed = pkgs.runCommand "rm-safe-gnu-prefixed" { } ''
          mkdir -p $out/bin
          ln -s ${pkgs.gnused}/bin/sed     $out/bin/gsed
          ln -s ${pkgs.gnugrep}/bin/grep   $out/bin/ggrep
          ln -s ${pkgs.findutils}/bin/find $out/bin/gfind
          ln -s ${pkgs.gawk}/bin/awk       $out/bin/gawk
        '';

        # Runtime tools both impls may shell out to.
        runtimeDeps = [
          pkgs.coreutils-prefixed gnuPrefixed pkgs.gawk
          pkgs.gum pkgs.fzf pkgs.glib pkgs.trash-cli
        ];

        testDeps = runtimeDeps ++ [ pkgs.bashInteractive pkgs.expect pkgs.coreutils ];

        # checkDeps omits gum/fzf so the suite skips the pty-driven picker tests
        # (gum/fzf drive a pty via expect which is flaky/broken in the headless
        # nix sandbox).  The core undo/restore parity tests still run.
        # gum/fzf remain in testDeps so the devShell gets them for local testing.
        checkDeps = lib.filter (d: d != pkgs.gum && d != pkgs.fzf) testDeps;
      in {
        packages = rec {
          rm-safe = pkgs.stdenv.mkDerivation {
            pname = "rm-safe"; version = "5.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              mkdir -p $out/bin
              cp bin/rm-safe $out/bin/rm-safe-luajit
              cp bin/rm-safe.bash $out/bin/rm-safe.bash
              cp bin/rm $out/bin/rm
              makeWrapper ${luajitWithLfs}/bin/luajit $out/bin/rm-safe \
                --add-flags $out/bin/rm-safe-luajit \
                --prefix PATH : ${lib.makeBinPath runtimeDeps}
              wrapProgram $out/bin/rm-safe.bash \
                --prefix PATH : ${lib.makeBinPath (runtimeDeps ++ [ pkgs.bashInteractive ])}
            '';
          };
          rm-safe-bash = pkgs.stdenv.mkDerivation {
            pname = "rm-safe-bash"; version = "5.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              mkdir -p $out/bin
              cp bin/rm-safe.bash $out/bin/rm-safe-bash-impl
              makeWrapper ${pkgs.bashInteractive}/bin/bash $out/bin/rm-safe-bash \
                --add-flags $out/bin/rm-safe-bash-impl \
                --prefix PATH : ${lib.makeBinPath (runtimeDeps ++ [ pkgs.bashInteractive ])}
            '';
          };
          default = rm-safe;
        };

        devShells.default = pkgs.mkShell {
          packages = [ luajitWithLfs ] ++ testDeps;
          shellHook = ''
            echo "rm-safe dev shell: luajit($(luajit -v 2>&1 | head -1)) + bash $BASH_VERSION"
            echo "run tests: bin/test/run-all"
          '';
        };

        checks.tests = pkgs.runCommand "rm-safe-tests"
          { nativeBuildInputs = checkDeps ++ [ luajitWithLfs ]; }
          ''
            cp -r ${./.} src && chmod -R u+w src && cd src
            export HOME=$TMPDIR
            bin/test/run-all
            touch $out
          '';
      });
}
