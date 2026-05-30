const canvas = document.getElementById("glass-canvas");
const shell = document.querySelector(".intro-shell");
const wordmarkWrap = document.querySelector(".wordmark-wrap");
const startButton = document.querySelector(".start-button");
const replayButton = document.getElementById("replay");
const controls = {
  dispersion: document.getElementById("dispersion"),
  refraction: document.getElementById("refraction"),
  glass: document.getElementById("glass"),
  brightness: document.getElementById("brightness"),
  taglineX: document.getElementById("taglineX"),
  taglineY: document.getElementById("taglineY")
};
const controlOutputs = Object.fromEntries(
  Object.entries(controls).map(([name, input]) => [name, document.querySelector(`output[for="${input.id}"]`)])
);

const gl = canvas.getContext("webgl", {
  alpha: true,
  antialias: true,
  premultipliedAlpha: false
});

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const params = new URLSearchParams(window.location.search);
let parallaxEnabled = params.get("parallax") === "1";
let startTime = performance.now();
let reveal = reducedMotion ? 1 : 0;
let logoTexture = null;
let logoReady = false;

const vertexSource = `
attribute vec2 a_position;
varying vec2 v_uv;

void main() {
  v_uv = a_position * 0.5 + 0.5;
  gl_Position = vec4(a_position, 0.0, 1.0);
}
`;

