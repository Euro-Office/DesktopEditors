# Desktop Editors

Docker image where we are experimenting with building the OnlyOffice Desktop Editors.

## Building the Image

First, clone the repositories for the core-fonts, sdkjs, web-apps, and server components:

```sh
git clone --recurse-submodules https://github.com/Euro-Office/DesktopEditors.git
```

If the repo was cloned without --recurse-submodules, initialize and download the submodules with:
```sh
git submodule update --init --recursive
```

Then, you can build the full image by running:

```sh
cd DesktopEditors/build
docker buildx bake
```

After it finishes the desktop editors will be in build/deploy/desktop