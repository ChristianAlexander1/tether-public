# Releases

## Before archiving

1. Run `./scripts/validate.sh --all`.
2. Complete and date `DEVICE-PASS.md` on a supported iPhone and iPad size.
3. Verify a real account login, browser return/paste flow, workspace edit and
   Git operation.
4. Confirm framework versions, licenses and notices match the archive.
5. Confirm the Alpine rootfs URL/checksum and offline bootstrap behavior.
6. Review privacy strings, document access, network use, export compliance and
   App Store review notes against the current binary.

## Version source

The app target’s Xcode build settings are the release source of truth. Do not
invent a second version in documentation. Tag releases only after the archived
binary and validation record refer to the same version/build.

## Release evidence

Store the Xcode archive/build log, aggregate validation output, device checklist
and dependency-notice audit with the release record. Do not mark a gate passed
from an older simulator container or a handoff document.
