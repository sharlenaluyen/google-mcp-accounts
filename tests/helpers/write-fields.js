// Child process for the cross-process lock test in store.test.js. Waits until
// a shared start time, then writes `count` distinct fields to the "main"
// account one after another, in the config folder given by GOOGLE_MCP_DIR.
import { setAccountField } from "../../store.js";

const [id, count, startAt] = process.argv.slice(2);
await new Promise((resolve) => setTimeout(resolve, Math.max(0, Number(startAt) - Date.now())));
for (let i = 0; i < Number(count); i++) {
  await setAccountField("main", `w${id}_${i}`, i);
}
