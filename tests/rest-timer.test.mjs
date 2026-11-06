import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import { shouldShowRestTimer } from "../lib.js";

// Exercise the production controller with a deterministic clock, without adding a DOM dependency.
const source = await readFile(new URL("../app.js", import.meta.url), "utf8");
const controller = source.slice(source.indexOf("const timer = {"), source.indexOf("function bindEvents()"));

function element(dataset = {}) {
  const classes = new Set();
  return {
    dataset,
    textContent: "",
    attributes: {},
    style: { setProperty(name, value) { this[name] = value; } },
    setAttribute(name, value) { this.attributes[name] = value; },
    classList: {
      add(name) { classes.add(name); },
      remove(name) { classes.delete(name); },
      contains(name) { return classes.has(name); },
      toggle(name, enabled = !classes.has(name)) {
        if (enabled) classes.add(name);
        else classes.delete(name);
        return enabled;
      },
    },
  };
}

function setup() {
  let now = 0;
  let nextId = 0;
  const jobs = new Map();
  const nodes = new Map(["rest-timer", "timer-label", "timer-time", "timer-play"].map((id) => [`#${id}`, element()]));
  const presets = [60, 90, 120, 180].map((seconds) => element({ timer: String(seconds) }));
  const messages = [];
  const vibrations = [];
  const schedule = (callback, delay, repeat) => {
    const id = ++nextId;
    jobs.set(id, { callback, at: now + delay, delay, repeat });
    return id;
  };
  const context = vm.createContext({
    $: (selector) => nodes.get(selector),
    $$: () => presets,
    Date: { now: () => now },
    setInterval: (callback, delay) => schedule(callback, delay, true),
    clearInterval: (id) => jobs.delete(id),
    setTimeout: (callback, delay) => schedule(callback, delay, false),
    clearTimeout: (id) => jobs.delete(id),
    navigator: { vibrate: (pattern) => vibrations.push(pattern) },
    showToast: (message) => messages.push(message),
    activeView: "today",
    shouldShowRestTimer,
  });
  vm.runInContext(controller, context);
  const run = (code) => vm.runInContext(code, context);
  run("updateTimerUi()");
  return {
    run, presets, messages, vibrations, jobs,
    node: (id) => nodes.get(`#${id}`),
    progress: () => Number(nodes.get("#rest-timer").style["--timer-progress"]),
    has: (name) => nodes.get("#rest-timer").classList.contains(name),
    elapse(ms) { now += ms; },
    advance(ms) {
      const target = now + ms;
      while (true) {
        const next = [...jobs].filter(([, job]) => job.at <= target).sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) break;
        const [id, job] = next;
        now = Math.max(now, job.at);
        if (job.repeat) job.at = now + job.delay;
        else jobs.delete(id);
        job.callback();
      }
      now = target;
    },
  };
}

test("rest bar starts full and shrinks with remaining time to empty", () => {
  const ui = setup();
  assert.equal(ui.progress(), 1);
  assert.equal(ui.node("timer-time").textContent, "01:30");
  ui.run("startTimer()");
  ui.advance(45_000);
  assert.equal(ui.progress(), 0.5);
  assert.equal(ui.node("timer-time").textContent, "00:45");
  ui.advance(45_000);
  assert.equal(ui.progress(), 0);
  assert.equal(ui.node("timer-time").textContent, "00:00");
});

test("final ten seconds have a text cue and emphasis, never at eleven or zero", () => {
  const ui = setup();
  ui.run("setTimer(60, true)");
  ui.advance(49_000);
  assert.equal(ui.has("is-ending"), false);
  assert.equal(ui.node("timer-label").textContent, "REST");
  ui.advance(1_000);
  assert.equal(ui.has("is-ending"), true);
  assert.equal(ui.node("timer-label").textContent, "FINAL 10s");
  ui.advance(9_000);
  assert.equal(ui.has("is-ending"), true);
  ui.advance(1_000);
  assert.equal(ui.has("is-ending"), false);
  assert.equal(ui.has("is-finished"), true);
});

test("pause freezes progress and resume keeps the remaining duration", () => {
  const ui = setup();
  ui.run("setTimer(60, true)");
  ui.advance(20_000);
  ui.run("startTimer()");
  const progress = ui.progress();
  assert.equal(ui.node("timer-play").attributes["aria-label"], "Start rest timer");
  ui.advance(30_000);
  assert.equal(ui.progress(), progress);
  assert.equal(ui.node("timer-time").textContent, "00:40");
  ui.run("startTimer()");
  assert.equal(ui.node("timer-play").attributes["aria-label"], "Pause rest timer");
  ui.advance(40_000);
  assert.equal(ui.has("is-finished"), true);
});

test("pausing in the final seconds keeps the cue but does not complete", () => {
  const ui = setup();
  ui.run("setTimer(60, true)");
  ui.advance(53_000);
  ui.run("startTimer()");
  ui.advance(60_000);
  assert.equal(ui.node("timer-time").textContent, "00:07");
  assert.equal(ui.has("is-ending"), true);
  assert.equal(ui.has("is-finished"), false);
});

