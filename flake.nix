{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        # "aarch64-linux"
        # "x86_64-darwin"
        # "aarch64-darwin"
      ];
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          nordvpn-wg = pkgs.stdenvNoCC.mkDerivation {
            pname = "nordvpn-wg";
            version = "1.0.0";

            src = ./.;

            dontBuild = true;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              runHook preInstall

              install -Dm755 nordvpn-wg.sh $out/bin/nordvpn-wg

              wrapProgram $out/bin/nordvpn-wg \
                --prefix PATH : ${
                  pkgs.lib.makeBinPath [
                    pkgs.bash      # for the /usr/bin/env bash shebang
                    pkgs.coreutils # tr, sort, cat, mkdir, chmod
                    pkgs.curl
                    pkgs.gnugrep
                    pkgs.gnused
                  ]
                }

              runHook postInstall
            '';
          };
        in
        {
          inherit nordvpn-wg;
          default = nordvpn-wg;
        }
      );
    };
}
