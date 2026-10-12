# Whalebridge

## Releasing

A release isn't finished until the Homebrew cask points at it. Always confirm
that as part of every release — it has been forgotten more than once.

1. Roll the `[Unreleased]` section of `CHANGELOG.md` into a `[X.Y.Z]` section
   (and update the compare links at the bottom) on `main`.
2. Tag `vX.Y.Z` on `main` and push the tag. That triggers
   `.github/workflows/release.yml`, which publishes `Whalebridge-X.Y.Z.zip`
   and `appcast.xml` to a GitHub Release, then updates `version` and `sha256`
   in `Casks/whalebridge.rb` in
   [`cap10morgan/homebrew-brew`](https://github.com/cap10morgan/homebrew-brew).
3. Once the workflow has finished, check that the cask actually moved. The
   cask step needs the `HOMEBREW_TAP_TOKEN` repository secret; without it the
   step is skipped with a warning on the run. If the cask wasn't updated, do
   it by hand: set `version` to `X.Y.Z` and `sha256` to the SHA-256 of the
   published `Whalebridge-X.Y.Z.zip` (download the release asset and hash it
   — a local build won't match).
