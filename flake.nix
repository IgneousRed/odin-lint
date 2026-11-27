{
  description = "Locked local tools and source-independent odin-lint package";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/619c39f6eac5d1ed6b8f073a9414baf7034b2356";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-linux" ];
      forSystems = nixpkgs.lib.genAttrs systems;
      environment = system: withFuzzer:
        assert !withFuzzer || system == "aarch64-darwin";
        let
          pkgs = import nixpkgs { inherit system; };
          toolchain = if system == "aarch64-darwin" then
            import ./nix/llvm23/llvm23-toolchain.nix { inherit pkgs; }
            else import ./nix/toolchain.nix { inherit pkgs; };
          python = if system == "aarch64-darwin" then toolchain.python else pkgs.python3;
          fuzzSource = pkgs.callPackage ./nix/odin-fuzz-source.nix { };
          fuzzer = pkgs.callPackage ./nix/odin-fuzz-package.nix ({
            inherit (toolchain) odin llvmPackages;
            inherit (fuzzSource) src version;
            patches = [ ];
          } // pkgs.lib.optionalAttrs (system == "aarch64-darwin") {
            python3 = python;
          });
          tools = [
            toolchain.odin
            pkgs.gnumake
            (toolchain.git or pkgs.git)
            python
            toolchain.llvmPackages.clang
            toolchain.llvmPackages.llvm
          ] ++ pkgs.lib.optionals withFuzzer [ fuzzer ];
          variables = {
            ODIN = "${toolchain.odin}/bin/odin";
            ODIN_ROOT = "${toolchain.odin}/share";
            PYTHON = "${python}/bin/python3";
            PYTHONDONTWRITEBYTECODE = "1";
            PYTHONNOUSERSITE = "1";
          } // pkgs.lib.optionalAttrs withFuzzer {
            ODIN_FUZZ = "${fuzzer}/bin/odin-fuzz";
          };
          updates = {
            schema = 1;
            dependencies = [
              { name = "nixpkgs"; current = nixpkgs.rev; kind = "github-revision";
                repository = "NixOS/nixpkgs"; ref = "nixpkgs-unstable"; }
              { name = "odin"; current = toolchain.odin.version; kind = "github-release";
                repository = "odin-lang/Odin"; }
              { name = "odin-fuzz"; current = fuzzSource.rev; kind = "github-revision";
                repository = "IgneousRed/odin-fuzz"; ref = "main"; }
            ] ++ pkgs.lib.optionals (system == "aarch64-darwin") [
              { name = "llvm"; current = "llvmorg-${toolchain.native.version}";
                kind = "github-release"; repository = "llvm/llvm-project"; }
            ];
          };
          unset = [ "PYTHONHOME" "PYTHONPATH" "VIRTUAL_ENV"
            "ODIN_FUZZ_SCANNER" "ODIN_FUZZ_SCANNER_CACHE" ]
            ++ pkgs.lib.optionals (!withFuzzer) [ "ODIN_FUZZ" ];
          manifest = pkgs.writeTextDir "share/project-environment.json" (builtins.toJSON {
            schema = 1;
            inherit variables unset;
          });
          metadata = pkgs.writeTextDir "share/dependency-updates.json" (builtins.toJSON updates);
          package = pkgs.buildEnv {
            name = "odin-lint-${if withFuzzer then "fuzz" else "dev"}-environment";
            paths = tools ++ [ manifest metadata ];
            pathsToLink = [ "/bin" ];
            postBuild = ''
              mkdir -p "$out/share"
              ln -s ${manifest}/share/project-environment.json "$out/share/project-environment.json"
              ln -s ${metadata}/share/dependency-updates.json "$out/share/dependency-updates.json"
            '';
          };
        in
        { inherit pkgs toolchain python tools variables unset updates package; };
    in
    {
      # Lazy component identities for portable native-unit verification/reuse.
      lib.nativeToolchain = forSystems (system: (environment system false).toolchain);

      lib.dependencyCheck = forSystems (system:
        let
          inherit (environment system false) pkgs python updates;
          interpreter = pkgs.python315;
        in {
          inherit interpreter;
          python = "${interpreter}/bin/python3";
          preferredPython = if system == "aarch64-darwin" then
            "${python}/bin/python3"
            else "";
          metadata = updates;
        });

      packages = forSystems (system:
        let
          inherit (environment system false) pkgs toolchain package;
          binary = pkgs.callPackage ./nix/package.nix ({
            odin = toolchain.odin;
            src = self;
            revision = self.rev or "unknown";
            development = !(self ? rev);
          } // pkgs.lib.optionalAttrs (system == "aarch64-darwin") {
            stdenv = toolchain.llvmPackages.stdenv;
          });
        in
        {
          default = binary;
          odin-lint = binary;
          dev-environment = package;
        } // pkgs.lib.optionalAttrs (system == "aarch64-darwin") {
          fuzz-environment = (environment system true).package;
        });

      devShells = forSystems (system:
        let
          inherit (environment system false) pkgs variables unset package;
        in
        {
          default = pkgs.mkShellNoCC (variables // {
            packages = [ package ];
            PROJECT_NIX_ENVIRONMENT = toString package;
            shellHook = "unset " + pkgs.lib.concatStringsSep " " unset;
          });
        } // pkgs.lib.optionalAttrs (system == "aarch64-darwin") {
          fuzz = let selected = environment system true; in
            pkgs.mkShellNoCC (selected.variables // {
              packages = [ selected.package ];
              PROJECT_NIX_ENVIRONMENT = toString selected.package;
              shellHook = "unset " + pkgs.lib.concatStringsSep " " selected.unset;
            });
        });
    };
}
