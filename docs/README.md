# Social preview

[`social-preview.png`](social-preview.png) is the GitHub social preview image: 1280 × 640 pixels, with an opaque background. The editable source is [`social-preview.svg`](social-preview.svg), which uses the existing [`icon.png`](icon.png).

To apply it, open [the repository settings](https://github.com/timdeschryver/Libellule/settings), then under **Social preview**, choose **Edit → Upload an image…** and select `docs/social-preview.png`. Adding the file to the repository does not activate the preview; GitHub requires a separate upload in settings. See [GitHub's documentation](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/customizing-your-repositorys-social-media-preview).

To regenerate the PNG on macOS, run this from the repository root with Google Chrome installed:

```sh
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --no-first-run --no-default-browser-check \
  --user-data-dir="$(mktemp -d "${TMPDIR:-/tmp}/libellule-social-preview.XXXXXX")" \
  --hide-scrollbars --force-device-scale-factor=1 --window-size=1280,640 \
  --screenshot="$PWD/docs/social-preview.png" \
  "file://$PWD/docs/social-preview.svg"
```
