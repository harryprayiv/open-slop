{ mkDerivation, aeson, base, base16-bytestring, bytestring
, containers, cryptohash-sha256, directory, filelock, filepath
, http-client, http-client-tls, http-types, lib
, optparse-applicative, tasty, tasty-hunit, tasty-quickcheck, text
, time, typed-process, unix
}:
mkDerivation {
  pname = "open-slop";
  version = "0.1.0.0";
  src = ./haskell;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson base base16-bytestring bytestring containers
    cryptohash-sha256 directory filelock filepath http-client
    http-client-tls http-types text time
  ];
  executableHaskellDepends = [
    aeson base bytestring containers directory filepath
    optparse-applicative text time typed-process unix
  ];
  testHaskellDepends = [
    base tasty tasty-hunit tasty-quickcheck text
  ];
  description = "A Nix-configured local LLM machine: catalogue, engines, jobs, client";
  license = lib.meta.getLicenseFromSpdxId "AGPL-3.0-or-later";
  mainProgram = "llmq";
}
