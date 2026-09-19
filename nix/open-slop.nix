# The Haskell package, in the shape cabal2nix produces, committed rather than
# generated at evaluation time so a consumer flake never needs
# import-from-derivation to evaluate open-slop. Regenerate after editing
# haskell/open-slop.cabal:
#
#   nix run .#cabal2nix
#
# which writes this file from the cabal file. The dependency lists below must
# match the cabal file's; the app checks that they do.
{
  mkDerivation,
  aeson,
  base,
  base16-bytestring,
  bytestring,
  containers,
  cryptohash-sha256,
  directory,
  filelock,
  filepath,
  http-client,
  http-client-tls,
  http-types,
  lib,
  optparse-applicative,
  tasty,
  tasty-hunit,
  tasty-quickcheck,
  text,
  time,
  typed-process,
  unix,
}:
mkDerivation {
  pname = "open-slop";
  version = "0.1.0.0";
  src = ../haskell;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson
    base
    base16-bytestring
    bytestring
    containers
    cryptohash-sha256
    directory
    filelock
    filepath
    http-client
    http-client-tls
    http-types
    text
    time
  ];
  executableHaskellDepends = [
    aeson
    base
    bytestring
    containers
    directory
    filepath
    optparse-applicative
    text
    time
    typed-process
    unix
  ];
  testHaskellDepends = [
    base
    tasty
    tasty-hunit
    tasty-quickcheck
    text
  ];
  description = "A Nix-configured local LLM machine: catalogue, engines, jobs, client";
  license = lib.licenses.agpl3Plus;
  mainProgram = "llmq";
}
