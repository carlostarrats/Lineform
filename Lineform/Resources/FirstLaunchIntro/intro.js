const canvas = document.getElementById("glass-canvas");
const shell = document.querySelector(".intro-shell");
const wordmarkWrap = document.querySelector(".wordmark-wrap");
const writeStrokes = Array.from(document.querySelectorAll(".write-stroke"));
const startButton = document.querySelector(".start-button");
const replayButton = document.getElementById("replay");
const controls = {
  dispersion: document.getElementById("dispersion"),
  refraction: document.getElementById("refraction"),
  glass: document.getElementById("glass"),
  brightness: document.getElementById("brightness"),
  taglineX: document.getElementById("taglineX"),
  taglineY: document.getElementById("taglineY"),
  writeTime: document.getElementById("writeTime"),
  finalDelay: document.getElementById("finalDelay"),
  finalFade: document.getElementById("finalFade"),
  effectFade: document.getElementById("effectFade")
};
const controlOutputs = Object.fromEntries(
  Object.entries(controls).map(([name, input]) => [name, document.querySelector(`output[for="${input.id}"]`)])
);

const gl = canvas.getContext("webgl", {
  alpha: true,
  antialias: true,
  premultipliedAlpha: false
});
const logoTextureSource = "data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iNjM5IiBoZWlnaHQ9IjI1NSIgdmlld0JveD0iMCAwIDYzOSAyNTUiIGZpbGw9Im5vbmUiIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+CjxwYXRoIGQ9Ik01NDcuOTI4IDE1OC4zNEM1NDIuMTA0IDE2Mi40NjUgNTM1Ljk3NyAxNjYuNTMgNTI5LjU0NiAxNzAuNTM0TDUyOSAxNjcuOTg2TDU0Ni4yOSAxNTUuOTc0QzU1Mi4yMzUgMTUxLjcyNyA1NTYuNzg1IDE0OS42MDQgNTU5Ljk0IDE0OS42MDRDNTYzLjA5NSAxNDkuNjA0IDU2NC42NzIgMTUwLjkzOSA1NjQuNjcyIDE1My42MDhDNTY0LjY3MiAxNTcuNjEyIDU2MS44ODEgMTYyLjQwNSA1NTYuMyAxNjcuOTg2TDU1OS4zOTQgMTY2LjE2NkM1NzYuMDE3IDE1NS4zNjcgNTg2LjM5MSAxNDkuOTY4IDU5MC41MTYgMTQ5Ljk2OEM1OTQuNjQxIDE0OS45NjggNTk2LjcwNCAxNTEuMDYgNTk2LjcwNCAxNTMuMjQ0QzU5Ni43MDQgMTU1LjY3MSA1OTQuNzYzIDE1OS40OTMgNTkwLjg4IDE2NC43MUM2MDQuNzEyIDE1NS4xMjUgNjE1LjgxNCAxNTAuMzMyIDYyNC4xODYgMTUwLjMzMkM2MjcuNDYyIDE1MC4zMzIgNjI5LjEgMTUxLjcyNyA2MjkuMSAxNTQuNTE4QzYyOS4xIDE1Ny4zMDkgNjI3Ljg4NyAxNjAuMjIxIDYyNS40NiAxNjMuMjU0QzYyMy4wMzMgMTY2LjE2NiA2MjAuMzY0IDE2OC43MTQgNjE3LjQ1MiAxNzAuODk4QzYwOS42ODcgMTc2LjQ3OSA2MDUuODA0IDE3OS45OTggNjA1LjgwNCAxODEuNDU0QzYwNS44MDQgMTgyLjMwMyA2MDYuNDcxIDE4Mi43MjggNjA3LjgwNiAxODIuNzI4QzYwOS4yNjIgMTgyLjcyOCA2MTEuNjI4IDE4MiA2MTQuOTA0IDE4MC41NDRDNjE4LjE4IDE3OS4wODggNjIxLjA5MiAxNzcuNjMyIDYyMy42NCAxNzYuMTc2QzYyNi4xODggMTc0LjU5OSA2MjkuMjIxIDE3Mi43MTggNjMyLjc0IDE3MC41MzRDNjM2LjM4IDE2OC4yMjkgNjM4LjMyMSAxNjcuMDE1IDYzOC41NjQgMTY2Ljg5NEw2MzguOTI4IDE2OS42MjRDNjIyLjU0OCAxODAuNTQ0IDYxMS4wODIgMTg2LjAwNCA2MDQuNTMgMTg2LjAwNEM2MDEuMzc1IDE4Ni4wMDQgNTk5Ljc5OCAxODQuNDg3IDU5OS43OTggMTgxLjQ1NEM1OTkuNzk4IDE3OS4zOTEgNjAxLjA3MiAxNzYuOTY1IDYwMy42MiAxNzQuMTc0QzYwNi4yODkgMTcxLjI2MiA2MDkuMTQxIDE2OC41OTMgNjEyLjE3NCAxNjYuMTY2QzYyMC41NDYgMTU5Ljg1NyA2MjQuNzMyIDE1NS42NzEgNjI0LjczMiAxNTMuNjA4QzYyNC43MzIgMTUzLjAwMSA2MjQuMDY1IDE1Mi42OTggNjIyLjczIDE1Mi42OThDNjE4LjI0MSAxNTIuNjk4IDYxMS41NjcgMTU1LjEyNSA2MDIuNzEgMTU5Ljk3OEM1OTMuODUzIDE2NC44MzEgNTg0LjAyNSAxNzIuNzE4IDU3My4yMjYgMTgzLjYzOEM1NzIuNDk4IDE4NC4zNjYgNTcwLjkyMSAxODQuNzMgNTY4LjQ5NCAxODQuNzNDNTY2LjE4OSAxODQuNzMgNTY1LjAzNiAxODQuMTg0IDU2NS4wMzYgMTgzLjA5MkM1NjUuMDM2IDE4Mi42MDcgNTY3LjE1OSAxODAuMzYyIDU3MS40MDYgMTc2LjM1OEM1ODQuMzg5IDE2NC4xMDMgNTkwLjg4IDE1Ni42NDEgNTkwLjg4IDE1My45NzJDNTkwLjg4IDE1My4yNDQgNTkwLjQ1NSAxNTIuODggNTg5LjYwNiAxNTIuODhDNTg2LjgxNSAxNTIuODggNTgwLjY4OCAxNTUuOTc0IDU3MS4yMjQgMTYyLjE2MkM1NjEuODgxIDE2OC4yMjkgNTUyLjI5NiAxNzUuMzI3IDU0Mi40NjggMTgzLjQ1NkM1NDEuMDEyIDE4NC4zMDUgNTM5Ljg1OSAxODQuNzMgNTM5LjAxIDE4NC43M0M1MzUuMjQ5IDE4NC43MyA1MzMuMzY4IDE4NC4zMDUgNTMzLjM2OCAxODMuNDU2QzUzMy4zNjggMTgyLjk3MSA1MzUuMDA2IDE4MS4yNzIgNTM4LjI4MiAxNzguMzZDNTQxLjY3OSAxNzUuNDQ4IDU0Ni4xNjkgMTcxLjA4IDU1MS43NSAxNjUuMjU2QzU1Ny40NTMgMTU5LjMxMSA1NjAuMzA0IDE1NS4xODUgNTYwLjMwNCAxNTIuODhDNTYwLjMwNCAxNTIuMzk1IDU2MC4wMDEgMTUyLjE1MiA1NTkuMzk0IDE1Mi4xNTJDNTU3LjIxIDE1Mi4xNTIgNTUzLjM4OCAxNTQuMjE1IDU0Ny45MjggMTU4LjM0WiIgZmlsbD0iYmxhY2siLz4KPHBhdGggZD0iTTQ5OC44NjYgMTU1LjYxTDUwNy40MiAxNTQuNTE4QzUwOC44NzYgMTU0LjUxOCA1MTAuMDI5IDE1NS4wMDMgNTEwLjg3OCAxNTUuOTc0QzUxMS43MjggMTU2Ljk0NSA1MTIuMTUyIDE1OC4wOTcgNTEyLjE1MiAxNTkuNDMyQzUxMi4xNTIgMTYyLjEwMSA1MTAuMjcyIDE2NS4wMTMgNTA2LjUxIDE2OC4xNjhDNTAyLjc0OSAxNzEuMzIzIDQ5OC45ODggMTc0LjI5NSA0OTUuMjI2IDE3Ny4wODZDNDkxLjU4NiAxNzkuODc3IDQ4OS43NjYgMTgyLjEyMSA0ODkuNzY2IDE4My44MkM0ODkuNzY2IDE4NC43OTEgNDkwLjU1NSAxODUuMjc2IDQ5Mi4xMzIgMTg1LjI3NkM0OTcuMzUgMTg1LjI3NiA1MDUuMjk3IDE4Mi4yNDMgNTE1Ljk3NCAxNzYuMTc2QzUyMC41ODUgMTczLjYyOCA1MjUuNDk5IDE3MC41MzQgNTMwLjcxNiAxNjYuODk0TDUzMS4wOCAxNjkuNjI0QzUyNi45NTUgMTcyLjI5MyA1MjIuMzQ0IDE3NS4wMjMgNTE3LjI0OCAxNzcuODE0QzUxNC4zMzYgMTc5LjYzNCA1MTAuMDkgMTgxLjY5NyA1MDQuNTA4IDE4NC4wMDJDNDk4LjkyNyAxODYuNDI5IDQ5NC4zMTYgMTg3LjY0MiA0OTAuNjc2IDE4Ny42NDJDNDg3LjAzNiAxODcuNjQyIDQ4NS4yMTYgMTg2LjAwNCA0ODUuMjE2IDE4Mi43MjhDNDg1LjIxNiAxNzguOTY3IDQ4Ny4xNTggMTc1LjQ0OCA0OTEuMDQgMTcyLjE3MkM0OTQuOTIzIDE2OC43NzUgNDk4Ljc0NSAxNjUuOTg0IDUwMi41MDYgMTYzLjhDNTA2LjM4OSAxNjEuNDk1IDUwOC4zMyAxNTkuNzM1IDUwOC4zMyAxNTguNTIyQzUwOC4zMyAxNTguMTU4IDUwNy45MDYgMTU3Ljk3NiA1MDcuMDU2IDE1Ny45NzZMNDk2Ljg2NCAxNTguODg2QzQ5NC45MjMgMTU4Ljg4NiA0OTMuMTY0IDE1OC43MDQgNDkxLjU4NiAxNTguMzRDNDg1Ljc2MiAxNjIuNDY1IDQ3OS42MzUgMTY2LjUzIDQ3My4yMDQgMTcwLjUzNEw0NzIuNjU4IDE2Ny45ODZMNDg5Ljk0OCAxNTUuOTc0QzQ5MC4wNyAxNTMuNjY5IDQ5MS41MjYgMTUxLjM2MyA0OTQuMzE2IDE0OS4wNThDNDk3LjEwNyAxNDYuNzUzIDQ5OS40NzMgMTQ1LjYgNTAxLjQxNCAxNDUuNkM1MDMuMzU2IDE0NS42IDUwNC4zMjYgMTQ2LjE0NiA1MDQuMzI2IDE0Ny4yMzhDNTA0LjMyNiAxNDguMjA5IDUwMy4xNzQgMTQ5LjQ4MyA1MDAuODY4IDE1MS4wNkM0OTguNTYzIDE1Mi42MzcgNDk3LjQxIDE1My43OSA0OTcuNDEgMTU0LjUxOEM0OTcuNDEgMTU1LjI0NiA0OTcuODk2IDE1NS42MSA0OTguODY2IDE1NS42MVoiIGZpbGw9ImJsYWNrIi8+CjxwYXRoIGQ9Ik00MjEuNjExIDE4Mi45MUM0MzAuMzQ3IDE4Mi45MSA0MzguODQgMTc4LjU0MiA0NDcuMDkxIDE2OS44MDZWMTY5LjYyNEM0NDcuMDkxIDE2My44IDQ0OS44ODIgMTU4LjM0IDQ1NS40NjMgMTUzLjI0NEM0NTUuMDk5IDE1MS45MSA0NTQuMDY4IDE1MS4yNDIgNDUyLjM2OSAxNTEuMjQyQzQ0My4zOSAxNTEuMjQyIDQzNS40NDMgMTU0LjY0IDQyOC41MjcgMTYxLjQzNEM0MjEuNjExIDE2OC4xMDggNDE4LjE1MyAxNzMuOTkyIDQxOC4xNTMgMTc5LjA4OEM0MTguMTUzIDE4MS42MzYgNDE5LjMwNiAxODIuOTEgNDIxLjYxMSAxODIuOTFaTTQ0OS44MjEgMTQ4LjUxMkM0NTYuMjUyIDE0OC41MTIgNDU5LjQ2NyAxNTAuNjM2IDQ1OS40NjcgMTU0Ljg4MkM0NTkuNDY3IDE1OC41MjIgNDU3LjIyMiAxNjIuODkgNDUyLjczMyAxNjcuOTg2VjE2OS40NDJDNDUyLjczMyAxNzMuNDQ2IDQ1NC40OTIgMTc1LjQ0OCA0NTguMDExIDE3NS40NDhDNDYwLjE5NSAxNzUuNDQ4IDQ2Mi42MjIgMTc0LjUzOCA0NjUuMjkxIDE3Mi43MThMNDc0LjIwOSAxNjYuODk0TDQ3NC41NzMgMTY5LjYyNEw0NjYuMjAxIDE3NC45MDJDNDYyLjMxOCAxNzcuNDUgNDU4LjQ5NiAxNzguNzI0IDQ1NC43MzUgMTc4LjcyNEM0NTEuMDk1IDE3OC43MjQgNDQ4LjY2OCAxNzYuODQ0IDQ0Ny40NTUgMTczLjA4MkM0MzcuNzQ4IDE4MS42OTcgNDI4LjUyNyAxODYuMDA0IDQxOS43OTEgMTg2LjAwNEM0MTQuNTc0IDE4Ni4wMDQgNDExLjk2NSAxODMuNTE3IDQxMS45NjUgMTc4LjU0MkM0MTEuOTY1IDE3Mi4yMzMgNDE1LjY2NiAxNjUuNjgxIDQyMy4wNjcgMTU4Ljg4NkM0MzAuNDY4IDE1MS45NyA0MzkuMzg2IDE0OC41MTIgNDQ5LjgyMSAxNDguNTEyWiIgZmlsbD0iYmxhY2siLz4KPHBhdGggZD0iTTMxNC44NzkgMjUwLjA2OEMzMTQuODc5IDI1MS40MDMgMzE1LjYwNyAyNTIuMDcgMzE3LjA2MyAyNTIuMDdDMzIxLjMxIDI1Mi4wNyAzMjcuNDk3IDI0Ny40NTkgMzM1LjYyNyAyMzguMjM4QzM0My43NTYgMjI5LjAxNyAzNTEuNDYxIDIxOC41MjEgMzU4Ljc0MSAyMDYuNzUyQzM2Ni4wMjEgMTk0Ljk4MyAzNzAuOTM1IDE4NS4yMTUgMzczLjQ4MyAxNzcuNDVDMzczLjExOSAxNzYuOTY1IDM3Mi45MzcgMTc2LjM1OCAzNzIuOTM3IDE3NS42M0MzNTYuMDcxIDE5My41ODcgMzQyLjE3OSAyMDkuNDgyIDMzMS4yNTkgMjIzLjMxNEMzMjAuMzM5IDIzNy4xNDYgMzE0Ljg3OSAyNDYuMDY0IDMxNC44NzkgMjUwLjA2OFpNNDgxLjk1NSA4MS41MzYxQzQ4MS45NTUgODAuNjg2OCA0ODEuMzQ4IDgwLjI2MjEgNDgwLjEzNSA4MC4yNjIxQzQ3NS4xNiA4MC4yNjIxIDQ2My41NzMgODguMzMwOCA0NDUuMzczIDEwNC40NjhDNDI3LjI5NCAxMjAuNDg0IDQwNy4zMzUgMTM5Ljc3NiAzODUuNDk1IDE2Mi4zNDRDNDAzLjY5NSAxNTAuNjk2IDQyNC4zMjIgMTM1LjM0NyA0NDcuMzc1IDExNi4yOThDNDcwLjQyOCA5Ny4yNDg4IDQ4MS45NTUgODUuNjYxNCA0ODEuOTU1IDgxLjUzNjFaTTM3Ny40ODcgMTc0LjkwMkMzNzguMzM2IDE3OC43ODUgMzgxLjE4NyAxODAuNzI2IDM4Ni4wNDEgMTgwLjcyNkMzOTMuMiAxODAuNzI2IDQwMy41MTMgMTc2LjExNSA0MTYuOTgxIDE2Ni44OTRMNDE3LjM0NSAxNjkuNjI0QzQwMy45OTggMTc4LjYwMyAzOTIuOTU3IDE4My4wOTIgMzg0LjIyMSAxODMuMDkyQzM4MC4yMTcgMTgzLjA5MiAzNzcuMjQ0IDE4Mi4xMjEgMzc1LjMwMyAxODAuMThDMzcxLjA1NiAxODkuODg3IDM2NS41MzYgMjAwLjIgMzU4Ljc0MSAyMTEuMTJDMzUxLjk0NiAyMjIuMTYxIDM0NC40MjQgMjMyLjExMSAzMzYuMTczIDI0MC45NjhDMzI3LjgwMSAyNDkuOTQ3IDMyMC43NjQgMjU0LjQzNiAzMTUuMDYxIDI1NC40MzZDMzExLjY2NCAyNTQuNDM2IDMwOS45NjUgMjUyLjk4IDMwOS45NjUgMjUwLjA2OEMzMDkuOTY1IDI0My41MTYgMzE3LjY2OSAyMzAuNjU1IDMzMy4wNzkgMjExLjQ4NEMzNDguNDg4IDE5Mi40MzUgMzY1Ljk2IDE3My4wODIgMzg1LjQ5NSAxNTMuNDI2QzQwNS4xNTEgMTMzLjY0OSA0MjQuNDQzIDExNi4wNTUgNDQzLjM3MSAxMDAuNjQ2QzQ2Mi40MiA4NS4xMTU0IDQ3NS4xIDc3LjM1MDEgNDgxLjQwOSA3Ny4zNTAxQzQ4NC4yIDc3LjM1MDEgNDg1LjU5NSA3OC4yNjAxIDQ4NS41OTUgODAuMDgwMUM0ODUuNTk1IDg0LjIwNTQgNDc4Ljg2MSA5Mi4zMzQ4IDQ2NS4zOTMgMTA0LjQ2OEM0NTIuMDQ2IDExNi42MDEgNDM3LjA2MiAxMjguNzk1IDQyMC40MzkgMTQxLjA1QzQwMy45MzggMTUzLjE4MyAzOTAuMjg3IDE2Mi40MDUgMzc5LjQ4OSAxNjguNzE0TDM3OS4zMDcgMTY4Ljg5NkMzNzkuMDY0IDE2OS45ODggMzc4LjQ1OCAxNzEuOTkgMzc3LjQ4NyAxNzQuOTAyWiIgZmlsbD0iYmxhY2siLz4KPHBhdGggZD0iTTM2OS4wNjQgMTUwLjg3OEMzNjkuMDY0IDE0OS45MDcgMzY4LjA5MyAxNDkuNDIyIDM2Ni4xNTIgMTQ5LjQyMkMzNjQuMjExIDE0OS40MjIgMzYwLjI2NyAxNTEuMzAzIDM1NC4zMjIgMTU1LjA2NEMzNDguMzc3IDE1OC43MDQgMzQzLjM0MSAxNjIuNjQ3IDMzOS4yMTYgMTY2Ljg5NEMzNDcuMzQ1IDE2NS41NTkgMzU0LjMyMiAxNjMuMTMzIDM2MC4xNDYgMTU5LjYxNEMzNjYuMDkxIDE1NS45NzQgMzY5LjA2NCAxNTMuMDYyIDM2OS4wNjQgMTUwLjg3OFpNMzMzLjM5MiAxNzYuNTRDMzMzLjM5MiAxODAuMDU5IDMzNS44MTkgMTgxLjgxOCAzNDAuNjcyIDE4MS44MThDMzQ5Ljg5MyAxODEuODE4IDM2MS4zNTkgMTc2Ljg0MyAzNzUuMDcgMTY2Ljg5NEwzNzUuNDM0IDE2OS42MjRDMzYxLjExNyAxNzkuNjk1IDM0OC44NjIgMTg0LjczIDMzOC42NyAxODQuNzNDMzMxLjM5IDE4NC43MyAzMjcuNzUgMTgxLjY5NyAzMjcuNzUgMTc1LjYzQzMyNy43NSAxNjkuNTYzIDMzMi4yMzkgMTYzLjI1NCAzNDEuMjE4IDE1Ni43MDJDMzUwLjMxOCAxNTAuMTUgMzU5LjY2MSAxNDYuODc0IDM2OS4yNDYgMTQ2Ljg3NEMzNzIuMjc5IDE0Ni44NzQgMzczLjc5NiAxNDcuNzg0IDM3My43OTYgMTQ5LjYwNEMzNzMuNzk2IDE1Mi41MTYgMzcwLjM5OSAxNTYuMDM1IDM2My42MDQgMTYwLjE2QzM1Ni45MzEgMTY0LjE2NCAzNDguMTM0IDE2Ny4xMzcgMzM3LjIxNCAxNjkuMDc4QzMzNC42NjYgMTcxLjk5IDMzMy4zOTIgMTc0LjQ3NyAzMzMuMzkyIDE3Ni41NFoiIGZpbGw9ImJsYWNrIi8+CjxwYXRoIGQ9Ik0yODYuMDk4IDE0OC42OTRDMjg4LjY0NiAxNDguNjk0IDI4OS45MiAxNTAuMDkgMjg5LjkyIDE1Mi44OEMyODkuOTIgMTU1LjU1IDI4Ny45NzkgMTU5LjQ5MyAyODQuMDk2IDE2NC43MUMyOTcuOTI4IDE1NS4xMjUgMzA5LjAzIDE1MC4zMzIgMzE3LjQwMiAxNTAuMzMyQzMyMC42NzggMTUwLjMzMiAzMjIuMzE2IDE1MS43MjggMzIyLjMxNiAxNTQuNTE4QzMyMi4zMTYgMTU3LjMwOSAzMjEuMTAzIDE2MC4yMjEgMzE4LjY3NiAxNjMuMjU0QzMxNi4yNSAxNjYuMTY2IDMxMy41OCAxNjguNzE0IDMxMC42NjggMTcwLjg5OEMzMDIuOTAzIDE3Ni40OCAyOTkuMDIgMTc5Ljk5OCAyOTkuMDIgMTgxLjQ1NEMyOTkuMDIgMTgyLjMwNCAyOTkuNjg4IDE4Mi43MjggMzAxLjAyMiAxODIuNzI4QzMwMi40NzggMTgyLjcyOCAzMDQuODQ0IDE4MiAzMDguMTIgMTgwLjU0NEMzMTEuMzk2IDE3OS4wODggMzE0LjMwOCAxNzcuNjMyIDMxNi44NTYgMTc2LjE3NkMzMTkuNDA0IDE3NC41OTkgMzIyLjQzOCAxNzIuNzE4IDMyNS45NTYgMTcwLjUzNEMzMjkuNTk2IDE2OC4yMjkgMzMxLjUzOCAxNjcuMDE2IDMzMS43OCAxNjYuODk0TDMzMi4xNDQgMTY5LjYyNEMzMTUuNzY0IDE4MC41NDQgMzA0LjI5OCAxODYuMDA0IDI5Ny43NDYgMTg2LjAwNEMyOTQuNTkyIDE4Ni4wMDQgMjkzLjAxNCAxODQuNDg4IDI5My4wMTQgMTgxLjQ1NEMyOTMuMDE0IDE3OS4zOTIgMjk0LjI4OCAxNzYuOTY1IDI5Ni44MzYgMTc0LjE3NEMyOTkuNTA2IDE3MS4yNjIgMzAyLjM1NyAxNjguNTkzIDMwNS4zOSAxNjYuMTY2QzMxMy43NjIgMTU5Ljg1NyAzMTcuOTQ4IDE1NS42NzEgMzE3Ljk0OCAxNTMuNjA4QzMxNy45NDggMTUzLjAwMiAzMTcuMjgxIDE1Mi42OTggMzE1Ljk0NiAxNTIuNjk4QzMxMS40NTcgMTUyLjY5OCAzMDQuNzg0IDE1NS4xMjUgMjk1LjkyNiAxNTkuOTc4QzI4Ny4wNjkgMTY0LjgzMiAyNzcuMjQxIDE3Mi43MTggMjY2LjQ0MiAxODMuNjM4QzI2NS43MTQgMTg0LjM2NiAyNjQuMzE5IDE4NC43MyAyNjIuMjU2IDE4NC43M0MyNjAuMzE1IDE4NC43MyAyNTkuMzQ0IDE4NC4xODQgMjU5LjM0NCAxODMuMDkyQzI1OS4zNDQgMTgyLjcyOCAyNjMuNTMgMTc4LjIzOSAyNzEuOTAyIDE2OS42MjRDMjgwLjI3NCAxNjEuMDEgMjg0LjQ2IDE1NS40MjggMjg0LjQ2IDE1Mi44OEMyODQuNDYgMTUyLjI3NCAyODQuMDM2IDE1MS45NyAyODMuMTg2IDE1MS45N0MyODIuNDU4IDE1MS45NyAyODAuODIgMTUyLjc1OSAyNzguMjcyIDE1NC4zMzZDMjc1Ljg0NiAxNTUuOTE0IDI3Mi4wMjQgMTU4LjQ2MiAyNjYuODA2IDE2MS45OEMyNjEuNzEgMTY1LjM3OCAyNTcuMzQyIDE2OC4yMjkgMjUzLjcwMiAxNzAuNTM0TDI1My4xNTYgMTY3Ljk4NkMyNTQuOTc2IDE2Ni43NzMgMjU3LjQ2NCAxNjUuMDc0IDI2MC42MTggMTYyLjg5QzI2My43NzMgMTYwLjcwNiAyNjYuMzgyIDE1OC45NDcgMjY4LjQ0NCAxNTcuNjEyQzI3MC41MDcgMTU2LjE1NiAyNzIuNzUyIDE1NC42NCAyNzUuMTc4IDE1My4wNjJDMjc5LjkxIDE1MC4xNSAyODMuNTUgMTQ4LjY5NCAyODYuMDk4IDE0OC42OTRaIiBmaWxsPSJibGFjayIvPgo8cGF0aCBkPSJNMjYxLjM1MyAxMzMuNDA2QzI2MS4zNTMgMTM1LjEwNSAyNjAuMzgyIDEzNi43NDMgMjU4LjQ0MSAxMzguMzJDMjU2LjUgMTM5Ljg5OCAyNTQuNjggMTQwLjY4NiAyNTIuOTgxIDE0MC42ODZDMjUxLjQwNCAxNDAuNjg2IDI1MC42MTUgMTQwLjAxOSAyNTAuNjE1IDEzOC42ODRDMjUwLjYxNSAxMzcuMzUgMjUxLjU4NiAxMzUuODMzIDI1My41MjcgMTM0LjEzNEMyNTUuNDY4IDEzMi4zMTQgMjU3LjIyOCAxMzEuNDA0IDI1OC44MDUgMTMxLjQwNEMyNjAuNTA0IDEzMS40MDQgMjYxLjM1MyAxMzIuMDcyIDI2MS4zNTMgMTMzLjQwNlpNMjQ1Ljg4MyAxNTMuMDYyQzIyOS41MDMgMTY3Ljg2NSAyMjEuMzEzIDE3Ny4xNDcgMjIxLjMxMyAxODAuOTA4QzIyMS4zMTMgMTgyLjEyMiAyMjIuMTYyIDE4Mi43MjggMjIzLjg2MSAxODIuNzI4QzIyNS40MzggMTgyLjcyOCAyMjcuODY1IDE4MiAyMzEuMTQxIDE4MC41NDRDMjM0LjQxNyAxNzkuMDg4IDIzNy4zMjkgMTc3LjYzMiAyMzkuODc3IDE3Ni4xNzZDMjQyLjQyNSAxNzQuNTk5IDI0NS40NTggMTcyLjcxOCAyNDguOTc3IDE3MC41MzRDMjUyLjYxNyAxNjguMjI5IDI1NC41NTggMTY3LjAxNiAyNTQuODAxIDE2Ni44OTRMMjU1LjE2NSAxNjkuNjI0QzI0OS41ODQgMTczLjI2NCAyNDMuMjE0IDE3Ni45MDQgMjM2LjA1NSAxODAuNTQ0QzIyOC44OTYgMTg0LjE4NCAyMjMuNDk3IDE4Ni4wMDQgMjE5Ljg1NyAxODYuMDA0QzIxNi4wOTYgMTg2LjAwNCAyMTQuMjE1IDE4NC40ODggMjE0LjIxNSAxODEuNDU0QzIxNC4yMTUgMTc4LjkwNiAyMTYuMzk5IDE3NS4wODQgMjIwLjc2NyAxNjkuOTg4QzIyNS4xMzUgMTY0Ljc3MSAyMjkuNTAzIDE2MC4yMjEgMjMzLjg3MSAxNTYuMzM4TDI0MC40MjMgMTUwLjUxNEMyNDEuMDMgMTUwLjAyOSAyNDIuMTgyIDE0OS44NDcgMjQzLjg4MSAxNDkuOTY4QzI0NS41OCAxNTAuMDkgMjQ2LjQyOSAxNTAuNjk2IDI0Ni40MjkgMTUxLjc4OEMyNDYuNDI5IDE1Mi4yNzQgMjQ2LjI0NyAxNTIuNjk4IDI0NS44ODMgMTUzLjA2MloiIGZpbGw9ImJsYWNrIi8+CjxwYXRoIGQ9Ik0zMi41NzggMTg2LjkxNEM0OC41OTQgMTg2LjkxNCA2NC43OTIgMTgyLjY2NyA4MS4xNzIgMTc0LjE3NEM1MC45NiAxNjUuOTIzIDMyLjMzNTMgMTYxLjc5OCAyNS4yOTggMTYxLjc5OEMxOC4yNjA3IDE2MS43OTggMTMuMTY0NyAxNjIuNzY5IDEwLjAxIDE2NC43MUM2Ljk3NjY3IDE2Ni42NTEgNS40NiAxNjkuMzIxIDUuNDYgMTcyLjcxOEM1LjQ2IDE3NS45OTQgNy44ODY2NyAxNzkuMTQ5IDEyLjc0IDE4Mi4xODJDMTcuNzE0NyAxODUuMzM3IDI0LjMyNzMgMTg2LjkxNCAzMi41NzggMTg2LjkxNFpNMTI3Ljc2NCAxODAuNTQ0QzE0NS4zNTcgMTg0LjMwNSAxNTkuMDA3IDE4Ni4xODYgMTY4LjcxNCAxODYuMTg2QzE3OC41NDIgMTg2LjE4NiAxODYuOTE0IDE4NC42MDkgMTkzLjgzIDE4MS40NTRDMjAwLjc0NiAxNzguMTc4IDIwNC4yMDQgMTc0LjUzOCAyMDQuMjA0IDE3MC41MzRDMjA0LjIwNCAxNjcuNjIyIDIwMi4wODEgMTY1LjE5NSAxOTcuODM0IDE2My4yNTRDMTkzLjU4NyAxNjEuMTkxIDE4Ny4zOTkgMTYwLjE2IDE3OS4yNyAxNjAuMTZDMTY2LjQwOSAxNjAuMTYgMTU1LjYxIDE2Mi4wNDEgMTQ2Ljg3NCAxNjUuODAyQzEzOC4xMzggMTY5LjU2MyAxMzEuNzY4IDE3NC40NzcgMTI3Ljc2NCAxODAuNTQ0Wk0yMTEuODQ4IDYyLjQyNkMyMDMuNTk3IDcwLjA3IDE5My40MDUgODAuNDQ0IDE4MS4yNzIgOTMuNTQ4QzE2OS4yNiAxMDYuNTMxIDE2MC40NjMgMTE1Ljg3MyAxNTQuODgyIDEyMS41NzZDMTU2LjA5NSAxMjEuNjk3IDE1Ny45NzYgMTIxLjc1OCAxNjAuNTI0IDEyMS43NThDMTcwLjQ3MyAxMjEuNzU4IDE4MS4yMTEgMTE5LjIxIDE5Mi43MzggMTE0LjExNEMyMDQuMzg2IDEwOS4wMTggMjE0LjYzOSAxMDIuOTUxIDIyMy40OTYgOTUuOTE0QzIzMi40NzUgODguODc2NyAyMzkuOTM3IDgxLjU5NjcgMjQ1Ljg4MiA3NC4wNzRDMjUxLjk0OSA2Ni40MyAyNTQuOTgyIDYwLjEyMDcgMjU0Ljk4MiA1NS4xNDZDMjU0Ljk4MiA0OS4yMDA3IDI1MC42NzUgNDYuMjI4IDI0Mi4wNiA0Ni4yMjhDMjMzLjQ0NSA0Ni4yMjggMjIzLjM3NSA1MS42MjczIDIxMS44NDggNjIuNDI2Wk0xOTcuNjUyIDM2Ljk0NkMxOTcuNjUyIDI4LjgxNjcgMTkxLjAzOSAyNC43NTIgMTc3LjgxNCAyNC43NTJDMTcwLjUzNCAyNC43NTIgMTYzLjAxMSAyNi41MTEzIDE1NS4yNDYgMzAuMDNDMTQ3LjYwMiAzMy40MjczIDE0MS4wNSAzNy45MTY3IDEzNS41OSA0My40OThDMTMwLjEzIDQ5LjA3OTMgMTI1LjcwMSA1NS4yNjczIDEyMi4zMDQgNjIuMDYyQzExOC45MDcgNjguODU2NyAxMTYuOTA1IDc1LjU5MDcgMTE2LjI5OCA4Mi4yNjRDMTE5LjQ1MyA4Mi41MDY3IDEyMi4wMDEgODIuNjI4IDEyMy45NDIgODIuNjI4QzEzNC4wMTMgODIuNjI4IDE0My43OCA4MS4wNTA3IDE1My4yNDQgNzcuODk2QzE2Mi43MDggNzQuNzQxMyAxNzAuNTk1IDcwLjg1ODcgMTc2LjkwNCA2Ni4yNDhDMTgzLjIxMyA2MS41MTYgMTg4LjI0OSA1Ni41NDEzIDE5Mi4wMSA1MS4zMjRDMTk1Ljc3MSA0NS45ODUzIDE5Ny42NTIgNDEuMTkyNyAxOTcuNjUyIDM2Ljk0NlpNOTIuMjc0IDE3Mi4xNzJDMTAxLjEzMSAxNzQuMzU2IDExMS42ODcgMTc2LjkwNCAxMjMuOTQyIDE3OS44MTZDMTI3Ljk0NiAxNzMuMjY0IDEzNC43NDEgMTY3Ljk4NiAxNDQuMzI2IDE2My45ODJDMTU0LjAzMyAxNTkuODU3IDE2Ni4yODcgMTU3Ljc5NCAxODEuMDkgMTU3Ljc5NEMxODkuODI2IDE1Ny43OTQgMTk2Ljc0MiAxNTkuMTI5IDIwMS44MzggMTYxLjc5OEMyMDcuMDU1IDE2NC40NjcgMjA5LjY2NCAxNjcuNjgzIDIwOS42NjQgMTcxLjQ0NEMyMDkuNjY0IDE3Ni4wNTUgMjA1LjcyMSAxODAuMTE5IDE5Ny44MzQgMTgzLjYzOEMxOTAuMDY5IDE4Ny4xNTcgMTc5Ljg3NyAxODguOTE2IDE2Ny4yNTggMTg4LjkxNkMxNTQuNzYxIDE4OC45MTYgMTQwLjgwNyAxODcuNDYgMTI1LjM5OCAxODQuNTQ4QzEyNC4xODUgMTg3LjQ2IDEyMy41NzggMTkwLjYxNSAxMjMuNTc4IDE5NC4wMTJDMTIzLjU3OCAyMDEuODk5IDEyNy40IDIwOC42MzMgMTM1LjA0NCAyMTQuMjE0QzE0Mi44MDkgMjE5LjkxNyAxNTMuNTQ3IDIyMi43NjggMTY3LjI1OCAyMjIuNzY4TDE2Ny45ODYgMjI0LjIyNEMxNjUuODAyIDIyNC40NjcgMTY0LjE2NCAyMjQuNTg4IDE2My4wNzIgMjI0LjU4OEMxNTAuMDg5IDIyNC41ODggMTM5LjY1NSAyMjEuNDMzIDEzMS43NjggMjE1LjEyNEMxMjQuMDAzIDIwOC45MzYgMTIwLjEyIDIwMS41OTUgMTIwLjEyIDE5My4xMDJDMTIwLjEyIDE4OS44MjYgMTIwLjcyNyAxODYuNzkzIDEyMS45NCAxODQuMDAyQzEwOS45MjggMTgxLjQ1NCA5Ny45MTYgMTc4LjYwMyA4NS45MDQgMTc1LjQ0OEM2Ny40NjEzIDE4NC42NjkgNDkuMDc5MyAxODkuMjggMzAuNzU4IDE4OS4yOEMyMS42NTggMTg5LjI4IDE0LjI1NjcgMTg3LjQ2IDguNTU0IDE4My44MkMyLjg1MTMzIDE4MC4zMDEgMCAxNzYuNTQgMCAxNzIuNTM2QzAgMTY4LjUzMiAyLjE4NCAxNjUuMzE3IDYuNTUyIDE2Mi44OUMxMC45MiAxNjAuMzQyIDE3LjQxMTMgMTU5LjA2OCAyNi4wMjYgMTU5LjA2OEMzNC43NjIgMTU5LjA2OCA1NS4xNDYgMTYzLjAxMSA4Ny4xNzggMTcwLjg5OEMxMDMuOTIyIDE2MS4xOTEgMTIyLjkxMSAxNDUuMjk3IDE0NC4xNDQgMTIzLjIxNEMxMzMuNTg4IDEyMC45MDkgMTI1LjY0MSAxMTYuMjk4IDEyMC4zMDIgMTA5LjM4MkMxMTQuOTYzIDEwMi4zNDUgMTEyLjI5NCA5NC4wMzMzIDExMi4yOTQgODQuNDQ4Vjg0LjA4NEMxMDIuMzQ1IDgyLjk5MiA5NC45NDMzIDgwLjE0MDcgOTAuMDkgNzUuNTNDODUuMzU4IDcwLjkxOTMgODIuOTkyIDY1LjIxNjcgODIuOTkyIDU4LjQyMkM4Mi45OTIgNDYuODk1MyA4OC45MzczIDM1LjEyNiAxMDAuODI4IDIzLjExNEMxMTIuNzE5IDEwLjk4MDcgMTI2Ljg1NCAzLjI3NiAxNDMuMjM0IDBMMTQzLjc4IDEuNjM4QzEyNy40IDUuMDM1MzMgMTEzLjYyOSAxMi4zNzYgMTAyLjQ2NiAyMy42NkM5MS4zMDMzIDM0LjgyMjcgODUuNzIyIDQ1Ljg2NCA4NS43MjIgNTYuNzg0Qzg1LjcyMiA2My4yMTQ3IDg3LjkwNiA2OC42NzQ3IDkyLjI3NCA3My4xNjRDOTYuNjQyIDc3LjUzMiAxMDMuMzE1IDgwLjQ0NCAxMTIuMjk0IDgxLjlDMTEyLjY1OCA3NC42MiAxMTQuNTM5IDY3LjQ2MTMgMTE3LjkzNiA2MC40MjRDMTIxLjMzMyA1My4yNjUzIDEyNS44MjMgNDYuNzc0IDEzMS40MDQgNDAuOTVDMTM3LjEwNyAzNS4wMDQ3IDE0NC4yNjUgMzAuMjEyIDE1Mi44OCAyNi41NzJDMTYxLjQ5NSAyMi45MzIgMTcwLjEwOSAyMS4xMTIgMTc4LjcyNCAyMS4xMTJDMTk0LjQ5NyAyMS4xMTIgMjAyLjM4NCAyNi4wMjYgMjAyLjM4NCAzNS44NTRDMjAyLjM4NCA0MC41ODYgMjAwLjM4MiA0NS44MDMzIDE5Ni4zNzggNTEuNTA2QzE5Mi4zNzQgNTcuMDg3MyAxODYuOTc1IDYyLjM2NTMgMTgwLjE4IDY3LjM0QzE3My41MDcgNzIuMTkzMyAxNjUuMDEzIDc2LjMxODcgMTU0LjcgNzkuNzE2QzE0NC41MDggODIuOTkyIDEzMy43NyA4NC42MyAxMjIuNDg2IDg0LjYzQzExOS41NzQgODQuNjMgMTE3LjQ1MSA4NC41NjkzIDExNi4xMTYgODQuNDQ4Vjg2LjI2OEMxMTYuMTE2IDk0Ljg4MjcgMTE4LjYwMyAxMDIuMjg0IDEyMy41NzggMTA4LjQ3MkMxMjguNjc0IDExNC41MzkgMTM2LjM3OSAxMTguNTQzIDE0Ni42OTIgMTIwLjQ4NEMxNTAuNTc1IDExNi40OCAxNTYuMjc3IDExMC4zNTMgMTYzLjggMTAyLjEwMkMxNzEuNDQ0IDkzLjg1MTMgMTc3LjIwNyA4Ny42NjMzIDE4MS4wOSA4My41MzhDMTg1LjA5NCA3OS40MTI3IDE5MC4zMTEgNzQuMzE2NyAxOTYuNzQyIDY4LjI1QzIwMy4xNzMgNjIuMTgzMyAyMDguNTcyIDU3LjY5NCAyMTIuOTQgNTQuNzgyQzIyNC40NjcgNDcuMjU5MyAyMzQuNzE5IDQzLjQ5OCAyNDMuNjk4IDQzLjQ5OEMyNTUuMjI1IDQzLjQ5OCAyNjAuOTg4IDQ3LjMyIDI2MC45ODggNTQuOTY0QzI2MC45ODggNjAuNTQ1MyAyNTcuODMzIDY3LjM0IDI1MS41MjQgNzUuMzQ4QzI0NS4zMzYgODMuMzU2IDIzNy41MSA5MSAyMjguMDQ2IDk4LjI4QzIxOC41ODIgMTA1LjU2IDIwNy40OCAxMTEuODA5IDE5NC43NCAxMTcuMDI2QzE4Mi4xMjEgMTIyLjEyMiAxNzAuMDQ5IDEyNC42NyAxNTguNTIyIDEyNC42N0MxNTUuNjEgMTI0LjY3IDE1My40ODcgMTI0LjYwOSAxNTIuMTUyIDEyNC40ODhDMTMwLjQzMyAxNDYuMjA3IDExMC40NzQgMTYyLjEwMSA5Mi4yNzQgMTcyLjE3MloiIGZpbGw9ImJsYWNrIi8+Cjwvc3ZnPgo";

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const params = new URLSearchParams(window.location.search);
let parallaxEnabled = params.get("parallax") === "1";
let startTime = performance.now();
let reveal = reducedMotion ? 1 : 0;
let effectReveal = reducedMotion ? 1 : 0;
let finalReveal = reducedMotion ? 1 : 0;
let logoTexture = null;
let logoReady = false;
let strokeLengths = [];

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

