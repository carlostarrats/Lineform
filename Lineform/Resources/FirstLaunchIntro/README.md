# Lineform Intro WebGL Prototype

Static browser prototype for the first-launch Lineform wordmark animation.

Run it from the repo root:

```sh
python3 -m http.server 4173 --directory docs/prototypes/lineform-intro-webgl
```

Then open:

```text
http://localhost:4173/
```

Optional prototype controls:

- `?tune=1` shows the shader tuning panel.
- `?dim=1` starts with the darker background pass.
- `?parallax=1` enables the pointer-following depth pass.
- Press `T` while the prototype is focused to show or hide tuning controls.
- Press `P` while focused to toggle pointer parallax.

The prototype keeps the logo vector-sharp in the DOM and uses WebGL as a glass/effect layer for chromatic dispersion, refraction bands, highlights, and the write-on reveal. The shader is intentionally small enough to map to a Swift/Metal fragment shader later.
