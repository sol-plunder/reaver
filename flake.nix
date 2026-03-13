{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }: {
    devShells.x86_64-linux.default =
      let
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        ghcEnv = pkgs.haskellPackages.ghcWithPackages (hp: with hp; [
          text primitive pretty-show containers deepseq
          optics ghc-prim mtl transformers cryptohash-sha256
          base58-bytestring vector
        ]);
      in
        pkgs.mkShell {
          packages = [
            ghcEnv
            pkgs.haskellPackages.ghcid
            pkgs.haskellPackages.stylish-haskell
          ];
        };
  };
}
