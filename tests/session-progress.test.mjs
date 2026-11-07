import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const updateProgress = app.slice(app.indexOf("function updateSessionProgress("), app.indexOf("function loadLastSession("));

test("the ring and set count agree when a workout starts, gains sets, and finishes", () => {
  const attributes = new Map();
  const styles = new Map();
  const els = {
    exerciseList: [], extraActivityList: [], progressValue: {}, setCount: {},
    progressRing: { style: { setProperty: (key, value) => styles.set(key, value) },
      setAttribute: (key, value) => attributes.set(key, value) },
  };
  const context = vm.createContext({ els, $$: (_selector, list) => list });
  vm.runInContext(updateProgress, context);
  function check(percent, label) {
    context.updateSessionProgress();
    assert.equal(els.progressValue.textContent, `${percent}%`);
    assert.equal(styles.get("--progress"), `${percent}%`);
    assert.equal(attributes.get("aria-valuenow"), String(percent));
    assert.equal(attributes.get("aria-valuetext"), label);
    assert.equal(els.setCount.textContent, label);
  }
  check(0, "No sets planned");
  els.exerciseList.push({ checked: false });
  check(0, "0 of 1 set complete");
  els.exerciseList[0].checked = true;
  check(100, "1 of 1 set complete");
  els.exerciseList.push({ checked: false });
  els.extraActivityList.push({ checked: false });
  check(33, "1 of 3 sets complete");
  els.exerciseList[1].checked = true;
  els.extraActivityList[0].checked = true;
  check(100, "3 of 3 sets complete");
});
