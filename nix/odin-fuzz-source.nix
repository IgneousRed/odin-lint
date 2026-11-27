# Canonical full-public source declaration for published odin-fuzz 0.5.0 main.
{ fetchFromGitHub }:
let
  owner = "IgneousRed";
  repo = "odin-fuzz";
  version = "0.5.0";
  rev = "ed06f23bea76601e44efc9c5c13e42e54b1b9f14";
  hash = "sha256-2GTSHyTO0fqoMJJzD84Sjq0oOd5nmIoehN/TahXbVOU=";
in
{
  inherit
    owner
    repo
    version
    rev
    hash
    ;
  src = fetchFromGitHub {
    inherit
      owner
      repo
      rev
      hash
      ;
  };
}
