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

The prototype keeps the logo vector-sharp in the DOM and uses WebGL as a glass/effect layer for chromatic dispersion, refraction bands, highlights, and the write-on reveal. The shader is intentionally small enough to map to a Swift/Metal fragment shader later.
