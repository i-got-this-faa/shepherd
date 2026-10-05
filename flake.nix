{
  description = "Shepherd — Declarative fleet management for Windows, NixOS, and macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {};
          overlays = [];
        };

        version = "0.1.0-dev";
        src = builtins.path {
          path = ./.;
          name = "shepherd-source";
        };

        mkShepherdBinary = { pname, subPackages, description }:
          pkgs.buildGoModule {
            inherit pname version src subPackages;
            vendorHash = null;

            ldflags = [
              "-s" "-w"
              "-X github.com/i-got-this-faa/shepherd/internal/version.Version=${version}"
            ];

            meta = with pkgs.lib; {
              inherit description;
              homepage = "https://github.com/i-got-this-faa/shepherd";
              license = licenses.asl20;
            };
          };

      in {
        packages = {
          default = self.packages.${system}.shepherd-node;

          shepherd = mkShepherdBinary {
            pname = "shepherd";
            subPackages = [ "apps/control-plane/cmd/shepherd" ];
            description = "Central control plane service";
          };

          shepherd-node = mkShepherdBinary {
            pname = "shepherd-node";
            subPackages = [ "apps/node-daemon/cmd/shepherd-node" ];
            description = "Cross-platform node daemon";
          };

          shepherd-builder = mkShepherdBinary {
            pname = "shepherd-builder";
            subPackages = [ "apps/build-worker/cmd/shepherd-builder" ];
            description = "Build and artifact worker";
          };

          shepherd-derper = mkShepherdBinary {
            pname = "shepherd-derper";
            subPackages = [ "infra/networking/relays/cmd/shepherd-derper" ];
            description = "Tailcat DERP relay wrapper";
          };

          shepherdctl = mkShepherdBinary {
            pname = "shepherdctl";
            subPackages = [ "tools/shepherdctl" ];
            description = "Admin and operator CLI";
          };
        };

        checks = {
          shepherd = self.packages.${system}.shepherd;
          shepherd-node = self.packages.${system}.shepherd-node;
          shepherd-builder = self.packages.${system}.shepherd-builder;
          shepherd-derper = self.packages.${system}.shepherd-derper;
          shepherdctl = self.packages.${system}.shepherdctl;
        };

        devShells.default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            go_1_27
            gopls
            golangci-lint
            buf
            protoc-gen-go
            protoc-gen-connect-go
            bun
            postgresql
            attic-client
            sqlc
            goose
            gitleaks
            nixfmt
            jq
            git
          ];

          shellHook = ''
            export GOPATH="$HOME/go"
            export PATH="$GOPATH/bin:$PATH"
          '';
        };

        formatter = pkgs.nixfmt;
      }
    );
}
