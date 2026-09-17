{ pkgs, ... }:
{
  name = "storm-software/model-router";

  dotenv = {
    enable = true;
    filename = [
      ".env"
      ".env.local"
    ];
    disableHint = true;
  };
}
