{
  description = "Moonlight Android - reproducible toolchain to build & sign the non-root release APK";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # androidenv only ships the SDK/NDK for these systems.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Versions mirror .github/workflows/android.yml and app/build.gradle.
      ndkVersion = "27.0.12077973";
      buildToolsVersion = "34.0.0";
      platformVersion = "34";

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config = {
            android_sdk.accept_license = true;
            allowUnfree = true;
          };
        };

      androidFor =
        system:
        let
          pkgs = pkgsFor system;
          composition = pkgs.androidenv.composeAndroidPackages {
            cmdLineToolsVersion = "11.0";
            platformVersions = [ platformVersion ];
            buildToolsVersions = [ buildToolsVersion ];
            ndkVersions = [ ndkVersion ];
            includeNDK = true;
          };
          sdkRoot = "${composition.androidsdk}/libexec/android-sdk";
        in
        {
          inherit pkgs composition sdkRoot;
          ndkRoot = "${sdkRoot}/ndk/${ndkVersion}";
          # Nix-patched aapt2. The copy AGP fetches from Maven is a glibc ELF
          # that cannot run on NixOS, so we force the build to use this one.
          aapt2 = "${sdkRoot}/build-tools/${buildToolsVersion}/aapt2";
          apksigner = "${sdkRoot}/build-tools/${buildToolsVersion}/apksigner";
        };

      buildScript =
        system:
        let
          a = androidFor system;
          pkgs = a.pkgs;
        in
        pkgs.writeShellApplication {
          name = "build-moonlight-apk";
          runtimeInputs = [
            pkgs.jdk17
            pkgs.git
            pkgs.coreutils
          ];
          text = ''
            export ANDROID_HOME="${a.sdkRoot}"
            export ANDROID_SDK_ROOT="${a.sdkRoot}"
            export ANDROID_NDK_ROOT="${a.ndkRoot}"
            export JAVA_HOME="${pkgs.jdk17.home}"

            repo_root="$(git rev-parse --show-toplevel)"
            cd "$repo_root"

            echo ">> Ensuring native submodule is checked out"
            git submodule update --init --recursive

            echo ">> Writing local.properties"
            {
              echo "sdk.dir=${a.sdkRoot}"
              echo "ndk.dir=${a.ndkRoot}"
            } > local.properties

            echo ">> Building assembleNonRootRelease"
            ./gradlew --no-daemon \
              -Pandroid.aapt2FromMavenOverride="${a.aapt2}" \
              assembleNonRootRelease

            unsigned="app/build/outputs/apk/nonRoot/release/app-nonRoot-release-unsigned.apk"
            signed="app-nonRoot-release-signed.apk"

            # Real signing config can be supplied via env. Otherwise generate a
            # throwaway key, exactly like the CI workflow does.
            keystore="''${KEYSTORE:-}"
            key_alias="''${KEY_ALIAS:-temp_key}"
            store_pass="''${KEYSTORE_PASS:-password}"
            key_pass="''${KEY_PASS:-password}"

            if [ -z "$keystore" ]; then
              keystore="$(mktemp -u --suffix=.keystore)"
              echo ">> No KEYSTORE set, generating throwaway key at $keystore"
              keytool -genkeypair -v \
                -keystore "$keystore" -alias "$key_alias" \
                -keyalg RSA -keysize 2048 -validity 10000 \
                -storepass "$store_pass" -keypass "$key_pass" \
                -dname "CN=MoonlightLocalBuild"
            fi

            echo ">> Signing APK"
            "${a.apksigner}" sign \
              --ks "$keystore" --ks-key-alias "$key_alias" \
              --ks-pass "pass:$store_pass" --key-pass "pass:$key_pass" \
              --out "$signed" "$unsigned"

            "${a.apksigner}" verify --verbose "$signed"
            echo ">> Done: $repo_root/$signed"
          '';
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          a = androidFor system;
        in
        {
          # The pinned Android SDK + NDK (handy for `nix build .#androidSdk`).
          androidSdk = a.composition.androidsdk;
          build = buildScript system;
          default = buildScript system;
        }
      );

      apps = forAllSystems (system: {
        build = {
          type = "app";
          program = "${buildScript system}/bin/build-moonlight-apk";
        };
        default = {
          type = "app";
          program = "${buildScript system}/bin/build-moonlight-apk";
        };
      });

      devShells = forAllSystems (
        system:
        let
          a = androidFor system;
          pkgs = a.pkgs;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.jdk17
              pkgs.gradle
              pkgs.git
              a.composition.androidsdk
            ];

            ANDROID_HOME = a.sdkRoot;
            ANDROID_SDK_ROOT = a.sdkRoot;
            ANDROID_NDK_ROOT = a.ndkRoot;
            JAVA_HOME = pkgs.jdk17.home;
            GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${a.aapt2}";

            shellHook = ''
              {
                echo "sdk.dir=${a.sdkRoot}"
                echo "ndk.dir=${a.ndkRoot}"
              } > local.properties
              echo "Android SDK: ${a.sdkRoot}"
              echo "NDK:         ${a.ndkRoot}"
              echo "Build with:  ./gradlew assembleNonRootRelease"
            '';
          };
        }
      );
    };
}
