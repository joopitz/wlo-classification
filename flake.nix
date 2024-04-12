{
  description = "A Python package defined as a Nix Flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
    flake-utils.url = "github:numtide/flake-utils";
    openapi-checks = {
      url = "github:openeduhub/nix-openapi-checks";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    {
      # define an overlay to add wlo-classification to nixpkgs
      overlays.default = (final: prev: {
        inherit (self.packages.${final.system}) wlo-classification;
      });
    } //
    # tensorflow is currently marked as broken on darwin
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        projectDir = self;
        # import the packages from nixpkgs
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        openapi-checks = self.inputs.openapi-checks.lib.${system};

        # the python version we are using
        python = pkgs.python3;

        ### create the python installation for the package
        python-packages-build = py-pkgs:
          with py-pkgs; [
            numpy
            scikit-learn
            pandas
            nltk
            tensorflow
            fastapi
            pydantic
            uvicorn
            transformers
            keras
          ];

        ### create the python installation for development
        # the development installation contains all build packages,
        # plus some additional ones we do not need to include in production.
        python-packages-devel = py-pkgs:
          with py-pkgs; [
            ipython
            jupyter
            black
          ] ++ (python-packages-build py-pkgs);

        ### create the python package
        # download the metadata on the bert language model being used.
        # cannot be moved to inputs due to git LFS
        gbert-base = pkgs.fetchgit {
          url = "https://huggingface.co/deepset/gbert-base";
          rev = "e2073f52ebb8dd8b50ed5230a9752e251105c096";
          hash = "sha256-iRNhzt/VNkOErS1/slIQ0jS0472qNSlNNow9juzdu3w=";
          # do not fetch the files managed by git LFS
          fetchLFS = false;
        };

        # download the full wlo-classification model.
        # cannot be moved to inputs due to git LFS
        wlo-classification-model = pkgs.fetchFromGitLab {
          domain = "gitlab.gwdg.de";
          owner = "jopitz";
          repo = "wlo-classification-model";
          rev = "66661ad257969a66af632fc5b184765d0ef95fd8";
          hash = "sha256-CIZAbCH5JUAXOchxSByCxUO/p9jR1B+8CkIOoNOQtiA=";
        };

        # build the application itself
        python-app = python.pkgs.buildPythonApplication {
          pname = "wlo-classification";
          version = "0.1.0";
          src = projectDir;
          propagatedBuildInputs = (python-packages-build python.pkgs);
          # set the folder for NLTK resources
          # and run the application with the model file already specified
          makeWrapperArgs = [
            "--set NLTK_DATA ${pkgs.nltk-data.stopwords}"
            "--add-flags ${wlo-classification-model}"
          ];
          # use prefetched external resources
          prePatch = ''
            substituteInPlace src/*.py \
              --replace "deepset/gbert-base" "${gbert-base}"
          '';
          # this package has no tests.
          # additionally, the automatic import test fails for fastapi for some
          # reason (supposedly due to an mismatch in starlette's version), even
          # though the library works perfectly fine.
          doCheck = false;
        };

        ### build the docker image
        docker-img = pkgs.dockerTools.buildLayeredImage {
          name = python-app.pname;
          tag = python-app.version;
          config = {
            Cmd = [ "${python-app}/bin/wlo-classification" ];
          };
        };

      in
      {
        # the packages that we can build
        packages = rec {
          wlo-classification = python-app;
          docker = docker-img;
          default = wlo-classification;
        };
        # the development environment
        devShells.default = pkgs.mkShell {
          buildInputs = [
            # the development installation of python
            (python.withPackages python-packages-devel)
            # non-python packages
            pkgs.nodePackages.pyright
            # for automatically generating nix expressions, e.g. from PyPi
            pkgs.nix-init
            pkgs.nix-template
          ];
        };
        # checks
        checks = {
          openapi-valid = openapi-checks.test-service {
            service-bin = "${self.packages.${system}.wlo-classification}/bin/wlo-classification";
            memory-size = 4 * 1024;
            service-port = 8080;
            openapi-domain = "/openapi.json";
          };
        };
      });
}
