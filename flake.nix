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
      in {
        devShells.default = pkgs.mkShell {
          packages = [ luajitWithLfs ] ++ testDeps;
          shellHook = ''
            echo "rm-safe dev shell: luajit($(luajit -v 2>&1 | head -1)) + bash $BASH_VERSION"
            echo "run tests: bin/test/run-all"
          '';
        };
      });
}