const fragmentSource = `
precision highp float;

uniform sampler2D u_logo;
uniform vec2 u_resolution;
uniform vec4 u_logoRect;
uniform float u_time;
uniform float u_reveal;
uniform float u_dispersion;
uniform float u_refraction;
uniform float u_glass;

varying vec2 v_uv;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(hash(i + vec2(0.0, 0.0)), hash(i + vec2(1.0, 0.0)), u.x),
    mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
    u.y
  );
}

float logoAlpha(vec2 logoUV) {
  if (logoUV.x < 0.0 || logoUV.x > 1.0 || logoUV.y < 0.0 || logoUV.y > 1.0) {
    return 0.0;
  }
  return texture2D(u_logo, logoUV).a;
}

float progressiveLogoBlur(vec2 logoUV, vec2 texel, float radius) {
  float a = logoAlpha(logoUV) * 0.18;
  a += logoAlpha(logoUV + texel * radius * vec2(1.0, 0.0)) * 0.07;
  a += logoAlpha(logoUV + texel * radius * vec2(-1.0, 0.0)) * 0.07;
  a += logoAlpha(logoUV + texel * radius * vec2(0.0, 1.0)) * 0.07;
  a += logoAlpha(logoUV + texel * radius * vec2(0.0, -1.0)) * 0.07;
  a += logoAlpha(logoUV + texel * radius * vec2(0.72, 0.72)) * 0.065;
  a += logoAlpha(logoUV + texel * radius * vec2(-0.72, 0.72)) * 0.065;
  a += logoAlpha(logoUV + texel * radius * vec2(0.72, -0.72)) * 0.065;
  a += logoAlpha(logoUV + texel * radius * vec2(-0.72, -0.72)) * 0.065;
  a += logoAlpha(logoUV + texel * radius * vec2(1.45, 0.36)) * 0.045;
  a += logoAlpha(logoUV + texel * radius * vec2(-1.45, 0.36)) * 0.045;
  a += logoAlpha(logoUV + texel * radius * vec2(1.45, -0.36)) * 0.045;
  a += logoAlpha(logoUV + texel * radius * vec2(-1.45, -0.36)) * 0.045;
  a += logoAlpha(logoUV + texel * radius * vec2(0.36, 1.45)) * 0.045;
  a += logoAlpha(logoUV + texel * radius * vec2(-0.36, 1.45)) * 0.045;
  a += logoAlpha(logoUV + texel * radius * vec2(0.36, -1.45)) * 0.045;
  a += logoAlpha(logoUV + texel * radius * vec2(-0.36, -1.45)) * 0.045;
  return a;
}

float band(vec2 p, vec2 center, float angle, float length, float width) {
  float s = sin(angle);
  float c = cos(angle);
  mat2 r = mat2(c, -s, s, c);
  vec2 q = r * (p - center);
  float body = smoothstep(length, length * 0.76, abs(q.x));
  float cross = smoothstep(width, width * 0.45, abs(q.y));
  return body * cross;
}

void main() {
  vec2 frag = v_uv * u_resolution;
  vec2 logoUV = (frag - u_logoRect.xy) / u_logoRect.zw;
  logoUV.y = 1.0 - logoUV.y;

  float writtenNoise = noise(vec2(logoUV.x * 5.0 - u_time * 0.24, logoUV.y * 3.0));
  float revealEdge = smoothstep(-0.12, 0.04, u_reveal - logoUV.x + (writtenNoise - 0.5) * 0.06);
  float revealGlow = smoothstep(0.07, -0.02, abs(u_reveal - logoUV.x));
  float revealMask = clamp(revealEdge, 0.0, 1.0);

  vec2 p = v_uv;
  float glassA = band(p, vec2(0.38, 0.535), -0.115, 0.62, 0.052);
  float glassB = band(p, vec2(0.64, 0.485), 0.082, 0.56, 0.039);
  float glassC = band(p, vec2(0.51, 0.41), -0.028, 0.48, 0.028);
  float glassMask = clamp(glassA + glassB * 0.92 + glassC * 0.66, 0.0, 1.0) * u_glass;

  float wave = noise(p * vec2(9.0, 4.0) + vec2(u_time * 0.08, -u_time * 0.04));
  vec2 direction = normalize(vec2(
    sin((p.y + wave) * 18.0 + u_time * 0.5),
    cos((p.x - wave) * 15.0 - u_time * 0.35)
  ));

  vec2 texel = vec2(1.0 / u_logoRect.z, 1.0 / u_logoRect.w);
  float center = logoAlpha(logoUV);
  float gx = logoAlpha(logoUV + vec2(texel.x * 3.0, 0.0)) - logoAlpha(logoUV - vec2(texel.x * 3.0, 0.0));
  float gy = logoAlpha(logoUV + vec2(0.0, texel.y * 3.0)) - logoAlpha(logoUV - vec2(0.0, texel.y * 3.0));
  float edge = smoothstep(0.02, 0.38, abs(gx) + abs(gy));

  float radial = length(logoUV - vec2(0.5, 0.5));
  vec2 lensPull = normalize((logoUV - vec2(0.5, 0.52)) + direction * 0.14);
  vec2 refractOffset = (direction * 0.54 + lensPull * radial) * texel * (12.0 + 55.0 * glassMask) * u_refraction;
  vec2 edgeOffset = normalize(vec2(gx, gy) + direction * 0.2) * texel * (10.0 + 34.0 * glassMask);
  vec2 chromaOffset = (refractOffset + edgeOffset) * u_dispersion;

  float red = logoAlpha(logoUV + chromaOffset * 1.25) * revealMask;
  float green = logoAlpha(logoUV + refractOffset * 0.32) * revealMask;
  float blue = logoAlpha(logoUV - chromaOffset * 1.35) * revealMask;
  float ghost = logoAlpha(logoUV + refractOffset * 0.7) * revealMask;
  float smear = 0.0;
  smear += logoAlpha(logoUV + refractOffset * 1.05) * 0.34;
  smear += logoAlpha(logoUV - refractOffset * 0.8) * 0.24;
  smear += logoAlpha(logoUV + direction * texel * 32.0 * glassMask) * 0.18;
  smear *= revealMask * glassMask;

  float halo = 0.0;
  halo += logoAlpha(logoUV + texel * vec2(7.0, 3.0)) * 0.28;
  halo += logoAlpha(logoUV + texel * vec2(-8.0, -2.0)) * 0.26;
  halo += logoAlpha(logoUV + texel * vec2(3.0, -8.0)) * 0.22;
  halo *= revealMask;

  vec3 chroma = vec3(red * 1.02 + halo * 0.22, green * 0.82 + halo * 0.06, blue * 1.04 + halo * 0.22);
  float chromaStrength = clamp((abs(red - blue) + edge * 0.54 + glassMask * center * 0.5) * 0.54, 0.0, 1.0);

  vec3 color = vec3(0.0);
  color = mix(color, vec3(0.0), ghost * 0.28);
  color += chroma * chromaStrength;

  float caustic = pow(max(0.0, sin((p.x * 1.7 + p.y * 0.8) * 24.0 - 0.9)), 22.0) * glassMask * center * 0.08;
  float writeSpark = revealGlow * center * (0.18 + 0.16 * noise(p * 80.0 + u_time));

  color += vec3(0.10, 0.75, 1.0) * caustic * 0.18;
  color += vec3(1.0, 0.04, 0.38) * caustic * 0.14;
  color += vec3(0.0) * smear * 0.56;
  color += vec3(0.08, 0.62, 1.0) * smear * 0.12;
  color += vec3(1.0, 0.02, 0.34) * smear * 0.1;
  color += vec3(0.18, 0.68, 1.0) * writeSpark * 0.24;
  color += vec3(1.0, 0.72, 0.10) * writeSpark * 0.16;

  vec2 fLensUV = (logoUV - vec2(0.70, 0.53)) / vec2(0.15, 0.38);
  float fLensDistance = length(fLensUV);
  float fLens = 1.0 - smoothstep(0.58, 1.08, fLensDistance);
  float fLensCore = 1.0 - smoothstep(0.26, 0.7, fLensDistance);
  float blurRadius = mix(1.4, 7.2, fLensCore);
  float blurredAlpha = progressiveLogoBlur(logoUV, texel, blurRadius);
  float strokeEdge = smoothstep(0.06, 0.5, edge);
  float coreInk = center * (0.72 + strokeEdge * 0.18);
  float edgeInk = blurredAlpha * (0.46 + strokeEdge * 0.5);
  float treatedInk = max(coreInk, edgeInk) * revealMask * fLens;
  float treatedEdgeColor = strokeEdge * fLens;
  color *= 1.0 - treatedEdgeColor * 0.36;
  color = mix(color, vec3(0.0), clamp(treatedInk * 0.96, 0.0, 1.0));

  float alpha = clamp(
    chromaStrength * 0.42 +
    ghost * 0.12 +
    smear * 0.36 +
    halo * 0.2 +
    caustic * 0.52 +
    writeSpark +
    treatedInk * 0.92,
    0.0,
    0.92
  );

  gl_FragColor = vec4(color, alpha);
}
`;