float curlBand(vec2 logoUV, vec2 center, float radius, float width, float startAngle, float endAngle) {
  vec2 delta = logoUV - center;
  float distance = length(delta);
  float angle = atan(delta.y, delta.x);
  float ring = 1.0 - smoothstep(width, width * 2.1, abs(distance - radius));
  float start = smoothstep(startAngle - 0.22, startAngle + 0.08, angle);
  float end = 1.0 - smoothstep(endAngle - 0.08, endAngle + 0.24, angle);
  return ring * start * end;
}

void main() {
  vec2 frag = v_uv * u_resolution;
  vec2 logoUV = (frag - u_logoRect.xy) / u_logoRect.zw;
  logoUV.y = 1.0 - logoUV.y;

  float writtenNoise = noise(vec2(logoUV.x * 5.0 - u_time * 0.24, logoUV.y * 3.0));
  float revealEdge = smoothstep(-0.05, 0.12, u_reveal + (writtenNoise - 0.5) * 0.04);
  float revealGlow = smoothstep(0.0, 0.36, u_reveal);
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

  float fCurl = curlBand(logoUV, vec2(0.54, 0.54), 0.215, 0.022, -2.56, 0.82) * revealMask;
  vec2 curlTangent = normalize(vec2(-(logoUV.y - 0.54), logoUV.x - 0.54));
  vec2 curlOffset = curlTangent * texel * 34.0 + vec2(-texel.x * 14.0, texel.y * 3.0);
  float curlAlpha = progressiveLogoBlur(logoUV + curlOffset, texel, 5.8) * fCurl;
  float curlEdge = max(
    logoAlpha(logoUV + curlOffset * 1.2 + texel * vec2(8.0, -2.0)),
    logoAlpha(logoUV + curlOffset * 0.75 - texel * vec2(7.0, 2.0))
  ) * fCurl;

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
  color += vec3(0.02, 0.0, 0.0) * curlAlpha * 0.72;
  color += vec3(0.95, 0.7, 0.14) * curlEdge * 0.18;
  color += vec3(0.12, 0.52, 0.88) * curlEdge * 0.16;

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
    curlAlpha * 0.78 +
    curlEdge * 0.18 +
    caustic * 0.52 +
    writeSpark +
    treatedInk * 0.92,
    0.0,
    0.92
  );

  gl_FragColor = vec4(color, alpha);
}
`;

function prepareWriteStrokes() {
  strokeLengths = writeStrokes.map(path => {
    const length = path.getTotalLength();
    path.style.strokeDasharray = `${length}`;
    path.style.strokeDashoffset = reducedMotion ? "0" : `${length}`;
    return length;
  });
}

function updateWriteStrokes(progress) {
  if (!strokeLengths.length) {
    return;
  }

  const strokeCount = Math.max(1, writeStrokes.length);
  writeStrokes.forEach((path, index) => {
    const stagger = index / strokeCount * 0.42;
    const localProgress = Math.max(0, Math.min(1, (progress - stagger) / 0.5));
    const eased = 1 - Math.pow(1 - localProgress, 3);
    path.style.strokeDashoffset = `${strokeLengths[index] * (1 - eased)}`;
  });
}

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
  image.src = logoTextureSource;
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
    effectReveal = 1;
    finalReveal = 1;
  } else {
    const writeTime = Number(controls.writeTime.value);
    const finalDelay = Number(controls.finalDelay.value);
    const finalFade = Number(controls.finalFade.value);
    const effectFade = Number(controls.effectFade.value);
    const rawReveal = Math.min(1, elapsed / writeTime);
    reveal = rawReveal * rawReveal * (3 - 2 * rawReveal);
    finalReveal = Math.min(1, Math.max(0, (elapsed - finalDelay) / finalFade));
    effectReveal = Math.min(1, elapsed / effectFade);
  }

  updateWriteStrokes(reveal);
  document.documentElement.style.setProperty("--reveal", reveal.toFixed(4));
  document.documentElement.style.setProperty("--effect-reveal", effectReveal.toFixed(4));
  document.documentElement.style.setProperty("--final-reveal", finalReveal.toFixed(4));
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
  effectReveal = reducedMotion ? 1 : 0;
  finalReveal = reducedMotion ? 1 : 0;
  updateWriteStrokes(reveal);
  document.documentElement.style.setProperty("--effect-reveal", effectReveal.toFixed(4));
  document.documentElement.style.setProperty("--final-reveal", finalReveal.toFixed(4));
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
  window.webkit?.messageHandlers?.lineformIntro?.postMessage("dismiss");
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
prepareWriteStrokes();

if (gl && program) {
  createLogoTexture();
  requestAnimationFrame(animate);
} else {
  shell.classList.add("is-complete");
  document.documentElement.style.setProperty("--reveal", "1");
}
