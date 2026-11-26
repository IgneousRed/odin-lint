# Canonical source declaration for published IgneousRed/odin-fuzz v0.5.0.
{ fetchFromGitHub }:
let
  owner = "IgneousRed";
  repo = "odin-fuzz";
  version = "0.5.0";
  rev = "48ebaa452381da86b2b54b76b4879511a3f2be03";
  hash = "sha256-RiM9jLYUBLREfrhY12J2OEXUrpsQYWrad+UISiGD7J0=";
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