function compileShader(type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(shader));
  }
  return shader;
}

function makeProgram() {
  const program = gl.createProgram();
  gl.attachShader(program, compileShader(gl.VERTEX_SHADER, vertexSource));
  gl.attachShader(program, compileShader(gl.FRAGMENT_SHADER, fragmentSource));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(program));
  }
  return program;
}

let program = null;
let locations = null;

if (gl) {
  try {
    program = makeProgram();
    locations = {
      position: gl.getAttribLocation(program, "a_position"),
      resolution: gl.getUniformLocation(program, "u_resolution"),
      logoRect: gl.getUniformLocation(program, "u_logoRect"),
      time: gl.getUniformLocation(program, "u_time"),
      reveal: gl.getUniformLocation(program, "u_reveal"),
      dispersion: gl.getUniformLocation(program, "u_dispersion"),
      refraction: gl.getUniformLocation(program, "u_refraction"),
      glass: gl.getUniformLocation(program, "u_glass")
    };
  } catch (error) {
    console.warn("Lineform intro WebGL disabled:", error);
  }
}

if (gl && program) {
  const quad = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, quad);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([
    -1, -1,
     1, -1,
    -1,  1,
     1,  1
  ]), gl.STATIC_DRAW);
  gl.useProgram(program);
  gl.enableVertexAttribArray(locations.position);
  gl.vertexAttribPointer(locations.position, 2, gl.FLOAT, false, 0, 0);
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
}

function createLogoTexture() {
  if (!gl) {
    return;
  }

  const image = new Image();
  image.onload = () => {
    logoTexture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, logoTexture);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, image);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    logoReady = true;
  };
  image.src = "./assets/Lineform.svg";
}

function resize() {
  if (!gl) {
    return;
  }

  const scale = Math.min(window.devicePixelRatio || 1, 2);
  const width = Math.floor(canvas.clientWidth * scale);
  const height = Math.floor(canvas.clientHeight * scale);
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
    gl.viewport(0, 0, width, height);
  }
}

function logoRect() {
  const canvasBox = canvas.getBoundingClientRect();
  const wordmarkBox = wordmarkWrap.getBoundingClientRect();
  const scaleX = canvas.width / canvasBox.width;
  const scaleY = canvas.height / canvasBox.height;

  return [
    (wordmarkBox.left - canvasBox.left) * scaleX,
    canvas.height - (wordmarkBox.bottom - canvasBox.top) * scaleY,
    wordmarkBox.width * scaleX,
    wordmarkBox.height * scaleY
  ];
}

