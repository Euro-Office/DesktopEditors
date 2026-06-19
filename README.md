[![License](https://img.shields.io/badge/License-GNU%20AGPL%20V3-green.svg?style=flat)](https://www.gnu.org/licenses/agpl-3.0.en.html)
![Platforms Windows | macOS | Linux](https://img.shields.io/badge/Platforms-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey.svg?style=flat)

## Welcome to the Desktop Editors repo!

[Desktop Editors](https://github.com/Euro-Office/DesktopEditors) is a free office suite that combines text, spreadsheet, presentation, and PDF editors & Diagram Viewer. The application allows creating, viewing and editing documents stored on your Windows/Linux PC or Mac without an Internet connection. It is fully compatible with Office Open XML formats: .docx, .xlsx, .pptx.

## Features you'll love ✨

Take advantage of the powerful editors included in Desktop Editors.

* Document Editor
* Spreadsheet Editor
* Presentation Editor
* Form Creator
* PDF Editor
* Diagram Viewer

The suite empowers you to create, edit, save, and export text documents, spreadsheets, presentations, PDFs, fill out PDF forms, open diagrams, all while offering additional advanced features such as:

* Connection to the cloud (Moodle, Nextcloud, ownCloud, Seafile, Liferay, kDrive) for real-time collaboration ☁️
* AI-powered assistants 🤖
* Digital signatures ✍️🔏
* Password protection 🔒🔑
* Scalable UI options (including dark mode 🌓)

## Localization 🌐

Constantly improving localization of the editors to make the suite accessible to all users, all over the world.

* Interface available in 46 languages
* RTL support
* Hieroglyph support 🈴

## Plugins 🧩

Desktop Editors offer support for plugins allowing developers to add specific features to the editors that are not directly related to the OOXML format.

## Components 📦

Desktop Editors contain the following components:

* [desktop-apps](https://github.com/Euro-Office/desktop-apps) - the frontend for Desktop Editors which is used to build the program interface for the operating system selected.
* [desktop-sdk](https://github.com/Euro-Office/desktop-sdk) - SDK which is a core part of Desktop Editors.
* [core](https://github.com/Euro-Office/core) - server core components for [Document Server][1] which is a part of Desktop Editors and is used to enable the conversion between the most popular office document formats (DOC, DOCX, ODT, RTF, TXT, PDF, HTML, EPUB, XPS, DjVu, XLS, XLSX, ODS, CSV, PPT, PPTX, ODP).
* [sdkjs](https://github.com/Euro-Office/sdkjs) - JavaScript SDK for the [Document Server][1] which is a part of Desktop Editors and contains API for all the included components client-side interaction.
* [web-apps](https://github.com/Euro-Office/web-apps) - the frontend for [Document Server][1] which is a part of Desktop Editors that allows the user to create, edit, save and export text, spreadsheet and presentation documents using the common interface of a document editor.
* [dictionaries](https://github.com/Euro-Office/dictionaries) - the dictionaries of various languages used for spellchecking in Desktop Editors.

## Build it yourself 🛠️

You can build Desktop Editors from source on **Windows** and **Linux**. This is a
super-repository, so the first step is always to check out the submodules:

```sh
git clone https://github.com/Euro-Office/DesktopEditors.git
cd DesktopEditors
git submodule update --init --recursive
```

Then head to the build docs:

* **[build/](./build/README.md)** — start here for the overall build model (the
  shared CMake definition, the common editors payload, vcpkg, and caching).
* **[build/windows/](./build/windows/README.md)** — the Windows build (`build.ps1`, MSVC + CMake).
* **[build/linux/](./build/linux/README.md)** — the Linux build (Docker / `docker buildx bake`).

## Get involved 🤝

Contributions are welcome! Whether it's a bug report, a feature idea, a
translation, or a pull request, here's how to take part:

* **Found a bug or have an idea?** Open an [issue](https://github.com/Euro-Office/DesktopEditors/issues)
  and describe what you ran into or what you'd like to see.
* **Want to contribute code?** Fork the relevant [component](#components-) repo,
  make your change, and open a pull request. For build changes, see the
  [build docs](./build/README.md) above.
* **Want to help translate?** Localization improvements are always appreciated —
  see 
  the editors' interface translations.

Please keep contributions compatible with the project's AGPL v3 license.

## License 📄

Desktop Editors is licensed under the GNU Affero Public License, version 3.0, ensuring its transparency and commitment to the open-source community.

  [1]: https://github.com/Euro-Office/DocumentServer