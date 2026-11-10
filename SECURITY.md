# Security

## Reporting a problem

Please do not open a public issue for a security problem. Report it privately:
[open a private report](https://github.com/kddige/diskmap/security/advisories/new)
(Security tab > Report a vulnerability). Say what you did, what happened and
which version of DiskMap and macOS you were on.

This is a one-person project, so an answer can take a few days. Once a fix is
released the report is published, with credit to you unless you ask otherwise.

## What counts

DiskMap reads file names and sizes, usually with Full Disk Access, and can move
files to the Trash. Anything that makes it do more than that is in scope, for
example:

- a file or folder name that makes DiskMap run code, crash, or act on a
  different file than the one shown;
- anything moved to the Trash or changed without the confirmation alert;
- the installer (`install.sh`) or a release download being made to install
  something other than the published build.

## Supported versions

Only the latest release gets fixes. Update with the install command in the
README.

## Checking a download

Each release has a `DiskMap.zip.sha256` next to `DiskMap.zip`; `install.sh`
checks it before installing. The app is signed ad hoc and is not notarized by
Apple, so the checksum and this repository are the only proof of where a
build came from.