function animate(now) {
  resize();
  const elapsed = (now - startTime) / 1000;
  if (reducedMotion) {
    reveal = 1;
  } else {
    const duration = 2.65;
    const targetReveal = Math.min(1, elapsed / duration);
    reveal += (targetReveal - reveal) * 0.075;
    if (targetReveal >= 1) {
      reveal = Math.min(1, reveal + 0.012);
    }
  }

  document.documentElement.style.setProperty("--reveal", reveal.toFixed(4));
  if (reveal > 0.985) {
    shell.classList.add("is-complete");
  }

  if (logoReady) {
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.useProgram(program);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, logoTexture);
    gl.uniform2f(locations.resolution, canvas.width, canvas.height);
    gl.uniform4fv(locations.logoRect, logoRect());
    gl.uniform1f(locations.time, elapsed);
    gl.uniform1f(locations.reveal, reveal);
    gl.uniform1f(locations.dispersion, Number(controls.dispersion.value));
    gl.uniform1f(locations.refraction, Number(controls.refraction.value));
    gl.uniform1f(locations.glass, Number(controls.glass.value));
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  requestAnimationFrame(animate);
}

function replay() {
  startTime = performance.now();
  reveal = reducedMotion ? 1 : 0;
  shell.classList.remove("is-complete", "is-exiting");
  startButton.removeAttribute("aria-disabled");
  shell.getAnimations().forEach(animation => animation.cancel());
}

function setBackgroundBrightness(value) {
  const brightness = Math.max(0, Math.min(1, Number(value) || 0));
  controls.brightness.value = String(brightness);
  updateControlValue("brightness");
  document.documentElement.style.setProperty("--bg-dim", brightness.toFixed(2));
}

function updateControlValue(name) {
  const decimals = name === "taglineX" || name === "taglineY" ? 1 : 2;
  controlOutputs[name].value = Number(controls[name].value).toFixed(decimals);
}

function updateAllControlValues() {
  Object.keys(controls).forEach(updateControlValue);
}

function setTaglinePosition() {
  document.documentElement.style.setProperty("--tagline-x", `${controls.taglineX.value}%`);
  document.documentElement.style.setProperty("--tagline-y", `${controls.taglineY.value}%`);
  updateControlValue("taglineX");
  updateControlValue("taglineY");
}

function setTuningVisible(visible) {
  const panel = replayButton.closest(".tuning-panel");
  panel.hidden = !visible;
}

function resetPointerPosition() {
  document.documentElement.style.setProperty("--pointer-x", "0");
  document.documentElement.style.setProperty("--pointer-y", "0");
}

function setPointerPosition(event) {
  if (reducedMotion || !parallaxEnabled) {
    return;
  }

  const bounds = shell.getBoundingClientRect();
  const x = ((event.clientX - bounds.left) / bounds.width - 0.5) * 2;
  const y = ((event.clientY - bounds.top) / bounds.height - 0.5) * 2;
  document.documentElement.style.setProperty("--pointer-x", x.toFixed(3));
  document.documentElement.style.setProperty("--pointer-y", y.toFixed(3));
}

replayButton.addEventListener("click", replay);
Object.entries(controls).forEach(([name, input]) => {
  input.addEventListener("input", () => updateControlValue(name));
});
controls.brightness.addEventListener("input", event => setBackgroundBrightness(event.target.value));
controls.taglineX.addEventListener("input", setTaglinePosition);
controls.taglineY.addEventListener("input", setTaglinePosition);
startButton.addEventListener("click", () => {
  shell.classList.add("is-exiting");
  startButton.setAttribute("aria-disabled", "true");
  shell.animate(
    [
      { opacity: 1, filter: "blur(0px)" },
      { opacity: 0, filter: "blur(12px)" }
    ],
    { duration: 520, easing: "cubic-bezier(.2,.8,.2,1)", fill: "forwards" }
  );
});
shell.addEventListener("pointermove", setPointerPosition);
shell.addEventListener("pointerleave", resetPointerPosition);
window.addEventListener("keydown", event => {
  if (event.key.toLowerCase() === "t") {
    const panel = replayButton.closest(".tuning-panel");
    setTuningVisible(panel.hidden);
  }
  if (event.key.toLowerCase() === "p") {
    parallaxEnabled = !parallaxEnabled;
    resetPointerPosition();
  }
});

setBackgroundBrightness(params.get("dim") === "1" ? 1 : 0);
setTaglinePosition();
updateAllControlValues();
setTuningVisible(params.get("tune") === "1");

if (gl && program) {
  createLogoTexture();
  requestAnimationFrame(animate);
} else {
  shell.classList.add("is-complete");
  document.documentElement.style.setProperty("--reveal", "1");
}