test("done persists beyond five seconds and across views until restarted", () => {
  const ui = setup();
  ui.run("setTimer(60, true); activeView = 'progress'; syncTimerVisibility()");
  ui.advance(60_000);
  ui.advance(60_000);
  ui.run("activeView = 'data'; syncTimerVisibility(); updateTimerUi()");
  assert.equal(ui.has("is-finished"), true);
  assert.equal(ui.has("is-context-hidden"), false);
  assert.equal(ui.node("timer-label").textContent, "REST DONE");
  assert.equal(ui.jobs.size, 0);
  assert.equal(ui.messages.length, 1);
  assert.equal(ui.vibrations.length, 1);
  ui.run("startTimer()");
  assert.equal(ui.has("is-finished"), false);
  assert.equal(ui.node("timer-label").textContent, "REST");
  assert.equal(ui.node("timer-time").textContent, "01:00");
  assert.equal(ui.progress(), 1);
  ui.advance(6_000);
  assert.equal(ui.has("is-finished"), false);
});

test("reset clears ending and done states, stops ticking and refills the bar", () => {
  const ui = setup();
  ui.run("setTimer(60, true)");
  ui.advance(55_000);
  ui.run("setTimer(timer.total)");
  assert.equal(ui.has("is-ending"), false);
  assert.equal(ui.progress(), 1);
  assert.equal(ui.jobs.size, 0);
  ui.run("startTimer()");
  ui.advance(60_000);
  ui.run("activeView = 'progress'; setTimer(timer.total)");
  assert.equal(ui.has("is-finished"), false);
  assert.equal(ui.has("is-context-hidden"), true);
  assert.equal(ui.node("timer-label").textContent, "REST");
  assert.equal(ui.progress(), 1);
});

test("presets replace a running or completed timer and select the new duration", () => {
  const ui = setup();
  ui.run("setTimer(90, true)");
  ui.advance(50_000);
  ui.run("setTimer(120)");
  ui.advance(90_000);
  assert.equal(ui.node("timer-time").textContent, "02:00");
  assert.equal(ui.jobs.size, 0);
  assert.equal(ui.presets.find((button) => button.classList.contains("is-active")).dataset.timer, "120");
  ui.run("startTimer()");
  ui.advance(120_000);
  ui.run("setTimer(180)");
  assert.equal(ui.has("is-finished"), false);
  assert.equal(ui.node("timer-time").textContent, "03:00");
});

test("rapid toggles and repeated set-completion starts leave only one active countdown", () => {
  const ui = setup();
  ui.run("startTimer(); startTimer(); startTimer(); setTimer(60, true); setTimer(120, true)");
  assert.equal(ui.jobs.size, 1);
  ui.advance(60_000);
  assert.equal(ui.node("timer-time").textContent, "01:00");
  assert.equal(ui.messages.length, 0);
  ui.advance(60_000);
  assert.equal(ui.messages.length, 1);
  assert.equal(ui.jobs.size, 0);
});

test("a delayed interval uses the deadline rather than losing elapsed time", () => {
  const ui = setup();
  ui.run("setTimer(60, true)");
  ui.elapse(75_000);
  ui.advance(0);
  assert.equal(ui.has("is-finished"), true);
  assert.equal(ui.progress(), 0);
  assert.equal(ui.messages.length, 1);
});

test("pause at an expired deadline still produces the persistent completion cue", () => {
  const ui = setup();
  ui.run("setTimer(60, true)");
  ui.elapse(60_000);
  ui.run("startTimer()");
  assert.equal(ui.has("is-finished"), true);
  assert.equal(ui.node("timer-time").textContent, "00:00");
  assert.equal(ui.messages.length, 1);
  assert.equal(ui.jobs.size, 0);
});

test("progress stays in its valid visual range", () => {
  const ui = setup();
  ui.run("timer.remaining = 120; updateTimerUi()");
  assert.equal(ui.progress(), 1);
  ui.run("timer.remaining = -1; updateTimerUi()");
  assert.equal(ui.progress(), 0);
  ui.run("setTimer(0)");
  assert.equal(ui.progress(), 0);
});

test("visible bar consumes progress and reduced motion disables timer effects", async () => {
  const html = await readFile(new URL("../index.html", import.meta.url), "utf8");
  const css = await readFile(new URL("../styles.css", import.meta.url), "utf8");
  assert.match(html, /class="timer-progress" aria-hidden="true"><div class="timer-progress-fill">/);
  assert.match(css, /\.timer-progress-fill\s*\{[^}]*transform: scaleX\(var\(--timer-progress\)\)/);
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)\s*\{\s*\.timer-progress-fill\s*\{\s*transition: none;/);
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)[\s\S]*?\.timer\.is-finished\s*\{\s*animation: none;/);
});
